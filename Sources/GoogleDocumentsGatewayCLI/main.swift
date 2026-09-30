import Foundation
import GoogleDocumentsGatewayCore

FileHandle.standardError.write(Data(
  "Deprecated: use google-docs-gateway-reader instead.\n".utf8
))
let result = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .read))
  .run(arguments: Array(CommandLine.arguments.dropFirst()))
if !result.stdout.isEmpty { print(result.stdout) }
exit(result.exitCode)
