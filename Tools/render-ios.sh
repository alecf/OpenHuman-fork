#!/usr/bin/env bash
set -euo pipefail
SCREENS_ALL="inbox reader swipe done compose search mailboxes settings remind"
BUNDLE_ID="dev.openhuman.mail.ios"

usage() {
    cat <<'EOF'
Usage: Tools/render-ios.sh --app <OpenHumanMail.app> [options]

Renders the iPhone app's main screens on sample mail into PNGs, in light and dark, for a visual
check. Installs a Debug or DevTools build (Tools/ci/build-ios-app.sh) on an iOS Simulator,
launches it once per screen with -OHScreen <screen>, and saves a screenshot of each
as <screen>-<appearance>.png. The output folder must be outside every git work tree; never commit
the PNGs.

  --app <path>               the built OpenHumanMail.app for the iOS Simulator
  --out <dir>                output folder (default ~/Downloads/OpenHuman-renders/ios-<timestamp>)
  --device <udid>            simulator to use (default: the first available iPhone)
  --screens <a,b,...>        only these screens: inbox, reader, swipe, done, compose, search,
                             mailboxes, settings, remind (default: all)
  --appearances <a,b>        light, dark or both (default: light,dark)
  --data <fake|fixture|fake-gmail>
                             the sample mail: the fake mail store (default), the real mail store
                             seeded with it, or the sync engine against an in-process fake Gmail
  --settle <seconds>         wait after each launch before the screenshot (default 4)
  -h, --help                 show this help
EOF
}

die() { echo "render-ios: $1" >&2; exit 2; }

APP=""; OUT="$HOME/Downloads/OpenHuman-renders/ios-$(date +%Y%m%d-%H%M%S)"; DEVICE=""; SCREENS="$SCREENS_ALL"
APPEARANCES="light dark"; SETTLE=4; DATA=fake
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) [[ $# -ge 2 ]] || die "--app needs a value"; APP="$2"; shift 2 ;;
        --out) [[ $# -ge 2 ]] || die "--out needs a value"; OUT="$2"; shift 2 ;;
        --device) [[ $# -ge 2 ]] || die "--device needs a value"; DEVICE="$2"; shift 2 ;;
        --screens) [[ $# -ge 2 ]] || die "--screens needs a value"; SCREENS="${2//,/ }"; shift 2 ;;
        --appearances) [[ $# -ge 2 ]] || die "--appearances needs a value"; APPEARANCES="${2//,/ }"; shift 2 ;;
        --settle) [[ $# -ge 2 ]] || die "--settle needs a value"; SETTLE="$2"; shift 2 ;;
        --data) [[ $# -ge 2 ]] || die "--data needs a value"; DATA="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument $1 (see --help)" ;;
    esac
done
[[ -n "$APP" ]] || die "--app is required (see --help)"
[[ -d "$APP" ]] || die "no app at $APP"
[[ "$SETTLE" =~ ^[0-9]+$ ]] || die "--settle takes whole seconds"
case "$DATA" in
    fake) DATA_ARG=-UseFakeData ;;
    fixture) DATA_ARG=-UseFixtureStore ;;
    fake-gmail) DATA_ARG=-UseFakeGmail ;;
    *) die "--data takes fake, fixture or fake-gmail" ;;
esac
for screen in $SCREENS; do [[ " $SCREENS_ALL " == *" $screen "* ]] || die "unknown screen '$screen'"; done
for look in $APPEARANCES; do [[ "$look" == light || "$look" == dark ]] || die "unknown appearance '$look'"; done

mkdir -p "$OUT"
if git -C "$OUT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "$OUT is inside a git work tree; choose a folder outside every repository"
fi

if [[ -z "$DEVICE" ]]; then
    DEVICE="$(xcrun simctl list devices available -j | python3 -c '
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
')" || die "no iPhone simulator is installed"
fi

state="$(xcrun simctl list devices -j | python3 -c '
import json, sys
udid = sys.argv[1]
for runtime in json.load(sys.stdin)["devices"].values():
    for device in runtime:
        if device["udid"] == udid:
            print(device["state"])
            sys.exit(0)
sys.exit(1)
' "$DEVICE")" || die "no simulator with id $DEVICE"

BOOTED_HERE=0
if [[ "$state" != "Booted" ]]; then
    xcrun simctl boot "$DEVICE"
    BOOTED_HERE=1
fi
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
ORIGINAL="$(xcrun simctl ui "$DEVICE" appearance 2>/dev/null || echo light)"
# Why: the simulator service writes the screenshot itself and may not reach an external volume
SHOTS="$(mktemp -d /tmp/oh-render-ios.XXXXXX)"

cleanup() {
    xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
    xcrun simctl status_bar "$DEVICE" clear >/dev/null 2>&1 || true
    xcrun simctl ui "$DEVICE" appearance "$ORIGINAL" >/dev/null 2>&1 || true
    if [[ "$BOOTED_HERE" == 1 ]]; then xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true; fi
    rm -f "$SHOTS"/*.png
    rmdir "$SHOTS" 2>/dev/null || true
}
trap cleanup EXIT

xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100 \
    --cellularBars 4 --wifiBars 3 >/dev/null 2>&1 || true
xcrun simctl install "$DEVICE" "$APP"

for look in $APPEARANCES; do
    xcrun simctl ui "$DEVICE" appearance "$look"
    for screen in $SCREENS; do
        xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true
        xcrun simctl launch "$DEVICE" "$BUNDLE_ID" "$DATA_ARG" -OHScreen "$screen" >/dev/null
        sleep "$SETTLE"
        xcrun simctl io "$DEVICE" screenshot "$SHOTS/$screen-$look.png" >/dev/null 2>&1
        mv "$SHOTS/$screen-$look.png" "$OUT/$screen-$look.png"
        echo "render-ios: $OUT/$screen-$look.png"
    done
done
