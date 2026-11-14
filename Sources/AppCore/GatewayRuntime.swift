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
      let data = try jsonSource(options)
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
      let data = try inputFile(options)
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
      return try JSONSerialization.data(withJSONObject: ["name": try required("name", options), "mimeType": "application/vnd.google-apps.folder"], options: [.sortedKeys])
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
    if options["json"] != nil { return Data(sources[0].utf8) }
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

  private static func validateSheetsValues(_ object: [String: Any], batch: Bool) throws {
    let values = batch ? object["data"] : object["values"]
    guard let arrays = values as? [Any], !arrays.isEmpty else { throw GatewayError.invalidArgument("Sheets input must contain non-empty values") }
  }
}
