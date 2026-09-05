import Foundation
import GatewaySDKKit
import Testing
@testable import GoogleDocumentsGatewayCore

private final class SnapshotCleanupReplacementProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var snapshotPath: String?
  private var replaced = false

  func record(_ path: String) { lock.withLock { snapshotPath = path } }

  func replaceWithDirectory() throws {
    let path = try lock.withLock { () throws -> String in
      guard let snapshotPath else { throw GatewayError.invalidArgument("Missing catalog snapshot") }
      guard !replaced else { return snapshotPath }
      replaced = true
      return snapshotPath
    }
    try FileManager.default.removeItem(atPath: path)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
  }
}

private final class SnapshotCleanupReplacementTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let replacement: SnapshotCleanupReplacementProbe
  private let response: GatewayHTTPResponse
  private let failure: GatewayError?
  private var callCount = 0

  init(
    replacement: SnapshotCleanupReplacementProbe,
    response: GatewayHTTPResponse = .init(statusCode: 200, data: Data("{}".utf8), requestID: "fixture"),
    failure: GatewayError? = nil
  ) {
    self.replacement = replacement
    self.response = response
    self.failure = failure
  }

  var calls: Int { lock.withLock { callCount } }

  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse {
    try sendResponse(cancellation: GatewaySDKCancellation())
  }

  func send(
    url _: URL, method _: String, headers _: [String: String], body _: Data?, timeout _: TimeInterval,
    cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    try sendResponse(cancellation: cancellation)
  }

  func send(
    url _: URL, method _: String, headers _: [String: String], body _: Data?, maximumResponseBytes: Int,
    timeout _: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    let result = try sendResponse(cancellation: cancellation)
    guard result.data.count <= maximumResponseBytes else {
      throw GatewayError.transportFailure("SDK transport exceeded the response byte limit")
    }
    return result
  }

  private func sendResponse(cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }
    try replacement.replaceWithDirectory()
    lock.withLock { callCount += 1 }
    if let failure { throw failure }
    return response
  }
}

private final class SnapshotUnlinkFailureProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var allowed = false

  func allow() { lock.withLock { allowed = true } }

  func unlink(_ descriptor: Int32, _ leaf: String) -> Int32 {
    guard lock.withLock({ allowed }) else { return -1 }
    return leaf.withCString { Darwin.unlinkat(descriptor, $0, 0) }
  }
}

private final class SnapshotDirectoryCloseProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptors: [Int32] = []

  var closedDescriptors: [Int32] { lock.withLock { descriptors } }

  func close(_ descriptor: Int32) -> Int32 {
    lock.withLock { descriptors.append(descriptor) }
    return Darwin.close(descriptor)
  }
}

private final class SnapshotDirectoryDescriptorPool: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptors: [Int32]

  init(_ descriptors: [Int32]) { self.descriptors = descriptors }

  deinit {
    let remaining = lock.withLock { () -> [Int32] in
      defer { descriptors = [] }
      return descriptors
    }
    remaining.forEach { Darwin.close($0) }
  }

  func take() throws -> Int32 {
    try lock.withLock {
      guard !descriptors.isEmpty else {
        throw GatewayError.invalidArgument("Missing snapshot directory descriptor")
      }
      return descriptors.removeFirst()
    }
  }
}

@Test func sdkPreservesOutcomeUncertaintyWhenPostDispatchSnapshotCleanupFails() async throws {
  enum Fixture: Equatable {
    case success
    case rejectedProviderResponse
    case transportFailure

    var response: GatewayHTTPResponse {
      switch self {
      case .success, .transportFailure:
        return .init(statusCode: 200, data: Data("{}".utf8), requestID: "fixture")
      case .rejectedProviderResponse:
        return .init(statusCode: 500, data: Data("{}".utf8), requestID: "fixture")
      }
    }

    var failure: GatewayError? {
      self == .transportFailure ? .transportFailure("fixture failure") : nil
    }
  }

  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  try Data("{\"requests\":[{\"addSheet\":{}}]}".utf8).write(to: input)
  let variables: [String: GatewayJSONValue] = [
    "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"),
    "input-file": .string(input.path)
  ]

  for fixture in [Fixture.success, .rejectedProviderResponse, .transportFailure] {
    let replacement = SnapshotCleanupReplacementProbe()
    let snapshotter = CatalogFileSnapshotter { operation, values in
      let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: values)
      replacement.record(try #require(snapshots.paths.first))
      return snapshots
    }
    let transport = SnapshotCleanupReplacementTransport(
      replacement: replacement, response: fixture.response, failure: fixture.failure
    )
    let sdk = GoogleDocumentsGatewaySDK(
      role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: transport,
      catalogFileSnapshotter: snapshotter, fileAccessPolicy: .init(inputRoots: [root])
    )
    let result = await sdk.invoke(.init(operation: "spreadsheet batch-update", variables: variables), environment: [:])
    #expect(result.exitCode == 5)
    #expect(result.errors.first?.code == "OUTCOME_UNKNOWN")
    #expect(result.errors.first?.message == "Provider write may have completed; do not retry without reconciliation.")
    #expect(transport.calls == 1)
  }

  let localReplacement = SnapshotCleanupReplacementProbe()
  let localSnapshotter = CatalogFileSnapshotter { operation, values in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: values)
    localReplacement.record(try #require(snapshots.paths.first))
    try localReplacement.replaceWithDirectory()
    return snapshots
  }
  let localTransport = SDKFixtureTransport()
  let localSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: localTransport,
    catalogFileSnapshotter: localSnapshotter, fileAccessPolicy: .init(inputRoots: [root])
  )
  let local = await localSDK.invoke(
    .init(operation: "spreadsheet batch-update", variables: variables.merging(["dry-run": .bool(true)]) { _, replacement in replacement }),
    environment: [:]
  )
  #expect(local.exitCode == 2)
  #expect(local.errors.first?.code == "INVALID_ARGUMENT")
  #expect(localTransport.calls == 0)
}

@Test func sdkSnapshotCleanupRetriesOnlyTheRequestedPublicRecovery() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  try Data("{\"requests\":[{\"addSheet\":{}}]}".utf8).write(to: input)
  let firstDescriptor = root.path.withCString {
    Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
  }
  let secondDescriptor = root.path.withCString {
    Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
  }
  guard firstDescriptor >= 0, secondDescriptor >= 0 else {
    if firstDescriptor >= 0 { Darwin.close(firstDescriptor) }
    if secondDescriptor >= 0 { Darwin.close(secondDescriptor) }
    throw GatewayError.invalidArgument("Unable to open snapshot cleanup fixture directory")
  }
  let unlinkProbe = SnapshotUnlinkFailureProbe()
  let closeProbe = SnapshotDirectoryCloseProbe()
  let descriptors = SnapshotDirectoryDescriptorPool([firstDescriptor, secondDescriptor])
  let registry = GatewaySDKSnapshotCleanupRegistry()
  let snapshotter = CatalogFileSnapshotter { operation, variables in
    let state = CatalogSnapshotCleanupState(
      directoryPath: root.path, directoryDescriptor: try descriptors.take(), closeDirectory: closeProbe.close,
      unlink: unlinkProbe.unlink, recoveryRegistry: registry
    )
    return try CatalogFileSnapshots.capture(
      operation: operation, variables: variables, cleanupState: state
    )
  }
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: SDKFixtureTransport(),
    catalogFileSnapshotter: snapshotter, fileAccessPolicy: .init(inputRoots: [root]),
    snapshotCleanupRegistry: registry
  )
  let request = GatewayOperationRequest(operation: "spreadsheet batch-update", variables: [
    "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"),
    "input-file": .string(input.path), "dry-run": .bool(true)
  ])
  #expect((await sdk.invoke(request, environment: [:])).exitCode == 2)
  let firstRecovery = try #require(sdk.pendingSnapshotCleanupRecoveries.first)
  #expect(closeProbe.closedDescriptors.isEmpty)
  #expect((await sdk.invoke(request, environment: [:])).exitCode == 2)
  let recoveries = sdk.pendingSnapshotCleanupRecoveries
  #expect(recoveries.count == 2)
  let secondRecovery = try #require(recoveries.first { $0.id != firstRecovery.id })
  #expect(recoveries.allSatisfy { $0.path == root.path })
  #expect(closeProbe.closedDescriptors.isEmpty)
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
    $0.hasPrefix("google-documents-gateway-sdk-")
  }.count == 2)
  unlinkProbe.allow()
  let firstRemaining = sdk.retryPendingSnapshotCleanup(recoveryID: firstRecovery.id)
  #expect(firstRemaining.map(\.id) == [secondRecovery.id])
  #expect(sdk.pendingSnapshotCleanupRecoveries.map(\.id) == [secondRecovery.id])
  #expect(closeProbe.closedDescriptors == [firstDescriptor])
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter {
    $0.hasPrefix("google-documents-gateway-sdk-")
  }.count == 1)
  #expect(sdk.retryPendingSnapshotCleanup(recoveryID: secondRecovery.id).isEmpty)
  #expect(sdk.pendingSnapshotCleanupRecoveries.isEmpty)
  #expect(closeProbe.closedDescriptors == [firstDescriptor, secondDescriptor])
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
    !$0.hasPrefix("google-documents-gateway-sdk-")
  })
}

@Test func sdkSnapshotRecoverySurvivesFacadeRelease() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  try Data("{\"requests\":[{\"addSheet\":{}}]}".utf8).write(to: input)
  let unlinkProbe = SnapshotUnlinkFailureProbe()
  var registry: GatewaySDKSnapshotCleanupRegistry? = .init()
  let recovery: GatewaySDKSnapshotCleanupRecovery
  do {
    let retainedRegistry = try #require(registry)
    let snapshotter = CatalogFileSnapshotter { operation, variables in
      let state = CatalogSnapshotCleanupState(
        directoryPath: root.path, unlink: unlinkProbe.unlink, recoveryRegistry: retainedRegistry
      )
      return try CatalogFileSnapshots.capture(operation: operation, variables: variables, cleanupState: state)
    }
    let sdk = GoogleDocumentsGatewaySDK(
      role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: SDKFixtureTransport(),
      catalogFileSnapshotter: snapshotter, fileAccessPolicy: .init(inputRoots: [root]),
      snapshotCleanupRegistry: retainedRegistry
    )
    let request = GatewayOperationRequest(operation: "spreadsheet batch-update", variables: [
      "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"),
      "input-file": .string(input.path), "dry-run": .bool(true)
    ])
    #expect((await sdk.invoke(request, environment: [:])).exitCode == 2)
    recovery = try #require(sdk.pendingSnapshotCleanupRecoveries.first)
    #expect(FileManager.default.fileExists(atPath: recovery.path))
  }
  registry = nil
  unlinkProbe.allow()
  let successor = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: SDKFixtureTransport()
  )
  #expect(successor.pendingSnapshotCleanupRecoveries.contains { $0.id == recovery.id })
  #expect(successor.retryPendingSnapshotCleanup(recoveryID: recovery.id).contains { $0.id == recovery.id } == false)
  #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy {
    !$0.hasPrefix("google-documents-gateway-sdk-")
  })
}

@Test func sdkRawExecutionPreservesOutcomeUncertaintyWhenSnapshotCleanupFails() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  try Data("{\"requests\":[{\"addSheet\":{}}]}".utf8).write(to: input)
  let replacement = SnapshotCleanupReplacementProbe()
  let snapshotter = CatalogFileSnapshotter { operation, values in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: values)
    replacement.record(try #require(snapshots.paths.first))
    return snapshots
  }
  let transport = SnapshotCleanupReplacementTransport(replacement: replacement)
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: transport,
    catalogFileSnapshotter: snapshotter, fileAccessPolicy: .init(inputRoots: [root])
  )
  let arguments = [
    "spreadsheet", "batch-update", "--spreadsheet-id", "sheet",
    "--confirm-spreadsheet-id", "sheet", "--input-file", input.path
  ]
  let document = try GatewayJSONValue.array(arguments.map(GatewayJSONValue.string)).jsonString()
  let result = await sdk.execute(document: document, variables: [:], environment: [:])
  #expect(result.exitCode == 5)
  #expect(result.errors.first?.code == "OUTCOME_UNKNOWN")
  #expect(result.errors.first?.message == "Provider write may have completed; do not retry without reconciliation.")
  #expect(transport.calls == 1)
}

@Test func operationRunPreservesOutcomeUncertaintyWhenPostDispatchSnapshotCleanupFails() throws {
  enum Fixture: Equatable {
    case success
    case rejectedProviderResponse
    case transportFailure
    case alreadyUncertain

    var response: GatewayHTTPResponse {
      switch self {
      case .success, .transportFailure, .alreadyUncertain:
        return .init(statusCode: 200, data: Data("{}".utf8), requestID: "fixture")
      case .rejectedProviderResponse:
        return .init(statusCode: 500, data: Data("{}".utf8), requestID: "fixture")
      }
    }

    var failure: GatewayError? {
      switch self {
      case .transportFailure:
        return .transportFailure("fixture failure")
      case .alreadyUncertain:
        return .transportFailure("OUTCOME_UNKNOWN: provider write may have completed")
      default:
        return nil
      }
    }
  }

  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  try Data("{\"requests\":[{\"addSheet\":{}}]}".utf8).write(to: input)
  let variables = try GatewayJSONValue.object([
    "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"),
    "input-file": .string(input.path)
  ]).jsonString()

  for fixture in [Fixture.success, .rejectedProviderResponse, .transportFailure, .alreadyUncertain] {
    let replacement = SnapshotCleanupReplacementProbe()
    let snapshotter = CatalogFileSnapshotter { operation, values in
      let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: values)
      replacement.record(try #require(snapshots.paths.first))
      return snapshots
    }
    let transport = SnapshotCleanupReplacementTransport(
      replacement: replacement, response: fixture.response, failure: fixture.failure
    )
    let runner = GatewayCommandRunner(
      role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: transport
    )
    let result = GatewaySDKCommandRouter.operationRun(
      ["spreadsheet", "batch-update", "--variables", variables], runner: runner,
      fileAccessPolicy: .init(inputRoots: [root]), catalogFileSnapshotter: snapshotter
    )
    #expect(result.exitCode == 5)
    #expect(result.stdout.contains("\"code\":\"OUTCOME_UNKNOWN\""))
    #expect(result.stdout.contains("Provider write may have completed; do not retry without reconciliation."))
    #expect(transport.calls == 1)
  }

  let localReplacement = SnapshotCleanupReplacementProbe()
  let localSnapshotter = CatalogFileSnapshotter { operation, values in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: values)
    localReplacement.record(try #require(snapshots.paths.first))
    try localReplacement.replaceWithDirectory()
    return snapshots
  }
  let localTransport = SDKFixtureTransport()
  let localRunner = GatewayCommandRunner(
    role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: localTransport
  )
  let localResult = GatewaySDKCommandRouter.operationRun(
    ["spreadsheet", "batch-update", "--variables", try GatewayJSONValue.object([
      "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"),
      "input-file": .string(input.path), "dry-run": .bool(true)
    ]).jsonString()], runner: localRunner,
    fileAccessPolicy: .init(inputRoots: [root]), catalogFileSnapshotter: localSnapshotter
  )
  #expect(localResult.exitCode == 2)
  #expect(localResult.stdout.contains("\"code\":\"INVALID_ARGUMENT\""))
  #expect(localTransport.calls == 0)
}
