import Foundation

public enum GatewayRequestBuilder {
  public static func plan(
    role: GatewayRole,
    operation: String,
    options: [String: [String]]
  ) throws -> GatewayRequestPlan {
    guard GatewayCapabilityCatalog.commands(for: role).contains(operation) else {
      throw GatewayError.forbiddenCommand(operation)
    }
    switch role.service {
    case .docs:
      return try docsPlan(operation: operation, options: options)
    case .sheets:
      return try sheetsPlan(operation: operation, options: options)
    case .drive:
      return try drivePlan(operation: operation, options: options)
    }
  }

  private static func docsPlan(
    operation: String,
    options: [String: [String]]
  ) throws -> GatewayRequestPlan {
    switch operation {
    case "document get":
      let id = try required("document-id", options)
      let tabs = value("include-tabs-content", options) ?? "true"
      guard ["true", "false"].contains(tabs) else {
        throw GatewayError.invalidArgument("--include-tabs-content must be true or false")
      }
      var query = [("includeTabsContent", tabs)]
      if let suggestions = value("suggestions-view-mode", options) {
        let valid = Set([
          "DEFAULT_FOR_CURRENT_ACCESS",
          "SUGGESTIONS_INLINE",
          "PREVIEW_SUGGESTIONS_ACCEPTED",
          "PREVIEW_WITHOUT_SUGGESTIONS"
        ])
        guard valid.contains(suggestions) else {
          throw GatewayError.invalidArgument("Unsupported --suggestions-view-mode")
        }
        query.append(("suggestionsViewMode", suggestions))
      }
      return GatewayRequestPlan(
        operation: operation,
        method: "GET",
        path: "/v1/documents/\(pathPart(id))",
        query: query
      )
    case "document create":
      return GatewayRequestPlan(operation: operation, method: "POST", path: "/v1/documents")
    case "document batch-update":
      let id = try required("document-id", options)
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/v1/documents/\(pathPart(id)):batchUpdate"
      )
    default:
      throw GatewayError.forbiddenCommand(operation)
    }
  }

  private static func sheetsPlan(
    operation: String,
    options: [String: [String]]
  ) throws -> GatewayRequestPlan {
    let spreadsheetID = value("spreadsheet-id", options).map(pathPart)
    switch operation {
    case "spreadsheet get":
      return GatewayRequestPlan(
        operation: operation,
        method: "GET",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id"))",
        query: [("includeGridData", "false")]
      )
    case "spreadsheet get-by-data-filter":
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id")):getByDataFilter"
      )
    case "values get":
      return try sheetsValuesPlan(operation: operation, method: "GET", suffix: "", options: options)
    case "values batch-get":
      let ranges = options["range"] ?? []
      guard !ranges.isEmpty else { throw GatewayError.invalidArgument("At least one --range is required") }
      return GatewayRequestPlan(
        operation: operation,
        method: "GET",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id"))/values:batchGet",
        query: ranges.map { ("ranges", $0) }
      )
    case "values batch-get-by-data-filter":
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id"))/values:batchGetByDataFilter"
      )
    case "developer-metadata get":
      let metadataID = pathPart(try required("metadata-id", options))
      return GatewayRequestPlan(
        operation: operation,
        method: "GET",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id"))/developerMetadata/\(metadataID)"
      )
    case "developer-metadata search":
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id"))/developerMetadata:search"
      )
    case "spreadsheet create":
      return GatewayRequestPlan(operation: operation, method: "POST", path: "/v4/spreadsheets")
    case "spreadsheet batch-update":
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id")):batchUpdate"
      )
    case "sheet copy-to":
      let sheetID = pathPart(try required("sheet-id", options))
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id"))/sheets/\(sheetID):copyTo"
      )
    case "values append":
      return try sheetsValuesPlan(operation: operation, method: "POST", suffix: ":append", options: options)
    case "values update":
      return try sheetsValuesPlan(operation: operation, method: "PUT", suffix: "", options: options)
    case "values clear":
      return try sheetsValuesPlan(operation: operation, method: "POST", suffix: ":clear", options: options)
    case "values batch-update":
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id"))/values:batchUpdate"
      )
    case "values batch-clear":
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id"))/values:batchClear"
      )
    case "values batch-clear-by-data-filter":
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id"))/values:batchClearByDataFilter"
      )
    case "values batch-update-by-data-filter":
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/v4/spreadsheets/\(try spreadsheetID.required("spreadsheet-id"))/values:batchUpdateByDataFilter"
      )
    default:
      throw GatewayError.forbiddenCommand(operation)
    }
  }

  private static func sheetsValuesPlan(
    operation: String,
    method: String,
    suffix: String,
    options: [String: [String]]
  ) throws -> GatewayRequestPlan {
    let spreadsheetID = pathPart(try required("spreadsheet-id", options))
    let range = pathPart(try required("range", options))
    let query: [(String, String)]
    if ["values append", "values update"].contains(operation) {
      query = [("valueInputOption", value("value-input-option", options) ?? "RAW")]
    } else {
      query = []
    }
    return GatewayRequestPlan(
      operation: operation,
      method: method,
      path: "/v4/spreadsheets/\(spreadsheetID)/values/\(range)\(suffix)",
      query: query
    )
  }

  // This exhaustive provider-operation dispatcher is intentionally kept in one
  // place so every Drive path remains auditable against the capability catalog.
  // swiftlint:disable:next cyclomatic_complexity
  private static func drivePlan(
    operation: String,
    options: [String: [String]]
  ) throws -> GatewayRequestPlan {
    switch operation {
    case "about get":
      return GatewayRequestPlan(
        operation: operation,
        method: "GET",
        path: "/drive/v3/about",
        query: [("fields", "user,storageQuota,maxUploadSize,canCreateDrives,driveThemes,folderColorPalette")]
      )
    case "changes start-token":
      var query = [("supportsAllDrives", "true")]
      append("driveId", from: "drive-id", options: options, to: &query)
      return GatewayRequestPlan(operation: operation, method: "GET", path: "/drive/v3/changes/startPageToken", query: query)
    case "changes list":
      var query = [
        ("pageToken", try required("page-token", options)),
        ("pageSize", value("page-size", options) ?? "100"),
        ("supportsAllDrives", "true"),
        ("includeItemsFromAllDrives", "true"),
        ("fields", "nextPageToken,newStartPageToken,changes(changeType,time,removed,fileId,driveId,file(id,name,mimeType,modifiedTime,trashed,parents))")
      ]
      append("driveId", from: "drive-id", options: options, to: &query)
      return GatewayRequestPlan(operation: operation, method: "GET", path: "/drive/v3/changes", query: query)
    case "shared-drives list":
      var query = [
        ("pageSize", value("page-size", options) ?? "100"),
        ("fields", "nextPageToken,drives(id,name,createdTime,hidden,capabilities,restrictions)")
      ]
      append("pageToken", from: "page-token", options: options, to: &query)
      append("q", from: "query", options: options, to: &query)
      return GatewayRequestPlan(operation: operation, method: "GET", path: "/drive/v3/drives", query: query)
    case "shared-drives get":
      let driveID = pathPart(try required("drive-id", options))
      return GatewayRequestPlan(operation: operation, method: "GET", path: "/drive/v3/drives/\(driveID)")
    case "files list":
      var query = [
        ("q", value("query", options) ?? "trashed = false"),
        ("supportsAllDrives", "true"),
        ("includeItemsFromAllDrives", "true"),
        ("pageSize", value("page-size", options) ?? "100"),
        ("fields", "nextPageToken,files(id,name,mimeType,modifiedTime,size,parents,webViewLink)")
      ]
      append("pageToken", from: "page-token", options: options, to: &query)
      if let driveID = value("drive-id", options) {
        query.append(contentsOf: [("corpora", "drive"), ("driveId", driveID)])
      }
      return GatewayRequestPlan(operation: operation, method: "GET", path: "/drive/v3/files", query: query)
    case "files get":
      return try driveFilePlan(operation: operation, method: "GET", suffix: "", options: options)
    case "files download":
      return try driveFilePlan(
        operation: operation,
        method: "GET",
        suffix: "",
        options: options,
        query: [("alt", "media"), ("supportsAllDrives", "true")]
      )
    case "files export":
      return try driveFilePlan(
        operation: operation,
        method: "GET",
        suffix: "/export",
        options: options,
        query: [("mimeType", required("mime-type", options))]
      )
    case "permissions list":
      var query = [
        ("supportsAllDrives", "true"),
        ("pageSize", value("page-size", options) ?? "100"),
        ("fields", "nextPageToken,permissions(id,type,role,emailAddress,domain,displayName)")
      ]
      append("pageToken", from: "page-token", options: options, to: &query)
      return try drivePermissionPlan(operation: operation, method: "GET", options: options, query: query)
    case "permissions get":
      return try drivePermissionPlan(operation: operation, method: "GET", includePermissionID: true, options: options)
    case "comments list":
      return try driveNestedListPlan(
        operation: operation,
        resource: "comments",
        fields: "nextPageToken,comments(id,content,createdTime,modifiedTime,resolved,deleted,author,replies)",
        options: options
      )
    case "comments get":
      return try driveCommentPlan(operation: operation, method: "GET", includeCommentID: true, options: options)
    case "replies list":
      return try driveRepliesPlan(operation: operation, method: "GET", options: options, list: true)
    case "replies get":
      return try driveRepliesPlan(operation: operation, method: "GET", options: options, includeReplyID: true)
    case "revisions list":
      return try driveNestedListPlan(
        operation: operation,
        resource: "revisions",
        fields: "nextPageToken,revisions(id,mimeType,modifiedTime,size,keepForever,published,originalFilename)",
        options: options
      )
    case "revisions get":
      return try driveRevisionPlan(operation: operation, method: "GET", options: options)
    case "revisions download":
      return try driveRevisionPlan(
        operation: operation,
        method: "GET",
        options: options,
        query: [("alt", "media")]
      )
    case "folders create":
      return GatewayRequestPlan(operation: operation, method: "POST", path: "/drive/v3/files")
    case "files upload":
      return GatewayRequestPlan(
        operation: operation,
        method: "POST",
        path: "/upload/drive/v3/files",
        query: [("uploadType", "resumable")]
      )
    case "files replace-content":
      let fileID = pathPart(try required("file-id", options))
      return GatewayRequestPlan(
        operation: operation,
        method: "PATCH",
        path: "/upload/drive/v3/files/\(fileID)",
        query: [("uploadType", "resumable")]
      )
    case "files copy":
      return try driveFilePlan(operation: operation, method: "POST", suffix: "/copy", options: options)
    case "files rename":
      return try driveFilePlan(operation: operation, method: "PATCH", suffix: "", options: options)
    case "files move":
      var query = [("supportsAllDrives", "true")]
      append("addParents", from: "add-parents", options: options, to: &query)
      append("removeParents", from: "remove-parents", options: options, to: &query)
      return try driveFilePlan(operation: operation, method: "PATCH", suffix: "", options: options, query: query)
    case "files trash", "files untrash":
      return try driveFilePlan(operation: operation, method: "PATCH", suffix: "", options: options)
    case "permissions create":
      return try drivePermissionPlan(
        operation: operation,
        method: "POST",
        options: options,
        query: [("sendNotificationEmail", "true"), ("supportsAllDrives", "true")]
      )
    case "permissions update":
      return try drivePermissionPlan(operation: operation, method: "PATCH", includePermissionID: true, options: options)
    case "permissions delete":
      return try drivePermissionPlan(operation: operation, method: "DELETE", includePermissionID: true, options: options)
    case "comments create":
      return try driveCommentPlan(operation: operation, method: "POST", options: options)
    case "comments update":
      return try driveCommentPlan(operation: operation, method: "PATCH", includeCommentID: true, options: options)
    case "comments delete":
      return try driveCommentPlan(operation: operation, method: "DELETE", includeCommentID: true, options: options)
    case "replies create":
      return try driveRepliesPlan(operation: operation, method: "POST", options: options)
    case "replies update":
      return try driveRepliesPlan(operation: operation, method: "PATCH", options: options, includeReplyID: true)
    case "replies delete":
      return try driveRepliesPlan(operation: operation, method: "DELETE", options: options, includeReplyID: true)
    case "revisions update":
      return try driveRevisionPlan(operation: operation, method: "PATCH", options: options)
    default:
      throw GatewayError.forbiddenCommand(operation)
    }
  }

  private static func driveFilePlan(
    operation: String,
    method: String,
    suffix: String,
    options: [String: [String]],
    query: [(String, String)] = [("supportsAllDrives", "true")]
  ) throws -> GatewayRequestPlan {
    let fileID = pathPart(try required("file-id", options))
    return GatewayRequestPlan(
      operation: operation,
      method: method,
      path: "/drive/v3/files/\(fileID)\(suffix)",
      query: query
    )
  }

  private static func drivePermissionPlan(
    operation: String,
    method: String,
    includePermissionID: Bool = false,
    options: [String: [String]],
    query: [(String, String)] = [("supportsAllDrives", "true")]
  ) throws -> GatewayRequestPlan {
    let fileID = pathPart(try required("file-id", options))
    var path = "/drive/v3/files/\(fileID)/permissions"
    if includePermissionID {
      path += "/\(pathPart(try required("permission-id", options)))"
    }
    return GatewayRequestPlan(operation: operation, method: method, path: path, query: query)
  }

  private static func driveNestedListPlan(
    operation: String,
    resource: String,
    fields: String,
    options: [String: [String]]
  ) throws -> GatewayRequestPlan {
    let fileID = pathPart(try required("file-id", options))
    var query = [("pageSize", value("page-size", options) ?? "100"), ("fields", fields)]
    append("pageToken", from: "page-token", options: options, to: &query)
    return GatewayRequestPlan(
      operation: operation,
      method: "GET",
      path: "/drive/v3/files/\(fileID)/\(resource)",
      query: query
    )
  }

  private static func driveCommentPlan(
    operation: String,
    method: String,
    includeCommentID: Bool = false,
    options: [String: [String]]
  ) throws -> GatewayRequestPlan {
    let fileID = pathPart(try required("file-id", options))
    var path = "/drive/v3/files/\(fileID)/comments"
    if includeCommentID { path += "/\(pathPart(try required("comment-id", options)))" }
    let query = method == "DELETE" ? [] : [("fields", "id,content,createdTime,modifiedTime,resolved,deleted,author,replies")]
    return GatewayRequestPlan(operation: operation, method: method, path: path, query: query)
  }

  private static func driveRepliesPlan(
    operation: String,
    method: String,
    options: [String: [String]],
    list: Bool = false,
    includeReplyID: Bool = false
  ) throws -> GatewayRequestPlan {
    let fileID = pathPart(try required("file-id", options))
    let commentID = pathPart(try required("comment-id", options))
    var path = "/drive/v3/files/\(fileID)/comments/\(commentID)/replies"
    if includeReplyID { path += "/\(pathPart(try required("reply-id", options)))" }
    var query: [(String, String)] = []
    if list {
      query = [
        ("pageSize", value("page-size", options) ?? "100"),
        ("fields", "nextPageToken,replies(id,content,createdTime,modifiedTime,deleted,action,author)")
      ]
      append("pageToken", from: "page-token", options: options, to: &query)
    } else if method != "DELETE" {
      query = [("fields", "id,content,createdTime,modifiedTime,deleted,action,author")]
    }
    return GatewayRequestPlan(operation: operation, method: method, path: path, query: query)
  }

  private static func driveRevisionPlan(
    operation: String,
    method: String,
    options: [String: [String]],
    query: [(String, String)] = []
  ) throws -> GatewayRequestPlan {
    let fileID = pathPart(try required("file-id", options))
    let revisionID = pathPart(try required("revision-id", options))
    return GatewayRequestPlan(
      operation: operation,
      method: method,
      path: "/drive/v3/files/\(fileID)/revisions/\(revisionID)",
      query: query
    )
  }

  private static func value(_ name: String, _ options: [String: [String]]) -> String? {
    options[name]?.last?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func required(_ name: String, _ options: [String: [String]]) throws -> String {
    guard let candidate = value(name, options), !candidate.isEmpty else {
      throw GatewayError.invalidArgument("Missing required --\(name)")
    }
    return candidate
  }

  private static func pathPart(_ text: String) -> String {
    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
    return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
  }

  private static func append(
    _ queryName: String,
    from optionName: String,
    options: [String: [String]],
    to query: inout [(String, String)]
  ) {
    if let item = value(optionName, options) { query.append((queryName, item)) }
  }
}

private extension Optional where Wrapped == String {
  func required(_ option: String) throws -> String {
    guard let value = self, !value.isEmpty else {
      throw GatewayError.invalidArgument("Missing required --\(option)")
    }
    return value
  }
}
