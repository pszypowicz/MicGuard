import Foundation
import PackagePlugin

@main
struct BuildMetadataPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let output = context.pluginWorkDirectoryURL.appending(path: "BuildMetadata.generated.swift")
        // Paths go to the script as arguments, unencoded, so spaces and quotes
        // in the checkout path survive.
        return [
            .prebuildCommand(
                displayName: "Generate build metadata",
                executable: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    """
                    SRC="$1"
                    OUT="$2"
                    HASH=$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo "unknown")
                    DIRTY=$(git -C "$SRC" diff --quiet HEAD 2>/dev/null || echo "+")
                    DATE=$(date "+%Y-%m-%d %H:%M")
                    VERSION=$(head -1 "$SRC/VERSION" 2>/dev/null | tr -d '[:space:]')
                    [ -n "$VERSION" ] || VERSION="dev"
                    cat > "$OUT" <<SWIFT
                    enum BuildMetadata {
                        static let version = "$VERSION"
                        static let gitHash = "${HASH}${DIRTY}"
                        static let buildDate = "$DATE"
                    }
                    SWIFT
                    """,
                    "BuildMetadata",
                    context.package.directoryURL.path(percentEncoded: false),
                    output.path(percentEncoded: false),
                ],
                outputFilesDirectory: context.pluginWorkDirectoryURL
            ),
        ]
    }
}
