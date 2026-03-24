// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MicGuard",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "MicGuardCore"),
        .executableTarget(
            name: "MicGuard",
            dependencies: ["MicGuardCore"],
            exclude: ["Info.plist"],
            plugins: [.plugin(name: "BuildMetadata")]
        ),
        .testTarget(
            name: "MicGuardCoreTests",
            dependencies: ["MicGuardCore"]
        ),
        .plugin(
            name: "BuildMetadata",
            capability: .buildTool()
        ),
    ]
)
