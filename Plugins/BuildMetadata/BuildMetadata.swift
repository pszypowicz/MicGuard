import Foundation
import PackagePlugin

@main
struct BuildMetadataPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let output = context.pluginWorkDirectoryURL.appending(path: "BuildMetadata.generated.swift")
        let srcDir = context.package.directoryURL.path()
        return [
            .prebuildCommand(
                displayName: "Generate build metadata",
                executable: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    """
                    HASH=$(git -C '\(srcDir)' rev-parse --short HEAD 2>/dev/null || echo "unknown")
                    DIRTY=$(git -C '\(srcDir)' diff --quiet HEAD 2>/dev/null || echo "+")
                    DATE=$(date "+%Y-%m-%d %H:%M")
                    VERSION=$(head -1 '\(srcDir)/VERSION' 2>/dev/null | tr -d '[:space:]')
                    [ -n "$VERSION" ] || VERSION="dev"
                    cat > '\(output.path())' <<SWIFT
                    enum BuildMetadata {
                        static let version = "$VERSION"
                        static let gitHash = "${HASH}${DIRTY}"
                        static let buildDate = "$DATE"
                    }
                    SWIFT
                    """,
                ],
                outputFilesDirectory: context.pluginWorkDirectoryURL
            ),
        ]
    }
}
