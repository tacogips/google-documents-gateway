import GatewaySDKKit

extension GoogleDocumentsCatalog {
  static let sheetsReadCommands = [
    "developer-metadata get", "developer-metadata search", "spreadsheet get", "spreadsheet get-by-data-filter",
    "values batch-get", "values batch-get-by-data-filter", "values get"
  ]
  static let sheetsWriteCommands = [
    "sheet copy-to", "spreadsheet batch-update", "spreadsheet create", "values append", "values batch-clear",
    "values batch-clear-by-data-filter", "values batch-update", "values batch-update-by-data-filter", "values clear", "values update"
  ]

  static let sheetsRequired: [String: Set<String>] = [
    "spreadsheet get": ["spreadsheet-id"],
    "spreadsheet get-by-data-filter": ["spreadsheet-id", "input-file"],
    "spreadsheet create": ["title"],
    "sheet copy-to": ["spreadsheet-id", "sheet-id", "destination-spreadsheet-id"],
    "values get": ["spreadsheet-id", "range"],
    "values batch-get": ["spreadsheet-id", "range"],
    "values batch-get-by-data-filter": ["spreadsheet-id", "input-file"],
    "developer-metadata get": ["spreadsheet-id", "metadata-id"],
    "developer-metadata search": ["spreadsheet-id", "input-file"],
    "spreadsheet batch-update": ["spreadsheet-id", "input-file"],
    "values append": ["spreadsheet-id", "range"],
    "values update": ["spreadsheet-id", "range"],
    "values clear": ["spreadsheet-id", "range"],
    "values batch-update": ["spreadsheet-id", "input-file"],
    "values batch-clear": ["spreadsheet-id", "input-file"],
    "values batch-clear-by-data-filter": ["spreadsheet-id", "input-file"],
    "values batch-update-by-data-filter": ["spreadsheet-id", "input-file"]
  ]

  static func sheetsReadOperations(tier: String, domain: String) -> [GatewayOperation] {
    operations(named: sheetsReadCommands, tier: tier, domain: domain)
  }

  static func sheetsWriteOperations(tier: String, domain: String) -> [GatewayOperation] {
    operations(named: sheetsWriteCommands, tier: tier, domain: domain)
  }
}
