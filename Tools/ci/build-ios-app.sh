#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/Tools/versions.env"

usage() {
    cat <<'EOF'
Usage: Tools/ci/build-ios-app.sh [options]

Builds the iPhone app for the iOS Simulator. Runs Tools/bootstrap.sh --no-generate for the
pinned XcodeGen, then generates Apps/MailiOS/MailiOS.xcodeproj. The iPhone app shows sample mail
only: Debug and DevTools builds open it with -UseFakeData, -UseFixtureStore or -UseFakeGmail, and a
Release build says that Gmail on iPhone comes later.

  --configuration <Debug|DevTools|Release>  default Debug
  --derived-data <dir>        default <repo>/build/ios-dd (ignored by git)
  --test                      also build MailiOSTests and run them on a simulator (Debug only)
  --destination <spec>        xcodebuild destination for --test (default: the first available
                              iPhone simulator)
  --check-flavour             after a Release build, fail when the app carries a sample-data launch
                              argument or a developer switch (the same names the Mac release check
                              looks for, plus the iPhone render switch -OHScreen)
  -h, --help                  show this help

OH_COMPILATION_CACHE_PATH=<dir>  compilation cache (default ~/Library/Caches/OpenHuman/compilation-cache)
OH_SOURCE_PACKAGES=<dir>         package checkouts (default: inside the derived data folder)
EOF
}

die() { echo "build-ios-app: $1" >&2; exit 2; }

CONFIG=Debug; DD="$ROOT/build/ios-dd"; TEST=0; DEST=""; FLAVOUR=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) [[ $# -ge 2 ]] || die "--configuration needs a value"; CONFIG="$2"; shift 2 ;;
        --derived-data) [[ $# -ge 2 ]] || die "--derived-data needs a value"; DD="$2"; shift 2 ;;
        --test) TEST=1; shift ;;
        --destination) [[ $# -ge 2 ]] || die "--destination needs a value"; DEST="$2"; shift 2 ;;
        --check-flavour) FLAVOUR=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument $1 (see --help)" ;;
    esac
done
case "$CONFIG" in Debug|DevTools|Release) ;; *) die "--configuration must be Debug, DevTools or Release" ;; esac
[[ "$TEST" == 0 || "$CONFIG" == Debug ]] || die "--test needs --configuration Debug"
[[ "$FLAVOUR" == 0 || "$CONFIG" == Release ]] || die "--check-flavour needs --configuration Release"

"$ROOT/Tools/bootstrap.sh" --no-generate
"$ROOT/Tools/.bin/xcodegen-$XCODEGEN_VERSION/bin/xcodegen" generate --quiet \
    --spec "$ROOT/Apps/MailiOS/project.yml" --project "$ROOT/Apps/MailiOS"

first_iphone() {
    xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime in sorted(devices, reverse=True):
    if "iOS" not in runtime:
        continue
    for device in devices[runtime]:
        if device["name"].startswith("iPhone"):
            print(device["udid"])
            sys.exit(0)
sys.exit(1)
'
}

cache_dir="${OH_COMPILATION_CACHE_PATH:-$HOME/Library/Caches/OpenHuman/compilation-cache}"
args=(-project "$ROOT/Apps/MailiOS/MailiOS.xcodeproj" -scheme MailiOS -configuration "$CONFIG"
      -derivedDataPath "$DD" -skipPackageUpdates ARCHS=arm64
      "OH_GIT_COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
      COMPILATION_CACHE_ENABLE_CACHING=YES "COMPILATION_CACHE_CAS_PATH=$cache_dir")
[[ -z "${OH_SOURCE_PACKAGES:-}" ]] || args+=(-clonedSourcePackagesDirPath "$OH_SOURCE_PACKAGES")

if [[ "$TEST" == 1 ]]; then
    if [[ -z "$DEST" ]]; then
        udid="$(first_iphone)" || { echo "build-ios-app: no iPhone simulator is installed" >&2; exit 1; }
        DEST="platform=iOS Simulator,id=$udid"
    fi
    xcodebuild test "${args[@]}" -destination "$DEST" -parallel-testing-enabled NO -collect-test-diagnostics never
else
    xcodebuild build "${args[@]}" -destination 'generic/platform=iOS Simulator'
fi

APP="$DD/Build/Products/$CONFIG-iphonesimulator/OpenHumanMail.app"
[[ -d "$APP" ]] || { echo "build-ios-app: expected $APP after the build" >&2; exit 1; }
echo "build-ios-app: built $APP"

if [[ "$FLAVOUR" == 1 ]]; then
    eval "$(sed -n '/^DEVELOPER_NAMES="/,/"$/p' "$ROOT/Tools/release/check-release.sh")"
    [[ -n "${DEVELOPER_NAMES:-}" ]] || { echo "build-ios-app: could not read the developer names" >&2; exit 1; }
    patterns="$(mktemp)"; found="$(mktemp)"
    trap 'rm -f "$patterns" "$found"' EXIT
    printf '%s\n' $DEVELOPER_NAMES -OHScreen >"$patterns"
    while IFS= read -r -d '' f; do
        hits="$(LC_ALL=C grep -a -o -F -f "$patterns" "$f" 2>/dev/null | LC_ALL=C sort -u | tr '\n' ' ' || true)"
        [[ -z "$hits" ]] || printf '%s: %s\n' "${f#"$APP"/}" "${hits% }" >>"$found"
    done < <(find "$APP" -type f -print0)
    if [[ -s "$found" ]]; then
        echo "build-ios-app: FAIL developer switches or sample-data launch arguments in a Release build:"
        sed 's/^/  /' "$found"
        exit 1
    fi
    echo "build-ios-app: ok, no developer switches or sample-data launch arguments in the app"
fi
