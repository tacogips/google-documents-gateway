// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "document-gateway",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AppCore", targets: ["AppCore"]),
    .executable(name: "document-gateway", targets: ["AppCLI"]),
    .executable(name: "google-docs-gateway-reader", targets: ["GoogleDocsGatewayReader"]),
    .executable(name: "google-docs-gateway-writer", targets: ["GoogleDocsGatewayWriter"]),
    .executable(name: "google-sheet-gateway-reader", targets: ["GoogleSheetGatewayReader"]),
    .executable(name: "google-sheet-gateway-writer", targets: ["GoogleSheetGatewayWriter"]),
    .executable(name: "google-drive-gateway-reader", targets: ["GoogleDriveGatewayReader"]),
    .executable(name: "google-drive-gateway-writer", targets: ["GoogleDriveGatewayWriter"])
  ],
  targets: [
    .target(name: "AppCore"),
    .executableTarget(
      name: "AppCLI",
      dependencies: ["AppCore"]
    ),
    .executableTarget(name: "GoogleDocsGatewayReader", dependencies: ["AppCore"]),
    .executableTarget(name: "GoogleDocsGatewayWriter", dependencies: ["AppCore"]),
    .executableTarget(name: "GoogleSheetGatewayReader", dependencies: ["AppCore"]),
    .executableTarget(name: "GoogleSheetGatewayWriter", dependencies: ["AppCore"]),
    .executableTarget(name: "GoogleDriveGatewayReader", dependencies: ["AppCore"]),
    .executableTarget(name: "GoogleDriveGatewayWriter", dependencies: ["AppCore"]),
    .testTarget(
      name: "AppCoreTests",
      dependencies: ["AppCore"]
    )
  ],
  swiftLanguageModes: [.v6]
)
