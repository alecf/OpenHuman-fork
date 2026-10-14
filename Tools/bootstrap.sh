#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Tools/versions.env"

usage() {
    cat <<'EOF'
Usage: Tools/bootstrap.sh [--no-generate]

Checks the Xcode and Swift versions, downloads the pinned XcodeGen release
(version and SHA-256 in Tools/versions.env) into Tools/.bin/, verifies its
checksum, assembles the developer test checklist and generates
Apps/Mail/Mail.xcodeproj. Needs no Homebrew or Mint. Safe to run again.

  --no-generate   only install and verify the tools
  -h, --help      show this help
EOF
}

GENERATE=1
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --no-generate) GENERATE=0 ;;
    "") ;;
    *) echo "bootstrap: unknown argument $1" >&2; exit 2 ;;
esac

xcode_major="$(xcodebuild -version 2>/dev/null | sed -n 's/^Xcode \([0-9]*\).*/\1/p')"
[[ -n "$xcode_major" && "$xcode_major" -ge "$XCODE_MIN_MAJOR" ]] || { echo "bootstrap: Xcode >= $XCODE_MIN_MAJOR required (found: ${xcode_major:-none})" >&2; exit 1; }
swift_ver="$(xcrun swift --version 2>&1 | sed -n 's/.*Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)"
[[ "$(printf '%s\n%s\n' "$SWIFT_MIN" "$swift_ver" | sort -V | head -1)" == "$SWIFT_MIN" ]] || { echo "bootstrap: Swift >= $SWIFT_MIN required (found: ${swift_ver:-none})" >&2; exit 1; }

[[ -n "$XCODEGEN_SHA256" ]] || { echo "bootstrap: XCODEGEN_SHA256 is empty in Tools/versions.env" >&2; exit 1; }
DIST="$ROOT/Tools/.bin/xcodegen-$XCODEGEN_VERSION"
BIN="$DIST/bin/xcodegen"
if [[ ! -x "$BIN" ]]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    echo "bootstrap: downloading XcodeGen $XCODEGEN_VERSION"
    curl -fsSL -o "$tmp/xcodegen.zip" "https://github.com/yonaskolb/XcodeGen/releases/download/${XCODEGEN_VERSION}/xcodegen.zip"
    echo "$XCODEGEN_SHA256  $tmp/xcodegen.zip" | shasum -a 256 -c - >/dev/null \
        || { echo "bootstrap: SHA-256 mismatch for XcodeGen $XCODEGEN_VERSION; refusing to use it" >&2; exit 1; }
    unzip -q "$tmp/xcodegen.zip" -d "$tmp/x"
    mkdir -p "$ROOT/Tools/.bin"; rm -rf "$DIST"
    mv "$tmp/x/xcodegen" "$DIST"
fi
echo "bootstrap: $("$BIN" --version | head -1) (pinned $XCODEGEN_VERSION, checksum verified)"

if [[ "$GENERATE" == 1 ]]; then
    # Must exist before XcodeGen lists the app's resources; fails loudly on an invalid fragment
    python3 "$ROOT/Tools/ci/checklist.py" build
    "$BIN" generate --spec "$ROOT/Apps/Mail/project.yml" --project "$ROOT/Apps/Mail"
    echo "bootstrap: generated Apps/Mail/Mail.xcodeproj"
fi
