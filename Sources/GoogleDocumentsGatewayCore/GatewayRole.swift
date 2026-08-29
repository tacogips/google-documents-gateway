import Foundation

public enum GatewayService: String, Sendable, CaseIterable, Codable {
  case docs
  case sheets
  case drive
}

public enum GatewayAccessMode: String, Sendable, CaseIterable, Codable {
  case read
  case write
}

public struct GatewayRole: Sendable, Equatable {
  public let service: GatewayService
  public let accessMode: GatewayAccessMode

  public init(service: GatewayService, accessMode: GatewayAccessMode) {
    self.service = service
    self.accessMode = accessMode
  }

  public var scope: String {
    switch (service, accessMode) {
    case (.docs, .read): "https://www.googleapis.com/auth/documents.readonly"
    case (.docs, .write): "https://www.googleapis.com/auth/documents"
    case (.sheets, .read): "https://www.googleapis.com/auth/spreadsheets.readonly"
    case (.sheets, .write): "https://www.googleapis.com/auth/spreadsheets"
    case (.drive, .read): "https://www.googleapis.com/auth/drive.readonly"
    case (.drive, .write): "https://www.googleapis.com/auth/drive.file"
    }
  }

  public var identifier: String {
    let role = accessMode == .read ? "reader" : "writer"
    return "\(service.rawValue)-\(role)"
  }
}

public enum GatewayError: Error, Equatable, Sendable {
  case invalidArgument(String)
  case forbiddenCommand(String)
  case authenticationRequired
  case grantInspectionFailed
  case scopeMismatch
  case inputTooLarge
  case transportFailure(String)
}

public struct GatewayRequestPlan: Sendable {
  public let operation: String
  public let method: String
  public let path: String
  public let query: [(String, String)]

  public init(operation: String, method: String, path: String, query: [(String, String)] = []) {
    self.operation = operation
    self.method = method
    self.path = path
    self.query = query
  }
}
