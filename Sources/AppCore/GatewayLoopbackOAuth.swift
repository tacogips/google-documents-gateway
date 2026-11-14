import AppKit
import Foundation
import Network

public struct GatewayLoopbackOAuth: Sendable {
  public let profile: GatewayCredentialProfile
  public let transport: GatewayHTTPTransport

  public init(profile: GatewayCredentialProfile, transport: GatewayHTTPTransport = URLSessionGatewayTransport()) {
    self.profile = profile
    self.transport = transport
  }

  public func login(timeout: TimeInterval = 180) throws -> GatewayTokenStore {
    let callback = LoopbackCallback()
    let port = try callback.start(timeout: min(timeout, 10))
    defer { callback.cancel() }

    let state = Self.randomURLSafe(byteCount: 32)
    let verifier = Self.randomURLSafe(byteCount: 64)
    let redirectURI = "http://127.0.0.1:\(port)/callback"
    let authorizationURL = try GatewayOAuthPKCE.authorizationURL(
      profile: profile,
      redirectURI: redirectURI,
      state: state,
      verifier: verifier
    )
    try Self.openBrowser(authorizationURL)
    let result = try callback.wait(timeout: timeout)
    guard result.state == state else { throw GatewayError.authenticationRequired }
    guard result.error == nil, let code = result.code, !code.isEmpty else {
      throw GatewayError.authenticationRequired
    }
    return try GatewayOAuthClient(profile: profile, transport: transport)
      .exchangeAuthorizationCode(code, redirectURI: redirectURI, verifier: verifier)
  }

  private static func randomURLSafe(byteCount: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func openBrowser(_ url: URL) throws {
    guard NSWorkspace.shared.open(url) else { throw GatewayError.authenticationRequired }
  }
}

private struct LoopbackResult: Sendable {
  let code: String?
  let state: String?
  let error: String?
}

private final class LoopbackCallback: @unchecked Sendable {
  private let queue = DispatchQueue(label: "document-gateway.oauth-loopback")
  private let ready = DispatchSemaphore(value: 0)
  private let completed = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var listener: NWListener?
  private var port: UInt16?
  private var startupError: Error?
  private var result: LoopbackResult?

  func start(timeout: TimeInterval) throws -> UInt16 {
    let listener = try NWListener(using: .tcp, on: .any)
    self.listener = listener
    listener.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        lock.lock()
        port = listener.port?.rawValue
        lock.unlock()
        ready.signal()
      case .failed(let error):
        lock.lock()
        startupError = error
        lock.unlock()
        ready.signal()
      default:
        break
      }
    }
    listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + timeout) == .success else {
      throw GatewayError.transportFailure("OAuth loopback listener timed out")
    }
    lock.lock()
    defer { lock.unlock() }
    if startupError != nil { throw GatewayError.transportFailure("OAuth loopback listener failed") }
    guard let port else { throw GatewayError.transportFailure("OAuth loopback listener did not bind a port") }
    return port
  }

  func wait(timeout: TimeInterval) throws -> LoopbackResult {
    guard completed.wait(timeout: .now() + timeout) == .success else {
      throw GatewayError.transportFailure("OAuth login timed out")
    }
    lock.lock()
    defer { lock.unlock() }
    guard let result else { throw GatewayError.authenticationRequired }
    return result
  }

  func cancel() {
    listener?.cancel()
  }

  private func receive(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
      guard let self else { return }
      let parsed = data.flatMap(Self.parseRequest)
      let body = parsed?.error == nil && parsed?.code != nil
        ? "Authorization received. You can close this window."
        : "Authorization failed. Return to the terminal."
      let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
      connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
      lock.lock()
      if result == nil { result = parsed }
      lock.unlock()
      completed.signal()
    }
  }

  private static func parseRequest(_ data: Data) -> LoopbackResult? {
    guard
      let request = String(data: data, encoding: .utf8),
      let firstLine = request.split(separator: "\n", maxSplits: 1).first,
      firstLine.hasPrefix("GET "),
      let target = firstLine.split(separator: " ").dropFirst().first,
      let components = URLComponents(string: "http://127.0.0.1\(target)"),
      components.path == "/callback"
    else { return nil }
    let values = (components.queryItems ?? []).reduce(into: [String: String]()) { values, item in
      values[item.name] = item.value ?? ""
    }
    return LoopbackResult(code: values["code"], state: values["state"], error: values["error"])
  }
}
