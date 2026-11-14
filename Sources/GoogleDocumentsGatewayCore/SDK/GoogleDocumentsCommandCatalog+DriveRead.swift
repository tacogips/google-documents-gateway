import GatewaySDKKit

extension GoogleDocumentsCatalog {
  static let driveReadCommands = [
    "about get", "changes list", "changes start-token", "comments get", "comments list", "files download",
    "files export", "files get", "files list", "permissions get", "permissions list", "replies get", "replies list",
    "revisions download", "revisions get", "revisions list", "shared-drives get", "shared-drives list"
  ]

  static let driveReadRequired: [String: Set<String>] = [
    "changes list": ["page-token"],
    "shared-drives get": ["drive-id"],
    "files get": ["file-id"],
    "files download": ["file-id", "output", "max-bytes"],
    "files export": ["file-id", "mime-type", "output", "max-bytes"],
    "permissions list": ["file-id"],
    "permissions get": ["file-id", "permission-id"],
    "comments list": ["file-id"],
    "comments get": ["file-id", "comment-id"],
    "replies list": ["file-id", "comment-id"],
    "replies get": ["file-id", "comment-id", "reply-id"],
    "revisions list": ["file-id"],
    "revisions get": ["file-id", "revision-id"],
    "revisions download": ["file-id", "revision-id", "output", "max-bytes"]
  ]

  static func driveReadOperations(tier: String, domain: String) -> [GatewayOperation] {
    operations(named: driveReadCommands, tier: tier, domain: domain)
  }
}
