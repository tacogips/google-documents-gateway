import Foundation
import GatewaySDKKit
import Testing
@testable import GoogleDocumentsGatewayCore
@Test func sdkExecutionPolicyNormalizesAllFiniteBoundaries() {
  for timeout in [TimeInterval.nan, .infinity, -.infinity, 0, -0.01] {
    #expect(GatewaySDKExecutionPolicy(timeout: timeout).timeout == 0.01)
  }
  #expect(GatewaySDKExecutionPolicy(timeout: 900).timeout == 600)
  for capacity in [Int.min, -1, 0] {
    #expect(GatewaySDKExecutionPolicy(maximumConcurrentOperations: capacity).maximumConcurrentOperations == 1)
  }
  #expect(GatewaySDKExecutionPolicy(maximumConcurrentOperations: .max).maximumConcurrentOperations == GatewaySDKExecutionPolicy.maximumConcurrentOperationsLimit)
  #expect(GatewaySDKExecutionPolicy(maximumResponseBytes: .min).maximumResponseBytes == 1)
  #expect(GatewaySDKExecutionPolicy(maximumResponseBytes: .max).maximumResponseBytes == GatewaySDKExecutionPolicy.maximumResponseBytes)
}
@Test func sdkMaximumConcurrentOperationsAtIntMaxStaysMateriallyBounded() async {
  let limit = GatewaySDKExecutionPolicy.maximumConcurrentOperationsLimit
  let capacity = limit + GatewaySDKExecutionPolicy.maximumQueuedOperationsLimit
  let limiter = GatewaySDKExecutionLimiter(limit: .max, maximumQueuedOperations: .max, startsSuspended: true)
  #expect(limiter.configuredMaximumConcurrentOperations == limit)
  #expect(limiter.configuredMaximumPendingOperations == capacity)
  let finished = DispatchGroup(), active = ConcurrentOperationProbe()
  for _ in 0 ..< capacity {
    finished.enter()
    #expect(limiter.submit { active.enter(); Thread.sleep(forTimeInterval: 0.002); active.leave(); finished.leave() } != nil)
  }
  #expect(limiter.submit {} == nil)
  limiter.resume()
  #expect(await gatewaySDKTestHandshake { finished.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success })
  #expect(active.maximumActive <= limit)
  let reused = DispatchSemaphore(value: 0)
  #expect(limiter.submit { reused.signal() } != nil)
  #expect(await gatewaySDKTestHandshake { reused.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success })
}
@Test func sdkExecutionLimiterBounds128NetworkCallsAndRetainsReuse() async {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let transport = GatewaySDKBoundaryTransport(delay: 0.002)
  let sdk = GoogleDocumentsGatewaySDK(
    role: role, authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport,
    executionPolicy: .init(timeout: 5, maximumConcurrentOperations: 4)
  )
  let request = GatewayOperationRequest(operation: "document get", variables: ["document-id": .string("document")])
  await withTaskGroup(of: GatewayEnvelope.self) { group in
    for _ in 0 ..< 128 { group.addTask { await sdk.invoke(request, environment: [:]) } }
    for await result in group { #expect(result.exitCode == 0) }
  }
  #expect(transport.calls == 128)
  #expect(transport.maximumActive <= 4)
  #expect((await sdk.invoke(request, environment: [:])).exitCode == 0)
}
@Test func sdkCancellationRemovesQueuedOperationsBeforeTransportAdmission() async {
  let transport = GatewaySDKBlockingBoundaryTransport(blockingFirst: 4)
  let submissions = ExecutionSubmissionProbe()
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport,
    catalogFileSnapshotter: .live, executionPolicy: .init(timeout: 5, maximumConcurrentOperations: 4),
    executionLimiter: .init(limit: 4, submissionObserver: submissions.record)
  )
  let request = GatewayOperationRequest(operation: "document get", variables: ["document-id": .string("document")])
  let active = (0 ..< 4).map { _ in Task { await sdk.invoke(request, environment: [:]) } }
  let saturated = await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: transport.waitForCalls(4)) }
  }
  #expect(saturated)
  let queued = (0 ..< 128).map { _ in Task { await sdk.invoke(request, environment: [:]) } }
  #expect(await gatewaySDKTestHandshake { submissions.waitForSubmissions(132) })
  let cancellationStarted = Date()
  queued.forEach { $0.cancel() }
  for task in queued { #expect((await task.value).errors.first?.code == "TRANSPORT_FAILURE") }
  #expect(Date().timeIntervalSince(cancellationStarted) < 1)
  #expect(submissions.submissions == 132)
  transport.releaseBlockedCalls(4)
  for task in active { #expect((await task.value).exitCode == 0) }
  try? await Task.sleep(nanoseconds: 20_000_000)
  #expect(transport.calls == 4)
  #expect((await sdk.invoke(request, environment: [:])).exitCode == 0)
  #expect(transport.calls == 5)
}
@Test func sdkExecutionLimiterReleasesCancelledQueuedCallStateBeforeActiveWorkersFinish() async throws {
  let limiter = GatewaySDKExecutionLimiter(limit: 1)
  let activeEntered = DispatchSemaphore(value: 0)
  let activeRelease = DispatchSemaphore(value: 0)
  let activeExited = DispatchSemaphore(value: 0)
  _ = limiter.submit {
    activeEntered.signal()
    activeRelease.wait()
    activeExited.signal()
  }
  #expect(await gatewaySDKTestHandshake { activeEntered.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success })
  weak var queuedState: GatewaySDKQueuedCallState?
  do {
    let state = GatewaySDKQueuedCallState()
    queuedState = state
    let queued = try #require(limiter.submit { state.recordAdmission() })
    queued.cancel()
  }
  #expect(queuedState == nil)
  #expect(await gatewaySDKTestHandshake { activeExited.wait(timeout: .now() + .milliseconds(50)) == .timedOut })
  activeRelease.signal()
  #expect(await gatewaySDKTestHandshake { activeExited.wait(timeout: .now() + gatewaySDKTestSynchronizationTimeout) == .success })
}
@Test func sdkExecutionLimiterRejectsCallsBeyondFiniteQueueCapacity() async {
  let transport = GatewaySDKBlockingBoundaryTransport(blockingFirst: 1)
  let submissions = ExecutionSubmissionProbe()
  let limiter = GatewaySDKExecutionLimiter(
    limit: 1, maximumQueuedOperations: 2, submissionObserver: submissions.record
  )
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport,
    catalogFileSnapshotter: .live, executionPolicy: .init(timeout: 5, maximumConcurrentOperations: 1), executionLimiter: limiter
  )
  let request = GatewayOperationRequest(operation: "document get", variables: ["document-id": .string("document")])
  let active = Task { await sdk.invoke(request, environment: [:]) }
  #expect(await gatewaySDKTestHandshake { transport.waitForCalls(1) })
  let queued = [Task { await sdk.invoke(request, environment: [:]) }, Task { await sdk.invoke(request, environment: [:]) }]
  #expect(await gatewaySDKTestHandshake { submissions.waitForSubmissions(3) })
  await withTaskGroup(of: GatewayEnvelope.self) { group in
    for _ in 0 ..< 32 { group.addTask { await sdk.invoke(request, environment: [:]) } }
    for await rejected in group {
      #expect(rejected.exitCode == 5)
      #expect(rejected.errors.first?.code == "TRANSPORT_FAILURE")
      #expect(rejected.errors.first?.message == "SDK execution queue is full; retry later.")
    }
  }
  #expect(submissions.submissions == 3)
  #expect(transport.calls == 1)
  queued.forEach { $0.cancel() }
  for task in queued { #expect((await task.value).exitCode == 5) }
  transport.releaseBlockedCalls(1)
  #expect((await active.value).exitCode == 0)
  #expect((await sdk.invoke(request, environment: [:])).exitCode == 0)
}
@Test func sdkCatalogPreflightCountsNodesAcrossEveryVariable() {
  var variables: [String: GatewayJSONValue] = [:]
  for index in 0 ..< 16_384 { variables["unknown\(index)"] = .null }
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .write))
  #expect(throws: GatewayError.inputTooLarge) {
    try sdk.buildArgv(operation: "document create", variables: variables)
  }
}
@Test func sdkCatalogPreflightCountsEscapedVariableKeys() {
  var variables: [String: GatewayJSONValue] = [:]
  for index in 0 ..< 16_383 {
    variables[String(repeating: "\\", count: 80) + "\(index)"] = .null
  }
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .write))
  #expect(throws: GatewayError.inputTooLarge) {
    try sdk.buildArgv(operation: "document create", variables: variables)
  }
}
@Test func sdkCatalogPreflightRejectsOversizedKeysAndWideContainersBeforeRendering() {
  let scalarCounter = CatalogPreflightCounter()
  let oversizedSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .write), catalogFileSnapshotter: .live,
    catalogEscapedScalarObserver: scalarCounter.record
  )
  let oversizedKey = String(repeating: "\\", count: GatewayInputValidator.maximumBodyBytes)
  #expect(throws: GatewayError.inputTooLarge) {
    try oversizedSDK.buildArgv(operation: "document create", variables: [oversizedKey: .null])
  }
  // The outer object and escaped-key quotes consume four bytes before two-byte backslash escapes.
  let acceptedEscapedScalars = (GatewayInputValidator.maximumBodyBytes - 4) / 2
  #expect(scalarCounter.events == acceptedEscapedScalars)
  let traversalCounter = CatalogPreflightCounter()
  let wideSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .write), catalogFileSnapshotter: .live,
    catalogTraversalObserver: traversalCounter.record
  )
  let wideContainer = GatewayJSONValue.array(Array(repeating: .null, count: 16_383))
  #expect(throws: GatewayError.inputTooLarge) {
    try wideSDK.buildArgv(operation: "document create", variables: ["json": wideContainer])
  }
  #expect(traversalCounter.events == 1)
}
@Test func sdkBoundsNonTransferResponseAndMarksMutatingParseFailureUnknown() async {
  let readTransport = GatewaySDKBoundaryTransport(response: .init(statusCode: 200, data: Data(repeating: 0, count: 8), requestID: nil))
  let reader = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: readTransport,
    executionPolicy: .init(maximumResponseBytes: 7)
  )
  let read = await reader.invoke(.init(operation: "document get", variables: ["document-id": .string("document")]), environment: [:])
  #expect(read.errors.first?.code == "TRANSPORT_FAILURE")

  let writeTransport = GatewaySDKBoundaryTransport(response: .init(statusCode: 200, data: Data("not-json".utf8), requestID: nil))
  let writer = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: GatewaySDKBoundaryAuthorizer(), transport: writeTransport
  )
  let write = await writer.invoke(.init(operation: "spreadsheet create", variables: ["title": .string("document")]), environment: [:])
  #expect(write.errors.first?.code == "OUTCOME_UNKNOWN")
}
@Test func sdkRejectsWideProviderJSONBeforeFoundationDecoding() async {
  let wideJSON = "[" + Array(repeating: "\"\"", count: 16 * 1024 + 1).joined(separator: ",") + "]"
  let decodeProbe = GatewayFoundationDecodeProbe()
  let response = GatewayHTTPResponse(statusCode: 200, data: Data(wideJSON.utf8), requestID: nil, providerJSONDecoder: decodeProbe.decoder())
  let transport = GatewaySDKBoundaryTransport(response: response)
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport
  )
  let result = await sdk.invoke(
    .init(operation: "document get", variables: ["document-id": .string("document")]), environment: [:]
  )
  #expect(result.exitCode == 5); #expect(result.errors.first?.code == "RESPONSE_LIMIT_EXCEEDED")
  #expect(decodeProbe.calls == 0)
}
@Test func sdkPageAllRejectsWideProviderPageBeforeAccumulation() async {
  let widePage = "{\"files\":[" + Array(repeating: "null", count: 16 * 1024 + 1).joined(separator: ",") + "]}"
  let decodeProbe = GatewayFoundationDecodeProbe()
  let response = GatewayHTTPResponse(statusCode: 200, data: Data(widePage.utf8), requestID: nil, providerJSONDecoder: decodeProbe.decoder())
  let transport = GatewaySDKBoundaryTransport(response: response)
  let accumulation = CatalogPreflightCounter()
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport,
    catalogFileSnapshotter: .live, pageAllAccumulationObserver: accumulation.record
  )
  let result = await sdk.invoke(
    .init(operation: "files list", variables: ["page-all": .bool(true)]), environment: [:]
  )
  #expect(result.exitCode == 5); #expect(result.errors.first?.code == "RESPONSE_LIMIT_EXCEEDED")
  #expect(transport.calls == 1)
  #expect(accumulation.events == 0)
  #expect(decodeProbe.calls == 0)
}
@Test func sdkMutationPreflightRejectsWideProviderResponseBeforeDecoding() async {
  let response = "{\"modifiedTime\":\"time\",\"padding\":[" + Array(repeating: "null", count: 16 * 1024 + 1).joined(separator: ",") + "]}"
  let decodeProbe = GatewayFoundationDecodeProbe()
  let providerResponse = GatewayHTTPResponse(statusCode: 200, data: Data(response.utf8), requestID: nil, providerJSONDecoder: decodeProbe.decoder())
  let transport = GatewaySDKBoundaryTransport(response: providerResponse)
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .write), authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport)
  let request = GatewayOperationRequest(operation: "files rename", variables: [
    "file-id": .string("file"), "confirm-file-id": .string("file"),
    "expected-modified-time": .string("time"), "name": .string("renamed")
  ])
  let result = await sdk.invoke(request, environment: [:])
  #expect(result.errors.first?.code == "RESPONSE_LIMIT_EXCEEDED"); #expect(transport.calls == 1)
  #expect(decodeProbe.calls == 0)
}
@Test func sdkPageAllChecksFinalSerializedResultAgainstOperationBudget() async {
  let first = GatewayHTTPResponse(
    statusCode: 200, data: Data("{\"files\":[{}],\"nextPageToken\":\"next\"}".utf8), requestID: nil
  )
  // A small scripted transport models two individually bounded provider replies. Their raw
  // bytes fit the operation budget, while the final envelope's structural JSON does not.
  let transport = GatewaySDKSequencedBoundaryTransport([first, .init(statusCode: 200, data: Data("{\"files\":[{}]}".utf8), requestID: nil)])
  let budget = first.data.count + Data("{\"files\":[{}]}".utf8).count
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport,
    executionPolicy: .init(maximumResponseBytes: budget)
  )
  let result = await sdk.invoke(.init(operation: "files list", variables: ["page-all": .bool(true), "max-pages": .int(2)]), environment: [:])
  #expect(result.errors.first?.code == "RESPONSE_LIMIT_EXCEEDED")
  #expect(transport.calls == 2)
}
@Test func sdkPageAllRejectsMalformedSuccessfulPages() async {
  let request = GatewayOperationRequest(operation: "files list", variables: ["page-all": .bool(true), "max-pages": .int(2)])
  for data in ["{\"nextPageToken\":\"next\"}", "{\"files\":{}}", "{\"files\":[],\"nextPageToken\":1}"] {
    let transport = SDKFixtureTransport(responses: [.init(statusCode: 200, data: Data(data.utf8), requestID: nil)])
    let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .read), authorizer: SDKFixtureAuthorizer(), transport: transport)
    #expect((await sdk.invoke(request, environment: [:])).errors.first?.code == "PROVIDER_RESPONSE_INVALID"); #expect(transport.calls == 1)
  }
  let later = SDKFixtureTransport(responses: [
    .init(statusCode: 200, data: Data("{\"files\":[],\"nextPageToken\":\"next\"}".utf8), requestID: nil),
    .init(statusCode: 200, data: Data("{\"nextPageToken\":\"next\"}".utf8), requestID: nil)
  ])
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .read), authorizer: SDKFixtureAuthorizer(), transport: later)
  #expect((await sdk.invoke(request, environment: [:])).errors.first?.code == "PROVIDER_RESPONSE_INVALID"); #expect(later.calls == 2)
}
@Test func sdkDestructiveAdmissionAndReplaceContentRejectsUnreconciledRetries() async throws {
  let admission = ResponseAdmissionProbe()
  let admissionLimiter = GatewaySDKExecutionLimiter(limit: 1)
  let admitted = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .write), authorizer: SDKFixtureAuthorizer(),
    transport: SDKFixtureTransport(responses: [.init(statusCode: 200, data: Data("{\"modifiedTime\":\"time\"}".utf8), requestID: nil), .init(statusCode: 204, data: Data(), requestID: nil)]),
    catalogFileSnapshotter: .live,
    executionPolicy: .init(timeout: 1, maximumConcurrentOperations: 1, remoteResponseAdmissionObserver: admission.pause),
    executionLimiter: admissionLimiter
  )
  let deleting: [String: GatewayJSONValue] = ["file-id": .string("file"), "confirm-file-id": .string("file"), "expected-modified-time": .string("time"), "acknowledge-permanent-delete": .bool(true)]
  let deleteTask = Task { await admitted.invoke(.init(operation: "files delete", variables: deleting), environment: [:]) }
  #expect(await gatewaySDKTestHandshake { admission.waitForEntry() })
  deleteTask.cancel()
  let admittedResult = await deleteTask.value
  #expect(admittedResult.exitCode == 5)
  #expect(admittedResult.errors.first?.code == "OUTCOME_UNKNOWN")
  #expect(admittedResult.errors.first?.message == "Provider write may have completed; do not retry without reconciliation.")
  #expect(admittedResult.rawOutput == "{\"errors\":[{\"code\":\"OUTCOME_UNKNOWN\",\"message\":\"Provider write may have completed; do not retry without reconciliation.\"}]}")
  #expect(admission.isPaused)
  admission.releaseAdmission()
  #expect(await gatewaySDKTestHandshake { admission.waitForExit() })
  let admissionReuse = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .write), authorizer: SDKFixtureAuthorizer(),
    transport: SDKFixtureTransport(), catalogFileSnapshotter: .live,
    executionPolicy: .init(timeout: 1, maximumConcurrentOperations: 1), executionLimiter: admissionLimiter
  )
  let dryDelete = GatewayOperationRequest(
    operation: "files delete",
    variables: [
      "dry-run": .bool(true), "file-id": .string("file"), "confirm-file-id": .string("file"),
      "expected-modified-time": .string("time"), "acknowledge-permanent-delete": .bool(true)
    ]
  )
  let admissionReuseResult = await admissionReuse.invoke(dryDelete, environment: [:])
  #expect(admissionReuseResult.exitCode == 0)
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("replacement.bin"); try Data(repeating: 0x61, count: 256 * 1024 + 1).write(to: input)
  let retrying = RejectedReplaceContentTransport()
  let replacing = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: retrying,
    fileAccessPolicy: .init(inputRoots: [root]), executionPolicy: .init(timeout: 1))
  let replacementValues: [String: GatewayJSONValue] = ["file-id": .string("file"), "confirm-file-id": .string("file"), "expected-modified-time": .string("time"),
    "input": .string(input.path), "max-bytes": .int(256 * 1024 + 1)]
  let replacement = await replacing.invoke(.init(operation: "files replace-content", variables: replacementValues), environment: [:])
  #expect(replacement.exitCode == 5)
  #expect(replacement.errors.first?.code == "OUTCOME_UNKNOWN")
  #expect(replacement.errors.first?.message == "Provider write may have completed; do not retry without reconciliation.")
  // Preflight, upload-session creation, the first 308 chunk, then one rejected final chunk.
  #expect(retrying.calls == 4)
  let uploadInput = root.appendingPathComponent("upload.bin"); try Data(repeating: 0, count: 256 * 1024 + 1).write(to: uploadInput)
  let progress = SDKFixtureTransport(responses: [
    .init(statusCode: 200, data: Data(), requestID: nil, location: "https://upload.googleapis.com/initial"),
    .init(statusCode: 308, data: Data(), requestID: nil, location: "https://upload.googleapis.com/updated", range: "bytes=0-131071"),
    .init(statusCode: 308, data: Data(), requestID: nil, range: "bytes=0-262143"),
    .init(statusCode: 200, data: Data("{}".utf8), requestID: nil)
  ])
  let resumed = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: progress,
    fileAccessPolicy: .init(inputRoots: [root]))
  #expect((await resumed.invoke(.init(operation: "files upload", variables: ["input": .string(uploadInput.path), "max-bytes": .int(256 * 1024 + 1)]), environment: [:])).exitCode == 0)
  #expect(progress.calls == 4); #expect(progress.urls[2].absoluteString == "https://upload.googleapis.com/updated")
  #expect(progress.headers[2]["Content-Range"] == "bytes 131072-262144/262145")
  #expect(progress.headers[3]["Content-Range"] == "bytes 262144-262144/262145")
  let noRange = SDKFixtureTransport(responses: [
    .init(statusCode: 200, data: Data(), requestID: nil, location: "https://upload.googleapis.com/session"),
    .init(statusCode: 308, data: Data(), requestID: nil)
  ])
  let unresolved = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: noRange,
    fileAccessPolicy: .init(inputRoots: [root]))
  #expect((await unresolved.invoke(.init(operation: "files upload", variables: ["input": .string(uploadInput.path), "max-bytes": .int(256 * 1024 + 1)]), environment: [:])).errors.first?.code == "OUTCOME_UNKNOWN")
  #expect(noRange.calls == 2)
  let destructiveRole = GatewayRole(service: .drive, accessMode: .write)
  let lateDelete = GoogleDocumentsGatewaySDK(role: destructiveRole, authorizer: SDKFixtureAuthorizer(), transport: LateDestructiveSDKTransport(blockOnCall: 2), executionPolicy: .init(timeout: 0.01))
  #expect((await lateDelete.invoke(.init(operation: "files delete", variables: deleting), environment: [:])).errors.first?.code == "OUTCOME_UNKNOWN")
  let lateComment = GoogleDocumentsGatewaySDK(role: destructiveRole, authorizer: SDKFixtureAuthorizer(), transport: LateDestructiveSDKTransport(blockOnCall: 1), executionPolicy: .init(timeout: 0.01))
  let commentValues: [String: GatewayJSONValue] = ["file-id": .string("file"), "comment-id": .string("comment"), "confirm-comment-id": .string("comment")]
  #expect((await lateComment.invoke(.init(operation: "comments delete", variables: commentValues), environment: [:])).errors.first?.code == "OUTCOME_UNKNOWN")
}
@Test func sdkRemoteWritesAndReadOnlyPostsClassifyPostDispatchCancellation() async throws {
  let sheetsTransport = LateDestructiveSDKTransport(blockOnCall: 1)
  let sheets = GoogleDocumentsGatewaySDK(role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: sheetsTransport, executionPolicy: .init(timeout: 1))
  let append: [String: GatewayJSONValue] = ["spreadsheet-id": .string("sheet"), "range": .string("A1"), "json-values": .array([.array([.string("value")])])]
  let appendTask = Task { await sheets.invoke(.init(operation: "values append", variables: append), environment: [:]) }
  #expect(await gatewaySDKTestHandshake { sheetsTransport.waitForEntry() }); appendTask.cancel(); #expect((await appendTask.value).errors.first?.code == "OUTCOME_UNKNOWN")
  let root = try gatewaySDKTestScratchDirectory(); defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("upload.bin"); try Data("body".utf8).write(to: input)
  let uploadTransport = LateDestructiveSDKTransport(blockOnCall: 1); let upload = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .write), authorizer: SDKFixtureAuthorizer(),
    transport: uploadTransport, fileAccessPolicy: .init(inputRoots: [root]), executionPolicy: .init(timeout: 1))
  let uploadTask = Task { await upload.invoke(.init(operation: "files upload", variables: ["input": .string(input.path), "max-bytes": .int(4)]), environment: [:]) }
  #expect(await gatewaySDKTestHandshake { uploadTransport.waitForEntry() }); uploadTask.cancel(); #expect((await uploadTask.value).errors.first?.code == "OUTCOME_UNKNOWN")
  let moveTransport = LateDestructiveSDKTransport(blockOnCall: 2)
  let move = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: moveTransport, executionPolicy: .init(timeout: 1))
  let moving: [String: GatewayJSONValue] = ["file-id": .string("file"), "confirm-file-id": .string("file"), "expected-modified-time": .string("time"), "add-parents": .string("parent")]
  let moveTask = Task { await move.invoke(.init(operation: "files move", variables: moving), environment: [:]) }
  #expect(await gatewaySDKTestHandshake { moveTransport.waitForEntry() }); moveTask.cancel(); #expect((await moveTask.value).errors.first?.code == "OUTCOME_UNKNOWN")
  let filters = root.appendingPathComponent("filters.json"); try Data("{\"dataFilters\":[{}]}".utf8).write(to: filters); let readTransport = LateDestructiveSDKTransport(blockOnCall: 1)
  let reader = GoogleDocumentsGatewaySDK(role: .init(service: .sheets, accessMode: .read), authorizer: SDKFixtureAuthorizer(),
    transport: readTransport, fileAccessPolicy: .init(inputRoots: [root]), executionPolicy: .init(timeout: 1))
  let readTask = Task { await reader.invoke(.init(operation: "spreadsheet get-by-data-filter", variables: ["spreadsheet-id": .string("sheet"), "input-file": .string(filters.path)]), environment: [:]) }
  #expect(await gatewaySDKTestHandshake { readTransport.waitForEntry() }); readTask.cancel(); #expect((await readTask.value).errors.first?.code == "TRANSPORT_FAILURE")
  struct PostDispatchFailure {
    let readCode: String
    let makeTransport: () -> SDKFixtureTransport
  }
  let failures: [PostDispatchFailure] = [
    .init(readCode: "TRANSPORT_FAILURE", makeTransport: { SDKFixtureTransport(failure: URLError(.networkConnectionLost)) }),
    .init(readCode: "TRANSPORT_FAILURE", makeTransport: { SDKFixtureTransport(failure: GatewayError.transportFailure("No HTTP response was returned")) }),
    .init(readCode: "TRANSPORT_FAILURE", makeTransport: { SDKFixtureTransport(failure: GatewayError.invalidArgument("injected provider failure")) }),
    .init(readCode: "TRANSPORT_FAILURE", makeTransport: { SDKFixtureTransport(failure: GatewayError.inputTooLarge) }),
    .init(readCode: "TRANSPORT_FAILURE", makeTransport: { SDKFixtureTransport(failure: GatewayError.authenticationRequired) }),
    .init(readCode: "TRANSPORT_FAILURE", makeTransport: { SDKFixtureTransport(responses: [.init(statusCode: 200, data: Data(repeating: 0, count: 65), requestID: nil)]) }),
    .init(readCode: "PROVIDER_ERROR", makeTransport: { SDKFixtureTransport(responses: [.init(statusCode: 503, data: Data("unavailable".utf8), requestID: nil)]) }),
    .init(readCode: "PROVIDER_RESPONSE_INVALID", makeTransport: { SDKFixtureTransport(responses: [.init(statusCode: 200, data: Data("not-json".utf8), requestID: nil)]) })
  ]
  for failure in failures {
    let retryUnsafe = GoogleDocumentsGatewaySDK(
      role: .init(service: .sheets, accessMode: .write), authorizer: SDKFixtureAuthorizer(),
      transport: failure.makeTransport(), executionPolicy: .init(timeout: 1, maximumResponseBytes: 64)
    )
    let mutation = await retryUnsafe.invoke(.init(operation: "values append", variables: append), environment: [:])
    #expect(mutation.exitCode == 5)
    #expect(mutation.errors == [
      .init(message: "Provider write may have completed; do not retry without reconciliation.", code: "OUTCOME_UNKNOWN")
    ])
    let retrySafe = GoogleDocumentsGatewaySDK(
      role: .init(service: .docs, accessMode: .read), authorizer: SDKFixtureAuthorizer(),
      transport: failure.makeTransport(), executionPolicy: .init(timeout: 1, maximumResponseBytes: 64)
    )
    let readOnly = await retrySafe.invoke(.init(operation: "document get", variables: ["document-id": .string("document")]), environment: [:])
    #expect(readOnly.exitCode == 5)
    #expect(readOnly.errors.first?.code == failure.readCode)
  }
  let intentionalTransportFailure = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .read), authorizer: SDKFixtureAuthorizer(),
    transport: SDKFixtureTransport(failure: GatewayError.transportFailure("fixture transport message")),
    executionPolicy: .init(timeout: 1)
  )
  let deliberate = await intentionalTransportFailure.invoke(
    .init(operation: "document get", variables: ["document-id": .string("document")]), environment: [:]
  )
  #expect(deliberate.exitCode == 5)
  #expect(deliberate.errors == [.init(message: "fixture transport message", code: "TRANSPORT_FAILURE")])
}
@Test func sdkBoundsCatalogRenderingAndPageAllAggregation() async throws {
  var deeplyNested: GatewayJSONValue = .array([])
  for _ in 0 ..< 128 { deeplyNested = .array([deeplyNested]) }
  let oversized = String(repeating: "x", count: 64 * 1024 + 1), oversizedVariables: [[String: GatewayJSONValue]] = [
    ["title": .string(oversized)], ["json": .object(["title": .string(oversized)])],
    ["json": .array(Array(repeating: .array([]), count: 16 * 1024))], ["json": deeplyNested]
  ]
  let bounded = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .write), authorizer: SDKFixtureAuthorizer(), transport: SDKFixtureTransport())
  for variables in oversizedVariables {
    #expect(throws: GatewayError.inputTooLarge) { try bounded.buildArgv(operation: "document create", variables: variables) }
    #expect((await bounded.invoke(.init(operation: "document create", variables: variables), environment: [:])).errors.first?.code == "INPUT_TOO_LARGE")
  }
  let first = Data("{\"files\":[{\"id\":\"one\"}],\"nextPageToken\":\"next\"}".utf8), second = Data("{\"files\":[{\"id\":\"two\"}]}".utf8)
  let pages = SDKFixtureTransport(responses: [.init(statusCode: 200, data: first, requestID: nil), .init(statusCode: 200, data: second, requestID: nil)])
  let paged = GoogleDocumentsGatewaySDK(role: .init(service: .drive, accessMode: .read), authorizer: SDKFixtureAuthorizer(), transport: pages, executionPolicy: .init(timeout: 1, maximumResponseBytes: first.count + 1))
  let result = await paged.invoke(.init(operation: "files list", variables: ["page-all": .bool(true), "max-pages": .int(2)]), environment: [:])
  #expect(result.errors.first?.code == "RESPONSE_LIMIT_EXCEEDED"); #expect(pages.calls == 2)
}

@Test func sdkBoundsRenderedArgvFinalRequestBodiesAndTraversalCancellation() async throws {
  let firstRange = String(repeating: "a", count: 40_000)
  let secondRange = String(repeating: "b", count: 40_000)
  let individualRanges = [
    GatewayJSONValue.string(firstRange), GatewayJSONValue.string(secondRange)
  ]
  let rangeSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(),
    transport: GatewaySDKBoundaryTransport()
  )
  let individuallyBoundedRanges = GatewayOperationRequest(
    operation: "values batch-get",
    variables: ["spreadsheet-id": .string("sheet"), "range": .array(individualRanges), "dry-run": .bool(true)]
  )
  let listArgv = try rangeSDK.buildArgv(
    operation: individuallyBoundedRanges.operation, variables: individuallyBoundedRanges.variables
  )
  #expect(listArgv.contains(firstRange))
  #expect(listArgv.contains(secondRange))
  #expect((await rangeSDK.invoke(individuallyBoundedRanges, environment: [:])).exitCode == 0)

  let oversizedJSONTransport = GatewaySDKBoundaryTransport()
  let oversizedJSONSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .write), authorizer: GatewaySDKBoundaryAuthorizer(),
    transport: oversizedJSONTransport
  )
  let oversizedJSONRequest = GatewayOperationRequest(
    operation: "document create",
    variables: [
      "json": .object(["title": .string(String(repeating: "x", count: 64 * 1024))]),
      "dry-run": .bool(true)
    ]
  )
  #expect(throws: GatewayError.inputTooLarge) {
    try oversizedJSONSDK.buildArgv(operation: oversizedJSONRequest.operation, variables: oversizedJSONRequest.variables)
  }
  #expect((await oversizedJSONSDK.invoke(oversizedJSONRequest, environment: [:])).errors.first?.code == "INPUT_TOO_LARGE")
  #expect(oversizedJSONTransport.calls == 0)

  let rangeLength = 65_530
  let ranges = Array(repeating: GatewayJSONValue.string(String(repeating: "x", count: rangeLength)), count: 32)
  let renderedArgvTransport = GatewaySDKBoundaryTransport()
  let aggregateRangeSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: renderedArgvTransport
  )
  let rangeRequest = GatewayOperationRequest(operation: "values batch-get", variables: ["spreadsheet-id": .string("sheet"), "range": .array(ranges)])
  #expect(throws: GatewayError.inputTooLarge) { try aggregateRangeSDK.buildArgv(operation: rangeRequest.operation, variables: rangeRequest.variables) }
  #expect((await aggregateRangeSDK.invoke(rangeRequest, environment: [:])).errors.first?.code == "INPUT_TOO_LARGE")
  #expect(renderedArgvTransport.calls == 0)

  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let prefix = "{\"data\":[{\"range\":\"A1\",\"values\":[[\""
  let suffix = "\"]]}]}"
  let payload = String(repeating: "x", count: GatewayInputValidator.maximumBodyBytes - prefix.utf8.count - suffix.utf8.count - 8)
  let bodyInput = root.appendingPathComponent("values.json")
  let source = Data((prefix + payload + suffix).utf8)
  #expect(source.count <= GatewayInputValidator.maximumBodyBytes)
  try source.write(to: bodyInput)
  let finalBodyTransport = GatewaySDKBoundaryTransport()
  let bodySDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write), authorizer: GatewaySDKBoundaryAuthorizer(), transport: finalBodyTransport,
    fileAccessPolicy: .init(inputRoots: [root])
  )
  let bodyResult = await bodySDK.invoke(.init(operation: "values batch-update", variables: [
    "spreadsheet-id": .string("sheet"), "input-file": .string(bodyInput.path)
  ]), environment: [:])
  #expect(bodyResult.errors.first?.code == "INPUT_TOO_LARGE")
  #expect(finalBodyTransport.calls == 0)

  let traversal = CatalogTraversalProbe()
  let traversalTransport = GatewaySDKBoundaryTransport()
  let traversalSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .write), authorizer: GatewaySDKBoundaryAuthorizer(), transport: traversalTransport,
    catalogFileSnapshotter: .live, executionPolicy: .init(timeout: 5), catalogTraversalObserver: traversal.pauseFirstTraversal
  )
  let task = Task { await traversalSDK.invoke(.init(operation: "document create", variables: ["title": .string("Document")]), environment: [:]) }
  #expect(await gatewaySDKTestHandshake { traversal.waitForEntry() })
  task.cancel()
  traversal.releaseTraversal()
  #expect((await task.value).errors.first?.code == "TRANSPORT_FAILURE")
  #expect(await gatewaySDKTestHandshake { traversal.waitForExit() })
  #expect(traversalTransport.calls == 0)

  let deadlineTraversal = CatalogTraversalProbe()
  let deadlineTraversalTransport = GatewaySDKBoundaryTransport()
  let deadlineTraversalSDK = GoogleDocumentsGatewaySDK(
    role: .init(service: .docs, accessMode: .write), authorizer: GatewaySDKBoundaryAuthorizer(),
    transport: deadlineTraversalTransport, catalogFileSnapshotter: .live,
    executionPolicy: .init(timeout: 0.01), catalogTraversalObserver: deadlineTraversal.pauseFirstTraversal
  )
  let deadlineTask = Task {
    await deadlineTraversalSDK.invoke(.init(operation: "document create", variables: ["title": .string("Document")]), environment: [:])
  }
  #expect(await gatewaySDKTestHandshake { deadlineTraversal.waitForEntry() })
  let deadlineResult = await deadlineTask.value
  #expect(deadlineTraversal.isPaused)
  #expect(deadlineResult.exitCode == 5)
  #expect(deadlineResult.errors.first?.code == "TRANSPORT_FAILURE")
  deadlineTraversal.releaseTraversal()
  #expect(await gatewaySDKTestHandshake { deadlineTraversal.waitForExit() })
  #expect(deadlineTraversalTransport.calls == 0)
}

@Test func sdkCancellationAndDeadlineInterruptPageAllAccumulation() async {
  for deadlineDriven in [false, true] {
    let accumulation = PageAllAccumulationProbe()
    let limiter = GatewaySDKExecutionLimiter(limit: 1)
    let transport = GatewaySDKSequencedBoundaryTransport([
      .init(statusCode: 200, data: Data("{\"files\":[{\"id\":\"one\"}],\"nextPageToken\":\"next\"}".utf8), requestID: nil)
    ])
    let sdk = GoogleDocumentsGatewaySDK(
      role: .init(service: .drive, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport,
      catalogFileSnapshotter: .live, executionPolicy: .init(timeout: deadlineDriven ? 0.01 : 1, maximumConcurrentOperations: 1),
      executionLimiter: limiter, pageAllAccumulationObserver: accumulation.pause
    )
    let task = Task.detached {
      await sdk.invoke(.init(operation: "files list", variables: ["page-all": .bool(true), "max-pages": .int(2)]), environment: [:])
    }
    #expect(await gatewaySDKTestHandshake { accumulation.waitForEntry() })
    if !deadlineDriven { task.cancel() }
    let result = await task.value
    #expect(result.exitCode == 5)
    #expect(result.errors.first?.code == "TRANSPORT_FAILURE")
    #expect(accumulation.isPaused)
    #expect(transport.calls == 1)
    accumulation.releaseAccumulation()
    #expect(await gatewaySDKTestHandshake { accumulation.waitForExit() })
    // A dry-run shares the one-slot limiter. Its completion proves the cancelled worker has
    // returned, so the next assertion cannot race a late second page request.
    let reuseSDK = GoogleDocumentsGatewaySDK(
      role: .init(service: .drive, accessMode: .read), authorizer: GatewaySDKBoundaryAuthorizer(), transport: transport,
      catalogFileSnapshotter: .live, executionPolicy: .init(timeout: 1, maximumConcurrentOperations: 1), executionLimiter: limiter
    )
    let reuse = await reuseSDK.invoke(.init(operation: "files list", variables: ["dry-run": .bool(true)]), environment: [:])
    #expect(reuse.exitCode == 0)
    #expect(transport.calls == 1)
  }
}
@Test func sdkTerminalCallsReleaseDeadlineCapturesImmediately() async {
  weak var released: SDKFixtureTransport?
  do {
    let transport = SDKFixtureTransport(); released = transport
    let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .read), transport: transport, executionPolicy: .init(timeout: 600))
    for _ in 0 ..< 32 { #expect((await sdk.invoke(.init(operation: "document get", variables: ["document-id": .string("doc"), "dry-run": .bool(true)]), environment: [:])).exitCode == 0) }
  }
  for _ in 0 ..< 20 where released != nil { try? await Task.sleep(nanoseconds: 1_000_000) }
  #expect(released == nil)
}
@Test func sdkDefaultAuthorizerRefreshRespectsCancellationDeadlineAndLimiter() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let role = GatewayRole(service: .docs, accessMode: .read)
  let tokenStoreURL = root.appendingPathComponent("token.json")
  let tokenStore = GatewayTokenStore(
    role: role,
    accessToken: "expired",
    refreshToken: "refresh",
    expiresAt: .distantPast
  )
  try GatewayTokenStoreFile.write(tokenStore, to: tokenStoreURL)
  let originalStore = try Data(contentsOf: tokenStoreURL)
  let environment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "fixture-client",
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON": try #require(String(data: originalStore, encoding: .utf8))
  ]
  for timeout in [TimeInterval.nan, .infinity, -.infinity, 0, -1] { #expect(GatewaySDKExecutionPolicy(timeout: timeout).timeout == 0.01) }
  for capacity in [0, -1] { #expect(GatewaySDKExecutionPolicy(timeout: 1, maximumConcurrentOperations: capacity).maximumConcurrentOperations == 1) }
  let policy = GatewaySDKExecutionPolicy(timeout: .infinity, maximumConcurrentOperations: 1); guard policy.timeout == 0.01 else { return }
  let cancellationTransport = RefreshBlockingTransport()
  let cancellationSDK = GoogleDocumentsGatewaySDK(role: role, transport: cancellationTransport, executionPolicy: .init(timeout: 1, maximumConcurrentOperations: 1))
  let request = GatewayOperationRequest(operation: "document get", variables: ["document-id": .string("doc")])
  let cancellationTask = Task { await cancellationSDK.invoke(request, environment: environment) }
  for _ in 0 ..< 200 where cancellationTransport.snapshot.calls == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
  #expect(cancellationTransport.snapshot.calls == 1)
  cancellationTask.cancel()
  let cancelled = await cancellationTask.value
  #expect(cancelled.exitCode == 5)
  #expect(cancelled.errors.first?.message == "SDK execution was cancelled")
  for _ in 0 ..< 200 where cancellationTransport.snapshot.cancellations == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
  #expect(cancellationTransport.snapshot.cancellations == 1)
  let deadlineTransport = RefreshBlockingTransport()
  let deadlineSDK = GoogleDocumentsGatewaySDK(role: role, transport: deadlineTransport, executionPolicy: .init(timeout: 0.01, maximumConcurrentOperations: 1))
  let deadlineTask = Task { await deadlineSDK.invoke(request, environment: environment) }
  #expect(await gatewaySDKTestHandshake { deadlineTransport.waitForCalls(1) })
  let timedOut = await deadlineTask.value
  #expect(timedOut.exitCode == 5)
  #expect(timedOut.errors.first?.message == "SDK execution exceeded its deadline")
  let followUpTask = Task { await deadlineSDK.invoke(request, environment: environment) }
  #expect(await gatewaySDKTestHandshake { deadlineTransport.waitForCalls(1) })
  let followUp = await followUpTask.value
  #expect(followUp.exitCode == 5)
  #expect(await gatewaySDKTestHandshake { deadlineTransport.waitForCancellations(2) })
  #expect(cancellationTransport.snapshot.cancellations == 1)
  #expect(cancellationTransport.snapshot.timeouts == 0)
  #expect(deadlineTransport.snapshot.calls == 2)
  #expect(deadlineTransport.snapshot.cancellations == 2)
  #expect(deadlineTransport.snapshot.timeouts == 0)
  try await Task.sleep(nanoseconds: 25_000_000)
  #expect(try Data(contentsOf: tokenStoreURL) == originalStore)
}
@Test func sdkRefreshRejectsWideResponseBeforeTokenDecoding() async throws {
  let role = GatewayRole(service: .docs, accessMode: .read), probe = GatewayOAuthTokenDecodeProbe()
  let store = GatewayTokenStore(role: role, accessToken: "expired", refreshToken: "refresh", expiresAt: .distantPast)
  let tokenJSON = try #require(String(data: JSONEncoder().encode(store), encoding: .utf8))
  let wide = "{\"access_token\":\"token\",\"padding\":[" + Array(repeating: "null", count: 16 * 1024 + 1).joined(separator: ",") + "]}"
  let transport = SDKFixtureTransport(responses: [.init(statusCode: 200, data: Data(wide.utf8), requestID: nil)])
  let decoder = GatewaySDKCredentialDecoder(
    decodeInstalledClient: GatewaySDKCredentialDecoder.live.decodeInstalledClient,
    decodeTokenStore: GatewaySDKCredentialDecoder.live.decodeTokenStore,
    decodeOAuthTokenResponse: probe.decode
  )
  let sdk = GoogleDocumentsGatewaySDK(role: role, transport: transport, catalogFileSnapshotter: .live,
    executionPolicy: .init(maximumConcurrentOperations: 1), credentialDecoder: decoder)
  let request = GatewayOperationRequest(operation: "document get", variables: ["document-id": .string("document")])
  let environment = ["GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "fixture", "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON": tokenJSON]
  #expect((await sdk.invoke(request, environment: environment)).errors.first?.code == "AUTH_REQUIRED"); #expect(probe.calls == 0); #expect(transport.calls == 1)
  let valid = GatewayTokenStore(role: role, accessToken: "token", refreshToken: nil, expiresAt: .distantFuture)
  let validJSON = try #require(String(data: JSONEncoder().encode(valid), encoding: .utf8))
  let validEnvironment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "fixture",
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON": validJSON
  ]
  #expect((await sdk.invoke(request, environment: validEnvironment)).exitCode == 0)
  #expect(transport.calls == 2)
}
@Test func sdkBoundsCatalogPreparationAndCancelsQueuedWork() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("input.txt")
  try Data("fixture".utf8).write(to: input)
  let probe = PreparationProbe()
  let snapshotter = CatalogFileSnapshotter { _, variables in
    probe.enter(); defer { probe.leave() }; Thread.sleep(forTimeInterval: 0.04)
    return .init(variables: variables, paths: [])
  }
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .write),
    catalogFileSnapshotter: snapshotter,
    fileAccessPolicy: .init(inputRoots: [root]),
    executionPolicy: .init(timeout: 1, maximumConcurrentOperations: 1)
  )
  let request = GatewayOperationRequest(operation: "files upload", variables: [
    "input": .string(input.path), "max-bytes": .int(64), "dry-run": .bool(true)
  ])
  async let first = sdk.invoke(request, environment: [:])
  try await Task.sleep(nanoseconds: 5_000_000)
  let queued = (0 ..< 32).map { _ in Task { await sdk.invoke(request, environment: [:]) } }
  queued.forEach { $0.cancel() }
  for task in queued { #expect((await task.value).exitCode == 5) }
  #expect((await first).exitCode == 0)
  #expect(probe.peak == 1); #expect(probe.entries == 1)
}
@Test func sdkRejectsNonCancellableAuthorizersBeforeNetworkExecution() async {
  let authorizer = NonCancellableFixtureAuthorizer()
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .read), authorizer: authorizer)
  let result = await sdk.invoke(.init(operation: "document get", variables: ["document-id": .string("doc")]), environment: [:])
  #expect(result.exitCode == 5)
  #expect(result.errors.first?.code == "TRANSPORT_FAILURE")
  #expect(authorizer.calls == 0)
}
@Test func sdkDefaultCredentialLoadingRejectsEnvironmentCredentialPathsWithoutFallback() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let role = GatewayRole(service: .docs, accessMode: .read)
  let tokenStore = GatewayTokenStore(role: role, accessToken: "token", refreshToken: nil, expiresAt: nil); let tokenPath = root.appendingPathComponent("token.json")
  try GatewayTokenStoreFile.write(tokenStore, to: tokenPath)
  let secret = root.appendingPathComponent("secret.json")
  let linkedSecret = root.appendingPathComponent("secret-link.json"); let oversizedSecret = root.appendingPathComponent("secret-oversized.json")
  try Data("{\"installed\":{\"client_id\":\"fixture\",\"client_secret\":\"secret\"}}".utf8).write(to: secret)
  try FileManager.default.createSymbolicLink(atPath: linkedSecret.path, withDestinationPath: secret.path)
  var oversized = Data("{\"installed\":{\"client_id\":\"fixture\"},\"padding\":\"".utf8)
  oversized.append(Data(repeating: 0x61, count: GatewayInputValidator.maximumBodyBytes + 1))
  oversized.append(Data("\"}".utf8))
  try oversized.write(to: oversizedSecret)
  for (secretPath, exitCode, errorCode) in [(linkedSecret, 4, "AUTH_REQUIRED"), (oversizedSecret, 4, "AUTH_REQUIRED")] {
    let transport = SDKCredentialFixtureTransport()
    let sdk = GoogleDocumentsGatewaySDK(role: role, transport: transport)
    let environment = [
      "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_SECRET_PATH": secretPath.path,
      "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_PATH": tokenPath.path
    ]
    let result = await sdk.invoke(.init(operation: "document get", variables: ["document-id": .string("doc")]), environment: environment)
    #expect(result.exitCode == exitCode, "path: \(secretPath.path)")
    #expect(result.errors.first?.code == errorCode, "path: \(secretPath.path)")
    #expect(transport.calls == 0, "path: \(secretPath.path)")
  }
  let transport = SDKCredentialFixtureTransport(); let sdk = GoogleDocumentsGatewaySDK(role: role, transport: transport, executionPolicy: .init(maximumConcurrentOperations: 1))
  let request = GatewayOperationRequest(operation: "document get", variables: ["document-id": .string("doc")]); let r = await sdk.invoke(request, environment: [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_SECRET_PATH": secret.path,
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_PATH": tokenPath.path
  ])
  #expect(r.exitCode == 4); #expect(r.errors.first?.code == "AUTH_REQUIRED")
  #expect(transport.calls == 0); let tokenJSON = try #require(String(data: JSONEncoder().encode(tokenStore), encoding: .utf8))
  #expect((await sdk.invoke(request, environment: [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "fixture", "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_JSON": tokenJSON
  ])).exitCode == 0)
  #expect(transport.calls == 1)
}
@Test func sdkConfigValidateRejectsMalformedConfiguredOAuthSecretWithoutFallback() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let malformedSecret = root.appendingPathComponent("malformed-secret.json")
  try Data("{\"installed\":{\"client_id\":\"   \"}}".utf8).write(to: malformedSecret)
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .read))
  let prefix = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_"
  let cases = [
    [
      prefix + "OAUTH_CLIENT_SECRET_JSON": "{}",
      prefix + "OAUTH_CLIENT_ID": "must-not-fallback"
    ],
    [
      prefix + "OAUTH_CLIENT_SECRET_PATH": malformedSecret.path,
      prefix + "OAUTH_CLIENT_ID": "must-not-fallback"
    ]
  ]
  for environment in cases {
    let result = await sdk.execute(document: try rawSDKDocument(["config", "validate"]), variables: [:], environment: environment)
    #expect(result.exitCode == (environment[prefix + "OAUTH_CLIENT_SECRET_PATH"] == nil ? 2 : 4))
  }
}
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
      executionPolicy: .init(timeout: 0.01, maximumConcurrentOperations: 1), credentialDecoder: decoder
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
@Test func sdkCancelledCredentialLoadingNeverFallsBackToUnboundedSecretRead() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let role = GatewayRole(service: .docs, accessMode: .read)
  let secretFIFO = root.appendingPathComponent("secret.fifo")
  let tokenPath = root.appendingPathComponent("token.json")
  #expect(secretFIFO.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
  let cancellation = GatewaySDKCancellation()
  cancellation.cancel()
  let readerProbe = CredentialSecretFIFOProbe(path: secretFIFO.path)
  readerProbe.start()
  #expect(await gatewaySDKTestHandshake { readerProbe.waitUntilObserving() })
  let transport = SDKCredentialFixtureTransport()
  let runner = GatewayCommandRunner(
    role: role,
    transport: transport,
    environment: [
      "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_SECRET_PATH": secretFIFO.path,
      "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_PATH": tokenPath.path
    ],
    cancellation: cancellation
  )
  let result = runner.run(arguments: ["document", "get", "--document-id", "doc"])
  #expect(await gatewaySDKTestHandshake { readerProbe.waitForCompletion() })
  #expect(!readerProbe.wasOpened)
  #expect(result.exitCode == 4)
  #expect(result.stdout.contains("AUTH_REQUIRED"))
  #expect(transport.calls == 0)
  #expect(!FileManager.default.fileExists(atPath: tokenPath.path))
}
@Test func sdkDefersCredentialLoadingForOfflineAndRoleGatePaths() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let secretFIFO = root.appendingPathComponent("secret.fifo")
  #expect(secretFIFO.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
  let readerProbe = CredentialSecretFIFOProbe(path: secretFIFO.path)
  readerProbe.start()
  #expect(await gatewaySDKTestHandshake { readerProbe.waitUntilObserving() })
  let environment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_SECRET_PATH": secretFIFO.path,
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "must-not-be-read"
  ]
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .read))
  let foreign = await sdk.execute(
    document: try rawSDKDocument(["document", "create"]), variables: [:], environment: environment
  )
  let schema = await sdk.execute(
    document: try rawSDKDocument(["schema", "search", "^document get$", "--kinds", "command"]),
    variables: [:],
    environment: environment
  )
  let dryRun = await sdk.execute(
    document: try rawSDKDocument(["document", "get", "--document-id", "doc", "--dry-run"]),
    variables: [:],
    environment: environment
  )
  #expect(foreign.exitCode == 2)
  #expect(foreign.errors.first?.code == "FORBIDDEN_COMMAND")
  #expect(schema.exitCode == 0)
  #expect(dryRun.exitCode == 0)
  #expect(await gatewaySDKTestHandshake { readerProbe.waitForCompletion() })
  #expect(!readerProbe.wasOpened)
}
@Test func sdkUsesInjectedCredentialProfileWithBoundedAuthorization() async throws {
  let role = GatewayRole(service: .docs, accessMode: .read)
  let store = GatewayTokenStore(role: role, accessToken: "token", refreshToken: nil, expiresAt: nil)
  let tokenStoreJSON = try #require(String(bytes: JSONEncoder().encode(store), encoding: .utf8))
  let profile = try GatewayCredentialProfile(
    id: "fixture", role: role, clientID: "fixture-client",
    tokenStoreURL: URL(fileURLWithPath: "/tmp/gateway-sdk-unused-token.json"),
    tokenStoreJSON: tokenStoreJSON
  )
  let transport = SDKCredentialFixtureTransport()
  let sdk = GoogleDocumentsGatewaySDK(role: role, transport: transport, credentialProfile: profile)
  let result = await sdk.invoke(.init(operation: "document get", variables: ["document-id": .string("doc")]), environment: [:])
  #expect(result.exitCode == 0)
  #expect(transport.calls == 1)
}
@Test func sdkInvokePreservesGatewaySDKBindingErrors() async {
  let sdk = GoogleDocumentsGatewaySDK(role: .init(service: .docs, accessMode: .read))
  let missing = await sdk.invoke(.init(operation: "document get", variables: [:]), environment: [:])
  let mismatch = await sdk.invoke(
    .init(operation: "document get", variables: ["document-id": .int(1)]),
    environment: [:]
  )
  #expect(missing.exitCode == 2)
  #expect(missing.rawOutput.isEmpty)
  #expect(missing.errors.first?.message == "operation 'document get' requires variable 'document-id'")
  #expect(mismatch.exitCode == 2)
  #expect(mismatch.rawOutput.isEmpty)
  #expect(mismatch.errors.first?.message == "variable 'document-id' expects String! but got int")
}
@Test func sdkDiagnosticsRejectFIFOProfilesAndStoresWithoutRetainingLimiterCapacity() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let role = GatewayRole(service: .docs, accessMode: .read)
  let secretFIFO = root.appendingPathComponent("secret.fifo")
  let storeFIFO = root.appendingPathComponent("store.fifo")
  #expect(secretFIFO.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
  #expect(storeFIFO.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
  let secretProbe = CredentialSecretFIFOProbe(path: secretFIFO.path)
  let storeProbe = CredentialSecretFIFOProbe(path: storeFIFO.path)
  secretProbe.start(); storeProbe.start()
  #expect(await gatewaySDKTestHandshake { secretProbe.waitUntilObserving() })
  #expect(await gatewaySDKTestHandshake { storeProbe.waitUntilObserving() })
  let transport = SDKCredentialFixtureTransport()
  let sdk = GoogleDocumentsGatewaySDK(
    role: role,
    transport: transport,
    executionPolicy: .init(timeout: 1, maximumConcurrentOperations: 1)
  )
  let secretEnvironment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_SECRET_PATH": secretFIFO.path
  ]
  let storeEnvironment = [
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID": "fixture-client",
    "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_TOKEN_STORE_PATH": storeFIFO.path
  ]
  let validate = await sdk.execute(
    document: try rawSDKDocument(["config", "validate"]), variables: [:], environment: secretEnvironment
  )
  #expect(validate.exitCode == 4)
  #expect(validate.errors.first?.code == "AUTH_REQUIRED")
  for command in [["auth", "status"], ["doctor"]] {
    let diagnostic = await sdk.execute(
      document: try rawSDKDocument(command), variables: [:], environment: storeEnvironment
    )
    #expect(diagnostic.exitCode == 4, "command: \(command)")
    #expect(diagnostic.errors.first?.code == "AUTH_REQUIRED", "command: \(command)")
  }
  #expect(await gatewaySDKTestHandshake { secretProbe.waitForCompletion() })
  #expect(await gatewaySDKTestHandshake { storeProbe.waitForCompletion() })
  #expect(!secretProbe.wasOpened)
  #expect(!storeProbe.wasOpened)
  #expect(transport.calls == 0)
  for _ in 0 ..< 3 {
    let followUp = await sdk.execute(
      document: try rawSDKDocument(["schema", "print"]), variables: [:], environment: [:]
    )
    #expect(followUp.exitCode == 0)
  }
}
@Test func sdkBindsInvokeArgumentsInsideBoundedExecution() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("input.txt")
  try Data("fixture".utf8).write(to: input)
  let probe = PreparationProbe()
  let snapshotter = CatalogFileSnapshotter { _, variables in
    probe.enter()
    defer { probe.leave() }
    probe.waitForRelease()
    return .init(variables: variables, paths: [])
  }
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .drive, accessMode: .write),
    catalogFileSnapshotter: snapshotter,
    fileAccessPolicy: .init(inputRoots: [root]),
    executionPolicy: .init(timeout: 0.02, maximumConcurrentOperations: 1)
  )
  let active = Task {
    await sdk.invoke(.init(operation: "files upload", variables: [
      "input": .string(input.path), "max-bytes": .int(64), "dry-run": .bool(true)
    ]), environment: [:])
  }
  #expect(await gatewaySDKTestHandshake { probe.waitForEntry() })
  let queuedBindingFailure = await sdk.invoke(
    .init(operation: "files upload", variables: [:]),
    environment: [:]
  )
  #expect(queuedBindingFailure.exitCode == 5)
  #expect(queuedBindingFailure.errors.first?.code == "TRANSPORT_FAILURE")
  probe.release()
  _ = await active.value
}
@Test func sdkPreservesPostSnapshotBindingErrorsAsGatewaySDKEnvelopes() async throws {
  let root = try gatewaySDKTestScratchDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let input = root.appendingPathComponent("batch.json")
  try Data("{\"requests\":[]}".utf8).write(to: input)
  let snapshotter = CatalogFileSnapshotter { _, variables in
    var altered = variables
    altered["spreadsheet-id"] = .int(1)
    return .init(variables: altered, paths: [])
  }
  let sdk = GoogleDocumentsGatewaySDK(
    role: .init(service: .sheets, accessMode: .write),
    catalogFileSnapshotter: snapshotter,
    fileAccessPolicy: .init(inputRoots: [root])
  )
  let result = await sdk.invoke(.init(operation: "spreadsheet batch-update", variables: [
    "spreadsheet-id": .string("sheet"),
    "confirm-spreadsheet-id": .string("sheet"),
    "input-file": .string(input.path)
  ]), environment: [:])
  #expect(result.exitCode == 2)
  #expect(result.rawOutput.isEmpty)
  #expect(result.errors.first?.message == "variable 'spreadsheet-id' expects String! but got int")
}
