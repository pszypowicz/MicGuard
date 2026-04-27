#!/bin/bash
set -euo pipefail

# Derive version from git tag (v0.5.0 -> 0.5.0), fall back to 0.0.0-dev
VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "0.0.0-dev")

swift build -c release

APP=".build/MicGuard.app/Contents"
rm -rf ".build/MicGuard.app"
mkdir -p "$APP/MacOS" "$APP/Resources" "$APP/Library/LaunchAgents"

cp .build/release/MicGuard "$APP/MacOS/MicGuard"
cp Sources/MicGuard/Info.plist "$APP/Info.plist"

# Stamp version from git tag into Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Info.plist"
cp Resources/MicGuard.icns "$APP/Resources/MicGuard.icns"
cp Resources/com.pszypowicz.MicGuard.agent.plist "$APP/Library/LaunchAgents/"

# Codesign with hardened runtime. Identity defaults to ad-hoc ("-") so local
# `make build` works without a Developer ID; the release workflow exports
# SIGNING_IDENTITY="Developer ID Application: ..." and ENTITLEMENTS to produce
# a notarizable bundle. --timestamp is required for notarization, but only
# valid when signing with a real identity (not ad-hoc).
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
ENTITLEMENTS="${ENTITLEMENTS:-}"
sign_args=(--force --options runtime --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    sign_args+=(--timestamp)
fi
if [[ -n "$ENTITLEMENTS" ]]; then
    sign_args+=(--entitlements "$ENTITLEMENTS")
fi
codesign "${sign_args[@]}" .build/MicGuard.app

# Create bin/mic-guard symlink for CLI usage (included in zip for cask binary stanza)
mkdir -p .build/bin
ln -sf ../MicGuard.app/Contents/MacOS/MicGuard .build/bin/mic-guard

echo "Built .build/MicGuard.app"
