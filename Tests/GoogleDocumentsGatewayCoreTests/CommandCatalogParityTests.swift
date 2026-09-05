import Foundation
import GatewaySDKKit
import Testing
@testable import GoogleDocumentsGatewayCore

private let expectedRequiredArguments: [String: Set<String>] = [
  "document get": ["document-id"], "document batch-update": ["document-id"],
  "spreadsheet get": ["spreadsheet-id"], "spreadsheet get-by-data-filter": ["spreadsheet-id", "input-file"],
  "spreadsheet create": ["title"], "sheet copy-to": ["spreadsheet-id", "sheet-id", "destination-spreadsheet-id"],
  "values get": ["spreadsheet-id", "range"], "values batch-get": ["spreadsheet-id", "range"],
  "values batch-get-by-data-filter": ["spreadsheet-id", "input-file"], "developer-metadata get": ["spreadsheet-id", "metadata-id"],
  "developer-metadata search": ["spreadsheet-id", "input-file"], "spreadsheet batch-update": ["spreadsheet-id", "input-file"],
  "values append": ["spreadsheet-id", "range"], "values update": ["spreadsheet-id", "range"],
  "values clear": ["spreadsheet-id", "range"], "values batch-update": ["spreadsheet-id", "input-file"],
  "values batch-clear": ["spreadsheet-id", "input-file"], "values batch-clear-by-data-filter": ["spreadsheet-id", "input-file"],
  "values batch-update-by-data-filter": ["spreadsheet-id", "input-file"], "changes list": ["page-token"],
  "shared-drives get": ["drive-id"], "files get": ["file-id"],
  "files download": ["file-id", "output", "max-bytes"], "files export": ["file-id", "mime-type", "output", "max-bytes"],
  "permissions list": ["file-id"], "permissions get": ["file-id", "permission-id"],
  "comments list": ["file-id"], "comments get": ["file-id", "comment-id"],
  "replies list": ["file-id", "comment-id"], "replies get": ["file-id", "comment-id", "reply-id"],
  "revisions list": ["file-id"], "revisions get": ["file-id", "revision-id"],
  "revisions download": ["file-id", "revision-id", "output", "max-bytes"], "folders create": ["name"],
  "files upload": ["input", "max-bytes"], "files copy": ["file-id", "confirm-file-id"],
  "files replace-content": ["file-id", "confirm-file-id", "expected-modified-time", "input", "max-bytes"],
  "files rename": ["file-id", "confirm-file-id", "expected-modified-time", "name"],
  "files move": ["file-id", "confirm-file-id", "expected-modified-time"],
  "files trash": ["file-id", "confirm-file-id", "expected-modified-time"],
  "files untrash": ["file-id", "confirm-file-id", "expected-modified-time"],
  "files delete": ["file-id", "confirm-file-id", "expected-modified-time", "acknowledge-permanent-delete"],
  "permissions create": ["file-id", "type", "role"],
  "permissions update": ["file-id", "permission-id", "confirm-permission-id", "expected-role", "role"],
  "permissions delete": ["file-id", "permission-id", "confirm-permission-id", "expected-role"],
  "comments create": ["file-id", "content"], "comments update": ["file-id", "comment-id", "confirm-comment-id", "content"],
  "comments delete": ["file-id", "comment-id", "confirm-comment-id"], "replies create": ["file-id", "comment-id"],
  "replies update": ["file-id", "comment-id", "reply-id", "confirm-reply-id", "content"],
  "replies delete": ["file-id", "comment-id", "reply-id", "confirm-reply-id"],
  "revisions update": ["file-id", "revision-id", "confirm-revision-id"]
]

// These accepted inventories are intentionally test-owned. They must not read the runtime flag
// table or mutation classifier, otherwise a production omission would make both sides agree.
private let expectedAllowedOptions: [String: Set<String>] = [
  "document get": ["document-id", "include-tabs-content", "suggestions-view-mode", "dry-run"],
  "document create": ["title", "json", "json-file", "dry-run"], "document batch-update": ["document-id", "text", "json", "json-file", "dry-run"],
  "spreadsheet get": ["spreadsheet-id", "dry-run"], "spreadsheet get-by-data-filter": ["spreadsheet-id", "input-file", "dry-run"],
  "spreadsheet create": ["title", "dry-run"], "spreadsheet batch-update": ["spreadsheet-id", "confirm-spreadsheet-id", "input-file", "dry-run"],
  "sheet copy-to": ["spreadsheet-id", "sheet-id", "destination-spreadsheet-id", "dry-run"], "values get": ["spreadsheet-id", "range", "dry-run"],
  "values batch-get": ["spreadsheet-id", "range", "dry-run"], "values batch-get-by-data-filter": ["spreadsheet-id", "input-file", "dry-run"],
  "developer-metadata get": ["spreadsheet-id", "metadata-id", "dry-run"], "developer-metadata search": ["spreadsheet-id", "input-file", "dry-run"],
  "values append": ["spreadsheet-id", "range", "values", "json-values", "input-file", "major-dimension", "value-input-option", "dry-run"],
  "values update": ["spreadsheet-id", "range", "values", "json-values", "input-file", "major-dimension", "value-input-option", "dry-run"],
  "values clear": ["spreadsheet-id", "range", "confirm-range", "dry-run"], "values batch-update": ["spreadsheet-id", "input-file", "value-input-option", "dry-run"],
  "values batch-clear": ["spreadsheet-id", "input-file", "confirm-clear", "dry-run"], "values batch-clear-by-data-filter": ["spreadsheet-id", "input-file", "confirm-clear", "dry-run"],
  "values batch-update-by-data-filter": ["spreadsheet-id", "input-file", "value-input-option", "dry-run"], "about get": ["dry-run"],
  "changes start-token": ["drive-id", "dry-run"], "changes list": ["page-token", "page-size", "page-all", "max-pages", "drive-id", "dry-run"],
  "shared-drives list": ["query", "page-size", "page-token", "page-all", "max-pages", "dry-run"], "shared-drives get": ["drive-id", "dry-run"],
  "files list": ["query", "page-size", "page-token", "page-all", "max-pages", "drive-id", "dry-run"], "files get": ["file-id", "dry-run"],
  "files download": ["file-id", "output", "max-bytes", "overwrite", "dry-run"], "files export": ["file-id", "mime-type", "output", "max-bytes", "overwrite", "dry-run"],
  "permissions list": ["file-id", "page-size", "page-token", "page-all", "max-pages", "dry-run"], "permissions get": ["file-id", "permission-id", "dry-run"],
  "comments list": ["file-id", "page-size", "page-token", "page-all", "max-pages", "dry-run"], "comments get": ["file-id", "comment-id", "dry-run"],
  "replies list": ["file-id", "comment-id", "page-size", "page-token", "page-all", "max-pages", "dry-run"], "replies get": ["file-id", "comment-id", "reply-id", "dry-run"],
  "revisions list": ["file-id", "page-size", "page-token", "page-all", "max-pages", "dry-run"], "revisions get": ["file-id", "revision-id", "dry-run"],
  "revisions download": ["file-id", "revision-id", "output", "max-bytes", "overwrite", "dry-run"], "folders create": ["name", "parent-id", "dry-run"],
  "files upload": ["input", "max-bytes", "name", "parent-id", "mime-type", "dry-run"], "files copy": ["file-id", "confirm-file-id", "name", "parent-id", "dry-run"],
  "files replace-content": ["file-id", "confirm-file-id", "expected-modified-time", "input", "max-bytes", "dry-run"], "files rename": ["file-id", "confirm-file-id", "expected-modified-time", "name", "dry-run"],
  "files move": ["file-id", "confirm-file-id", "expected-modified-time", "add-parents", "remove-parents", "dry-run"], "files trash": ["file-id", "confirm-file-id", "expected-modified-time", "dry-run"],
  "files untrash": ["file-id", "confirm-file-id", "expected-modified-time", "dry-run"], "files delete": ["file-id", "confirm-file-id", "expected-modified-time", "acknowledge-permanent-delete", "dry-run"],
  "permissions create": ["file-id", "type", "role", "email", "domain", "acknowledge-broad-access", "dry-run"],
  "permissions update": ["file-id", "permission-id", "confirm-permission-id", "expected-role", "role", "dry-run"],
  "permissions delete": ["file-id", "permission-id", "confirm-permission-id", "expected-role", "dry-run"], "comments create": ["file-id", "content", "dry-run"],
  "comments update": ["file-id", "comment-id", "confirm-comment-id", "content", "dry-run"], "comments delete": ["file-id", "comment-id", "confirm-comment-id", "dry-run"],
  "replies create": ["file-id", "comment-id", "content", "action", "dry-run"], "replies update": ["file-id", "comment-id", "reply-id", "confirm-reply-id", "content", "dry-run"],
  "replies delete": ["file-id", "comment-id", "reply-id", "confirm-reply-id", "dry-run"], "revisions update": ["file-id", "revision-id", "confirm-revision-id", "keep-forever", "publish", "dry-run"]
]

private let expectedDestructiveCommands: Set<String> = [
  "document create", "document batch-update", "spreadsheet create", "spreadsheet batch-update",
  "sheet copy-to", "values append", "values update", "values clear", "values batch-update",
  "values batch-clear", "values batch-clear-by-data-filter", "values batch-update-by-data-filter",
  "folders create", "files upload", "files replace-content", "files copy", "files rename",
  "files move", "files trash", "files untrash", "files delete", "permissions create",
  "permissions update", "permissions delete", "comments create", "comments update",
  "comments delete", "replies create", "replies update", "replies delete", "revisions update"
]

private func expectedRoleCommands(_ role: GatewayRole) -> Set<String> {
  switch (role.service, role.accessMode) {
  case (.docs, .read): return ["document get"]
  case (.docs, .write): return ["document batch-update", "document create"]
  case (.sheets, .read): return [
    "developer-metadata get", "developer-metadata search", "spreadsheet get",
    "spreadsheet get-by-data-filter", "values batch-get", "values batch-get-by-data-filter", "values get"
  ]
  case (.sheets, .write): return [
    "sheet copy-to", "spreadsheet batch-update", "spreadsheet create", "values append",
    "values batch-clear", "values batch-clear-by-data-filter", "values batch-update",
    "values batch-update-by-data-filter", "values clear", "values update"
  ]
  case (.drive, .read): return [
    "about get", "changes list", "changes start-token", "comments get", "comments list",
    "files download", "files export", "files get", "files list", "permissions get",
    "permissions list", "replies get", "replies list", "revisions download", "revisions get",
    "revisions list", "shared-drives get", "shared-drives list"
  ]
  case (.drive, .write): return [
    "comments create", "comments delete", "comments update", "files copy", "files delete",
    "files move", "files rename", "files replace-content", "files trash", "files untrash",
    "files upload", "folders create", "permissions create", "permissions delete",
    "permissions update", "replies create", "replies delete", "replies update", "revisions update"
  ]
  }
}

private let commandsWithBodyValues: Set<String> = [
  "document create", "document batch-update", "spreadsheet get-by-data-filter", "spreadsheet create",
  "spreadsheet batch-update", "sheet copy-to", "values batch-get-by-data-filter", "developer-metadata search",
  "values append", "values update", "values batch-update", "values batch-clear",
  "values batch-clear-by-data-filter", "values batch-update-by-data-filter", "folders create", "files upload",
  "files copy", "files replace-content", "files rename", "files trash", "files untrash", "permissions create",
  "permissions update", "comments create", "comments update", "replies create", "replies update", "revisions update"
]

@Test(arguments: [
  GatewayRole(service: .docs, accessMode: .read), GatewayRole(service: .docs, accessMode: .write),
  GatewayRole(service: .sheets, accessMode: .read), GatewayRole(service: .sheets, accessMode: .write),
  GatewayRole(service: .drive, accessMode: .read), GatewayRole(service: .drive, accessMode: .write)
])
func catalogsAreRoleLocalAndMatchRuntimeInventory(role: GatewayRole) {
  let catalog = GatewaySchemaCatalog.googleDocuments(role: role)
  #expect(catalog.validate().isEmpty)
  #expect(catalog.provider == "google-documents-gateway")
  #expect(catalog.tier == "\(role.service.rawValue)-\(role.accessMode.rawValue)")
  let names = Set(catalog.operations.map(\.name))
  #expect(names == expectedRoleCommands(role).union(["config validate", "auth status", "doctor"]))
  #expect(GatewayCapabilityCatalog.commands(for: role) == expectedRoleCommands(role))
  #expect(!names.contains("auth login"))
  #expect(!names.contains("auth revoke"))
  for operation in catalog.operations where expectedAllowedOptions[operation.name] != nil {
    #expect(Set(operation.arguments.map(\.name)) == expectedAllowedOptions[operation.name])
  }
  for operation in catalog.operations where ["config validate", "auth status", "doctor"].contains(operation.name) {
    #expect(operation.arguments == [.init(name: "credential", type: .named("String"), description: "Optional credential profile identifier.")])
  }
}

@Test func everyRoleHasExactNamedTypeClosureAndLocalSchemaSearch() throws {
  let expectedByRole: [(GatewayRole, Set<String>)] = [
    (.init(service: .docs, accessMode: .read), ["SuggestionsViewMode"]),
    (.init(service: .docs, accessMode: .write), []),
    (.init(service: .sheets, accessMode: .read), []),
    (.init(service: .sheets, accessMode: .write), ["MajorDimension", "ValueInputOption"]),
    (.init(service: .drive, accessMode: .read), []),
    (.init(service: .drive, accessMode: .write), ["PermissionType", "PermissionRole"])
  ]
  let allNamedTypes: Set<String> = ["SuggestionsViewMode", "MajorDimension", "ValueInputOption", "PermissionType", "PermissionRole"]

  for (role, expected) in expectedByRole {
    let catalog = GatewaySchemaCatalog.googleDocuments(role: role)
    #expect(Set(catalog.types.map(\.name)) == expected)
    let sdk = GoogleDocumentsGatewaySDK(role: role)
    for name in expected {
      #expect(try sdk.searchSchema("^\(name)$", options: .init(kinds: [.enumeration])).map(\.name) == [name])
    }
    for name in allNamedTypes.subtracting(expected) {
      #expect(try sdk.searchSchema("^\(name)$", options: .init(kinds: [.enumeration])).isEmpty)
    }
  }
}

@Test func catalogDestructiveMetadataAndEnumerationValuesStayExact() {
  let expectedEnumsByRole: [(GatewayRole, [String: [String]])] = [
    (.init(service: .docs, accessMode: .read), [
      "SuggestionsViewMode": ["DEFAULT_FOR_CURRENT_ACCESS", "SUGGESTIONS_INLINE", "PREVIEW_SUGGESTIONS_ACCEPTED", "PREVIEW_WITHOUT_SUGGESTIONS"]
    ]),
    (.init(service: .docs, accessMode: .write), [:]),
    (.init(service: .sheets, accessMode: .read), [:]),
    (.init(service: .sheets, accessMode: .write), [
      "MajorDimension": ["ROWS", "COLUMNS"], "ValueInputOption": ["RAW", "USER_ENTERED"]
    ]),
    (.init(service: .drive, accessMode: .read), [:]),
    (.init(service: .drive, accessMode: .write), [
      "PermissionType": ["user", "group", "domain", "anyone"], "PermissionRole": ["reader", "commenter", "writer"]
    ])
  ]

  for (role, expectedEnums) in expectedEnumsByRole {
    let catalog = GatewaySchemaCatalog.googleDocuments(role: role)
    let actualEnums = Dictionary(uniqueKeysWithValues: catalog.types.map { ($0.name, $0.enumValues ?? []) })
    #expect(actualEnums == expectedEnums)
    for operation in catalog.operations {
      #expect(operation.isDestructive == expectedDestructiveCommands.contains(operation.name))
    }
  }
}

@Test func everyCatalogCommandHasRuntimeRoleParity() {
  for service in GatewayService.allCases {
    for access in GatewayAccessMode.allCases {
      let role = GatewayRole(service: service, accessMode: access)
      let catalog = GatewaySchemaCatalog.googleDocuments(role: role)
      for operation in catalog.operations where expectedAllowedOptions[operation.name] != nil {
        #expect(expectedRoleCommands(role).contains(operation.name))
      }
    }
  }
}

@Test func catalogRequirednessAndSDLStayRoleScoped() {
  for service in GatewayService.allCases {
    for access in GatewayAccessMode.allCases {
      let catalog = GatewaySchemaCatalog.googleDocuments(role: .init(service: service, accessMode: access))
      for operation in catalog.operations where expectedAllowedOptions[operation.name] != nil {
        #expect(Set(operation.arguments.filter(\.isRequired).map(\.name)) == expectedRequiredArguments[operation.name, default: []])
        for argument in operation.arguments {
          #expect(argument.isRequired == argument.type.isRequired)
        }
      }
    }
  }
  let sheets = GatewaySchemaCatalog.googleDocuments(role: .init(service: .sheets, accessMode: .write))
  #expect(sheets.sdl().contains("spreadsheet_id: String!"))
  #expect(sheets.sdl().contains("confirm_spreadsheet_id: String"))
  let drive = GatewaySchemaCatalog.googleDocuments(role: .init(service: .drive, accessMode: .write))
  #expect(drive.sdl().contains("acknowledge_permanent_delete: Boolean!"))
  #expect(drive.operation(named: "files upload")?.arguments.first(where: { $0.name == "input" })?.description?.contains("67108864") == true)
  #expect(drive.operation(named: "replies create")?.arguments.first(where: { $0.name == "action" })?.description?.contains("resolve or reopen") == true)
}

@Test func everyRoleGatedCatalogCommandBuildsAndRunsDry() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let files = try CatalogFixtureFiles(root: root)
  let authorizer = CatalogFixtureAuthorizer()
  let transport = CatalogFixtureTransport()

  for service in GatewayService.allCases {
    for access in GatewayAccessMode.allCases {
      let role = GatewayRole(service: service, accessMode: access)
      let sdk = GoogleDocumentsGatewaySDK(
        role: role,
        authorizer: authorizer,
        transport: transport,
        fileAccessPolicy: .init(inputRoots: [root], outputRoots: [root])
      )
      let runner = GatewayCommandRunner(role: role, authorizer: authorizer, transport: transport, environment: [:])
      for operation in sdk.catalog.operations where expectedAllowedOptions[operation.name] != nil {
        let variables = fixtureVariables(for: operation, files: files, root: root)
        let nonDryOptionalNames = Set(operation.arguments.filter { !$0.isRequired && $0.name != "dry-run" }.map(\.name))
        if !nonDryOptionalNames.isEmpty {
          #expect(!nonDryOptionalNames.isDisjoint(with: Set(variables.keys)), "\(operation.name) must exercise one optional argument")
        }
        let envelope = await sdk.invoke(.init(operation: operation.name, variables: variables), environment: [:])
        #expect(envelope.exitCode == 0, "\(operation.name): \(envelope.rawOutput)")
        #expect(envelope.errors.isEmpty, "\(operation.name): \(envelope.rawOutput)")
        #expect(envelope.rawOutput.contains("\"dryRun\":true"))
        if commandsWithBodyValues.contains(operation.name) {
          #expect(envelope.rawOutput.contains("\"bodyValuesRedacted\":true"), "\(operation.name): \(envelope.rawOutput)")
        }
        let argv = try sdk.buildArgv(operation: operation.name, variables: variables)
        let rejected = runner.run(arguments: argv + ["--undeclared-option", "value"])
        #expect(rejected.exitCode == 2)
        #expect(rejected.stdout.contains("INVALID_ARGUMENT"))
      }
    }
  }
  #expect(authorizer.calls == 0)
  #expect(transport.calls == 0)
}

func gatewaySDKTestScratchDirectory() throws -> URL {
  let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    .appendingPathComponent("tmp", isDirectory: true)
    .appendingPathComponent("gateway-sdk-tests", isDirectory: true)
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

private struct CatalogFixtureFiles {
  let dataFilters: URL
  let spreadsheetBatch: URL
  let valuesBatch: URL
  let batchClear: URL
  let upload: URL

  init(root: URL) throws {
    dataFilters = root.appendingPathComponent("filters.json")
    spreadsheetBatch = root.appendingPathComponent("spreadsheet-batch.json")
    valuesBatch = root.appendingPathComponent("values-batch.json")
    batchClear = root.appendingPathComponent("batch-clear.json")
    upload = root.appendingPathComponent("upload.txt")
    try Data("{\"dataFilters\":[{}]}".utf8).write(to: dataFilters)
    try Data("{\"requests\":[{\"addSheet\":{}}]}".utf8).write(to: spreadsheetBatch)
    try Data("{\"data\":[{\"range\":\"A1\",\"values\":[[\"value\"]]}]}".utf8).write(to: valuesBatch)
    try Data("{\"ranges\":[\"A1\"]}".utf8).write(to: batchClear)
    try Data("fixture".utf8).write(to: upload)
  }

  func inputFile(for command: String) -> URL {
    switch command {
    case "spreadsheet get-by-data-filter", "values batch-get-by-data-filter", "developer-metadata search", "values batch-clear-by-data-filter": dataFilters
    case "spreadsheet batch-update": spreadsheetBatch
    case "values batch-update", "values batch-update-by-data-filter": valuesBatch
    case "values batch-clear": batchClear
    default: valuesBatch
    }
  }
}

private final class CatalogFixtureAuthorizer: GatewayCancellableAuthorizer, @unchecked Sendable {
  private(set) var calls = 0
  func accessToken(for role: GatewayRole) throws -> String {
    calls += 1
    return "fixture"
  }
  func accessToken(for role: GatewayRole, cancellation: GatewaySDKCancellation) throws -> String {
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }
    return try accessToken(for: role)
  }
}

private final class CatalogFixtureTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private(set) var calls = 0
  private(set) var lastURL: URL?
  private(set) var lastMethod: String?
  private(set) var lastBody: Data?
  private(set) var urls: [URL] = []
  private(set) var methods: [String] = []
  private(set) var headers: [[String: String]] = []
  private let responses: [GatewayHTTPResponse]
  init(responses: [GatewayHTTPResponse] = []) { self.responses = responses }
  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    calls += 1
    lastURL = url; lastMethod = method; lastBody = body
    urls.append(url); methods.append(method); self.headers.append(headers)
    if responses.indices.contains(calls - 1) { return responses[calls - 1] }
    return GatewayHTTPResponse(statusCode: 200, data: Data("{}".utf8), requestID: "fixture")
  }
  func send(url: URL, method: String, headers: [String: String], body: Data?, timeout _: TimeInterval, cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }
    return try send(url: url, method: method, headers: headers, body: body)
  }
  func send(
    url: URL, method: String, headers: [String: String], body: Data?, maximumResponseBytes: Int,
    timeout: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse { try enforceResponseLimit(try send(url: url, method: method, headers: headers, body: body, timeout: timeout, cancellation: cancellation), maximumResponseBytes) }
}
private func enforceResponseLimit(
  _ response: GatewayHTTPResponse, _ maximumResponseBytes: Int
) throws -> GatewayHTTPResponse { guard response.data.count <= maximumResponseBytes else { throw GatewayError.transportFailure("SDK transport exceeded the response byte limit") }; return response }

private func fixtureVariables(for operation: GatewayOperation, files: CatalogFixtureFiles, root: URL) -> [String: GatewayJSONValue] {
  var values: [String: GatewayJSONValue] = ["dry-run": .bool(true)]
  for argument in operation.arguments where argument.isRequired {
    values[argument.name] = fixtureValue(name: argument.name, operation: operation.name, files: files, root: root)
  }
  if let optional = optionalFixture(for: operation, files: files, root: root) {
    values[optional.name] = optional.value
  }
  switch operation.name {
  case "document create": values["title"] = .string("Fixture document")
  case "document batch-update": values["text"] = .string("Fixture text")
  case "values append", "values update": values["values"] = .string("fixture")
  case "files move": values["add-parents"] = .string("parent")
  case "permissions create": values["email"] = .string("fixture@example.invalid")
  case "replies create": values["content"] = .string("Fixture reply")
  case "revisions update": values["keep-forever"] = .bool(true)
  default: break
  }
  return values
}

private func optionalFixture(for operation: GatewayOperation, files: CatalogFixtureFiles, root: URL) -> (name: String, value: GatewayJSONValue)? {
  let excludedCrossFlagSources: Set<String> = operation.name == "document create" || operation.name == "document batch-update"
    ? ["json", "json-file"]
    : ["input-file", "json-values"]
  guard let argument = operation.arguments.first(where: {
    !$0.isRequired && $0.name != "dry-run" && !excludedCrossFlagSources.contains($0.name)
  }) else { return nil }
  return (argument.name, fixtureValue(name: argument.name, operation: operation.name, files: files, root: root))
}

private func fixtureValue(name: String, operation: String, files: CatalogFixtureFiles, root: URL) -> GatewayJSONValue {
  if name == "range" {
    return operation == "values batch-get" ? .array([.string("Sheet1!A1")]) : .string("Sheet1!A1")
  }
  if let value = stringFixtures[name] { return .string(value) }
  if ["sheet-id", "metadata-id", "page-size", "max-pages"].contains(name) { return .int(1) }
  if name == "max-bytes" { return .int(1024) }
  if ["dry-run", "overwrite", "page-all", "acknowledge-broad-access", "acknowledge-permanent-delete", "confirm-clear", "keep-forever", "publish"].contains(name) { return .bool(true) }
  if name == "output" { return .string(root.appendingPathComponent("output-\(operation)").path) }
  if name == "input" { return .string(files.upload.path) }
  if name == "input-file" { return .string(files.inputFile(for: operation).path) }
  return .string("fixture")
}

private let stringFixtures: [String: String] = [
  "document-id": "document", "spreadsheet-id": "spreadsheet", "destination-spreadsheet-id": "destination",
  "file-id": "file", "confirm-file-id": "file", "permission-id": "permission", "confirm-permission-id": "permission",
  "comment-id": "comment", "confirm-comment-id": "comment", "reply-id": "reply", "confirm-reply-id": "reply",
  "revision-id": "revision", "confirm-revision-id": "revision", "expected-modified-time": "2026-09-04T00:00:00Z",
  "expected-role": "reader", "drive-id": "token", "page-token": "token", "include-tabs-content": "true",
  "suggestions-view-mode": "DEFAULT_FOR_CURRENT_ACCESS", "major-dimension": "ROWS", "value-input-option": "RAW",
  "query": "name contains 'fixture'", "mime-type": "text/plain", "confirm-range": "Sheet1!A1",
  "confirm-spreadsheet-id": "spreadsheet", "name": "fixture", "content": "fixture", "type": "user", "role": "reader"
]
