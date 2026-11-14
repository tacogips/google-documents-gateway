import Testing
@testable import AppCore

@Test func sheetsReaderAndWriterScopesAreNotInterchangeable() throws {
  let writer = GatewayTokenStore(role: GatewayRole(service: .sheets, accessMode: .write), accessToken: "redacted", refreshToken: nil, expiresAt: nil)
  #expect(throws: GatewayError.scopeMismatch) { try writer.validates(role: GatewayRole(service: .sheets, accessMode: .read)) }
}
