// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Quota",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(name: "Quota", dependencies: ["QuotaCore"]),
        .executableTarget(name: "QuotaServer", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaServerTests", dependencies: ["QuotaServer"]),
    ],
    swiftLanguageModes: [.v5]
)
