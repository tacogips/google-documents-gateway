import Foundation

/// Maps product-specific names onto the historical role-specific inputs.
func gatewayCredentialEnvironment(
  role: GatewayRole, id: String, source: [String: String]
) throws -> [String: String] {
  var result = source
  let product = "GOOGLE_\(role.service.rawValue.uppercased())_GATEWAY_"
  let normalized = id.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
  let canonicalProfile = product + "CREDENTIAL_\(normalized)_"
  let legacyProfile = "GOOGLE_DOCUMENTS_GATEWAY_CREDENTIAL_\(normalized)_"
  let suffixes = [
    ("OAUTH_CLIENT_JSON", "OAUTH_CLIENT_SECRET_JSON"),
    ("OAUTH_CLIENT_PATH", "OAUTH_CLIENT_SECRET_PATH"),
    ("OAUTH_CLIENT_ID", "OAUTH_CLIENT_ID"),
    ("TOKEN_STORE_JSON", "TOKEN_STORE_JSON"),
    ("TOKEN_STORE_PATH", "TOKEN_STORE_PATH"),
    ("ACCESS_TOKEN", "ACCESS_TOKEN")
  ]
  let hasSpecific: [Bool: Bool] = Dictionary(uniqueKeysWithValues: [false, true].map { isApplication in
    let present = suffixes.filter { $0.0.hasPrefix("OAUTH_CLIENT_") == isApplication }.contains { canonical, legacy in
      [canonicalProfile + canonical, legacyProfile + legacy].contains { gatewayCredentialNonBlank(source[$0]) != nil }
    }
    return (isApplication, present)
  })
  for (canonical, legacy) in suffixes {
    let specificKey = canonicalProfile + canonical
    let canonicalKey = hasSpecific[canonical.hasPrefix("OAUTH_CLIENT_")] == true ? specificKey : product + canonical
    let names = Array(Set([canonicalKey, legacyProfile + legacy])).sorted()
    let entries = try names.compactMap { name -> (String, String)? in
      guard let raw = source[name] else { return nil }
      guard raw.utf8.count <= GatewayInputValidator.maximumBodyBytes else { throw GatewayError.inputTooLarge }
      return gatewayCredentialNonBlank(raw).map { (name, $0) }
    }
    guard let first = entries.first else { continue }
    guard entries.allSatisfy({ $0.1 == first.1 }) else {
      throw GatewayError.invalidArgument("Conflicting credential environment variables: \(entries.map { $0.0 }.joined(separator: ", "))")
    }
    result[legacyProfile + legacy] = first.1
  }
  if let token = gatewayCredentialNonBlank(result[legacyProfile + "ACCESS_TOKEN"]) {
    guard token.utf8.count <= 8192, !token.utf8.contains(where: { $0 < 33 || $0 == 127 }) else {
      throw GatewayError.invalidArgument("ACCESS_TOKEN must contain a valid token string")
    }
    guard gatewayCredentialNonBlank(result[legacyProfile + "TOKEN_STORE_JSON"]) == nil,
          gatewayCredentialNonBlank(result[legacyProfile + "TOKEN_STORE_PATH"]) == nil else {
      throw GatewayError.invalidArgument("ACCESS_TOKEN cannot be combined with token-store inputs for the same credential")
    }
    let store = GatewayTokenStore(role: role, accessToken: token, refreshToken: nil, expiresAt: nil)
    guard let json = String(data: try JSONEncoder().encode(store), encoding: .utf8) else {
      throw GatewayError.invalidArgument("Unable to encode external token")
    }
    result[legacyProfile + "TOKEN_STORE_JSON"] = json
  }
  return result
}

private func gatewayCredentialNonBlank(_ value: String?) -> String? {
  guard let value else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}
