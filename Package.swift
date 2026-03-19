// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MicGuard",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MicGuard",
            exclude: ["Info.plist"],
            plugins: [.plugin(name: "BuildMetadata")]
        ),
        .plugin(
            name: "BuildMetadata",
            capability: .buildTool()
        ),
    ]
)
