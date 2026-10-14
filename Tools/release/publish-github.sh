#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Tools/release/publish-github.sh [options] <version>

Puts a build of OpenHuman Mail on the GitHub release for tag v<version>, marked as a
pre-release (every release is an early development build). By default it builds an unsigned DMG
with make-dmg.sh --unsigned. With --dmg it uploads a DMG that make-dmg.sh already made. It
uploads the DMG, its .sha256 and release-info.txt, and uses the release-notes.md beside the DMG
as the release notes. The release stays a draft, to publish in the GitHub UI, unless --publish
is given. It runs the gh command with whatever GitHub login gh has.

  --dmg <path>         upload this OpenHuman-Mail-<version>.dmg (with the release-info.txt and
                       release-notes.md that make-dmg.sh wrote beside it) instead of building
                       one
  --build-number <n>   build number when building (default: the number of commits in HEAD)
  --notes <file>       release notes to use instead of the release-notes.md beside the DMG
  --repo <owner/repo>  the GitHub repository (default: the one gh picks for this checkout)
  --publish            publish the release now instead of leaving a draft
  --dry-run            print every make-dmg.sh and gh command instead of running it
  -h, --help           show this help

It refuses to run unless the working tree is clean, <version> is the version in
Apps/Mail/Config/Version.xcconfig, a local tag v<version> (if there is one) points at HEAD, and
the DMG's release-info.txt names HEAD, this version, the early development channel and the
DMG's SHA-256.
EOF
}
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/Tools/release"
NOTICE="Early development build — expect rough edges. Please send feedback."
UNSIGNED_SECTION="## Opening an unsigned build"
DRY=0; PUBLISH=0; DMG=""; BUILD_NUMBER=""; NOTES=""; VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dmg|--build-number|--notes|--repo)
            [[ $# -ge 2 && -n "$2" ]] || { echo "publish-github: $1 needs a value" >&2; exit 2; }
            case "$1" in
                --dmg) DMG="$2" ;;
                --build-number) BUILD_NUMBER="$2" ;;
                --notes) NOTES="$2" ;;
                --repo) export GH_REPO="$2" ;;
            esac
            shift 2 ;;
        --publish) PUBLISH=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "publish-github: unknown option $1 (see --help)" >&2; exit 2 ;;
        *) [[ -z "$VERSION" ]] || { echo "publish-github: one version only (see --help)" >&2; exit 2; }
           VERSION="$1"; shift ;;
    esac
done
[[ -n "$VERSION" ]] || { echo "publish-github: give the version to publish, such as 0.1.0 (see --help)" >&2; exit 2; }

say() { printf 'publish-github: %s\n' "$*"; }
die() { printf 'publish-github: %s\n' "$*" >&2; exit 1; }
run() {
    if [[ "$DRY" == 1 ]]; then printf '  $'; printf ' %q' "$@"; printf '\n'; return 0; fi
    "$@"
}

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "the version must be three numbers such as 0.1.0 (got '$VERSION')."
[[ "$DRY" == 1 ]] || command -v gh >/dev/null 2>&1 || die "the gh command (GitHub CLI) is not installed."
[[ -z "$(git -C "$ROOT" status --porcelain)" ]] \
    || die "the working tree has changes (git status). Commit or remove them first: a release names its exact commit."
CURRENT="$("$HERE/bump-version.sh")" || die "could not read the version (above)."
[[ "$VERSION" == "$CURRENT" ]] || die "$VERSION is not the version in Apps/Mail/Config/Version.xcconfig ($CURRENT)."
CHANNEL="$("$HERE/bump-version.sh" --channel)"; LABEL="$("$HERE/bump-version.sh" --label)"
[[ "$CHANNEL" == early-development ]] || die "OH_RELEASE_CHANNEL is '$CHANNEL'. Every release is an early development build."
TAG="v$VERSION"
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD)"; HEAD_SHORT="$(git -C "$ROOT" rev-parse --short HEAD)"
if git -C "$ROOT" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    [[ "$(git -C "$ROOT" rev-parse "$TAG^{commit}")" == "$HEAD_SHA" ]] \
        || die "tag $TAG points at another commit than HEAD ($HEAD_SHORT). Check out $TAG, or publish from the commit it names."
fi
say "$TAG: OpenHuman Mail $LABEL from commit $HEAD_SHORT"

if [[ -z "$DMG" ]]; then
    [[ -n "$BUILD_NUMBER" ]] || BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD)"
    DMG="$ROOT/build/release/OpenHuman-Mail-$VERSION-$BUILD_NUMBER-unsigned/OpenHuman-Mail-$VERSION.dmg"
    run "$HERE/make-dmg.sh" --unsigned --build-number "$BUILD_NUMBER"
fi
[[ "$(basename "$DMG")" == "OpenHuman-Mail-$VERSION.dmg" ]] || die "the DMG must be named OpenHuman-Mail-$VERSION.dmg (got $(basename "$DMG"))."
DIR="$(dirname "$DMG")"
INFO="$DIR/release-info.txt"; SUMS="$DMG.sha256"
NOTES="${NOTES:-$DIR/release-notes.md}"

if [[ "$DRY" == 1 && ! -f "$DMG" ]]; then
    say "dry run: $DMG is not there yet, so its release-info.txt, checksum and notes are checked in a real run."
else
    [[ -f "$DMG" ]] || die "no DMG at $DMG."
    [[ -f "$INFO" ]] || die "no release-info.txt beside the DMG. Use a DMG made by Tools/release/make-dmg.sh."
    "$HERE/check-release.sh" "$INFO" || die "release-info.txt failed the checks above."
    field() { sed -n "s/^$1=//p" "$INFO" | head -1; }
    [[ "$(field version)" == "$VERSION" ]] || die "release-info.txt is for version $(field version), not $VERSION."
    [[ "$(field commit)" == "$HEAD_SHORT" ]] \
        || die "release-info.txt says the DMG was built from $(field commit), but HEAD is $HEAD_SHORT. Build it from HEAD."
    SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
    [[ "$(field sha256)" == "$SHA" ]] || die "the DMG's SHA-256 ($SHA) is not the one in release-info.txt. It changed after make-dmg.sh made it."
    if [[ -f "$SUMS" ]]; then
        [[ "$(cut -d' ' -f1 "$SUMS")" == "$SHA" ]] || die "$SUMS does not match the DMG."
    elif [[ "$DRY" == 1 ]]; then
        printf '  $ (cd %q && shasum -a 256 %q > %q)\n' "$DIR" "$(basename "$DMG")" "$(basename "$SUMS")"
    else
        (cd "$DIR" && shasum -a 256 "$(basename "$DMG")" >"$(basename "$SUMS")")
    fi
    [[ -f "$NOTES" ]] || die "no release notes at $NOTES."
    grep -qF "$NOTICE" "$NOTES" || die "the release notes must say \"$NOTICE\" ($NOTES)."
    if [[ "$(field notarized)" != yes ]]; then
        grep -qF "$UNSIGNED_SECTION" "$NOTES" \
            || die "this build is not notarized, so the release notes must explain how to open it (\"$UNSIGNED_SECTION\", $NOTES)."
    fi
fi

TITLE="OpenHuman Mail $LABEL"
FILES=("$DMG" "$SUMS" "$INFO")
CREATE=(gh release create "$TAG" --target "$HEAD_SHA" --prerelease --title "$TITLE" --notes-file "$NOTES")
EDIT=(gh release edit "$TAG" --prerelease --title "$TITLE" --notes-file "$NOTES")
if [[ "$PUBLISH" == 1 ]]; then EDIT+=(--draft=false); else CREATE+=(--draft); fi
UPLOAD=(gh release upload "$TAG" --clobber "${FILES[@]}")

if [[ "$DRY" == 1 ]]; then
    run gh release view "$TAG" --json isDraft --jq .isDraft
    say "a new release:"
    run "${CREATE[@]}" "${FILES[@]}"
    say "a release that exists already (a published one only with --publish):"
    run "${EDIT[@]}"
    run "${UPLOAD[@]}"
    run gh release view "$TAG" --json url --jq .url
    run "$HERE/check-release.sh" --github-release "$TAG"
    say "dry run: nothing was built or sent."
    exit 0
fi

rc=0; state="$(gh release view "$TAG" --json isDraft --jq .isDraft 2>&1)" || rc=$?
if [[ "$rc" != 0 ]]; then
    case "$state" in
        *"release not found"*) state=missing ;;
        *) die "gh release view $TAG failed: $state" ;;
    esac
fi
case "$state" in
    missing) run "${CREATE[@]}" "${FILES[@]}" ;;
    true) run "${EDIT[@]}"; run "${UPLOAD[@]}" ;;
    false) [[ "$PUBLISH" == 1 ]] || die "$TAG is published already. Pass --publish to update it."
           run "${EDIT[@]}"; run "${UPLOAD[@]}" ;;
    *) die "unexpected answer from gh release view $TAG: $state" ;;
esac
URL="$(gh release view "$TAG" --json url --jq .url)"
"$HERE/check-release.sh" --github-release "$TAG" || die "the GitHub release failed the checks above."
if [[ "$PUBLISH" == 1 ]]; then say "published: $URL"
else say "draft: $URL (review it, then publish it in the GitHub UI)"; fi
