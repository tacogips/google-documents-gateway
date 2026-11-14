import CryptoKit
import Foundation

public struct GatewayCredentialProfile: Sendable, Equatable {
  public let id: String
  public let role: GatewayRole
  public let clientID: String
  public let clientSecret: String?
  public let tokenStoreURL: URL
  public let tokenStoreJSON: String?

  public init(
    id: String,
    role: GatewayRole,
    clientID: String,
    clientSecret: String? = nil,
    tokenStoreURL: URL,
    tokenStoreJSON: String? = nil
  ) throws {
    try GatewayCredentialProfile.validateID(id)
    guard
          !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GatewayError.invalidArgument("Credential ID and OAuth client ID are required")
    }
    self.id = id
    self.role = role
    self.clientID = clientID
    self.clientSecret = clientSecret
    self.tokenStoreURL = tokenStoreURL
    self.tokenStoreJSON = tokenStoreJSON
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
    let suffix = id.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    let pathKey = "DOCUMENT_GATEWAY_CREDENTIAL_\(suffix)_TOKEN_STORE_PATH"
    let clientKey = "DOCUMENT_GATEWAY_CREDENTIAL_\(suffix)_OAUTH_CLIENT_ID"
    let secretJSONKey = "DOCUMENT_GATEWAY_CREDENTIAL_\(suffix)_OAUTH_CLIENT_SECRET_JSON"
    let secretPathKey = "DOCUMENT_GATEWAY_CREDENTIAL_\(suffix)_OAUTH_CLIENT_SECRET_PATH"
    let tokenJSONKey = "DOCUMENT_GATEWAY_CREDENTIAL_\(suffix)_TOKEN_STORE_JSON"
    let tokenPath = environment[pathKey] ?? defaultTokenStoreURL(id: id).path
    let installedClient = try loadInstalledClient(json: environment[secretJSONKey], path: environment[secretPathKey])
    guard let clientID = installedClient?.clientID ?? environment[clientKey], !clientID.isEmpty else {
      throw GatewayError.authenticationRequired
    }
    return try GatewayCredentialProfile(
      id: id,
      role: role,
      clientID: clientID,
      clientSecret: installedClient?.clientSecret,
      tokenStoreURL: URL(fileURLWithPath: tokenPath),
      tokenStoreJSON: nonBlank(environment[tokenJSONKey])
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

  private static func defaultTokenStoreURL(id: String) -> URL {
    let root = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config").path
    return URL(fileURLWithPath: root).appendingPathComponent("document-gateway/tokens/\(id).json")
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
    try decode(Data(contentsOf: url), role: role)
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
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(store)
    try data.write(to: url, options: [.atomic])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  public static func revoke(url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }
}

public enum GatewayOAuthPKCE {
  public static func authorizationURL(profile: GatewayCredentialProfile, redirectURI: String, state: String, verifier: String) throws -> URL {
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
    guard let refreshToken = previous.refreshToken, !refreshToken.isEmpty else {
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
