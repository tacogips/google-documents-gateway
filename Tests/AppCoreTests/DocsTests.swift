import Foundation
import Testing
@testable import AppCore

@Test func docsAuthorizationURLUsesExactScopeAndPKCE() throws {
  let profile = try GatewayCredentialProfile(id: "docs-reader", role: GatewayRole(service: .docs, accessMode: .read), clientID: "client", tokenStoreURL: URL(fileURLWithPath: "/tmp/docs-token.json"))
  let url = try GatewayOAuthPKCE.authorizationURL(profile: profile, redirectURI: "http://127.0.0.1:1234/callback", state: "state", verifier: String(repeating: "a", count: 43))
  #expect(url.absoluteString.contains("documents.readonly"))
  #expect(url.absoluteString.contains("code_challenge_method=S256"))
}

@Test func docsCredentialLoaderReadsKinkoDesktopClientJSON() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let environment = [
    "DOCUMENT_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_SECRET_JSON":
      "{\"installed\":{\"client_id\":\"desktop-client\",\"client_secret\":\"synthetic-secret\"}}",
    "DOCUMENT_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_PATH": "/tmp/document-gateway-docs-reader.json"
  ]
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: environment)
  #expect(profile.id == "docs-reader")
  #expect(profile.clientID == "desktop-client")
  #expect(profile.clientSecret == "synthetic-secret")
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
    "DOCUMENT_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "desktop-client",
    "DOCUMENT_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON": tokenJSON
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
