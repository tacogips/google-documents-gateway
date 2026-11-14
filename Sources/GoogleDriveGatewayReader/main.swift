import GoogleGatewayAuth
import Foundation
import GoogleDocumentsGatewayCore

let gatewayInvocation = GatewayAuthBootstrap.prepareOrExit(product: .drive, role: "reader")

let result = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .read), environment: gatewayInvocation.environment).run(arguments: gatewayInvocation.arguments)
print(result.stdout)
exit(gatewayInvocation.complete(exitCode: result.exitCode))
