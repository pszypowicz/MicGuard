#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build a release MicGuard.app signed with Developer ID, notarize it,
staple the ticket, and produce the release assets: MicGuard.zip (for
the Homebrew cask) and MicGuard.dmg (drag-to-Applications installer),
both rebuilt after stapling so they carry the ticket.

Usage: scripts/notarize-release.sh [--keychain-profile <name>]

Flags:
  --keychain-profile  notarytool keychain profile with the notarization
                      credentials (default: micguard-notary). Create once
                      with:
                        xcrun notarytool store-credentials micguard-notary \
                          --key <AuthKey.p8> --key-id <id> --issuer <uuid>
  -h, --help          Show this help.
EOF
}

profile=micguard-notary

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keychain-profile) profile="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

scripts/bundle.sh --identity "Developer ID Application"

app=".build/MicGuard.app"
zip=".build/MicGuard.zip"

# bundle.sh hard-errors on a missing identity; this guards the outcome
# anyway - a release must never ship with a different signature.
signature="$(codesign -dvv "$app" 2>&1)"
if [[ "$signature" != *"Authority=Developer ID Application"* ]]; then
  echo "error: $app is not signed with a Developer ID Application identity" >&2
  exit 1
fi

rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
# Stapling fails unless the submission was actually accepted, so a
# rejected notarization stops the script here.
xcrun stapler staple "$app"
rm "$zip"
ditto -c -k --keepParent "$app" "$zip"

spctl -a -vv "$app"
echo "Release asset: $zip"
shasum -a 256 "$zip"

# The DMG is packaged from the stapled app and notarized in its own right.
scripts/package-dmg.sh --keychain-profile "$profile"
