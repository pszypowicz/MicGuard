#!/usr/bin/env bash
#
# release-notarize.sh - submit MicGuard.zip to Apple notarization, staple the
# resulting ticket onto the .app, and re-zip so the published archive ships
# with offline-verifiable notarization.
#
# Inputs (named flags - positional args are not accepted):
#   --app PATH          path to the signed .app bundle (default: .build/MicGuard.app)
#   --zip PATH          path to the zip uploaded for notarization (default: .build/MicGuard.zip)
#   --apple-id EMAIL    Apple ID used for notarization
#   --team-id TEAM      10-char Apple Developer team identifier
#   --password PWD      app-specific password (NOT the Apple ID account password)
#   -h, --help          show usage and exit
#
# Exit codes:
#   0  notarized + stapled, zip refreshed
#   1  notarization rejected by Apple, or stapler failed
#   2  bad usage (missing flag, unknown flag)
#
# notarytool's --wait flag polls until Apple returns a terminal status, so
# this script does not implement its own polling loop. Submission log is
# fetched on rejection so the failure reason ends up in CI output.

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: release-notarize.sh --apple-id EMAIL --team-id TEAM --password PWD \
                           [--app PATH] [--zip PATH]

Submit a signed .app/.zip to Apple notarization, staple the ticket, and
refresh the zip so the published archive carries the notarization offline.

Required flags:
  --apple-id EMAIL    Apple ID used for notarization
  --team-id TEAM      10-char Apple Developer team identifier
  --password PWD      app-specific password (appleid.apple.com)

Optional flags:
  --app PATH          path to the .app bundle (default: .build/MicGuard.app)
  --zip PATH          path to the zip to submit (default: .build/MicGuard.zip)
  -h, --help          show this help and exit

Example:
  release-notarize.sh --apple-id me@example.com --team-id ABCDE12345 \
      --password "$APPLE_APP_SPECIFIC_PASSWORD"
USAGE
}

APP=".build/MicGuard.app"
ZIP=".build/MicGuard.zip"
APPLE_ID=""
TEAM_ID=""
PASSWORD=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)       APP="$2"; shift 2 ;;
        --zip)       ZIP="$2"; shift 2 ;;
        --apple-id)  APPLE_ID="$2"; shift 2 ;;
        --team-id)   TEAM_ID="$2"; shift 2 ;;
        --password)  PASSWORD="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
done

missing=()
[[ -z "$APPLE_ID" ]] && missing+=(--apple-id)
[[ -z "$TEAM_ID"  ]] && missing+=(--team-id)
[[ -z "$PASSWORD" ]] && missing+=(--password)
if (( ${#missing[@]} > 0 )); then
    echo "error: missing required flag(s): ${missing[*]}" >&2
    usage >&2
    exit 2
fi

[[ -e "$APP" ]] || { echo "error: app bundle not found: $APP" >&2; exit 2; }
[[ -f "$ZIP" ]] || { echo "error: zip not found: $ZIP" >&2; exit 2; }

echo "==> submitting $ZIP to notarization (waiting for Apple)"
submit_log=$(mktemp)
trap 'rm -f "$submit_log"' EXIT

if ! xcrun notarytool submit "$ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$TEAM_ID" \
        --password "$PASSWORD" \
        --wait \
        --output-format plist \
        > "$submit_log"; then
    echo "error: notarytool submit failed" >&2
    cat "$submit_log" >&2
    exit 1
fi

# Parse the submission ID + status from the plist output. PlistBuddy on macOS
# is the standard tool for this; fall back to grep if PlistBuddy is missing
# (notarytool always runs on macOS so PlistBuddy should be present).
status=$(/usr/libexec/PlistBuddy -c "Print :status" "$submit_log" 2>/dev/null || echo "")
submission_id=$(/usr/libexec/PlistBuddy -c "Print :id" "$submit_log" 2>/dev/null || echo "")

echo "==> notarytool status: ${status:-unknown} (submission ${submission_id:-unknown})"

if [[ "$status" != "Accepted" ]]; then
    echo "error: notarization not accepted" >&2
    if [[ -n "$submission_id" ]]; then
        echo "==> fetching submission log:" >&2
        xcrun notarytool log "$submission_id" \
            --apple-id "$APPLE_ID" \
            --team-id "$TEAM_ID" \
            --password "$PASSWORD" >&2 || true
    fi
    exit 1
fi

echo "==> stapling ticket onto $APP"
xcrun stapler staple "$APP"

echo "==> validating staple"
xcrun stapler validate "$APP"

echo "==> refreshing $ZIP with stapled bundle"
zip_dir=$(dirname "$ZIP")
zip_name=$(basename "$ZIP")
app_name=$(basename "$APP")
# Match the layout produced by `make zip` so the homebrew cask's `binary`
# stanza pointing at `bin/mic-guard` keeps working after notarization.
(
    cd "$zip_dir"
    rm -f "$zip_name"
    zip -ry "$zip_name" "$app_name" bin/mic-guard
)

echo "==> done: $ZIP is signed, notarized, stapled"
