#!/usr/bin/env bash
#
# release-notarize.sh - submit MicGuard.zip to Apple notarization, staple the
# resulting ticket onto the .app, and re-zip so the published archive ships
# with offline-verifiable notarization.
#
# Two authentication modes (pick one):
#
#   1. App Store Connect API key (recommended for CI):
#        --key PATH --key-id ID --issuer UUID
#
#   2. Keychain profile (recommended for local: run
#      `xcrun notarytool store-credentials NAME ...` once, then reference NAME):
#        --keychain-profile NAME
#
# notarytool's --wait flag polls until Apple returns a terminal status, so
# this script does not implement its own polling loop. The submission log is
# fetched on rejection so the failure reason ends up in CI output.
#
# Exit codes:
#   0  notarized + stapled, zip refreshed
#   1  notarization rejected by Apple, or stapler failed
#   2  bad usage (missing/conflicting flags, file not found)

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage:
  release-notarize.sh --key PATH --key-id ID --issuer UUID [--app PATH] [--zip PATH]
  release-notarize.sh --keychain-profile NAME            [--app PATH] [--zip PATH]

Submit a signed .app/.zip to Apple notarization, staple the ticket, and
refresh the zip so the published archive carries the notarization offline.

Authentication (choose exactly one):
  --key PATH                path to App Store Connect API key (.p8)
  --key-id ID               10-char Key ID from App Store Connect
  --issuer UUID             issuer UUID from App Store Connect
  --keychain-profile NAME   profile name set up via `notarytool store-credentials`

Optional:
  --app PATH                path to the .app bundle (default: .build/MicGuard.app)
  --zip PATH                path to the zip to submit (default: .build/MicGuard.zip)
  -h, --help                show this help and exit

Examples:
  # CI / explicit credentials
  release-notarize.sh --key ./AuthKey_ABCDEF1234.p8 \
      --key-id ABCDEF1234 --issuer 12345678-1234-1234-1234-123456789012

  # Local, after running `xcrun notarytool store-credentials MicGuard ...`
  release-notarize.sh --keychain-profile MicGuard
USAGE
}

APP=".build/MicGuard.app"
ZIP=".build/MicGuard.zip"
KEY=""
KEY_ID=""
ISSUER=""
KEYCHAIN_PROFILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)               APP="$2"; shift 2 ;;
        --zip)               ZIP="$2"; shift 2 ;;
        --key)               KEY="$2"; shift 2 ;;
        --key-id)            KEY_ID="$2"; shift 2 ;;
        --issuer)            ISSUER="$2"; shift 2 ;;
        --keychain-profile)  KEYCHAIN_PROFILE="$2"; shift 2 ;;
        -h|--help)           usage; exit 0 ;;
        *)                   echo "error: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Pick auth mode: keychain profile XOR (key + key-id + issuer).
api_key_mode_count=0
[[ -n "$KEY"     ]] && api_key_mode_count=$((api_key_mode_count + 1))
[[ -n "$KEY_ID"  ]] && api_key_mode_count=$((api_key_mode_count + 1))
[[ -n "$ISSUER"  ]] && api_key_mode_count=$((api_key_mode_count + 1))

if [[ -n "$KEYCHAIN_PROFILE" ]]; then
    if (( api_key_mode_count > 0 )); then
        echo "error: --keychain-profile cannot be combined with --key/--key-id/--issuer" >&2
        usage >&2
        exit 2
    fi
    auth_args=(--keychain-profile "$KEYCHAIN_PROFILE")
elif (( api_key_mode_count == 3 )); then
    [[ -f "$KEY" ]] || { echo "error: API key not found: $KEY" >&2; exit 2; }
    auth_args=(--key "$KEY" --key-id "$KEY_ID" --issuer "$ISSUER")
elif (( api_key_mode_count == 0 )); then
    echo "error: missing authentication; pass --keychain-profile NAME or all of --key/--key-id/--issuer" >&2
    usage >&2
    exit 2
else
    echo "error: --key, --key-id, and --issuer must be passed together" >&2
    usage >&2
    exit 2
fi

[[ -e "$APP" ]] || { echo "error: app bundle not found: $APP" >&2; exit 2; }
[[ -f "$ZIP" ]] || { echo "error: zip not found: $ZIP" >&2; exit 2; }

echo "==> submitting $ZIP to notarization (waiting for Apple)"
submit_log=$(mktemp)
trap 'rm -f "$submit_log"' EXIT

if ! xcrun notarytool submit "$ZIP" \
        "${auth_args[@]}" \
        --wait \
        --output-format plist \
        > "$submit_log"; then
    echo "error: notarytool submit failed" >&2
    cat "$submit_log" >&2
    exit 1
fi

status=$(/usr/libexec/PlistBuddy -c "Print :status" "$submit_log" 2>/dev/null || echo "")
submission_id=$(/usr/libexec/PlistBuddy -c "Print :id" "$submit_log" 2>/dev/null || echo "")

echo "==> notarytool status: ${status:-unknown} (submission ${submission_id:-unknown})"

if [[ "$status" != "Accepted" ]]; then
    echo "error: notarization not accepted" >&2
    if [[ -n "$submission_id" ]]; then
        echo "==> fetching submission log:" >&2
        xcrun notarytool log "$submission_id" "${auth_args[@]}" >&2 || true
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
