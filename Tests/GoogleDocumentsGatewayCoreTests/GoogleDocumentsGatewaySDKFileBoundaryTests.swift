import Foundation
import GatewaySDKKit
import Testing
@testable import GoogleDocumentsGatewayCore
private final class OutputCleanupFailureProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var calls: Int { lock.withLock { count } }
  func unlink(parent: Int32, leaf: String) -> Int32 {
    let shouldFail = lock.withLock {
      count += 1
      return count == 1
    }
    guard !shouldFail else { return -1 }
    return leaf.withCString { Darwin.unlinkat(parent, $0, 0) }
  }
}
private final class PersistentOutputCleanupFailureProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  private var shouldFail = true
  private var shouldBlockNextUnlink = false
  private let unlinkEntered = DispatchSemaphore(value: 0)
  private let unblockUnlink = DispatchSemaphore(value: 0)
  var calls: Int { lock.withLock { count } }
  func allowCleanup() { lock.withLock { shouldFail = false } }
  func blockNextUnlink() { lock.withLock { shouldBlockNextUnlink = true } }
  func waitForBlockedUnlink() -> Bool { unlinkEntered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func releaseBlockedUnlink() { unblockUnlink.signal() }
  func unlink(parent: Int32, leaf: String) -> Int32 {
    let state = lock.withLock { () -> (Bool, Bool) in
      count += 1
      let shouldBlock = shouldBlockNextUnlink
      shouldBlockNextUnlink = false
      return (shouldFail, shouldBlock)
    }
    if state.1 {
      unlinkEntered.signal()
      guard unblockUnlink.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success else { return -1 }
    }
    let fails = state.0
    guard !fails else { return -1 }
    return leaf.withCString { Darwin.unlinkat(parent, $0, 0) }
  }
}
private final class OutputRollbackFailureProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var swaps = 0
  func swap(_ sourceDirectory: Int32, _ source: String, _ destinationDirectory: Int32, _ destination: String) -> Int32 {
    let shouldSwap = lock.withLock { () -> Bool in
      swaps += 1
      return swaps == 1
    }
    guard shouldSwap else { return -1 }
    return source.withCString { sourcePointer in
      destination.withCString { destinationPointer in
        renameatx_np(sourceDirectory, sourcePointer, destinationDirectory, destinationPointer, UInt32(RENAME_SWAP))
      }
    }
  }
}
private final class CatalogFilePreparationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var authorizationCount = 0
  private var snapshotCount = 0
  var authorizations: Int { lock.withLock { authorizationCount } }
  var snapshots: Int { lock.withLock { snapshotCount } }
  func recordAuthorization() { lock.withLock { authorizationCount += 1 } }
  func recordSnapshot() { lock.withLock { snapshotCount += 1 } }
}
private final class FilesystemTraversalProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var delayed = false
  private let checkpoint = DispatchSemaphore(value: 0)
  func delayOnce() {
    let shouldDelay = lock.withLock { () -> Bool in
      guard !delayed else { return false }
      delayed = true
      return true
    }
    guard shouldDelay else { return }
    Thread.sleep(forTimeInterval: 0.05)
    checkpoint.signal()
  }
  func waitForCheckpoint() -> Bool { checkpoint.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
}
@Test func sdkBuildArgvIsConstructionOnlyForDeniedFileInputs() throws {
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .sheets, accessMode: .write))
  let argv = try sdk.buildArgv(operation: "spreadsheet batch-update", variables: [
    "spreadsheet-id": .string("sheet"),
    "confirm-spreadsheet-id": .string("sheet"),
    "input-file": .string("/a/path-that-must-not-be-opened.json")
  ])
  #expect(argv.contains("/a/path-that-must-not-be-opened.json"))
}
@Test func invalidCatalogBindingsDoNotPrepareFileInputsForSDKOrOperationRun() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  try Data("{\"requests\":[]}".utf8).write(to: input)
  let variables: [String: GatewayJSONValue] = [
    "confirm-spreadsheet-id": .string("sheet"), "input-file": .string(input.path)
  ]
  func policy(_ probe: CatalogFilePreparationProbe) -> GatewaySDKFileAccessPolicy {
    .init(inputRoots: [root], inputAuthorizationObserver: probe.recordAuthorization)
  }
  func snapshotter(_ probe: CatalogFilePreparationProbe) -> CatalogFileSnapshotter {
    .init { operation, values in
      probe.recordSnapshot()
      return try CatalogFileSnapshots.capture(operation: operation, variables: values)
    }
  }
  let sdkProbe = CatalogFilePreparationProbe()
  let sdkTransport = SDKFixtureTransport()
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: sdkTransport,
    catalogFileSnapshotter: snapshotter(sdkProbe), fileAccessPolicy: policy(sdkProbe)
  )
  let invoked = await sdk.invoke(.init(operation: "spreadsheet batch-update", variables: variables), environment: [:])
  #expect(invoked.exitCode == 2)
  #expect(sdkProbe.authorizations == 0)
  #expect(sdkProbe.snapshots == 0)
  #expect(sdkTransport.calls == 0)
  let operationProbe = CatalogFilePreparationProbe()
  let operationAuthorizer = SDKFixtureAuthorizer()
  let operationTransport = SDKFixtureTransport()
  let runner = GatewayCommandRunner(
    role: .init(service: .sheets, accessMode: .write), authorizer: operationAuthorizer, transport: operationTransport
  )
  let operation = GatewaySDKCommandRouter.operationRun(
    ["spreadsheet", "batch-update", "--variables", try GatewayJSONValue.object(variables).jsonString()],
    runner: runner,
    fileAccessPolicy: policy(operationProbe),
    catalogFileSnapshotter: snapshotter(operationProbe)
  )
  #expect(operation.exitCode == 2)
  #expect(operationProbe.authorizations == 0)
  #expect(operationProbe.snapshots == 0)
  #expect(operationAuthorizer.calls == 0)
  #expect(operationTransport.calls == 0)
}
@Test func sdkSnapshotsRetainedDescriptorAcrossDirectoryAndLeafReplacement() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let approved = root.appendingPathComponent("approved", isDirectory: true)
  try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
  let input = approved.appendingPathComponent("input.json")
  let original = Data("{\"requests\":[{\"addSheet\":{}}]}".utf8)
  try original.write(to: input)
  let opened = DispatchSemaphore(value: 0)
  let continueRead = DispatchSemaphore(value: 0)
  let policy = GatewaySDKFileAccessPolicy(
    inputRoots: [root],
    inputAuthorizationObserver: { opened.signal(); _ = continueRead.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) }
  )
  let transport = GatewaySDKBoundaryTransport()
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport,
    fileAccessPolicy: policy
  )
  let request = GatewayOperationRequest(operation: "spreadsheet batch-update", variables: [
    "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"), "input-file": .string(input.path)
  ])
  let task = Task { await sdk.invoke(request, environment: [:]) }
  let didOpen = await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      continuation.resume(returning: opened.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success)
    }
  }
  #expect(didOpen)
  let oldDirectory = root.appendingPathComponent("old-approved", isDirectory: true)
  try FileManager.default.moveItem(at: approved, to: oldDirectory)
  try FileManager.default.createDirectory(at: approved, withIntermediateDirectories: true)
  try Data("{\"requests\":[{\"replacement\":{}}]}".utf8).write(to: approved.appendingPathComponent("input.json"))
  try FileManager.default.removeItem(at: oldDirectory.appendingPathComponent("input.json"))
  try Data("{\"requests\":[{\"leafReplacement\":{}}]}".utf8).write(to: oldDirectory.appendingPathComponent("input.json"))
  continueRead.signal()
  let result = await task.value
  #expect(result.exitCode == 0, "\(result.rawOutput)")
  #expect(transport.lastBody == original)
}
@Test func sdkConsumesCapturedSnapshotBytesAfterSnapshotPathReplacement() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  let original = Data("{\"requests\":[{\"addSheet\":{}}]}".utf8)
  try original.write(to: input)
  let snapshotter = CatalogFileSnapshotter { operation, variables in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: variables)
    let path = try #require(snapshots.paths.first)
    try FileManager.default.removeItem(atPath: path)
    try Data(repeating: 0x78, count: GatewayInputValidator.maximumBodyBytes + 1).write(to: URL(fileURLWithPath: path))
    return snapshots
  }
  let transport = GatewaySDKBoundaryTransport()
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport,
    catalogFileSnapshotter: snapshotter, fileAccessPolicy: .init(inputRoots: [root])
  )
  let result = await sdk.invoke(.init(operation: "spreadsheet batch-update", variables: [
    "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"), "input-file": .string(input.path)
  ]), environment: [:])
  #expect(result.exitCode == 0)
  #expect(transport.calls == 1)
  #expect(transport.lastBody == original)
  let operationTransport = SDKFixtureTransport()
  let operationRunner = GatewayCommandRunner(
    role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: operationTransport
  )
  let operationSnapshotter = CatalogFileSnapshotter { operation, variables in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: variables)
    let path = try #require(snapshots.paths.first)
    try FileManager.default.removeItem(atPath: path)
    try Data(repeating: 0x78, count: GatewayInputValidator.maximumBodyBytes + 1).write(to: URL(fileURLWithPath: path))
    return snapshots
  }
  let encodedVariables = try GatewayJSONValue.object([
    "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"), "input-file": .string(input.path)
  ]).jsonString()
  let operationResult = GatewaySDKCommandRouter.operationRun(
    ["spreadsheet", "batch-update", "--variables", encodedVariables], runner: operationRunner,
    fileAccessPolicy: .init(inputRoots: [root]), catalogFileSnapshotter: operationSnapshotter
  )
  #expect(operationResult.exitCode == 0)
  #expect(operationTransport.lastBody == original)
}
@Test func sdkSurfacesSnapshotCleanupFailureAfterPostSnapshotBindingFailure() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  try Data("{\"requests\":[{\"addSheet\":{}}]}".utf8).write(to: input)
  let snapshotter = CatalogFileSnapshotter { operation, variables in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: variables)
    let path = try #require(snapshots.paths.first)
    try FileManager.default.removeItem(atPath: path)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    var altered = snapshots.variables
    altered["spreadsheet-id"] = .int(1)
    return snapshots.replacing(variables: altered)
  }
  let transport = SDKFixtureTransport()
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: transport,
    catalogFileSnapshotter: snapshotter, fileAccessPolicy: .init(inputRoots: [root])
  )
  let result = await sdk.invoke(.init(operation: "spreadsheet batch-update", variables: [
    "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"), "input-file": .string(input.path)
  ]), environment: [:])
  #expect(result.exitCode == 2)
  #expect(result.errors.first?.message.hasPrefix("Unable to remove catalog file snapshot; recovery_id=") == true)
  #expect(transport.calls == 0)
}
@Test func sdkOutputCommitAndCancellationShareOneResultBoundary() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  for deadlineDriven in [false, true] { for overwrite in [false, true] {
    let path = root.appendingPathComponent("committed-\(deadlineDriven)-\(overwrite).txt")
    if overwrite { try Data("previous".utf8).write(to: path) }
    let probe = SDKOutputRaceProbe()
    let task = Task { await transferSDK(root: root, probe: probe, timeout: deadlineDriven ? 0.01 : 1).invoke(transferRequest(path, overwrite), environment: [:]) }
    #expect(await gatewaySDKTestHandshake { probe.waitForCommit() }); if !deadlineDriven { task.cancel() }
    let result = await task.value; #expect(result.exitCode == 0); #expect(result.errors.isEmpty)
    #expect(try Data(contentsOf: path) == Data("{}".utf8)); #expect(privateOutputPaths(in: root).isEmpty)
  } }
  for deadlineDriven in [false, true] { for overwrite in [false, true] {
    let path = root.appendingPathComponent("uncommitted-\(deadlineDriven)-\(overwrite).txt")
    if overwrite { try Data("previous".utf8).write(to: path) }
    let probe = SDKOutputRaceProbe()
    let task = Task { await transferSDK(root: root, probe: probe, blockDuringSync: true, timeout: deadlineDriven ? 0.01 : 1).invoke(transferRequest(path, overwrite), environment: [:]) }
    #expect(await gatewaySDKTestHandshake { probe.waitForSync() })
    if !deadlineDriven { task.cancel() }
    #expect(await gatewaySDKTestHandshake { probe.waitForCancellationAttempt() })
    #expect((await task.value).exitCode == 5)
    probe.releaseSync()
    for _ in 0 ..< 20 where !privateOutputPaths(in: root).isEmpty {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    #expect(privateOutputPaths(in: root).isEmpty)
    if overwrite { #expect(try Data(contentsOf: path) == Data("previous".utf8)) } else { #expect(!FileManager.default.fileExists(atPath: path.path)) }
  } }
  for failure in ["write", "quota", "sync"] {
    let path = root.appendingPathComponent("failure-\(failure).txt")
    let result = await transferSDK(root: root, probe: .init(), failure: failure).invoke(transferRequest(path, false), environment: [:])
    #expect(result.exitCode != 0); #expect(!FileManager.default.fileExists(atPath: path.path)); #expect(privateOutputPaths(in: root).isEmpty)
  }
}
@Test func sdkOverwriteRevalidatesDestinationBeforeCommit() throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let destination = root.appendingPathComponent("destination.txt")
  try Data("approved".utf8).write(to: destination)
  let destinationPath = destination.path
  let policy = GatewaySDKFileAccessPolicy(
    outputRoots: [root],
    outputDataWriter: { data, descriptor, cancellation in
      try writeSDKOutput(data, descriptor, cancellation)
    },
    outputSynchronizer: { _ in },
    outputCommitObserver: { overwrite in
      guard overwrite else { return }
      precondition(Darwin.unlink(destinationPath) == 0)
      precondition(FileManager.default.createFile(atPath: destinationPath, contents: Data("replacement".utf8)))
    }
  )
  #expect(throws: GatewayError.invalidArgument("SDK output changed before commit")) {
    try policy.outputWriter().write(Data("sdk-output".utf8), destinationPath, true)
  }
  #expect(try Data(contentsOf: destination) == Data("replacement".utf8))
  #expect(privateOutputPaths(in: root).isEmpty)
}
@Test func sdkOverwriteReportsOutcomeUnknownForReplacementBetweenValidationAndSwap() throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let destination = root.appendingPathComponent("destination.txt")
  try Data("approved".utf8).write(to: destination)
  let destinationPath = destination.path
  let policy = GatewaySDKFileAccessPolicy(
    outputRoots: [root],
    outputDataWriter: { data, descriptor, cancellation in
      try writeSDKOutput(data, descriptor, cancellation)
    },
    outputSynchronizer: { _ in },
    outputPreSwapObserver: {
      precondition(Darwin.unlink(destinationPath) == 0)
      precondition(FileManager.default.createFile(atPath: destinationPath, contents: Data("replacement".utf8)))
    }
  )
  do {
    try policy.outputWriter().write(Data("sdk-output".utf8), destinationPath, true)
    Issue.record("Expected an outcome-unknown overwrite failure")
  } catch let error as GatewayError {
    guard case .transportFailure(let message) = error else {
      Issue.record("Expected transport failure, got \(error)")
      return
    }
    #expect(message.hasPrefix("OUTCOME_UNKNOWN:"))
  }
  #expect(try Data(contentsOf: destination) == Data("sdk-output".utf8))
  let recovery = try #require(privateOutputPaths(in: root).first)
  #expect(try Data(contentsOf: root.appendingPathComponent(recovery)) == Data("replacement".utf8))
}
@Test func sdkOverwriteRollsBackWhenDisplacedOutputCleanupFails() throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let destination = root.appendingPathComponent("destination.txt")
  try Data("approved".utf8).write(to: destination)
  let cleanupProbe = OutputCleanupFailureProbe()
  let policy = GatewaySDKFileAccessPolicy(
    outputRoots: [root],
    outputDataWriter: { data, descriptor, cancellation in
      try writeSDKOutput(data, descriptor, cancellation)
    },
    outputSynchronizer: { _ in },
    outputUnlinker: { parent, leaf in cleanupProbe.unlink(parent: parent, leaf: leaf) }
  )
  #expect(throws: GatewayError.invalidArgument("Unable to write SDK output")) {
    try policy.outputWriter().write(Data("sdk-output".utf8), destination.path, true)
  }
  #expect(try Data(contentsOf: destination) == Data("approved".utf8))
  #expect(cleanupProbe.calls == 2)
  #expect(privateOutputPaths(in: root).isEmpty)
}
@Test func sdkReportsPersistentStagingCleanupFailuresWithRecoveryOwnership() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let cleanup = PersistentOutputCleanupFailureProbe()
  func policy(
    writer: @escaping @Sendable (Data, Int32, GatewaySDKCancellation?) throws -> Void = writeSDKOutput,
    synchronizer: @escaping @Sendable (Int32) throws -> Void = { _ in },
    publisher: @escaping @Sendable (Int32, String, Int32, String) -> Int32 = { _, _, _, _ in -1 }
  ) -> GatewaySDKFileAccessPolicy {
    .init(
      outputRoots: [root], outputDataWriter: writer, outputSynchronizer: synchronizer,
      outputNoOverwritePublisher: publisher, outputUnlinker: cleanup.unlink
    )
  }
  func expectCleanupFailure(_ action: () throws -> Void) {
    do { try action(); Issue.record("Expected a staging cleanup failure") } catch let error as GatewayError {
      guard case .transportFailure(let message) = error else { Issue.record("Expected cleanup failure, got \(error)"); return }
      #expect(message.hasPrefix("SDK output staging cleanup failed; recovery_path=\(root.path)/.google-documents-gateway-sdk-"))
    } catch { Issue.record("Expected cleanup failure, got \(error)") }
  }
  expectCleanupFailure {
    try policy(writer: { _, _, _ in throw GatewayError.invalidArgument("writer failed") })
      .outputWriter().write(Data(), root.appendingPathComponent("writer.txt").path, false)
  }
  expectCleanupFailure {
    try policy(synchronizer: { _ in throw GatewayError.invalidArgument("sync failed") })
      .outputWriter().write(Data(), root.appendingPathComponent("sync.txt").path, false)
  }
  let cancellation = GatewaySDKCancellation()
  expectCleanupFailure {
    try policy(writer: { data, descriptor, token in
      try writeSDKOutput(data, descriptor, token); cancellation.cancel()
    }).outputWriter(cancellation: cancellation).write(Data(), root.appendingPathComponent("cancel.txt").path, false)
  }
  expectCleanupFailure {
    try policy().outputWriter().write(Data(), root.appendingPathComponent("no-overwrite.txt").path, false)
  }
  let overwrite = root.appendingPathComponent("overwrite.txt")
  try Data("approved".utf8).write(to: overwrite)
  expectCleanupFailure {
    try policy().outputWriter().write(Data("replacement".utf8), overwrite.path, true)
  }
  #expect(try Data(contentsOf: overwrite) == Data("approved".utf8))
  #expect(privateOutputPaths(in: root).count == 5)
  #expect(cleanup.calls >= 6)
  let retainedPolicy = policy(writer: { _, _, _ in throw GatewayError.invalidArgument("retained failure") })
  expectCleanupFailure {
    try retainedPolicy.outputWriter().write(Data(), root.appendingPathComponent("retained-one.txt").path, false)
  }
  expectCleanupFailure {
    try retainedPolicy.outputWriter().write(Data(), root.appendingPathComponent("retained-two.txt").path, false)
  }
  let retained = retainedPolicy.pendingOutputCleanupRecoveries
  #expect(retained.count == 2)
  let first = try #require(retained.first)
  let second = try #require(retained.last)
  #expect(first.id != second.id)
  #expect(first.path.hasPrefix(root.path + "/.google-documents-gateway-sdk-"))
  cleanup.allowCleanup(); cleanup.blockNextUnlink()
  let retry = Task.detached { retainedPolicy.retryPendingOutputCleanup(recoveryID: first.id) }
  let retryEntered = await withCheckedContinuation { continuation in
    DispatchQueue.global().async { continuation.resume(returning: cleanup.waitForBlockedUnlink()) }
  }
  #expect(retryEntered)
  #expect(retainedPolicy.pendingOutputCleanupRecoveries == retained)
  #expect(retainedPolicy.retryPendingOutputCleanup(recoveryID: second.id) == retained)
  cleanup.releaseBlockedUnlink()
  #expect(await retry.value == [second])
  #expect(FileManager.default.fileExists(atPath: second.path))
  #expect(!FileManager.default.fileExists(atPath: first.path))
  #expect(retainedPolicy.retryPendingOutputCleanup(recoveryID: second.id).isEmpty)
  #expect(retainedPolicy.pendingOutputCleanupRecoveries.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: second.path))
}
@Test func sdkOverwriteReportsOutcomeUnknownAndRetainsRecoveryWhenRollbackFails() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let destination = root.appendingPathComponent("destination.txt")
  try Data("approved".utf8).write(to: destination)
  let race = UncertainPublicationRaceProbe()
  let rollbackProbe = OutputRollbackFailureProbe()
  let policy = GatewaySDKFileAccessPolicy(
    outputRoots: [root],
    outputDataWriter: { data, descriptor, cancellation in
      try writeSDKOutput(data, descriptor, cancellation)
    },
    outputSynchronizer: { _ in },
    outputSwapper: rollbackProbe.swap,
    outputUnlinker: race.blockFailedUnlink,
    cancellationAttemptObserver: race.recordCancellationAttempt
  )
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(),
    transport: GatewaySDKBoundaryTransport(), fileAccessPolicy: policy
  )
  let task = Task { await sdk.invoke(.init(operation: "files download", variables: [
    "file-id": .string("file"), "output": .string(destination.path), "max-bytes": .int(64), "overwrite": .bool(true)
  ]), environment: [:]) }
  let failedUnlinkStarted = await withCheckedContinuation { continuation in
    DispatchQueue.global().async { continuation.resume(returning: race.waitForUnlink()) }
  }
  #expect(failedUnlinkStarted)
  let cancellationTask = Task.detached { task.cancel() }
  let cancellationStarted = await withCheckedContinuation { continuation in
    DispatchQueue.global().async { continuation.resume(returning: race.waitForCancellation()) }
  }
  #expect(cancellationStarted)
  race.release()
  let result = await task.value
  _ = await cancellationTask.value
  #expect(result.errors.first?.code == "OUTCOME_UNKNOWN")
  #expect(result.errors.first?.message.hasPrefix("SDK_LOCAL_PUBLICATION_UNCERTAIN;") == true)
  #expect(try Data(contentsOf: destination) == Data("{}".utf8))
  let recovery = try #require(privateOutputPaths(in: root).first)
  #expect(try Data(contentsOf: root.appendingPathComponent(recovery)) == Data("approved".utf8))
  let owned = try #require(policy.pendingOutputCleanupRecoveries.first)
  #expect(owned.path == root.appendingPathComponent(recovery).path)
  #expect(result.errors.first?.message.contains("recovery_path=\(owned.path)") == true)
}
@Test func sdkBlockedStagingCleanupPublishesRecoveryDespiteCancellation() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let cleanup = PersistentOutputCleanupFailureProbe(); let attempted = DispatchSemaphore(value: 0); cleanup.blockNextUnlink()
  let policy = GatewaySDKFileAccessPolicy(outputRoots: [root], outputDataWriter: { _, _, _ in throw GatewayError.invalidArgument("write") }, outputSynchronizer: { _ in }, outputUnlinker: cleanup.unlink,
                                          cancellationAttemptObserver: { attempted.signal() })
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: GatewaySDKBoundaryTransport(), fileAccessPolicy: policy)
  let task = Task { await sdk.invoke(.init(operation: "files download", variables: ["file-id": .string("file"), "output": .string(root.appendingPathComponent("output").path), "max-bytes": .int(64)]), environment: [:]) }
  #expect(await gatewaySDKTestHandshake { cleanup.waitForBlockedUnlink() }); let cancellation = Task.detached { task.cancel() }
  #expect(await gatewaySDKTestHandshake { attempted.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }); cleanup.releaseBlockedUnlink()
  let result = await task.value; _ = await cancellation.value; let recovery = try #require(policy.pendingOutputCleanupRecoveries.first)
  #expect(result.errors.first?.code == "TRANSPORT_FAILURE"); #expect(result.errors.first?.message.contains("recovery_path=\(recovery.path)") == true, "\(result.errors)")
}
@Test func sdkRejectsAmbientAndNonRegularCatalogFileArgumentsBeforeExecution() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let fifo = root.appendingPathComponent("input.fifo")
  #expect(fifo.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
  let inputCases = [
    CatalogFileArgumentCase(role: .init(service: .docs, accessMode: .write), operation: "document create", variables: ["json-file": .string("-")]),
    CatalogFileArgumentCase(role: .init(service: .sheets, accessMode: .write), operation: "spreadsheet batch-update", variables: [
      "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"), "input-file": .string("-")
    ]),
    CatalogFileArgumentCase(role: .init(service: .drive, accessMode: .write), operation: "files upload", variables: ["input": .string("-"), "max-bytes": .int(1)])
  ]
  for testCase in inputCases {
    let authorizer = SDKFixtureAuthorizer()
    let transport = SDKFixtureTransport()
    let sdk = GoogleDocumentsGatewaySDK(role: testCase.role, authorizer: authorizer, transport: transport)
    let envelope = await sdk.invoke(.init(operation: testCase.operation, variables: testCase.variables), environment: [:])
    #expect(envelope.exitCode == 2, "operation: \(testCase.operation)")
    #expect(envelope.errors.first?.code == "INVALID_ARGUMENT", "operation: \(testCase.operation)")
    #expect(envelope.rawOutput.contains("\"code\":\"INVALID_ARGUMENT\""), "operation: \(testCase.operation)")
    #expect(authorizer.calls == 0, "operation: \(testCase.operation)")
    #expect(transport.calls == 0, "operation: \(testCase.operation)")
  }
  let authorizer = SDKFixtureAuthorizer()
  let transport = SDKFixtureTransport()
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .sheets, accessMode: .write), authorizer: authorizer, transport: transport, fileAccessPolicy: .init(inputRoots: [root]))
  let envelope = await sdk.invoke(.init(operation: "spreadsheet batch-update", variables: ["spreadsheet-id": .string("sheet"),
    "confirm-spreadsheet-id": .string("sheet"), "input-file": .string(fifo.path)]), environment: [:])
  #expect(envelope.exitCode == 2); #expect(envelope.errors.first?.code == "INVALID_ARGUMENT")
  #expect(envelope.rawOutput.contains("\"code\":\"INVALID_ARGUMENT\"")); #expect(authorizer.calls == 0)
  #expect(transport.calls == 0)
}
@Test func sdkSnapshotsCatalogFileInputsBeforeRunnerExecution() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appendingPathComponent("input.json")
  try Data("{\"requests\":[]}".utf8).write(to: source)
  let sourcePath = source.path
  let replacementAuthorizer = SDKFixtureAuthorizer()
  let replacementTransport = SDKFixtureTransport()
  let replacementSnapshotter = CatalogFileSnapshotter { operation, variables in
    try FileManager.default.removeItem(atPath: sourcePath)
    guard sourcePath.withCString({ Darwin.mkfifo($0, 0o600) }) == 0 else {
      throw GatewayError.invalidArgument("Unable to replace catalog fixture")
    }
    return try CatalogFileSnapshots.capture(operation: operation, variables: variables)
  }
  let replacementSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: replacementAuthorizer,
    transport: replacementTransport, catalogFileSnapshotter: replacementSnapshotter, fileAccessPolicy: .init(inputRoots: [root])
  )
  let variables: [String: GatewayJSONValue] = ["spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"), "input-file": .string(sourcePath)]
  let replacement = await replacementSDK.invoke(
    .init(operation: "spreadsheet batch-update", variables: variables),
    environment: [:]
  )
  #expect(replacement.exitCode == 2)
  #expect(replacementAuthorizer.calls == 0)
  #expect(replacementTransport.calls == 0)
  try FileManager.default.removeItem(atPath: sourcePath)
  try Data().write(to: source)
  let probe = CatalogSnapshotProbe(chunks: [
    Data([0x61]),
    Data(repeating: 0x61, count: GatewayInputValidator.maximumBodyBytes)
  ])
  let boundedAuthorizer = SDKFixtureAuthorizer()
  let boundedTransport = SDKFixtureTransport()
  let boundedSnapshotter = CatalogFileSnapshotter { operation, values in
    try CatalogFileSnapshots.capture(
      operation: operation,
      variables: values,
      dataReader: { descriptor, requestedBytes in
        probe.read(descriptor: descriptor, requestedBytes: requestedBytes)
      }
    )
  }
  let boundedSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write),
    authorizer: boundedAuthorizer,
    transport: boundedTransport,
    catalogFileSnapshotter: boundedSnapshotter,
    fileAccessPolicy: .init(inputRoots: [root])
  )
  let oversized = await boundedSDK.invoke(
    .init(operation: "spreadsheet batch-update", variables: variables),
    environment: [:]
  )
  #expect(oversized.exitCode == 2)
  #expect(probe.requestedBytes == [
    GatewayInputValidator.maximumBodyBytes + 1,
    GatewayInputValidator.maximumBodyBytes
  ])
  #expect(Set(probe.descriptors).count == 1)
  #expect(boundedAuthorizer.calls == 0)
  #expect(boundedTransport.calls == 0)
}
@Test func catalogSnapshotsPreserveBinaryUploadAcrossShortReads() throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("binary.dat")
  let payload = Data([0x00, 0xff, 0x01, 0xfe, 0x02, 0xfd])
  try payload.write(to: input)
  let role = GatewayRole(service: .drive, accessMode: .write)
  let operation = try #require(GatewaySchemaCatalog.googleDocuments(role: role).operation(named: "files upload"))
  let probe = CatalogSnapshotProbe(chunks: [
    Data(payload.prefix(2)),
    Data(payload.dropFirst(2))
  ])
  let snapshots = try CatalogFileSnapshots.capture(
    operation: operation,
    variables: ["input": .string(input.path), "max-bytes": .int(64)],
    dataReader: { descriptor, requestedBytes in
      probe.read(descriptor: descriptor, requestedBytes: requestedBytes)
    }
  )
  defer { snapshots.cleanup() }
  let snapshotPath = try #require(snapshots.paths.first)
  #expect(try Data(contentsOf: URL(fileURLWithPath: snapshotPath)) == payload)
  #expect(probe.requestedBytes == [65, 63, 59])
  #expect(Set(probe.descriptors).count == 1)
}
@Test func sdkSnapshotsAreOwnerOnlyAndCleanedAfterRunnerSuccessAndFailure() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  try Data("{\"requests\":[{\"addSheet\":{}}]}".utf8).write(to: input)
  let role = GatewayRole(service: .sheets, accessMode: .write)
  let variables: [String: GatewayJSONValue] = [
    "spreadsheet-id": .string("sheet"),
    "confirm-spreadsheet-id": .string("sheet"),
    "input-file": .string(input.path)
  ]
  let successRecorder = SnapshotPathRecorder()
  let successSnapshotter = CatalogFileSnapshotter { operation, values in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: values)
    successRecorder.record(snapshots.paths)
    return snapshots
  }
  let successTransport = SDKFixtureTransport()
  let successSDK = GoogleDocumentsGatewaySDK(
    role: role,
    authorizer: SDKFixtureAuthorizer(),
    transport: successTransport,
    catalogFileSnapshotter: successSnapshotter,
    fileAccessPolicy: .init(inputRoots: [root])
  )
  let success = await successSDK.invoke(.init(operation: "spreadsheet batch-update", variables: variables), environment: [:])
  #expect(success.exitCode == 0)
  #expect(successTransport.calls == 1)
  #expect(successRecorder.ownerOnlyModes == [true])
  #expect(successRecorder.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
  let failureRecorder = SnapshotPathRecorder()
  let failureSnapshotter = CatalogFileSnapshotter { operation, values in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: values)
    failureRecorder.record(snapshots.paths)
    return snapshots
  }
  let failureTransport = SDKFixtureTransport(failure: GatewayError.transportFailure("fixture failure"))
  let failureSDK = GoogleDocumentsGatewaySDK(
    role: role,
    authorizer: SDKFixtureAuthorizer(),
    transport: failureTransport,
    catalogFileSnapshotter: failureSnapshotter,
    fileAccessPolicy: .init(inputRoots: [root])
  )
  let failure = await failureSDK.invoke(.init(operation: "spreadsheet batch-update", variables: variables), environment: [:])
  #expect(failure.exitCode == 5)
  #expect(failureTransport.calls == 1)
  #expect(failureRecorder.ownerOnlyModes == [true])
  #expect(failureRecorder.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
}
@Test func sdkRawSnapshotsAreCleanedAfterRunnerFailure() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  try Data("{\"requests\":[{\"addSheet\":{}}]}".utf8).write(to: input)
  let recorder = SnapshotPathRecorder()
  let snapshotter = CatalogFileSnapshotter { operation, values in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: values)
    recorder.record(snapshots.paths)
    return snapshots
  }
  let transport = SDKFixtureTransport(failure: GatewayError.transportFailure("fixture failure"))
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write),
    authorizer: SDKFixtureAuthorizer(),
    transport: transport,
    catalogFileSnapshotter: snapshotter,
    fileAccessPolicy: .init(inputRoots: [root])
  )
  let arguments = [
    "spreadsheet", "batch-update", "--spreadsheet-id", "sheet",
    "--confirm-spreadsheet-id", "sheet", "--input-file", input.path
  ]
  let document = try GatewayJSONValue.array(arguments.map(GatewayJSONValue.string)).jsonString()
  let result = await sdk.execute(document: document, variables: [:], environment: [:])
  #expect(result.exitCode == 5)
  #expect(transport.calls == 1)
  #expect(recorder.ownerOnlyModes == [true])
  #expect(recorder.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
}
@Test func catalogSnapshotFailuresPreserveRunnerErrorParity() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let oversizedBody = root.appendingPathComponent("oversized-body.json")
  let oversizedUpload = root.appendingPathComponent("oversized-upload.bin")
  try Data(repeating: 0x61, count: GatewayInputValidator.maximumBodyBytes + 1).write(to: oversizedBody)
  try Data([0x61, 0x62]).write(to: oversizedUpload)
  let cases = [
    CatalogSnapshotParityCase(
      role: .init(service: .sheets, accessMode: .write),
      operation: "spreadsheet batch-update",
      variables: [
        "spreadsheet-id": .string("sheet"),
        "confirm-spreadsheet-id": .string("sheet"),
        "input-file": .string(oversizedBody.path)
      ],
      directArguments: [
        "spreadsheet", "batch-update", "--spreadsheet-id", "sheet",
        "--confirm-spreadsheet-id", "sheet", "--input-file", oversizedBody.path
      ]
    ),
    CatalogSnapshotParityCase(
      role: .init(service: .drive, accessMode: .write),
      operation: "files upload",
      variables: ["input": .string(oversizedUpload.path), "max-bytes": .int(1)],
      directArguments: ["files", "upload", "--input", oversizedUpload.path, "--max-bytes", "1"]
    )
  ]
  for testCase in cases {
    let directAuthorizer = SDKFixtureAuthorizer()
    let directTransport = SDKFixtureTransport()
    let direct = GatewayCommandRunner(
      role: testCase.role,
      authorizer: directAuthorizer,
      transport: directTransport
    ).run(arguments: testCase.directArguments)
    #expect(direct.exitCode == 2, "operation: \(testCase.operation)")
    #expect(direct.stdout.contains("INPUT_TOO_LARGE"), "operation: \(testCase.operation)")
    let sdkAuthorizer = SDKFixtureAuthorizer()
    let sdkTransport = SDKFixtureTransport()
    let sdk = GoogleDocumentsGatewaySDK(
      role: testCase.role,
      authorizer: sdkAuthorizer,
      transport: sdkTransport,
      fileAccessPolicy: .init(inputRoots: [root])
    )
    let invoked = await sdk.invoke(
      .init(operation: testCase.operation, variables: testCase.variables),
      environment: [:]
    )
    #expect(invoked.exitCode == direct.exitCode, "operation: \(testCase.operation)")
    #expect(invoked.rawOutput == direct.stdout, "operation: \(testCase.operation)")
    #expect(invoked.errors.first?.code == "INPUT_TOO_LARGE", "operation: \(testCase.operation)")
    let operationAuthorizer = SDKFixtureAuthorizer()
    let operationTransport = SDKFixtureTransport()
    let operationRunner = GatewayCommandRunner(
      role: testCase.role,
      authorizer: operationAuthorizer,
      transport: operationTransport
    )
    let variables = try GatewayJSONValue.object(testCase.variables).jsonString()
    let operationRun = operationRunner.run(arguments: [
      "operation", "run"
    ] + testCase.operation.split(separator: " ").map(String.init) + ["--variables", variables])
    #expect(operationRun.exitCode == direct.exitCode, "operation: \(testCase.operation)")
    #expect(operationRun.stdout == direct.stdout, "operation: \(testCase.operation)")
    #expect(directAuthorizer.calls == 0, "operation: \(testCase.operation)")
    #expect(directTransport.calls == 0, "operation: \(testCase.operation)")
    #expect(sdkAuthorizer.calls == 0, "operation: \(testCase.operation)")
    #expect(sdkTransport.calls == 0, "operation: \(testCase.operation)")
    #expect(operationAuthorizer.calls == 0, "operation: \(testCase.operation)")
    #expect(operationTransport.calls == 0, "operation: \(testCase.operation)")
  }
}
@Test func filesUploadSnapshotsPreserveImplicitMetadataParity() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("implicit.csv")
  try Data("a,b\n1,2\n".utf8).write(to: input)
  let role = GatewayRole(service: .drive, accessMode: .write)
  let directTransport = SDKFixtureTransport(responses: uploadFixtureResponses())
  let direct = GatewayCommandRunner(
    role: role,
    authorizer: SDKFixtureAuthorizer(),
    transport: directTransport
  ).run(arguments: ["files", "upload", "--input", input.path, "--max-bytes", "64"])
  #expect(direct.exitCode == 0)
  let values: [String: GatewayJSONValue] = ["input": .string(input.path), "max-bytes": .int(64)]
  let sdkTransport = SDKFixtureTransport(responses: uploadFixtureResponses())
  let sdk = GoogleDocumentsGatewaySDK(
    role: role,
    authorizer: SDKFixtureAuthorizer(),
    transport: sdkTransport,
    fileAccessPolicy: .init(inputRoots: [root])
  )
  #expect((await sdk.invoke(.init(operation: "files upload", variables: values), environment: [:])).exitCode == 0)
  let operationTransport = SDKFixtureTransport(responses: uploadFixtureResponses())
  let operationRunner = GatewayCommandRunner(
    role: role,
    authorizer: SDKFixtureAuthorizer(),
    transport: operationTransport
  )
  let variables = try GatewayJSONValue.object(values).jsonString()
  let operation = operationRunner.run(arguments: [
    "operation", "run", "files", "upload", "--variables", variables
  ])
  #expect(operation.exitCode == 0)
  for transport in [directTransport, sdkTransport, operationTransport] {
    #expect(transport.methods == ["POST", "PUT"])
    let metadata = try JSONSerialization.jsonObject(with: try #require(transport.bodies.first ?? nil)) as? [String: String]
    #expect(metadata == ["mimeType": "text/csv", "name": "implicit.csv"])
    #expect(transport.headers.first?["X-Upload-Content-Type"] == "text/csv")
    #expect(transport.headers.first?["X-Upload-Content-Length"] == "8")
  }
}
@Test func sdkFileCapabilitiesDenyHostPathsAndPreventOutputClobberRaces() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let secret = root.appendingPathComponent("credentials.json")
  try Data("secret".utf8).write(to: secret)
  let authorizer = SDKFixtureAuthorizer()
  let transport = SDKFixtureTransport()
  let denied = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .write), authorizer: authorizer, transport: transport
  )
  let upload = await denied.invoke(.init(operation: "files upload", variables: [
    "input": .string(secret.path), "max-bytes": .int(64)
  ]), environment: [:])
  #expect(upload.exitCode == 2)
  #expect(upload.errors.first?.code == "INVALID_ARGUMENT")
  #expect(authorizer.calls == 0)
  #expect(transport.calls == 0)
  let output = root.appendingPathComponent("startup.conf")
  let readAuthorizer = SDKFixtureAuthorizer()
  let readTransport = SDKFixtureTransport()
  let readSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .read), authorizer: readAuthorizer, transport: readTransport
  )
  let download = await readSDK.invoke(.init(operation: "files download", variables: [
    "file-id": .string("file"), "output": .string(output.path), "max-bytes": .int(64), "overwrite": .bool(true)
  ]), environment: [:])
  #expect(download.exitCode == 2)
  #expect(readAuthorizer.calls == 0)
  #expect(readTransport.calls == 0)
  let writer = GatewaySDKFileAccessPolicy(outputRoots: [root]).outputWriter()
  try writer.validate(output.path, false)
  try Data("winner".utf8).write(to: output)
  #expect(throws: GatewayError.invalidArgument("Output exists; specify --overwrite")) {
    try writer.write(Data("loser".utf8), output.path, false)
  }
  #expect(try Data(contentsOf: output) == Data("winner".utf8))
  let protectedFile = root.deletingLastPathComponent().appendingPathComponent("sdk-protected-output-\(UUID().uuidString)")
  try Data("protected".utf8).write(to: protectedFile)
  defer { try? FileManager.default.removeItem(at: protectedFile) }
  let hardLink = root.appendingPathComponent("linked-output")
  #expect(Darwin.link(protectedFile.path, hardLink.path) == 0)
  #expect(throws: GatewayError.invalidArgument("SDK output must not reference a multiply linked file")) {
    try writer.write(Data("attacker".utf8), hardLink.path, true)
  }
  #expect(try Data(contentsOf: protectedFile) == Data("protected".utf8))
  let realRoot = root.appendingPathComponent("real/capability", isDirectory: true)
  try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
  try Data("input".utf8).write(to: realRoot.appendingPathComponent("input.txt"))
  let linkedAncestor = root.appendingPathComponent("linked", isDirectory: true)
  #expect(Darwin.symlink("real", linkedAncestor.path) == 0)
  let symlinkedRoot = linkedAncestor.appendingPathComponent("capability", isDirectory: true)
  let symlinkedInput = symlinkedRoot.appendingPathComponent("input.txt")
  let symlinkedWriter = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .write), fileAccessPolicy: .init(inputRoots: [symlinkedRoot]))
  #expect((await symlinkedWriter.invoke(.init(operation: "files upload", variables: ["input": .string(symlinkedInput.path), "max-bytes": .int(64), "dry-run": .bool(true)]), environment: [:])).exitCode == 2)
  let symlinkedOutput = symlinkedRoot.appendingPathComponent("output.txt")
  let symlinkedReader = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .read), fileAccessPolicy: .init(outputRoots: [symlinkedRoot]))
  #expect((await symlinkedReader.invoke(.init(operation: "files download", variables: ["file-id": .string("file"), "output": .string(symlinkedOutput.path), "max-bytes": .int(64)]), environment: [:])).exitCode == 2)
  let pinnedRoot = root.appendingPathComponent("pinned", isDirectory: true), pinnedInput = pinnedRoot.appendingPathComponent("input.txt")
  try FileManager.default.createDirectory(at: pinnedRoot, withIntermediateDirectories: true); try Data("approved".utf8).write(to: pinnedInput)
  let authorized = DispatchSemaphore(value: 0), continueRead = DispatchSemaphore(value: 0), pinnedTransport = SDKFixtureTransport(responses: uploadFixtureResponses())
  let pinned = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: pinnedTransport,
    fileAccessPolicy: .init(inputRoots: [pinnedRoot], inputAuthorizationObserver: { authorized.signal(); _ = continueRead.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) }))
  let pinnedTask = Task { await pinned.invoke(.init(operation: "files upload", variables: ["input": .string(pinnedInput.path), "max-bytes": .int(64)]), environment: [:]) }
  let inputAuthorized = await withCheckedContinuation { continuation in DispatchQueue.global().async { continuation.resume(returning: authorized.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)) } }
  #expect(inputAuthorized == .success); try FileManager.default.moveItem(at: pinnedInput, to: pinnedRoot.appendingPathComponent("replaced.txt")); try Data("attacker".utf8).write(to: pinnedInput); continueRead.signal()
  #expect((await pinnedTask.value).exitCode == 0); #expect(pinnedTransport.bodies.last! == Data("approved".utf8))
  let approvedAncestor = root.appendingPathComponent("current", isDirectory: true)
  let approvedRoot = approvedAncestor.appendingPathComponent("capability", isDirectory: true)
  let alternate = root.appendingPathComponent("alternate", isDirectory: true)
  try FileManager.default.createDirectory(at: approvedRoot, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: alternate.appendingPathComponent("capability"), withIntermediateDirectories: true)
  let approvedInput = approvedRoot.appendingPathComponent("input.txt")
  try Data("approved".utf8).write(to: approvedInput)
  let started = DispatchSemaphore(value: 0), proceed = DispatchSemaphore(value: 0)
  let synchronized = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .write),
    fileAccessPolicy: .init(inputRoots: [approvedRoot], rootComponentObserver: { component in
      if component == "current" { started.signal(); _ = proceed.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) }
    })
  )
  let replacement = Task { await synchronized.invoke(.init(operation: "files upload", variables: ["input": .string(approvedInput.path), "max-bytes": .int(64), "dry-run": .bool(true)]), environment: [:]) }
  let traversalStarted = await withCheckedContinuation { continuation in
    DispatchQueue.global().async { continuation.resume(returning: started.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)) }
  }
  #expect(traversalStarted == .success)
  try FileManager.default.moveItem(at: approvedAncestor, to: root.appendingPathComponent("prior-current"))
  #expect(Darwin.symlink("alternate", approvedAncestor.path) == 0)
  proceed.signal()
  #expect((await replacement.value).exitCode == 2)
}
@Test func sdkCancellationAndDeadlineReturnWithoutRetainingSnapshots() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json"); try Data("{\"requests\":[{\"addSheet\":{}}]}".utf8).write(to: input)
  let recorder = SnapshotPathRecorder()
  let snapshotter = CatalogFileSnapshotter { operation, variables in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: variables)
    recorder.record(snapshots.paths)
    return snapshots
  }
  let blocking = BlockingSDKFixtureTransport()
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: blocking,
    catalogFileSnapshotter: snapshotter, fileAccessPolicy: .init(inputRoots: [root]), executionPolicy: .init(timeout: 5, maximumConcurrentOperations: 1))
  let task = Task { await sdk.invoke(.init(operation: "spreadsheet batch-update", variables: ["spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"),
    "input-file": .string(input.path)]), environment: [:]) }
  let cancellationTransportEntered = await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: blocking.waitForEntry()) }
  }
  #expect(cancellationTransportEntered)
  task.cancel()
  let result = await task.value
  #expect(result.exitCode == 5)
  #expect(result.errors.first?.code == "OUTCOME_UNKNOWN")
  let cancellationTransportTerminated = await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: blocking.waitForTermination()) }
  }
  #expect(cancellationTransportTerminated)
  let followUp = await sdk.invoke(.init(operation: "spreadsheet create", variables: ["title": .string("Follow-up"), "dry-run": .bool(true)]), environment: [:])
  #expect(followUp.exitCode == 0)
  #expect(blocking.snapshot.cancellations == 1)
  #expect(recorder.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
  #expect(blocking.snapshot.calls == 1)
  let timeoutRecorder = SnapshotPathRecorder()
  let timeoutSnapshotter = CatalogFileSnapshotter { operation, variables in
    let snapshots = try CatalogFileSnapshots.capture(operation: operation, variables: variables)
    timeoutRecorder.record(snapshots.paths)
    return snapshots
  }
  let timeoutTransport = BlockingSDKFixtureTransport()
  let timedOut = GoogleDocumentsGatewaySDK(role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: timeoutTransport,
    catalogFileSnapshotter: timeoutSnapshotter, fileAccessPolicy: .init(inputRoots: [root]), executionPolicy: .init(timeout: 2, maximumConcurrentOperations: 1))
  let timeoutTask = Task { await timedOut.invoke(.init(operation: "spreadsheet batch-update", variables: ["spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"),
    "input-file": .string(input.path)]), environment: [:]) }
  let timeoutTransportEntered = await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: timeoutTransport.waitForEntry()) }
  }
  #expect(timeoutTransportEntered)
  let timeout = await timeoutTask.value
  #expect(timeout.exitCode == 5)
  #expect(timeout.errors.first?.code == "OUTCOME_UNKNOWN")
  let timeoutTransportTerminated = await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: timeoutTransport.waitForTermination()) }
  }
  #expect(timeoutTransportTerminated)
  let timeoutFollowUp = await timedOut.invoke(.init(operation: "spreadsheet create", variables: ["title": .string("Timeout follow-up"), "dry-run": .bool(true)]), environment: [:])
  #expect(timeoutFollowUp.exitCode == 0)
  #expect(timeoutTransport.terminationCount == 1)
  #expect(timeoutRecorder.paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
  #expect(timeoutTransport.snapshot.calls == 1)
}
@Test func sdkCancelledFilesystemTraversalReleasesTheSingleWorker() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json"); try Data("{\"requests\":[]}".utf8).write(to: input)
  let traversal = FilesystemTraversalProbe()
  let policy = GatewaySDKFileAccessPolicy(inputRoots: [root], rootComponentObserver: { _ in traversal.delayOnce() })
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), fileAccessPolicy: policy,
    executionPolicy: .init(timeout: 0.01, maximumConcurrentOperations: 1)
  )
  let timedOut = await sdk.invoke(.init(operation: "spreadsheet batch-update", variables: [
    "spreadsheet-id": .string("sheet"), "confirm-spreadsheet-id": .string("sheet"),
    "input-file": .string(input.path), "dry-run": .bool(true)
  ]), environment: [:])
  #expect(timedOut.errors.first?.message == "SDK execution exceeded its deadline")
  let reachedCancellationCheckpoint = await withCheckedContinuation { continuation in
    DispatchQueue.global().async { continuation.resume(returning: traversal.waitForCheckpoint()) }
  }
  #expect(reachedCancellationCheckpoint)
  try await Task.sleep(nanoseconds: 10_000_000)
  #expect((await sdk.execute(document: "[\"schema\",\"print\"]", variables: [:], environment: [:])).exitCode == 0)
}
@Test func sdkDescriptorTraversalClosesFailedIntermediateParentExactlyOnce() {
  var closed: [Int32] = []
  let operations = GatewaySDKDescriptorOperations(open: { _, _ in 10 }, openAt: { descriptor, component, _ in component == "missing" ? -1 : descriptor + 1 }, close: { descriptor in closed.append(descriptor); return 0 })
  #expect(GatewaySDKCommandRouter.boundedVariablesFile(at: "/parent/missing/variables.json", descriptorOperations: operations) == nil)
  #expect(closed == [10, 11])
}
@Test func sdkTransferLimitsCancelAtLimitPlusOneAndRejectIncapableTransports() async throws {
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }; let bounded = BoundedSDKTransferTransport()
  let driveRead = GatewayRole(service: .drive, accessMode: .read)
  let sdk = GoogleDocumentsGatewaySDK(role: driveRead, authorizer: SDKFixtureAuthorizer(), transport: bounded,
    fileAccessPolicy: .init(outputRoots: [root]), executionPolicy: .init(timeout: .greatestFiniteMagnitude))
  let output = root.appendingPathComponent("output")
  let request = GatewayOperationRequest(operation: "files download", variables: ["file-id": .string("file"), "output": .string(output.path), "max-bytes": .int(3), "overwrite": .bool(true)])
  let result = await sdk.invoke(request, environment: [:])
  #expect(result.errors.first?.code == "TRANSFER_LIMIT_EXCEEDED"); #expect(bounded.maximumResponseBytes == 3); #expect(bounded.timeout == GatewaySDKExecutionPolicy.maximumTimeout)
  let ordinary = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .read), authorizer: SDKFixtureAuthorizer(), transport: bounded, executionPolicy: .init(maximumResponseBytes: 3))
  #expect((await ordinary.invoke(.init(operation: "document get", variables: ["document-id": .string("doc")]), environment: [:])).errors.first?.code == "TRANSPORT_FAILURE")
  let smaller = GoogleDocumentsGatewaySDK(role: driveRead, authorizer: SDKFixtureAuthorizer(), transport: bounded,
    fileAccessPolicy: .init(outputRoots: [root]), executionPolicy: .init(maximumResponseBytes: 2))
  #expect((await smaller.invoke(request, environment: [:])).errors.first?.code == "TRANSFER_LIMIT_EXCEEDED"); #expect(bounded.maximumResponseBytes == 2)
  #expect(!FileManager.default.fileExists(atPath: output.path))
  #expect(GatewaySDKExecutionPolicy(maximumResponseBytes: .max).maximumResponseBytes == GatewaySDKExecutionPolicy.maximumResponseBytes); let incapable = UnboundedSDKTransferTransport()
  let rejected = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .read), authorizer: SDKFixtureAuthorizer(), transport: incapable, fileAccessPolicy: .init(outputRoots: [root]))
  #expect((await rejected.invoke(request, environment: [:])).errors.first?.code == "TRANSPORT_FAILURE"); #expect(incapable.calls == 0)
  let session = URLSession(configuration: .ephemeral); let task = session.dataTask(with: URL(string: "https://example.invalid")!); let state = GatewaySDKTransportState(maximumResponseBytes: 3)
  state.urlSession(session, dataTask: task, didReceive: Data(repeating: 0, count: 3))
  #expect(!state.exceededLimit); #expect(state.data?.count == 3)
  state.urlSession(session, dataTask: task, didReceive: Data([0]))
  #expect(state.exceededLimit); #expect(state.data?.count == 4); #expect(task.state == .canceling)
}
