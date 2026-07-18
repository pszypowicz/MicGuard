#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Package a signed, notarized, stapled MicGuard.dmg: the classic installer
window with the app on the left and an Applications-folder link on the
right, over Resources/dmg-background.tiff (icon coordinates here and in
generate-dmg-background.swift must agree).

Usage: scripts/package-dmg.sh [--app <path>] [--output <path>] [--keychain-profile <name>]

Flags:
  --app               App bundle to package (default: .build/MicGuard.app).
                      Must already be Developer ID signed (and stapled, so
                      the app inside the DMG carries its own ticket).
  --output            Path of the .dmg to write (default: .build/MicGuard.dmg)
  --keychain-profile  notarytool keychain profile (default: micguard-notary)
  -h, --help          Show this help.

Requires create-dmg (brew install create-dmg); a missing dependency or
signing identity is a hard error, never a downgrade.
EOF
}

app=".build/MicGuard.app"
dmg=".build/MicGuard.dmg"
profile=micguard-notary

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) app="$2"; shift 2 ;;
    --output) dmg="$2"; shift 2 ;;
    --keychain-profile) profile="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

command -v create-dmg >/dev/null || {
  echo "error: create-dmg not found (brew install create-dmg)" >&2
  exit 1
}
[[ -d "$app" ]] || { echo "error: no app bundle at $app" >&2; exit 1; }

signature="$(codesign -dvv "$app" 2>&1)"
if [[ "$signature" != *"Authority=Developer ID Application"* ]]; then
  echo "error: $app is not signed with a Developer ID Application identity" >&2
  exit 1
fi

identity="Developer ID Application"
sign="$(security find-identity -v -p codesigning | awk -v id="$identity" '$0 ~ id {print $2; exit}' || true)"
if [[ -z "$sign" ]]; then
  echo "error: no codesigning identity matching '$identity'" >&2
  exit 1
fi

# create-dmg images the whole source folder, so the app is staged alone.
staging="$(mktemp -d /tmp/micguard-dmg.XXXXXX)"
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"

rm -f "$dmg"
create-dmg \
  --volname "MicGuard" \
  --volicon Resources/MicGuard.icns \
  --background Resources/dmg-background.tiff \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "MicGuard.app" 165 185 \
  --hide-extension "MicGuard.app" \
  --app-drop-link 495 185 \
  --no-internet-enable \
  "$dmg" "$staging"

codesign --force --timestamp --sign "$sign" "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"

# Assessment type "open" with the primary-signature context is Gatekeeper's
# verdict for mounting a downloaded disk image.
spctl -a -t open --context context:primary-signature -vv "$dmg"
echo "DMG asset: $dmg"
shasum -a 256 "$dmg"
