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

# Create bin/mic-guard symlink for CLI usage (included in zip for cask binary stanza)
mkdir -p .build/bin
ln -sf ../MicGuard.app/Contents/MacOS/MicGuard .build/bin/mic-guard

echo "Built .build/MicGuard.app"
