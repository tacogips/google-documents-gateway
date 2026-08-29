import Foundation
import Testing
@testable import AppCore

@Test func commandReportsVersion() throws {
  let command = AppCommand(arguments: ["--version"])
  #expect(try command.run() == Version.current)
}

@Test func commandReportsUsage() throws {
  let command = AppCommand(arguments: ["--help"])
  #expect(try command.run().contains("Usage: google-documents-gateway"))
}

@Test func commandRejectsUnknownFlags() throws {
  let command = AppCommand(arguments: ["--unknown"])
  do {
    _ = try command.run()
    Issue.record("Expected an unknown argument error")
  } catch AppCommand.Error.unknownArgument(let argument) {
    #expect(argument == "--unknown")
  } catch {
    Issue.record("Unexpected error: \(error)")
  }
}

/// A host that links this package as a library supplies one call's credential
/// environment directly; the command runner must resolve profiles from that
/// environment rather than the host process's own.
@Test func commandRunnerResolvesCredentialsFromTheInjectedEnvironment() throws {
  let variable = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_DOCS_READER_OAUTH_CLIENT_ID"
  #expect(ProcessInfo.processInfo.environment[variable] == nil)

  let runner = GatewayCommandRunner(
    role: GatewayRole(service: .docs, accessMode: .read),
    environment: [variable: "injected-desktop-client", "XDG_STATE_HOME": "/tmp/xdg-state"]
  )
  let result = runner.run(arguments: ["config", "validate"])
  #expect(result.exitCode == 0)
  #expect(result.stdout.contains("\"status\""))
  #expect(result.stdout.contains("VALID"))

  // Without the injected variable the same command cannot resolve a profile,
  // proving the success above came from the injected environment.
  let bare = GatewayCommandRunner(
    role: GatewayRole(service: .docs, accessMode: .read),
    environment: [:]
  )
  #expect(bare.run(arguments: ["config", "validate"]).exitCode != 0)
}
