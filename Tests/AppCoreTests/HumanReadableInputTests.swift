import Foundation
import Testing
@testable import AppCore

@Test func docsReadableSourcesGenerateEquivalentProviderBodies() throws {
  let generatedCreate = try #require(try GatewayInputValidator.body(
    for: GatewayRole(service: .docs, accessMode: .write),
    command: "document create",
    options: ["title": [" Project notes "]]
  ))
  let rawCreate = try #require(try GatewayInputValidator.body(
    for: GatewayRole(service: .docs, accessMode: .write),
    command: "document create",
    options: ["json": ["{\"title\":\" Project notes \"}"]]
  ))
  #expect(try jsonObject(generatedCreate) as? NSDictionary == jsonObject(rawCreate) as? NSDictionary)

  let text = "First line\nSecond line"
  let generatedText = try #require(try GatewayInputValidator.body(
    for: GatewayRole(service: .docs, accessMode: .write),
    command: "document batch-update",
    options: ["text": [text]]
  ))
  let rawTextFile = try temporaryFile(Data("{\"requests\":[{\"insertText\":{\"endOfSegmentLocation\":{\"segmentId\":\"\"},\"text\":\"First line\\nSecond line\"}}]}".utf8))
  defer { try? FileManager.default.removeItem(at: rawTextFile) }
  let rawText = try #require(try GatewayInputValidator.body(
    for: GatewayRole(service: .docs, accessMode: .write),
    command: "document batch-update",
    options: ["json-file": [rawTextFile.path]]
  ))
  #expect(try jsonObject(generatedText) as? NSDictionary == jsonObject(rawText) as? NSDictionary)
}

@Test func docsReadableSourcesAreExclusiveAndRedactedInDryRun() {
  let probe = DryRunProbe()
  let runner = dryRunRunner(service: .docs, probe: probe)
  let duplicate = runner.run(arguments: ["document", "create", "--title", "one", "--title", "two", "--dry-run"])
  #expect(duplicate.exitCode == 2)
  let ambiguous = runner.run(arguments: ["document", "create", "--title", "one", "--json", "{\"title\":\"two\"}", "--dry-run"])
  #expect(ambiguous.exitCode == 2)
  let dryRun = runner.run(arguments: ["document", "batch-update", "--document-id", "document", "--text", "private", "--dry-run"])
  #expect(dryRun.exitCode == 0)
  #expect(dryRun.stdout.contains("\"bodyValuesRedacted\":true"))
  #expect(!dryRun.stdout.contains("private"))
  #expect(probe.authorizerCalls == 0)
  #expect(probe.transportCalls == 0)
}

@Test func sheetsReadableRowsPreserveStringsAndTypedJSON() throws {
  let stringBody = try #require(try GatewayInputValidator.body(
    for: GatewayRole(service: .sheets, accessMode: .write),
    command: "values update",
    options: ["spreadsheet-id": ["sheet"], "range": ["Sheet1!A1"], "values": ["a, b,"]]
  ))
  let stringObject = try #require(try jsonObject(stringBody) as? [String: Any])
  #expect(stringObject["range"] as? String == "Sheet1!A1")
  #expect(stringObject["majorDimension"] as? String == "ROWS")
  let stringRows = try #require(stringObject["values"] as? [[String]])
  #expect(stringRows == [["a", " b", ""]])

  let typedBody = try #require(try GatewayInputValidator.body(
    for: GatewayRole(service: .sheets, accessMode: .write),
    command: "values append",
    options: ["spreadsheet-id": ["sheet"], "range": ["Sheet1!A1"], "json-values": ["[[1,true,null],[\"x\"]]"], "major-dimension": ["COLUMNS"]]
  ))
  let typedObject = try #require(try jsonObject(typedBody) as? [String: Any])
  #expect(typedObject["majorDimension"] as? String == "COLUMNS")
  let rows = try #require(typedObject["values"] as? [[Any]])
  #expect(rows.count == 2)
  #expect((rows[0][0] as? NSNumber)?.intValue == 1)
  #expect((rows[0][1] as? NSNumber)?.boolValue == true)
  #expect(rows[0][2] is NSNull)

  let rawBody = try #require(try GatewayInputValidator.body(
    for: GatewayRole(service: .sheets, accessMode: .write),
    command: "values update",
    options: ["spreadsheet-id": ["sheet"], "range": ["Sheet1!A1"], "values": ["one,two"]]
  ))
  let rawFile = try temporaryFile(rawBody)
  defer { try? FileManager.default.removeItem(at: rawFile) }
  let compatibilityBody = try #require(try GatewayInputValidator.body(
    for: GatewayRole(service: .sheets, accessMode: .write),
    command: "values update",
    options: ["spreadsheet-id": ["sheet"], "range": ["Sheet1!A1"], "input-file": [rawFile.path]]
  ))
  let generatedObject = try jsonObject(rawBody) as? NSDictionary
  let compatibilityObject = try jsonObject(compatibilityBody) as? NSDictionary
  #expect(generatedObject == compatibilityObject)
}

@Test func sheetsReadableSourcesRejectAmbiguityAndNestedValues() throws {
  let probe = DryRunProbe()
  let runner = dryRunRunner(service: .sheets, probe: probe)
  let base = ["values", "update", "--spreadsheet-id", "sheet", "--range", "A1"]
  #expect(runner.run(arguments: base + ["--values", "one", "--input-file", "body.json", "--dry-run"]).exitCode == 2)
  #expect(runner.run(arguments: base + ["--values", "one", "--values", "two", "--dry-run"]).exitCode == 2)
  #expect(runner.run(arguments: base + ["--json-values", "[[[1]]]", "--dry-run"]).exitCode == 2)
  #expect(runner.run(arguments: base + ["--json-values", "[1e400]", "--dry-run"]).exitCode == 2)
  #expect(runner.run(arguments: base + ["--values", "one", "--major-dimension", "DIAGONAL", "--dry-run"]).exitCode == 2)
  let body = try temporaryFile(Data("{\"range\":\"A1\",\"majorDimension\":\"ROWS\",\"values\":[[\"one\"]]}".utf8))
  defer { try? FileManager.default.removeItem(at: body) }
  #expect(runner.run(arguments: base + ["--input-file", body.path, "--major-dimension", "ROWS", "--dry-run"]).exitCode == 2)
  let dryRun = runner.run(arguments: base + ["--values", "secret", "--dry-run"])
  #expect(dryRun.exitCode == 0)
  #expect(dryRun.stdout.contains("\"bodyValuesRedacted\":true"))
  #expect(!dryRun.stdout.contains("secret"))
  #expect(probe.authorizerCalls == 0)
  #expect(probe.transportCalls == 0)
}

@Test func driveUploadUsesOneValidatedMIMETypeForMetadataAndMedia() throws {
  let input = try temporaryFile(Data("content".utf8), pathExtension: "CSV")
  defer { try? FileManager.default.removeItem(at: input) }
  let transport = MetadataUploadTransport()
  let runner = GatewayCommandRunner(
    role: GatewayRole(service: .drive, accessMode: .write),
    authorizer: ReadableTestAuthorizer(),
    transport: transport
  )
  let result = runner.run(arguments: ["files", "upload", "--input", input.path, "--max-bytes", "10", "--parent-id", "parent"])
  #expect(result.exitCode == 0)
  #expect(transport.initialHeaders?["X-Upload-Content-Type"] == "text/csv")
  #expect(transport.chunkHeaders?["Content-Type"] == "text/csv")
  let metadata = try #require(transport.initialBody.flatMap { try? jsonObject($0) as? [String: Any] })
  #expect(metadata["name"] as? String == input.lastPathComponent)
  #expect(metadata["mimeType"] as? String == "text/csv")
  #expect(metadata["parents"] as? [String] == ["parent"])

  let overrideTransport = MetadataUploadTransport()
  let overrideRunner = GatewayCommandRunner(
    role: GatewayRole(service: .drive, accessMode: .write),
    authorizer: ReadableTestAuthorizer(),
    transport: overrideTransport
  )
  let overrideResult = overrideRunner.run(arguments: [
    "files", "upload", "--input", input.path, "--max-bytes", "10",
    "--name", "renamed.payload", "--mime-type", "application/x-example"
  ])
  #expect(overrideResult.exitCode == 0)
  #expect(overrideTransport.initialHeaders?["X-Upload-Content-Type"] == "application/x-example")
  #expect(overrideTransport.chunkHeaders?["Content-Type"] == "application/x-example")
  let overrideMetadata = try #require(overrideTransport.initialBody.flatMap { try? jsonObject($0) as? [String: Any] })
  #expect(overrideMetadata["name"] as? String == "renamed.payload")
  #expect(overrideMetadata["mimeType"] as? String == "application/x-example")
}

@Test func driveReadableMetadataRejectsUnsafeMIMEAndSupportsFolders() throws {
  let runner = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .write))
  let malformed = runner.run(arguments: ["files", "upload", "--input", "/tmp/file", "--max-bytes", "1", "--mime-type", "text/plain; charset=utf-8", "--dry-run"])
  #expect(malformed.exitCode == 2)
  let folder = try #require(try GatewayInputValidator.body(
    for: GatewayRole(service: .drive, accessMode: .write),
    command: "folders create",
    options: ["name": ["Folder"], "parent-id": ["parent"]]
  ))
  let object = try #require(try jsonObject(folder) as? [String: Any])
  #expect(object["parents"] as? [String] == ["parent"])
}

@Test func dryRunsRedactEveryReadableOrRawSourceWithoutProviderAccess() throws {
  let docsProbe = DryRunProbe()
  let sheetsProbe = DryRunProbe()
  let driveProbe = DryRunProbe()
  let docs = dryRunRunner(service: .docs, probe: docsProbe)
  let sheets = dryRunRunner(service: .sheets, probe: sheetsProbe)
  let drive = dryRunRunner(service: .drive, probe: driveProbe)
  let titleDryRun = docs.run(arguments: ["document", "create", "--title", "private-title", "--dry-run"])
  let textDryRun = docs.run(arguments: ["document", "batch-update", "--document-id", "document", "--text", "private-text", "--dry-run"])
  let rawDocsDryRun = docs.run(arguments: ["document", "create", "--json", "{\"title\":\"private-raw\"}", "--dry-run"])
  let valuesDryRun = sheets.run(arguments: ["values", "append", "--spreadsheet-id", "sheet", "--range", "A1", "--values", "private-values", "--dry-run"])
  let jsonValuesDryRun = sheets.run(arguments: ["values", "append", "--spreadsheet-id", "sheet", "--range", "A1", "--json-values", "[\"private-value\"]", "--dry-run"])
  let rawSheet = try temporaryFile(Data("{\"range\":\"A1\",\"majorDimension\":\"ROWS\",\"values\":[[\"private-raw\"]]}".utf8))
  defer { try? FileManager.default.removeItem(at: rawSheet) }
  let rawSheetsDryRun = sheets.run(arguments: ["values", "append", "--spreadsheet-id", "sheet", "--range", "A1", "--input-file", rawSheet.path, "--dry-run"])
  let uploadBytes = "private-upload-bytes"
  let uploadName = "private-upload-name"
  let uploadParent = "private-upload-parent"
  let uploadMIMEType = "application/x-private-upload"
  let uploadInput = try temporaryFile(Data(uploadBytes.utf8), pathExtension: "unknown")
  defer { try? FileManager.default.removeItem(at: uploadInput) }
  let uploadDryRun = drive.run(arguments: [
    "files", "upload", "--input", uploadInput.path, "--max-bytes", "1024",
    "--name", uploadName, "--parent-id", uploadParent, "--mime-type", uploadMIMEType, "--dry-run"
  ])
  let folderName = "private-folder-name"
  let folderParent = "private-folder-parent"
  let folderDryRun = drive.run(arguments: ["folders", "create", "--name", folderName, "--parent-id", folderParent, "--dry-run"])
  for result in [titleDryRun, textDryRun, rawDocsDryRun, valuesDryRun, jsonValuesDryRun, rawSheetsDryRun, uploadDryRun, folderDryRun] {
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("\"bodyValuesRedacted\":true"))
  }
  #expect(!titleDryRun.stdout.contains("private-title"))
  #expect(!textDryRun.stdout.contains("private-text"))
  #expect(!rawDocsDryRun.stdout.contains("private-raw"))
  #expect(!valuesDryRun.stdout.contains("private-values"))
  #expect(!jsonValuesDryRun.stdout.contains("private-value"))
  #expect(!rawSheetsDryRun.stdout.contains("private-raw"))
  for value in [uploadBytes, uploadName, uploadParent, uploadMIMEType, folderName, folderParent] {
    #expect(!uploadDryRun.stdout.contains(value))
    #expect(!folderDryRun.stdout.contains(value))
  }
  #expect(docsProbe.authorizerCalls == 0)
  #expect(docsProbe.transportCalls == 0)
  #expect(sheetsProbe.authorizerCalls == 0)
  #expect(sheetsProbe.transportCalls == 0)
  #expect(driveProbe.authorizerCalls == 0)
  #expect(driveProbe.transportCalls == 0)
  #expect((try? GatewayReadableInput.resolvedMIMEType(input: "/tmp/file.unknown", explicitType: nil)) == "application/octet-stream")
  #expect((try? GatewayReadableInput.driveUploadMetadata(["input": ["/tmp/input"], "name": ["bad\nname"]])) == nil)
  #expect((try? GatewayReadableInput.driveUploadMetadata(["input": ["/"]])) == nil)
}

@Test func writerHelpMakesReadableInputsDiscoverable() {
  let docs = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .write)).run(arguments: ["--help"])
  let sheets = GatewayCommandRunner(role: GatewayRole(service: .sheets, accessMode: .write)).run(arguments: ["--help"])
  let drive = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .write)).run(arguments: ["--help"])
  for flag in ["--title", "--text", "--json", "--json-file"] { #expect(docs.stdout.contains(flag)) }
  for flag in ["--values", "--json-values", "--major-dimension", "--input-file"] { #expect(sheets.stdout.contains(flag)) }
  for flag in ["--input", "--max-bytes", "--name", "--parent-id", "--mime-type"] { #expect(drive.stdout.contains(flag)) }
}

@Test func readableInputsRejectBoundaryAndMalformedCases() {
  let docs = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .write))
  let sheets = GatewayCommandRunner(role: GatewayRole(service: .sheets, accessMode: .write))
  let sheetBase = ["values", "update", "--spreadsheet-id", "sheet", "--range", "A1", "--json-values"]
  #expect(docs.run(arguments: ["document", "create", "--title", "   ", "--dry-run"]).exitCode == 2)
  #expect(docs.run(arguments: ["document", "batch-update", "--document-id", "document", "--text", "", "--dry-run"]).exitCode == 2)
  #expect(sheets.run(arguments: sheetBase + ["[]", "--dry-run"]).exitCode == 2)
  #expect(sheets.run(arguments: sheetBase + ["[[]]", "--dry-run"]).exitCode == 2)
  #expect(sheets.run(arguments: sheetBase + ["[\"one\",[\"two\"]]", "--dry-run"]).exitCode == 2)
  #expect(sheets.run(arguments: sheetBase + ["[{\"value\":1}]", "--dry-run"]).exitCode == 2)
}

@Test func readableInputsSupportEqualsSyntaxForLeadingHyphenValues() {
  let docs = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .write))
  let sheets = GatewayCommandRunner(role: GatewayRole(service: .sheets, accessMode: .write))
  #expect(docs.run(arguments: ["document", "create", "--title=--leading", "--dry-run"]).exitCode == 0)
  #expect(docs.run(arguments: ["document", "batch-update", "--document-id", "document", "--text=--leading", "--dry-run"]).exitCode == 0)
  #expect(sheets.run(arguments: ["values", "update", "--spreadsheet-id", "sheet", "--range", "A1", "--values=--leading", "--dry-run"]).exitCode == 0)
}

@Test func driveMIMETypeUsesASCIITokenSyntax() throws {
  let runner = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .write))
  let input = try temporaryFile(Data())
  defer { try? FileManager.default.removeItem(at: input) }
  let base = ["files", "upload", "--input", input.path, "--max-bytes", "1", "--dry-run"]
  #expect(runner.run(arguments: base + ["--mime-type", "tēxt/plain"]).exitCode == 2)
  #expect(runner.run(arguments: base + ["--mime-type", "application/x!$%&'*+-.^_`|~"]).exitCode == 0)
}

@Test func dryRunOnlyMarksActualRequestBodiesAsRedacted() {
  let reader = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .read))
  let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: output) }
  let result = reader.run(arguments: [
    "files", "export", "--file-id", "file", "--mime-type", "application/pdf",
    "--output", output.path, "--max-bytes", "1", "--dry-run"
  ])
  #expect(result.exitCode == 0)
  #expect(result.stdout.contains("\"bodyValuesRedacted\":false"))
}

@Test func generatedReadableBodiesRespectProviderSizeLimit() {
  let oversized = String(repeating: "x", count: GatewayInputValidator.maximumBodyBytes)
  let docs = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .write))
  let sheets = GatewayCommandRunner(role: GatewayRole(service: .sheets, accessMode: .write))
  #expect(docs.run(arguments: ["document", "create", "--title", oversized, "--dry-run"]).exitCode == 2)
  #expect(sheets.run(arguments: ["values", "update", "--spreadsheet-id", "sheet", "--range", "A1", "--values", oversized, "--dry-run"]).exitCode == 2)
}

private func jsonObject(_ data: Data) throws -> Any {
  try JSONSerialization.jsonObject(with: data)
}

private func temporaryFile(_ data: Data, pathExtension: String? = nil) throws -> URL {
  var file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  if let pathExtension { file.appendPathExtension(pathExtension) }
  try data.write(to: file)
  return file
}

private struct ReadableTestAuthorizer: GatewayAuthorizing {
  func accessToken(for role: GatewayRole) throws -> String { "token" }
}

private final class DryRunProbe: GatewayAuthorizing, GatewayHTTPTransport, @unchecked Sendable {
  private(set) var authorizerCalls = 0
  private(set) var transportCalls = 0

  func accessToken(for role: GatewayRole) throws -> String {
    authorizerCalls += 1
    throw GatewayError.transportFailure("Dry runs must not authorize")
  }

  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    transportCalls += 1
    throw GatewayError.transportFailure("Dry runs must not send transport")
  }
}

private func dryRunRunner(service: GatewayService, probe: DryRunProbe) -> GatewayCommandRunner {
  GatewayCommandRunner(
    role: GatewayRole(service: service, accessMode: .write),
    authorizer: probe,
    transport: probe
  )
}

private final class MetadataUploadTransport: GatewayHTTPTransport, @unchecked Sendable {
  private(set) var calls = 0
  private(set) var initialBody: Data?
  private(set) var initialHeaders: [String: String]?
  private(set) var chunkHeaders: [String: String]?

  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    calls += 1
    if calls == 1 {
      initialBody = body
      initialHeaders = headers
      return GatewayHTTPResponse(statusCode: 200, data: Data(), requestID: "start", location: "https://www.googleapis.com/upload/session")
    }
    chunkHeaders = headers
    return GatewayHTTPResponse(statusCode: 200, data: Data("{\"id\":\"file\"}".utf8), requestID: "finish")
  }
}
