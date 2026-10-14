#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="$ROOT/Apps/Mail/Config/Version.xcconfig"
die() { printf 'bump-version: %s\n' "$*" >&2; exit 1; }
setting() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" "$FILE" | head -1; }

usage() {
    cat <<'EOF'
Usage: Tools/release/bump-version.sh                     print the current version (0.1.0)
       Tools/release/bump-version.sh --channel           print the release channel (early-development)
       Tools/release/bump-version.sh --label             print the version with its channel (0.1.0 (early development))
       Tools/release/bump-version.sh patch|minor|major   0.1.0 becomes 0.1.1 | 0.2.0 | 1.0.0
       Tools/release/bump-version.sh 0.2.0               set an exact version (three numbers, higher than now)
       Tools/release/bump-version.sh -h|--help           show this help

Shows or raises the app's version: MARKETING_VERSION in Apps/Mail/Config/Version.xcconfig. The
release channel beside it (OH_RELEASE_CHANNEL, early-development for every release so far) is
read, never changed.

It only edits the version line. Commit the change on a branch and merge it like any other
change.
EOF
}

current="$(setting MARKETING_VERSION)"
[[ "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "MARKETING_VERSION in $FILE is '$current', not three numbers such as 0.1.0. Fix it by hand."
major="${BASH_REMATCH[1]}"; minor="${BASH_REMATCH[2]}"; patch="${BASH_REMATCH[3]}"
channel="$(setting OH_RELEASE_CHANNEL)"
[[ "$channel" =~ ^[a-z]+(-[a-z]+)*$ ]] \
    || die "OH_RELEASE_CHANNEL in $FILE is '$channel', expected a channel such as early-development. Fix it by hand."
label() { echo "$1 (${channel//-/ })"; }

case "${1:-}" in
    "") echo "$current"; exit 0 ;;
    --channel) echo "$channel"; exit 0 ;;
    --label) label "$current"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    patch) next="$major.$minor.$((patch + 1))" ;;
    minor) next="$major.$((minor + 1)).0" ;;
    major) next="$((major + 1)).0.0" ;;
    *) [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "expected patch, minor, major or three numbers such as 0.2.0 (got '$1')."
       next="$1" ;;
esac
[[ $# -le 1 ]] || die "one argument only (see --help)."
if [[ "$next" == "$current" || "$(printf '%s\n%s\n' "$current" "$next" | sort -V | tail -1)" != "$next" ]]; then
    die "$next is not higher than the current $current. Versions only go up."
fi

tmp="$(mktemp)"
sed "s/^\([[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*\)${current//./\\.}/\1$next/" "$FILE" >"$tmp"
written="$(sed -n 's/^[[:space:]]*MARKETING_VERSION[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' "$tmp" | head -1)"
[[ "$written" == "$next" ]] || { rm -f "$tmp"; die "could not rewrite $FILE. It is unchanged."; }
cat "$tmp" >"$FILE"
rm -f "$tmp"
echo "bump-version: $current -> $(label "$next") in Apps/Mail/Config/Version.xcconfig. Commit it on a branch. make-dmg.sh reads it from there."
