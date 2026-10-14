#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Tools/ci/package-app.sh <path/to/OpenHumanMail.app> <out.zip>

Packages a built app as a zip for CI artifacts: signs the whole bundle ad hoc,
verifies the signature and zips it.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac
[[ $# -eq 2 ]] || { usage >&2; exit 2; }
APP="$1"; OUT="$2"
[[ -d "$APP" ]] || { echo "package-app: no such app bundle: $APP" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"; rm -f "$OUT"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT"
echo "package-app: wrote $OUT"
