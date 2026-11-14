@preconcurrency import Foundation

public struct GatewayHTTPResponse: Sendable {
  public let statusCode: Int
  public let data: Data
  public let requestID: String?
  public let location: String?

  public init(statusCode: Int, data: Data, requestID: String?, location: String? = nil) {
    self.statusCode = statusCode
    self.data = data
    self.requestID = requestID
    self.location = location
  }
}

public protocol GatewayHTTPTransport: Sendable {
  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse
}

public final class URLSessionGatewayTransport: GatewayHTTPTransport, @unchecked Sendable {
  public init() {}

  public func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let semaphore = DispatchSemaphore(value: 0)
    let state = TransportState()
    URLSession.shared.dataTask(with: request) { data, response, error in
      state.complete(data: data, response: response, error: error)
      semaphore.signal()
    }.resume()
    semaphore.wait()
    if let error = state.error { throw error }
    guard let response = state.response as? HTTPURLResponse else {
      throw GatewayError.transportFailure("No HTTP response was returned")
    }
    return GatewayHTTPResponse(
      statusCode: response.statusCode,
      data: state.data ?? Data(),
      requestID: response.value(forHTTPHeaderField: "x-goog-request-id"),
      location: response.value(forHTTPHeaderField: "Location")
    )
  }
}

private final class TransportState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedData: Data?
  private var storedResponse: URLResponse?
  private var storedError: Error?

  var data: Data? { lock.withLock { storedData } }
  var response: URLResponse? { lock.withLock { storedResponse } }
  var error: Error? { lock.withLock { storedError } }

  func complete(data: Data?, response: URLResponse?, error: Error?) {
    lock.withLock {
      storedData = data
      storedResponse = response
      storedError = error
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () -> T) -> T {
    lock()
    defer { unlock() }
    return body()
  }
}

public protocol GatewayAuthorizing: Sendable {
  func accessToken(for role: GatewayRole) throws -> String
}

public struct PersistedTokenAuthorizer: GatewayAuthorizing {
  public let profile: GatewayCredentialProfile
  public let oauthClient: GatewayOAuthClient

  public init(profile: GatewayCredentialProfile, transport: GatewayHTTPTransport = URLSessionGatewayTransport()) {
    self.profile = profile
    oauthClient = GatewayOAuthClient(profile: profile, transport: transport)
  }

  public func accessToken(for role: GatewayRole) throws -> String {
    guard role == profile.role else { throw GatewayError.scopeMismatch }
    let store = try loadStore(role: role)
    guard !store.accessToken.isEmpty else { throw GatewayError.authenticationRequired }
    if let expiresAt = store.expiresAt, expiresAt <= Date().addingTimeInterval(60) {
      let refreshed = try oauthClient.refresh(store)
      if profile.tokenStoreJSON == nil {
        try GatewayTokenStoreFile.write(refreshed, to: profile.tokenStoreURL)
      }
      return refreshed.accessToken
    }
    return store.accessToken
  }

  private func loadStore(role: GatewayRole) throws -> GatewayTokenStore {
    if let tokenStoreJSON = profile.tokenStoreJSON {
      return try GatewayTokenStoreFile.read(json: tokenStoreJSON, role: role)
    }
    return try GatewayTokenStoreFile.read(from: profile.tokenStoreURL, role: role)
  }
}

public struct MissingCredentialAuthorizer: GatewayAuthorizing {
  public init() {}
  public func accessToken(for role: GatewayRole) throws -> String { throw GatewayError.authenticationRequired }
}

public struct EnvironmentGrantAuthorizer: GatewayAuthorizing {
  public let environment: [String: String]
  public let transport: GatewayHTTPTransport

  public init(environment: [String: String] = ProcessInfo.processInfo.environment, transport: GatewayHTTPTransport = URLSessionGatewayTransport()) {
    self.environment = environment
    self.transport = transport
  }

  public func accessToken(for role: GatewayRole) throws -> String {
    guard let token = environment["DOCUMENT_GATEWAY_ACCESS_TOKEN"], !token.isEmpty else {
      throw GatewayError.authenticationRequired
    }
    guard let url = URL(string: "https://oauth2.googleapis.com/tokeninfo") else { throw GatewayError.authenticationRequired }
    let response = try transport.send(url: url, method: "GET", headers: ["Authorization": "Bearer \(token)"], body: nil)
    guard (200...299).contains(response.statusCode),
          let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any],
          let scopeText = object["scope"] as? String
    else {
      throw GatewayError.grantInspectionFailed
    }
    let granted = Set(scopeText.split(separator: " ").map(String.init))
    guard granted == Set([role.scope]) else { throw GatewayError.scopeMismatch }
    return token
  }
}

public enum GatewayInputValidator {
  public static let maximumBodyBytes = 2 * 1024 * 1024
  public static let maximumDriveUploadBytes = 64 * 1024 * 1024

  // Request-body construction mirrors the audited provider command catalog.
  // Keeping its exhaustive cases together makes unsupported variants fail closed.
  // swiftlint:disable:next cyclomatic_complexity
  public static func body(for role: GatewayRole, command: String, options: [String: [String]]) throws -> Data? {
    switch (role.service, command) {
    case (.docs, "document create"), (.docs, "document batch-update"):
      let data: Data
      if command == "document create", let title = options["title"]?.last {
        data = try GatewayReadableInput.documentCreateBody(title: title)
      } else if command == "document batch-update", let text = options["text"]?.last {
        data = try GatewayReadableInput.documentAppendBody(text: text)
      } else {
        data = try jsonSource(options)
      }
      let object = try object(data)
      if command == "document create" {
        guard Set(object.keys) == ["title"], let title = object["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw GatewayError.invalidArgument("Document create JSON must contain only a non-empty title")
        }
      } else {
        guard let requests = object["requests"] as? [[String: Any]], !requests.isEmpty else {
          throw GatewayError.invalidArgument("Document batch-update JSON requires a non-empty requests array")
        }
        guard requests.allSatisfy({
          $0.keys.count == 1 && Set($0.keys).isSubset(of: GatewayCapabilityCatalog.docsBatchUpdateRequests)
        }) else {
          throw GatewayError.invalidArgument("Document batch-update contains an unsupported request variant")
        }
      }
      return data
    case (.sheets, "spreadsheet get-by-data-filter"),
         (.sheets, "values batch-get-by-data-filter"),
         (.sheets, "developer-metadata search"):
      let data = try inputFile(options)
      let input = try object(data)
      guard let filters = input["dataFilters"] as? [Any], !filters.isEmpty else {
        throw GatewayError.invalidArgument("Data-filter input requires a non-empty dataFilters array")
      }
      return data
    case (.sheets, "spreadsheet create"):
      let title = try required("title", options)
      return try JSONSerialization.data(withJSONObject: ["properties": ["title": title]], options: [.sortedKeys])
    case (.sheets, "spreadsheet batch-update"):
      let data = try inputFile(options)
      let input = try object(data)
      guard
        let requests = input["requests"] as? [[String: Any]],
        !requests.isEmpty,
        requests.allSatisfy({
          $0.keys.count == 1 && Set($0.keys).isSubset(of: GatewayCapabilityCatalog.sheetsBatchUpdateRequests)
        })
      else {
        throw GatewayError.invalidArgument("Spreadsheet batch-update requires supported request variants")
      }
      return data
    case (.sheets, "sheet copy-to"):
      return try JSONSerialization.data(
        withJSONObject: ["destinationSpreadsheetId": try required("destination-spreadsheet-id", options)],
        options: [.sortedKeys]
      )
    case (.sheets, "values append"), (.sheets, "values update"):
      let data: Data
      if options["values"] != nil || options["json-values"] != nil {
        data = try GatewayReadableInput.sheetsValuesBody(options)
      } else {
        data = try inputFile(options)
      }
      let object = try object(data)
      try validateSheetsValues(object, batch: false)
      return data
    case (.sheets, "values batch-update"), (.sheets, "values batch-update-by-data-filter"):
      let data = try inputFile(options)
      var input = try object(data)
      try validateSheetsValues(input, batch: true)
      input["valueInputOption"] = options["value-input-option"]?.last ?? input["valueInputOption"] ?? "RAW"
      return try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
    case (.sheets, "values batch-clear"):
      let data = try inputFile(options)
      let input = try object(data)
      guard let ranges = input["ranges"] as? [String], !ranges.isEmpty else {
        throw GatewayError.invalidArgument("Batch clear requires a non-empty ranges array")
      }
      return data
    case (.sheets, "values batch-clear-by-data-filter"):
      let data = try inputFile(options)
      let input = try object(data)
      guard let filters = input["dataFilters"] as? [Any], !filters.isEmpty else {
        throw GatewayError.invalidArgument("Batch clear requires a non-empty dataFilters array")
      }
      return data
    case (.drive, "folders create"):
      var body: [String: Any] = ["name": try required("name", options), "mimeType": "application/vnd.google-apps.folder"]
      if let parent = options["parent-id"]?.last { body["parents"] = [try nonEmpty("parent-id", parent)] }
      return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    case (.drive, "files rename"):
      return try JSONSerialization.data(withJSONObject: ["name": try required("name", options)], options: [.sortedKeys])
    case (.drive, "files copy"):
      var body: [String: Any] = [:]
      if let name = options["name"]?.last { body["name"] = name }
      if let parent = options["parent-id"]?.last { body["parents"] = [parent] }
      return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    case (.drive, "files trash"):
      return Data("{\"trashed\":true}".utf8)
    case (.drive, "files untrash"):
      return Data("{\"trashed\":false}".utf8)
    case (.drive, "files upload"), (.drive, "files replace-content"):
      guard
        let maximum = options["max-bytes"]?.last.flatMap(Int.init),
        (0...maximumDriveUploadBytes).contains(maximum)
      else {
        throw GatewayError.invalidArgument("Drive uploads require --max-bytes between 0 and 67108864")
      }
      return try read(path: required("input", options), maximumBytes: maximum)
    case (.drive, "permissions create"):
      var body: [String: Any] = ["type": try required("type", options), "role": try required("role", options)]
      if let email = options["email"]?.last { body["emailAddress"] = email }
      if let domain = options["domain"]?.last { body["domain"] = domain }
      return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    case (.drive, "permissions update"):
      return try JSONSerialization.data(withJSONObject: ["role": try required("role", options)], options: [.sortedKeys])
    case (.drive, "comments create"), (.drive, "comments update"):
      return try JSONSerialization.data(
        withJSONObject: ["content": try required("content", options)],
        options: [.sortedKeys]
      )
    case (.drive, "replies create"):
      var body: [String: Any] = [:]
      if let content = options["content"]?.last { body["content"] = content }
      if let action = options["action"]?.last { body["action"] = action }
      return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    case (.drive, "replies update"):
      return try JSONSerialization.data(
        withJSONObject: ["content": try required("content", options)],
        options: [.sortedKeys]
      )
    case (.drive, "revisions update"):
      var body: [String: Any] = [:]
      if options["keep-forever"] != nil { body["keepForever"] = true }
      if options["publish"] != nil { body["published"] = true }
      return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    default:
      return nil
    }
  }

  private static func jsonSource(_ options: [String: [String]]) throws -> Data {
    let sources = [options["json"]?.last, options["json-file"]?.last].compactMap { $0 }
    guard sources.count == 1 else { throw GatewayError.invalidArgument("Specify exactly one of --json or --json-file") }
    if options["json"] != nil {
      let data = Data(sources[0].utf8)
      guard data.count <= maximumBodyBytes else { throw GatewayError.inputTooLarge }
      return data
    }
    return try read(path: sources[0])
  }

  private static func inputFile(_ options: [String: [String]], option: String = "input-file") throws -> Data {
    try read(path: required(option, options))
  }

  private static func read(path: String, maximumBytes: Int = maximumBodyBytes) throws -> Data {
    let data: Data
    if path == "-" {
      data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
      guard FileManager.default.fileExists(atPath: path) else { throw GatewayError.invalidArgument("Input file does not exist") }
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    }
    guard data.count <= maximumBytes else { throw GatewayError.inputTooLarge }
    return data
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let result = try? JSONSerialization.jsonObject(with: data), let object = result as? [String: Any] else {
      throw GatewayError.invalidArgument("Input must be a JSON object")
    }
    return object
  }

  private static func required(_ name: String, _ options: [String: [String]]) throws -> String {
    guard let value = options[name]?.last?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      throw GatewayError.invalidArgument("Missing required --\(name)")
    }
    return value
  }

  private static func nonEmpty(_ name: String, _ value: String) throws -> String {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GatewayError.invalidArgument("Missing required --\(name)")
    }
    return value
  }

  private static func validateSheetsValues(_ object: [String: Any], batch: Bool) throws {
    let values = batch ? object["data"] : object["values"]
    guard let arrays = values as? [Any], !arrays.isEmpty else { throw GatewayError.invalidArgument("Sheets input must contain non-empty values") }
  }
}

enum GatewayReadableInput {
  static func selectExactlyOne(_ options: [String: [String]], names: [String]) throws {
    for name in names where (options[name]?.count ?? 0) > 1 {
      throw GatewayError.invalidArgument("--\(name) may only be specified once")
    }
    let selected = names.filter { options[$0] != nil }
    guard selected.count == 1 else {
      throw GatewayError.invalidArgument("Specify exactly one of \(names.map { "--\($0)" }.joined(separator: ", "))")
    }
  }

  static func documentCreateBody(title: String) throws -> Data {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw GatewayError.invalidArgument("--title must not be empty")
    }
    return try encodedBody(["title": title])
  }

  static func documentAppendBody(text: String) throws -> Data {
    guard !text.unicodeScalars.isEmpty else {
      throw GatewayError.invalidArgument("--text must contain at least one Unicode scalar")
    }
    return try encodedBody([
      "requests": [[
        "insertText": [
          "endOfSegmentLocation": ["segmentId": ""],
          "text": text
        ]
      ]]
    ])
  }

  static func sheetsValuesBody(_ options: [String: [String]]) throws -> Data {
    try selectExactlyOne(options, names: ["values", "json-values", "input-file"])
    let values: [Any]
    if let row = options["values"]?.last {
      values = [row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)]
    } else if let json = options["json-values"]?.last {
      values = try jsonRows(json)
    } else {
      throw GatewayError.invalidArgument("Specify --values or --json-values")
    }
    let range = try required("range", options)
    let dimension = options["major-dimension"]?.last ?? "ROWS"
    guard ["ROWS", "COLUMNS"].contains(dimension) else {
      throw GatewayError.invalidArgument("--major-dimension must be ROWS or COLUMNS")
    }
    return try encodedBody(["range": range, "majorDimension": dimension, "values": values])
  }

  static func validateDriveUploadMetadata(_ options: [String: [String]]) throws {
    _ = try driveUploadMetadata(options)
  }

  static func driveUploadMetadata(_ options: [String: [String]]) throws -> [String: Any] {
    let input = try required("input", options)
    let name = try uploadName(input: input, explicitName: options["name"]?.last)
    let mimeType = try resolvedMIMEType(input: input, explicitType: options["mime-type"]?.last)
    var metadata: [String: Any] = ["name": name, "mimeType": mimeType]
    if let parent = options["parent-id"]?.last {
      guard !parent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw GatewayError.invalidArgument("--parent-id must not be empty")
      }
      metadata["parents"] = [parent]
    }
    return metadata
  }

  static func resolvedMIMEType(input: String, explicitType: String?) throws -> String {
    if let explicitType {
      guard isValidMediaType(explicitType) else {
        throw GatewayError.invalidArgument("--mime-type must be a media type without parameters or control characters")
      }
      return explicitType
    }
    let extensionName = URL(fileURLWithPath: input).pathExtension.lowercased()
    return mimeTypes[extensionName] ?? "application/octet-stream"
  }

  private static func uploadName(input: String, explicitName: String?) throws -> String {
    let name = explicitName ?? URL(fileURLWithPath: input).lastPathComponent
    guard name != "/",
          !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw GatewayError.invalidArgument("Upload name must be non-empty and contain no control characters")
    }
    return name
  }

  private static func jsonRows(_ source: String) throws -> [Any] {
    guard let decoded = try? JSONSerialization.jsonObject(with: Data(source.utf8)), let items = decoded as? [Any], !items.isEmpty else {
      throw GatewayError.invalidArgument("--json-values must be a non-empty JSON row or array of rows")
    }
    if items.allSatisfy(isScalar) { return [items] }
    guard items.allSatisfy({ row in
      guard let cells = row as? [Any], !cells.isEmpty else { return false }
      return cells.allSatisfy(isScalar)
    }) else {
      throw GatewayError.invalidArgument("--json-values rows may contain only strings, finite numbers, booleans, or null")
    }
    return items
  }

  private static func isScalar(_ value: Any) -> Bool {
    if value is String || value is NSNull { return true }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return true }
      return number.doubleValue.isFinite
    }
    return false
  }

  private static func isValidMediaType(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
    return parts.allSatisfy { part in
      part.utf8.allSatisfy { byte in
        (byte >= 65 && byte <= 90) ||
          (byte >= 97 && byte <= 122) ||
          (byte >= 48 && byte <= 57) ||
          "!#$%&'*+-.^_`|~".utf8.contains(byte)
      }
    }
  }

  private static func encodedBody(_ object: [String: Any]) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard data.count <= GatewayInputValidator.maximumBodyBytes else { throw GatewayError.inputTooLarge }
    return data
  }

  private static let mimeTypes = [
    "txt": "text/plain", "text": "text/plain", "md": "text/markdown", "csv": "text/csv",
    "json": "application/json", "pdf": "application/pdf", "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "ppt": "application/vnd.ms-powerpoint",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "odt": "application/vnd.oasis.opendocument.text",
    "ods": "application/vnd.oasis.opendocument.spreadsheet",
    "odp": "application/vnd.oasis.opendocument.presentation",
    "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
    "mp3": "audio/mpeg", "wav": "audio/wav", "mp4": "video/mp4", "mov": "video/quicktime",
    "zip": "application/zip", "gz": "application/gzip", "tar": "application/x-tar"
  ]

  private static func required(_ name: String, _ options: [String: [String]]) throws -> String {
    guard let value = options[name]?.last?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      throw GatewayError.invalidArgument("Missing required --\(name)")
    }
    return value
  }
}
