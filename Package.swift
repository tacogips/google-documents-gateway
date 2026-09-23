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
    .package(url: "https://github.com/tacogips/gateway-sdk-kit.git", exact: "0.1.0")
  ],
  targets: [
    .target(
      name: "GoogleDocumentsGatewayCore",
      dependencies: [.product(name: "GatewaySDKKit", package: "gateway-sdk-kit")]
    ),
    .executableTarget(
      name: "GoogleDocumentsGatewayCLI",
      dependencies: ["GoogleDocumentsGatewayCore"]
    ),
    .executableTarget(name: "GoogleDocsGatewayReader", dependencies: ["GoogleDocumentsGatewayCore"]),
    .executableTarget(name: "GoogleDocsGatewayWriter", dependencies: ["GoogleDocumentsGatewayCore"]),
    .executableTarget(name: "GoogleSheetGatewayReader", dependencies: ["GoogleDocumentsGatewayCore"]),
    .executableTarget(name: "GoogleSheetGatewayWriter", dependencies: ["GoogleDocumentsGatewayCore"]),
    .executableTarget(name: "GoogleDriveGatewayReader", dependencies: ["GoogleDocumentsGatewayCore"]),
    .executableTarget(name: "GoogleDriveGatewayWriter", dependencies: ["GoogleDocumentsGatewayCore"]),
    .testTarget(
      name: "GoogleDocumentsGatewayCoreTests",
      dependencies: ["GoogleDocumentsGatewayCore", .product(name: "GatewaySDKKit", package: "gateway-sdk-kit")]
    )
  ],
  swiftLanguageModes: [.v6]
)
