import Foundation
import Testing
@testable import GoogleDocumentsGatewayCore

@Test func allDocumentRolesAcceptProductAccessTokensWithoutClients() throws {
  for service in GatewayService.allCases {
    for mode in GatewayAccessMode.allCases {
      let role = GatewayRole(service: service, accessMode: mode)
      let key = "GOOGLE_\(service.rawValue.uppercased())_GATEWAY_ACCESS_TOKEN"
      let profile = try GatewayCredentialProfileLoader.load(role: role, environment: [key: "external-token"])
      #expect(profile.clientID.isEmpty)
      #expect(try PersistedTokenAuthorizer(profile: profile, transport: CanonicalCredentialTransport()).accessToken(for: role) == "external-token")
      #expect(profile.tokenStoreJSON != nil)
      #expect(throws: GatewayError.self) {
        _ = try GatewayOAuthPKCE.authorizationURL(profile: profile, redirectURI: "http://127.0.0.1:12345/callback",
                                                state: "state", verifier: String(repeating: "v", count: 64))
      }
    }
  }
}

@Test func productTokensDoNotCrossDocumentServices() throws {
  let docs = GatewayRole(service: .docs, accessMode: .read)
  #expect(throws: GatewayError.self) {
    _ = try GatewayCredentialProfileLoader.load(role: docs, environment: isolatedCredentialTestEnvironment().merging(["GOOGLE_DRIVE_GATEWAY_ACCESS_TOKEN": "drive-token"]) { _, value in value })
  }
}

@Test func canonicalAndLegacyDocumentAliasesRemainCompatible() throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let legacy = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_SECRET_JSON"
  let canonical = "GOOGLE_DOCS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_JSON"
  let json = #"{"installed":{"client_id":"desktop-client"}}"#
  for env in [[legacy: json], [canonical: json], [legacy: json, canonical: json]] {
    #expect(try GatewayCredentialProfileLoader.load(role: role, environment: env).clientID == "desktop-client")
  }
  #expect(throws: GatewayError.self) {
    _ = try GatewayCredentialProfileLoader.load(role: role, environment: [legacy: "legacy-secret", canonical: "canonical-secret"])
  }
}

@Test func tokenStoreJSONWorksWithoutApplicationAndStillRejectsWrongRoles() throws {
  let role = GatewayRole(service: .sheets, accessMode: .read)
  let store = GatewayTokenStore(role: role, accessToken: "external-token", refreshToken: nil, expiresAt: nil)
  let json = try #require(String(data: JSONEncoder().encode(store), encoding: .utf8))
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: ["GOOGLE_SHEETS_GATEWAY_TOKEN_STORE_JSON": json])
  #expect(try PersistedTokenAuthorizer(profile: profile).accessToken(for: role) == "external-token")
  let wrongRole = GatewayRole(service: .sheets, accessMode: .write)
  let wrong = try GatewayCredentialProfileLoader.load(role: wrongRole, environment: ["GOOGLE_SHEETS_GATEWAY_TOKEN_STORE_JSON": json])
  #expect(throws: GatewayError.self) { _ = try PersistedTokenAuthorizer(profile: wrong).accessToken(for: wrongRole) }
}

@Test func canonicalDocumentRequestUsesExternalTokenWithoutLoginOrPersistence() {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let runner = GatewayCommandRunner(role: role, transport: CanonicalCredentialTransport(),
                                    environment: ["GOOGLE_DOCS_GATEWAY_ACCESS_TOKEN": "external-token"])
  let result = runner.run(arguments: ["document", "get", "--document-id", "external-doc"])
  #expect(result.exitCode == 0)
  #expect(result.stdout.contains("external-doc"))
  #expect(!result.stdout.contains("external-token"))
}

@Test func canonicalDocumentSDKTokenOnlyProfileKeepsCallScopedFileBoundary() throws {
  let role = GatewayRole(service: .drive, accessMode: .read)
  let profile = try GatewaySDKCredentialProfileLoader.load(role: role,
    environment: ["GOOGLE_DRIVE_GATEWAY_ACCESS_TOKEN": "external-token"], cancellation: GatewaySDKCancellation())
  #expect(profile.clientID.isEmpty)
  #expect(profile.tokenStoreURL.path == "/dev/null")
  #expect(try GatewaySDKPersistedAuthorizer(profile: profile, transport: CanonicalCredentialTransport(),
                                          cancellation: GatewaySDKCancellation(), decoder: .live).accessToken(for: role) == "external-token")
  #expect(throws: GatewayError.self) {
    _ = try GatewaySDKCredentialProfileLoader.load(role: role,
      environment: ["GOOGLE_DRIVE_GATEWAY_TOKEN_STORE_PATH": "/tmp/untrusted-token.json"], cancellation: GatewaySDKCancellation())
  }
}

@Test func documentTokenFileDoesNotRequireClientAndExpiredStoreStopsBeforeNetwork() throws {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let path = root.appendingPathComponent("token.json")
  let role = GatewayRole(service: .drive, accessMode: .read)
  let store = GatewayTokenStore(role: role, accessToken: "external-token", refreshToken: nil, expiresAt: nil)
  try GatewayTokenStoreFile.write(store, to: path)
  let profile = try GatewayCredentialProfileLoader.load(role: role, environment: ["GOOGLE_DRIVE_GATEWAY_TOKEN_STORE_PATH": path.path])
  #expect(profile.clientID.isEmpty)
  #expect(try PersistedTokenAuthorizer(profile: profile).accessToken(for: role) == "external-token")
  try GatewayTokenStoreFile.write(.init(role: role, accessToken: "expired-token", refreshToken: "refresh-token", expiresAt: .distantPast), to: path)
  #expect(throws: GatewayError.self) {
    _ = try PersistedTokenAuthorizer(profile: profile, transport: CanonicalCredentialTransport()).accessToken(for: role)
  }
}

private struct CanonicalCredentialTransport: GatewayHTTPTransport {
  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    #expect(headers["Authorization"] == "Bearer external-token")
    #expect(url.host != "oauth2.googleapis.com")
    return GatewayHTTPResponse(statusCode: 200, data: Data(#"{"documentId":"external-doc"}"#.utf8), requestID: nil)
  }
}

@Test func documentProfileSourcesReplaceProductDefaultsAcrossInputTypes() throws {
  for service in GatewayService.allCases {
    for mode in GatewayAccessMode.allCases {
      let role = GatewayRole(service: service, accessMode: mode)
      let product = "GOOGLE_\(service.rawValue.uppercased())_GATEWAY_"
      let id = "work"
      let selected = try gatewayCredentialEnvironment(role: role, id: id, source: [
        product + "TOKEN_STORE_PATH": "/unused/global-token.json",
        product + "CREDENTIAL_WORK_ACCESS_TOKEN": "work-token",
        product + "OAUTH_CLIENT_PATH": "/unused/global-client.json",
        product + "CREDENTIAL_WORK_OAUTH_CLIENT_JSON": "inline-application"
      ])
      #expect(selected["GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_WORK_TOKEN_STORE_PATH"] == nil)
      #expect(selected["GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_WORK_OAUTH_CLIENT_SECRET_PATH"] == nil)
      #expect(selected["GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_WORK_OAUTH_CLIENT_SECRET_JSON"] == "inline-application")
      let store = try JSONDecoder().decode(GatewayTokenStore.self, from: Data(try #require(selected["GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_WORK_TOKEN_STORE_JSON"]).utf8))
      #expect(store.accessToken == "work-token")
    }
  }
}
