import Foundation
import Testing
@testable import GoogleDocumentsGatewayCore

@Test func inlineSourceErrorsNameTheExactOverrideWithoutSecrets() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let role = GatewayRole(service: .docs, accessMode: .read)
  let jsonVariable = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON"
  let pathVariable = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_PATH"
  let incompatible = GatewayTokenStore(role: GatewayRole(service: .docs, accessMode: .write), accessToken: "secret-marker", refreshToken: nil, expiresAt: nil)
  let environment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "client",
    pathVariable: root.appendingPathComponent("token.json").path,
    jsonVariable: try #require(String(bytes: JSONEncoder().encode(incompatible), encoding: .utf8))
  ]
  let runner = GatewayCommandRunner(role: role, environment: environment)
  let login = runner.run(arguments: ["auth", "login"])
  #expect(login.exitCode == 2)
  #expect(login.stdout.contains(jsonVariable))
  #expect(login.stdout.contains(pathVariable))
  let read = runner.run(arguments: ["document", "get", "--document-id", "example"])
  #expect(read.exitCode == 4)
  #expect(read.stdout.contains("SCOPE_MISMATCH"))
  #expect(read.stdout.contains(jsonVariable))
  #expect(!read.stdout.contains("secret-marker"))
  #expect(!login.stdout.contains("secret-marker"))
}

@Test func missingSelectedTokenFileIsAnActionableAuthError() {
  let variable = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_PATH"
  let runner = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .read), environment: [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "client",
    variable: "/tmp/missing-docs-token-\(UUID().uuidString).json"
  ])
  let result = runner.run(arguments: ["document", "get", "--document-id", "example"])
  #expect(result.exitCode == 4)
  #expect(result.stdout.contains("AUTH_REQUIRED"))
  #expect(result.stdout.contains(variable))
  #expect(result.stdout.contains("ENVIRONMENT_PATH"))
}
