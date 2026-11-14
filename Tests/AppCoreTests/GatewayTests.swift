import Foundation
import Testing
@testable import AppCore

@Test func rolesUseExactLeastPrivilegeScopes() {
  #expect(GatewayRole(service: .docs, accessMode: .read).scope == "https://www.googleapis.com/auth/documents.readonly")
  #expect(GatewayRole(service: .sheets, accessMode: .write).scope == "https://www.googleapis.com/auth/spreadsheets")
  #expect(GatewayRole(service: .drive, accessMode: .write).scope == "https://www.googleapis.com/auth/drive.file")
}

@Test func readersRejectMutationsBeforeAuthentication() {
  let result = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .read)).run(arguments: ["document", "create", "--json", "{\"title\":\"x\"}"])
  #expect(result.exitCode == 2)
  #expect(result.stdout.contains("FORBIDDEN_COMMAND"))
  #expect(!result.stdout.contains("AUTH_REQUIRED"))
}

@Test func sheetsClearNeedsExactConfirmationUnlessDryRun() {
  let runner = GatewayCommandRunner(role: GatewayRole(service: .sheets, accessMode: .write))
  let rejected = runner.run(arguments: ["values", "clear", "--spreadsheet-id", "one", "--range", "Sheet1!A1", "--confirm-range", "Sheet1!B1"])
  #expect(rejected.exitCode == 2)
  let dryRun = runner.run(arguments: ["values", "clear", "--spreadsheet-id", "one", "--range", "Sheet1!A1", "--dry-run"])
  #expect(dryRun.exitCode == 0)
  #expect(dryRun.stdout.contains("transportCalled"))
}

@Test func docsGetDefaultsToTabsContent() throws {
  let plan = try GatewayRequestBuilder.plan(
    role: GatewayRole(service: .docs, accessMode: .read),
    operation: "document get",
    options: ["document-id": ["document id"]]
  )
  #expect(plan.method == "GET")
  #expect(plan.path == "/v1/documents/document%20id")
  #expect(plan.query.contains { $0.0 == "includeTabsContent" && $0.1 == "true" })
}

@Test func driveMutationsRequireExactFileConfirmation() {
  let runner = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .write))
  let result = runner.run(arguments: ["files", "rename", "--file-id", "a", "--name", "new", "--expected-modified-time", "2026-08-13T00:00:00Z", "--confirm-file-id", "b", "--dry-run"])
  #expect(result.exitCode == 2)
  #expect(result.stdout.contains("INVALID_ARGUMENT"))
}

@Test func driveListAndPermissionCreateHaveCorrectLocalRequirements() {
  let reader = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .read))
  #expect(reader.run(arguments: ["files", "list", "--dry-run"]).exitCode == 0)
  let writer = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .write))
  let result = writer.run(arguments: ["permissions", "create", "--file-id", "f", "--type", "user", "--role", "reader", "--email", "user@example.invalid", "--dry-run"])
  #expect(result.exitCode == 0)
}

@Test func dryRunValidatesJSONAndInputFilesBeforeSucceeding() {
  let docs = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .write))
  #expect(docs.run(arguments: ["document", "create", "--json", "not-json", "--dry-run"]).exitCode == 2)
  let sheets = GatewayCommandRunner(role: GatewayRole(service: .sheets, accessMode: .write))
  #expect(sheets.run(arguments: ["values", "append", "--spreadsheet-id", "s", "--range", "A1", "--input-file", "/missing/input.json", "--dry-run"]).exitCode == 2)
}

@Test func authorizedCallsUseInjectedTransportAndPreserveProviderJSON() {
  let transport = FixtureTransport()
  let runner = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .read), authorizer: FixtureAuthorizer(), transport: transport)
  let result = runner.run(arguments: ["document", "get", "--document-id", "d"])
  #expect(result.exitCode == 0)
  #expect(result.stdout.contains("unmodeledField"))
  #expect(transport.calls == 1)
}

@Test func permissionEscalationRequiresExplicitAcknowledgement() {
  let runner = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .write))
  let rejected = runner.run(arguments: ["permissions", "create", "--file-id", "f", "--type", "anyone", "--role", "reader", "--dry-run"])
  #expect(rejected.exitCode == 2)
  let allowed = runner.run(arguments: ["permissions", "create", "--file-id", "f", "--type", "anyone", "--role", "reader", "--acknowledge-broad-access", "--dry-run"])
  #expect(allowed.exitCode == 0)
}

@Test func defaultAuthorizerDoesNotUseEnvironmentAccessToken() {
  let runner = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .read))
  let result = runner.run(arguments: ["document", "get", "--document-id", "d"])
  #expect(result.exitCode == 4)
  #expect(result.stdout.contains("AUTH_REQUIRED"))
}

private struct FixtureAuthorizer: GatewayAuthorizing {
  func accessToken(for role: GatewayRole) throws -> String { "fixture-token" }
}

private final class FixtureTransport: GatewayHTTPTransport, @unchecked Sendable {
  private(set) var calls = 0

  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    calls += 1
    return GatewayHTTPResponse(statusCode: 200, data: Data("{\"documentId\":\"d\",\"unmodeledField\":true}".utf8), requestID: "fixture")
  }
}
