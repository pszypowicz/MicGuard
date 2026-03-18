#!/bin/bash
set -euo pipefail

# Derive version from git tag (v0.5.0 -> 0.5.0), fall back to 0.0.0-dev
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0-dev")

swift build -c release

APP=".build/MicGuard.app/Contents"
rm -rf ".build/MicGuard.app"
mkdir -p "$APP/MacOS" "$APP/Resources"

cp .build/release/MicGuard "$APP/MacOS/MicGuard"
cp Sources/MicGuard/Info.plist "$APP/Info.plist"

# Stamp version from git tag into Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Info.plist"
cp Resources/MicGuard.icns "$APP/Resources/MicGuard.icns"

codesign --sign - --force .build/MicGuard.app

# Create bin/mic-guard symlink for CLI usage (included in zip for cask binary stanza)
mkdir -p .build/bin
ln -sf ../MicGuard.app/Contents/MacOS/MicGuard .build/bin/mic-guard

echo "Built .build/MicGuard.app"
