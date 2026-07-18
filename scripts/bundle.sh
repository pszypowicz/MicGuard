#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build MicGuard.app from the Swift package into .build/MicGuard.app.

Usage: scripts/bundle.sh [--identity <substring|adhoc>]

Flags:
  --identity   Codesign identity, matched as a substring against
               'security find-identity' output (default: "Developer ID
               Application", the release identity). No fallback: a missing
               match is a hard error, never a silently different signature.
               Pass "adhoc" for an unsigned local build.
  -h, --help   Show this help.
EOF
}

identity="Developer ID Application"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity) identity="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

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

if [[ "$identity" == "adhoc" ]]; then
  codesign --sign - --force --options runtime .build/MicGuard.app
else
  # || true: with set -e, a failing security query (locked/absent
  # keychain) would abort before the explicit error below.
  sign=$(security find-identity -v -p codesigning | awk -v id="$identity" '$0 ~ id {print $2; exit}' || true)
  if [[ -z "$sign" ]]; then
    echo "error: no codesigning identity matching '$identity'" >&2
    echo "List identities with: security find-identity -v -p codesigning" >&2
    echo "Pick one with --identity <substring>, or --identity adhoc for an unsigned dev build." >&2
    exit 1
  fi
  # --timestamp: notarization requires a secure timestamp.
  codesign --sign "$sign" --force --options runtime --timestamp .build/MicGuard.app
fi

echo "Built .build/MicGuard.app"
