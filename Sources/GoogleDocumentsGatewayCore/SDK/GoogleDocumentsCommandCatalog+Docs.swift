import GatewaySDKKit

extension GoogleDocumentsCatalog {
  static let docsReadCommands = ["document get"]
  static let docsWriteCommands = ["document batch-update", "document create"]

  static let docsRequired: [String: Set<String>] = [
    "document get": ["document-id"],
    "document batch-update": ["document-id"]
  ]

  static func docsReadOperations(tier: String, domain: String) -> [GatewayOperation] {
    operations(named: docsReadCommands, tier: tier, domain: domain)
  }

  static func docsWriteOperations(tier: String, domain: String) -> [GatewayOperation] {
    operations(named: docsWriteCommands, tier: tier, domain: domain)
  }
}
