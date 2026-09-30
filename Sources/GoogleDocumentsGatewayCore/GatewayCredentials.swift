import CryptoKit
import Foundation

public struct GatewayCredentialProfile: Sendable, Equatable {
  public let id: String
  public let role: GatewayRole
  public let clientID: String
  public let clientSecret: String?
  public let tokenStoreURL: URL
  public let tokenStoreJSON: String?
  public let tokenStorePathFromEnvironment: Bool
  /// The legacy location is populated only for an unconfigured, synthesized
  /// default. It is deliberately nil for kinko and explicit path overrides.
  public let legacyTokenStoreURL: URL?

  public init(
    id: String,
    role: GatewayRole,
    clientID: String,
    clientSecret: String? = nil,
    tokenStoreURL: URL,
    tokenStoreJSON: String? = nil,
    tokenStorePathFromEnvironment: Bool = false,
    legacyTokenStoreURL: URL? = nil
  ) throws {
    try GatewayCredentialProfile.validateID(id)
    self.id = id
    self.role = role
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.tokenStoreURL = tokenStoreURL
    self.tokenStoreJSON = tokenStoreJSON
    self.tokenStorePathFromEnvironment = tokenStorePathFromEnvironment
    self.legacyTokenStoreURL = legacyTokenStoreURL
  }

  public static func validateID(_ id: String) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    guard
      id.count <= 64,
      let first = id.unicodeScalars.first,
      CharacterSet.alphanumerics.contains(first),
      id.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      throw GatewayError.invalidArgument("Credential ID must use 1-64 letters, numbers, underscores, or hyphens and begin with a letter or number")
    }
  }
}

public enum GatewayCredentialProfileLoader {
  public static func load(role: GatewayRole, credentialID: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> GatewayCredentialProfile {
    let id = credentialID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? credentialID! : role.identifier
    try GatewayCredentialProfile.validateID(id)
    let environment = try gatewayCredentialEnvironment(role: role, id: id, source: environment)
    let suffix = id.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    let pathKey = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(suffix)_TOKEN_STORE_PATH"
    let clientKey = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(suffix)_OAUTH_CLIENT_ID"
    let secretJSONKey = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(suffix)_OAUTH_CLIENT_SECRET_JSON"
    let secretPathKey = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(suffix)_OAUTH_CLIENT_SECRET_PATH"
    let tokenJSONKey = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(suffix)_TOKEN_STORE_JSON"
    let pathOverride = nonBlank(environment[pathKey])
    let credentialDirectoryOverride = nonBlank(environment["GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR"])
    let tokenJSON = nonBlank(environment[tokenJSONKey])
    let tokenPath = pathOverride ?? defaultTokenStoreURL(
      id: id,
      credentialDirectoryOverride: credentialDirectoryOverride,
      environment: environment
    ).path
    let installedClient = try loadInstalledClient(json: environment[secretJSONKey], path: environment[secretPathKey])
    let clientID = installedClient?.clientID ?? nonBlank(environment[clientKey]) ?? ""
    guard !clientID.isEmpty || tokenJSON != nil || pathOverride != nil || FileManager.default.fileExists(atPath: tokenPath) else {
      throw GatewayError.authenticationRequired
    }
    return try GatewayCredentialProfile(
      id: id,
      role: role,
      clientID: clientID,
      clientSecret: installedClient?.clientSecret,
      tokenStoreURL: URL(fileURLWithPath: tokenPath),
      tokenStoreJSON: tokenJSON,
      tokenStorePathFromEnvironment: pathOverride != nil,
      legacyTokenStoreURL: pathOverride == nil && credentialDirectoryOverride == nil && tokenJSON == nil
        ? legacyTokenStoreURL(id: id, environment: environment)
        : nil
    )
  }

  private static func nonBlank(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
  }

  private static func loadInstalledClient(json: String?, path: String?) throws -> InstalledClient? {
    let data: Data?
    if let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      data = Data(json.utf8)
    } else if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } else {
      data = nil
    }
    guard let data else { return nil }
    guard
      let client = try JSONDecoder().decode(InstalledClientFile.self, from: data).installed,
      !client.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw GatewayError.invalidArgument("OAuth client JSON must contain an installed Desktop client")
    }
    return client
  }

  /// Tokens are auth state, not configuration: the default lives under
  /// XDG_STATE_HOME (~/.local/state), never ~/.config. Precedence:
  /// per-credential *_TOKEN_STORE_PATH (exact file) wins in load(role:) above,
  /// then GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR relocates the directory,
  /// then the XDG state default applies.
  private static func defaultTokenStoreURL(
    id: String,
    credentialDirectoryOverride: String?,
    environment: [String: String]
  ) -> URL {
    if let credentialDir = credentialDirectoryOverride {
      return URL(fileURLWithPath: credentialDir).appendingPathComponent("\(id).json")
    }
    let stateRoot = nonBlank(environment["XDG_STATE_HOME"]).flatMap { $0.hasPrefix("/") ? $0 : nil }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state").path
    return URL(fileURLWithPath: stateRoot)
      .appendingPathComponent("google-documents-gateway/credentials/\(id).json")
  }

  /// The only location migrated is the pre-0.2.1 synthesized config default.
  /// Do not derive a legacy path from an explicit token destination.
  private static func legacyTokenStoreURL(id: String, environment: [String: String]) -> URL {
    let configRoot = nonBlank(environment["XDG_CONFIG_HOME"]).flatMap { $0.hasPrefix("/") ? $0 : nil }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
    return URL(fileURLWithPath: configRoot)
      .appendingPathComponent("google-documents-gateway/tokens/\(id).json")
  }
}

private struct InstalledClientFile: Decodable {
  let installed: InstalledClient?
}

private struct InstalledClient: Decodable {
  let clientID: String
  let clientSecret: String?

  private enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case clientSecret = "client_secret"
  }
}

public struct GatewayTokenStore: Codable, Sendable, Equatable {
  public let service: GatewayService
  public let accessMode: GatewayAccessMode
  public let scope: String
  public let accessToken: String
  public let refreshToken: String?
  public let expiresAt: Date?

  public init(role: GatewayRole, accessToken: String, refreshToken: String?, expiresAt: Date?) {
    service = role.service
    accessMode = role.accessMode
    scope = role.scope
    self.accessToken = accessToken
    self.refreshToken = refreshToken
    self.expiresAt = expiresAt
  }

  public func validates(role: GatewayRole) throws {
    guard service == role.service, accessMode == role.accessMode, scope == role.scope else { throw GatewayError.scopeMismatch }
  }
}

public enum GatewayTokenStoreFile {
  public static func read(from url: URL, role: GatewayRole) throws -> GatewayTokenStore {
    try decode(try secureRead(from: url), role: role)
  }

  public static func read(json: String, role: GatewayRole) throws -> GatewayTokenStore {
    try decode(Data(json.utf8), role: role)
  }

  private static func decode(_ data: Data, role: GatewayRole) throws -> GatewayTokenStore {
    let store = try JSONDecoder().decode(GatewayTokenStore.self, from: data)
    try store.validates(role: role)
    return store
  }

  public static func write(_ store: GatewayTokenStore, to url: URL) throws {
    let data = try JSONEncoder().encode(store)
    try GatewaySecureTokenFilesystem.write(data, to: url, replacing: true)
  }

  public static func revoke(url: URL) throws {
    try GatewaySecureTokenFilesystem.remove(url)
  }

  private static let migrationMarker = Data("google-documents-gateway-token-migration-v1\n".utf8)

  /// Record that the legacy synthesized source is permanently ineligible,
  /// without reading it. Used before destructive lifecycle operations.
  public static func completeLegacyMigration(profile: GatewayCredentialProfile) throws {
    guard profile.legacyTokenStoreURL != nil else { return }
    let marker = URL(fileURLWithPath: profile.tokenStoreURL.path + ".migration-complete")
    try GatewaySecureTokenFilesystem.withMigrationLock(for: profile.tokenStoreURL) { try ensureMarker(marker) }
  }

  /// Copy a valid token from the former synthesized XDG config location only
  /// when the state destination is absent. Atomic exclusive publication never
  /// overwrites a concurrent login. Retain the legacy recovery copy, but a
  /// durable marker permanently excludes it after migration or revoke.
  public static func migrateLegacyStoreIfNeeded(profile: GatewayCredentialProfile) throws {
    guard let legacy = profile.legacyTokenStoreURL else { return }
    let marker = URL(fileURLWithPath: profile.tokenStoreURL.path + ".migration-complete")
    guard try GatewaySecureTokenFilesystem.exists(marker) || GatewaySecureTokenFilesystem.exists(profile.tokenStoreURL)
      || GatewaySecureTokenFilesystem.exists(legacy) else { return }
    try GatewaySecureTokenFilesystem.withMigrationLock(for: profile.tokenStoreURL) {
      try migrateLegacyStoreLocked(profile: profile)
    }
  }

  private static func migrateLegacyStoreLocked(profile: GatewayCredentialProfile) throws {
    guard let legacyURL = profile.legacyTokenStoreURL else { return }
    let destination = profile.tokenStoreURL
    guard legacyURL.path != destination.path else { return }
    let marker = URL(fileURLWithPath: destination.path + ".migration-complete")
    if try GatewaySecureTokenFilesystem.exists(marker) {
      guard try secureRead(from: marker) == migrationMarker else { throw POSIXError(.EINVAL) }
      return
    }

    if try GatewaySecureTokenFilesystem.exists(destination) {
      _ = try secureRead(from: destination)
      try ensureMarker(marker)
      return
    }
    guard try GatewaySecureTokenFilesystem.exists(legacyURL) else { return }
    let legacyData = try secureRead(from: legacyURL)
    _ = try decode(legacyData, role: profile.role)
    do {
      try createExclusive(data: legacyData, at: destination)
    } catch let error as POSIXError where error.code == .EEXIST {
      _ = try secureRead(from: destination)
      try ensureMarker(marker)
      return
    }
    try ensureMarker(marker)
    // Retain the legacy recovery copy. The durable marker makes it permanently
    // ineligible, including after revoke or an interrupted later operation.
  }

  /// A durable migration marker, rather than deleting a legacy path, prevents
  /// stale credentials from returning after login or revoke.
  public static func discardLegacyStore(profile: GatewayCredentialProfile) throws {
    try completeLegacyMigration(profile: profile)
  }

  private static func secureRead(from url: URL) throws -> Data {
    try GatewaySecureTokenFilesystem.read(url)
  }

  private static func createExclusive(data: Data, at url: URL) throws {
    try GatewaySecureTokenFilesystem.create(data, at: url)
  }

  private static func ensureMarker(_ marker: URL) throws {
    do { try createExclusive(data: migrationMarker, at: marker) } catch let error as POSIXError where error.code == .EEXIST {
      guard try secureRead(from: marker) == migrationMarker else { throw POSIXError(.EINVAL) }
    }
  }
}

public enum GatewayOAuthPKCE {
  public static func authorizationURL(profile: GatewayCredentialProfile, redirectURI: String, state: String, verifier: String) throws -> URL {
    guard !profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GatewayError.authenticationRequired }
    guard !state.isEmpty, verifier.count >= 43, verifier.count <= 128 else { throw GatewayError.invalidArgument("OAuth state or PKCE verifier is invalid") }
    let digest = SHA256.hash(data: Data(verifier.utf8))
    let challenge = Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    components.queryItems = [
      URLQueryItem(name: "client_id", value: profile.clientID),
      URLQueryItem(name: "redirect_uri", value: redirectURI),
      URLQueryItem(name: "response_type", value: "code"),
      URLQueryItem(name: "scope", value: profile.role.scope),
      URLQueryItem(name: "access_type", value: "offline"),
      URLQueryItem(name: "prompt", value: "consent"),
      URLQueryItem(name: "include_granted_scopes", value: "false"),
      URLQueryItem(name: "state", value: state),
      URLQueryItem(name: "code_challenge", value: challenge),
      URLQueryItem(name: "code_challenge_method", value: "S256")
    ]
    guard let url = components.url else { throw GatewayError.invalidArgument("Unable to construct OAuth URL") }
    return url
  }
}

public struct GatewayOAuthTokenResponse: Decodable, Sendable {
  public let accessToken: String
  public let refreshToken: String?
  public let scope: String?
  public let expiresIn: TimeInterval?

  private enum CodingKeys: String, CodingKey {
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case scope
    case expiresIn = "expires_in"
  }
}

public struct GatewayOAuthClient: Sendable {
  public let profile: GatewayCredentialProfile
  public let transport: GatewayHTTPTransport

  public init(profile: GatewayCredentialProfile, transport: GatewayHTTPTransport) {
    self.profile = profile
    self.transport = transport
  }

  public func exchangeAuthorizationCode(_ code: String, redirectURI: String, verifier: String) throws -> GatewayTokenStore {
    guard !profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GatewayError.authenticationRequired }
    guard !code.isEmpty, !redirectURI.isEmpty, verifier.count >= 43 else {
      throw GatewayError.invalidArgument("OAuth authorization-code inputs are invalid")
    }
    return try exchange([
      "client_id": profile.clientID,
      "code": code,
      "code_verifier": verifier,
      "grant_type": "authorization_code",
      "redirect_uri": redirectURI
    ].merging(clientSecretForm, uniquingKeysWith: { current, _ in current }), previous: nil)
  }

  public func refresh(_ previous: GatewayTokenStore) throws -> GatewayTokenStore {
    try previous.validates(role: profile.role)
    guard !profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let refreshToken = previous.refreshToken, !refreshToken.isEmpty else {
      throw GatewayError.authenticationRequired
    }
    return try exchange([
      "client_id": profile.clientID,
      "grant_type": "refresh_token",
      "refresh_token": refreshToken
    ].merging(clientSecretForm, uniquingKeysWith: { current, _ in current }), previous: previous)
  }

  public func revoke(_ store: GatewayTokenStore) throws {
    try store.validates(role: profile.role)
    let token = store.refreshToken ?? store.accessToken
    guard !token.isEmpty, let endpoint = URL(string: "https://oauth2.googleapis.com/revoke") else {
      throw GatewayError.authenticationRequired
    }
    let response = try transport.send(
      url: endpoint,
      method: "POST",
      headers: ["Content-Type": "application/x-www-form-urlencoded"],
      body: Data("token=\(formEncode(token))".utf8)
    )
    guard (200...299).contains(response.statusCode) else { throw GatewayError.authenticationRequired }
  }

  private func exchange(_ form: [String: String], previous: GatewayTokenStore?) throws -> GatewayTokenStore {
    guard let endpoint = URL(string: "https://oauth2.googleapis.com/token") else {
      throw GatewayError.transportFailure("Unable to construct OAuth token endpoint")
    }
    let body = form.keys.sorted().map { key in
      let value = form[key] ?? ""
      return "\(formEncode(key))=\(formEncode(value))"
    }.joined(separator: "&")
    let response = try transport.send(
      url: endpoint,
      method: "POST",
      headers: ["Content-Type": "application/x-www-form-urlencoded"],
      body: Data(body.utf8)
    )
    guard (200...299).contains(response.statusCode) else { throw GatewayError.authenticationRequired }
    let token = try JSONDecoder().decode(GatewayOAuthTokenResponse.self, from: response.data)
    guard !token.accessToken.isEmpty else { throw GatewayError.authenticationRequired }
    let grantedScope = token.scope ?? previous?.scope ?? profile.role.scope
    guard grantedScope == profile.role.scope else { throw GatewayError.scopeMismatch }
    let refresh = token.refreshToken ?? previous?.refreshToken
    if previous == nil, refresh?.isEmpty != false {
      throw GatewayError.authenticationRequired
    }
    let expiry = token.expiresIn.map { Date().addingTimeInterval($0) } ?? previous?.expiresAt
    return GatewayTokenStore(role: profile.role, accessToken: token.accessToken, refreshToken: refresh, expiresAt: expiry)
  }

  private var clientSecretForm: [String: String] {
    guard let secret = profile.clientSecret, !secret.isEmpty else { return [:] }
    return ["client_secret": secret]
  }

  private func formEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
  }
}
