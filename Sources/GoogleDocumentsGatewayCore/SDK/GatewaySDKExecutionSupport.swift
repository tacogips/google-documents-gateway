import Foundation

/// Cancellation token supplied to SDK-aware transports and local output writers.
public final class GatewaySDKCancellation: @unchecked Sendable {
  private enum State {
    case active
    case cancelled
    case committed
  }

  private let lock = NSLock()
  private let cancellationAttemptObserver: @Sendable () -> Void
  private let remoteResponseAdmissionObserver: @Sendable () -> Void
  private var state: State = .active

  public init() { cancellationAttemptObserver = {}; remoteResponseAdmissionObserver = {} }

  init(
    cancellationAttemptObserver: @escaping @Sendable () -> Void,
    remoteResponseAdmissionObserver: @escaping @Sendable () -> Void = {}
  ) {
    self.cancellationAttemptObserver = cancellationAttemptObserver
    self.remoteResponseAdmissionObserver = remoteResponseAdmissionObserver
  }

  /// Transitions the execution to cancellation unless a local output commit already won.
  /// The Boolean tells the deadline/task handler whether it owns completion of the result latch.
  @discardableResult
  public func cancel() -> Bool {
    cancellationAttemptObserver()
    lock.lock()
    defer { lock.unlock() }
    guard case .active = state else { return false }
    state = .cancelled
    return true
  }

  /// Runs the irreversible output commit while holding the same state transition used by
  /// deadline and task cancellation. Exactly one of cancellation or commit can win.
  func commit(
    _ operation: () throws -> Void,
    onUncertainFailure: (Error) -> Void = { _ in }
  ) throws {
    lock.lock()
    guard case .active = state else {
      lock.unlock()
      throw GatewayError.transportFailure("SDK execution was cancelled")
    }
    do {
      try operation()
      state = .committed
      lock.unlock()
    } catch {
      // An uncertain local publication has already crossed an irreversible filesystem boundary.
      // Keep cancellation from publishing a retryable envelope while writeOutput records its
      // descriptor-owned recovery path after this closure returns.
      if case GatewayError.transportFailure(let message) = error,
        message.hasPrefix("OUTCOME_UNKNOWN:") {
        onUncertainFailure(error)
        state = .committed
      }
      lock.unlock()
      throw error
    }
  }

  /// Runs terminal local cleanup while excluding a competing cancellation publication. Local
  /// failures can leave private bytes behind; once cleanup begins, its recovery-bearing result
  /// must be the invocation result even when unlinking blocks.
  func commitLocalCleanup<T>(_ operation: () -> T) throws -> T {
    lock.lock()
    let result = operation()
    if case .active = state { state = .committed }
    lock.unlock()
    return result
  }

  public var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    if case .cancelled = state { return true }
    return false
  }

  /// Records provider response arrival without committing the local cancellation state.
  /// JSON parsing and envelope publication remain deadline-bound after a remote response.
  func admitRemoteResponse() -> Bool {
    lock.lock()
    guard case .active = state else { lock.unlock(); return false }
    lock.unlock()
    remoteResponseAdmissionObserver()
    return true
  }
}

/// Records whether a bounded call crossed a remote write boundary. A cancellation after a
/// mutating or non-idempotent request must not be presented as safe to retry.
final class GatewaySDKRemoteDispatch: @unchecked Sendable {
  struct Request: Sendable {
    let outcomeUncertain: Bool
    let admitsTerminalResponse: Bool
    let requiresSuccessfulResponse: Bool
  }

  private let lock = NSLock()
  private var nextRequest = Request(outcomeUncertain: false, admitsTerminalResponse: false, requiresSuccessfulResponse: false)
  private var outcomeUncertainRequestWasDispatched = false

  func markOutcomeUncertainRequest(admitsTerminalResponse: Bool, requiresSuccessfulResponse: Bool = false) {
    lock.lock()
    nextRequest = .init(
      outcomeUncertain: true, admitsTerminalResponse: admitsTerminalResponse,
      requiresSuccessfulResponse: requiresSuccessfulResponse
    )
    lock.unlock()
  }

  func beginRequest() -> Request {
    lock.lock()
    defer { lock.unlock() }
    let request = nextRequest
    nextRequest = .init(outcomeUncertain: false, admitsTerminalResponse: false, requiresSuccessfulResponse: false)
    if request.outcomeUncertain { outcomeUncertainRequestWasDispatched = true }
    return request
  }

  var hasOutcomeUncertainDispatch: Bool {
    lock.lock()
    defer { lock.unlock() }
    return outcomeUncertainRequestWasDispatched
  }
}

/// Transport contract for injected SDK transports. Implementations must stop work when the
/// token is cancelled or the supplied deadline has passed.
public protocol GatewayCancellableHTTPTransport: GatewayHTTPTransport {
  func send(
    url: URL,
    method: String,
    headers: [String: String],
    body: Data?,
    timeout: TimeInterval,
    cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse
}

/// Required transport extension for every SDK provider response. Implementations must enforce the
/// limit while receiving data and retain no more than `maximumResponseBytes + 1` bytes.
public protocol GatewayResponseByteLimitedHTTPTransport: GatewayCancellableHTTPTransport {
  func send(
    url: URL,
    method: String,
    headers: [String: String],
    body: Data?,
    maximumResponseBytes: Int,
    timeout: TimeInterval,
    cancellation: GatewaySDKCancellation
  ) throws -> GatewayHTTPResponse
}

/// Authorization boundary for SDK executions. Unlike the command-line path,
/// an SDK operation has a deadline and must be able to stop credential work
/// before it monopolizes the shared execution limiter.
public protocol GatewayCancellableAuthorizer: GatewayAuthorizing {
  func accessToken(for role: GatewayRole, cancellation: GatewaySDKCancellation) throws -> String
}

public struct GatewaySDKExecutionPolicy: Sendable {
  public static let maximumTimeout: TimeInterval = 600
  /// Upper bound for callers that accidentally derive concurrency from untrusted input.
  public static let maximumConcurrentOperationsLimit = 64
  public static let maximumQueuedOperationsLimit = 256
  public static let defaultMaximumResponseBytes = 8 * 1024 * 1024
  public static let maximumResponseBytes = 64 * 1024 * 1024
  public let timeout: TimeInterval
  public let maximumConcurrentOperations: Int
  public let maximumResponseBytes: Int
  let remoteResponseAdmissionObserver: @Sendable () -> Void

  public init(
    timeout: TimeInterval = 30, maximumConcurrentOperations: Int = 4,
    maximumResponseBytes: Int = Self.defaultMaximumResponseBytes
  ) {
    self.init(timeout: timeout, maximumConcurrentOperations: maximumConcurrentOperations,
              maximumResponseBytes: maximumResponseBytes, remoteResponseAdmissionObserver: {})
  }

  init(
    timeout: TimeInterval, maximumConcurrentOperations: Int,
    maximumResponseBytes: Int = Self.defaultMaximumResponseBytes,
    remoteResponseAdmissionObserver: @escaping @Sendable () -> Void
  ) {
    // A public policy must never let NaN or infinity turn off deadline enforcement.
    self.timeout = timeout.isFinite ? min(Self.maximumTimeout, max(0.01, timeout)) : 0.01
    self.maximumConcurrentOperations = min(
      Self.maximumConcurrentOperationsLimit, max(1, maximumConcurrentOperations)
    )
    self.maximumResponseBytes = min(Self.maximumResponseBytes, max(1, maximumResponseBytes))
    self.remoteResponseAdmissionObserver = remoteResponseAdmissionObserver
  }
}

final class GatewaySDKExecutionLatch<Result: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Result, Never>?
  private var completed = false
  private var pendingResult: Result?
  private var terminalObserver: (() -> Void)?

  func install(_ continuation: CheckedContinuation<Result, Never>) {
    lock.lock()
    if let pendingResult {
      lock.unlock()
      continuation.resume(returning: pendingResult)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func observeTerminalResult(_ observer: @escaping () -> Void) {
    lock.lock()
    if completed {
      lock.unlock()
      observer()
      return
    }
    terminalObserver = observer
    lock.unlock()
  }

  func finish(_ result: Result) {
    lock.lock()
    guard !completed else { lock.unlock(); return }
    completed = true
    let observer = terminalObserver
    terminalObserver = nil
    guard let continuation else {
      pendingResult = result
      lock.unlock()
      observer?()
      return
    }
    self.continuation = nil
    lock.unlock()
    continuation.resume(returning: result)
    observer?()
  }
}

/// Owns a per-call deadline source so terminal execution releases queued timer captures promptly.
final class GatewaySDKDeadline: @unchecked Sendable {
  private let lock = NSLock()
  private var timer: DispatchSourceTimer?
  private var action: (@Sendable () -> Void)?

  init(after interval: TimeInterval, action: @escaping @Sendable () -> Void) {
    self.action = action
    let source = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
    timer = source
    source.schedule(deadline: .now() + interval)
    source.setEventHandler { [weak self] in self?.fire() }
    source.resume()
  }

  @discardableResult
  func cancel() -> Bool {
    lock.lock()
    let source = timer
    let hadAction = action != nil
    timer = nil
    action = nil
    lock.unlock()
    source?.setEventHandler {}
    source?.cancel()
    return hadAction
  }

  private func fire() {
    lock.lock()
    let source = timer
    let action = action
    timer = nil
    self.action = nil
    lock.unlock()
    source?.setEventHandler {}
    source?.cancel()
    action?()
  }

  deinit { _ = cancel() }
}

struct GatewayBoundedTransport: GatewayHTTPTransport {
  let base: GatewayHTTPTransport
  let timeout: TimeInterval
  let maximumResponseBytes: Int
  let cancellation: GatewaySDKCancellation
  let remoteDispatch: GatewaySDKRemoteDispatch

  func send(url: URL, method: String, headers: [String: String], body: Data?) throws -> GatewayHTTPResponse {
    guard !cancellation.isCancelled else { throw GatewayError.transportFailure("SDK execution was cancelled") }
    let requestedLimit = headers["X-Gateway-SDK-Max-Response-Bytes"].flatMap(Int.init) ?? maximumResponseBytes
    let limit = min(maximumResponseBytes, max(1, requestedLimit))
    let requestHeaders = headers.filter { $0.key != "X-Gateway-SDK-Max-Response-Bytes" }
    let send: () throws -> GatewayHTTPResponse
    if let limited = base as? GatewayResponseByteLimitedHTTPTransport {
      send = {
        try limited.send(
          url: url, method: method, headers: requestHeaders, body: body,
          maximumResponseBytes: limit, timeout: timeout, cancellation: cancellation
        )
      }
    } else if base is URLSessionGatewayTransport {
      send = { try sendURLSession(url: url, method: method, headers: requestHeaders, body: body, maximumResponseBytes: limit) }
    } else {
      throw GatewayError.transportFailure("SDK transport must enforce GatewayResponseByteLimitedHTTPTransport")
    }
    let requestDisposition = remoteDispatch.beginRequest()
    do {
      let response = try send()
      guard response.data.count <= limit else {
        if headers["X-Gateway-SDK-Max-Response-Bytes"] != nil {
          throw GatewayError.transportFailure("TRANSFER_LIMIT_EXCEEDED: Provider response exceeds the effective response limit.")
        }
        throw GatewayError.transportFailure("SDK transport exceeded the response byte limit")
      }
      let admitsResponse = requestDisposition.admitsTerminalResponse
        && (!requestDisposition.requiresSuccessfulResponse || (200...299).contains(response.statusCode))
      if admitsResponse {
        guard cancellation.admitRemoteResponse() else {
          throw GatewayError.transportFailure("OUTCOME_UNKNOWN: provider write may have completed")
        }
      } else if cancellation.isCancelled {
        let message = requestDisposition.outcomeUncertain
          ? "OUTCOME_UNKNOWN: provider write may have completed"
          : "SDK execution was cancelled"
        throw GatewayError.transportFailure(message)
      }
      return response
    } catch {
      if requestDisposition.outcomeUncertain {
        throw GatewayError.transportFailure("OUTCOME_UNKNOWN: provider write may have completed")
      }
      if let gatewayError = error as? GatewayError, case .transportFailure = gatewayError {
        throw gatewayError
      }
      throw GatewayError.transportFailure("SDK transport failed: \(error.localizedDescription)")
    }
  }

  private func sendURLSession(
    url: URL, method: String, headers: [String: String], body: Data?, maximumResponseBytes: Int
  ) throws -> GatewayHTTPResponse {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpBody = body
    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
    let semaphore = DispatchSemaphore(value: 0)
    let state = GatewaySDKTransportState(maximumResponseBytes: maximumResponseBytes)
    state.onCompletion = { semaphore.signal() }
    let session = URLSession(configuration: .ephemeral, delegate: state, delegateQueue: nil)
    let task = session.dataTask(with: request)
    task.resume()
    let deadline = Date().addingTimeInterval(timeout)
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
      if cancellation.isCancelled {
        task.cancel()
        session.invalidateAndCancel()
        throw GatewayError.transportFailure("SDK execution was cancelled")
      }
      if Date() >= deadline {
        task.cancel()
        session.invalidateAndCancel()
        throw GatewayError.transportFailure("SDK execution exceeded its deadline")
      }
    }
    session.finishTasksAndInvalidate()
    if !state.exceededLimit, let error = state.error { throw error }
    guard let response = state.response as? HTTPURLResponse else {
      throw GatewayError.transportFailure("No HTTP response was returned")
    }
    return .init(
      statusCode: response.statusCode,
      data: state.data ?? Data(),
      requestID: response.value(forHTTPHeaderField: "x-goog-request-id"),
      location: response.value(forHTTPHeaderField: "Location"),
      range: response.value(forHTTPHeaderField: "Range")
    )
  }
}

final class GatewaySDKTransportState: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let buffer: GatewaySDKTransferBuffer
  private var storedResponse: URLResponse?
  private var storedError: Error?
  private var didExceedLimit = false
  var onCompletion: (@Sendable () -> Void)?

  init(maximumResponseBytes: Int) {
    buffer = .init(maximumResponseBytes: maximumResponseBytes)
  }

  var data: Data? { buffer.data }
  var response: URLResponse? { lock.lock(); defer { lock.unlock() }; return storedResponse }
  var error: Error? { lock.lock(); defer { lock.unlock() }; return storedError }
  var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return didExceedLimit }

  func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    lock.lock()
    storedResponse = response
    lock.unlock()
    completionHandler(.allow)
  }

  func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let exceeded = buffer.append(data)
    if exceeded { lock.lock(); didExceedLimit = true; lock.unlock() }
    if exceeded { dataTask.cancel() }
  }

  func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    storedError = error
    lock.unlock()
    onCompletion?()
  }
}

final class GatewaySDKTransferBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private let retainedByteLimit: Int
  private var storedData = Data()

  init(maximumResponseBytes: Int) {
    retainedByteLimit = maximumResponseBytes == Int.max ? Int.max : maximumResponseBytes + 1
  }

  var data: Data { lock.lock(); defer { lock.unlock() }; return storedData }

  @discardableResult
  func append(_ chunk: Data) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let remaining = retainedByteLimit - storedData.count
    if remaining > 0 { storedData.append(chunk.prefix(remaining)) }
    return storedData.count >= retainedByteLimit
  }
}

final class GatewaySDKExecutionLimiter: @unchecked Sendable {
  private let queue: OperationQueue
  private let submissionObserver: @Sendable () -> Void
  private let lock = NSLock()
  private let maximumPendingOperations: Int
  private var pendingOperations = 0
  var configuredMaximumConcurrentOperations: Int { queue.maxConcurrentOperationCount }
  var configuredMaximumPendingOperations: Int { maximumPendingOperations }

  init(
    limit: Int, maximumQueuedOperations: Int = 256,
    submissionObserver: @escaping @Sendable () -> Void = {}, startsSuspended: Bool = false
  ) {
    queue = .init()
    queue.name = "GoogleDocumentsGatewaySDK.execution"
    queue.qualityOfService = .userInitiated
    let normalizedLimit = min(GatewaySDKExecutionPolicy.maximumConcurrentOperationsLimit, max(1, limit))
    queue.maxConcurrentOperationCount = normalizedLimit
    queue.isSuspended = startsSuspended
    let queueCapacity = min(
      GatewaySDKExecutionPolicy.maximumQueuedOperationsLimit, max(1, maximumQueuedOperations)
    )
    maximumPendingOperations = normalizedLimit + queueCapacity
    self.submissionObserver = submissionObserver
  }

  func resume() { queue.isSuspended = false }

  /// Bounds both active workers and the waiting population. A rejected call never enters
  /// `OperationQueue`, so its deadline source and request closure can be released immediately.
  @discardableResult
  func submit(_ operation: @escaping @Sendable () -> Void) -> GatewaySDKQueuedExecution? {
    lock.lock()
    guard pendingOperations < maximumPendingOperations else {
      lock.unlock()
      return nil
    }
    pendingOperations += 1
    lock.unlock()
    let submitted = GatewaySDKQueuedExecution(operation) { [weak self] in
      self?.completeSubmission()
    }
    queue.addOperation(submitted.operation)
    submissionObserver()
    return submitted
  }

  private func completeSubmission() {
    lock.lock()
    pendingOperations -= 1
    lock.unlock()
  }
}

/// Keeps the queued block's call state separate from the `BlockOperation` retained by
/// `OperationQueue`. A cancellation atomically drops that state even when the queue is saturated.
final class GatewaySDKQueuedExecution: @unchecked Sendable {
  fileprivate let operation: BlockOperation
  private let state: GatewaySDKQueuedExecutionState

  init(_ action: @escaping @Sendable () -> Void, onCompletion: @escaping @Sendable () -> Void) {
    state = .init(action, onCompletion: onCompletion)
    operation = .init()
    operation.addExecutionBlock { [weak operation, state] in
      guard let operation, !operation.isCancelled else {
        state.cancel()
        return
      }
      state.run()
    }
  }

  func cancel() {
    state.cancel()
    operation.cancel()
  }
}

private final class GatewaySDKQueuedExecutionState: @unchecked Sendable {
  private let lock = NSLock()
  private var action: (@Sendable () -> Void)?
  private let onCompletion: @Sendable () -> Void
  private var didStart = false
  private var didComplete = false

  init(_ action: @escaping @Sendable () -> Void, onCompletion: @escaping @Sendable () -> Void) {
    self.action = action
    self.onCompletion = onCompletion
  }

  func run() {
    let action = lock.withLock { () -> (@Sendable () -> Void)? in
      guard !didComplete, let action = self.action else { return nil }
      self.action = nil
      didStart = true
      return action
    }
    guard let action else { return }
    defer { complete() }
    action()
  }

  func cancel() {
    let shouldComplete = lock.withLock { () -> Bool in
      guard !didStart, !didComplete else { return false }
      action = nil
      didComplete = true
      return true
    }
    if shouldComplete { onCompletion() }
  }

  private func complete() {
    let shouldComplete = lock.withLock { () -> Bool in
      guard !didComplete else { return false }
      didComplete = true
      return true
    }
    if shouldComplete { onCompletion() }
  }
}

/// Bridges a call's terminal latch with the operation that is still waiting in the limiter.
/// Cancellation may win before or after submission, so installation and cancellation share one
/// lock and a late submission is immediately cancelled.
final class GatewaySDKExecutionSubmission: @unchecked Sendable {
  private let lock = NSLock()
  private var operation: GatewaySDKQueuedExecution?
  private var isCancelled = false

  func install(_ operation: GatewaySDKQueuedExecution) {
    lock.lock()
    self.operation = operation
    let shouldCancel = isCancelled
    lock.unlock()
    if shouldCancel { operation.cancel() }
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let operation = operation
    self.operation = nil
    lock.unlock()
    operation?.cancel()
  }
}
