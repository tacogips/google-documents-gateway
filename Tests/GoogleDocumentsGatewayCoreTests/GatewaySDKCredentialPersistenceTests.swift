import Foundation
import GatewaySDKKit
import Testing
@testable import GoogleDocumentsGatewayCore

@Test func sdkFileBackedTokenPersistenceDoesNotWriteAfterCancellationWins() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let role = GatewayRole(service: .docs, accessMode: .read)
  let tokenURL = root.appendingPathComponent("token.json")
  let original = GatewayTokenStore(
    role: role, accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast
  )
  try GatewayTokenStoreFile.write(original, to: tokenURL)
  let originalBytes = try Data(contentsOf: tokenURL)
  let profile = try GatewayCredentialProfile(
    id: "fixture", role: role, clientID: "fixture-client", tokenStoreURL: tokenURL
  )
  let cancellation = GatewaySDKCancellation()
  let persistence = TokenStorePersistenceProbe()
  let refreshed = "{\"access_token\":\"fresh\",\"scope\":\"\(role.scope)\",\"expires_in\":3600}"
  let transport = TokenStoreRefreshTransport(
    response: .init(statusCode: 200, data: Data(refreshed.utf8), requestID: "refresh")
  )
  let authorizer = GatewaySDKPersistedAuthorizer(
    profile: profile, transport: transport, cancellation: cancellation, decoder: .live,
    tokenStorePersistenceObserver: persistence.pauseBeforePersistence
  )
  let task = Task.detached { Result { try authorizer.accessToken(for: role, cancellation: cancellation) } }
  let entered = await withCheckedContinuation { continuation in
    DispatchQueue.global().async { continuation.resume(returning: persistence.waitForEntry()) }
  }
  #expect(entered)
  #expect(cancellation.cancel())
  persistence.release()
  let result = await task.value
  switch result {
  case .success: Issue.record("Expected cancellation to prevent token-store persistence")
  case .failure: break
  }
  #expect(try Data(contentsOf: tokenURL) == originalBytes)
  #expect(transport.calls == 1)
}

@Test func sdkCancellationAfterCredentialPersistenceStopsDestructiveDispatch() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let role = GatewayRole(service: .drive, accessMode: .write)
  let tokenURL = root.appendingPathComponent("token.json")
  let original = GatewayTokenStore(
    role: role, accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast
  )
  try GatewayTokenStoreFile.write(original, to: tokenURL)
  let profile = try GatewayCredentialProfile(
    id: "fixture", role: role, clientID: "fixture-client", tokenStoreURL: tokenURL
  )
  let persistence = TokenStorePersistenceProbe()
  var persistenceReleased = false
  defer {
    if !persistenceReleased { persistence.releasePersistence() }
  }
  let refreshed = "{\"access_token\":\"fresh\",\"scope\":\"\(role.scope)\",\"expires_in\":3600}"
  let transport = SDKFixtureTransport(responses: [
    .init(statusCode: 200, data: Data(refreshed.utf8), requestID: "refresh")
  ])
  let sdk = GoogleDocumentsGatewaySDK(
    role: role, transport: transport, credentialProfile: profile, catalogFileSnapshotter: .live,
    fileAccessPolicy: .denyAll, executionPolicy: .init(timeout: 5, maximumConcurrentOperations: 1),
    tokenStorePersistenceCompletedObserver: persistence.pauseAfterPersistence
  )
  let task = Task {
    await sdk.invoke(.init(operation: "folders create", variables: ["name": .string("folder")]), environment: [:])
  }
  #expect(await gatewaySDKTestHandshake { persistence.waitForPersistence() })
  #expect(try GatewayTokenStoreFile.read(from: tokenURL, role: role).accessToken == "fresh")
  let cancellationCompleted = DispatchSemaphore(value: 0)
  let cancellationRequest = Task.detached {
    task.cancel()
    cancellationCompleted.signal()
  }
  let cancellationFinished = await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: cancellationCompleted.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success)
    }
  }
  #expect(cancellationFinished)
  persistence.releasePersistence()
  persistenceReleased = true
  await cancellationRequest.value
  let result = await task.value
  #expect(result.exitCode == 5)
  #expect(result.errors.first?.code == "TRANSPORT_FAILURE")
  #expect(result.errors.first?.message == "SDK execution was cancelled")
  #expect(transport.calls == 1)
}

@Test func sdkConcurrentFileBackedRefreshUsesOneProviderRefresh() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let role = GatewayRole(service: .docs, accessMode: .read)
  let tokenURL = root.appendingPathComponent("token.json")
  try GatewayTokenStoreFile.write(
    .init(role: role, accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast), to: tokenURL
  )
  let aliasRoot = root.appendingPathComponent("alias", isDirectory: true)
  #expect(aliasRoot.path.withCString { Darwin.symlink(root.path, $0) } == 0)
  let aliasTokenURL = aliasRoot.appendingPathComponent("token.json")
  let profile = try GatewayCredentialProfile(
    id: "fixture", role: role, clientID: "fixture-client", tokenStoreURL: tokenURL
  )
  let aliasProfile = try GatewayCredentialProfile(
    id: "fixture", role: role, clientID: "fixture-client", tokenStoreURL: aliasTokenURL
  )
  let decoded = TokenStoreDecodeProbe()
  let decoder = GatewaySDKCredentialDecoder(
    decodeInstalledClient: GatewaySDKCredentialDecoder.live.decodeInstalledClient,
    decodeTokenStore: { data in
      decoded.record()
      return try GatewaySDKCredentialDecoder.live.decodeTokenStore(data)
    }
  )
  let refreshed = "{\"access_token\":\"fresh\",\"scope\":\"\(role.scope)\",\"expires_in\":3600}"
  let transport = ConcurrentCredentialRefreshTransport(
    tokenResponse: .init(statusCode: 200, data: Data(refreshed.utf8), requestID: "refresh")
  )
  let sdk = GoogleDocumentsGatewaySDK(
    role: role, transport: transport, credentialProfile: profile, catalogFileSnapshotter: .live,
    fileAccessPolicy: .denyAll, executionPolicy: .init(timeout: 5, maximumConcurrentOperations: 2),
    credentialDecoder: decoder
  )
  let aliasSDK = GoogleDocumentsGatewaySDK(
    role: role, transport: transport, credentialProfile: aliasProfile, catalogFileSnapshotter: .live,
    fileAccessPolicy: .denyAll, executionPolicy: .init(timeout: 5, maximumConcurrentOperations: 2), credentialDecoder: decoder
  )
  let request = GatewayOperationRequest(operation: "document get", variables: ["document-id": .string("document")])
  let first = Task { await sdk.invoke(request, environment: [:]) }
  #expect(await gatewaySDKTestHandshake { transport.waitForRefresh() })
  let second = Task { await aliasSDK.invoke(request, environment: [:]) }
  #expect(await gatewaySDKTestHandshake { decoded.waitForReads(3) })
  transport.releaseRefresh()
  #expect((await first.value).exitCode == 0)
  #expect((await second.value).exitCode == 0)
  #expect(transport.refreshCalls == 1)
  #expect(transport.providerCalls == 2)
  #expect(try GatewayTokenStoreFile.read(from: tokenURL, role: role).accessToken == "fresh")
}

@Test func sdkCancelledSingleFlightRefreshWaiterReleasesLimiterCapacity() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let role = GatewayRole(service: .docs, accessMode: .read)
  let tokenURL = root.appendingPathComponent("token.json")
  try GatewayTokenStoreFile.write(
    .init(role: role, accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast), to: tokenURL
  )
  let profile = try GatewayCredentialProfile(
    id: "fixture", role: role, clientID: "fixture-client", tokenStoreURL: tokenURL
  )
  let refreshed = "{\"access_token\":\"fresh\",\"scope\":\"\(role.scope)\",\"expires_in\":3600}"
  let transport = ConcurrentCredentialRefreshTransport(
    tokenResponse: .init(statusCode: 200, data: Data(refreshed.utf8), requestID: "refresh")
  )
  var refreshReleased = false
  defer {
    if !refreshReleased { transport.releaseRefresh() }
  }
  let waiting = TokenStoreRefreshWaitProbe()
  let sdk = GoogleDocumentsGatewaySDK(
    role: role, transport: transport, credentialProfile: profile, catalogFileSnapshotter: .live,
    fileAccessPolicy: .denyAll, executionPolicy: .init(timeout: 5, maximumConcurrentOperations: 2),
    tokenStoreRefreshWaitObserver: waiting.recordWait
  )
  let request = GatewayOperationRequest(operation: "document get", variables: ["document-id": .string("document")])
  let first = Task { await sdk.invoke(request, environment: [:]) }
  #expect(await gatewaySDKTestHandshake { transport.waitForRefresh() })
  let waiter = Task { await sdk.invoke(request, environment: [:]) }
  #expect(await gatewaySDKTestHandshake { waiting.waitForWaiter() })
  waiter.cancel()
  #expect((await waiter.value).errors.first?.code == "TRANSPORT_FAILURE")
  let dryRun = await sdk.invoke(
    .init(operation: "document get", variables: ["document-id": .string("document"), "dry-run": .bool(true)]),
    environment: [:]
  )
  #expect(dryRun.exitCode == 0)
  #expect(transport.isRefreshBlocked)
  #expect(transport.refreshCalls == 1)
  transport.releaseRefresh()
  refreshReleased = true
  #expect((await first.value).exitCode == 0)
}
