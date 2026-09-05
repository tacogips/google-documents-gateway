import Darwin
import Foundation

/// Defers reading credential configuration until a command has passed all local gates and
/// actually needs an OAuth token. This keeps schema, help, dry-run, and rejected-role paths
/// independent of caller-controlled credential files.
struct GatewayDeferredAuthorizer: GatewayCancellableAuthorizer {
  let role: GatewayRole
  let environment: [String: String]
  let transport: GatewayHTTPTransport
  let decoder: GatewaySDKCredentialDecoder

  func accessToken(for role: GatewayRole) throws -> String {
    guard role == self.role else { throw GatewayError.scopeMismatch }
    guard let profile = try? GatewayCredentialProfileLoader.load(role: role, environment: environment) else {
      throw GatewayError.authenticationRequired
    }
    return try PersistedTokenAuthorizer(profile: profile, transport: transport).accessToken(for: role)
  }

  func accessToken(for role: GatewayRole, cancellation: GatewaySDKCancellation) throws -> String {
    guard role == self.role else { throw GatewayError.scopeMismatch }
    let profile: GatewayCredentialProfile
    do {
      profile = try GatewaySDKCredentialProfileLoader.load(
        role: role,
        environment: environment,
        cancellation: cancellation,
        decoder: decoder
      )
    } catch GatewayError.inputTooLarge {
      throw GatewayError.inputTooLarge
    } catch GatewayError.transportFailure {
      throw GatewayError.transportFailure("SDK execution was cancelled")
    } catch {
      throw GatewayError.authenticationRequired
    }
    return try GatewaySDKPersistedAuthorizer(
      profile: profile,
      transport: transport,
      cancellation: cancellation,
      decoder: decoder
    ).accessToken(for: role, cancellation: cancellation)
  }
}

struct GatewaySDKPersistedAuthorizer: GatewayCancellableAuthorizer {
  let profile: GatewayCredentialProfile
  let transport: GatewayHTTPTransport
  let cancellation: GatewaySDKCancellation
  let decoder: GatewaySDKCredentialDecoder
  /// Test-only synchronization seam before a file-backed token store is replaced.
  /// Production keeps this a no-op.
  let tokenStorePersistenceObserver: @Sendable () -> Void
  /// Test-only seam invoked after replacement and before subsequent provider dispatch.
  /// Production keeps this a no-op.
  let tokenStorePersistenceCompletedObserver: @Sendable () -> Void
  /// Test-only seam invoked when a same-store refresh waits for the single-flight owner.
  /// Production keeps this a no-op.
  let tokenStoreRefreshWaitObserver: @Sendable () -> Void

  init(
    profile: GatewayCredentialProfile,
    transport: GatewayHTTPTransport,
    cancellation: GatewaySDKCancellation,
    decoder: GatewaySDKCredentialDecoder,
    tokenStorePersistenceObserver: @escaping @Sendable () -> Void = {},
    tokenStorePersistenceCompletedObserver: @escaping @Sendable () -> Void = {},
    tokenStoreRefreshWaitObserver: @escaping @Sendable () -> Void = {}
  ) {
    self.profile = profile
    self.transport = transport
    self.cancellation = cancellation
    self.decoder = decoder
    self.tokenStorePersistenceObserver = tokenStorePersistenceObserver
    self.tokenStorePersistenceCompletedObserver = tokenStorePersistenceCompletedObserver
    self.tokenStoreRefreshWaitObserver = tokenStoreRefreshWaitObserver
  }

  func accessToken(for role: GatewayRole) throws -> String {
    try PersistedTokenAuthorizer(profile: profile, transport: transport).accessToken(for: role)
  }

  func accessToken(for role: GatewayRole, cancellation _: GatewaySDKCancellation) throws -> String {
    try checkCancellation()
    guard role == profile.role else { throw GatewayError.scopeMismatch }
    let store = try loadStore(role: role)
    guard !store.accessToken.isEmpty else { throw GatewayError.authenticationRequired }
    let token: String
    if let expiresAt = store.expiresAt, expiresAt <= Date().addingTimeInterval(60) {
      if profile.tokenStoreJSON == nil {
        token = try GatewaySDKCredentialRefreshCoordinator.shared.withLock(
          for: profile.tokenStoreURL, cancellation: cancellation, waitObserver: tokenStoreRefreshWaitObserver
        ) {
          let current = try loadStore(role: role)
          if current.expiresAt.map({ $0 > Date().addingTimeInterval(60) }) ?? true {
            return current.accessToken
          }
          let refreshed = try refresh(current)
          try checkCancellation()
          tokenStorePersistenceObserver()
          try checkCancellation()
          // Credential persistence is local state, not invocation completion. A cancellation that
          // races or follows this atomic replacement must still stop provider work below.
          try GatewayTokenStoreFile.write(refreshed, to: profile.tokenStoreURL)
          tokenStorePersistenceCompletedObserver()
          try checkCancellation()
          return refreshed.accessToken
        }
      } else {
        let refreshed = try refresh(store)
        try checkCancellation()
        token = refreshed.accessToken
      }
    } else {
      token = store.accessToken
    }
    try checkCancellation()
    return token
  }

  private func refresh(_ previous: GatewayTokenStore) throws -> GatewayTokenStore {
    try previous.validates(role: profile.role)
    guard let refreshToken = previous.refreshToken, !refreshToken.isEmpty,
          let endpoint = URL(string: "https://oauth2.googleapis.com/token") else {
      throw GatewayError.authenticationRequired
    }
    var form = ["client_id": profile.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken]
    if let secret = profile.clientSecret, !secret.isEmpty { form["client_secret"] = secret }
    let body = try encodedRefreshForm(form)
    let response = try transport.send(
      url: endpoint, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded"], body: Data(body.utf8)
    )
    try checkCancellation()
    guard (200...299).contains(response.statusCode),
          try GatewayBoundedProviderJSON.structureIsBounded(response.data, cancellation: cancellation) else {
      throw GatewayError.authenticationRequired
    }
    try checkCancellation()
    let token = try decoder.decodeOAuthTokenResponse(response.data)
    try checkCancellation()
    guard !token.accessToken.isEmpty else { throw GatewayError.authenticationRequired }
    let scope = token.scope ?? previous.scope
    guard scope == profile.role.scope else { throw GatewayError.scopeMismatch }
    return .init(
      role: profile.role, accessToken: token.accessToken,
      refreshToken: token.refreshToken ?? previous.refreshToken,
      expiresAt: token.expiresIn.map { Date().addingTimeInterval($0) } ?? previous.expiresAt
    )
  }

  private func encodedRefreshForm(_ form: [String: String]) throws -> String {
    var pairs: [String] = []
    for key in form.keys.sorted() {
      try checkCancellation()
      let value = form[key] ?? ""
      try GatewaySDKCredentialProfileLoader.validateField(value, cancellation: cancellation)
      let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
      try checkCancellation()
      pairs.append("\(key)=\(encoded)")
    }
    return pairs.joined(separator: "&")
  }

  private func checkCancellation() throws {
    if cancellation.isCancelled { throw GatewayError.transportFailure("SDK execution was cancelled") }
  }

  private func loadStore(role: GatewayRole) throws -> GatewayTokenStore {
    if let tokenStoreJSON = profile.tokenStoreJSON {
      let data = try GatewaySDKCredentialProfileLoader.boundedInlineData(tokenStoreJSON, cancellation: cancellation)
      let store = try decoder.decodeTokenStore(data)
      try store.validates(role: role)
      try GatewaySDKCredentialProfileLoader.validateTokenStoreFields(store, cancellation: cancellation)
      try checkCancellation()
      return store
    }
    let data = try GatewaySDKCredentialProfileLoader.boundedData(at: profile.tokenStoreURL.path, cancellation: cancellation)
    let store = try decoder.decodeTokenStore(data)
    try store.validates(role: role)
    try GatewaySDKCredentialProfileLoader.validateTokenStoreFields(store, cancellation: cancellation)
    try checkCancellation()
    return store
  }
}

/// Serializes refresh-and-replace work for one file-backed credential store. Waiting callers
/// reread under the same lock so a completed refresh is reused instead of overwritten.
final class GatewaySDKCredentialRefreshCoordinator: @unchecked Sendable {
  static let shared = GatewaySDKCredentialRefreshCoordinator()

  private let lock = NSLock()
  private var locks: [String: NSLock] = [:]

  func withLock<T>(
    for url: URL, cancellation: GatewaySDKCancellation, waitObserver: @escaping @Sendable () -> Void,
    operation: () throws -> T
  ) throws -> T {
    let identity = try fileIdentity(for: url)
    let key = "\(identity.device):\(identity.inode)"
    let storeLock = lock.withLock { () -> NSLock in
      if let existing = locks[key] { return existing }
      let created = NSLock()
      locks[key] = created
      return created
    }
    while !storeLock.try() {
      waitObserver()
      if cancellation.isCancelled { throw GatewayError.transportFailure("SDK execution was cancelled") }
      Thread.sleep(forTimeInterval: 0.005)
    }
    defer { storeLock.unlock() }
    if cancellation.isCancelled { throw GatewayError.transportFailure("SDK execution was cancelled") }
    let descriptor = try openAdvisoryLock(for: identity)
    defer { Darwin.lockf(descriptor, F_ULOCK, 0); Darwin.close(descriptor) }
    while Darwin.lockf(descriptor, F_TLOCK, 0) != 0 {
      waitObserver()
      if cancellation.isCancelled { throw GatewayError.transportFailure("SDK execution was cancelled") }
      guard errno == EWOULDBLOCK || errno == EAGAIN else { throw GatewayError.authenticationRequired }
      Thread.sleep(forTimeInterval: 0.005)
    }
    if cancellation.isCancelled { throw GatewayError.transportFailure("SDK execution was cancelled") }
    return try operation()
  }

  private struct FileIdentity { let device: UInt64; let inode: UInt64 }

  private func fileIdentity(for url: URL) throws -> FileIdentity {
    let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard descriptor >= 0 else { throw GatewayError.authenticationRequired }
    defer { Darwin.close(descriptor) }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw GatewayError.authenticationRequired
    }
    return .init(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
  }

  private func openAdvisoryLock(for identity: FileIdentity) throws -> Int32 {
    let lockPath = FileManager.default.temporaryDirectory
      .appendingPathComponent("google-documents-gateway-sdk-refresh-\(identity.device)-\(identity.inode).lock").path
    let descriptor = lockPath.withCString {
      Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else { throw GatewayError.authenticationRequired }
    return descriptor
  }
}

enum GatewaySDKCredentialProfileLoader {
  private static let maximumBytes = GatewayInputValidator.maximumBodyBytes
  static let maximumFieldBytes = 64 * 1024

  static func load(
    role: GatewayRole,
    credentialID: String? = nil,
    environment: [String: String],
    cancellation: GatewaySDKCancellation,
    decoder: GatewaySDKCredentialDecoder = .live
  ) throws -> GatewayCredentialProfile {
    let id = nonBlank(credentialID) ?? role.identifier
    try GatewayCredentialProfile.validateID(id)
    let suffix = id.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    let prefix = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(suffix)_"
    let client: SDKInstalledClient?
    if let json = try boundedNonBlankInline(environment[prefix + "OAUTH_CLIENT_SECRET_JSON"], cancellation: cancellation) {
      client = try installedClient(from: json.data, cancellation: cancellation, decoder: decoder)
    } else { client = nil }
    let inlineClientID = try boundedNonBlankInline(
      environment[prefix + "OAUTH_CLIENT_ID"], cancellation: cancellation, maximumBytes: maximumFieldBytes
    )?.value
    guard let clientID = client?.clientID ?? inlineClientID else { throw GatewayError.authenticationRequired }
    let tokenStoreJSON = try boundedNonBlankInline(environment[prefix + "TOKEN_STORE_JSON"], cancellation: cancellation)
    // An SDK environment is call-scoped data, not authority over the host filesystem. File
    // credentials remain available only through a constructor-injected trusted profile.
    guard let tokenStoreJSON else { throw GatewayError.authenticationRequired }
    return try GatewayCredentialProfile(
      id: id, role: role, clientID: clientID, clientSecret: client?.clientSecret,
      tokenStoreURL: URL(fileURLWithPath: "/dev/null"), tokenStoreJSON: tokenStoreJSON.value
    )
  }

  static func boundedData(at path: String, cancellation: GatewaySDKCancellation) throws -> Data {
    try check(cancellation)
    let descriptor = path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
    guard descriptor >= 0 else { throw GatewayError.authenticationRequired }
    defer { Darwin.close(descriptor) }
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { throw GatewayError.authenticationRequired }
    let data = try CatalogFileSnapshots.readBoundedData(from: descriptor, maximumBytes: maximumBytes, cancellation: cancellation)
    guard data.count <= maximumBytes else { throw GatewayError.inputTooLarge }
    try check(cancellation)
    return data
  }

  static func boundedInlineData(_ value: String, cancellation: GatewaySDKCancellation) throws -> Data {
    try check(cancellation)
    guard value.lengthOfBytes(using: .utf8) <= maximumBytes else { throw GatewayError.inputTooLarge }
    let data = Data(value.utf8)
    try check(cancellation)
    return data
  }

  private static func boundedNonBlankInline(
    _ value: String?, cancellation: GatewaySDKCancellation, maximumBytes: Int = maximumBytes
  ) throws -> (value: String, data: Data)? {
    guard let value else { return nil }
    try check(cancellation)
    guard value.lengthOfBytes(using: .utf8) <= maximumBytes else { throw GatewayError.inputTooLarge }
    let data = Data(value.utf8)
    var index = 0
    for scalar in value.unicodeScalars {
      if index.isMultiple(of: 1_024) { try check(cancellation) }
      if !CharacterSet.whitespacesAndNewlines.contains(scalar) { return (value, data) }
      index += 1
    }
    try check(cancellation)
    return nil
  }

  private static func installedClient(
    from data: Data, cancellation: GatewaySDKCancellation, decoder: GatewaySDKCredentialDecoder
  ) throws -> SDKInstalledClient {
    try check(cancellation)
    guard
      let client = try decoder.decodeInstalledClient(data).installed,
      nonBlank(client.clientID) != nil
    else {
      throw GatewayError.invalidArgument("OAuth client JSON must contain an installed Desktop client")
    }
    try check(cancellation)
    return .init(
      clientID: try boundedRequiredField(client.clientID, cancellation: cancellation),
      clientSecret: try boundedOptionalField(client.clientSecret, cancellation: cancellation)
    )
  }

  static func validateField(_ value: String, cancellation: GatewaySDKCancellation) throws {
    try check(cancellation)
    guard value.lengthOfBytes(using: .utf8) <= maximumFieldBytes else { throw GatewayError.inputTooLarge }
    try check(cancellation)
  }

  static func validateTokenStoreFields(_ store: GatewayTokenStore, cancellation: GatewaySDKCancellation) throws {
    try validateField(store.accessToken, cancellation: cancellation)
    if let refreshToken = store.refreshToken { try validateField(refreshToken, cancellation: cancellation) }
  }

  private static func boundedRequiredField(_ value: String, cancellation: GatewaySDKCancellation) throws -> String {
    guard let bounded = try boundedNonBlankInline(value, cancellation: cancellation, maximumBytes: maximumFieldBytes)?.value else {
      throw GatewayError.invalidArgument("OAuth client JSON must contain an installed Desktop client")
    }
    return bounded
  }

  private static func boundedOptionalField(_ value: String?, cancellation: GatewaySDKCancellation) throws -> String? {
    try boundedNonBlankInline(value, cancellation: cancellation, maximumBytes: maximumFieldBytes)?.value
  }

  private static func nonBlank(_ value: String?) -> String? { value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : nil }
  private static func check(_ cancellation: GatewaySDKCancellation) throws { if cancellation.isCancelled { throw GatewayError.transportFailure("SDK execution was cancelled") } }
}

struct SDKInstalledClientFile: Decodable { let installed: SDKInstalledClient? }
struct SDKInstalledClient: Decodable {
  let clientID: String; let clientSecret: String?
  enum CodingKeys: String, CodingKey { case clientID = "client_id"; case clientSecret = "client_secret" }
}

struct GatewaySDKCredentialDecoder: Sendable {
  let decodeInstalledClient: @Sendable (Data) throws -> SDKInstalledClientFile
  let decodeTokenStore: @Sendable (Data) throws -> GatewayTokenStore
  let decodeOAuthTokenResponse: @Sendable (Data) throws -> GatewayOAuthTokenResponse

  init(
    decodeInstalledClient: @escaping @Sendable (Data) throws -> SDKInstalledClientFile,
    decodeTokenStore: @escaping @Sendable (Data) throws -> GatewayTokenStore,
    decodeOAuthTokenResponse: @escaping @Sendable (Data) throws -> GatewayOAuthTokenResponse = {
      try JSONDecoder().decode(GatewayOAuthTokenResponse.self, from: $0)
    }
  ) {
    self.decodeInstalledClient = decodeInstalledClient
    self.decodeTokenStore = decodeTokenStore
    self.decodeOAuthTokenResponse = decodeOAuthTokenResponse
  }

  static let live = Self(
    decodeInstalledClient: { try JSONDecoder().decode(SDKInstalledClientFile.self, from: $0) },
    decodeTokenStore: { try JSONDecoder().decode(GatewayTokenStore.self, from: $0) },
    decodeOAuthTokenResponse: { try JSONDecoder().decode(GatewayOAuthTokenResponse.self, from: $0) }
  )
}
