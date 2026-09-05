import Darwin
import Foundation
import GatewaySDKKit

/// Owns the descriptor that was capability-authorized for one catalog input. Keeping this
/// descriptor open makes validation and snapshotting one operation rather than two path walks.
final class GatewaySDKAuthorizedInput: @unchecked Sendable {
  private let lock = NSLock()
  private var descriptor: Int32

  init(descriptor: Int32) { self.descriptor = descriptor }
  deinit { close() }

  func read(maximumBytes: Int, cancellation: GatewaySDKCancellation?) throws -> Data {
    lock.lock()
    let current = descriptor
    descriptor = -1
    lock.unlock()
    guard current >= 0 else { throw GatewayError.invalidArgument("Catalog input was already consumed") }
    defer { Darwin.close(current) }
    try checkCancellation(cancellation)
    let data = try CatalogFileSnapshots.readBoundedData(
      from: current, maximumBytes: maximumBytes, cancellation: cancellation
    )
    guard data.count <= maximumBytes else { throw GatewayError.inputTooLarge }
    try checkCancellation(cancellation)
    return data
  }

  func close() {
    lock.lock()
    let current = descriptor
    descriptor = -1
    lock.unlock()
    if current >= 0 { Darwin.close(current) }
  }
}

func checkCancellation(_ cancellation: GatewaySDKCancellation?) throws {
  if cancellation?.isCancelled == true {
    throw GatewayError.transportFailure("SDK execution was cancelled")
  }
}

/// A private staging artifact whose cleanup was not completed. The policy retains its authorized
/// parent descriptor until a caller explicitly retries cleanup or releases the policy.
public struct GatewaySDKOutputCleanupRecovery: Sendable, Equatable {
  /// Stable descriptor-bound identity used to retry only this recovery artifact.
  public let id: UUID
  public let path: String
}

private final class GatewaySDKOutputCleanupRegistry: @unchecked Sendable {
  private struct Entry {
    let id: UUID
    let parent: Int32
    let leaf: String
    let recovery: GatewaySDKOutputCleanupRecovery
  }

  private let lock = NSLock()
  private var entries: [Entry] = []
  private var retryInProgress = false

  deinit {
    lock.lock()
    let pending = entries
    entries = []
    lock.unlock()
    for entry in pending { Darwin.close(entry.parent) }
  }

  @discardableResult
  func retain(parent: Int32, leaf: String, path: String) -> GatewaySDKOutputCleanupRecovery {
    let recovery = GatewaySDKOutputCleanupRecovery(id: UUID(), path: path)
    lock.lock()
    entries.append(.init(id: recovery.id, parent: parent, leaf: leaf, recovery: recovery))
    lock.unlock()
    return recovery
  }

  func recoveries() -> [GatewaySDKOutputCleanupRecovery] {
    lock.lock(); defer { lock.unlock() }
    return entries.map(\.recovery)
  }

  func retry(
    recoveryID: UUID, using unlinker: @escaping @Sendable (Int32, String) -> Int32
  ) -> [GatewaySDKOutputCleanupRecovery] {
    lock.lock()
    guard !retryInProgress else {
      let recoveries = entries.map(\.recovery)
      lock.unlock()
      return recoveries
    }
    retryInProgress = true
    let pending = entries.filter { $0.id == recoveryID }
    lock.unlock()
    var released: [Int32] = []
    // Calling this public retry API is an explicit caller decision after it has reconciled any
    // uncertain publication. Keep entries visible while unlinking, and release a descriptor only
    // after its descriptor-relative unlink succeeds.
    for entry in pending where unlinker(entry.parent, entry.leaf) == 0 {
      released.append(entry.parent)
    }
    lock.lock()
    entries.removeAll { entry in released.contains(entry.parent) && entry.id == recoveryID }
    retryInProgress = false
    let recoveries = entries.map(\.recovery)
    lock.unlock()
    for descriptor in released { Darwin.close(descriptor) }
    return recoveries
  }
}

/// Explicit filesystem capabilities for a long-lived SDK host; callers opt in with owned roots.
public struct GatewaySDKFileAccessPolicy: Sendable {
  private enum OutputDestination: Equatable {
    case missing
    case regular(device: UInt64, inode: UInt64, links: UInt64)
  }

  public let inputRoots: [URL]; public let outputRoots: [URL]
  private let outputDataWriter: @Sendable (Data, Int32, GatewaySDKCancellation?) throws -> Void
  private let outputSynchronizer: @Sendable (Int32) throws -> Void; private let outputCommitObserver: @Sendable (Bool) -> Void
  private let outputPreSwapObserver: @Sendable () -> Void
  private let outputNoOverwritePublisher: @Sendable (Int32, String, Int32, String) -> Int32
  private let outputSwapper: @Sendable (Int32, String, Int32, String) -> Int32
  private let outputUnlinker: @Sendable (Int32, String) -> Int32
  private let outputCleanupRegistry: GatewaySDKOutputCleanupRegistry
  let cancellationAttemptObserver: @Sendable () -> Void
  private let rootComponentObserver: @Sendable (String) -> Void
  private let inputAuthorizationObserver: @Sendable () -> Void

  public init(inputRoots: [URL] = [], outputRoots: [URL] = []) {
    self.inputRoots = inputRoots.map(\.standardizedFileURL)
    self.outputRoots = outputRoots.map(\.standardizedFileURL)
    outputDataWriter = Self.writeAll
    outputSynchronizer = Self.synchronize
    outputCommitObserver = { _ in }
    outputPreSwapObserver = {}
    outputNoOverwritePublisher = Self.publishWithoutOverwrite
    outputSwapper = Self.swapOutputEntries
    outputUnlinker = Self.unlinkOutput
    outputCleanupRegistry = .init()
    cancellationAttemptObserver = {}
    rootComponentObserver = { _ in }
    inputAuthorizationObserver = {}
  }

  init(
    inputRoots: [URL] = [], outputRoots: [URL] = [],
    rootComponentObserver: @escaping @Sendable (String) -> Void = { _ in },
    inputAuthorizationObserver: @escaping @Sendable () -> Void = {},
    cancellationAttemptObserver: @escaping @Sendable () -> Void = {}
  ) {
    self.inputRoots = inputRoots.map(\.standardizedFileURL)
    self.outputRoots = outputRoots.map(\.standardizedFileURL)
    outputDataWriter = Self.writeAll
    outputSynchronizer = Self.synchronize
    outputCommitObserver = { _ in }
    outputPreSwapObserver = {}
    outputNoOverwritePublisher = Self.publishWithoutOverwrite
    outputSwapper = Self.swapOutputEntries
    outputUnlinker = Self.unlinkOutput
    outputCleanupRegistry = .init()
    self.cancellationAttemptObserver = cancellationAttemptObserver
    self.rootComponentObserver = rootComponentObserver
    self.inputAuthorizationObserver = inputAuthorizationObserver
  }

  init(
    inputRoots: [URL] = [], outputRoots: [URL] = [],
    outputDataWriter: @escaping @Sendable (Data, Int32, GatewaySDKCancellation?) throws -> Void,
    outputSynchronizer: @escaping @Sendable (Int32) throws -> Void,
    outputCommitObserver: @escaping @Sendable (Bool) -> Void = { _ in },
    outputPreSwapObserver: @escaping @Sendable () -> Void = {},
    outputNoOverwritePublisher: @escaping @Sendable (Int32, String, Int32, String) -> Int32 = Self.publishWithoutOverwrite,
    outputSwapper: @escaping @Sendable (Int32, String, Int32, String) -> Int32 = Self.swapOutputEntries,
    outputUnlinker: @escaping @Sendable (Int32, String) -> Int32 = Self.unlinkOutput,
    cancellationAttemptObserver: @escaping @Sendable () -> Void = {},
    rootComponentObserver: @escaping @Sendable (String) -> Void = { _ in },
    inputAuthorizationObserver: @escaping @Sendable () -> Void = {}
  ) {
    self.inputRoots = inputRoots.map(\.standardizedFileURL)
    self.outputRoots = outputRoots.map(\.standardizedFileURL)
    self.outputDataWriter = outputDataWriter
    self.outputSynchronizer = outputSynchronizer
    self.outputCommitObserver = outputCommitObserver
    self.outputPreSwapObserver = outputPreSwapObserver
    self.outputNoOverwritePublisher = outputNoOverwritePublisher
    self.outputSwapper = outputSwapper
    self.outputUnlinker = outputUnlinker
    outputCleanupRegistry = .init()
    self.cancellationAttemptObserver = cancellationAttemptObserver
    self.rootComponentObserver = rootComponentObserver
    self.inputAuthorizationObserver = inputAuthorizationObserver
  }

  public static let denyAll = Self()
  static let commandLine = Self(inputRoots: [URL(fileURLWithPath: "/")], outputRoots: [URL(fileURLWithPath: "/")])

  /// Retries exactly one descriptor-bound recovery artifact. It never touches another request's
  /// pending artifact, even when both artifacts share an output directory.
  public func retryPendingOutputCleanup(
    recoveryID: UUID
  ) -> [GatewaySDKOutputCleanupRecovery] {
    outputCleanupRegistry.retry(recoveryID: recoveryID, using: outputUnlinker)
  }

  /// Recovery artifacts still owned by this policy's descriptor-bound cleanup registry.
  public var pendingOutputCleanupRecoveries: [GatewaySDKOutputCleanupRecovery] {
    outputCleanupRegistry.recoveries()
  }

  func validateInput(path: String, argument: String, cancellation: GatewaySDKCancellation? = nil) throws {
    let input = try authorizeInput(path: path, argument: argument, cancellation: cancellation)
    input.close()
  }

  func authorizeInput(
    path: String, argument: String, cancellation: GatewaySDKCancellation? = nil
  ) throws -> GatewaySDKAuthorizedInput {
    .init(descriptor: try openInput(path: path, argument: argument, cancellation: cancellation))
  }

  func readInput(
    path: String,
    argument: String,
    maximumBytes: Int,
    cancellation: GatewaySDKCancellation? = nil
  ) throws -> Data {
    try checkCancellation(cancellation)
    return try authorizeInput(path: path, argument: argument, cancellation: cancellation).read(
      maximumBytes: maximumBytes, cancellation: cancellation
    )
  }

  func outputWriter(cancellation: GatewaySDKCancellation? = nil) -> GatewayOutputWriter {
    GatewayOutputWriter(
      validate: { path, overwrite in
        try checkCancellation(cancellation)
        try validateOutput(path: path, overwrite: overwrite, cancellation: cancellation)
      },
      write: { data, path, overwrite in
        try checkCancellation(cancellation)
        try writeOutput(data, path: path, overwrite: overwrite, cancellation: cancellation)
      }
    )
  }

  private func openInput(
    path: String, argument: String, cancellation: GatewaySDKCancellation?
  ) throws -> Int32 {
    guard path != "-" else { throw CatalogFileArgumentError.standardInput(name: argument) }
    let (parent, leaf) = try parentDescriptor(
      path: path, roots: inputRoots, kind: "input", cancellation: cancellation
    )
    defer { Darwin.close(parent) }
    try checkCancellation(cancellation)
    let descriptor = leaf.withCString { Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
    guard descriptor >= 0 else { throw GatewayError.invalidArgument("--\(argument) is outside the SDK input capability") }
    var ownsDescriptor = true
    defer { if ownsDescriptor { Darwin.close(descriptor) } }
    try checkCancellation(cancellation)
    var status = stat()
    guard Darwin.fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
      throw CatalogFileArgumentError.notRegularFile(name: argument)
    }
    guard status.st_nlink == 1 else {
      throw GatewayError.invalidArgument("SDK input must not reference a multiply linked file")
    }
    inputAuthorizationObserver()
    // Ownership transfers to the authorized input only after the final cancellation check.
    try checkCancellation(cancellation)
    ownsDescriptor = false
    return descriptor
  }

  private func validateOutput(
    path: String, overwrite: Bool, cancellation: GatewaySDKCancellation?
  ) throws {
    let (parent, leaf) = try parentDescriptor(
      path: path, roots: outputRoots, kind: "output", cancellation: cancellation
    )
    defer { Darwin.close(parent) }
    _ = try outputDestination(parent: parent, leaf: leaf, overwrite: overwrite, cancellation: cancellation)
  }

  /// Resolves the destination against an already-authorized parent descriptor. The returned
  /// identity is used by overwrite publication to reject a replacement between staging and commit.
  private func outputDestination(
    parent: Int32, leaf: String, overwrite: Bool, cancellation: GatewaySDKCancellation? = nil
  ) throws -> OutputDestination {
    try checkCancellation(cancellation)
    var status = stat()
    let exists = leaf.withCString { Darwin.fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW) == 0 }
    guard exists else {
      guard errno == ENOENT else { throw GatewayError.invalidArgument("Unable to write SDK output") }
      return .missing
    }
    guard overwrite else { throw GatewayError.invalidArgument("Output exists; specify --overwrite") }
    guard (status.st_mode & S_IFMT) == S_IFREG else {
      throw GatewayError.invalidArgument("SDK output must reference a regular file")
    }
    guard status.st_nlink == 1 else {
      throw GatewayError.invalidArgument("SDK output must not reference a multiply linked file")
    }
    return .regular(
      device: UInt64(status.st_dev), inode: UInt64(status.st_ino), links: UInt64(status.st_nlink)
    )
  }

  /// Atomically exchanges a staged result with the destination and validates the displaced inode.
  /// A changed destination is never reported as success: publication remains recoverable under its
  /// private staging name and the caller receives a non-retryable outcome-unknown result.
  private func publishOverwrite(
    parent: Int32, temporary: String, destination: String, expected: OutputDestination
  ) throws {
    guard expected != .missing else {
      guard outputNoOverwritePublisher(parent, temporary, parent, destination) == 0 else {
        throw GatewayError.invalidArgument("SDK output changed before commit")
      }
      return
    }
    guard try outputDestination(
      parent: parent, leaf: destination, overwrite: true
    ) == expected else {
      throw GatewayError.invalidArgument("SDK output changed before commit")
    }
    outputPreSwapObserver()
    guard outputSwapper(parent, temporary, parent, destination) == 0 else {
      throw GatewayError.invalidArgument("Unable to write SDK output")
    }
    guard (try? outputDestination(parent: parent, leaf: temporary, overwrite: true)) == expected else {
      throw GatewayError.transportFailure("OUTCOME_UNKNOWN: SDK_LOCAL_PUBLICATION_UNCERTAIN; do not retry without reconciliation.")
    }
    // `RENAME_SWAP` leaves the approved old destination at the staging name. Do not publish a
    // success result if it cannot be removed: restore the prior destination and leave cleanup
    // ownership with writeOutput's defer.
    guard outputUnlinker(parent, temporary) == 0 else {
      guard outputSwapper(parent, temporary, parent, destination) == 0 else {
        throw GatewayError.transportFailure("OUTCOME_UNKNOWN: SDK_LOCAL_PUBLICATION_UNCERTAIN; do not retry without reconciliation.")
      }
      throw GatewayError.invalidArgument("Unable to write SDK output")
    }
  }

  private func writeOutput(
    _ data: Data,
    path: String,
    overwrite: Bool,
    cancellation: GatewaySDKCancellation?
  ) throws {
    let (parent, leaf) = try parentDescriptor(
      path: path, roots: outputRoots, kind: "output", cancellation: cancellation
    )
    var ownsParent = true
    defer { if ownsParent { Darwin.close(parent) } }
    // Keep the authorized parent open from validation through publication. For overwrite, record
    // the approved destination identity and require it again immediately before replacement.
    let expectedDestination = try outputDestination(
      parent: parent, leaf: leaf, overwrite: overwrite, cancellation: cancellation
    )
    let destination = ".google-documents-gateway-sdk-\(UUID().uuidString)"
    var temporaryLeaf: String? = destination
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
    try checkCancellation(cancellation)
    let descriptor = destination.withCString { Darwin.openat(parent, $0, flags, S_IRUSR | S_IWUSR) }
    guard descriptor >= 0 else {
      throw GatewayError.invalidArgument(overwrite ? "Unable to write SDK output" : "Output exists; specify --overwrite")
    }
    var failure: Error?
    do {
      try outputDataWriter(data, descriptor, cancellation)
      try checkCancellation(cancellation)
      try outputSynchronizer(descriptor)
      let commit = {
        outputCommitObserver(overwrite)
        if overwrite {
          try publishOverwrite(
            parent: parent, temporary: destination, destination: leaf, expected: expectedDestination
          )
        } else {
          guard outputNoOverwritePublisher(parent, destination, parent, leaf) == 0 else {
            throw GatewayError.invalidArgument("Output exists; specify --overwrite")
          }
        }
      }
      if let cancellation {
        try cancellation.commit(commit) { error in
          guard
            case GatewayError.transportFailure = error,
            let temporary = temporaryLeaf
          else { return }
          let recovery = recoveryPath(path, temporary: temporary)
          outputCleanupRegistry.retain(parent: parent, leaf: temporary, path: recovery)
          ownsParent = false
          temporaryLeaf = nil
          failure = GatewayError.transportFailure("OUTCOME_UNKNOWN: SDK_LOCAL_PUBLICATION_UNCERTAIN; do not retry without reconciliation. recovery_path=\(recovery)")
        }
      } else { try commit() }
      temporaryLeaf = nil
    } catch let error as GatewayError {
      if case .transportFailure(let message) = error, message.hasPrefix("OUTCOME_UNKNOWN:"),
        let temporary = temporaryLeaf {
        // A failed rollback may leave the prior destination at the private staging name. Retain
        // the authorized descriptor before relinquishing the local name, so policy release owns
        // its lifetime and callers can query a stable, machine-readable recovery path.
        let recovery = recoveryPath(path, temporary: temporary)
        outputCleanupRegistry.retain(parent: parent, leaf: temporary, path: recovery)
        ownsParent = false
        temporaryLeaf = nil
        failure = GatewayError.transportFailure("\(message) recovery_path=\(recovery)")
      } else if failure == nil {
        failure = error
      }
    } catch {
      failure = error
    }
    Darwin.close(descriptor)
    if let temporary = temporaryLeaf {
      let cleanupFailure: () -> GatewayError? = {
        guard outputUnlinker(parent, temporary) != 0 else { return nil }
        let recovery = recoveryPath(path, temporary: temporary)
        outputCleanupRegistry.retain(parent: parent, leaf: temporary, path: recovery)
        ownsParent = false
        return GatewayError.transportFailure(
          "SDK output staging cleanup failed; recovery_path=\(recovery)"
        )
      }
      let recoveryError: GatewayError?
      if let cancellation {
        recoveryError = try cancellation.commitLocalCleanup(cleanupFailure)
      } else {
        recoveryError = cleanupFailure()
      }
      if let recoveryError { throw recoveryError }
    }
    if let failure { throw failure }
  }

  private func recoveryPath(_ output: String, temporary: String) -> String {
    URL(fileURLWithPath: output).standardizedFileURL.deletingLastPathComponent()
      .appendingPathComponent(temporary).path
  }

  private static func writeAll(_ data: Data, _ descriptor: Int32, _ cancellation: GatewaySDKCancellation?) throws {
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        if cancellation?.isCancelled == true { throw GatewayError.transportFailure("SDK execution was cancelled") }
        let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        guard count > 0 else { throw GatewayError.invalidArgument("Unable to write SDK output") }
        offset += count
      }
    }
  }

  private static func synchronize(_ descriptor: Int32) throws {
    guard Darwin.fsync(descriptor) == 0 else { throw GatewayError.invalidArgument("Unable to write SDK output") }
  }

  /// Publishes the staged inode with a kernel-enforced no-replace operation.  The former
  /// link/unlink sequence could expose a second name if cleanup failed after publication.
  private static func publishWithoutOverwrite(_ sourceDirectory: Int32, _ source: String, _ destinationDirectory: Int32, _ destination: String) -> Int32 {
    source.withCString { sourcePointer in
      destination.withCString { destinationPointer in
        renameatx_np(sourceDirectory, sourcePointer, destinationDirectory, destinationPointer, UInt32(RENAME_EXCL))
      }
    }
  }

  private static func swapOutputEntries(_ sourceDirectory: Int32, _ source: String, _ destinationDirectory: Int32, _ destination: String) -> Int32 {
    source.withCString { sourcePointer in
      destination.withCString { destinationPointer in
        renameatx_np(sourceDirectory, sourcePointer, destinationDirectory, destinationPointer, UInt32(RENAME_SWAP))
      }
    }
  }

  private static func unlinkOutput(_ parent: Int32, _ leaf: String) -> Int32 {
    leaf.withCString { Darwin.unlinkat(parent, $0, 0) }
  }

  private func checkCancellation(_ cancellation: GatewaySDKCancellation?) throws {
    if cancellation?.isCancelled == true {
      throw GatewayError.transportFailure("SDK execution was cancelled")
    }
  }

  private func parentDescriptor(
    path: String, roots: [URL], kind: String, cancellation: GatewaySDKCancellation?
  ) throws -> (Int32, String) {
    try checkCancellation(cancellation)
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard url.isFileURL else { throw GatewayError.invalidArgument("SDK \(kind) paths must be file paths") }
    guard let root = roots.first(where: { $0.path == "/" || url.path.hasPrefix($0.path + "/") }) else {
      throw GatewayError.invalidArgument("Path is outside the SDK \(kind) capability")
    }
    let relative = root.path == "/" ? String(url.path.dropFirst()) : String(url.path.dropFirst(root.path.count + 1))
    let components = relative.split(separator: "/").map(String.init)
    guard let leaf = components.last, !leaf.isEmpty else { throw GatewayError.invalidArgument("SDK \(kind) path must name a file") }
    let rootComponents = root.path.split(separator: "/").map(String.init)
    var descriptor = "/".withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
    guard descriptor >= 0 else { throw GatewayError.invalidArgument("SDK \(kind) capability root is unavailable") }
    var transferred = false
    defer { if !transferred { Darwin.close(descriptor) } }
    for component in rootComponents {
      try checkCancellation(cancellation)
      rootComponentObserver(component)
      try checkCancellation(cancellation)
      let next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
      guard next >= 0 else { throw GatewayError.invalidArgument("SDK \(kind) capability root is unavailable") }
      Darwin.close(descriptor)
      descriptor = next
    }
    for component in components.dropLast() {
      try checkCancellation(cancellation)
      let next = component.withCString { Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
      guard next >= 0 else { throw GatewayError.invalidArgument("SDK \(kind) path contains an unsafe directory") }
      Darwin.close(descriptor)
      descriptor = next
    }
    try checkCancellation(cancellation)
    transferred = true
    return (descriptor, leaf)
  }
}
