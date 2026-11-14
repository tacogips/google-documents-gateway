import Foundation
import Testing
@testable import AppCore

@Test func docsBatchUpdateAcceptsEveryDiscoveredRequestVariant() throws {
  for request in GatewayCapabilityCatalog.docsBatchUpdateRequests {
    let data = try JSONSerialization.data(withJSONObject: ["requests": [[request: [:]]]])
    let file = try temporaryJSONFile(data)
    defer { try? FileManager.default.removeItem(at: file) }
    let body = try GatewayInputValidator.body(
      for: GatewayRole(service: .docs, accessMode: .write),
      command: "document batch-update",
      options: ["json-file": [file.path]]
    )
    #expect(body == data)
  }
}

@Test func docsBatchUpdateRejectsUnknownRequestVariant() throws {
  let file = try temporaryJSONFile(Data("{\"requests\":[{\"inventedRequest\":{}}]}".utf8))
  defer { try? FileManager.default.removeItem(at: file) }
  #expect(throws: GatewayError.self) {
    try GatewayInputValidator.body(
      for: GatewayRole(service: .docs, accessMode: .write),
      command: "document batch-update",
      options: ["json-file": [file.path]]
    )
  }
}

@Test func sheetsCatalogCoversAllStableSpreadsheetMethods() {
  let reader = GatewayCapabilityCatalog.commands(
    for: GatewayRole(service: .sheets, accessMode: .read)
  )
  let writer = GatewayCapabilityCatalog.commands(
    for: GatewayRole(service: .sheets, accessMode: .write)
  )
  #expect(reader.count == 7)
  #expect(writer.count == 10)
  #expect(reader.contains("spreadsheet get-by-data-filter"))
  #expect(reader.contains("developer-metadata search"))
  #expect(writer.contains("spreadsheet batch-update"))
  #expect(writer.contains("sheet copy-to"))
  #expect(writer.contains("values batch-update-by-data-filter"))
}

@Test func spreadsheetGetReturnsStructuralMetadataWithoutGridData() throws {
  let plan = try GatewayRequestBuilder.plan(
    role: GatewayRole(service: .sheets, accessMode: .read),
    operation: "spreadsheet get",
    options: ["spreadsheet-id": ["sheet"]]
  )
  #expect(plan.query.contains { $0.0 == "includeGridData" && $0.1 == "false" })
  #expect(!plan.query.contains { $0.0 == "fields" })
}

@Test func sheetsStructuralBatchUpdateAcceptsDiscoveredVariantsAndRejectsUnknownOnes() throws {
  let role = GatewayRole(service: .sheets, accessMode: .write)
  let accepted = try temporaryJSONFile(Data("{\"requests\":[{\"addSheet\":{}}]}".utf8))
  let rejected = try temporaryJSONFile(Data("{\"requests\":[{\"inventedRequest\":{}}]}".utf8))
  defer {
    try? FileManager.default.removeItem(at: accepted)
    try? FileManager.default.removeItem(at: rejected)
  }
  #expect(try GatewayInputValidator.body(
    for: role,
    command: "spreadsheet batch-update",
    options: ["input-file": [accepted.path]]
  ) != nil)
  #expect(throws: GatewayError.self) {
    try GatewayInputValidator.body(
      for: role,
      command: "spreadsheet batch-update",
      options: ["input-file": [rejected.path]]
    )
  }
}

@Test func sheetsBatchValuesPlacesValueInputOptionInRequestBody() throws {
  let file = try temporaryJSONFile(Data("{\"data\":[{\"range\":\"A1\",\"values\":[[1]]}]}".utf8))
  defer { try? FileManager.default.removeItem(at: file) }
  let options = [
    "spreadsheet-id": ["sheet"],
    "input-file": [file.path],
    "value-input-option": ["USER_ENTERED"]
  ]
  let plan = try GatewayRequestBuilder.plan(
    role: GatewayRole(service: .sheets, accessMode: .write),
    operation: "values batch-update",
    options: options
  )
  let encodedBody = try GatewayInputValidator.body(
    for: GatewayRole(service: .sheets, accessMode: .write),
    command: "values batch-update",
    options: options
  )
  let data = try #require(encodedBody)
  let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(plan.query.isEmpty)
  #expect(body["valueInputOption"] as? String == "USER_ENTERED")
}

@Test func driveReaderAndWriterExposeCuratedCoreResources() {
  let reader = GatewayCapabilityCatalog.commands(
    for: GatewayRole(service: .drive, accessMode: .read)
  )
  let writer = GatewayCapabilityCatalog.commands(
    for: GatewayRole(service: .drive, accessMode: .write)
  )
  #expect(reader.contains("about get"))
  #expect(reader.contains("changes list"))
  #expect(reader.contains("shared-drives list"))
  #expect(reader.contains("comments list"))
  #expect(reader.contains("replies list"))
  #expect(reader.contains("revisions download"))
  #expect(writer.contains("files copy"))
  #expect(writer.contains("files trash"))
  #expect(writer.contains("comments create"))
  #expect(writer.contains("replies update"))
  #expect(writer.contains("revisions update"))
  #expect(!writer.contains("files delete"))
}

@Test func requestBuilderEnforcesRoleBoundaryWhenCalledDirectly() {
  #expect(throws: GatewayError.self) {
    try GatewayRequestBuilder.plan(
      role: GatewayRole(service: .drive, accessMode: .read),
      operation: "files trash",
      options: ["file-id": ["file"]]
    )
  }
  #expect(throws: GatewayError.self) {
    try GatewayRequestBuilder.plan(
      role: GatewayRole(service: .sheets, accessMode: .write),
      operation: "values get",
      options: ["spreadsheet-id": ["sheet"], "range": ["A1"]]
    )
  }
}

@Test func everyCatalogCommandHasARequestPlan() throws {
  let options: [String: [String]] = [
    "document-id": ["document"],
    "spreadsheet-id": ["spreadsheet"],
    "destination-spreadsheet-id": ["destination"],
    "sheet-id": ["1"],
    "metadata-id": ["2"],
    "range": ["Sheet1!A1"],
    "file-id": ["file"],
    "permission-id": ["permission"],
    "comment-id": ["comment"],
    "reply-id": ["reply"],
    "revision-id": ["revision"],
    "drive-id": ["drive"],
    "page-token": ["token"],
    "mime-type": ["text/plain"],
    "add-parents": ["parent"]
  ]
  for service in GatewayService.allCases {
    for accessMode in GatewayAccessMode.allCases {
      let role = GatewayRole(service: service, accessMode: accessMode)
      for command in GatewayCapabilityCatalog.commands(for: role) {
        #expect(throws: Never.self) {
          try GatewayRequestBuilder.plan(role: role, operation: command, options: options)
        }
      }
    }
  }
}

@Test func driveCommentCreateDoesNotRequireExistingCommentID() {
  let runner = GatewayCommandRunner(
    role: GatewayRole(service: .drive, accessMode: .write),
    authorizer: CoverageAuthorizer(),
    transport: NoCallTransport()
  )
  let result = runner.run(arguments: [
    "comments", "create", "--file-id", "file", "--content", "hello", "--dry-run"
  ])
  #expect(result.exitCode == 0)
  #expect(result.stdout.contains("/comments"))
  #expect(result.stdout.contains("fields"))
}

@Test func driveNestedPageAllAggregatesTheCorrectCollection() {
  let transport = CommentPaginationTransport()
  let runner = GatewayCommandRunner(
    role: GatewayRole(service: .drive, accessMode: .read),
    authorizer: CoverageAuthorizer(),
    transport: transport
  )
  let result = runner.run(arguments: [
    "comments", "list", "--file-id", "file", "--page-all", "--max-pages", "2"
  ])
  #expect(result.exitCode == 0)
  #expect(result.stdout.contains("first"))
  #expect(result.stdout.contains("second"))
  #expect(result.stdout.contains("\"pagesFetched\":2"))
}

private func temporaryJSONFile(_ data: Data) throws -> URL {
  let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  try data.write(to: file)
  return file
}

private struct CoverageAuthorizer: GatewayAuthorizing {
  func accessToken(for role: GatewayRole) throws -> String { "token" }
}

private struct NoCallTransport: GatewayHTTPTransport {
  func send(
    url: URL,
    method: String,
    headers: [String: String],
    body: Data?
  ) throws -> GatewayHTTPResponse {
    throw GatewayError.transportFailure("Unexpected transport call")
  }
}

private final class CommentPaginationTransport: GatewayHTTPTransport, @unchecked Sendable {
  private var calls = 0

  func send(
    url: URL,
    method: String,
    headers: [String: String],
    body: Data?
  ) throws -> GatewayHTTPResponse {
    calls += 1
    if calls == 1 {
      return GatewayHTTPResponse(
        statusCode: 200,
        data: Data("{\"comments\":[{\"id\":\"first\"}],\"nextPageToken\":\"next\"}".utf8),
        requestID: nil
      )
    }
    #expect(url.query?.contains("pageToken=next") == true)
    return GatewayHTTPResponse(
      statusCode: 200,
      data: Data("{\"comments\":[{\"id\":\"second\"}]}".utf8),
      requestID: nil
    )
  }
}
