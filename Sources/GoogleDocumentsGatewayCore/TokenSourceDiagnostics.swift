import Foundation

extension GatewayCredentialProfile {
  var tokenSourceDetails: [String: String] {
    let suffix = id.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    let jsonVariable = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(suffix)_TOKEN_STORE_JSON"
    let pathVariable = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(suffix)_TOKEN_STORE_PATH"
    var details = ["credentialId": id]
    if tokenStoreJSON != nil {
      details["tokenSource"] = "ENVIRONMENT_JSON"
      details["tokenEnvironmentVariable"] = jsonVariable
      details["tokenSourceHint"] = "Unset \(jsonVariable) before login; inline JSON overrides token files."
      if tokenStorePathFromEnvironment { details["tokenPathEnvironmentVariable"] = pathVariable }
    } else {
      details["tokenSource"] = tokenStorePathFromEnvironment ? "ENVIRONMENT_PATH" : "FILE"
      details["tokenStorePath"] = tokenStoreURL.path
      details["tokenSourceHint"] = "Keep \(jsonVariable) unset and select this path with \(pathVariable) in subsequent commands."
      if tokenStorePathFromEnvironment { details["tokenEnvironmentVariable"] = pathVariable }
    }
    return details
  }

  func tokenSourceMessage(_ message: String) -> String {
    let details = tokenSourceDetails
    let summary = details.keys.sorted().compactMap { key in details[key].map { "\(key)=\($0)" } }.joined(separator: "; ")
    return "\(message) (\(summary))"
  }
}
