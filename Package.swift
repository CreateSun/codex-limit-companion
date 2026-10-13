// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CodexLimitCompanion",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "CodexLimitCompanion", resources: [.process("Resources")]),
        .testTarget(name: "CodexLimitCompanionTests", dependencies: ["CodexLimitCompanion"])
    ]
)
