import Foundation
import Testing
@testable import AppCore

@Test func driveTokenStoresAreRoleBoundAndPrivate() throws {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  let file = directory.appendingPathComponent("writer.json")
  let role = GatewayRole(service: .drive, accessMode: .write)
  try GatewayTokenStoreFile.write(GatewayTokenStore(role: role, accessToken: "redacted", refreshToken: "redacted", expiresAt: nil), to: file)
  #expect(try GatewayTokenStoreFile.read(from: file, role: role).scope == role.scope)
  let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
  #expect(permissions?.intValue == 0o600)
  try FileManager.default.removeItem(at: directory)
}

@Test func driveRejectsUnsafeCredentialIdentifiers() {
  #expect(throws: GatewayError.self) {
    try GatewayCredentialProfile(id: "../outside", role: GatewayRole(service: .drive, accessMode: .read), clientID: "client", tokenStoreURL: URL(fileURLWithPath: "/tmp/token.json"))
  }
}

@Test func driveResumableUploadSendsInitiationThenBinaryContent() throws {
  let input = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  try Data("content".utf8).write(to: input)
  defer { try? FileManager.default.removeItem(at: input) }
  let transport = UploadFixtureTransport()
  let runner = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .write), authorizer: TestAuthorizer(), transport: transport)
  let result = runner.run(arguments: ["files", "upload", "--input", input.path, "--max-bytes", "10"])
  #expect(result.exitCode == 0)
  #expect(transport.calls == 2)
  #expect(transport.secondBody == Data("content".utf8))
}

private struct TestAuthorizer: GatewayAuthorizing {
  func accessToken(for role: GatewayRole) throws -> String { "token" }
}

private final class UploadFixtureTransport: GatewayHTTPTransport, @unchecked Sendable {
  private(set) var calls = 0
  private(set) var secondBody: Data?

  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    calls += 1
    if calls == 1 {
      return GatewayHTTPResponse(statusCode: 200, data: Data(), requestID: "start", location: "https://www.googleapis.com/upload/session")
    }
    secondBody = body
    return GatewayHTTPResponse(statusCode: 200, data: Data("{\"id\":\"file\"}".utf8), requestID: "finish")
  }
}

@Test func driveRejectsUntrustedResumableSessionLocation() throws {
  let input = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  try Data("content".utf8).write(to: input)
  defer { try? FileManager.default.removeItem(at: input) }
  let runner = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .write), authorizer: TestAuthorizer(), transport: UntrustedUploadTransport())
  let result = runner.run(arguments: ["files", "upload", "--input", input.path, "--max-bytes", "10"])
  #expect(result.exitCode == 5)
}

@Test func driveDownloadUsesFilesGetMediaEndpoint() throws {
  let plan = try GatewayRequestBuilder.plan(
    role: GatewayRole(service: .drive, accessMode: .read),
    operation: "files download",
    options: ["file-id": ["file/id"]]
  )
  #expect(plan.path == "/drive/v3/files/file%2Fid")
  #expect(plan.query.contains { $0.0 == "alt" && $0.1 == "media" })
}

@Test func drivePageAllAggregatesBoundedPages() {
  let transport = PaginationFixtureTransport()
  let runner = GatewayCommandRunner(
    role: GatewayRole(service: .drive, accessMode: .read),
    authorizer: TestAuthorizer(),
    transport: transport
  )
  let result = runner.run(arguments: ["files", "list", "--page-all", "--max-pages", "3"])
  #expect(result.exitCode == 0)
  #expect(result.stdout.contains("\"pagesFetched\":2"))
  #expect(result.stdout.contains("second"))
  #expect(transport.calls == 2)
  #expect(transport.secondURL?.query?.contains("pageToken=next") == true)
}

@Test func driveMutationStopsWhenObservedStateIsStale() {
  let transport = StalePreflightTransport()
  let runner = GatewayCommandRunner(
    role: GatewayRole(service: .drive, accessMode: .write),
    authorizer: TestAuthorizer(),
    transport: transport
  )
  let result = runner.run(arguments: [
    "files", "rename", "--file-id", "file", "--confirm-file-id", "file",
    "--name", "new", "--expected-modified-time", "expected"
  ])
  #expect(result.exitCode == 3)
  #expect(result.stdout.contains("STALE_REMOTE_STATE"))
  #expect(transport.calls == 1)
}

private struct UntrustedUploadTransport: GatewayHTTPTransport {
  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    GatewayHTTPResponse(statusCode: 200, data: Data(), requestID: "start", location: "https://evil.invalid/session")
  }
}

private final class PaginationFixtureTransport: GatewayHTTPTransport, @unchecked Sendable {
  private(set) var calls = 0
  private(set) var secondURL: URL?

  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    calls += 1
    if calls == 1 {
      return GatewayHTTPResponse(
        statusCode: 200,
        data: Data("{\"files\":[{\"id\":\"first\"}],\"nextPageToken\":\"next\"}".utf8),
        requestID: "page-one"
      )
    }
    secondURL = url
    return GatewayHTTPResponse(statusCode: 200, data: Data("{\"files\":[{\"id\":\"second\"}]}".utf8), requestID: "page-two")
  }
}

private final class StalePreflightTransport: GatewayHTTPTransport, @unchecked Sendable {
  private(set) var calls = 0

  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    calls += 1
    return GatewayHTTPResponse(statusCode: 200, data: Data("{\"modifiedTime\":\"changed\"}".utf8), requestID: "preflight")
  }
}
