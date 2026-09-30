import Foundation
import GatewaySDKKit
import Testing
@testable import GoogleDocumentsGatewayCore

@Test func sdkBoundsInlineCredentialJSONAndReleasesExecutionCapacity() async throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let prefix = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_"; let validationDocument = try rawSDKDocument(["config", "validate"])
  let exactSecret = paddedCredentialJSON("{\"installed\":{\"client_id\":\"fixture\"}}")
  let tokenData = try JSONEncoder().encode(GatewayTokenStore(role: role, accessToken: "fixture", refreshToken: nil, expiresAt: nil))
  let exactToken = paddedCredentialJSON(try #require(String(data: tokenData, encoding: .utf8)))
  let boundaryTransport = SDKCredentialFixtureTransport()
  let boundarySDK = GoogleDocumentsGatewaySDK(role: role, transport: boundaryTransport)
  #expect((await boundarySDK.execute(document: validationDocument, variables: [:], environment: [prefix + "OAUTH_CLIENT_SECRET_JSON": exactSecret])).exitCode == 4)
  let boundaryEnvironment = [prefix + "OAUTH_CLIENT_ID": "fixture-client", prefix + "TOKEN_STORE_JSON": exactToken]
  #expect((await boundarySDK.invoke(.init(operation: "document get", variables: ["document-id": .string("document")]), environment: boundaryEnvironment)).exitCode == 0)
  #expect(boundaryTransport.calls == 1)
  let request = GatewayOperationRequest(operation: "document get", variables: ["document-id": .string("document")])
  let limitedTransport = SDKCredentialFixtureTransport()
  let limitedSDK = GoogleDocumentsGatewaySDK(role: role, transport: limitedTransport, executionPolicy: .init(timeout: 1, maximumConcurrentOperations: 1))
  for oversizedJSON in [String(repeating: "x", count: GatewayInputValidator.maximumBodyBytes + 1), String(repeating: " ", count: GatewayInputValidator.maximumBodyBytes + 1)] {
    for environment in [[prefix + "OAUTH_CLIENT_SECRET_JSON": oversizedJSON], [prefix + "OAUTH_CLIENT_ID": "fixture-client", prefix + "TOKEN_STORE_JSON": oversizedJSON]] {
      let result = await limitedSDK.invoke(request, environment: environment)
      #expect(result.exitCode == 2)
      #expect(result.errors.first?.code == "INPUT_TOO_LARGE")
    }
  }
  let oversizedClientID = String(repeating: "x", count: GatewaySDKCredentialProfileLoader.maximumFieldBytes + 1)
  let oversizedClient = await limitedSDK.invoke(request, environment: [prefix + "OAUTH_CLIENT_ID": oversizedClientID, prefix + "TOKEN_STORE_JSON": try #require(String(data: tokenData, encoding: .utf8))])
  #expect(oversizedClient.exitCode == 2); #expect(oversizedClient.errors.first?.code == "INPUT_TOO_LARGE"); #expect(limitedTransport.calls == 0)
  let followUp = await limitedSDK.invoke(request, environment: [prefix + "OAUTH_CLIENT_ID": "fixture-client", prefix + "TOKEN_STORE_JSON": try #require(String(data: tokenData, encoding: .utf8))])
  #expect(followUp.exitCode == 0); #expect(followUp.errors.isEmpty); #expect(limitedTransport.calls == 1)
  for blocksTokenStore in [false, true] {
    let probe = InlineCredentialDecodeProbe()
    let decoder = GatewaySDKCredentialDecoder(
      decodeInstalledClient: { data in blocksTokenStore ? try JSONDecoder().decode(SDKInstalledClientFile.self, from: data) : try probe.block { try JSONDecoder().decode(SDKInstalledClientFile.self, from: data) } },
      decodeTokenStore: { data in !blocksTokenStore ? try JSONDecoder().decode(GatewayTokenStore.self, from: data) : try probe.block { try JSONDecoder().decode(GatewayTokenStore.self, from: data) } }
    )
    let transport = SDKCredentialFixtureTransport()
    let timedSDK = GoogleDocumentsGatewaySDK(
      role: role, transport: transport, catalogFileSnapshotter: .live,
      // Allow decoder entry under full-suite scheduling before testing its blocked deadline.
      executionPolicy: .init(timeout: 1, maximumConcurrentOperations: 1), credentialDecoder: decoder
    )
    let tokenData = try JSONEncoder().encode(GatewayTokenStore(role: role, accessToken: "fixture", refreshToken: "refresh", expiresAt: .distantPast))
    let tokenJSON = try #require(String(data: tokenData, encoding: .utf8))
    var environment = [prefix + "TOKEN_STORE_JSON": tokenJSON]
    environment[blocksTokenStore ? prefix + "OAUTH_CLIENT_ID" : prefix + "OAUTH_CLIENT_SECRET_JSON"] = blocksTokenStore ? "fixture-client" : "{\"installed\":{\"client_id\":\"fixture\"}}"
    let task = Task { await timedSDK.invoke(.init(operation: "document get", variables: ["document-id": .string("document")]), environment: environment) }
    #expect(await gatewaySDKTestHandshake { probe.waitForDecode() })
    let timedOut = await task.value
    #expect(timedOut.exitCode == 5)
    probe.release(); #expect(await gatewaySDKTestHandshake { probe.waitForCompletion() }); try await Task.sleep(nanoseconds: 5_000_000); #expect(transport.calls == 0)
    let available = await timedSDK.execute(document: validationDocument, variables: [:], environment: [prefix + "OAUTH_CLIENT_ID": "fixture-client"])
    #expect(available.exitCode == 4)
  }
}
