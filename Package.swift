// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "sim",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentCore", targets: ["AgentCore"]),
        .executable(name: "sim", targets: ["sim"]),
    ],
    targets: [
        .target(name: "ProcessSupport"),
        .target(name: "AgentCore", dependencies: ["ProcessSupport"]),
        .executableTarget(name: "sim", dependencies: ["AgentCore"]),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
        .testTarget(name: "simTests", dependencies: ["sim"]),
    ]
)
