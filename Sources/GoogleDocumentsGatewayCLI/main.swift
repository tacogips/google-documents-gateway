import GoogleGatewayAuth
import Foundation
import GoogleDocumentsGatewayCore

FileHandle.standardError.write(Data(
  "Deprecated: use google-docs-gateway-reader instead.\n".utf8
))
let gatewayInvocation = GatewayAuthBootstrap.prepareOrExit(product: .docs, role: "reader")

let result = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .read), environment: gatewayInvocation.environment)
  .run(arguments: gatewayInvocation.arguments)
if !result.stdout.isEmpty { print(result.stdout) }
exit(gatewayInvocation.complete(exitCode: result.exitCode))
