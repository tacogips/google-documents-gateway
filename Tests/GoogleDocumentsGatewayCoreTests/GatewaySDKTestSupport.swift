import Foundation
import GatewaySDKKit
@testable import GoogleDocumentsGatewayCore

// Full Swift Testing discovery executes boundary suites concurrently. Keep fixture handshakes
// bounded but allow enough scheduling time to distinguish harness load from product behavior.
let gatewaySDKTestSynchronizationTimeout: TimeInterval = 5

func gatewaySDKTestHandshake(_ operation: @escaping @Sendable () -> Bool) async -> Bool {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      continuation.resume(returning: operation())
    }
  }
}

/// Shared fixtures for the SDK boundary suites. These are deliberately fixtures only; behavioral
/// assertions stay with their owning boundary tests.
final class GatewaySDKBoundaryAuthorizer: GatewayCancellableAuthorizer, @unchecked Sendable {
  func accessToken(for _: GatewayRole) throws -> String { "fixture" }

  func accessToken(for role: GatewayRole, cancellation: GatewaySDKCancellation) throws -> String {
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }
    return try accessToken(for: role)
  }
}

final class GatewayFoundationDecodeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var decodedCount = 0
  var calls: Int { lock.withLock { decodedCount } }

  func decoder() -> GatewayProviderJSONDecoder {
    GatewayProviderJSONDecoder { [self] data in
      lock.withLock { decodedCount += 1 }
      return try? JSONSerialization.jsonObject(with: data)
    }
  }
}

final class GatewayRawDocumentDecodeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var decodedCount = 0
  var calls: Int { lock.withLock { decodedCount } }

  func parse(_ document: String) throws -> GatewayJSONValue {
    lock.withLock { decodedCount += 1 }
    return try GatewayJSONValue.parse(document)
  }
}

final class GatewayOAuthTokenDecodeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var decodedCount = 0
  var calls: Int { lock.withLock { decodedCount } }
  func decode(_ data: Data) throws -> GatewayOAuthTokenResponse {
    lock.withLock { decodedCount += 1 }
    return try JSONDecoder().decode(GatewayOAuthTokenResponse.self, from: data)
  }
}

final class GatewaySDKBoundaryTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let response: GatewayHTTPResponse
  private let delay: TimeInterval
  private var activeCount = 0
  private var maximumActiveCount = 0
  private var sentCount = 0
  private var lastRequestBody: Data?

  init(response: GatewayHTTPResponse = .init(statusCode: 200, data: Data("{}".utf8), requestID: "fixture"), delay: TimeInterval = 0) {
    self.response = response
    self.delay = delay
  }

  var calls: Int { lock.withLock { sentCount } }
  var maximumActive: Int { lock.withLock { maximumActiveCount } }
  var lastBody: Data? { lock.withLock { lastRequestBody } }

  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse {
    throw GatewayError.transportFailure("Expected bounded SDK transport")
  }

  func send(
    url _: URL, method _: String, headers _: [String: String], body: Data?, timeout _: TimeInterval,
    cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    try sendBounded(body: body, cancellation: cancellation)
  }

  func send(
    url _: URL, method _: String, headers _: [String: String], body: Data?, maximumResponseBytes: Int,
    timeout _: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    let value = try sendBounded(body: body, cancellation: cancellation)
    guard value.data.count <= maximumResponseBytes else {
      throw GatewayError.transportFailure("SDK transport exceeded the response byte limit")
    }
    return value
  }

  private func sendBounded(body: Data?, cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    lock.withLock {
      sentCount += 1
      lastRequestBody = body
      activeCount += 1
      maximumActiveCount = max(maximumActiveCount, activeCount)
    }
    defer { lock.withLock { activeCount -= 1 } }
    if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }
    return response
  }
}

final class GatewaySDKSequencedBoundaryTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var responses: [GatewayHTTPResponse]
  private var sentCount = 0

  init(_ responses: [GatewayHTTPResponse]) { self.responses = responses }
  var calls: Int { lock.withLock { sentCount } }

  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse {
    throw GatewayError.transportFailure("Expected bounded SDK transport")
  }

  func send(
    url: URL, method: String, headers: [String: String], body: Data?, timeout _: TimeInterval,
    cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    try sendResponse(cancellation: cancellation)
  }

  func send(
    url _: URL, method _: String, headers _: [String: String], body _: Data?, maximumResponseBytes: Int,
    timeout _: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    let response = try sendResponse(cancellation: cancellation)
    guard response.data.count <= maximumResponseBytes else {
      throw GatewayError.transportFailure("SDK transport exceeded the response byte limit")
    }
    return response
  }

  private func sendResponse(cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }
    return try lock.withLock {
      sentCount += 1
      guard !responses.isEmpty else { throw GatewayError.transportFailure("Unexpected transport request") }
      return responses.removeFirst()
    }
  }
}

final class GatewaySDKBlockingBoundaryTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)
  private var sentCount = 0
  private var remainingBlocks: Int

  init(blockingFirst count: Int) { remainingBlocks = count }
  var calls: Int { lock.withLock { sentCount } }

  func waitForCalls(_ expected: Int) -> Bool {
    for _ in 0 ..< expected { guard entered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success else { return false } }
    return true
  }
  func releaseBlockedCalls(_ count: Int) { for _ in 0 ..< count { release.signal() } }

  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse {
    throw GatewayError.transportFailure("Expected bounded SDK transport")
  }

  func send(
    url: URL, method: String, headers: [String: String], body: Data?, timeout: TimeInterval,
    cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    try sendResponse(cancellation: cancellation)
  }

  func send(
    url _: URL, method _: String, headers _: [String: String], body _: Data?, maximumResponseBytes: Int,
    timeout _: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    let response = try sendResponse(cancellation: cancellation)
    guard response.data.count <= maximumResponseBytes else {
      throw GatewayError.transportFailure("SDK transport exceeded the response byte limit")
    }
    return response
  }

  private func sendResponse(cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    let shouldBlock = lock.withLock { () -> Bool in
      sentCount += 1
      guard remainingBlocks > 0 else { return false }
      remainingBlocks -= 1
      return true
    }
    guard shouldBlock else { return .init(statusCode: 200, data: Data("{}".utf8), requestID: "fixture") }
    entered.signal()
    _ = release.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }
    return .init(statusCode: 200, data: Data("{}".utf8), requestID: "fixture")
  }
}

final class ExecutionSubmissionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let submitted = DispatchSemaphore(value: 0)
  private var count = 0

  func record() {
    lock.withLock { count += 1 }
    submitted.signal()
  }

  func waitForSubmissions(_ expected: Int) -> Bool {
    for _ in 0 ..< expected {
      guard submitted.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success else { return false }
    }
    return true
  }

  var submissions: Int { lock.withLock { count } }
}

final class ConcurrentOperationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var active = 0
  private var peak = 0

  func enter() { lock.withLock { active += 1; peak = max(peak, active) } }
  func leave() { lock.withLock { active -= 1 } }
  var maximumActive: Int { lock.withLock { peak } }
}

final class GatewaySDKQueuedCallState: @unchecked Sendable {
  private let lock = NSLock()
  private var admissions = 0

  func recordAdmission() { lock.withLock { admissions += 1 } }
}

final class CatalogPreflightCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func record() { lock.withLock { count += 1 } }
  var events: Int { lock.withLock { count } }
}

final class CatalogTraversalProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)
  private let exited = DispatchSemaphore(value: 0)
  private var first = true
  private var paused = false

  func pauseFirstTraversal() {
    let shouldPause = lock.withLock { () -> Bool in
      defer { first = false }
      return first
    }
    guard shouldPause else { return }
    lock.withLock { paused = true }
    entered.signal()
    defer {
      lock.withLock { paused = false }
      exited.signal()
    }
    _ = release.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)
  }

  func waitForEntry() -> Bool { entered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func releaseTraversal() { release.signal() }
  func waitForExit() -> Bool { exited.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  var isPaused: Bool { lock.withLock { paused } }
}

final class RequestJSONPreflightProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)
  private let exited = DispatchSemaphore(value: 0)
  private var first = true
  private var paused = false

  func pauseFirstTraversal() {
    let shouldPause = lock.withLock { defer { first = false }; return first }
    guard shouldPause else { return }
    lock.withLock { paused = true }; entered.signal()
    defer { lock.withLock { paused = false }; exited.signal() }
    _ = release.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)
  }

  func waitForEntry() -> Bool { entered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func releaseTraversal() { release.signal() }
  func waitForExit() -> Bool { exited.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  var isPaused: Bool { lock.withLock { paused } }
}

final class PageAllAccumulationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)
  private let exited = DispatchSemaphore(value: 0)
  private var paused = false

  func pause() {
    lock.withLock { paused = true }
    entered.signal()
    defer {
      lock.withLock { paused = false }
      exited.signal()
    }
    _ = release.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)
  }

  func waitForEntry() -> Bool { entered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func releaseAccumulation() { release.signal() }
  func waitForExit() -> Bool { exited.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  var isPaused: Bool { lock.withLock { paused } }
}

final class SDKFixtureAuthorizer: GatewayCancellableAuthorizer, @unchecked Sendable {
  private(set) var calls = 0
  func accessToken(for _: GatewayRole) throws -> String { calls += 1; return "fixture" }
  func accessToken(for role: GatewayRole, cancellation: GatewaySDKCancellation) throws -> String {
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }; return try accessToken(for: role)
  }
}
final class BlockingSDKFixtureTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let terminated = DispatchSemaphore(value: 0)
  private var calls = 0
  private var cancellations = 0
  private var timeouts = 0
  var snapshot: (calls: Int, cancellations: Int) { lock.lock(); defer { lock.unlock() }; return (calls, cancellations) }
  var terminationCount: Int { lock.lock(); defer { lock.unlock() }; return cancellations + timeouts }

  func waitForEntry(timeout: TimeInterval = gatewaySDKTestSynchronizationTimeout) -> Bool { entered.wait(timeout: .now() + timeout) == .success }
  func waitForTermination(timeout: TimeInterval = gatewaySDKTestSynchronizationTimeout) -> Bool { terminated.wait(timeout: .now() + timeout) == .success }

  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse {
    lock.lock()
    calls += 1
    lock.unlock()
    Thread.sleep(forTimeInterval: 0.25)
    return .init(statusCode: 200, data: Data("{}".utf8), requestID: nil)
  }
  func send(
    url _: URL,
    method _: String,
    headers _: [String: String],
    body _: Data?,
    timeout: TimeInterval,
    cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    lock.lock()
    calls += 1
    lock.unlock()
    entered.signal()
    let deadline = Date().addingTimeInterval(timeout)
    while !cancellation.isCancelled, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.002)
    }
    if cancellation.isCancelled {
      lock.lock()
      cancellations += 1
      lock.unlock()
      terminated.signal()
      throw GatewayError.transportFailure("SDK execution was cancelled")
    }
    lock.lock()
    timeouts += 1
    lock.unlock()
    terminated.signal()
    throw GatewayError.transportFailure("SDK execution exceeded its deadline")
  }
  func send(
    url: URL, method: String, headers: [String: String], body: Data?, maximumResponseBytes: Int,
    timeout: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse { try enforceSDKResponseLimit(try send(url: url, method: method, headers: headers, body: body, timeout: timeout, cancellation: cancellation), maximumResponseBytes) }
}
final class CatalogSnapshotProbe: @unchecked Sendable {
  var requestedBytes: [Int] = []
  var descriptors: [Int32] = []
  private var chunks: [Data]
  init(chunks: [Data]) { self.chunks = chunks }
  func read(descriptor: Int32, requestedBytes: Int) -> Data {
    descriptors.append(descriptor); self.requestedBytes.append(requestedBytes)
    return chunks.isEmpty ? Data() : chunks.removeFirst()
  }
}
final class SnapshotPathRecorder: @unchecked Sendable {
  private(set) var paths: [String] = []
  private(set) var ownerOnlyModes: [Bool] = []
  func record(_ snapshotPaths: [String]) {
    for path in snapshotPaths {
      var status = stat()
      let result = path.withCString { Darwin.lstat($0, &status) }
      paths.append(path)
      let mode = Int(status.st_mode)
      ownerOnlyModes.append(result == 0 && (mode & 0o077) == 0 && (mode & 0o600) == 0o600)
    }
  }
}
struct CatalogFileArgumentCase {
  let role: GatewayRole
  let operation: String
  let variables: [String: GatewayJSONValue]
}
struct CatalogSnapshotParityCase {
  let role: GatewayRole
  let operation: String
  let variables: [String: GatewayJSONValue]
  let directArguments: [String]
}
final class SDKFixtureTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private(set) var calls = 0; private(set) var lastURL: URL?; private(set) var lastMethod: String?; private(set) var lastBody: Data?
  private(set) var urls: [URL] = []; private(set) var methods: [String] = []; private(set) var headers: [[String: String]] = []; private(set) var bodies: [Data?] = []
  private let responses: [GatewayHTTPResponse]; private let failure: Error?
  init(responses: [GatewayHTTPResponse] = [], failure: Error? = nil) { self.responses = responses; self.failure = failure }
  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    calls += 1; lastURL = url; lastMethod = method; lastBody = body; urls.append(url); methods.append(method); self.headers.append(headers); bodies.append(body)
    if let failure { throw failure }
    if responses.indices.contains(calls - 1) { return responses[calls - 1] }
    return GatewayHTTPResponse(statusCode: 200, data: Data("{}".utf8), requestID: "fixture")
  }
  func send(url: URL, method: String, headers: [String: String], body: Data?, timeout _: TimeInterval, cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }; let response = try send(url: url, method: method, headers: headers, body: body)
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }; return response
  }
  func send(
    url: URL, method: String, headers: [String: String], body: Data?, maximumResponseBytes: Int,
    timeout: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse { try enforceSDKResponseLimit(try send(url: url, method: method, headers: headers, body: body, timeout: timeout, cancellation: cancellation), maximumResponseBytes) }
}
final class BoundedSDKTransferTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private(set) var maximumResponseBytes = -1; private(set) var timeout = 0.0
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse { .init(statusCode: 200, data: Data(), requestID: nil) }
  func send(
    url: URL, method: String, headers: [String: String], body: Data?, timeout _: TimeInterval,
    cancellation _: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse { try send(url: url, method: method, headers: headers, body: body) }
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?, maximumResponseBytes: Int, timeout: TimeInterval, cancellation _: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    self.maximumResponseBytes = maximumResponseBytes; self.timeout = timeout
    return .init(statusCode: 200, data: Data(repeating: 0, count: maximumResponseBytes + 1), requestID: nil)
  }
}
final class UnboundedSDKTransferTransport: GatewayCancellableHTTPTransport, @unchecked Sendable {
  private(set) var calls = 0
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse { .init(statusCode: 200, data: Data(), requestID: nil) }
  func send(
    url: URL, method: String, headers: [String: String], body: Data?, timeout _: TimeInterval,
    cancellation _: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse { calls += 1; return try send(url: url, method: method, headers: headers, body: body) }
}
final class ResponseAdmissionProbe: @unchecked Sendable {
  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)
  private let exited = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var paused = false

  func pause() {
    lock.withLock { paused = true }
    entered.signal()
    defer {
      lock.withLock { paused = false }
      exited.signal()
    }
    _ = release.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)
  }

  func waitForEntry() -> Bool { entered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func releaseAdmission() { release.signal() }
  func waitForExit() -> Bool { exited.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  var isPaused: Bool { lock.withLock { paused } }
}
final class RejectedReplaceContentTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private(set) var calls = 0
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse { .init(statusCode: 200, data: Data(), requestID: nil) }
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?, timeout _: TimeInterval, cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    calls += 1
    switch calls {
    case 1: return .init(statusCode: 200, data: Data("{\"modifiedTime\":\"time\"}".utf8), requestID: nil)
    case 2: return .init(statusCode: 200, data: Data(), requestID: nil, location: "https://upload.googleapis.com/session")
    case 3: return .init(statusCode: 308, data: Data(), requestID: nil, range: "bytes=0-262143")
    default: return .init(statusCode: 500, data: Data(), requestID: nil)
    }
  }
  func send(
    url: URL, method: String, headers: [String: String], body: Data?, maximumResponseBytes: Int,
    timeout: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse { try enforceSDKResponseLimit(try send(url: url, method: method, headers: headers, body: body, timeout: timeout, cancellation: cancellation), maximumResponseBytes) }
}
final class LateDestructiveSDKTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private let entry = DispatchSemaphore(value: 0); private let blockOnCall: Int; private var calls = 0
  init(blockOnCall: Int) { self.blockOnCall = blockOnCall }
  func waitForEntry() -> Bool { entry.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse { .init(statusCode: 200, data: Data(), requestID: nil) }
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?, timeout _: TimeInterval, cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    calls += 1; if calls != blockOnCall { return .init(statusCode: 200, data: Data("{\"modifiedTime\":\"time\"}".utf8), requestID: nil) }; entry.signal()
    while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.001) }; return .init(statusCode: 204, data: Data(), requestID: nil)
  }
  func send(
    url: URL, method: String, headers: [String: String], body: Data?, maximumResponseBytes: Int,
    timeout: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse { try enforceSDKResponseLimit(try send(url: url, method: method, headers: headers, body: body, timeout: timeout, cancellation: cancellation), maximumResponseBytes) }
}
func uploadFixtureResponses() -> [GatewayHTTPResponse] {
  [
    .init(
      statusCode: 200,
      data: Data(),
      requestID: "init",
      location: "https://www.googleapis.com/upload/session"
    ),
    .init(statusCode: 200, data: Data("{\"id\":\"file\"}".utf8), requestID: "finish")
  ]
}
func sdkCredentialEnvironment(role: GatewayRole, token: String) throws -> [String: String] {
  let suffix = role.identifier.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
  let tokenStore = GatewayTokenStore(role: role, accessToken: token, refreshToken: nil, expiresAt: nil)
  let encodedToken = try JSONEncoder().encode(tokenStore)
  guard let tokenJSON = String(bytes: encodedToken, encoding: .utf8) else {
    throw GatewayError.invalidArgument("Unable to encode fixture token store")
  }
  return [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(suffix)_OAUTH_CLIENT_ID": "fixture-client",
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(suffix)_TOKEN_STORE_JSON": tokenJSON
  ]
}
func enforceSDKResponseLimit(
  _ response: GatewayHTTPResponse, _ maximumResponseBytes: Int
) throws -> GatewayHTTPResponse { guard response.data.count <= maximumResponseBytes else { throw GatewayError.transportFailure("SDK transport exceeded the response byte limit") }; return response }
func queryPairs(_ url: URL?) -> [String] {
  URLComponents(url: url ?? URL(string: "https://example.invalid")!, resolvingAgainstBaseURL: false)?.queryItems?.map {
    "\($0.name)=\($0.value ?? "")"
  } ?? []
}

func rawSDKDocument(_ arguments: [String]) throws -> String { try GatewayJSONValue.array(arguments.map(GatewayJSONValue.string)).jsonString() }
final class VariablesFileFixtureAuthorizer: GatewayCancellableAuthorizer, @unchecked Sendable {
  private(set) var calls = 0
  func accessToken(for role: GatewayRole) throws -> String { calls += 1; return "fixture" }
  func accessToken(for role: GatewayRole, cancellation: GatewaySDKCancellation) throws -> String {
    if cancellation.isCancelled { throw GatewayError.transportFailure("SDK execution was cancelled") }
    return try accessToken(for: role)
  }
}
final class SDKOutputRaceProbe: @unchecked Sendable {
  private let commit = DispatchSemaphore(value: 0), sync = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0), cancellation = DispatchSemaphore(value: 0)
  func enterCommit() { commit.signal() }
  func enterSync() { sync.signal(); _ = release.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) }
  func recordCancellationAttempt() { cancellation.signal() }
  func releaseSync() { release.signal() }
  func waitForCommit() -> Bool { commit.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func waitForSync() -> Bool { sync.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func waitForCancellationAttempt() -> Bool { cancellation.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
}
final class UncertainPublicationRaceProbe: @unchecked Sendable {
  private let unlinkEntered = DispatchSemaphore(value: 0)
  private let releaseUnlink = DispatchSemaphore(value: 0)
  private let cancellationStarted = DispatchSemaphore(value: 0)
  func blockFailedUnlink(_: Int32, _: String) -> Int32 {
    unlinkEntered.signal()
    _ = releaseUnlink.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)
    return -1
  }
  func recordCancellationAttempt() { cancellationStarted.signal() }
  func release() { releaseUnlink.signal() }
  func waitForUnlink() -> Bool { unlinkEntered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func waitForCancellation() -> Bool { cancellationStarted.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
}
func transferSDK(root: URL, probe: SDKOutputRaceProbe, blockDuringSync: Bool = false, timeout: TimeInterval = 1, failure: String? = nil) -> GoogleDocumentsGatewaySDK {
  let policy = GatewaySDKFileAccessPolicy(
    outputRoots: [root],
    outputDataWriter: { data, descriptor, cancellation in
      if failure == "quota" { throw POSIXError(.ENOSPC) }
      if failure == "write" { throw GatewayError.invalidArgument("injected write failure") }
      try writeSDKOutput(data, descriptor, cancellation)
    },
    outputSynchronizer: { _ in if blockDuringSync { probe.enterSync() }; if failure == "sync" { throw GatewayError.invalidArgument("injected sync failure") } },
    outputCommitObserver: { _ in probe.enterCommit(); precondition(probe.waitForCancellationAttempt(), "Cancellation did not enter the commit window") }, cancellationAttemptObserver: probe.recordCancellationAttempt
  )
  return .init(role: .init(service: .drive, accessMode: .read), authorizer: VariablesFileFixtureAuthorizer(), transport: SDKCredentialFixtureTransport(),
               fileAccessPolicy: policy, executionPolicy: .init(timeout: timeout, maximumConcurrentOperations: 1))
}
func transferRequest(_ path: URL, _ overwrite: Bool) -> GatewayOperationRequest {
  .init(operation: "files download", variables: ["file-id": .string("file"), "output": .string(path.path), "max-bytes": .int(64), "overwrite": .bool(overwrite)])
}
func writeSDKOutput(_ data: Data, _ descriptor: Int32, _: GatewaySDKCancellation?) throws {
  let written = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }; guard written == data.count else { throw GatewayError.invalidArgument("injected write failure") }
}
func paddedCredentialJSON(_ value: String) -> String { value + String(repeating: " ", count: GatewayInputValidator.maximumBodyBytes - value.lengthOfBytes(using: .utf8)) }
func privateOutputPaths(in root: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".google-documents-gateway-sdk-") }) ?? [] }
final class InlineCredentialDecodeProbe: @unchecked Sendable {
  private let lock = NSLock(), entered = DispatchSemaphore(value: 0), releaseGate = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
  private var hasBlocked = false
  func block<T>(_ operation: () throws -> T) throws -> T {
    let shouldBlock = lock.withLock { if hasBlocked { return false }; hasBlocked = true; return true }
    guard shouldBlock else { return try operation() }
    entered.signal(); _ = releaseGate.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout); defer { completed.signal() }; return try operation()
  }
  func release() { releaseGate.signal() }
  func waitForDecode() -> Bool { entered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func waitForCompletion() -> Bool { completed.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
}
final class PreparationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let releaseGate = DispatchSemaphore(value: 0)
  private var active = 0; private var maximum = 0; private var count = 0
  var peak: Int { lock.withLock { maximum } }
  var entries: Int { lock.withLock { count } }
  var isActive: Bool { lock.withLock { active > 0 } }
  func enter() {
    lock.withLock { active += 1; count += 1; maximum = max(maximum, active) }
    entered.signal()
  }
  func leave() { lock.withLock { active -= 1 } }
  func waitForEntry() -> Bool { entered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func waitForRelease() { _ = releaseGate.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) }
  func release() { releaseGate.signal() }
}
final class NonCancellableFixtureAuthorizer: GatewayAuthorizing, @unchecked Sendable {
  private(set) var calls = 0
  func accessToken(for role: GatewayRole) throws -> String { calls += 1; return "fixture" }
}
final class SDKCredentialFixtureTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private let lock = NSLock(); private var count = 0; var calls: Int { lock.withLock { count } }
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse {
    throw GatewayError.transportFailure("Expected bounded SDK transport")
  }
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?, timeout _: TimeInterval, cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    if cancellation.isCancelled { throw GatewayError.transportFailure("SDK execution was cancelled") }
    lock.withLock { count += 1 }
    return .init(statusCode: 200, data: Data("{}".utf8), requestID: "fixture")
  }
  func send(url: URL, method: String, headers: [String: String], body: Data?, maximumResponseBytes _: Int,
            timeout: TimeInterval, cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    try send(url: url, method: method, headers: headers, body: body, timeout: timeout, cancellation: cancellation)
  }
}

final class TokenStorePersistenceProbe: @unchecked Sendable {
  private let entered = DispatchSemaphore(value: 0)
  private let releaseGate = DispatchSemaphore(value: 0)
  private let persistenceCompleted = DispatchSemaphore(value: 0)
  private let persistenceReleaseGate = DispatchSemaphore(value: 0)

  func pauseBeforePersistence() {
    entered.signal()
    _ = releaseGate.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)
  }

  func waitForEntry() -> Bool { entered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func release() { releaseGate.signal() }
  func pauseAfterPersistence() {
    persistenceCompleted.signal()
    _ = persistenceReleaseGate.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)
  }
  func waitForPersistence() -> Bool { persistenceCompleted.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func releasePersistence() { persistenceReleaseGate.signal() }
}

final class TokenStoreRefreshTransport: GatewayHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let response: GatewayHTTPResponse
  private var count = 0

  init(response: GatewayHTTPResponse) { self.response = response }
  var calls: Int { lock.withLock { count } }

  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse {
    lock.withLock { count += 1 }
    return response
  }
}

final class ConcurrentCredentialRefreshTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let refreshEntered = DispatchSemaphore(value: 0)
  private let refreshRelease = DispatchSemaphore(value: 0)
  private let tokenResponse: GatewayHTTPResponse
  private var refreshCount = 0
  private var providerCount = 0
  private var refreshBlocked = false

  init(tokenResponse: GatewayHTTPResponse) { self.tokenResponse = tokenResponse }
  var refreshCalls: Int { lock.withLock { refreshCount } }
  var providerCalls: Int { lock.withLock { providerCount } }
  var isRefreshBlocked: Bool { lock.withLock { refreshBlocked } }
  func waitForRefresh() -> Bool { refreshEntered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
  func releaseRefresh() { refreshRelease.signal() }

  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse {
    throw GatewayError.transportFailure("Expected bounded SDK transport")
  }

  func send(
    url: URL, method _: String, headers _: [String: String], body _: Data?, timeout _: TimeInterval,
    cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    try response(for: url, cancellation: cancellation)
  }

  func send(
    url: URL, method _: String, headers _: [String: String], body _: Data?, maximumResponseBytes: Int,
    timeout _: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    try enforceSDKResponseLimit(try response(for: url, cancellation: cancellation), maximumResponseBytes)
  }

  private func response(for url: URL, cancellation: GatewaySDKCancellation) throws -> GatewayHTTPResponse {
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }
    if url.host == "oauth2.googleapis.com" {
      lock.withLock { refreshCount += 1; refreshBlocked = true }
      defer { lock.withLock { refreshBlocked = false } }
      refreshEntered.signal()
      _ = refreshRelease.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout)
      guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }
      return tokenResponse
    }
    lock.withLock { providerCount += 1 }
    return .init(statusCode: 200, data: Data("{}".utf8), requestID: "provider")
  }
}

final class TokenStoreDecodeProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let reads = DispatchSemaphore(value: 0)
  private var count = 0

  func record() { lock.withLock { count += 1 }; reads.signal() }
  func waitForReads(_ expected: Int) -> Bool {
    while lock.withLock({ count < expected }) {
      guard reads.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success else { return false }
    }
    return true
  }
}

final class TokenStoreRefreshWaitProbe: @unchecked Sendable {
  private let waiters = DispatchSemaphore(value: 0)
  func recordWait() { waiters.signal() }
  func waitForWaiter() -> Bool { waiters.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success }
}
final class CredentialSecretFIFOProbe: @unchecked Sendable {
  private let path: String
  private let lock = NSLock()
  private let completion = DispatchGroup()
  private let observerActive = DispatchSemaphore(value: 0)
  private let stop = DispatchSemaphore(value: 0)
  private var opened = false
  private var observing = true
  init(path: String) { self.path = path }
  var wasOpened: Bool { lock.withLock { opened } }
  func start() {
    completion.enter()
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      defer { completion.leave() }
      var hasObservedFIFO = false
      while true {
        // A failed nonblocking writer open proves the observer has reached the FIFO and remains
        // able to rendezvous with any unbounded reader without using a readiness sleep.
        let descriptor = path.withCString { Darwin.open($0, O_WRONLY | O_NONBLOCK | O_CLOEXEC) }
        if descriptor >= 0 {
          lock.withLock { if observing { opened = true } }
          Darwin.close(descriptor)
          return
        }
        guard errno == ENXIO else { return }
        if !hasObservedFIFO {
          hasObservedFIFO = true
          observerActive.signal()
        }
        if stop.wait(timeout: .now() + .milliseconds(1)) == .success { return }
      }
    }
  }
  func waitUntilObserving() -> Bool {
    observerActive.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success
  }
  func waitForCompletion() -> Bool {
    lock.withLock { observing = false }
    stop.signal()
    return completion.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success
  }
}
struct SchemaSearchErrorResponse: Decodable {
  let ok: Bool
  let error: Error
  struct Error: Decodable {
    let code: String
    let message: String
  }
}
final class VariablesFileFixtureTransport: GatewayHTTPTransport, @unchecked Sendable {
  private(set) var calls = 0
  private(set) var lastBody: Data?
  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    calls += 1
    lastBody = body
    return GatewayHTTPResponse(statusCode: 200, data: Data("{}".utf8), requestID: "fixture")
  }
}
struct RefreshTransportSnapshot: Equatable {
  let calls: Int
  let cancellations: Int
  let timeouts: Int
}
final class RefreshBlockingTransport: GatewayResponseByteLimitedHTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private let entered = DispatchSemaphore(value: 0)
  private let terminated = DispatchSemaphore(value: 0)
  private var calls = 0
  private var cancellations = 0
  private var timeouts = 0
  var snapshot: RefreshTransportSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return .init(calls: calls, cancellations: cancellations, timeouts: timeouts)
  }
  func waitForCalls(_ expected: Int) -> Bool {
    for _ in 0 ..< expected { guard entered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success else { return false } }
    return true
  }
  func waitForCancellations(_ expected: Int) -> Bool {
    for _ in 0 ..< expected { guard terminated.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success else { return false } }
    return true
  }
  func send(url _: URL, method _: String, headers _: [String: String], body _: Data?) throws -> GatewayHTTPResponse {
    throw GatewayError.transportFailure("Expected bounded SDK transport")
  }
  func send(
    url _: URL,
    method _: String,
    headers _: [String: String],
    body _: Data?,
    timeout _: TimeInterval,
    cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse {
    lock.lock()
    calls += 1
    lock.unlock()
    entered.signal()
    while !cancellation.isCancelled {
      Thread.sleep(forTimeInterval: 0.002)
    }
    lock.lock()
    cancellations += 1
    lock.unlock()
    terminated.signal()
    throw GatewayError.transportFailure("Refresh was stopped")
  }
  func send(
    url: URL, method: String, headers: [String: String], body: Data?, maximumResponseBytes: Int,
    timeout: TimeInterval, cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse { try enforceSDKResponseLimit(try send(url: url, method: method, headers: headers, body: body, timeout: timeout, cancellation: cancellation), maximumResponseBytes) }
}
