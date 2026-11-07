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
    --identity)
      [[ $# -ge 2 ]] || { echo "error: --identity needs a value" >&2; usage >&2; exit 1; }
      identity="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Version comes from the VERSION file - the single source of truth, also
# read by the BuildMetadata plugin so the app reports the same string.
VERSION=$(head -1 VERSION 2>/dev/null | tr -d '[:space:]')
[ -n "$VERSION" ] || { echo "error: VERSION file missing or empty" >&2; exit 1; }

swift build -c release

APP=".build/MicGuard.app/Contents"
rm -rf ".build/MicGuard.app"
mkdir -p "$APP/MacOS" "$APP/Resources"

cp .build/release/MicGuard "$APP/MacOS/MicGuard"
cp Sources/MicGuard/Info.plist "$APP/Info.plist"

# Stamp the version from VERSION into Info.plist. CFBundleShortVersionString
# takes period-separated integers, so a prerelease suffix (0.20.0-rc.1) is
# left out there. The About window shows the full string from BuildMetadata.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION%%-*}" "$APP/Info.plist"
cp Resources/MicGuard.icns "$APP/Resources/MicGuard.icns"

# Translations: compile the string catalog into <language>.lproj folders.
# xcstringstool ships with Xcode, not the Command Line Tools, and without it
# the app runs in English only.
if xcrun --find xcstringstool >/dev/null 2>&1; then
  xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$APP/Resources"
else
  echo "warning: xcstringstool not found (it ships with Xcode), building without translations" >&2
fi
# English text is the key itself, so the catalog compiles no en.lproj. An
# empty one still marks English as available, so a user who prefers English
# over another supported language gets English.
mkdir -p "$APP/Resources/en.lproj"
/usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations array" "$APP/Info.plist"
for lproj in "$APP"/Resources/*.lproj; do
  /usr/libexec/PlistBuddy -c "Add :CFBundleLocalizations: string $(basename "$lproj" .lproj)" "$APP/Info.plist"
done

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
