import Foundation

public struct GatewayCommandResult: Sendable {
  public let stdout: String
  public let exitCode: Int32
}

public struct GatewayCommandRunner: Sendable {
  public let role: GatewayRole
  public let authorizer: GatewayAuthorizing
  public let transport: GatewayHTTPTransport
  public let credentialProfile: GatewayCredentialProfile?

  public init(role: GatewayRole, authorizer: GatewayAuthorizing? = nil, transport: GatewayHTTPTransport = URLSessionGatewayTransport(), credentialProfile: GatewayCredentialProfile? = nil) {
    self.role = role
    self.credentialProfile = credentialProfile
    self.authorizer = authorizer ?? credentialProfile.map { PersistedTokenAuthorizer(profile: $0, transport: transport) } ?? GatewayCommandRunner.defaultAuthorizer(role: role)
    self.transport = transport
  }

  public func run(arguments: [String]) -> GatewayCommandResult {
    do {
      if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
        return success(["usage": usage, "service": role.service.rawValue, "role": role.accessMode.rawValue])
      }
      if arguments == ["--version"] { return success(["version": Version.current]) }
      let parsed = try ParsedArguments(arguments)
      let command = parsed.command
      if command == "config validate" {
        let profile = try resolvedProfile(parsed.options["credential"]?.last ?? role.identifier)
        return success(["operation": command, "status": "VALID", "service": role.service.rawValue, "role": role.accessMode.rawValue, "credential": profile.id])
      }
      if command == "auth status" || command == "doctor" {
        return try diagnosticResult(command: command, options: parsed.options)
      }
      if command == "auth login" || command == "auth revoke" {
        return try authenticationResult(command: command, options: parsed.options)
      }
      guard allowedCommands.contains(command) else {
        return failure("FORBIDDEN_COMMAND", "\(command) is not available to the \(role.identifier) executable.", exitCode: 2)
      }
      try validate(command: command, options: parsed.options)
      let plan = try GatewayRequestBuilder.plan(role: role, operation: command, options: parsed.options)
      let body = try GatewayInputValidator.body(for: role, command: command, options: parsed.options)
      if parsed.options["dry-run"] != nil {
        return success(dryRunPayload(for: plan, options: parsed.options))
      }
      let token = try authorizer.accessToken(for: role)
      if role.service == .drive, [
        "files replace-content", "files rename", "files move", "files trash", "files untrash",
        "permissions update", "permissions delete"
      ].contains(command) {
        let preflight = try driveMutationPreflight(command: command, token: token, options: parsed.options)
        if let preflight { return preflight }
      }
      if role.service == .drive, ["files upload", "files replace-content"].contains(command), let body {
        return try driveUploadResult(operation: command, plan: plan, input: body, token: token, options: parsed.options)
      }
      if role.service == .drive, drivePaginatedOperations.contains(command), parsed.options["page-all"] != nil {
        return try drivePaginatedResult(operation: command, token: token, options: parsed.options)
      }
      let response = try transport.send(url: try providerURL(for: plan), method: plan.method, headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"], body: body)
      if role.service == .drive, ["files download", "files export", "revisions download"].contains(command) {
        return try driveTransferResult(operation: command, response: response, options: parsed.options)
      }
      return try providerResult(operation: command, response: response)
    } catch GatewayError.forbiddenCommand(let command) {
      return failure("FORBIDDEN_COMMAND", "\(command) is not available to this executable.", exitCode: 2)
    } catch GatewayError.invalidArgument(let message) {
      return failure("INVALID_ARGUMENT", message, exitCode: 2)
    } catch GatewayError.inputTooLarge {
      return failure("INPUT_TOO_LARGE", "The input exceeds the configured command size limit.", exitCode: 2)
    } catch GatewayError.authenticationRequired {
      return failure("AUTH_REQUIRED", "Configure a role-specific OAuth credential. Token values are not accepted as command arguments.", exitCode: 4)
    } catch GatewayError.grantInspectionFailed {
      return failure("GRANT_INSPECTION_FAILED", "The imported token grant could not be inspected online; provider use is denied.", exitCode: 4)
    } catch GatewayError.scopeMismatch {
      return failure("SCOPE_MISMATCH", "The inspected token grant does not exactly match this executable role.", exitCode: 4)
    } catch GatewayError.transportFailure(let message) {
      return failure("TRANSPORT_FAILURE", message, exitCode: 5)
    } catch {
      return failure("INVALID_ARGUMENT", "Unable to parse command arguments.", exitCode: 2)
    }
  }

  private var allowedCommands: Set<String> { GatewayCapabilityCatalog.commands(for: role) }

  private var drivePaginatedOperations: Set<String> {
    [
      "changes list", "shared-drives list", "files list", "permissions list",
      "comments list", "replies list", "revisions list"
    ]
  }

  private var usage: String {
    let common = "config validate | auth login --credential ID | auth status --credential ID | auth revoke --credential ID --confirm-credential ID | doctor"
    return "Usage: \(executableName) <command> [options]\nRole: \(role.accessMode.rawValue); exact scope: \(role.scope)\nCommands: \(allowedCommands.sorted().joined(separator: ", "))\nCommon: \(common)"
  }

  private var executableName: String {
    let noun = role.service == .sheets ? "sheet" : role.service.rawValue
    let suffix = role.accessMode == .read ? "reader" : "writer"
    return "google-\(noun)-gateway-\(suffix)"
  }

  private func validate(command: String, options: [String: [String]]) throws {
    let allowedOptions: [String: Set<String>] = [
      "document get": ["document-id", "include-tabs-content", "suggestions-view-mode", "dry-run"],
      "document create": ["json", "json-file", "dry-run"],
      "document batch-update": ["document-id", "json", "json-file", "dry-run"],
      "spreadsheet get": ["spreadsheet-id", "dry-run"],
      "spreadsheet get-by-data-filter": ["spreadsheet-id", "input-file", "dry-run"],
      "spreadsheet create": ["title", "dry-run"],
      "spreadsheet batch-update": ["spreadsheet-id", "confirm-spreadsheet-id", "input-file", "dry-run"],
      "sheet copy-to": ["spreadsheet-id", "sheet-id", "destination-spreadsheet-id", "dry-run"],
      "values get": ["spreadsheet-id", "range", "dry-run"],
      "values batch-get": ["spreadsheet-id", "range", "dry-run"],
      "values batch-get-by-data-filter": ["spreadsheet-id", "input-file", "dry-run"],
      "developer-metadata get": ["spreadsheet-id", "metadata-id", "dry-run"],
      "developer-metadata search": ["spreadsheet-id", "input-file", "dry-run"],
      "values append": ["spreadsheet-id", "range", "input-file", "value-input-option", "dry-run"],
      "values update": ["spreadsheet-id", "range", "input-file", "value-input-option", "dry-run"],
      "values clear": ["spreadsheet-id", "range", "confirm-range", "dry-run"],
      "values batch-update": ["spreadsheet-id", "input-file", "value-input-option", "dry-run"],
      "values batch-clear": ["spreadsheet-id", "input-file", "confirm-clear", "dry-run"],
      "values batch-clear-by-data-filter": ["spreadsheet-id", "input-file", "confirm-clear", "dry-run"],
      "values batch-update-by-data-filter": ["spreadsheet-id", "input-file", "value-input-option", "dry-run"],
      "about get": ["dry-run"],
      "changes start-token": ["drive-id", "dry-run"],
      "changes list": ["page-token", "page-size", "page-all", "max-pages", "drive-id", "dry-run"],
      "shared-drives list": ["query", "page-size", "page-token", "page-all", "max-pages", "dry-run"],
      "shared-drives get": ["drive-id", "dry-run"],
      "files list": ["query", "page-size", "page-token", "page-all", "max-pages", "drive-id", "dry-run"],
      "files get": ["file-id", "dry-run"],
      "files download": ["file-id", "output", "max-bytes", "overwrite", "dry-run"],
      "files export": ["file-id", "mime-type", "output", "max-bytes", "overwrite", "dry-run"],
      "permissions list": ["file-id", "page-size", "page-token", "page-all", "max-pages", "dry-run"],
      "permissions get": ["file-id", "permission-id", "dry-run"],
      "comments list": ["file-id", "page-size", "page-token", "page-all", "max-pages", "dry-run"],
      "comments get": ["file-id", "comment-id", "dry-run"],
      "replies list": ["file-id", "comment-id", "page-size", "page-token", "page-all", "max-pages", "dry-run"],
      "replies get": ["file-id", "comment-id", "reply-id", "dry-run"],
      "revisions list": ["file-id", "page-size", "page-token", "page-all", "max-pages", "dry-run"],
      "revisions get": ["file-id", "revision-id", "dry-run"],
      "revisions download": ["file-id", "revision-id", "output", "max-bytes", "overwrite", "dry-run"],
      "folders create": ["name", "dry-run"],
      "files upload": ["input", "max-bytes", "dry-run"],
      "files copy": ["file-id", "confirm-file-id", "name", "parent-id", "dry-run"],
      "files replace-content": [
        "file-id", "confirm-file-id", "expected-modified-time", "input", "max-bytes", "dry-run"
      ],
      "files rename": ["file-id", "confirm-file-id", "expected-modified-time", "name", "dry-run"],
      "files move": [
        "file-id", "confirm-file-id", "expected-modified-time", "add-parents", "remove-parents", "dry-run"
      ],
      "files trash": ["file-id", "confirm-file-id", "expected-modified-time", "dry-run"],
      "files untrash": ["file-id", "confirm-file-id", "expected-modified-time", "dry-run"],
      "permissions create": ["file-id", "type", "role", "email", "domain", "acknowledge-broad-access", "dry-run"],
      "permissions update": [
        "file-id", "permission-id", "confirm-permission-id", "expected-role", "role", "dry-run"
      ],
      "permissions delete": [
        "file-id", "permission-id", "confirm-permission-id", "expected-role", "dry-run"
      ],
      "comments create": ["file-id", "content", "dry-run"],
      "comments update": ["file-id", "comment-id", "confirm-comment-id", "content", "dry-run"],
      "comments delete": ["file-id", "comment-id", "confirm-comment-id", "dry-run"],
      "replies create": ["file-id", "comment-id", "content", "action", "dry-run"],
      "replies update": ["file-id", "comment-id", "reply-id", "confirm-reply-id", "content", "dry-run"],
      "replies delete": ["file-id", "comment-id", "reply-id", "confirm-reply-id", "dry-run"],
      "revisions update": ["file-id", "revision-id", "confirm-revision-id", "keep-forever", "publish", "dry-run"]
    ]
    if let allowed = allowedOptions[command], let unknown = Set(options.keys).subtracting(allowed).sorted().first {
      throw GatewayError.invalidArgument("Unsupported option --\(unknown) for \(command)")
    }
    switch role.service {
    case .docs:
      try validateDocs(command: command, options: options)
    case .sheets:
      try validateSheets(command: command, options: options)
    case .drive:
      try validateDrive(command: command, options: options)
    }
  }

  private func validateDocs(command: String, options: [String: [String]]) throws {
    if command.contains("document") && command != "document create" {
      try require("document-id", options: options)
    }
    if command == "document create" || command == "document batch-update" {
      let sources = [options["json"] != nil, options["json-file"] != nil].filter { $0 }.count
      guard sources == 1 else { throw GatewayError.invalidArgument("Specify exactly one of --json or --json-file") }
    }
  }

  private func validateSheets(command: String, options: [String: [String]]) throws {
    if command == "spreadsheet create" { try require("title", options: options) }
    if command != "spreadsheet create" { try require("spreadsheet-id", options: options) }
    let bodyCommands = [
      "spreadsheet get-by-data-filter", "spreadsheet batch-update", "values batch-get-by-data-filter",
      "developer-metadata search", "values append", "values update", "values batch-update",
      "values batch-clear", "values batch-clear-by-data-filter", "values batch-update-by-data-filter"
    ]
    if bodyCommands.contains(command) { try require("input-file", options: options) }
    if ["values get", "values append", "values update", "values clear"].contains(command) {
      try require("range", options: options)
    }
    if let inputOption = options["value-input-option"]?.last, !["RAW", "USER_ENTERED"].contains(inputOption) {
      throw GatewayError.invalidArgument("--value-input-option must be RAW or USER_ENTERED")
    }
    if command == "values clear", options["dry-run"] == nil {
      let range = options["range"]?.last?.trimmingCharacters(in: .whitespacesAndNewlines)
      let confirmation = options["confirm-range"]?.last?.trimmingCharacters(in: .whitespacesAndNewlines)
      guard range == confirmation else { throw GatewayError.invalidArgument("--confirm-range must exactly match --range") }
    }
    if command == "spreadsheet batch-update", options["dry-run"] == nil {
      guard options["spreadsheet-id"]?.last == options["confirm-spreadsheet-id"]?.last else {
        throw GatewayError.invalidArgument("--confirm-spreadsheet-id must exactly match --spreadsheet-id")
      }
    }
    if ["values batch-clear", "values batch-clear-by-data-filter"].contains(command),
       options["dry-run"] == nil,
       options["confirm-clear"] == nil {
      throw GatewayError.invalidArgument("Batch clear requires --confirm-clear")
    }
    if command == "sheet copy-to" {
      try require("sheet-id", options: options)
      try require("destination-spreadsheet-id", options: options)
    }
    if command == "developer-metadata get" { try require("metadata-id", options: options) }
  }

  // Validation is an exhaustive safety policy for the curated Drive surface.
  // swiftlint:disable:next cyclomatic_complexity
  private func validateDrive(command: String, options: [String: [String]]) throws {
    let commandsRequiringFileID = [
      "files get", "files download", "files export", "files copy", "files replace-content", "files rename",
      "files move", "files trash", "files untrash", "permissions list", "permissions get", "permissions create",
      "permissions update", "permissions delete", "comments list", "comments get", "comments create",
      "comments update", "comments delete", "replies list", "replies get", "replies create", "replies update",
      "replies delete", "revisions list", "revisions get", "revisions download", "revisions update"
    ]
    if commandsRequiringFileID.contains(command) { try require("file-id", options: options) }
    if ["files upload", "files replace-content"].contains(command) {
      try require("input", options: options)
      try require("max-bytes", options: options)
    }
    if let maximum = options["max-bytes"]?.last.flatMap(Int.init), maximum < 0 {
      throw GatewayError.invalidArgument("--max-bytes must be non-negative")
    }
    if ["files download", "files export", "revisions download"].contains(command) {
      try require("output", options: options)
      guard let maximum = options["max-bytes"]?.last.flatMap(Int.init), maximum >= 0 else {
        throw GatewayError.invalidArgument("Drive transfers require a non-negative --max-bytes")
      }
      let output = options["output"]?.last ?? ""
      if FileManager.default.fileExists(atPath: output), options["overwrite"] == nil {
        throw GatewayError.invalidArgument("Output exists; specify --overwrite")
      }
    }
    if ["files list", "permissions list", "changes list", "shared-drives list", "comments list", "replies list", "revisions list"].contains(command) {
      if let pageSize = options["page-size"]?.last.flatMap(Int.init), !(1...1000).contains(pageSize) {
        throw GatewayError.invalidArgument("--page-size must be between 1 and 1000")
      }
      if let maxPages = options["max-pages"]?.last.flatMap(Int.init), !(1...100).contains(maxPages) {
        throw GatewayError.invalidArgument("--max-pages must be between 1 and 100")
      }
    }
    if ["files replace-content", "files rename", "files move", "files trash", "files untrash"].contains(command) {
      try require("expected-modified-time", options: options)
      let fileID = options["file-id"]?.last
      guard fileID == options["confirm-file-id"]?.last else { throw GatewayError.invalidArgument("--confirm-file-id must exactly match --file-id") }
    }
    if command == "files move", options["add-parents"] == nil, options["remove-parents"] == nil {
      throw GatewayError.invalidArgument("files move requires --add-parents or --remove-parents")
    }
    if command == "files copy" {
      guard options["file-id"]?.last == options["confirm-file-id"]?.last else {
        throw GatewayError.invalidArgument("--confirm-file-id must exactly match --file-id")
      }
    }
    if ["permissions get", "permissions update", "permissions delete"].contains(command) {
      try require("permission-id", options: options)
    }
    if ["permissions update", "permissions delete"].contains(command) {
      let permissionID = options["permission-id"]?.last
      guard permissionID == options["confirm-permission-id"]?.last else { throw GatewayError.invalidArgument("--confirm-permission-id must exactly match --permission-id") }
      try require("expected-role", options: options)
    }
    if command == "permissions create" {
      try require("type", options: options)
      try require("role", options: options)
      let type = options["type"]?.last
      guard ["user", "group", "domain", "anyone"].contains(type) else {
        throw GatewayError.invalidArgument("Unsupported permission type")
      }
      if ["user", "group"].contains(type) { try require("email", options: options) }
      if type == "domain" { try require("domain", options: options) }
      if type == "anyone", options["email"] != nil || options["domain"] != nil { throw GatewayError.invalidArgument("anyone permissions cannot specify --email or --domain") }
      if ["domain", "anyone"].contains(type), options["acknowledge-broad-access"] == nil { throw GatewayError.invalidArgument("Broad sharing requires --acknowledge-broad-access") }
      guard ["reader", "commenter", "writer"].contains(options["role"]?.last) else { throw GatewayError.invalidArgument("Unsupported permission role") }
    }
    if command == "permissions update" {
      try require("role", options: options)
      guard ["reader", "commenter", "writer"].contains(options["role"]?.last) else {
        throw GatewayError.invalidArgument("Unsupported permission role")
      }
    }
    if command == "shared-drives get" { try require("drive-id", options: options) }
    if command == "changes list" { try require("page-token", options: options) }
    if ["comments get", "comments update", "comments delete"].contains(command) {
      try require("comment-id", options: options)
    }
    if command == "comments create" { try require("content", options: options) }
    if ["comments update", "comments delete"].contains(command) {
      guard options["comment-id"]?.last == options["confirm-comment-id"]?.last else {
        throw GatewayError.invalidArgument("--confirm-comment-id must exactly match --comment-id")
      }
      if command == "comments update" { try require("content", options: options) }
    }
    if command.hasPrefix("replies ") { try require("comment-id", options: options) }
    if ["replies get", "replies update", "replies delete"].contains(command) {
      try require("reply-id", options: options)
    }
    if command == "replies create" {
      guard options["content"] != nil || options["action"] != nil else {
        throw GatewayError.invalidArgument("Reply create requires --content or --action")
      }
    }
    if ["replies update", "replies delete"].contains(command) {
      guard options["reply-id"]?.last == options["confirm-reply-id"]?.last else {
        throw GatewayError.invalidArgument("--confirm-reply-id must exactly match --reply-id")
      }
      if command == "replies update" { try require("content", options: options) }
    }
    if ["revisions get", "revisions download", "revisions update"].contains(command) {
      try require("revision-id", options: options)
    }
    if command == "revisions update" {
      guard options["revision-id"]?.last == options["confirm-revision-id"]?.last else {
        throw GatewayError.invalidArgument("--confirm-revision-id must exactly match --revision-id")
      }
      guard options["keep-forever"] != nil || options["publish"] != nil else {
        throw GatewayError.invalidArgument("Revision update requires --keep-forever or --publish")
      }
    }
  }

  private func require(_ option: String, options: [String: [String]]) throws {
    guard
      let value = options[option]?.last?.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.isEmpty
    else {
      throw GatewayError.invalidArgument("Missing required --\(option)")
    }
  }

  private func dryRunPayload(for plan: GatewayRequestPlan, options: [String: [String]]) -> [String: Any] {
    [
      "operation": plan.operation,
      "dryRun": true,
      "request": ["method": plan.method, "path": plan.path, "query": plan.query.map { ["name": $0.0, "value": $0.1] }],
      "meta": ["tokenLoaded": false, "transportCalled": false, "bodyValuesRedacted": options["input-file"] != nil || options["json"] != nil || options["json-file"] != nil]
    ]
  }

  private func success(_ data: [String: Any]) -> GatewayCommandResult {
    GatewayCommandResult(stdout: encode(["ok": true, "data": data]), exitCode: 0)
  }

  private func failure(_ code: String, _ message: String, exitCode: Int32) -> GatewayCommandResult {
    GatewayCommandResult(stdout: encode(["ok": false, "error": ["code": code, "message": message]]), exitCode: exitCode)
  }

  private func encode(_ object: [String: Any]) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
    return String(data: data, encoding: .utf8) ?? "{\"ok\":false}"
  }

  private func providerURL(for plan: GatewayRequestPlan) throws -> URL {
    let host: String
    switch role.service {
    case .docs: host = "https://docs.googleapis.com"
    case .sheets: host = "https://sheets.googleapis.com"
    case .drive: host = plan.path.hasPrefix("/upload/") ? "https://www.googleapis.com" : "https://www.googleapis.com"
    }
    guard var components = URLComponents(string: host + plan.path) else { throw GatewayError.transportFailure("Unable to construct provider URL") }
    components.queryItems = plan.query.map { URLQueryItem(name: $0.0, value: $0.1) }
    guard let url = components.url else { throw GatewayError.transportFailure("Unable to encode provider URL") }
    return url
  }

  private func providerResult(operation: String, response: GatewayHTTPResponse) throws -> GatewayCommandResult {
    guard (200...299).contains(response.statusCode) else {
      return failure("PROVIDER_ERROR", providerMessage(response.data), exitCode: 5)
    }
    let data: Any
    if response.data.isEmpty {
      data = [:]
    } else if let object = try? JSONSerialization.jsonObject(with: response.data) {
      data = object
    } else {
      return failure("PROVIDER_RESPONSE_INVALID", "Provider returned a non-JSON response.", exitCode: 5)
    }
    return success(["operation": operation, "data": data, "requestId": response.requestID ?? NSNull()])
  }

  private func driveUploadResult(operation: String, plan: GatewayRequestPlan, input: Data, token: String, options: [String: [String]]) throws -> GatewayCommandResult {
    let fileName = URL(fileURLWithPath: options["input"]?.last ?? "upload").lastPathComponent
    let metadata = operation == "files upload" ? try JSONSerialization.data(withJSONObject: ["name": fileName]) : Data("{}".utf8)
    let initial = try transport.send(
      url: try providerURL(for: plan),
      method: plan.method,
      headers: [
        "Authorization": "Bearer \(token)",
        "Content-Type": "application/json",
        "X-Upload-Content-Type": "application/octet-stream",
        "X-Upload-Content-Length": String(input.count)
      ],
      body: metadata
    )
    guard (200...299).contains(initial.statusCode), let location = initial.location, let sessionURL = URL(string: location), approvedUploadSessionURL(sessionURL) else {
      return failure("PROVIDER_ERROR", providerMessage(initial.data), exitCode: 5)
    }
    let chunkSize = 256 * 1024
    if input.isEmpty {
      let response = try transport.send(
        url: sessionURL,
        method: "PUT",
        headers: [
          "Authorization": "Bearer \(token)",
          "Content-Length": "0",
          "Content-Type": "application/octet-stream",
          "Content-Range": "bytes */0"
        ],
        body: Data()
      )
      return try providerResult(operation: operation, response: response)
    }
    var offset = 0
    var attempts = 0
    var finalResponse: GatewayHTTPResponse?
    while offset < input.count {
      let end = min(offset + chunkSize, input.count)
      let chunk = input.subdata(in: offset..<end)
      let response = try transport.send(
        url: sessionURL,
        method: "PUT",
        headers: [
          "Authorization": "Bearer \(token)",
          "Content-Length": String(chunk.count),
          "Content-Type": "application/octet-stream",
          "Content-Range": "bytes \(offset)-\(end - 1)/\(input.count)"
        ],
        body: chunk
      )
      if response.statusCode == 308 {
        offset = end
        attempts = 0
        continue
      }
      if (200...299).contains(response.statusCode) {
        finalResponse = response
        offset = input.count
        continue
      }
      attempts += 1
      guard attempts < 3 else { return failure("PROVIDER_ERROR", providerMessage(response.data), exitCode: 5) }
    }
    guard let finalResponse else { return failure("PROVIDER_ERROR", "Resumable upload did not return a final response.", exitCode: 5) }
    return try providerResult(operation: operation, response: finalResponse)
  }

  private func approvedUploadSessionURL(_ url: URL) -> Bool {
    url.scheme == "https" && ["www.googleapis.com", "upload.googleapis.com"].contains(url.host?.lowercased())
  }

  private func driveTransferResult(operation: String, response: GatewayHTTPResponse, options: [String: [String]]) throws -> GatewayCommandResult {
    guard (200...299).contains(response.statusCode) else {
      return failure("PROVIDER_ERROR", providerMessage(response.data), exitCode: 5)
    }
    let limit = options["max-bytes"]?.last.flatMap(Int.init) ?? 0
    guard response.data.count <= limit else {
      return failure("TRANSFER_LIMIT_EXCEEDED", "Provider response exceeds --max-bytes.", exitCode: 5)
    }
    guard let output = options["output"]?.last else { throw GatewayError.invalidArgument("Missing required --output") }
    try response.data.write(to: URL(fileURLWithPath: output), options: [.atomic])
    return success(["operation": operation, "bytesWritten": response.data.count, "output": output, "requestId": response.requestID ?? NSNull()])
  }

  private func drivePaginatedResult(operation: String, token: String, options: [String: [String]]) throws -> GatewayCommandResult {
    let collectionKeys = [
      "changes list": "changes",
      "shared-drives list": "drives",
      "files list": "files",
      "permissions list": "permissions",
      "comments list": "comments",
      "replies list": "replies",
      "revisions list": "revisions"
    ]
    guard let collectionKey = collectionKeys[operation] else {
      throw GatewayError.forbiddenCommand(operation)
    }
    let maximumPages = options["max-pages"]?.last.flatMap(Int.init) ?? 10
    var accumulated: [Any] = []
    var pageToken = operation == "changes list" ? options["page-token"]?.last : nil
    var newStartPageToken: String?
    var pages = 0
    repeat {
      pages += 1
      var pageOptions = options
      if let pageToken { pageOptions["page-token"] = [pageToken] }
      let plan = try GatewayRequestBuilder.plan(role: role, operation: operation, options: pageOptions)
      let response = try transport.send(
        url: try providerURL(for: plan),
        method: plan.method,
        headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
        body: nil
      )
      guard (200...299).contains(response.statusCode) else {
        return failure("PROVIDER_ERROR", providerMessage(response.data), exitCode: 5)
      }
      guard let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
        return failure("PROVIDER_RESPONSE_INVALID", "Provider returned a non-JSON response.", exitCode: 5)
      }
      accumulated.append(contentsOf: object[collectionKey] as? [Any] ?? [])
      pageToken = object["nextPageToken"] as? String
      if let token = object["newStartPageToken"] as? String { newStartPageToken = token }
    } while pageToken?.isEmpty == false && pages < maximumPages
    return success([
      "operation": operation,
      collectionKey: accumulated,
      "pagesFetched": pages,
      "truncated": pageToken?.isEmpty == false,
      "nextPageToken": pageToken ?? NSNull(),
      "newStartPageToken": newStartPageToken ?? NSNull()
    ])
  }

  private func driveMutationPreflight(command: String, token: String, options: [String: [String]]) throws -> GatewayCommandResult? {
    let fileID = options["file-id"]?.last ?? ""
    let pathID = fileID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? fileID
    let isPermission = command.hasPrefix("permissions ")
    let path: String
    let expectedKey: String
    let actualKey: String
    if isPermission {
      let permissionID = options["permission-id"]?.last ?? ""
      let pathPermissionID = permissionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? permissionID
      path = "/drive/v3/files/\(pathID)/permissions/\(pathPermissionID)"
      expectedKey = "expected-role"
      actualKey = "role"
    } else {
      path = "/drive/v3/files/\(pathID)"
      expectedKey = "expected-modified-time"
      actualKey = "modifiedTime"
    }
    let plan = GatewayRequestPlan(operation: "preflight", method: "GET", path: path, query: [("supportsAllDrives", "true"), ("fields", actualKey)])
    let response = try transport.send(
      url: try providerURL(for: plan),
      method: "GET",
      headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
      body: nil
    )
    guard (200...299).contains(response.statusCode) else {
      return failure("PROVIDER_ERROR", providerMessage(response.data), exitCode: 5)
    }
    guard
      let object = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
      let actual = object[actualKey] as? String,
      actual == options[expectedKey]?.last
    else {
      return failure("STALE_REMOTE_STATE", "Remote state no longer matches --\(expectedKey).", exitCode: 3)
    }
    return nil
  }

  private func providerMessage(_ data: Data) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = object["error"] as? [String: Any],
          let message = error["message"] as? String else { return "Google API request failed." }
    return message
  }

  private func authenticationResult(command: String, options: [String: [String]]) throws -> GatewayCommandResult {
    if command == "auth login", options["authorization-code"] != nil || options["pkce-verifier"] != nil {
      throw GatewayError.invalidArgument("Authorization codes and PKCE verifiers are not accepted as command arguments")
    }
    let credential = options["credential"]?.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? role.identifier
    guard !credential.isEmpty else { throw GatewayError.invalidArgument("Missing required --credential") }
    let profile = try resolvedProfile(credential)
    if command == "auth revoke" {
      guard options["confirm-credential"]?.last == credential else { throw GatewayError.invalidArgument("--confirm-credential must exactly match --credential") }
      if let store = try? tokenStore(profile: profile) {
        try GatewayOAuthClient(profile: profile, transport: transport).revoke(store)
      }
      if profile.tokenStoreJSON == nil {
        try GatewayTokenStoreFile.revoke(url: profile.tokenStoreURL)
      }
      return success([
        "operation": command,
        "credential": credential,
        "revoked": true,
        "environmentTokenStore": profile.tokenStoreJSON != nil
      ])
    }
    guard profile.tokenStoreJSON == nil else {
      throw GatewayError.invalidArgument("auth login cannot replace an environment-provided token store")
    }
    let timeout = options["timeout-seconds"]?.last.flatMap(TimeInterval.init) ?? 180
    guard timeout > 0, timeout <= 600 else { throw GatewayError.invalidArgument("--timeout-seconds must be between 1 and 600") }
    let store = try GatewayLoopbackOAuth(profile: profile, transport: transport).login(timeout: timeout)
    try GatewayTokenStoreFile.write(store, to: profile.tokenStoreURL)
    return success(["operation": command, "credential": credential, "status": "READY", "scope": role.scope])
  }

  private func diagnosticResult(command: String, options: [String: [String]]) throws -> GatewayCommandResult {
    let profile = try resolvedProfile(options["credential"]?.last ?? role.identifier)
    let store = try? tokenStore(profile: profile)
    return success([
      "operation": command,
      "credential": profile.id,
      "role": role.identifier,
      "requiredScope": role.scope,
      "tokenStorePath": profile.tokenStoreURL.path,
      "status": store == nil ? "NOT_READY" : "READY",
      "tokenStoreSource": profile.tokenStoreJSON == nil ? "file" : "environment",
      "hasRefreshToken": store?.refreshToken?.isEmpty == false,
      "expiresAt": store?.expiresAt?.description ?? NSNull()
    ])
  }

  private static func defaultAuthorizer(role: GatewayRole) -> GatewayAuthorizing {
    if let profile = try? GatewayCredentialProfileLoader.load(role: role) {
      return PersistedTokenAuthorizer(profile: profile)
    }
    return MissingCredentialAuthorizer()
  }

  private func resolvedProfile(_ credential: String) throws -> GatewayCredentialProfile {
    if let credentialProfile {
      guard credentialProfile.id == credential, credentialProfile.role == role else { throw GatewayError.scopeMismatch }
      return credentialProfile
    }
    return try GatewayCredentialProfileLoader.load(role: role, credentialID: credential)
  }

  private func tokenStore(profile: GatewayCredentialProfile) throws -> GatewayTokenStore {
    if let tokenStoreJSON = profile.tokenStoreJSON {
      return try GatewayTokenStoreFile.read(json: tokenStoreJSON, role: role)
    }
    return try GatewayTokenStoreFile.read(from: profile.tokenStoreURL, role: role)
  }
}

private struct ParsedArguments {
  let command: String
  let options: [String: [String]]

  init(_ arguments: [String]) throws {
    let commandWords = arguments.prefix { !$0.hasPrefix("-") }
    guard !commandWords.isEmpty, commandWords.count <= 2 else { throw GatewayError.invalidArgument("Expected a command") }
    command = commandWords.joined(separator: " ")
    var values: [String: [String]] = [:]
    var index = commandWords.count
    while index < arguments.count {
      let option = arguments[index]
      guard option.hasPrefix("--") else { throw GatewayError.invalidArgument("Expected option, got \(option)") }
      let key = String(option.dropFirst(2))
      if [
        "dry-run", "overwrite", "page-all", "online", "acknowledge-broad-access", "confirm-clear",
        "keep-forever", "publish"
      ].contains(key) {
        values[key, default: []].append("true")
        index += 1
      } else {
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw GatewayError.invalidArgument("Missing value for \(option)") }
        values[key, default: []].append(arguments[index + 1])
        index += 2
      }
    }
    options = values
  }
}
