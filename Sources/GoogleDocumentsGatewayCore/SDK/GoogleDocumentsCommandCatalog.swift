import GatewaySDKKit

extension GatewaySchemaCatalog {
  public static func googleDocuments(role: GatewayRole) -> GatewaySchemaCatalog {
    let tier = "\(role.service.rawValue)-\(role.accessMode.rawValue)"
    let operations = GoogleDocumentsCatalog.neutralOperations(tier: tier, domain: role.service.rawValue)
      + GoogleDocumentsCatalog.operations(for: role, tier: tier, domain: role.service.rawValue)
    let referenced = Set(operations.map(\.arguments).flatMap { $0 }.map { $0.type.namedTypeName })
    return GatewaySchemaCatalog(
      provider: "google-documents-gateway",
      tier: tier,
      operations: operations,
      types: GoogleDocumentsCatalog.namedTypes.filter { referenced.contains($0.name) }
    )
  }
}

enum GoogleDocumentsCatalog {
  static let namedTypes: [GatewayNamedType] = [
    .init(name: "SuggestionsViewMode", kind: .enumeration(["DEFAULT_FOR_CURRENT_ACCESS", "SUGGESTIONS_INLINE", "PREVIEW_SUGGESTIONS_ACCEPTED", "PREVIEW_WITHOUT_SUGGESTIONS"])),
    .init(name: "MajorDimension", kind: .enumeration(["ROWS", "COLUMNS"])),
    .init(name: "ValueInputOption", kind: .enumeration(["RAW", "USER_ENTERED"])),
    .init(name: "PermissionType", kind: .enumeration(["user", "group", "domain", "anyone"])),
    .init(name: "PermissionRole", kind: .enumeration(["reader", "commenter", "writer"]))
  ]

  /// State-changing and non-idempotent operations require destructive-operation approval.
  /// This inventory is also the source of truth for remote cancellation uncertainty.
  static let mutatingOperations: Set<String> = [
    "document create", "document batch-update", "spreadsheet create", "spreadsheet batch-update", "sheet copy-to",
    "values append", "values update", "values clear", "values batch-update", "values batch-clear",
    "values batch-clear-by-data-filter", "values batch-update-by-data-filter", "folders create", "files upload",
    "files replace-content", "files copy", "files rename", "files move", "files trash", "files untrash", "files delete",
    "permissions create", "permissions update", "permissions delete", "comments create", "comments update", "comments delete",
    "replies create", "replies update", "replies delete", "revisions update"
  ]

  static func neutralOperations(tier: String, domain: String) -> [GatewayOperation] {
    ["config validate", "auth status", "doctor"].map {
      GatewayOperation(
        name: $0,
        kind: .command,
        tier: tier,
        arguments: [.init(name: "credential", type: .named("String"), description: "Optional credential profile identifier.")],
        summary: "Gateway diagnostics command.",
        domain: domain
      )
    }
  }

  static func operations(for role: GatewayRole, tier: String, domain: String) -> [GatewayOperation] {
    switch (role.service, role.accessMode) {
    case (.docs, .read): docsReadOperations(tier: tier, domain: domain)
    case (.docs, .write): docsWriteOperations(tier: tier, domain: domain)
    case (.sheets, .read): sheetsReadOperations(tier: tier, domain: domain)
    case (.sheets, .write): sheetsWriteOperations(tier: tier, domain: domain)
    case (.drive, .read): driveReadOperations(tier: tier, domain: domain)
    case (.drive, .write): driveWriteOperations(tier: tier, domain: domain)
    }
  }

  static func operations(named names: [String], tier: String, domain: String) -> [GatewayOperation] {
    names.map { operation(named: $0, tier: tier, domain: domain) }
  }

  static func requiredArguments(for name: String) -> Set<String> {
    docsRequired[name] ?? sheetsRequired[name] ?? driveReadRequired[name] ?? driveWriteRequired[name] ?? []
  }

  static func operation(named name: String, tier: String, domain: String) -> GatewayOperation {
    let flags = GatewayCommandFlagInventory.allowedOptions[name, default: []].sorted()
    return GatewayOperation(
      name: name,
      kind: .command,
      tier: tier,
      arguments: flags.map { argument($0, required: requiredArguments(for: name).contains($0), command: name) },
      summary: "Runs \(name) for the selected Google \(domain) role.",
      isDestructive: mutatingOperations.contains(name),
      domain: domain
    )
  }

  static func argument(_ name: String, required: Bool = false, command: String = "") -> GatewayArgument {
    let base: GatewayTypeRef
    switch name {
    case "dry-run", "overwrite", "page-all", "acknowledge-broad-access", "acknowledge-permanent-delete", "confirm-clear", "keep-forever", "publish": base = .named("Boolean")
    case "page-size", "max-pages", "max-bytes", "sheet-id", "metadata-id": base = .named("Int")
    case "range" where command == "values batch-get": base = .list(.nonNull(.named("String")))
    case "json", "json-values": base = .named("JSON")
    case "suggestions-view-mode": base = .named("SuggestionsViewMode")
    case "major-dimension": base = .named("MajorDimension")
    case "value-input-option": base = .named("ValueInputOption")
    case "type": base = .named("PermissionType")
    case "role": base = .named("PermissionRole")
    default: base = .named("String")
    }
    let type = required ? GatewayTypeRef.nonNull(base) : base
    return GatewayArgument(name: name, type: type, isRequired: required, description: description(for: name, command: command, required: required))
  }

  static func description(for name: String, command: String, required: Bool) -> String {
    if let rule = commandRules["\(command)|\(name)"] { return rule }
    if name == "max-bytes" {
      return command == "files upload" || command == "files replace-content" ? "Non-negative, maximum 67108864 bytes." : "Non-negative byte limit."
    }
    if let description = argumentDescriptions[name] { return description }
    return required ? "Required --\(name) value for \(command)." : "Optional --\(name) value for \(command)."
  }

  static let argumentDescriptions: [String: String] = [
    "dry-run": "Plans without loading credentials or calling transport; request-body values are redacted.",
    "document-id": "Google Docs document identifier.", "spreadsheet-id": "Google Sheets spreadsheet identifier.",
    "destination-spreadsheet-id": "Destination Google Sheets spreadsheet identifier.",
    "sheet-id": "Numeric source sheet identifier.", "metadata-id": "Numeric developer metadata identifier.",
    "range": "A1 notation range.", "title": "Document or spreadsheet title.",
    "text": "Text used to build a supported document batch-update request.", "values": "Human-readable Sheets values input.",
    "input": "Drive upload content path; files upload and replace-content accept at most 67108864 bytes.",
    "input-file": "JSON request-body file path, limited to 2097152 bytes.", "json-file": "JSON request-body file path, limited to 2097152 bytes.",
    "file-id": "Google Drive file identifier.", "permission-id": "Google Drive permission identifier.",
    "comment-id": "Google Drive comment identifier.", "reply-id": "Google Drive reply identifier.",
    "revision-id": "Google Drive revision identifier.", "drive-id": "Google Drive shared-drive identifier.",
    "parent-id": "Optional Google Drive parent folder identifier.", "name": "Google Drive file or folder name.",
    "mime-type": "Google MIME type.", "expected-modified-time": "Expected remote Drive modifiedTime used by mutation preflight.",
    "expected-role": "Expected current Drive permission role used by mutation preflight.", "page-token": "Provider pagination token.",
    "query": "Provider search query.", "page-size": "Optional page size, 1...1000.", "max-pages": "Optional page limit, 1...100.",
    "page-all": "Fetches every available page up to max-pages.", "overwrite": "Permits replacement of an existing output path.",
    "confirm-range": "Required to exactly match range unless dry-run is set.",
    "confirm-spreadsheet-id": "Required to exactly match spreadsheet-id unless dry-run is set.",
    "confirm-clear": "Required for batch clear unless dry-run is set.",
    "suggestions-view-mode": "DEFAULT_FOR_CURRENT_ACCESS, SUGGESTIONS_INLINE, PREVIEW_SUGGESTIONS_ACCEPTED, or PREVIEW_WITHOUT_SUGGESTIONS.",
    "include-tabs-content": "String value true or false.", "json": "Inline JSON value.", "json-values": "Inline JSON value.",
    "add-parents": "At least one parent change is required.", "remove-parents": "At least one parent change is required.",
    "type": "Google Drive permission grantee type: user, group, domain, or anyone.",
    "role": "Google Drive permission role: reader, commenter, or writer.",
    "email": "Email address for a user or group permission grantee.", "domain": "Domain for a domain permission grantee.",
    "acknowledge-broad-access": "Explicit acknowledgement for domain or anyone permission access.",
    "output": "Local output file path.", "content": "Google Drive comment or reply content.",
    "action": "Google Drive reply action.", "keep-forever": "Retains a revision forever.", "publish": "Publishes a revision."
  ]

  static let commandRules: [String: String] = [
    "document create|title": "Exactly one of title, json, or json-file is required.",
    "document create|json": "Exactly one of title, json, or json-file is required; inline JSON object.",
    "document create|json-file": "Exactly one of title, json, or json-file is required; JSON file path.",
    "document batch-update|text": "Exactly one of text, json, or json-file is required.",
    "document batch-update|json": "Exactly one of text, json, or json-file is required; inline JSON object.",
    "document batch-update|json-file": "Exactly one of text, json, or json-file is required; JSON file path.",
    "values batch-get|range": "Repeatable range; supply at least one range.",
    "values append|values": "Exactly one of values, json-values, or input-file is required.",
    "values append|json-values": "Exactly one of values, json-values, or input-file is required; inline JSON rows.",
    "values append|input-file": "Exactly one of values, json-values, or input-file is required; JSON file path.",
    "values update|values": "Exactly one of values, json-values, or input-file is required.",
    "values update|json-values": "Exactly one of values, json-values, or input-file is required; inline JSON rows.",
    "values update|input-file": "Exactly one of values, json-values, or input-file is required; JSON file path.",
    "values append|major-dimension": "ROWS or COLUMNS; valid only with values or json-values.",
    "values update|major-dimension": "ROWS or COLUMNS; valid only with values or json-values.",
    "files copy|confirm-file-id": "Required and must exactly match file-id, including during dry-run.",
    "files replace-content|confirm-file-id": "Required and must exactly match file-id, including during dry-run.",
    "files rename|confirm-file-id": "Required and must exactly match file-id, including during dry-run.",
    "files move|confirm-file-id": "Required and must exactly match file-id, including during dry-run.",
    "files trash|confirm-file-id": "Required and must exactly match file-id, including during dry-run.",
    "files untrash|confirm-file-id": "Required and must exactly match file-id, including during dry-run.",
    "files delete|confirm-file-id": "Required and must exactly match file-id, including during dry-run.",
    "files delete|acknowledge-permanent-delete": "Required acknowledgement; permanent deletion bypasses trash.",
    "permissions create|email": "Required when type is user or group.",
    "permissions create|domain": "Required when type is domain; forbidden when type is anyone.",
    "permissions create|acknowledge-broad-access": "Required when type is domain or anyone.",
    "permissions update|confirm-permission-id": "Required and must exactly match permission-id.",
    "permissions delete|confirm-permission-id": "Required and must exactly match permission-id.",
    "comments update|confirm-comment-id": "Required and must exactly match comment-id.",
    "comments delete|confirm-comment-id": "Required and must exactly match comment-id.",
    "replies create|content": "At least one of content or action is required.",
    "replies create|action": "At least one of content or action is required; accepted action values are resolve or reopen.",
    "replies update|confirm-reply-id": "Required and must exactly match reply-id.",
    "replies delete|confirm-reply-id": "Required and must exactly match reply-id.",
    "revisions update|confirm-revision-id": "Required and must exactly match revision-id.",
    "revisions update|keep-forever": "At least one of keep-forever or publish is required.",
    "revisions update|publish": "At least one of keep-forever or publish is required.",
    "files download|output": "Required output path; it must not exist unless overwrite is set.",
    "files export|output": "Required output path; it must not exist unless overwrite is set.",
    "revisions download|output": "Required output path; it must not exist unless overwrite is set."
  ]
}
