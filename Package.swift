// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "S3ServerSwift",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "S3ServerSwift",
            targets: ["S3ServerSwift"]
        ),
        .executable(
            name: "Server",
            targets: ["Server"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "S3ServerSwift",
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .executableTarget(
            name: "Server",
            dependencies: ["S3ServerSwift"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
        .testTarget(
            name: "S3ServerSwiftTests",
            dependencies: ["S3ServerSwift"],
            swiftSettings: [
                .enableUpcomingFeature("ApproachableConcurrency"),
            ],
        ),
    ]
)
