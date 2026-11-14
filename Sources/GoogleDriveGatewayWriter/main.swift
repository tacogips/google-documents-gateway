import Foundation
import AppCore

let result = GatewayCommandRunner(role: GatewayRole(service: .drive, accessMode: .write)).run(arguments: Array(CommandLine.arguments.dropFirst()))
print(result.stdout)
exit(result.exitCode)
