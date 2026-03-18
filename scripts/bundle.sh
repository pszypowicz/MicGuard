#!/bin/bash
set -euo pipefail

swift build -c release

APP=".build/MicGuard.app/Contents"
rm -rf ".build/MicGuard.app"
mkdir -p "$APP/MacOS" "$APP/Resources"

cp .build/release/MicGuard "$APP/MacOS/MicGuard"
cp Sources/MicGuard/Info.plist "$APP/Info.plist"
cp Resources/MicGuard.icns "$APP/Resources/MicGuard.icns"

codesign --sign - --force .build/MicGuard.app

# Create mic-guard symlink for CLI usage
ln -sf MicGuard.app/Contents/MacOS/MicGuard .build/mic-guard

echo "Built .build/MicGuard.app"
