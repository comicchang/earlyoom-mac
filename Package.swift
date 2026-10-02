// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "earlyoom-mac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EarlyoomMac", targets: ["EarlyoomMac"]),
        .executable(name: "earlyoom-mac", targets: ["earlyoom-mac"])
    ],
    targets: [
        .target(name: "EarlyoomMac"),
        .executableTarget(name: "earlyoom-mac", dependencies: ["EarlyoomMac"]),
        .testTarget(name: "EarlyoomMacTests", dependencies: ["EarlyoomMac"])
    ]
)
