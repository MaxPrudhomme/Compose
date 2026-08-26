// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "container-compose",
  platforms: [
    .macOS(.v26)
  ],
  products: [
    .library(name: "ComposeCore", targets: ["ComposeCore"]),
    .library(name: "AppleContainerDriver", targets: ["AppleContainerDriver"]),
    .library(name: "ComposeCommands", targets: ["ComposeCommands"]),
    .executable(name: "compose", targets: ["compose"]),
    .executable(name: "container-compose", targets: ["container-compose"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
  ],
  targets: [
    .target(
      name: "ComposeCore",
      dependencies: ["Yams"],
      resources: [.copy("Resources/compose-compatibility.json")]
    ),
    .target(
      name: "AppleContainerDriver",
      dependencies: ["ComposeCore"]
    ),
    .target(
      name: "ComposeCommands",
      dependencies: [
        "ComposeCore",
        "AppleContainerDriver",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "compose",
      dependencies: ["ComposeCommands"]
    ),
    .executableTarget(
      name: "container-compose",
      dependencies: ["ComposeCommands"]
    ),
    .testTarget(
      name: "ComposeCoreTests",
      dependencies: ["ComposeCore"]
    ),
    .testTarget(
      name: "AppleContainerDriverTests",
      dependencies: ["AppleContainerDriver"]
    ),
    .testTarget(
      name: "ComposeCommandTests",
      dependencies: ["ComposeCommands", "ComposeCore", "AppleContainerDriver"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
