import GatewaySDKKit

extension GoogleDocumentsCatalog {
  static let driveWriteCommands = [
    "comments create", "comments delete", "comments update", "files copy", "files delete", "files move", "files rename",
    "files replace-content", "files trash", "files untrash", "files upload", "folders create", "permissions create",
    "permissions delete", "permissions update", "replies create", "replies delete", "replies update", "revisions update"
  ]

  static let driveWriteRequired: [String: Set<String>] = [
    "folders create": ["name"],
    "files upload": ["input", "max-bytes"],
    "files copy": ["file-id", "confirm-file-id"],
    "files replace-content": ["file-id", "confirm-file-id", "expected-modified-time", "input", "max-bytes"],
    "files rename": ["file-id", "confirm-file-id", "expected-modified-time", "name"],
    "files move": ["file-id", "confirm-file-id", "expected-modified-time"],
    "files trash": ["file-id", "confirm-file-id", "expected-modified-time"],
    "files untrash": ["file-id", "confirm-file-id", "expected-modified-time"],
    "files delete": ["file-id", "confirm-file-id", "expected-modified-time", "acknowledge-permanent-delete"],
    "permissions create": ["file-id", "type", "role"],
    "permissions update": ["file-id", "permission-id", "confirm-permission-id", "expected-role", "role"],
    "permissions delete": ["file-id", "permission-id", "confirm-permission-id", "expected-role"],
    "comments create": ["file-id", "content"],
    "comments update": ["file-id", "comment-id", "confirm-comment-id", "content"],
    "comments delete": ["file-id", "comment-id", "confirm-comment-id"],
    "replies create": ["file-id", "comment-id"],
    "replies update": ["file-id", "comment-id", "reply-id", "confirm-reply-id", "content"],
    "replies delete": ["file-id", "comment-id", "reply-id", "confirm-reply-id"],
    "revisions update": ["file-id", "revision-id", "confirm-revision-id"]
  ]

  static func driveWriteOperations(tier: String, domain: String) -> [GatewayOperation] {
    operations(named: driveWriteCommands, tier: tier, domain: domain)
  }
}
