// swift-tools-version: 6.2
// S3ServerSwift, the Swift port of the s3 package's Bun server (github.com/v57/s3): a library that apps embed (the Hub
// app's Storage) and the `Server` executable with the Bun CLI's flags. No package dependencies.

import PackageDescription

let settings: [SwiftSetting] = [.enableUpcomingFeature("ApproachableConcurrency")]

let package = Package(
  name: "S3ServerSwift",
  platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .visionOS(.v1)],
  products: [
    .library(name: "S3ServerSwift", targets: ["S3ServerSwift"]),
    .executable(name: "Server", targets: ["Server"]),
  ],
  dependencies: [],
  targets: [
    .target(name: "S3ServerSwift", swiftSettings: settings),
    .executableTarget(name: "Server", dependencies: ["S3ServerSwift"], swiftSettings: settings),
    .testTarget(name: "S3ServerSwiftTests", dependencies: ["S3ServerSwift"], swiftSettings: settings),
  ]
)
