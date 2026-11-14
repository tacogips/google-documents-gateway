import Darwin
import Foundation
import Testing
@testable import GoogleDocumentsGatewayCore

@Test func defaultTokenMigrationCopiesLegacyPrivatelyAndIsIdempotent() throws {
  let fixture = try MigrationFixture()
  defer { fixture.clean() }
  try GatewayTokenStoreFile.write(fixture.token, to: fixture.legacy)
  let profile = try fixture.profile()
  try GatewayTokenStoreFile.migrateLegacyStoreIfNeeded(profile: profile)
  #expect(try GatewayTokenStoreFile.read(from: profile.tokenStoreURL, role: fixture.role) == fixture.token)
  #expect(FileManager.default.fileExists(atPath: fixture.legacy.path))
  let attributes = try FileManager.default.attributesOfItem(atPath: profile.tokenStoreURL.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  let directoryAttributes = try FileManager.default.attributesOfItem(atPath: profile.tokenStoreURL.deletingLastPathComponent().path)
  #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
  try GatewayTokenStoreFile.completeLegacyMigration(profile: profile)
  try GatewayTokenStoreFile.completeLegacyMigration(profile: profile)
  try GatewayTokenStoreFile.migrateLegacyStoreIfNeeded(profile: profile)
}

@Test func actualRevokeCannotResurrectLegacyIncludingMalformedTokens() throws {
  for invalidLegacy in [false, true] {
    let fixture = try MigrationFixture()
    defer { fixture.clean() }
    let profile = try fixture.profile()
    try GatewayTokenStoreFile.write(fixture.token, to: fixture.legacy)
    if invalidLegacy {
      try Data("invalid-token".utf8).write(to: fixture.legacy)
    } else {
      try GatewayTokenStoreFile.write(fixture.token, to: profile.tokenStoreURL)
    }
    let runner = GatewayCommandRunner(role: fixture.role, transport: MigrationTransport(), environment: fixture.environment)
    let result = runner.run(arguments: ["auth", "revoke", "--confirm-credential", "docs-reader"])
    #expect(result.exitCode == 0)
    #expect(!FileManager.default.fileExists(atPath: profile.tokenStoreURL.path))
    try GatewayTokenStoreFile.migrateLegacyStoreIfNeeded(profile: fixture.profile())
    #expect(!FileManager.default.fileExists(atPath: profile.tokenStoreURL.path))
    #expect(FileManager.default.fileExists(atPath: fixture.legacy.path))
  }
}

@Test func missingDefaultTokenRevokeIsIdempotentAndFIFOIsRejected() throws {
  let fixture = try MigrationFixture()
  defer { fixture.clean() }
  let profile = try fixture.profile()
  try GatewayTokenStoreFile.revoke(url: profile.tokenStoreURL)
  #expect(!FileManager.default.fileExists(atPath: profile.tokenStoreURL.deletingLastPathComponent().path))
  try FileManager.default.createDirectory(at: fixture.legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
  guard mkfifo(fixture.legacy.path, 0o600) == 0 else { throw POSIXError(.EIO) }
  #expect(throws: Error.self) { try GatewayTokenStoreFile.migrateLegacyStoreIfNeeded(profile: profile) }
}

private struct MigrationFixture {
  let root: URL
  let role = GatewayRole(service: .docs, accessMode: .read)
  var legacy: URL { root.appendingPathComponent("config/google-documents-gateway/tokens/docs-reader.json") }
  var token: GatewayTokenStore { GatewayTokenStore(role: role, accessToken: "test-token", refreshToken: "test-refresh", expiresAt: .distantFuture) }
  var environment: [String: String] {
    ["XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
     "XDG_STATE_HOME": root.appendingPathComponent("state").path,
     "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "test-client"]
  }
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  func profile() throws -> GatewayCredentialProfile { try GatewayCredentialProfileLoader.load(role: role, environment: environment) }
  func clean() { try? FileManager.default.removeItem(at: root) }
}

private struct MigrationTransport: GatewayHTTPTransport {
  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    GatewayHTTPResponse(statusCode: 200, data: Data("{}".utf8), requestID: nil)
  }
}
