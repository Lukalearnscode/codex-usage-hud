// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexUsageHUD",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexUsageHUD", targets: ["CodexUsageHUD"]),
        .executable(name: "CodexUsageHUDCoreTests", targets: ["CodexUsageHUDCoreTests"])
    ],
    targets: [
        .target(name: "CodexUsageHUDCore"),
        .executableTarget(name: "CodexUsageHUD", dependencies: ["CodexUsageHUDCore"]),
        .executableTarget(name: "CodexUsageHUDCoreTests", dependencies: ["CodexUsageHUDCore"]),
        .testTarget(name: "CodexUsageHUDSwiftPMTests", dependencies: ["CodexUsageHUDCore"], path: "Tests/CodexUsageHUDCoreTests")
    ]
)
