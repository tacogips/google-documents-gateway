import AppKit
import Foundation
import GoogleGatewayAuth

public struct GatewayLoopbackOAuth: Sendable {
  public let profile: GatewayCredentialProfile
  public let transport: GatewayHTTPTransport

  public init(profile: GatewayCredentialProfile, transport: GatewayHTTPTransport = URLSessionGatewayTransport()) {
    self.profile = profile
    self.transport = transport
  }

  public func login(timeout: TimeInterval = 180, openBrowser: Bool = true) throws -> GatewayTokenStore {
    do { return try performLogin(timeout: timeout, openBrowser: openBrowser) }
    catch let error as GatewayAuthError {
      if error.kind == .configuration { throw GatewayError.invalidArgument(error.description) }
      throw GatewayError.transportFailure(error.description)
    }
  }

  private func performLogin(timeout: TimeInterval, openBrowser: Bool) throws -> GatewayTokenStore {
    guard !profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GatewayError.authenticationRequired }
    let prefix = "GOOGLE_" + profile.role.service.rawValue.uppercased() + "_GATEWAY_"
    let settings = try OAuthCallbackSettings(prefix: prefix, defaultPath: "/callback",
      requestedURI: profile.oauthClientKind == "web" && !OAuthCallbackSettings.isConfigured(prefix: prefix)
        ? profile.oauthRedirectURIs.first : nil)
    let callback = try OAuthCallbackServer(settings: settings)

    let state = Self.randomURLSafe(byteCount: 32)
    let verifier = Self.randomURLSafe(byteCount: 64)
    let redirectURI = callback.redirectURI.absoluteString
    try OAuthCallbackSettings.validateClientRedirect(kind: profile.oauthClientKind, registered: profile.oauthRedirectURIs, redirect: redirectURI)
    let authorizationURL = try GatewayOAuthPKCE.authorizationURL(
      profile: profile,
      redirectURI: redirectURI,
      state: state,
      verifier: verifier
    )
    try GatewayAuthorizationPresenter.live.present(authorizationURL, openBrowser: openBrowser)
    let result = try callback.wait(expectedState: state, timeout: timeout)
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
}

struct GatewayAuthorizationPresenter: Sendable {
  let browserOpener: @Sendable (URL) -> Bool
  let manualReporter: @Sendable (URL) -> Void

  func present(_ url: URL, openBrowser: Bool) throws {
    if openBrowser {
      guard browserOpener(url) else { throw GatewayError.authenticationRequired }
    } else {
      manualReporter(url)
    }
  }

  static let live = GatewayAuthorizationPresenter(
    browserOpener: { NSWorkspace.shared.open($0) },
    manualReporter: { url in
      let message = "Open this Google OAuth authorization URL to continue: \(url.absoluteString)\n"
      FileHandle.standardError.write(Data(message.utf8))
    }
  )
}
