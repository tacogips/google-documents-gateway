import Darwin
import Foundation
import GatewaySDKKit

public struct GatewayOutputWriter: Sendable {
  let validate: @Sendable (String, Bool) throws -> Void
  let write: @Sendable (Data, String, Bool) throws -> Void

  init(validate: @escaping @Sendable (String, Bool) throws -> Void, write: @escaping @Sendable (Data, String, Bool) throws -> Void) {
    self.validate = validate
    self.write = write
  }

  public static let live = Self(
    validate: { path, overwrite in
      if FileManager.default.fileExists(atPath: path), !overwrite { throw GatewayError.invalidArgument("Output exists; specify --overwrite") }
    },
    write: { data, path, _ in try data.write(to: URL(fileURLWithPath: path), options: [.atomic]) }
  )
}

struct GatewaySDKDescriptorOperations: @unchecked Sendable {
  let open: (String, Int32) -> Int32
  let openAt: (Int32, String, Int32) -> Int32
  let close: (Int32) -> Int32
  static let live = Self(
    open: { path, flags in path.withCString { Darwin.open($0, flags) } },
    openAt: { descriptor, path, flags in path.withCString { Darwin.openat(descriptor, $0, flags) } },
    close: { Darwin.close($0) }
  )
}

enum GatewaySDKCommandRouter {
  static func handle(arguments: [String], runner: GatewayCommandRunner) -> GatewayCommandResult? {
    guard arguments.starts(with: ["schema", "print"])
      || arguments.starts(with: ["schema", "search"])
      || arguments.starts(with: ["operation", "run"])
    else { return nil }
    let catalog = GatewaySchemaCatalog.googleDocuments(role: runner.role)
    switch Array(arguments.prefix(2)) {
    case ["schema", "print"]:
      return arguments.count == 2 ? .init(stdout: catalog.sdl(), exitCode: 0) : failure("schema print does not accept arguments")
    case ["schema", "search"]:
      return schemaSearch(Array(arguments.dropFirst(2)), catalog: catalog)
    case ["operation", "run"]:
      return operationRun(Array(arguments.dropFirst(2)), runner: runner)
    default:
      return nil
    }
  }

  private static func schemaSearch(_ arguments: [String], catalog: GatewaySchemaCatalog) -> GatewayCommandResult {
    guard let pattern = arguments.first, !pattern.hasPrefix("--") else { return failure("schema search requires a regex") }
    var kinds = Set(GatewayDefinitionKind.allCases)
    kinds.remove(.scalar)
    var hasKinds = false
    var includeTypes = false
    var limit: Int?
    var index = 1
    while index < arguments.count {
      let token = arguments[index]
      if token == "--include-referenced-types" {
        guard !includeTypes else { return failure("Duplicate option --include-referenced-types") }
        includeTypes = true
        index += 1
      } else if token == "--kinds" || token.hasPrefix("--kinds=") {
        guard !hasKinds else { return failure("Duplicate option --kinds") }
        guard let value = optionValue(token, arguments: arguments, index: &index), !value.isEmpty else { return failure("Missing value for --kinds") }
        let rawKinds = value.split(separator: ",", omittingEmptySubsequences: false)
        guard !rawKinds.contains(where: \.isEmpty) else { return failure("Schema kinds cannot be empty") }
        let parsed = rawKinds.compactMap { GatewayDefinitionKind(rawValue: String($0)) }
        guard parsed.count == rawKinds.count else { return failure("Unknown schema kind") }
        kinds = Set(parsed)
        hasKinds = true
      } else if token == "--limit" || token.hasPrefix("--limit=") {
        guard limit == nil, let value = optionValue(token, arguments: arguments, index: &index), let parsed = Int(value), parsed >= 0 else { return failure("--limit must be a non-negative base-10 integer") }
        limit = parsed
      } else {
        return failure("Unsupported schema search option \(token)")
      }
    }
    do {
      let matches = try GatewaySchemaSearch(catalog: catalog).search(pattern, options: .init(kinds: kinds, includeReferencedTypes: includeTypes, limit: limit))
      let data = try JSONEncoder.prettySorted.encode(matches)
      guard let output = String(data: data, encoding: .utf8) else {
        return failure("Unable to encode schema search results")
      }
      return .init(stdout: output, exitCode: 0)
    } catch {
      return failure(String(describing: error))
    }
  }

  static func operationRun(
    _ arguments: [String],
    runner: GatewayCommandRunner,
    variablesFileReader: ((String) -> String?)? = nil,
    fileAccessPolicy: GatewaySDKFileAccessPolicy = .commandLine,
    catalogFileSnapshotter: CatalogFileSnapshotter = .live
  ) -> GatewayCommandResult {
    guard let flagIndex = arguments.firstIndex(where: { $0.hasPrefix("--") }), flagIndex > 0 else {
      return failure("operation run requires a name and variables")
    }
    let name = arguments[..<flagIndex].joined(separator: " ")
    let options = Array(arguments[flagIndex...])

    let catalog = GatewaySchemaCatalog.googleDocuments(role: runner.role)
    guard catalog.operation(named: name) != nil else {
      if GatewayCommandFlagInventory.allowedOptions[name] != nil {
        // Preserve the runner's role-gate envelope without examining caller-controlled
        // variables sources for an operation that belongs to another role.
        return runner.run(arguments: name.split(separator: " ").map(String.init))
      }
      return failure("Unknown operation \(name)")
    }

    guard let variables = variables(
      from: options,
      variablesFileReader: variablesFileReader ?? { boundedVariablesFile(at: $0) }
    ) else { return failure("operation run requires exactly one variables source") }
    do {
      let object = try GatewayJSONValue.parse(variables)
      guard case .object(let values) = object else { return failure("--variables must contain a JSON object") }
      let sdk = GoogleDocumentsGatewaySDK(
        role: runner.role,
        catalogFileSnapshotter: catalogFileSnapshotter,
        fileAccessPolicy: fileAccessPolicy
      )
      let prepared = try sdk.preparedCatalogArguments(operation: name, variables: values)
      let remoteDispatch = GatewaySDKRemoteDispatch()
      let result = runner.trackingRemoteDispatch(remoteDispatch).run(
        arguments: prepared.argv, inputDataOverrides: prepared.inputDataOverrides
      )
      if let cleanupError = prepared.cleanupError(), let failure = GatewayCommandRunner.canonicalFailure(for: cleanupError) {
        if remoteDispatch.hasOutcomeUncertainDispatch {
          return GatewayCommandRunner.outcomeUnknownFailure()
        }
        return failure
      }
      return result
    } catch {
      if let result = GatewayCommandRunner.canonicalFailure(for: error) {
        return result
      }
      return failure(String(describing: error))
    }
  }

  private static func variables(
    from arguments: [String],
    variablesFileReader: (String) -> String?
  ) -> String? {
    var sources: [String] = []
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      if token == "--variables" || token.hasPrefix("--variables=") {
        guard let value = optionValue(token, arguments: arguments, index: &index) else { return nil }
        sources.append(value)
      } else if token == "--variables-file" || token.hasPrefix("--variables-file=") {
        guard
          let path = optionValue(token, arguments: arguments, index: &index),
          let value = variablesFileReader(path)
        else { return nil }
        sources.append(value)
      } else {
        return nil
      }
    }
    return sources.count == 1 ? sources[0] : nil
  }

  static func boundedVariablesFile(
    at path: String,
    opener: ((String, Int32) -> Int32)? = nil,
    statusReader: ((Int32, UnsafeMutablePointer<stat>) -> Int32)? = nil,
    dataReader: ((Int32, Int) throws -> Data)? = nil,
    descriptorOperations: GatewaySDKDescriptorOperations = .live
  ) -> String? {
    let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    let descriptor = opener?(path, flags) ?? openVariablesFile(at: path, flags: flags, operations: descriptorOperations)
    guard descriptor >= 0 else { return nil }
    defer { _ = descriptorOperations.close(descriptor) }

    var fileStatus = stat()
    let statusResult = statusReader?(descriptor, &fileStatus) ?? Darwin.fstat(descriptor, &fileStatus)
    guard statusResult == 0, (fileStatus.st_mode & S_IFMT) == S_IFREG else { return nil }

    do {
      let limit = GatewayInputValidator.maximumBodyBytes
      let data = try CatalogFileSnapshots.readBoundedData(
        from: descriptor,
        maximumBytes: limit,
        dataReader: dataReader
      )
      guard data.count <= limit else { return nil }
      return String(data: data, encoding: .utf8)
    } catch {
      return nil
    }
  }

  private static func openVariablesFile(at path: String, flags: Int32, operations: GatewaySDKDescriptorOperations) -> Int32 {
    let components = URL(fileURLWithPath: path).standardizedFileURL.path.split(separator: "/").map(String.init)
    guard let leaf = components.last, !leaf.isEmpty else { return -1 }
    var parent = operations.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard parent >= 0 else { return -1 }
    for component in components.dropLast() {
      let next = operations.openAt(parent, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
      guard next >= 0 else { _ = operations.close(parent); return -1 }
      _ = operations.close(parent)
      parent = next
    }
    let descriptor = operations.openAt(parent, leaf, flags)
    _ = operations.close(parent)
    return descriptor
  }

  private static func optionValue(_ token: String, arguments: [String], index: inout Int) -> String? {
    if let equals = token.firstIndex(of: "=") {
      index += 1
      return String(token[token.index(after: equals)...])
    }
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { return nil }
    index += 2
    return arguments[index - 1]
  }

  private static func failure(_ message: String) -> GatewayCommandResult {
    let object: [String: Any] = ["ok": false, "error": ["code": "INVALID_ARGUMENT", "message": message]]
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return .init(stdout: String(data: data, encoding: .utf8) ?? "{\"ok\":false}", exitCode: 2)
  }
}

private extension JSONEncoder {
  static var prettySorted: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }
}
