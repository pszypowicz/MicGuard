#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Update Resources/Localizable.xcstrings from the strings the app's code
marks as localizable. New strings are added, strings the code no longer
uses are marked stale or removed, and translations are kept.

The strings come from the Swift compiler (-emit-localized-strings), so
this builds the package in a temporary directory. It needs Xcode, which
ships xcstringstool.

Usage: scripts/sync-strings.sh [--check]

Flags:
  --check     Don't write anything. Exit 1 and show the difference if the
              catalog is out of date with the code.
  -h, --help  Show this help.

Examples:
  scripts/sync-strings.sh           # after adding or changing UI text
  scripts/sync-strings.sh --check   # what CI runs
EOF
}

check=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) check=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Rewrites a catalog in the layout xcstringstool and Xcode write: sorted
# keys, " : " separators, empty objects as "{" blank line "}", and no
# newline at the end. xcstringstool leaves a file alone when its content
# doesn't change, so without this a hand edit keeps its own layout until
# the next real change rewrites the whole file.
canonicalize() {
  python3 - "$1" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)


def dump(value, depth=0):
    pad = "  " * depth
    if isinstance(value, dict):
        if not value:
            return "{\n\n" + pad + "}"
        items = [
            f"{pad}  {json.dumps(key, ensure_ascii=False)} : {dump(item, depth + 1)}"
            for key, item in sorted(value.items())
        ]
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    return json.dumps(value, ensure_ascii=False)


with open(path, "w", encoding="utf-8") as f:
    f.write(dump(data))
PY
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

catalog="Resources/Localizable.xcstrings"

if ! xcrun --find xcstringstool >/dev/null 2>&1; then
  echo "error: xcstringstool not found - it ships with Xcode" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

swift build --product MicGuard --scratch-path "$work/build" \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$work/strings" >/dev/null

stringsdata=()
while IFS= read -r file; do
  stringsdata+=("$file")
done < <(find "$work/strings" -name '*.stringsdata')

if [[ ${#stringsdata[@]} -eq 0 ]]; then
  echo "error: the build produced no .stringsdata files" >&2
  exit 1
fi

if $check; then
  if [[ ! -f "$catalog" ]]; then
    echo "error: $catalog is missing. Run scripts/sync-strings.sh to create it." >&2
    exit 1
  fi
  cp "$catalog" "$work/Localizable.xcstrings"
  xcrun xcstringstool sync "$work/Localizable.xcstrings" --stringsdata "${stringsdata[@]}"
  canonicalize "$work/Localizable.xcstrings"
  if ! diff -u "$catalog" "$work/Localizable.xcstrings"; then
    echo "error: $catalog is out of date. Run scripts/sync-strings.sh and commit the result." >&2
    exit 1
  fi
  echo "$catalog is up to date"
else
  if [[ ! -f "$catalog" ]]; then
    mkdir -p "$(dirname "$catalog")"
    printf '{\n  "sourceLanguage" : "en",\n  "strings" : {},\n  "version" : "1.0"\n}\n' > "$catalog"
  fi
  xcrun xcstringstool sync "$catalog" --stringsdata "${stringsdata[@]}"
  canonicalize "$catalog"
  echo "Updated $catalog"
fi
