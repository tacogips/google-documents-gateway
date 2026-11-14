import GoogleGatewayAuth
import Foundation
import GoogleDocumentsGatewayCore

let gatewayInvocation = GatewayAuthBootstrap.prepareOrExit(product: .docs, role: "writer")

let result = GatewayCommandRunner(role: GatewayRole(service: .docs, accessMode: .write), environment: gatewayInvocation.environment).run(arguments: gatewayInvocation.arguments)
print(result.stdout)
exit(gatewayInvocation.complete(exitCode: result.exitCode))
