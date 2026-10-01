import Foundation

/// Missing private paths keep credential-free tests independent of host logins.
func isolatedCredentialTestEnvironment() -> [String: String] {
  let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("gateway-credential-test-" + UUID().uuidString)
  return ["XDG_CONFIG_HOME": root.appendingPathComponent("config").path,
          "XDG_STATE_HOME": root.appendingPathComponent("state").path]
}
