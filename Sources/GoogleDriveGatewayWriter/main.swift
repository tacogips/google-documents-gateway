import GoogleGatewayAuth
import Foundation
import GoogleDocumentsGatewayCore

let gatewayInvocation = GatewayAuthBootstrap.prepareOrExit(product: .drive, role: "writer")

let result = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .write), environment: gatewayInvocation.environment).run(arguments: gatewayInvocation.arguments)
print(result.stdout)
exit(gatewayInvocation.complete(exitCode: result.exitCode))
