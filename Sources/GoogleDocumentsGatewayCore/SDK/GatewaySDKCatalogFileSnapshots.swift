import Darwin
import Foundation
import GatewaySDKKit

struct RawCatalogArguments {
  let values: [String: GatewayJSONValue]
  let fileValues: [String: GatewayJSONValue]
  let locations: [String: RawOptionLocation]
  let fileLocations: [String: RawOptionLocation]
}

struct RawCommand {
  let name: String
  let tokenCount: Int
}

enum RawOptionLocation {
  case inline(index: Int, name: String)
  case separate(index: Int)

  func replace(with value: String, in arguments: inout [String]) {
    switch self {
    case .inline(let index, let name):
      arguments[index] = "--\(name)=\(value)"
    case .separate(let index):
      arguments[index] = value
    }
  }
}

struct CatalogPreparedArguments: Sendable {
  let argv: [String]
  let inputDataOverrides: [String: Data]
  private let snapshots: CatalogFileSnapshots

  init(
    argv: [String], snapshotPaths: [String] = [], inputDataOverrides: [String: Data] = [:],
    snapshots: CatalogFileSnapshots? = nil
  ) {
    self.argv = argv
    self.inputDataOverrides = snapshots?.inputDataOverrides ?? inputDataOverrides
    self.snapshots = snapshots ?? .init(variables: [:], paths: snapshotPaths, inputDataOverrides: inputDataOverrides)
  }

  @discardableResult
  func cleanup() -> Error? {
    snapshots.cleanupError()
  }

  func cleanupError() -> Error? {
    snapshots.cleanupError()
  }
}

struct CatalogFileSnapshotter: Sendable {
  let prepare: @Sendable (GatewayOperation, [String: GatewayJSONValue]) throws -> CatalogFileSnapshots
  private let isLive: Bool

  init(
    prepare: @escaping @Sendable (GatewayOperation, [String: GatewayJSONValue]) throws -> CatalogFileSnapshots
  ) {
    self.prepare = prepare
    isLive = false
  }

  private init(live: Bool) {
    prepare = { operation, variables in try CatalogFileSnapshots.capture(operation: operation, variables: variables) }
    isLive = live
  }

  func prepare(
    _ operation: GatewayOperation,
    _ variables: [String: GatewayJSONValue],
    sourceReader: @escaping (String, String, Int) throws -> Data,
    cancellation: GatewaySDKCancellation? = nil,
    cleanupRegistry: GatewaySDKSnapshotCleanupRegistry? = nil
  ) throws -> CatalogFileSnapshots {
    if isLive {
      return try CatalogFileSnapshots.capture(
        operation: operation,
        variables: variables,
        sourceReader: sourceReader,
        cancellation: cancellation,
        cleanupRegistry: cleanupRegistry
      )
    }
    try checkCancellation(cancellation)
    let snapshots = try prepare(operation, variables)
    do {
      try checkCancellation(cancellation)
      return snapshots
    } catch {
      if let cleanupError = snapshots.cleanupError() { throw cleanupError }
      throw error
    }
  }

  static let live = Self(live: true)
}

struct CatalogFileSnapshots: Sendable {
  let variables: [String: GatewayJSONValue]
  let paths: [String]
  let inputDataOverrides: [String: Data]
  private let cleanupState: CatalogSnapshotCleanupState

  init(
    variables: [String: GatewayJSONValue], paths: [String], inputDataOverrides: [String: Data] = [:]
  ) {
    self.init(
      variables: variables, paths: paths, inputDataOverrides: inputDataOverrides,
      cleanupState: .init()
    )
  }

  private init(
    variables: [String: GatewayJSONValue], paths: [String], inputDataOverrides: [String: Data],
    cleanupState: CatalogSnapshotCleanupState
  ) {
    self.variables = variables
    self.paths = paths
    self.inputDataOverrides = inputDataOverrides
    self.cleanupState = cleanupState
  }

  static func capture(
    operation: GatewayOperation,
    variables: [String: GatewayJSONValue],
    dataReader: ((Int32, Int) throws -> Data)? = nil,
    sourceReader: ((String, String, Int) throws -> Data)? = nil,
    cancellation: GatewaySDKCancellation? = nil,
    cleanupRegistry: GatewaySDKSnapshotCleanupRegistry? = nil,
    cleanupState: CatalogSnapshotCleanupState? = nil
  ) throws -> Self {
    var snapshotVariables = variables
    var paths: [String] = []
    var inputDataOverrides: [String: Data] = [:]
    let cleanupState = cleanupState ?? CatalogSnapshotCleanupState(recoveryRegistry: cleanupRegistry)
    do {
      for argument in operation.arguments where ["input", "input-file", "json-file"].contains(argument.name) {
        try checkCancellation(cancellation)
        guard case .string(let sourcePath) = variables[argument.name] else { continue }
        let maximumBytes = try maximumBytes(for: argument.name, variables: variables)
        if operation.name == "files upload", argument.name == "input" {
          try preserveFilesUploadDefaults(
            sourcePath: sourcePath,
            sourceVariables: variables,
            snapshotVariables: &snapshotVariables
          )
        }
        let data = try sourceReader?(sourcePath, argument.name, maximumBytes)
          ?? boundedData(
            at: sourcePath,
            argumentName: argument.name,
            maximumBytes: maximumBytes,
            dataReader: dataReader
          )
        let snapshotPath = try writeSnapshot(data, cleanupState: cleanupState, cancellation: cancellation)
        snapshotVariables[argument.name] = .string(snapshotPath)
        paths.append(snapshotPath)
        inputDataOverrides[snapshotPath] = data
      }
      return Self(
        variables: snapshotVariables, paths: paths, inputDataOverrides: inputDataOverrides,
        cleanupState: cleanupState
      )
    } catch {
      if let cleanupError = cleanupState.cleanupError() { throw cleanupError }
      throw error
    }
  }

  @discardableResult
  func cleanup() -> Error? {
    cleanupError()
  }

  func cleanupError() -> Error? {
    cleanupState.cleanupError()
  }

  func replacing(variables: [String: GatewayJSONValue]) -> Self {
    Self(
      variables: variables, paths: paths, inputDataOverrides: inputDataOverrides,
      cleanupState: cleanupState
    )
  }

  private static func preserveFilesUploadDefaults(
    sourcePath: String,
    sourceVariables: [String: GatewayJSONValue],
    snapshotVariables: inout [String: GatewayJSONValue]
  ) throws {
    var options = ["input": [sourcePath]]
    for name in ["name", "mime-type"] {
      if case .string(let value) = sourceVariables[name] {
        options[name] = [value]
      }
    }
    let metadata = try GatewayReadableInput.driveUploadMetadata(options)
    guard
      let name = metadata["name"] as? String,
      let mimeType = metadata["mimeType"] as? String
    else {
      throw GatewayError.invalidArgument("Unable to derive files upload metadata")
    }
    if sourceVariables["name"] == nil || sourceVariables["name"] == .null {
      snapshotVariables["name"] = .string(name)
    }
    if sourceVariables["mime-type"] == nil || sourceVariables["mime-type"] == .null {
      snapshotVariables["mime-type"] = .string(mimeType)
    }
  }

  private static func maximumBytes(
    for argumentName: String,
    variables: [String: GatewayJSONValue]
  ) throws -> Int {
    guard argumentName == "input" else { return GatewayInputValidator.maximumBodyBytes }
    guard
      case .int(let maximum)? = variables["max-bytes"],
      (0 ... GatewayInputValidator.maximumDriveUploadBytes).contains(maximum)
    else {
      throw GatewayError.invalidArgument("Drive uploads require --max-bytes between 0 and 67108864")
    }
    return maximum
  }

  private static func boundedData(
    at path: String,
    argumentName: String,
    maximumBytes: Int,
    dataReader: ((Int32, Int) throws -> Data)?
  ) throws -> Data {
    guard path != "-" else { throw CatalogFileArgumentError.standardInput(name: argumentName) }
    let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    let descriptor = path.withCString { Darwin.open($0, flags) }
    guard descriptor >= 0 else { throw CatalogFileArgumentError.notRegularFile(name: argumentName) }
    defer { Darwin.close(descriptor) }

    var fileStatus = stat()
    guard Darwin.fstat(descriptor, &fileStatus) == 0, (fileStatus.st_mode & S_IFMT) == S_IFREG else {
      throw CatalogFileArgumentError.notRegularFile(name: argumentName)
    }

    let data: Data
    do {
      data = try readBoundedData(
        from: descriptor,
        maximumBytes: maximumBytes,
        dataReader: dataReader
      )
    } catch {
      throw GatewayError.invalidArgument("Unable to read catalog file input")
    }
    guard data.count <= maximumBytes else { throw GatewayError.inputTooLarge }
    return data
  }

  static func readBoundedData(
    from descriptor: Int32,
    maximumBytes: Int,
    dataReader: ((Int32, Int) throws -> Data)? = nil,
    cancellation: GatewaySDKCancellation? = nil
  ) throws -> Data {
    let limitPlusOne = maximumBytes + 1
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    var data = Data()
    while data.count < limitPlusOne {
      try checkCancellation(cancellation)
      let remainingBytes = limitPlusOne - data.count
      let chunk: Data
      if let dataReader {
        chunk = try dataReader(descriptor, remainingBytes)
      } else {
        chunk = try handle.read(upToCount: remainingBytes) ?? Data()
      }
      guard !chunk.isEmpty else { break }
      data.append(chunk)
    }
    try checkCancellation(cancellation)
    return data
  }

  private static func writeSnapshot(
    _ data: Data, cleanupState: CatalogSnapshotCleanupState, cancellation: GatewaySDKCancellation?
  ) throws -> String {
    let leaf = "google-documents-gateway-sdk-\(UUID().uuidString)"
    let descriptor = try cleanupState.create(leaf: leaf)
    guard descriptor >= 0 else { throw GatewayError.invalidArgument("Unable to prepare catalog file input") }
    defer { Darwin.close(descriptor) }
    do {
      try data.withUnsafeBytes { rawBuffer in
        var offset = 0
        while offset < rawBuffer.count {
          try checkCancellation(cancellation)
          let count = Darwin.write(descriptor, rawBuffer.baseAddress!.advanced(by: offset), rawBuffer.count - offset)
          guard count > 0 else { throw GatewayError.invalidArgument("Unable to prepare catalog file input") }
          offset += count
        }
      }
      try checkCancellation(cancellation)
      return cleanupState.path(for: leaf)
    } catch {
      guard cleanupState.remove(leaf: leaf) else {
        throw GatewayError.invalidArgument("Unable to remove catalog file snapshot")
      }
      throw error
    }
  }

  private static func checkCancellation(_ cancellation: GatewaySDKCancellation?) throws {
    if cancellation?.isCancelled == true {
      throw GatewayError.transportFailure("SDK execution was cancelled")
    }
  }
}

/// Identifies one SDK-owned private input snapshot whose removal needs explicit recovery.
/// The identifier is stable until the descriptor-relative unlink succeeds.
public struct GatewaySDKSnapshotCleanupRecovery: Sendable, Equatable {
  public let id: UUID
  public let path: String
}

/// Owns failed snapshot cleanup state for a particular SDK facade. The registry retains the
/// authorized directory descriptor until targeted cleanup succeeds, so a returned failure never
/// silently abandons private uploaded contents.
final class GatewaySDKSnapshotCleanupRegistry: @unchecked Sendable {
  /// Process-lifetime owner for cleanup that outlives a facade. A caller can construct another
  /// facade and retry the same stable UUID without ever recovering a pathname capability.
  static let durable = GatewaySDKSnapshotCleanupRegistry(isDurable: true)

  private let lock = NSLock()
  private let isDurable: Bool
  private var entries: [UUID: CatalogSnapshotCleanupState] = [:]
  private var retryInProgress = false

  init() { isDurable = false }

  private init(isDurable: Bool) { self.isDurable = isDurable }

  deinit {
    guard !isDurable else { return }
    let retained = lock.withLock { () -> [CatalogSnapshotCleanupState] in
      defer { entries = [:] }
      return Array(entries.values)
    }
    retained.forEach { $0.transferRecoveryOwnership(to: Self.durable) }
  }

  func retain(_ state: CatalogSnapshotCleanupState, recovery: GatewaySDKSnapshotCleanupRecovery) {
    lock.withLock { entries[recovery.id] = state }
  }

  func recoveries() -> [GatewaySDKSnapshotCleanupRecovery] {
    lock.withLock {
      entries.values.compactMap(\.recovery).sorted { $0.id.uuidString < $1.id.uuidString }
    }
  }

  func retry(recoveryID: UUID) -> [GatewaySDKSnapshotCleanupRecovery] {
    lock.lock()
    guard !retryInProgress else {
      let recoveries = entries.values.compactMap(\.recovery).sorted { $0.id.uuidString < $1.id.uuidString }
      lock.unlock()
      return recoveries
    }
    retryInProgress = true
    let state = entries[recoveryID]
    lock.unlock()
    guard let state else {
      lock.lock()
      retryInProgress = false
      let recoveries = entries.values.compactMap(\.recovery).sorted { $0.id.uuidString < $1.id.uuidString }
      lock.unlock()
      return recoveries
    }
    _ = state.cleanupError()
    lock.lock()
    retryInProgress = false
    let recoveries = entries.values.compactMap(\.recovery).sorted { $0.id.uuidString < $1.id.uuidString }
    lock.unlock()
    return recoveries
  }

  func resolve(_ recoveryID: UUID) {
    _ = lock.withLock { entries.removeValue(forKey: recoveryID) }
  }
}

/// Holds the private snapshot directory descriptor until its caller has consumed the captured
/// bytes. Cleanup is descriptor-relative, checked, and retryable: a failed unlink remains owned
/// by this state instead of being silently discarded.
final class CatalogSnapshotCleanupState: @unchecked Sendable {
  private let lock = NSLock()
  private let directoryPath: String
  private var directoryDescriptor: Int32
  private let closeDirectory: @Sendable (Int32) -> Int32
  private let unlink: @Sendable (Int32, String) -> Int32
  private var leaves: Set<String> = []
  private weak var recoveryRegistry: GatewaySDKSnapshotCleanupRegistry?
  private var recoveryID: UUID?

  init(
    directoryPath: String = FileManager.default.temporaryDirectory.path,
    directoryDescriptor: Int32? = nil,
    closeDirectory: @escaping @Sendable (Int32) -> Int32 = Darwin.close,
    unlink: @escaping @Sendable (Int32, String) -> Int32 = { descriptor, leaf in
      leaf.withCString { Darwin.unlinkat(descriptor, $0, 0) }
    },
    recoveryRegistry: GatewaySDKSnapshotCleanupRegistry? = nil
  ) {
    self.directoryPath = directoryPath
    self.directoryDescriptor = directoryDescriptor ?? directoryPath.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    self.closeDirectory = closeDirectory
    self.unlink = unlink
    self.recoveryRegistry = recoveryRegistry
  }

  deinit {
    // Retry while the descriptor is still valid before releasing independently-created snapshots.
    _ = cleanupError()
    closeDirectoryDescriptor()
  }

  var recovery: GatewaySDKSnapshotCleanupRecovery? {
    lock.withLock {
      guard let recoveryID else { return nil }
      return .init(id: recoveryID, path: directoryPath)
    }
  }

  func create(leaf: String) throws -> Int32 {
    lock.lock()
    let descriptor = directoryDescriptor
    lock.unlock()
    guard descriptor >= 0 else { throw GatewayError.invalidArgument("Unable to prepare catalog file input") }
    let created = leaf.withCString {
      Darwin.openat(descriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    }
    guard created >= 0 else { throw GatewayError.invalidArgument("Unable to prepare catalog file input") }
    lock.lock()
    leaves.insert(leaf)
    lock.unlock()
    return created
  }

  func path(for leaf: String) -> String {
    URL(fileURLWithPath: directoryPath).appendingPathComponent(leaf).path
  }

  @discardableResult
  func remove(leaf: String) -> Bool {
    lock.lock()
    let descriptor = directoryDescriptor
    lock.unlock()
    guard descriptor >= 0 else { return false }
    let removed = unlink(descriptor, leaf) == 0
    if removed {
      lock.lock()
      leaves.remove(leaf)
      lock.unlock()
    }
    return removed
  }

  func cleanupError() -> Error? {
    lock.lock()
    let descriptor = directoryDescriptor
    let pending = leaves
    lock.unlock()
    guard descriptor >= 0 else { return nil }
    var failed = false
    for leaf in pending where !remove(leaf: leaf) { failed = true }
    if failed {
      let recovery = lock.withLock { () -> GatewaySDKSnapshotCleanupRecovery in
        let id = recoveryID ?? UUID()
        recoveryID = id
        return .init(id: id, path: directoryPath)
      }
      recoveryRegistry?.retain(self, recovery: recovery)
      return GatewayError.invalidArgument("Unable to remove catalog file snapshot; recovery_id=\(recovery.id.uuidString)")
    }
    let resolvedID = lock.withLock { recoveryID }
    if let resolvedID { recoveryRegistry?.resolve(resolvedID) }
    lock.lock()
    let shouldClose = leaves.isEmpty && directoryDescriptor >= 0
    lock.unlock()
    if shouldClose { closeDirectoryDescriptor() }
    return nil
  }

  func transferRecoveryOwnership(to registry: GatewaySDKSnapshotCleanupRegistry) {
    guard let recovery = lock.withLock({ () -> GatewaySDKSnapshotCleanupRecovery? in
      recoveryRegistry = registry
      return recoveryID.map { .init(id: $0, path: directoryPath) }
    }) else { return }
    registry.retain(self, recovery: recovery)
  }

  private func closeDirectoryDescriptor() {
    lock.lock()
    let descriptor = directoryDescriptor
    directoryDescriptor = -1
    lock.unlock()
    if descriptor >= 0 { _ = closeDirectory(descriptor) }
  }
}

enum CatalogFileArgumentError: Error, Sendable, CustomStringConvertible {
  case standardInput(name: String)
  case notRegularFile(name: String)

  var description: String {
    switch self {
    case .standardInput(let name):
      return "--\(name) cannot read ambient standard input for catalog-driven operations"
    case .notRegularFile(let name):
      return "--\(name) must reference a regular file for catalog-driven operations"
    }
  }
}
