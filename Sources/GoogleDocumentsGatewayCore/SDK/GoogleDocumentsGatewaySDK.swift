import Foundation
import GatewaySDKKit

/// Role-scoped SDK façade for the existing command gateway.
public struct GoogleDocumentsGatewaySDK: GatewaySDK {
  private static let maximumCatalogTokenBytes = 64 * 1024
  private static let maximumCatalogJSONDepth = 128
  private static let maximumCatalogJSONNodes = 16 * 1024
  private static let maximumRawArgumentCount = 16 * 1024
  public let provider = "google-documents-gateway"
  public let tier: String
  public let catalog: GatewaySchemaCatalog
  public let role: GatewayRole
  private let authorizer: GatewayAuthorizing?
  private let transport: GatewayHTTPTransport
  private let credentialProfile: GatewayCredentialProfile?
  private let catalogFileSnapshotter: CatalogFileSnapshotter
  private let snapshotCleanupRegistry: GatewaySDKSnapshotCleanupRegistry
  private let fileAccessPolicy: GatewaySDKFileAccessPolicy
  private let executionPolicy: GatewaySDKExecutionPolicy
  private let executionLimiter: GatewaySDKExecutionLimiter
  private let credentialDecoder: GatewaySDKCredentialDecoder
  private let catalogTraversalObserver: @Sendable () -> Void
  private let catalogEscapedScalarObserver: (@Sendable () -> Void)?
  private let pageAllAccumulationObserver: @Sendable () -> Void
  private let requestJSONStructuralValidationObserver: @Sendable () -> Void
  private let requestJSONDecoder: GatewayProviderJSONDecoder
  private let rawDocumentParser: @Sendable (String) throws -> GatewayJSONValue
  private let rawArgumentPreflightObserver: @Sendable (Int) -> Void
  private let tokenStorePersistenceCompletedObserver: @Sendable () -> Void
  private let tokenStoreRefreshWaitObserver: @Sendable () -> Void

  public init(
    role: GatewayRole,
    authorizer: GatewayAuthorizing? = nil,
    transport: GatewayHTTPTransport = URLSessionGatewayTransport(),
    credentialProfile: GatewayCredentialProfile? = nil,
    fileAccessPolicy: GatewaySDKFileAccessPolicy = .denyAll,
    executionPolicy: GatewaySDKExecutionPolicy = .init()
  ) {
    self.init(
      role: role,
      authorizer: authorizer,
      transport: transport,
      credentialProfile: credentialProfile,
      catalogFileSnapshotter: .live,
      fileAccessPolicy: fileAccessPolicy,
      executionPolicy: executionPolicy
    )
  }

  init(
    role: GatewayRole,
    authorizer: GatewayAuthorizing? = nil,
    transport: GatewayHTTPTransport = URLSessionGatewayTransport(),
    credentialProfile: GatewayCredentialProfile? = nil,
    catalogFileSnapshotter: CatalogFileSnapshotter,
    fileAccessPolicy: GatewaySDKFileAccessPolicy = .denyAll,
    executionPolicy: GatewaySDKExecutionPolicy = .init(),
    credentialDecoder: GatewaySDKCredentialDecoder = .live,
    executionLimiter: GatewaySDKExecutionLimiter? = nil,
    catalogTraversalObserver: @escaping @Sendable () -> Void = {},
    catalogEscapedScalarObserver: (@Sendable () -> Void)? = nil,
    pageAllAccumulationObserver: @escaping @Sendable () -> Void = {},
    requestJSONStructuralValidationObserver: @escaping @Sendable () -> Void = {},
    requestJSONDecoder: GatewayProviderJSONDecoder = .live,
    rawDocumentParser: @escaping @Sendable (String) throws -> GatewayJSONValue = GatewayJSONValue.parse,
    rawArgumentPreflightObserver: @escaping @Sendable (Int) -> Void = { _ in },
    snapshotCleanupRegistry: GatewaySDKSnapshotCleanupRegistry = .durable,
    tokenStorePersistenceCompletedObserver: @escaping @Sendable () -> Void = {},
    tokenStoreRefreshWaitObserver: @escaping @Sendable () -> Void = {}
  ) {
    self.role = role
    self.authorizer = authorizer
    self.transport = transport
    self.credentialProfile = credentialProfile
    self.catalogFileSnapshotter = catalogFileSnapshotter
    self.snapshotCleanupRegistry = snapshotCleanupRegistry
    self.fileAccessPolicy = fileAccessPolicy
    self.executionPolicy = executionPolicy
    self.credentialDecoder = credentialDecoder
    self.executionLimiter = executionLimiter ?? .init(limit: executionPolicy.maximumConcurrentOperations)
    self.catalogTraversalObserver = catalogTraversalObserver
    self.catalogEscapedScalarObserver = catalogEscapedScalarObserver
    self.pageAllAccumulationObserver = pageAllAccumulationObserver
    self.requestJSONStructuralValidationObserver = requestJSONStructuralValidationObserver
    self.requestJSONDecoder = requestJSONDecoder
    self.rawDocumentParser = rawDocumentParser
    self.rawArgumentPreflightObserver = rawArgumentPreflightObserver
    self.tokenStorePersistenceCompletedObserver = tokenStorePersistenceCompletedObserver
    self.tokenStoreRefreshWaitObserver = tokenStoreRefreshWaitObserver
    catalog = .googleDocuments(role: role)
    tier = "\(role.service.rawValue)-\(role.accessMode.rawValue)"
  }

  /// Private uploaded-input snapshots still owned by this SDK after an unlink failure.
  public var pendingSnapshotCleanupRecoveries: [GatewaySDKSnapshotCleanupRecovery] {
    snapshotCleanupRegistry.recoveries()
  }

  /// Retries exactly one retained private snapshot cleanup by its stable recovery identifier.
  public func retryPendingSnapshotCleanup(recoveryID: UUID) -> [GatewaySDKSnapshotCleanupRecovery] {
    snapshotCleanupRegistry.retry(recoveryID: recoveryID)
  }

  /// Executes a JSON argv array. Variables are intentionally ignored on this raw path.
  ///
  /// Raw requests retain runner output parity, but are constrained to the SDK's command
  /// surface before dispatch so they cannot bypass catalog file isolation or credential
  /// management exclusions. Serialized documents are capped at 2 MiB, arrays at 16,384
  /// arguments, and each UTF-8 argv token at 64 KiB; parsing and all limits run inside
  /// bounded execution.
  public func execute(
    document: String,
    variables _: [String: GatewayJSONValue],
    environment: [String: String]
  ) async -> GatewayEnvelope {
    return await runBoundedEnvelope(environment: environment) { cancellation, remoteDispatch in
      do {
        guard let arguments = try rawArguments(document, cancellation: cancellation) else { return unsupportedDocument() }
        let prepared = try preparedRawArguments(arguments, cancellation: cancellation)
        let result = runner(
          environment: environment, cancellation: cancellation, remoteDispatch: remoteDispatch,
          inputDataOverrides: prepared.inputDataOverrides
        ).run(arguments: prepared.argv)
        if let cleanupError = prepared.cleanupError() {
          return cleanupFailureEnvelope(for: cleanupError, remoteDispatch: remoteDispatch)
        }
        return envelope(
          for: result,
          rawArguments: prepared.argv
        )
      } catch {
        return failureEnvelope(for: error)
      }
    }
  }

  public func buildArgv(
    operation: String,
    variables: [String: GatewayJSONValue]
  ) throws -> [String] {
    _ = try validatedArgv([operation])
    try validateCatalogVariables(variables)
    let request = GatewayOperationRequest(operation: operation, variables: variables)
    let argv = try GatewayArgvBuilder.build(request, catalog: catalog)
    guard let catalogOperation = catalog.operation(named: operation) else { return try validatedArgv(argv) }
    return try validatedArgv(try normalizedArgv(argv, operation: catalogOperation, variables: variables))
  }

  public func invoke(
    _ request: GatewayOperationRequest,
    environment: [String: String]
  ) async -> GatewayEnvelope {
    return await runBoundedEnvelope(environment: environment) { cancellation, remoteDispatch in
      do {
        // Bound before catalog or inventory lookup so unknown operation names cannot bypass the
        // execution limiter/deadline or be reflected unbounded in an error envelope.
        _ = try validatedArgv([request.operation], cancellation: cancellation)
        if catalog.operation(named: request.operation) != nil {
          let prepared = try preparedCatalogArguments(
            operation: request.operation,
            variables: request.variables,
            cancellation: cancellation
          )
          let result = runner(
            environment: environment, cancellation: cancellation, remoteDispatch: remoteDispatch,
            inputDataOverrides: prepared.inputDataOverrides
          ).run(arguments: prepared.argv)
          if let cleanupError = prepared.cleanupError() {
            return cleanupFailureEnvelope(for: cleanupError, remoteDispatch: remoteDispatch)
          }
          return envelope(for: result)
        }
        if GatewayCommandFlagInventory.allowedOptions[request.operation] != nil {
          let command = request.operation.split(separator: " ").map(String.init)
          return envelope(for: runner(environment: environment, cancellation: cancellation, remoteDispatch: remoteDispatch).run(arguments: command))
        }
        return GatewayEnvelope.failure(GatewaySDKError.unknownOperation(name: request.operation), exitCode: 2)
      } catch {
        return failureEnvelope(for: error)
      }
    }
  }

  private func runBoundedEnvelope(
    environment: [String: String],
    operation: @escaping @Sendable (GatewaySDKCancellation, GatewaySDKRemoteDispatch) -> GatewayEnvelope
  ) async -> GatewayEnvelope {
    let cancellation = GatewaySDKCancellation(
      cancellationAttemptObserver: fileAccessPolicy.cancellationAttemptObserver,
      remoteResponseAdmissionObserver: executionPolicy.remoteResponseAdmissionObserver
    )
    let remoteDispatch = GatewaySDKRemoteDispatch()
    let latch = GatewaySDKExecutionLatch<GatewayEnvelope>()
    let submission = GatewaySDKExecutionSubmission()
    return await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { continuation in
        latch.install(continuation)
        let deadline = GatewaySDKDeadline(after: executionPolicy.timeout) {
          if cancellation.cancel() { latch.finish(Self.cancellationEnvelope(deadline: true, remoteDispatch: remoteDispatch)) }
        }
        latch.observeTerminalResult {
          _ = deadline.cancel()
          submission.cancel()
        }
        guard let queued = executionLimiter.submit({
          if cancellation.isCancelled { return }
          latch.finish(operation(cancellation, remoteDispatch))
        }) else {
          _ = deadline.cancel()
          latch.finish(Self.overloadedEnvelope())
          return
        }
        submission.install(queued)
      }
    }, onCancel: {
      if cancellation.cancel() { latch.finish(Self.cancellationEnvelope(deadline: false, remoteDispatch: remoteDispatch)) }
    })
  }

  private static func cancellationEnvelope(deadline: Bool, remoteDispatch: GatewaySDKRemoteDispatch) -> GatewayEnvelope {
    let unknown = remoteDispatch.hasOutcomeUncertainDispatch
    let code = unknown ? "OUTCOME_UNKNOWN" : "TRANSPORT_FAILURE"
    let message: String
    if unknown {
      message = "Provider write may have completed; do not retry without reconciliation."
    } else {
      message = deadline ? "SDK execution exceeded its deadline" : "SDK execution was cancelled"
    }
    return .init(
      errors: [.init(message: message, code: code)], exitCode: 5,
      rawOutput: "{\"errors\":[{\"code\":\"\(code)\",\"message\":\"\(message)\"}]}"
    )
  }

  private static func overloadedEnvelope() -> GatewayEnvelope {
    let message = "SDK execution queue is full; retry later."
    return .init(
      errors: [.init(message: message, code: "TRANSPORT_FAILURE")], exitCode: 5,
      rawOutput: "{\"errors\":[{\"code\":\"TRANSPORT_FAILURE\",\"message\":\"\(message)\"}]}"
    )
  }

  private func envelope(for result: GatewayCommandResult, rawArguments: [String]? = nil) -> GatewayEnvelope {
    if result.exitCode == 0, let rawArguments, rawArguments.starts(with: ["schema", "print"]) {
      return .init(data: .string(result.stdout), exitCode: 0, rawOutput: result.stdout)
    }
    if result.exitCode == 0, let rawArguments, rawArguments.starts(with: ["schema", "search"]) {
      return .init(data: (try? GatewayJSONValue.parse(result.stdout)) ?? .string(result.stdout), exitCode: 0, rawOutput: result.stdout)
    }
    return GatewayEnvelope(parsingCLIOutput: result.stdout, exitCode: result.exitCode)
  }

  private func failureEnvelope(for error: Error) -> GatewayEnvelope {
    if let result = GatewayCommandRunner.canonicalFailure(for: error) {
      return envelope(for: result)
    }
    if let catalogFileError = error as? CatalogFileArgumentError,
      let result = GatewayCommandRunner.canonicalFailure(
        for: GatewayError.invalidArgument(catalogFileError.description)
      ) {
      return envelope(for: result)
    }
    return GatewayEnvelope.failure(error, exitCode: 2)
  }

  private func cleanupFailureEnvelope(
    for error: Error, remoteDispatch: GatewaySDKRemoteDispatch
  ) -> GatewayEnvelope {
    guard remoteDispatch.hasOutcomeUncertainDispatch else { return failureEnvelope(for: error) }
    return Self.cancellationEnvelope(deadline: false, remoteDispatch: remoteDispatch)
  }

  private func stringArguments(_ values: [GatewayJSONValue]) -> [String]? {
    let arguments = values.compactMap { value -> String? in
      guard case .string(let value) = value else { return nil }
      return value
    }
    return arguments.count == values.count ? arguments : nil
  }

  func rawArguments(
    _ document: String, cancellation: GatewaySDKCancellation?
  ) throws -> [String]? {
    try checkCancellation(cancellation)
    guard document.lengthOfBytes(using: .utf8) <= GatewayInputValidator.maximumBodyBytes else {
      throw GatewayError.inputTooLarge
    }
    guard try GatewayRawArgumentPreflight.validates(
      document,
      maximumArguments: Self.maximumRawArgumentCount,
      maximumTokenBytes: Self.maximumCatalogTokenBytes,
      cancellation: cancellation,
      progressObserver: rawArgumentPreflightObserver
    ) else { return nil }
    try checkCancellation(cancellation)
    guard let argv = try? rawDocumentParser(document), case .array(let values) = argv,
      let arguments = stringArguments(values)
    else { return nil }
    for argument in arguments {
      try checkCancellation(cancellation)
      guard argument.lengthOfBytes(using: .utf8) <= Self.maximumCatalogTokenBytes else {
        throw GatewayError.inputTooLarge
      }
    }
    return arguments
  }

  private func normalizedArgv(
    _ argv: [String],
    operation: GatewayOperation,
    variables: [String: GatewayJSONValue],
    cancellation: GatewaySDKCancellation? = nil
  ) throws -> [String] {
    let commandCount = operation.name.split(separator: " ").count
    var sourceIndex = commandCount
    var normalized = Array(argv.prefix(commandCount))

    for argument in operation.arguments {
      try checkCancellation(cancellation)
      guard let value = variables[argument.name] else { continue }
      if argument.type.namedTypeName == "Boolean" {
        switch value {
        case .null, .bool(false):
          continue
        case .bool(true):
          guard sourceIndex < argv.count else { return argv }
          normalized.append(argv[sourceIndex])
          sourceIndex += 1
        default:
          return argv
        }
        continue
      }

      if case .null = value { continue }
      if argument.type.namedTypeName == "JSON" {
        let rendered = try renderedCatalogJSON(value, cancellation: cancellation)
        let sourceTokenCount: Int
        switch value {
        case .bool(true):
          sourceTokenCount = 1
        case .bool(false):
          sourceTokenCount = 0
        case .array(let elements):
          sourceTokenCount = elements.count * 2
        default:
          sourceTokenCount = 2
        }
        guard sourceIndex + sourceTokenCount <= argv.count else { return argv }
        appendNormalizedValue(option: "--\(argument.name)", value: rendered, to: &normalized)
        sourceIndex += sourceTokenCount
        continue
      }

      switch value {
      case .null:
        continue
      case .array(let elements) where argument.type.isList:
        for _ in elements {
          guard sourceIndex + 1 < argv.count else { return argv }
          appendNormalizedValue(
            option: argv[sourceIndex],
            value: argv[sourceIndex + 1],
            to: &normalized
          )
          sourceIndex += 2
        }
      case .array(let elements):
        let rendered = try renderedCatalogJSON(value, cancellation: cancellation)
        let consumedPairs = elements.count * 2
        guard sourceIndex + consumedPairs <= argv.count else { return argv }
        appendNormalizedValue(option: "--\(argument.name)", value: rendered, to: &normalized)
        sourceIndex += consumedPairs
      case .bool:
        return argv
      default:
        guard sourceIndex + 1 < argv.count else { return argv }
        appendNormalizedValue(
          option: argv[sourceIndex],
          value: argv[sourceIndex + 1],
          to: &normalized
        )
        sourceIndex += 2
      }
    }
    return sourceIndex == argv.count ? normalized : argv
  }

  private func validateCatalogVariables(
    _ variables: [String: GatewayJSONValue], cancellation: GatewaySDKCancellation? = nil
  ) throws {
    // Account for the outer source map as well as every nested value. This preflight runs before
    // binding so hostile unknown variables cannot evade the same finite limits as valid ones.
    // It enforces only the aggregate source budget: a list becomes multiple argv tokens, so the
    // per-token ceiling is enforced after command-specific argv normalization in `validatedArgv`.
    var total = 2 // `{}`
    var nodes = 1 // outer source map
    var hasPrevious = false
    for (name, value) in variables {
      try checkCancellation(cancellation)
      if hasPrevious { try addCatalogSourceBytes(1, to: &total) } // comma
      hasPrevious = true
      // Variables originate as a JSON object. Count the encoded key, including its quotes and
      // escapes, so unknown hostile names cannot evade the aggregate source budget before bind.
      // The count is scalar-by-scalar so cancellation and the remaining aggregate budget apply
      // before an oversized key is ever serialized.
      try addCatalogSourceBytes(try catalogEscapedJSONBytes(
        name, maximumBytes: remainingCatalogSourceBytes(total), cancellation: cancellation
      ), to: &total)
      try addCatalogSourceBytes(1, to: &total) // colon
      try countCatalogNodes(value, total: &nodes, cancellation: cancellation)
      try addCatalogSourceBytes(try catalogSourceBytes(
        value, maximumBytes: remainingCatalogSourceBytes(total), cancellation: cancellation
      ), to: &total)
    }
  }

  private func countCatalogNodes(
    _ value: GatewayJSONValue, total: inout Int, cancellation: GatewaySDKCancellation?
  ) throws {
    var work: [(value: GatewayJSONValue, depth: Int)] = [(value, 0)]
    while let item = work.popLast() {
      catalogTraversalObserver()
      try checkCancellation(cancellation)
      let next = total.addingReportingOverflow(1)
      guard !next.overflow, next.partialValue <= Self.maximumCatalogJSONNodes else {
        throw GatewayError.inputTooLarge
      }
      total = next.partialValue
      switch item.value {
      case .array(let values):
        guard item.depth < Self.maximumCatalogJSONDepth,
          values.count <= remainingCatalogNodeSlots(total: total, queued: work.count)
        else { throw GatewayError.inputTooLarge }
        for child in values { work.append((child, item.depth + 1)) }
      case .object(let values):
        guard item.depth < Self.maximumCatalogJSONDepth,
          values.count <= remainingCatalogNodeSlots(total: total, queued: work.count)
        else { throw GatewayError.inputTooLarge }
        for child in values.values { work.append((child, item.depth + 1)) }
      default:
        break
      }
    }
  }

  private func validatedArgv(_ argv: [String], cancellation: GatewaySDKCancellation? = nil) throws -> [String] {
    var total = 0
    for token in argv {
      var tokenBytes = 0
      for _ in token.utf8 {
        try checkCancellation(cancellation)
        tokenBytes = try checkedCatalogSum(tokenBytes, 1, maximumBytes: Self.maximumCatalogTokenBytes)
      }
      try addCatalogTokenBytes(tokenBytes, to: &total)
    }
    return argv
  }

  private func addCatalogTokenBytes(_ bytes: Int, to total: inout Int) throws {
    guard bytes <= Self.maximumCatalogTokenBytes,
      !total.addingReportingOverflow(bytes).overflow,
      total + bytes <= GatewayInputValidator.maximumBodyBytes
    else { throw GatewayError.inputTooLarge }
    total += bytes
  }

  private func addCatalogSourceBytes(_ bytes: Int, to total: inout Int) throws {
    guard !total.addingReportingOverflow(bytes).overflow,
      total + bytes <= GatewayInputValidator.maximumBodyBytes
    else { throw GatewayError.inputTooLarge }
    total += bytes
  }

  private func remainingCatalogSourceBytes(_ total: Int) throws -> Int {
    let remaining = GatewayInputValidator.maximumBodyBytes - total
    guard remaining >= 0 else { throw GatewayError.inputTooLarge }
    return remaining
  }

  private func remainingCatalogNodeSlots(total: Int, queued: Int) -> Int {
    max(0, Self.maximumCatalogJSONNodes - total - queued)
  }

  private func catalogSourceBytes(
    _ value: GatewayJSONValue, maximumBytes: Int, cancellation: GatewaySDKCancellation? = nil
  ) throws -> Int {
    try catalogRenderedJSONBytes(
      value, maximumBytes: maximumBytes, cancellation: cancellation
    )
  }

  private func renderedCatalogJSON(
    _ value: GatewayJSONValue, cancellation: GatewaySDKCancellation? = nil
  ) throws -> String {
    _ = try catalogRenderedJSONBytes(
      value, maximumBytes: Self.maximumCatalogTokenBytes, cancellation: cancellation
    )
    try checkCancellation(cancellation)
    let rendered = try value.jsonString()
    try checkCancellation(cancellation)
    guard rendered.utf8.count <= Self.maximumCatalogTokenBytes else { throw GatewayError.inputTooLarge }
    return rendered
  }

  private func catalogRenderedJSONBytes(
    _ value: GatewayJSONValue, maximumBytes: Int, cancellation: GatewaySDKCancellation?
  ) throws -> Int {
    var bytes = 0
    var nodes = 0
    var work: [(value: GatewayJSONValue, depth: Int)] = [(value, 0)]
    while let item = work.popLast() {
      catalogTraversalObserver()
      try checkCancellation(cancellation)
      nodes += 1
      guard nodes <= Self.maximumCatalogJSONNodes else { throw GatewayError.inputTooLarge }
      switch item.value {
      case .null:
        bytes = try checkedCatalogSum(bytes, 4, maximumBytes: maximumBytes)
      case .bool(let value):
        bytes = try checkedCatalogSum(bytes, value ? 4 : 5, maximumBytes: maximumBytes)
      case .int(let value):
        bytes = try checkedCatalogSum(bytes, String(value).utf8.count, maximumBytes: maximumBytes)
      case .double(let value):
        guard value.isFinite else { throw GatewaySDKError.invalidJSONValue("non-finite double \(value)") }
        bytes = try checkedCatalogSum(bytes, String(value).utf8.count, maximumBytes: maximumBytes)
      case .string(let value):
        bytes = try checkedCatalogSum(
          bytes, try catalogEscapedJSONBytes(value, maximumBytes: maximumBytes, cancellation: cancellation),
          maximumBytes: maximumBytes
        )
      case .array(let values):
        guard item.depth < Self.maximumCatalogJSONDepth,
          values.count <= Self.maximumCatalogJSONNodes - nodes - work.count
        else { throw GatewayError.inputTooLarge }
        bytes = try checkedCatalogSum(bytes, 2, maximumBytes: maximumBytes)
        if values.count > 1 { bytes = try checkedCatalogSum(bytes, values.count - 1, maximumBytes: maximumBytes) }
        for child in values { work.append((child, item.depth + 1)) }
      case .object(let values):
        guard item.depth < Self.maximumCatalogJSONDepth,
          values.count <= Self.maximumCatalogJSONNodes - nodes - work.count
        else { throw GatewayError.inputTooLarge }
        bytes = try checkedCatalogSum(bytes, 2, maximumBytes: maximumBytes)
        if values.count > 1 { bytes = try checkedCatalogSum(bytes, values.count - 1, maximumBytes: maximumBytes) }
        for (key, child) in values {
          bytes = try checkedCatalogSum(
            bytes, try catalogEscapedJSONBytes(key, maximumBytes: maximumBytes, cancellation: cancellation),
            maximumBytes: maximumBytes
          )
          bytes = try checkedCatalogSum(bytes, 1, maximumBytes: maximumBytes)
          work.append((child, item.depth + 1))
        }
      }
    }
    return bytes
  }

  private func catalogEscapedJSONBytes(
    _ value: String, maximumBytes: Int, cancellation: GatewaySDKCancellation?
  ) throws -> Int {
    var bytes = 2
    for scalar in value.unicodeScalars {
      try checkCancellation(cancellation)
      let scalarBytes: Int
      switch scalar.value {
      case 0x22, 0x5C, 0x0A, 0x0D, 0x09: scalarBytes = 2
      case 0 ... 0x1F: scalarBytes = 6
      case 0 ... 0x7F: scalarBytes = 1
      case 0 ... 0x7FF: scalarBytes = 2
      case 0 ... 0xFFFF: scalarBytes = 3
      default: scalarBytes = 4
      }
      bytes = try checkedCatalogSum(bytes, scalarBytes, maximumBytes: maximumBytes)
      catalogEscapedScalarObserver?()
    }
    return bytes
  }

  private func checkedCatalogSum(_ lhs: Int, _ rhs: Int, maximumBytes: Int) throws -> Int {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow, result.partialValue <= maximumBytes else {
      throw GatewayError.inputTooLarge
    }
    return result.partialValue
  }

  private func appendNormalizedValue(option: String, value: String, to argv: inout [String]) {
    if value.hasPrefix("-") {
      argv.append("\(option)=\(value)")
    } else {
      argv += [option, value]
    }
  }

  private func authorizeCatalogFileArguments(
    operation: GatewayOperation,
    variables: [String: GatewayJSONValue],
    cancellation: GatewaySDKCancellation?
  ) throws -> [String: GatewaySDKAuthorizedInput] {
    let names = Set(operation.arguments.map(\.name)).intersection(["input", "input-file", "json-file"])
    var inputs: [String: GatewaySDKAuthorizedInput] = [:]
    do {
      for name in names {
        guard case .string(let path) = variables[name] else { continue }
        inputs[name] = try fileAccessPolicy.authorizeInput(
          path: path, argument: name, cancellation: cancellation
        )
      }
      return inputs
    } catch {
      inputs.values.forEach { $0.close() }
      throw error
    }
  }

  private func validateCatalogOutputArguments(
    operation: GatewayOperation,
    variables: [String: GatewayJSONValue],
    cancellation: GatewaySDKCancellation?
  ) throws {
    guard operation.arguments.contains(where: { $0.name == "output" }), case .string(let path) = variables["output"] else { return }
    try fileAccessPolicy.outputWriter(cancellation: cancellation).validate(
      path, variables["overwrite"] == .bool(true)
    )
  }

  func preparedCatalogArguments(
    operation: String,
    variables: [String: GatewayJSONValue],
    cancellation: GatewaySDKCancellation? = nil
  ) throws -> CatalogPreparedArguments {
    try checkCancellation(cancellation)
    try validateCatalogVariables(variables, cancellation: cancellation)
    guard let catalogOperation = catalog.operation(named: operation) else {
      return .init(argv: try buildArgv(operation: operation, variables: variables), snapshotPaths: [])
    }
    // Validate the caller's binding before touching any caller-controlled file path. Snapshot
    // substitution changes only file values, so it must be followed by a second rendering pass.
    _ = try catalogArgv(operation: operation, definition: catalogOperation, variables: variables, cancellation: cancellation)
    let authorizedInputs = try authorizeCatalogFileArguments(
      operation: catalogOperation, variables: variables, cancellation: cancellation
    )
    defer { authorizedInputs.values.forEach { $0.close() } }
    try validateCatalogOutputArguments(
      operation: catalogOperation, variables: variables, cancellation: cancellation
    )
    let snapshots = try catalogFileSnapshotter.prepare(
      catalogOperation,
      variables,
      sourceReader: { _, argument, maximumBytes in
        guard let input = authorizedInputs[argument] else {
          throw GatewayError.invalidArgument("Missing authorized catalog input")
        }
        return try input.read(maximumBytes: maximumBytes, cancellation: cancellation)
      },
      cancellation: cancellation,
      cleanupRegistry: snapshotCleanupRegistry
    )
    do {
      return .init(
        argv: try catalogArgv(operation: operation, definition: catalogOperation, variables: snapshots.variables, cancellation: cancellation),
        snapshots: snapshots
      )
    } catch {
      if let cleanupError = snapshots.cleanupError() { throw cleanupError }
      throw error
    }
  }

  private func preparedRawArguments(
    _ arguments: [String],
    cancellation: GatewaySDKCancellation? = nil
  ) throws -> CatalogPreparedArguments {
    try checkCancellation(cancellation)
    if arguments == ["--help"] || arguments == ["-h"] || arguments.isEmpty || arguments == ["--version"] {
      return .init(argv: arguments, snapshotPaths: [])
    }
    guard !arguments.contains("--help"), !arguments.contains("-h") else {
      throw GatewayError.forbiddenCommand("Help must be requested as a standalone SDK argv request")
    }
    let command = try rawCommand(in: arguments)
    guard command.name != "auth login", command.name != "auth logout", command.name != "auth revoke" else {
      throw GatewayError.forbiddenCommand("Credential login and revocation are not available through the SDK.")
    }
    guard command.name != "operation run" else {
      throw GatewayError.forbiddenCommand("Raw operation run is not available through the SDK.")
    }
    guard let catalogOperation = catalog.operation(named: command.name) else {
      return .init(argv: arguments, snapshotPaths: [])
    }

    let parsed = try rawCatalogArguments(
      arguments,
      operation: catalogOperation,
      commandTokenCount: command.tokenCount
    )
    guard !parsed.fileValues.isEmpty else { return .init(argv: arguments, snapshotPaths: []) }
    _ = try catalogArgv(
      operation: catalogOperation.name,
      definition: catalogOperation,
      variables: parsed.values,
      cancellation: cancellation
    )
    let authorizedInputs = try authorizeCatalogFileArguments(
      operation: catalogOperation, variables: parsed.values, cancellation: cancellation
    )
    defer { authorizedInputs.values.forEach { $0.close() } }
    try validateCatalogOutputArguments(
      operation: catalogOperation, variables: parsed.values, cancellation: cancellation
    )
    let snapshots = try catalogFileSnapshotter.prepare(
      catalogOperation,
      parsed.fileValues,
      sourceReader: { _, argument, maximumBytes in
        guard let input = authorizedInputs[argument] else {
          throw GatewayError.invalidArgument("Missing authorized catalog input")
        }
        return try input.read(maximumBytes: maximumBytes, cancellation: cancellation)
      },
      cancellation: cancellation,
      cleanupRegistry: snapshotCleanupRegistry
    )
    var snapshotArguments = arguments
    for (name, location) in parsed.fileLocations {
      guard case .string(let path)? = snapshots.variables[name] else { continue }
      location.replace(with: path, in: &snapshotArguments)
    }
    for name in ["name", "mime-type"] where parsed.locations[name] == nil {
      guard case .string(let value)? = snapshots.variables[name] else { continue }
      snapshotArguments += ["--\(name)", value]
    }
    return .init(argv: snapshotArguments, snapshots: snapshots)
  }

  private func catalogArgv(
    operation: String,
    definition: GatewayOperation,
    variables: [String: GatewayJSONValue],
    cancellation: GatewaySDKCancellation?
  ) throws -> [String] {
    try validatedArgv(try normalizedArgv(
      GatewayArgvBuilder.build(.init(operation: operation, variables: variables), catalog: catalog),
      operation: definition,
      variables: variables,
      cancellation: cancellation
    ), cancellation: cancellation)
  }

  /// Matches `ParsedArguments` command formation so raw SDK policy is applied before
  /// the runner can interpret a combined command token such as `"auth login"`.
  private func rawCommand(in arguments: [String]) throws -> RawCommand {
    if arguments.starts(with: ["schema", "print"]) {
      return .init(name: "schema print", tokenCount: 2)
    }
    if arguments.starts(with: ["schema", "search"]) {
      return .init(name: "schema search", tokenCount: 2)
    }
    if arguments.starts(with: ["operation", "run"]) {
      return .init(name: "operation run", tokenCount: 2)
    }
    let commandTokens = arguments.prefix { !$0.hasPrefix("-") }
    guard !commandTokens.isEmpty, commandTokens.count <= 2 else {
      throw GatewayError.invalidArgument("Expected a command")
    }
    return .init(name: commandTokens.joined(separator: " "), tokenCount: commandTokens.count)
  }

  private func rawCatalogArguments(
    _ arguments: [String],
    operation: GatewayOperation,
    commandTokenCount: Int
  ) throws -> RawCatalogArguments {
    let declarations = Dictionary(uniqueKeysWithValues: operation.arguments.map { ($0.name, $0) })
    var values: [String: GatewayJSONValue] = [:]
    var locations: [String: RawOptionLocation] = [:]
    var index = commandTokenCount

    while index < arguments.count {
      let token = arguments[index]
      guard token.hasPrefix("--") else {
        throw GatewayError.invalidArgument("Unexpected raw SDK argument \(token)")
      }
      let option = String(token.dropFirst(2))
      let name = String(option.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
      guard let declaration = declarations[name] else {
        throw GatewayError.invalidArgument("Unsupported option --\(name) for \(operation.name)")
      }
      if declaration.type.namedTypeName == "Boolean" {
        guard !token.contains("=") else {
          throw GatewayError.invalidArgument("--\(name) does not accept a value")
        }
        values[name] = .bool(true)
        index += 1
        continue
      }

      let value: String
      let location: RawOptionLocation
      if let equals = token.firstIndex(of: "=") {
        value = String(token[token.index(after: equals)...])
        location = .inline(index: index, name: name)
        index += 1
      } else {
        guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
          throw GatewayError.invalidArgument("Missing value for --\(name)")
        }
        value = arguments[index + 1]
        location = .separate(index: index + 1)
        index += 2
      }
      locations[name] = location
      values[name] = rawValue(value, for: declaration)
    }

    let fileNames = Set(operation.arguments.map(\.name)).intersection(["input", "input-file", "json-file"])
    let fileValues = values.filter { fileNames.contains($0.key) }
    if fileValues.isEmpty { return .init(values: values, fileValues: [:], locations: locations, fileLocations: [:]) }

    var snapshotValues = fileValues
    for name in ["max-bytes", "name", "mime-type"] {
      if let value = values[name] { snapshotValues[name] = value }
    }
    return .init(
      values: values,
      fileValues: snapshotValues,
      locations: locations,
      fileLocations: locations.filter { fileNames.contains($0.key) }
    )
  }

  private func rawValue(_ value: String, for declaration: GatewayArgument) -> GatewayJSONValue {
    if declaration.type.namedTypeName == "Int", let integer = Int(value) {
      return .int(integer)
    }
    return .string(value)
  }
  private func unsupportedDocument() -> GatewayEnvelope {
    GatewayEnvelope(
      errors: [.init(message: "Command SDK documents must be JSON arrays of strings.", code: "UNSUPPORTED_DOCUMENT")],
      exitCode: 2
    )
  }
}
private extension GoogleDocumentsGatewaySDK {
  func runner(
    environment: [String: String], cancellation: GatewaySDKCancellation? = nil,
    remoteDispatch: GatewaySDKRemoteDispatch? = nil, inputDataOverrides: [String: Data] = [:]
  ) -> GatewayCommandRunner {
    let boundedTransport: GatewayHTTPTransport
    if let cancellation {
      boundedTransport = GatewayBoundedTransport(
        base: transport, timeout: executionPolicy.timeout,
        maximumResponseBytes: executionPolicy.maximumResponseBytes,
        cancellation: cancellation, remoteDispatch: remoteDispatch ?? .init()
      )
    } else {
      boundedTransport = transport
    }
    return GatewayCommandRunner(
      role: role,
      authorizer: authorizer,
      transport: boundedTransport,
      credentialProfile: credentialProfile,
      environment: environment,
      outputWriter: fileAccessPolicy.outputWriter(cancellation: cancellation),
      cancellation: cancellation,
      remoteDispatch: remoteDispatch,
      credentialDecoder: credentialDecoder,
      maximumAggregateResponseBytes: executionPolicy.maximumResponseBytes,
      pageAllAccumulationObserver: pageAllAccumulationObserver,
      requestJSONStructuralValidationObserver: requestJSONStructuralValidationObserver,
      requestJSONDecoder: requestJSONDecoder,
      inputDataOverrides: inputDataOverrides,
      tokenStorePersistenceCompletedObserver: tokenStorePersistenceCompletedObserver,
      tokenStoreRefreshWaitObserver: tokenStoreRefreshWaitObserver
    )
  }
}

private enum GatewayRawArgumentPreflight {
  /// Validates the only accepted raw-document shape, a flat JSON array of strings, before
  /// Foundation materializes a JSON graph. Raw string bytes are an upper bound on decoded UTF-8
  /// bytes because JSON escapes never shorten their source representation.
  static func validates(
    _ document: String,
    maximumArguments: Int,
    maximumTokenBytes: Int,
    cancellation: GatewaySDKCancellation?,
    progressObserver: @escaping @Sendable (Int) -> Void
  ) throws -> Bool {
    var scanner = GatewayRawByteScanner(document.utf8)
    var arguments = 0
    try scanner.skipWhitespace(cancellation, progressObserver)
    guard scanner.consume(0x5B) else { return false }
    try scanner.skipWhitespace(cancellation, progressObserver)
    if scanner.consume(0x5D) {
      try scanner.skipWhitespace(cancellation, progressObserver)
      return scanner.isAtEnd()
    }
    while true {
      try check(cancellation, at: scanner.offset, progressObserver)
      guard scanner.consume(0x22), try scanner.stringEnds(maximumTokenBytes, cancellation, progressObserver) else {
        return false
      }
      arguments += 1
      guard arguments <= maximumArguments else { throw GatewayError.inputTooLarge }
      try scanner.skipWhitespace(cancellation, progressObserver)
      if scanner.consume(0x5D) {
        try scanner.skipWhitespace(cancellation, progressObserver)
        return scanner.isAtEnd()
      }
      guard scanner.consume(0x2C) else { return false }
      try scanner.skipWhitespace(cancellation, progressObserver)
    }
  }

  private struct GatewayRawByteScanner {
    private var iterator: String.UTF8View.Iterator
    private var nextByte: UInt8?
    var offset = 0

    init(_ bytes: String.UTF8View) { iterator = bytes.makeIterator() }

    mutating func isAtEnd() -> Bool { peek() == nil }

    mutating func skipWhitespace(
      _ cancellation: GatewaySDKCancellation?, _ progressObserver: @escaping @Sendable (Int) -> Void
    ) throws {
      while let byte = peek(), [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
        _ = take()
        try GatewayRawArgumentPreflight.check(cancellation, at: offset, progressObserver)
      }
    }

    mutating func consume(_ expected: UInt8) -> Bool {
      guard peek() == expected else { return false }
      _ = take()
      return true
    }

    mutating func stringEnds(
      _ maximumTokenBytes: Int, _ cancellation: GatewaySDKCancellation?,
      _ progressObserver: @escaping @Sendable (Int) -> Void
    ) throws -> Bool {
      var sourceBytes = 0
      while let byte = take() {
        try GatewayRawArgumentPreflight.check(cancellation, at: offset, progressObserver)
        if byte == 0x22 { return true }
        guard byte >= 0x20 else { return false }
        sourceBytes += 1
        guard sourceBytes <= maximumTokenBytes else { throw GatewayError.inputTooLarge }
        guard byte == 0x5C else { continue }
        guard let escape = take() else { return false }
        sourceBytes += 1
        guard sourceBytes <= maximumTokenBytes else { throw GatewayError.inputTooLarge }
        switch escape {
        case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
          continue
        case 0x75:
          for _ in 0 ..< 4 {
            guard let hex = take(), GatewayRawArgumentPreflight.isHex(hex) else { return false }
          }
          sourceBytes += 4
          guard sourceBytes <= maximumTokenBytes else { throw GatewayError.inputTooLarge }
        default:
          return false
        }
      }
      return false
    }

    private mutating func peek() -> UInt8? {
      if nextByte == nil { nextByte = iterator.next() }
      return nextByte
    }

    private mutating func take() -> UInt8? {
      let byte = peek()
      if byte != nil { nextByte = nil; offset += 1 }
      return byte
    }
  }

  private static func isHex(_ byte: UInt8) -> Bool {
    (0x30 ... 0x39).contains(byte) || (0x41 ... 0x46).contains(byte) || (0x61 ... 0x66).contains(byte)
  }

  private static func check(
    _ cancellation: GatewaySDKCancellation?, at index: Int,
    _ progressObserver: @escaping @Sendable (Int) -> Void
  ) throws {
    if index & 0x0FFF == 0 {
      progressObserver(index)
      try checkCancellation(cancellation)
    }
  }
}
