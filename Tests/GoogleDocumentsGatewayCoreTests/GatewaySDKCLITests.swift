import Darwin
import Foundation
import GatewaySDKKit
import Testing
@testable import GoogleDocumentsGatewayCore
@Test func sdkCLIRejectsInvalidArguments() {
  let runner = GatewayCommandRunner(role: .init(service: .docs, accessMode: .read))
  #expect(runner.run(arguments: ["schema", "print", "extra"]).exitCode == 2)
  #expect(runner.run(arguments: ["schema", "search", "["]).exitCode == 2)
  #expect(runner.run(arguments: ["operation", "run", "document", "get"]).exitCode == 2)
  #expect(runner.run(arguments: ["schema", "search", "x", "--kinds", "query,mutation,command,object,inputObject,enumeration", "--kinds", "command"]).exitCode == 2)
  for kinds in [",", "command,", "command,,enumeration"] {
    let result = runner.run(arguments: ["schema", "search", "x", "--kinds", kinds])
    #expect(result.exitCode == 2, "kinds: \(kinds)")
    #expect(result.stdout.contains("INVALID_ARGUMENT"), "kinds: \(kinds)")
  }
  #expect(runner.run(arguments: ["--help"]).stdout.contains("SDK: schema print"))
}
@Test func sdkCLISchemaSearchOptionsAreBehavioral() throws {
  let docs = GatewayCommandRunner(role: .init(service: .docs, accessMode: .read))
  #expect(docs.run(arguments: ["schema", "print"]).stdout.contains("type Command"))
  let commandOnly = docs.run(arguments: ["schema", "search", "suggestions|Suggestions", "--kinds", "command"])
  let commandMatches = try JSONDecoder().decode([GatewaySchemaSearch.Match].self, from: Data(commandOnly.stdout.utf8))
  #expect(commandOnly.exitCode == 0)
  #expect(commandMatches.map(\.name) == ["document get"])
  #expect(commandMatches.allSatisfy { $0.kind == .command })
  let enumOnly = docs.run(arguments: ["schema", "search", "suggestions|Suggestions", "--kinds", "enumeration"])
  let enumMatches = try JSONDecoder().decode([GatewaySchemaSearch.Match].self, from: Data(enumOnly.stdout.utf8))
  #expect(enumOnly.exitCode == 0)
  #expect(enumMatches.map(\.name) == ["SuggestionsViewMode"])
  #expect(enumMatches.allSatisfy { $0.kind == .enumeration })
  let referenced = docs.run(arguments: ["schema", "search", "^document get$", "--kinds", "command", "--include-referenced-types"])
  let referencedMatches = try JSONDecoder().decode([GatewaySchemaSearch.Match].self, from: Data(referenced.stdout.utf8))
  #expect(referenced.exitCode == 0)
  #expect(referencedMatches.map(\.name) == ["document get", "SuggestionsViewMode"])
  #expect(referencedMatches.last?.kind == .enumeration)
  #expect(referencedMatches.last?.matchedOn == ["referenced-by:document get"])
  let sheets = GatewayCommandRunner(role: .init(service: .sheets, accessMode: .read))
  let unlimited = sheets.run(arguments: ["schema", "search", "values", "--kinds", "command"])
  let unlimitedMatches = try JSONDecoder().decode([GatewaySchemaSearch.Match].self, from: Data(unlimited.stdout.utf8))
  let limited = sheets.run(arguments: ["schema", "search", "values", "--kinds", "command", "--limit", "2"])
  let limitedMatches = try JSONDecoder().decode([GatewaySchemaSearch.Match].self, from: Data(limited.stdout.utf8))
  #expect(unlimited.exitCode == 0)
  #expect(unlimitedMatches.count > 2)
  #expect(limited.exitCode == 0)
  #expect(limitedMatches == Array(unlimitedMatches.prefix(2)))
  let invalid = docs.run(arguments: ["schema", "search", "["])
  let error = try JSONDecoder().decode(SchemaSearchErrorResponse.self, from: Data(invalid.stdout.utf8))
  #expect(invalid.exitCode == 2)
  #expect(error.ok == false)
  #expect(error.error.code == "INVALID_ARGUMENT")
  #expect(!error.error.message.isEmpty)
}
@Test func sdkRawExecutePreservesSchemaSearchOptions() async throws {
  let role = GatewayRole(service: .sheets, accessMode: .read)
  let arguments = ["schema", "search", "^values get$", "--kinds", "command", "--limit", "1"]
  let direct = GatewayCommandRunner(role: role, environment: [:]).run(arguments: arguments)
  let sdk = GoogleDocumentsGatewaySDK(role: role)
  let result = await sdk.execute(
    document: try rawSDKDocument(arguments),
    variables: ["ignored": .bool(true)],
    environment: [:]
  )
  #expect(result.exitCode == direct.exitCode)
  #expect(result.rawOutput == direct.stdout)
  #expect(result.rawOutput.contains("values get"))
  #expect(result.errors.isEmpty)
  let expectedSearchData = try GatewayJSONValue.parse(direct.stdout)
  #expect(result.data == expectedSearchData)
  let printed = await sdk.execute(document: try rawSDKDocument(["schema", "print"]), variables: [:], environment: [:])
  #expect(printed.exitCode == 0); #expect(printed.errors.isEmpty)
  #expect(printed.data == .string(GatewayCommandRunner(role: role).run(arguments: ["schema", "print"]).stdout))
}
@Test func sdkRawDocumentsEnforceSerializedAndArgumentLimits() async throws {
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .read))
  let oversizedDocument = String(repeating: " ", count: GatewayInputValidator.maximumBodyBytes + 1)
  let oversizedArgument = String(repeating: "x", count: 64 * 1024 + 1)
  for document in [oversizedDocument, try rawSDKDocument(["schema", "search", oversizedArgument])] {
    let result = await sdk.execute(document: document, variables: [:], environment: [:])
    #expect(result.exitCode == 2)
    #expect(result.errors.first?.code == "INPUT_TOO_LARGE")
  }
  let wideDocument = "[" + Array(repeating: "\"\"", count: 16 * 1024 + 1).joined(separator: ",") + "]"
  let decodeProbe = GatewayRawDocumentDecodeProbe()
  let wideSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .read), catalogFileSnapshotter: .live,
    rawDocumentParser: { try decodeProbe.parse($0) }
  )
  let wideResult = await wideSDK.execute(document: wideDocument, variables: [:], environment: [:])
  #expect(wideResult.exitCode == 2)
  #expect(wideResult.errors.first?.code == "INPUT_TOO_LARGE")
  #expect(decodeProbe.calls == 0)
  for document in ["[[\"nested\"]]", "[{\"nested\":\"value\"}]", "[\"unterminated]"] {
    let probe = GatewayRawDocumentDecodeProbe()
    let candidate = GoogleDocumentsGatewaySDK(
      role: .init(service: .docs, accessMode: .read), catalogFileSnapshotter: .live,
      rawDocumentParser: { try probe.parse($0) }
    )
    let result = await candidate.execute(document: document, variables: [:], environment: [:])
    #expect(result.exitCode == 2); #expect(result.errors.first?.code == "UNSUPPORTED_DOCUMENT")
    #expect(probe.calls == 0)
  }
  let preflightEntered = DispatchSemaphore(value: 0), resumePreflight = DispatchSemaphore(value: 0)
  let cancellation = GatewaySDKCancellation()
  let cancellationSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .read), catalogFileSnapshotter: .live,
    rawDocumentParser: { try decodeProbe.parse($0) }, rawArgumentPreflightObserver: { offset in
      guard offset == 4_096 else { return }
      preflightEntered.signal(); _ = resumePreflight.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)
    }
  )
  let preflight = Task { () -> Result<[String]?, GatewayError> in
    do {
      return .success(try cancellationSDK.rawArguments(wideDocument, cancellation: cancellation))
    } catch let error as GatewayError {
      return .failure(error)
    } catch {
      return .failure(.invalidArgument("Unexpected raw preflight error"))
    }
  }
  let entered = await withCheckedContinuation { continuation in
    DispatchQueue.global().async { continuation.resume(returning: preflightEntered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success) }
  }
  #expect(entered)
  cancellation.cancel(); resumePreflight.signal()
  #expect(await preflight.value == .failure(.transportFailure("SDK execution was cancelled")))
  #expect(decodeProbe.calls == 0)
}
@Test func directRunnerPreservesFinalBodyAndPageAllCompatibility() throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let prefix = "{\"data\":[{\"range\":\"A1\",\"values\":[[\"", suffix = "\"]]}]}"
  let source = Data((prefix + String(repeating: "x", count: GatewayInputValidator.maximumBodyBytes - prefix.utf8.count - suffix.utf8.count - 8) + suffix).utf8)
  let input = root.appendingPathComponent("values.json"); try source.write(to: input)
  let bodyTransport = SDKFixtureTransport()
  let body = GatewayCommandRunner(role: .init(service: .sheets, accessMode: .write), authorizer: GatewaySDKBoundaryAuthorizer(), transport: bodyTransport)
    .run(arguments: ["values", "batch-update", "--spreadsheet-id", "sheet", "--input-file", input.path])
  #expect(body.exitCode == 0); #expect((bodyTransport.lastBody?.count ?? 0) > GatewayInputValidator.maximumBodyBytes)
  let value = String(repeating: "x", count: GatewaySDKExecutionPolicy.maximumResponseBytes / 2)
  let pages = SDKFixtureTransport(responses: [
    .init(statusCode: 200, data: Data("{\"files\":[{\"id\":\"\(value)\"}],\"nextPageToken\":\"next\"}".utf8), requestID: nil),
    .init(statusCode: 200, data: Data("{\"files\":[{\"id\":\"\(value)\"}]}".utf8), requestID: nil)
  ])
  let result = GatewayCommandRunner(role: .init(service: .drive, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: pages)
    .run(arguments: ["files", "list", "--page-all", "--max-pages", "2"])
  #expect(result.exitCode == 0); #expect(result.stdout.contains("\"pagesFetched\":2")); #expect(pages.calls == 2)
}
@Test func sdkCLIOperationRunPreservesOptionLikeValues() {
  let runner = GatewayCommandRunner(role: .init(service: .docs, accessMode: .write))
  for title in ["--leading", "-h", "--help"] {
    let variables = "{\"title\":\"\(title)\",\"dry-run\":true}"
    let result = runner.run(arguments: ["operation", "run", "document", "create", "--variables", variables])
    #expect(result.exitCode == 0, "title: \(title)")
    #expect(result.stdout.contains("\"dryRun\":true"), "title: \(title)")
  }
}
@Test func sdkCLIOperationRunClassifiesOperationsBeforeOpeningVariablesFiles() {
  let runner = GatewayCommandRunner(role: .init(service: .sheets, accessMode: .read))
  var opens = 0
  let reader: (String) -> String? = { _ in
    opens += 1
    return "{}"
  }
  let foreign = GatewaySDKCommandRouter.operationRun(
    ["values", "update", "--variables-file", "ignored.json"],
    runner: runner,
    variablesFileReader: reader
  )
  #expect(opens == 0)
  #expect(foreign.exitCode == 2)
  #expect(foreign.stdout.contains("FORBIDDEN_COMMAND"))
  let unknown = GatewaySDKCommandRouter.operationRun(
    ["invented", "operation", "--variables-file", "ignored.json"],
    runner: runner,
    variablesFileReader: reader
  )
  #expect(opens == 0)
  #expect(unknown.exitCode == 2)
  #expect(unknown.stdout.contains("INVALID_ARGUMENT"))
}
@Test func sdkCLIOperationRunPreservesJSONValuesRows() throws {
  let authorizer = VariablesFileFixtureAuthorizer()
  let transport = VariablesFileFixtureTransport()
  let runner = GatewayCommandRunner(
    role: .init(service: .sheets, accessMode: .write),
    authorizer: authorizer,
    transport: transport
  )
  let cases: [(GatewayJSONValue, String)] = [
    (.array([.string("single")]), "{\"majorDimension\":\"ROWS\",\"range\":\"A1\",\"values\":[[\"single\"]]}"),
    (.array([.array([.string("a")]), .array([.string("b")])]), "{\"majorDimension\":\"ROWS\",\"range\":\"A1\",\"values\":[[\"a\"],[\"b\"]]}"),
    (.array([.int(1), .bool(true)]), "{\"majorDimension\":\"ROWS\",\"range\":\"A1\",\"values\":[[1,true]]}"),
    (.array([.array([.int(1)]), .array([.int(2)])]), "{\"majorDimension\":\"ROWS\",\"range\":\"A1\",\"values\":[[1],[2]]}")
  ]
  var calls = 0
  for operation in ["values append", "values update"] {
    for testCase in cases {
    let variables = try GatewayJSONValue.object([
      "spreadsheet-id": .string("sheet"),
      "range": .string("A1"),
      "json-values": testCase.0
    ]).jsonString()
    let result = runner.run(arguments: ["operation", "run"] + operation.split(separator: " ").map(String.init) + ["--variables", variables])
    calls += 1
    #expect(result.exitCode == 0)
    #expect(authorizer.calls == calls)
    #expect(transport.calls == calls)
    #expect(transport.lastBody == Data(testCase.1.utf8))
    }
  }
}
@Test func sdkCLIOperationRunRendersScalarJSONBooleans() throws {
  let runner = GatewayCommandRunner(role: .init(service: .docs, accessMode: .write))
  for (value, rendered) in [(GatewayJSONValue.bool(true), "true"), (.bool(false), "false")] {
    let variables = try GatewayJSONValue.object(["json": value, "dry-run": .bool(true)]).jsonString()
    let operationRun = runner.run(arguments: [
      "operation", "run", "document", "create", "--variables", variables
    ])
    let direct = runner.run(arguments: ["document", "create", "--dry-run", "--json", rendered])
    #expect(operationRun.exitCode == 2, "json: \(rendered)")
    #expect(operationRun.stdout == direct.stdout, "json: \(rendered)")
    #expect(operationRun.stdout.contains("Input must be a JSON object"), "json: \(rendered)")
    #expect(!operationRun.stdout.contains("Missing value for --json"), "json: \(rendered)")
  }
}
@Test func sdkCLIAcceptsVariablesFilesAndRejectsBadSources() throws {
  let authorizer = VariablesFileFixtureAuthorizer()
  let transport = VariablesFileFixtureTransport()
  let runner = GatewayCommandRunner(
    role: .init(service: .sheets, accessMode: .read),
    authorizer: authorizer,
    transport: transport
  )
  let root = try gatewaySDKTestScratchDirectory()
  let file = root.appendingPathComponent("variables.json"); let malformed = root.appendingPathComponent("malformed.json"); let array = root.appendingPathComponent("array.json")
  let boundary = root.appendingPathComponent("boundary.json"); let symbolicLink = root.appendingPathComponent("variables-link.json")
  let symbolicDirectory = root.appendingPathComponent("variables-directory-link")
  let oversized = root.appendingPathComponent("oversized.json")
  try Data("{\"spreadsheet-id\":\"s\",\"range\":\"A1\",\"dry-run\":true}".utf8).write(to: file)
  try Data("not json".utf8).write(to: malformed); try Data("[]".utf8).write(to: array)
  let boundaryPrefix = Data("{\"spreadsheet-id\":\"s\",\"range\":\"A1\",\"dry-run\":true}".utf8)
  try (boundaryPrefix + Data(repeating: 0x20, count: GatewayInputValidator.maximumBodyBytes - boundaryPrefix.count)).write(to: boundary)
  try FileManager.default.createSymbolicLink(atPath: symbolicLink.path, withDestinationPath: file.path); try FileManager.default.createSymbolicLink(atPath: symbolicDirectory.path, withDestinationPath: root.path)
  try Data(repeating: 0x78, count: GatewayInputValidator.maximumBodyBytes + 1).write(to: oversized)
  defer { try? FileManager.default.removeItem(at: root) }
  let fromFile = runner.run(arguments: ["operation", "run", "values", "get", "--variables-file", file.path])
  #expect(fromFile.exitCode == 0)
  #expect(runner.run(arguments: ["operation", "run", "values", "get", "--variables-file=\(file.path)"]).exitCode == 0)
  #expect(runner.run(arguments: ["operation", "run", "values", "get", "--variables", "{}", "--variables-file", file.path]).exitCode == 2)
  #expect(runner.run(arguments: ["operation", "run", "unknown", "command", "--variables", "{}"]).exitCode == 2)
  #expect(runner.run(arguments: ["operation", "run", "values", "get", "--variables", "[]"]).exitCode == 2)
  #expect(runner.run(arguments: ["operation", "run", "values", "get", "--variables-file", "/missing/variables.json"]).exitCode == 2)
  #expect(runner.run(arguments: ["operation", "run", "values", "get", "--variables-file", malformed.path]).exitCode == 2)
  #expect(runner.run(arguments: ["operation", "run", "values", "get", "--variables-file", array.path]).exitCode == 2)
  #expect(runner.run(arguments: ["operation", "run", "values", "get", "--variables-file", boundary.path]).exitCode == 0)
  for unsafePath in [symbolicLink, symbolicDirectory.appendingPathComponent("variables.json"), root.appendingPathComponent("missing-directory/variables.json")] {
    #expect(runner.run(arguments: ["operation", "run", "values", "get", "--variables-file", unsafePath.path]).exitCode == 2)
  }
  let oversizedResult = runner.run(arguments: ["operation", "run", "values", "get", "--variables-file", oversized.path])
  #expect(oversizedResult.exitCode == 2)
  #expect(oversizedResult.stdout.contains("INVALID_ARGUMENT"))
  #expect(authorizer.calls == 0); #expect(transport.calls == 0)
}
@Test func sdkCLIBoundedVariablesFileReaderUsesOneVerifiedDescriptorUntilEOF() throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("redirected.json")
  let payload = "{\"spreadsheet-id\":\"s\",\"range\":\"A1\",\"dry-run\":true}"
  try Data(payload.utf8).write(to: file)
  var capturedFlags: Int32?
  var statusCalls = 0
  var readDescriptors: [Int32] = []
  var requestedBytes: [Int] = []
  var chunks = [Data(payload.utf8.prefix(7)), Data(payload.utf8.dropFirst(7))]
  let value = GatewaySDKCommandRouter.boundedVariablesFile(
    at: root.appendingPathComponent("does-not-exist.json").path,
    opener: { _, flags in
      capturedFlags = flags
      return file.path.withCString { Darwin.open($0, flags) }
    },
    statusReader: { descriptor, status in
      statusCalls += 1
      return Darwin.fstat(descriptor, status)
    },
    dataReader: { descriptor, requestedByteCount in
      readDescriptors.append(descriptor)
      requestedBytes.append(requestedByteCount)
      return chunks.isEmpty ? Data() : chunks.removeFirst()
    }
  )
  #expect(value == payload)
  #expect(statusCalls == 1)
  #expect(readDescriptors.count == 3)
  #expect(Set(readDescriptors).count == 1)
  #expect(requestedBytes == [
    GatewayInputValidator.maximumBodyBytes + 1,
    GatewayInputValidator.maximumBodyBytes + 1 - 7,
    GatewayInputValidator.maximumBodyBytes + 1 - Data(payload.utf8).count
  ])
  #expect((capturedFlags ?? 0) & O_NOFOLLOW != 0)
  #expect((capturedFlags ?? 0) & O_NONBLOCK != 0)
  #expect((capturedFlags ?? 0) & O_CLOEXEC != 0)
}
@Test func sdkCLIBoundedVariablesFileRejectsLimitPlusOneAfterShortReads() throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("variables.json")
  try Data().write(to: file)
  let limit = GatewayInputValidator.maximumBodyBytes
  var requestedBytes: [Int] = []
  var chunks = [
    Data(repeating: 0x20, count: 3),
    Data(repeating: 0x20, count: limit - 3),
    Data([0x20])
  ]
  let value = GatewaySDKCommandRouter.boundedVariablesFile(
    at: file.path,
    dataReader: { _, requestedByteCount in
      requestedBytes.append(requestedByteCount)
      return chunks.isEmpty ? Data() : chunks.removeFirst()
    }
  )
  #expect(value == nil)
  #expect(requestedBytes == [limit + 1, limit - 2, 1])
}
@Test func sdkCLIOperationRunRejectsAmbientAndNonRegularFileInputsBeforeExecution() throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let fifo = root.appendingPathComponent("input.fifo")
  #expect(fifo.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
  let authorizer = VariablesFileFixtureAuthorizer()
  let transport = VariablesFileFixtureTransport()
  let runner = GatewayCommandRunner(
    role: .init(service: .sheets, accessMode: .write),
    authorizer: authorizer,
    transport: transport
  )
  for path in ["-", fifo.path] {
    let variables = "{\"spreadsheet-id\":\"sheet\",\"confirm-spreadsheet-id\":\"sheet\",\"input-file\":\"\(path)\"}"
    let result = runner.run(arguments: ["operation", "run", "spreadsheet", "batch-update", "--variables", variables])
    #expect(result.exitCode == 2, "path: \(path)")
    #expect(result.stdout.contains("INVALID_ARGUMENT"), "path: \(path)")
  }
  let oversized = root.appendingPathComponent("oversized.json")
  try Data(repeating: 0x61, count: GatewayInputValidator.maximumBodyBytes + 1).write(to: oversized)
  let oversizedVariables = "{\"spreadsheet-id\":\"sheet\",\"confirm-spreadsheet-id\":\"sheet\",\"input-file\":\"\(oversized.path)\"}"
  let oversizedResult = runner.run(arguments: [
    "operation", "run", "spreadsheet", "batch-update", "--variables", oversizedVariables
  ])
  #expect(oversizedResult.exitCode == 2)
  #expect(oversizedResult.stdout.contains("INPUT_TOO_LARGE"))
  #expect(authorizer.calls == 0)
  #expect(transport.calls == 0)
}
@Test func sdkRawOperationRunCannotBypassDefaultDenyFileCapabilities() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let secret = root.appendingPathComponent("secret.txt")
  let variablesFile = root.appendingPathComponent("variables.json")
  try Data("secret".utf8).write(to: secret)
  let variables = try GatewayJSONValue.object(["input": .string(secret.path)]).jsonString()
  try Data(variables.utf8).write(to: variablesFile)
  let authorizer = VariablesFileFixtureAuthorizer()
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .write),
    authorizer: authorizer
  )
  for source in [
    ["--variables", variables],
    ["--variables-file", variablesFile.path]
  ] {
    let document = try GatewayJSONValue.array(
      ["operation run", "files upload"].map(GatewayJSONValue.string) + source.map(GatewayJSONValue.string)
    ).jsonString()
    let result = await sdk.execute(document: document, variables: [:], environment: [:])
    #expect(result.exitCode == 2)
    #expect(result.errors.first?.code == "FORBIDDEN_COMMAND")
  }
  #expect(authorizer.calls == 0)
}
