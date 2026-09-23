import Darwin
import Foundation

/// Descriptor-relative storage for credential files. Every path component is
/// opened with O_NOFOLLOW before its child is accessed, so replacing an
/// ancestor with a symlink cannot redirect a token operation.
enum GatewaySecureTokenFilesystem {
  final class Parent {
    let descriptor: Int32
    let leaf: String

    init(descriptor: Int32, leaf: String) {
      self.descriptor = descriptor
      self.leaf = leaf
    }

    deinit { Darwin.close(descriptor) }
  }

  static func read(_ url: URL) throws -> Data {
    let parent = try openParent(url, create: false)
    let descriptor = Darwin.openat(parent.descriptor, parent.leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    try validateFile(descriptor)
    return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
  }

  static func write(_ data: Data, to url: URL, replacing: Bool) throws {
    let parent = try openParent(url, create: true)
    var destination = stat()
    let exists = Darwin.fstatat(parent.descriptor, parent.leaf, &destination, AT_SYMLINK_NOFOLLOW) == 0
    if exists { try validateFileMetadata(destination) }
    try publish(data, parent: parent, replacing: replacing && exists)
  }

  static func create(_ data: Data, at url: URL) throws {
    let parent = try openParent(url, create: true)
    try publish(data, parent: parent, replacing: false)
  }

  static func remove(_ url: URL) throws {
    let parent: Parent
    do { parent = try openParent(url, create: false) } catch let error as POSIXError where error.code == .ENOENT { return }
    let descriptor = Darwin.openat(parent.descriptor, parent.leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      if errno == ENOENT { return }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    var opened = stat()
    guard Darwin.fstat(descriptor, &opened) == 0 else { throw POSIXError(.EIO) }
    try validateFileMetadata(opened)
    let quarantine = ".\(parent.leaf).revoke.\(UUID().uuidString)"
    guard Darwin.renameatx_np(parent.descriptor, parent.leaf, parent.descriptor, quarantine, UInt32(RENAME_EXCL)) == 0 else {
      throw POSIXError(.EIO)
    }
    var moved = stat()
    guard Darwin.fstatat(parent.descriptor, quarantine, &moved, AT_SYMLINK_NOFOLLOW) == 0,
          moved.st_dev == opened.st_dev, moved.st_ino == opened.st_ino,
          (moved.st_mode & S_IFMT) == S_IFREG, moved.st_nlink == 1 else {
      _ = Darwin.renameatx_np(parent.descriptor, quarantine, parent.descriptor, parent.leaf, UInt32(RENAME_EXCL))
      throw POSIXError(.EPERM)
    }
    guard Darwin.unlinkat(parent.descriptor, quarantine, 0) == 0, Darwin.fsync(parent.descriptor) == 0 else { throw POSIXError(.EIO) }
  }

  static func withMigrationLock<T>(for url: URL, operation: () throws -> T) throws -> T {
    let parent = try openParent(URL(fileURLWithPath: url.path + ".migration.lock"), create: true)
    let descriptor = Darwin.openat(parent.descriptor, parent.leaf, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.EACCES) }
    defer { Darwin.close(descriptor) }
    try validateFile(descriptor)
    guard Darwin.fchmod(descriptor, 0o600) == 0, flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EACCES) }
    defer { _ = flock(descriptor, LOCK_UN) }
    return try operation()
  }

  static func exists(_ url: URL) throws -> Bool {
    let parent: Parent
    do { parent = try openParent(url, create: false) } catch let error as POSIXError where error.code == .ENOENT { return false }
    var value = stat()
    if Darwin.fstatat(parent.descriptor, parent.leaf, &value, AT_SYMLINK_NOFOLLOW) == 0 { return true }
    if errno == ENOENT { return false }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }

  private static func openParent(_ url: URL, create: Bool) throws -> Parent {
    let path = normalized(url.path)
    let pieces = path.split(separator: "/").map(String.init)
    guard let leaf = pieces.last, !leaf.isEmpty else { throw POSIXError(.EINVAL) }
    var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    for piece in pieces.dropLast() {
      var child = Darwin.openat(descriptor, piece, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      if child < 0, errno == ENOENT, create {
        guard Darwin.mkdirat(descriptor, piece, 0o700) == 0 || errno == EEXIST else { Darwin.close(descriptor); throw POSIXError(.EIO) }
        child = Darwin.openat(descriptor, piece, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard child >= 0 else {
        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        Darwin.close(descriptor)
        throw error
      }
      Darwin.close(descriptor)
      descriptor = child
    }
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else { Darwin.close(descriptor); throw POSIXError(.ENOTDIR) }
    if create {
      guard metadata.st_uid == Darwin.geteuid(), Darwin.fchmod(descriptor, 0o700) == 0 else { Darwin.close(descriptor); throw POSIXError(.EPERM) }
    }
    return Parent(descriptor: descriptor, leaf: leaf)
  }

  private static func publish(_ data: Data, parent: Parent, replacing: Bool) throws {
    let temporary = ".\(parent.leaf).\(UUID().uuidString).tmp"
    let descriptor = Darwin.openat(parent.descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    var installed = false
    defer { Darwin.close(descriptor); if !installed { _ = Darwin.unlinkat(parent.descriptor, temporary, 0) } }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
        guard written > 0 else { throw POSIXError(.EIO) }
        offset += written
      }
    }
    guard Darwin.fchmod(descriptor, 0o600) == 0, Darwin.fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    if replacing {
      guard Darwin.renameat(parent.descriptor, temporary, parent.descriptor, parent.leaf) == 0 else { throw POSIXError(.EIO) }
    } else {
      guard Darwin.renameatx_np(parent.descriptor, temporary, parent.descriptor, parent.leaf, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
    installed = true
    guard Darwin.fsync(parent.descriptor) == 0 else { throw POSIXError(.EIO) }
  }

  private static func validateFile(_ descriptor: Int32) throws {
    var metadata = stat()
    guard Darwin.fstat(descriptor, &metadata) == 0 else { throw POSIXError(.EIO) }
    try validateFileMetadata(metadata)
  }

  private static func validateFileMetadata(_ metadata: stat) throws {
    guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_nlink == 1, metadata.st_uid == Darwin.geteuid() else { throw POSIXError(.EPERM) }
  }

  private static func normalized(_ path: String) -> String {
    let absolute = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    let standardized = URL(fileURLWithPath: absolute).standardizedFileURL.path
    // macOS exposes /var as a system alias of /private/var. Canonicalize just
    // that root before walking; user-controlled descendants are never resolved.
    if standardized == "/var" { return "/private/var" }
    if standardized.hasPrefix("/var/") { return "/private" + standardized }
    if standardized == "/tmp" { return "/private/tmp" }
    if standardized.hasPrefix("/tmp/") { return "/private" + standardized }
    return standardized
  }
}
