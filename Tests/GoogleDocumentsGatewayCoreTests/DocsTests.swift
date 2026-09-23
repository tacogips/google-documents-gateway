import Foundation
import Testing
@testable import GoogleDocumentsGatewayCore

@Test func docsAuthorizationURLUsesExactScopeAndPKCE() throws {
  let profile = try GatewayCredentialProfile(id: "docs-reader", role: GatewayRole(service: .docs, accessMode: .read), clientID: "client", tokenStoreURL: URL(fileURLWithPath: "/tmp/docs-token.json"))
  let url = try GatewayOAuthPKCE.authorizationURL(profile: profile, redirectURI: "http://127.0.0.1:1234/callback", state: "state", verifier: String(repeating: "a", count: 43))
  #expect(url.absoluteString.contains("documents.readonly"))
  #expect(url.absoluteString.contains("code_challenge_method=S256"))
}

@Test func docsCredentialLoaderReadsKinkoDesktopClientJSON() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let environment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_SECRET_JSON":
      "{\"installed\":{\"client_id\":\"desktop-client\",\"client_secret\":\"synthetic-secret\"}}",
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_PATH": "/tmp/google-documents-gateway-docs-reader.json"
  ]
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: environment)
  #expect(profile.id == "docs-reader")
  #expect(profile.clientID == "desktop-client")
  #expect(profile.clientSecret == "synthetic-secret")
}

@Test func docsCredentialLoaderDefaultsTokenStoreToXDGStateHome() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let environment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "desktop-client",
    "XDG_STATE_HOME": "/tmp/xdg-state"
  ]
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: environment)
  #expect(
    profile.tokenStoreURL.path
      == "/tmp/xdg-state/google-documents-gateway/credentials/docs-reader.json"
  )
}

@Test func docsCredentialLoaderDefaultsTokenStoreUnderLocalState() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let environment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "desktop-client"
  ]
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: environment)
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  #expect(
    profile.tokenStoreURL.path
      == "\(home)/.local/state/google-documents-gateway/credentials/docs-reader.json"
  )
}

@Test func docsCredentialLoaderIgnoresRelativeXDGRoots() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "desktop-client",
    "XDG_STATE_HOME": "relative-state",
    "XDG_CONFIG_HOME": "relative-config"
  ])
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  #expect(profile.tokenStoreURL.path == "\(home)/.local/state/google-documents-gateway/credentials/docs-reader.json")
  #expect(profile.legacyTokenStoreURL?.path == "\(home)/.config/google-documents-gateway/tokens/docs-reader.json")
}

@Test func docsCredentialLoaderHonorsCredentialDirOverPathDefaults() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let environment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "desktop-client",
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR": "/tmp/riela-credentials",
    "XDG_STATE_HOME": "/tmp/xdg-state"
  ]
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: environment)
  #expect(profile.tokenStoreURL.path == "/tmp/riela-credentials/docs-reader.json")
}

@Test func docsCredentialLoaderPrefersExactTokenStorePathOverCredentialDir() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let environment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "desktop-client",
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DIR": "/tmp/riela-credentials",
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_PATH": "/tmp/exact.json"
  ]
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: environment)
  #expect(profile.tokenStoreURL.path == "/tmp/exact.json")
}

@Test func docsMigrationNeverOverwritesAnExistingStateTokenOrUsesOverrides() throws {
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let stateHome = root.appendingPathComponent("state")
  let configHome = root.appendingPathComponent("config")
  let role = GatewayRole(service: .docs, accessMode: .read)
  let legacyURL = configHome.appendingPathComponent("google-documents-gateway/tokens/docs-reader.json")
  let stateURL = stateHome.appendingPathComponent("google-documents-gateway/credentials/docs-reader.json")
  try GatewayTokenStoreFile.write(GatewayTokenStore(role: role, accessToken: "legacy", refreshToken: "refresh", expiresAt: .distantFuture), to: legacyURL)
  try GatewayTokenStoreFile.write(GatewayTokenStore(role: role, accessToken: "state", refreshToken: "refresh", expiresAt: .distantFuture), to: stateURL)
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "desktop-client",
    "XDG_STATE_HOME": stateHome.path,
    "XDG_CONFIG_HOME": configHome.path
  ])
  #expect(try PersistedTokenAuthorizer(profile: profile).accessToken(for: role) == "state")
  #expect(try GatewayTokenStoreFile.read(from: stateURL, role: role).accessToken == "state")
  #expect(FileManager.default.fileExists(atPath: legacyURL.path))
  #expect(FileManager.default.fileExists(atPath: stateURL.path + ".migration-complete"))
  try GatewayTokenStoreFile.revoke(url: stateURL)
  #expect(throws: Error.self) { try PersistedTokenAuthorizer(profile: profile).accessToken(for: role) }

  let overrideURL = root.appendingPathComponent("explicit.json")
  let overridden = try GatewayCredentialProfileLoader.load(role: role, environment: [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "desktop-client",
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_PATH": overrideURL.path,
    "XDG_CONFIG_HOME": configHome.path
  ])
  #expect(overridden.legacyTokenStoreURL == nil)
}

@Test func docsRejectsSymbolicLinkAndHardLinkTokenFiles() throws {
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let target = root.appendingPathComponent("target.json")
  try Data("{}".utf8).write(to: target)
  let symbolic = root.appendingPathComponent("symbolic.json")
  try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: target)
  let role = GatewayRole(service: .docs, accessMode: .read)
  #expect(throws: Error.self) { try GatewayTokenStoreFile.read(from: symbolic, role: role) }

  let linked = root.appendingPathComponent("linked.json")
  try FileManager.default.linkItem(at: target, to: linked)
  #expect(throws: Error.self) { try GatewayTokenStoreFile.read(from: linked, role: role) }
}

@Test func docsMigrationRejectsStateAncestorSymlink() throws {
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let state = root.appendingPathComponent("state")
  let config = root.appendingPathComponent("config")
  let outside = root.appendingPathComponent("outside")
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("google-documents-gateway"), withDestinationURL: outside)
  let role = GatewayRole(service: .docs, accessMode: .read)
  let legacy = config.appendingPathComponent("google-documents-gateway/tokens/docs-reader.json")
  try GatewayTokenStoreFile.write(GatewayTokenStore(role: role, accessToken: "legacy", refreshToken: "refresh", expiresAt: .distantFuture), to: legacy)
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "desktop-client",
    "XDG_STATE_HOME": state.path, "XDG_CONFIG_HOME": config.path
  ])
  #expect(throws: Error.self) { try PersistedTokenAuthorizer(profile: profile).accessToken(for: role) }
  #expect((try? FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty) == true)
}

@Test func docsCredentialLoaderAndAuthorizerReadTokenStoreJSON() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let tokenStore = GatewayTokenStore(
    role: role,
    accessToken: "environment-access",
    refreshToken: "environment-refresh",
    expiresAt: Date.distantFuture
  )
  let tokenJSON = String(data: try JSONEncoder().encode(tokenStore), encoding: .utf8) ?? ""
  let environment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "desktop-client",
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON": tokenJSON
  ]
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: environment)
  #expect(profile.tokenStoreJSON == tokenJSON)
  #expect(try PersistedTokenAuthorizer(profile: profile).accessToken(for: role) == "environment-access")
}

@Test func docsRefreshPreservesExistingRefreshTokenWhenGoogleOmitsIt() throws {
  let role = GatewayRole(service: .docs, accessMode: .write)
  let profile = try GatewayCredentialProfile(id: "docs-writer", role: role, clientID: "client", tokenStoreURL: URL(fileURLWithPath: "/tmp/docs-token.json"))
  let client = GatewayOAuthClient(profile: profile, transport: OAuthFixtureTransport())
  let previous = GatewayTokenStore(role: role, accessToken: "old", refreshToken: "refresh", expiresAt: Date.distantPast)
  let refreshed = try client.refresh(previous)
  #expect(refreshed.accessToken == "new")
  #expect(refreshed.refreshToken == "refresh")
}

@Test func docsInitialExchangeRecordsRequestedScopeWhenGoogleOmitsScope() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let profile = try GatewayCredentialProfile(id: "docs-reader", role: role, clientID: "client", tokenStoreURL: URL(fileURLWithPath: "/tmp/docs-token.json"))
  let client = GatewayOAuthClient(profile: profile, transport: InitialExchangeFixtureTransport())
  let store = try client.exchangeAuthorizationCode("code", redirectURI: "http://127.0.0.1:1234/callback", verifier: String(repeating: "a", count: 43))
  #expect(store.scope == role.scope)
}

@Test func docsLoginRejectsSensitiveCallbackValuesFromArguments() throws {
  let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let profile = try GatewayCredentialProfile(id: "docs-write", role: GatewayRole(service: .docs, accessMode: .write), clientID: "client", tokenStoreURL: root.appendingPathComponent("token.json"))
  let runner = GatewayCommandRunner(role: profile.role, transport: InitialExchangeFixtureTransport(), credentialProfile: profile)
  let result = runner.run(arguments: ["auth", "login", "--authorization-code", "code", "--redirect-uri", "http://127.0.0.1:1234/callback", "--pkce-verifier", String(repeating: "a", count: 43)])
  #expect(result.exitCode == 2)
  #expect(!result.stdout.contains("new"))
}

@Test func docsLoginRejectsInvalidOpenBrowserValue() throws {
  let profile = try GatewayCredentialProfile(id: "docs-writer", role: GatewayRole(service: .docs, accessMode: .write), clientID: "client", tokenStoreURL: URL(fileURLWithPath: "/tmp/docs-token.json"))
  let runner = GatewayCommandRunner(role: profile.role, transport: InitialExchangeFixtureTransport(), credentialProfile: profile)
  let result = runner.run(arguments: ["auth", "login", "--open-browser", "sometimes"])
  #expect(result.exitCode == 2)
  #expect(result.stdout.contains("--open-browser must be true or false"))
}

@Test func docsOAuthPresenterCanReportURLForManualOpening() throws {
  let probe = AuthorizationPresenterProbe()
  let presenter = GatewayAuthorizationPresenter(
    browserOpener: { url in probe.recordOpened(url); return true },
    manualReporter: { probe.recordReported($0) }
  )
  let url = try #require(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=test"))

  try presenter.present(url, openBrowser: false)

  #expect(probe.openedURL == nil)
  #expect(probe.reportedURL == url)
}

@Test func docsOAuthPresenterOpensBrowserByDefault() throws {
  let probe = AuthorizationPresenterProbe()
  let presenter = GatewayAuthorizationPresenter(
    browserOpener: { url in probe.recordOpened(url); return true },
    manualReporter: { probe.recordReported($0) }
  )
  let url = try #require(URL(string: "https://accounts.google.com/o/oauth2/v2/auth?client_id=test"))

  try presenter.present(url, openBrowser: true)

  #expect(probe.openedURL == url)
  #expect(probe.reportedURL == nil)
}

@Test func docsInitialExchangeRequiresRefreshToken() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let profile = try GatewayCredentialProfile(id: "docs-reader", role: role, clientID: "client", tokenStoreURL: URL(fileURLWithPath: "/tmp/docs-token.json"))
  let client = GatewayOAuthClient(profile: profile, transport: OAuthFixtureTransport())
  #expect(throws: GatewayError.self) {
    try client.exchangeAuthorizationCode("code", redirectURI: "http://127.0.0.1:1234/callback", verifier: String(repeating: "a", count: 43))
  }
}

private struct OAuthFixtureTransport: GatewayHTTPTransport {
  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    GatewayHTTPResponse(statusCode: 200, data: Data("{\"access_token\":\"new\",\"scope\":\"https://www.googleapis.com/auth/documents\",\"expires_in\":3600}".utf8), requestID: nil)
  }
}

private struct InitialExchangeFixtureTransport: GatewayHTTPTransport {
  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    GatewayHTTPResponse(statusCode: 200, data: Data("{\"access_token\":\"new\",\"refresh_token\":\"refresh\",\"expires_in\":3600}".utf8), requestID: nil)
  }
}

private final class AuthorizationPresenterProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedOpenedURL: URL?
  private var storedReportedURL: URL?

  var openedURL: URL? {
    lock.lock()
    defer { lock.unlock() }
    return storedOpenedURL
  }

  var reportedURL: URL? {
    lock.lock()
    defer { lock.unlock() }
    return storedReportedURL
  }

  func recordOpened(_ url: URL) {
    lock.lock()
    storedOpenedURL = url
    lock.unlock()
  }

  func recordReported(_ url: URL) {
    lock.lock()
    storedReportedURL = url
    lock.unlock()
  }
}
