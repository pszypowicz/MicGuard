// swift-tools-version: 6.4
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    // The app runs on the main thread: CoreAudio listeners are registered on
    // the main queue and the UI is AppKit and SwiftUI. Code that must run
    // elsewhere is marked nonisolated.
    .defaultIsolation(MainActor.self),
    // Every use of an unsafe construct needs an `unsafe` marker.
    .strictMemorySafety(),
    // Upcoming features that the Swift 7 language mode enables by default.
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "MicGuard",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "MicGuardCore", swiftSettings: swiftSettings),
        .executableTarget(
            name: "MicGuard",
            dependencies: ["MicGuardCore"],
            exclude: ["Info.plist"],
            swiftSettings: swiftSettings,
            plugins: [.plugin(name: "BuildMetadata")]
        ),
        .testTarget(
            name: "MicGuardCoreTests",
            dependencies: ["MicGuardCore"],
            swiftSettings: swiftSettings
        ),
        .plugin(
            name: "BuildMetadata",
            capability: .buildTool()
        ),
    ]
)
