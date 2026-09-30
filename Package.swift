// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "google-documents-gateway",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "GoogleDocumentsGatewayCore", targets: ["GoogleDocumentsGatewayCore"]),
    .executable(name: "google-documents-gateway", targets: ["GoogleDocumentsGatewayCLI"]),
    .executable(name: "google-docs-gateway-reader", targets: ["GoogleDocsGatewayReader"]),
    .executable(name: "google-docs-gateway-writer", targets: ["GoogleDocsGatewayWriter"]),
    .executable(name: "google-sheet-gateway-reader", targets: ["GoogleSheetGatewayReader"]),
    .executable(name: "google-sheet-gateway-writer", targets: ["GoogleSheetGatewayWriter"]),
    .executable(name: "google-drive-gateway-reader", targets: ["GoogleDriveGatewayReader"]),
    .executable(name: "google-drive-gateway-writer", targets: ["GoogleDriveGatewayWriter"])
  ],
  dependencies: [
    .package(url: "https://github.com/tacogips/google-gateway-auth.git", revision: "13c40e24b11da9bab17046a918630fbb6aa6c147"),
    .package(url: "https://github.com/tacogips/gateway-sdk-kit.git", exact: "0.1.0")
  ],
  targets: [
    .target(
      name: "GoogleDocumentsGatewayCore",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), .product(name: "GatewaySDKKit", package: "gateway-sdk-kit")]
    ),
    .executableTarget(
      name: "GoogleDocumentsGatewayCLI",
      dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleDocumentsGatewayCore"]
    ),
    .executableTarget(name: "GoogleDocsGatewayReader", dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleDocumentsGatewayCore"]),
    .executableTarget(name: "GoogleDocsGatewayWriter", dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleDocumentsGatewayCore"]),
    .executableTarget(name: "GoogleSheetGatewayReader", dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleDocumentsGatewayCore"]),
    .executableTarget(name: "GoogleSheetGatewayWriter", dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleDocumentsGatewayCore"]),
    .executableTarget(name: "GoogleDriveGatewayReader", dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleDocumentsGatewayCore"]),
    .executableTarget(name: "GoogleDriveGatewayWriter", dependencies: [.product(name: "GoogleGatewayAuth", package: "google-gateway-auth"), "GoogleDocumentsGatewayCore"]),
    .testTarget(
      name: "GoogleDocumentsGatewayCoreTests",
      dependencies: ["GoogleDocumentsGatewayCore", .product(name: "GatewaySDKKit", package: "gateway-sdk-kit")]
    )
  ],
  swiftLanguageModes: [.v6]
)
