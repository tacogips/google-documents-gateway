import Darwin
import Foundation
import GatewaySDKKit
import Testing
@testable import GoogleDocumentsGatewayCore

@Test func sdkBoundsUnknownOperationRoutingInsideExecution() async {
  let limiter = GatewaySDKExecutionLimiter(limit: 1, startsSuspended: true)
  defer { limiter.resume() }
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .read), catalogFileSnapshotter: .live,
    executionPolicy: .init(timeout: 0.05), executionLimiter: limiter
  )
  let fabricatedOperation = "fabricated bounded operation"
  let bounded = await sdk.invoke(.init(operation: fabricatedOperation), environment: [:])
  #expect(bounded.exitCode == 5)
  #expect(bounded.errors.first?.code == "TRANSPORT_FAILURE")
  #expect(bounded.errors.first?.message == "SDK execution exceeded its deadline")
  limiter.resume()
  let unknown = await sdk.invoke(.init(operation: fabricatedOperation), environment: [:])
  #expect(unknown == GatewayEnvelope.failure(GatewaySDKError.unknownOperation(name: fabricatedOperation), exitCode: 2))
  let oversizedOperation = String(repeating: "x", count: 64 * 1024 + 1)
  let oversized = await sdk.invoke(.init(operation: oversizedOperation), environment: [:])
  let expectedOversized = GatewayEnvelope(
    errors: [.init(message: "The input exceeds the configured command size limit.", code: "INPUT_TOO_LARGE")],
    exitCode: 2,
    rawOutput: #"{"error":{"code":"INPUT_TOO_LARGE","message":"The input exceeds the configured command size limit."},"ok":false}"#
  )
  #expect(oversized == expectedOversized)
  #expect(!(oversized.errors.first?.message.contains(oversizedOperation) ?? true))
  #expect(!oversized.rawOutput.contains(oversizedOperation))
  #expect(oversized.rawOutput.utf8.count < 256)
}

@Test func sdkRejectsOutsideRootHardLinkedCatalogInputBeforeSnapshotCredentialOrTransport() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let outside = root.deletingLastPathComponent().appendingPathComponent("sdk-outside-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: outside) }
  try Data("secret".utf8).write(to: outside)
  let linkedInput = root.appendingPathComponent("linked-input")
  #expect(Darwin.link(outside.path, linkedInput.path) == 0)
  let snapshots = PreparationProbe(), authorizer = SDKFixtureAuthorizer(), transport = SDKFixtureTransport()
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .write), authorizer: authorizer, transport: transport,
    catalogFileSnapshotter: .init { _, variables in snapshots.enter(); return .init(variables: variables, paths: []) },
    fileAccessPolicy: .init(inputRoots: [root])
  )
  let result = await sdk.invoke(.init(operation: "files upload", variables: [
    "input": .string(linkedInput.path), "max-bytes": .int(64)
  ]), environment: [:])
  #expect(result.exitCode == 2)
  #expect(result.errors.first?.code == "INVALID_ARGUMENT")
  #expect(snapshots.entries == 0)
  #expect(authorizer.calls == 0)
  #expect(transport.calls == 0)
}

@Test func sdkRejectsStructuralRequestJSONFloodsBeforeFoundationDecoding() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("request.json")
  let decoder = GatewayFoundationDecodeProbe(), authorizer = SDKFixtureAuthorizer(), transport = SDKFixtureTransport()
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .write), authorizer: authorizer, transport: transport,
    catalogFileSnapshotter: .live, fileAccessPolicy: .init(inputRoots: [root]), requestJSONDecoder: decoder.decoder()
  )
  let wide = "{\"requests\":[" + Array(repeating: "null", count: 16 * 1024 + 1).joined(separator: ",") + "]}"
  let deep = "{\"requests\":" + String(repeating: "[", count: 128) + "null" + String(repeating: "]", count: 128) + "}"
  for payload in [wide, deep] {
    try Data(payload.utf8).write(to: input)
    let result = await sdk.invoke(.init(operation: "document batch-update", variables: [
      "document-id": .string("document"), "json-file": .string(input.path)
    ]), environment: [:])
    #expect(result.exitCode == 2)
    #expect(result.errors.first?.code == "INPUT_TOO_LARGE", "\(result.rawOutput)")
  }
  #expect(decoder.calls == 0)
  #expect(authorizer.calls == 0)
  #expect(transport.calls == 0)

  let inlineDecoder = GatewayFoundationDecodeProbe()
  let inlineSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: authorizer, transport: transport,
    catalogFileSnapshotter: .live, requestJSONDecoder: inlineDecoder.decoder()
  )
  for payload in ["[" + Array(repeating: "0", count: 16 * 1024 + 1).joined(separator: ",") + "]", String(repeating: "[", count: 129) + "null" + String(repeating: "]", count: 129)] {
    let document = try GatewayJSONValue.array([
      .string("values"), .string("append"), .string("--spreadsheet-id"), .string("sheet"), .string("--range"), .string("A1"),
      .string("--json-values"), .string(payload)
    ]).jsonString()
    let result = await inlineSDK.execute(document: document, variables: [:], environment: [:])
    #expect(result.exitCode == 2)
    #expect(result.errors.first?.code == "INPUT_TOO_LARGE", "\(result.rawOutput)")
  }
  #expect(inlineDecoder.calls == 0)
  #expect(authorizer.calls == 0)
  #expect(transport.calls == 0)
}

@Test func sdkCancellationInterruptsRequestJSONPreflightAndReleasesLimiter() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("request.json")
  try Data("{\"requests\":[]}".utf8).write(to: input)
  let preflight = RequestJSONPreflightProbe(), decoder = GatewayFoundationDecodeProbe()
  let limiter = GatewaySDKExecutionLimiter(limit: 1)
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: SDKFixtureTransport(),
    catalogFileSnapshotter: .live, fileAccessPolicy: .init(inputRoots: [root]), executionPolicy: .init(timeout: 1, maximumConcurrentOperations: 1),
    executionLimiter: limiter, requestJSONStructuralValidationObserver: preflight.pauseFirstTraversal, requestJSONDecoder: decoder.decoder()
  )
  let task = Task { await sdk.invoke(.init(operation: "document batch-update", variables: [
    "document-id": .string("document"), "json-file": .string(input.path)
  ]), environment: [:]) }
  #expect(await gatewaySDKTestHandshake { preflight.waitForEntry() })
  task.cancel()
  let cancelled = await task.value
  #expect(cancelled.exitCode == 5)
  #expect(cancelled.errors.first?.message == "SDK execution was cancelled")
  #expect(preflight.isPaused)
  preflight.releaseTraversal()
  #expect(await gatewaySDKTestHandshake { preflight.waitForExit() })
  #expect(decoder.calls == 0)
  let reuse = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .write), catalogFileSnapshotter: .live,
    executionPolicy: .init(timeout: 1, maximumConcurrentOperations: 1), executionLimiter: limiter
  )
  #expect((await reuse.invoke(.init(operation: "document create", variables: ["title": .string("reuse"), "dry-run": .bool(true)]), environment: [:])).exitCode == 0)
}

@Test func sdkRendersJSONValuesArraysAsOneArgumentAndPreservesRows() async throws {
  let cases: [(GatewayJSONValue, String)] = [
    (.array([.string("single")]), "{\"majorDimension\":\"ROWS\",\"range\":\"A1\",\"values\":[[\"single\"]]}"),
    (.array([.array([.string("a")]), .array([.string("b")])]), "{\"majorDimension\":\"ROWS\",\"range\":\"A1\",\"values\":[[\"a\"],[\"b\"]]}"),
    (.array([.int(1), .bool(true)]), "{\"majorDimension\":\"ROWS\",\"range\":\"A1\",\"values\":[[1,true]]}"),
    (.array([.array([.int(1)]), .array([.int(2)])]), "{\"majorDimension\":\"ROWS\",\"range\":\"A1\",\"values\":[[1],[2]]}")
  ]
  for operation in ["values append", "values update"] {
    for (rows, expectedBody) in cases {
      let authorizer = SDKFixtureAuthorizer(); let transport = SDKFixtureTransport()
      let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .sheets, accessMode: .write), authorizer: authorizer, transport: transport)
      let values: [String: GatewayJSONValue] = ["spreadsheet-id": .string("sheet"), "range": .string("A1"), "json-values": rows]
      #expect(try sdk.buildArgv(operation: operation, variables: values) == operation.split(separator: " ").map(String.init) + ["--json-values", try rows.jsonString(), "--range", "A1", "--spreadsheet-id", "sheet"])
      let envelope = await sdk.invoke(.init(operation: operation, variables: values), environment: [:])
      #expect(envelope.exitCode == 0); #expect(authorizer.calls == 1); #expect(transport.calls == 1)
      #expect(transport.lastBody == Data(expectedBody.utf8))
    }
  }
}
@Test func sdkRawArgvRejectsCredentialAndUnsafeFileBypassesBeforeExecution() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let fifo = root.appendingPathComponent("raw-input.fifo")
  #expect(fifo.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
  let authorizer = SDKFixtureAuthorizer()
  let transport = SDKFixtureTransport()
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .sheets, accessMode: .write), authorizer: authorizer, transport: transport, fileAccessPolicy: .init(inputRoots: [root]))
  let credentialCommands = [
    ["auth logout"],
    ["auth", "logout"],
    ["auth login"],
    ["auth", "login"],
    ["auth revoke", "--credential", "fixture", "--confirm-credential", "fixture"],
    ["auth", "revoke", "--credential", "fixture", "--confirm-credential", "fixture"]
  ]
  for arguments in credentialCommands {
    let document = try GatewayJSONValue.array(arguments.map(GatewayJSONValue.string)).jsonString()
    let result = await sdk.execute(document: document, variables: [:], environment: [:])
    #expect(result.exitCode == 2, "arguments: \(arguments)")
    #expect(result.errors.first?.code == "FORBIDDEN_COMMAND", "arguments: \(arguments)")
    #expect(result.rawOutput.contains("\"code\":\"FORBIDDEN_COMMAND\""), "arguments: \(arguments)")
    #expect(authorizer.calls == 0, "arguments: \(arguments)")
    #expect(transport.calls == 0, "arguments: \(arguments)")
  }
  let unsafeArguments = [
    ["spreadsheet", "batch-update", "--spreadsheet-id", "sheet", "--confirm-spreadsheet-id", "sheet", "--input-file", "-", "--dry-run"],
    ["spreadsheet", "batch-update", "--spreadsheet-id", "sheet", "--confirm-spreadsheet-id", "sheet", "--input-file", fifo.path, "--dry-run"],
    ["spreadsheet", "batch-update", "--help"]
  ]
  for arguments in unsafeArguments {
    let document = try GatewayJSONValue.array(arguments.map(GatewayJSONValue.string)).jsonString()
    let result = await sdk.execute(document: document, variables: [:], environment: [:])
    #expect(result.exitCode == 2, "arguments: \(arguments)")
    let expectedCode = arguments.contains("--help") ? "FORBIDDEN_COMMAND" : "INVALID_ARGUMENT"
    #expect(result.errors.first?.code == expectedCode, "arguments: \(arguments)")
    #expect(result.rawOutput.contains("\"code\":\"\(expectedCode)\""), "arguments: \(arguments)")
    #expect(authorizer.calls == 0, "arguments: \(arguments)")
    #expect(transport.calls == 0, "arguments: \(arguments)")
  }
  let help = await sdk.execute(document: "[\"--help\"]", variables: [:], environment: [:])
  #expect(help.exitCode == 0)
  #expect(help.rawOutput.contains("usage"))
  let combinedFileCommands: [(role: GatewayRole, arguments: [String])] = [
    (
      .init(service: .sheets, accessMode: .write),
      ["spreadsheet batch-update", "--spreadsheet-id", "sheet", "--confirm-spreadsheet-id", "sheet", "--input-file", "-", "--dry-run"]
    ),
    (
      .init(service: .sheets, accessMode: .write),
      ["spreadsheet batch-update", "--spreadsheet-id", "sheet", "--confirm-spreadsheet-id", "sheet", "--input-file", fifo.path, "--dry-run"]
    ),
    (
      .init(service: .docs, accessMode: .write),
      ["document create", "--json-file", "-", "--dry-run"]
    ),
    (
      .init(service: .drive, accessMode: .write),
      ["files upload", "--input", "-", "--max-bytes", "1", "--dry-run"]
    )
  ]
  for testCase in combinedFileCommands {
    let caseAuthorizer = SDKFixtureAuthorizer()
    let caseTransport = SDKFixtureTransport()
    let caseSDK = GoogleDocumentsGatewaySDK(
      role: testCase.role,
      authorizer: caseAuthorizer,
      transport: caseTransport
    )
    let document = try GatewayJSONValue.array(testCase.arguments.map(GatewayJSONValue.string)).jsonString()
    let result = await caseSDK.execute(document: document, variables: [:], environment: [:])
    #expect(result.exitCode == 2, "arguments: \(testCase.arguments)")
    #expect(result.errors.first?.code == "INVALID_ARGUMENT", "arguments: \(testCase.arguments)")
    #expect(result.rawOutput.contains("\"code\":\"INVALID_ARGUMENT\""), "arguments: \(testCase.arguments)")
    #expect(caseAuthorizer.calls == 0, "arguments: \(testCase.arguments)")
    #expect(caseTransport.calls == 0, "arguments: \(testCase.arguments)")
  }
  let body = root.appendingPathComponent("raw-batch.json")
  let payload = Data("{\"requests\":[{\"addSheet\":{}}]}".utf8)
  try payload.write(to: body)
  let allowedArguments = [
    "spreadsheet", "batch-update", "--spreadsheet-id", "sheet",
    "--confirm-spreadsheet-id", "sheet", "--input-file", body.path
  ]
  let allowedDocument = try GatewayJSONValue.array(allowedArguments.map(GatewayJSONValue.string)).jsonString()
  let allowed = await sdk.execute(document: allowedDocument, variables: [:], environment: [:])
  #expect(allowed.exitCode == 0)
  #expect(authorizer.calls == 1)
  #expect(transport.calls == 1)
  #expect(transport.lastBody == payload)
}
@Test func sdkRawNonFileArgumentsPreserveRunnerValidationParity() async throws {
  let role = GatewayRole(service: .sheets, accessMode: .read)
  let arguments = ["values", "get", "--spreadsheet-id", "sheet"]
  let directAuthorizer = SDKFixtureAuthorizer()
  let directTransport = SDKFixtureTransport()
  let direct = GatewayCommandRunner(
    role: role,
    authorizer: directAuthorizer,
    transport: directTransport
  ).run(arguments: arguments)
  let sdkAuthorizer = SDKFixtureAuthorizer()
  let sdkTransport = SDKFixtureTransport()
  let sdk = GoogleDocumentsGatewaySDK(
    role: role,
    authorizer: sdkAuthorizer,
    transport: sdkTransport
  )
  let document = try GatewayJSONValue.array(arguments.map(GatewayJSONValue.string)).jsonString()
  let result = await sdk.execute(document: document, variables: [:], environment: [:])
  #expect(direct.exitCode == 2)
  #expect(result.exitCode == direct.exitCode)
  #expect(result.rawOutput == direct.stdout)
  #expect(directAuthorizer.calls == 0)
  #expect(directTransport.calls == 0)
  #expect(sdkAuthorizer.calls == 0)
  #expect(sdkTransport.calls == 0)
}
@Test func sdkFacadeCoversRequiredLiveInvocationPaths() async throws {
  let readRole = GatewayRole(service: .sheets, accessMode: .read)
  let values = ["spreadsheet-id": GatewayJSONValue.string("sheet"), "range": .string("A1")]
  let valuesTransport = SDKFixtureTransport(); let valuesSDK = GoogleDocumentsGatewaySDK(role: readRole, authorizer: SDKFixtureAuthorizer(), transport: valuesTransport)
  #expect(try valuesSDK.buildArgv(operation: "values get", variables: values) == ["values", "get", "--range", "A1", "--spreadsheet-id", "sheet"])
  #expect((await valuesSDK.invoke(.init(operation: "values get", variables: values), environment: [:])).exitCode == 0)
  #expect(valuesTransport.lastURL?.path == "/v4/spreadsheets/sheet/values/A1")
  let docs = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .write))
  for (value, rendered) in [(GatewayJSONValue.bool(true), "true"), (.bool(false), "false")] {
    let document: [String: GatewayJSONValue] = ["json": value, "dry-run": .bool(true)]
    #expect(try docs.buildArgv(operation: "document create", variables: document) == ["document", "create", "--dry-run", "--json", rendered])
    let result = await docs.invoke(.init(operation: "document create", variables: document), environment: [:])
    #expect(result.exitCode == 2); #expect(result.rawOutput.contains("Input must be a JSON object"))
  }
  let raw = try GatewayJSONValue.array([.string("values"), .string("get"), .string("--spreadsheet-id"), .string("sheet"), .string("--range"), .string("A1")]).jsonString()
  let direct = GatewayCommandRunner(role: readRole, authorizer: SDKFixtureAuthorizer(), transport: SDKFixtureTransport()).run(arguments: ["values", "get", "--spreadsheet-id", "sheet", "--range", "A1"])
  let executed = await valuesSDK.execute(document: raw, variables: ["range": .string("ignored")], environment: [:])
  #expect(executed.exitCode == direct.exitCode); #expect(executed.rawOutput == direct.stdout)
  let ranges: [String: GatewayJSONValue] = ["spreadsheet-id": .string("sheet"), "range": .array([.string("A1"), .string("B2")])]
  #expect(try valuesSDK.buildArgv(operation: "values batch-get", variables: ranges) == ["values", "batch-get", "--range", "A1", "--range", "B2", "--spreadsheet-id", "sheet"])
  #expect((await valuesSDK.invoke(.init(operation: "values batch-get", variables: ranges), environment: [:])).exitCode == 0); #expect(queryPairs(valuesTransport.lastURL) == ["ranges=A1", "ranges=B2"])
  let optionLikeRanges: [String: GatewayJSONValue] = ["spreadsheet-id": .string("sheet"), "range": .array([.string("--leading"), .string("-h"), .string("--help")])]
  #expect(try valuesSDK.buildArgv(operation: "values batch-get", variables: optionLikeRanges) == ["values", "batch-get", "--range=--leading", "--range=-h", "--range=--help", "--spreadsheet-id", "sheet"])
  #expect((await valuesSDK.invoke(.init(operation: "values batch-get", variables: optionLikeRanges), environment: [:])).exitCode == 0)
  #expect(queryPairs(valuesTransport.lastURL) == ["ranges=--leading", "ranges=-h", "ranges=--help"])
  let listTransport = SDKFixtureTransport(); let files = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .read), authorizer: SDKFixtureAuthorizer(), transport: listTransport)
  let listed: [String: GatewayJSONValue] = ["query": .string("name contains 'fixture'"), "page-size": .int(1), "drive-id": .string("drive")]
  #expect(try files.buildArgv(operation: "files list", variables: listed) == ["files", "list", "--drive-id", "drive", "--page-size", "1", "--query", "name contains 'fixture'"])
  #expect((await files.invoke(.init(operation: "files list", variables: listed), environment: [:])).exitCode == 0); #expect(listTransport.lastURL?.path == "/drive/v3/files")
  let expectedListQuery = ["q=name contains 'fixture'", "supportsAllDrives=true", "includeItemsFromAllDrives=true", "pageSize=1",
    "fields=nextPageToken,files(id,name,mimeType,modifiedTime,size,parents,webViewLink)", "corpora=drive", "driveId=drive"]
  #expect(queryPairs(listTransport.lastURL) == expectedListQuery)
  let deleteTransport = SDKFixtureTransport(responses: [.init(statusCode: 200, data: Data("{\"modifiedTime\":\"time\"}".utf8), requestID: nil), .init(statusCode: 204, data: Data(), requestID: nil)])
  let delete = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: deleteTransport)
  let deleting: [String: GatewayJSONValue] = ["file-id": .string("file"), "confirm-file-id": .string("file"), "expected-modified-time": .string("time"), "acknowledge-permanent-delete": .bool(true)]
  #expect(try delete.buildArgv(operation: "files delete", variables: deleting) ==
    ["files", "delete", "--acknowledge-permanent-delete", "--confirm-file-id", "file", "--expected-modified-time", "time", "--file-id", "file"])
  #expect((await delete.invoke(.init(operation: "files delete", variables: deleting), environment: [:])).exitCode == 0); #expect(deleteTransport.methods == ["GET", "DELETE"])
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let body = root.appendingPathComponent("batch.json"); let payload = Data("{\"requests\":[{\"addSheet\":{}}]}".utf8); try payload.write(to: body)
  let bodyTransport = SDKFixtureTransport()
  let writer = GoogleDocumentsGatewaySDK(role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: bodyTransport, fileAccessPolicy: .init(inputRoots: [root]))
  let unprivileged = GoogleDocumentsGatewaySDK(role: .init(service: .sheets, accessMode: .write))
  let bodyValues: [String: GatewayJSONValue] = ["spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"), "input-file": .string(body.path)]
  #expect(try unprivileged.buildArgv(operation: "spreadsheet batch-update", variables: bodyValues) ==
    ["spreadsheet", "batch-update", "--confirm-spreadsheet-id", "sheet", "--input-file", body.path, "--spreadsheet-id", "sheet"])
  #expect((await writer.invoke(.init(operation: "spreadsheet batch-update", variables: bodyValues), environment: [:])).exitCode == 0)
  #expect(bodyTransport.lastURL?.path == "/v4/spreadsheets/sheet:batchUpdate"); #expect(bodyTransport.lastBody == payload)
  let credentialTransport = SDKFixtureTransport(); let credentialSDK = GoogleDocumentsGatewaySDK(role: readRole, transport: credentialTransport)
  let request = GatewayOperationRequest(operation: "values get", variables: values)
  #expect((await credentialSDK.invoke(request, environment: try sdkCredentialEnvironment(role: readRole, token: "first"))).exitCode == 0)
  #expect((await credentialSDK.invoke(request, environment: try sdkCredentialEnvironment(role: readRole, token: "second"))).exitCode == 0)
  #expect((await credentialSDK.invoke(request, environment: [:])).errors.first?.code == "AUTH_REQUIRED"); #expect(credentialTransport.headers.map { $0["Authorization"] } == ["Bearer first", "Bearer second"])
}

@Test func sdkRejectsPrematureResumableUploadCompletion() async throws {
  struct UploadCase {
    let operation: String
    let values: [GatewayJSONValue]
    let responses: [GatewayHTTPResponse]
    let expectedCalls: Int
  }
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("upload.bin")
  try Data(repeating: 0x61, count: 256 * 1024 + 1).write(to: input)
  let cases: [UploadCase] = [
    .init(operation: "files upload", values: [.string(input.path), .int(256 * 1024 + 1)], responses: [
      .init(statusCode: 200, data: Data(), requestID: nil, location: "https://upload.googleapis.com/session"),
      .init(statusCode: 200, data: Data("{}".utf8), requestID: nil)
    ], expectedCalls: 2),
    .init(operation: "files replace-content", values: [.string("file"), .string("file"), .string("time"), .string(input.path), .int(256 * 1024 + 1)], responses: [
      .init(statusCode: 200, data: Data("{\"modifiedTime\":\"time\"}".utf8), requestID: nil),
      .init(statusCode: 200, data: Data(), requestID: nil, location: "https://upload.googleapis.com/session"),
      .init(statusCode: 200, data: Data("{}".utf8), requestID: nil)
    ], expectedCalls: 3)
  ]
  for testCase in cases {
    let transport = SDKFixtureTransport(responses: testCase.responses)
    let sdk = GoogleDocumentsGatewaySDK(
      role: .init(service: .drive, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: transport,
      fileAccessPolicy: .init(inputRoots: [root])
    )
    let variables: [String: GatewayJSONValue]
    if testCase.operation == "files upload" {
      variables = ["input": testCase.values[0], "max-bytes": testCase.values[1]]
    } else {
      variables = ["file-id": testCase.values[0], "confirm-file-id": testCase.values[1], "expected-modified-time": testCase.values[2], "input": testCase.values[3], "max-bytes": testCase.values[4]]
    }
    let result = await sdk.invoke(.init(operation: testCase.operation, variables: variables), environment: [:])
    #expect(result.exitCode == 5, "operation: \(testCase.operation)")
    #expect(result.errors.first?.code == "OUTCOME_UNKNOWN", "operation: \(testCase.operation)")
    #expect(transport.calls == testCase.expectedCalls, "operation: \(testCase.operation)")
  }
}
