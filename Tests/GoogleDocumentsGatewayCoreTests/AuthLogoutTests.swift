import Foundation
import Testing
@testable import GoogleDocumentsGatewayCore

private struct LogoutNoNetwork: GatewayHTTPTransport {
  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    Issue.record("Logout must not contact the provider")
    throw GatewayError.authenticationRequired
  }
}

@Test func allDocumentRolesLogoutLocallyAndRemainLoggedOut() throws {
  for service in GatewayService.allCases {
    for mode in GatewayAccessMode.allCases {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: root) }
      let role = GatewayRole(service: service, accessMode: mode)
      let env = ["XDG_STATE_HOME": root.appendingPathComponent("state").path,
                 "XDG_CONFIG_HOME": root.appendingPathComponent("config").path]
      let profile = try GatewayCredentialProfileLoader.load(role: role, environment: env, allowMissingClient: true)
      try GatewayTokenStoreFile.write(GatewayTokenStore(role: role, accessToken: "local-fixture", refreshToken: nil, expiresAt: nil), to: profile.tokenStoreURL)
      let runner = GatewayCommandRunner(role: role, transport: LogoutNoNetwork(), environment: env)
      let first = runner.run(arguments: ["auth", "logout"])
      #expect(first.exitCode == 0)
      #expect(first.stdout.contains("LOGGED_OUT"))
      #expect(!FileManager.default.fileExists(atPath: profile.tokenStoreURL.path))
      #expect(runner.run(arguments: ["auth", "logout"]).exitCode == 0)
      try GatewayTokenStoreFile.migrateLegacyStoreIfNeeded(profile: profile)
      #expect(!FileManager.default.fileExists(atPath: profile.tokenStoreURL.path))
    }
  }
}

@Test func allDocumentRolesPreserveExternalJSONAndPathOnLogout() throws {
  for service in GatewayService.allCases {
    for mode in GatewayAccessMode.allCases {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: root) }
      let path = root.appendingPathComponent("external.json")
      let original = Data("external-fixture".utf8)
      try original.write(to: path)
      let prefix = "GOOGLE_\(service.rawValue.uppercased())_GATEWAY_"
      let role = GatewayRole(service: service, accessMode: mode)
      for env in [[prefix + "TOKEN_STORE_PATH": path.path], [prefix + "TOKEN_STORE_JSON": "external-inline-fixture"],
                  [prefix + "ACCESS_TOKEN": "external-direct-fixture"]] {
        let result = GatewayCommandRunner(role: role, transport: LogoutNoNetwork(), environment: env).run(arguments: ["auth", "logout"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("EXTERNAL_CREDENTIAL_PRESERVED"))
        #expect(try Data(contentsOf: path) == original)
      }
    }
  }
}
