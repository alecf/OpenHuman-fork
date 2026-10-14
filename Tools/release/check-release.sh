#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENTITLEMENTS_SOURCE="$ROOT/Apps/Mail/Entitlements/Mail.entitlements"

usage() {
    cat <<'EOF'
Usage: Tools/release/check-release.sh [options] <path.app | path.dmg | path/release-info.txt>...

Checks a release build of OpenHuman Mail: the early development marker, signature, hardened
runtime, entitlements, no baked-in OAuth client, notarization ticket and Gatekeeper
(docs/release/RELEASE-HOWTO.md). Read-only: it never signs, submits or changes what it checks.
A .dmg is attached read-only and hidden from Finder, checked (with the app inside it), then
detached. A release-info.txt (written by make-dmg.sh) is checked for the marker, and so are the
release-notes.md beside it.

  --pre-notarization     skip the notarization checks (stapled ticket, Gatekeeper). make-dmg.sh
                         uses this before it sends anything to Apple
  --unsigned             an unsigned build (make-dmg.sh --unsigned): the app is ad-hoc signed
                         and nothing is notarized, so skip the Developer ID, timestamp,
                         hardened runtime and notarization checks. Everything else still runs
  --team <TEAMID>        the signatures must carry this team id (default: any Developer ID
                         team, the same everywhere)
  --expect-commit <sha>  Info.plist OHGitCommit must equal this (make-dmg.sh passes the commit
                         it built)
  --allow-dirty          accept an OHGitCommit ending in +dirty (rehearsals only, never a build
                         you hand out)
  --github-release <tag> the published GitHub release must be marked as a pre-release and say
                         "(early development)" in its title (asks GitHub through the gh
                         command)
  -h, --help             show this help

Exit status: 0 when every check passes, 1 when any check fails, 2 for bad arguments.
EOF
}

RELEASE_CHANNEL="early-development"
NOTES_MARKER="Early development build"

# Empty on purpose: add a key here only together with the same key in Mail.entitlements
ALLOWED_ENTITLEMENTS=""
IDENTITY_ENTITLEMENTS="com.apple.application-identifier com.apple.developer.team-identifier"

PRE=0; UNSIGNED=0; TEAM=""; EXPECT_COMMIT=""; ALLOW_DIRTY=0; TARGETS=(); RELEASES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pre-notarization) PRE=1; shift ;;
        --unsigned) UNSIGNED=1; PRE=1; shift ;;
        --team) TEAM="${2:-}"; shift 2 ;;
        --expect-commit) EXPECT_COMMIT="${2:-}"; shift 2 ;;
        --allow-dirty) ALLOW_DIRTY=1; shift ;;
        --github-release) [[ -n "${2:-}" ]] || { echo "check-release: --github-release needs a tag" >&2; exit 2; }
                          RELEASES+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "check-release: unknown option $1 (see --help)" >&2; exit 2 ;;
        *) TARGETS+=("$1"); shift ;;
    esac
done
[[ ${#TARGETS[@]} -gt 0 || ${#RELEASES[@]} -gt 0 ]] \
    || { echo "check-release: give a .app, .dmg or release-info.txt to check, or --github-release (see --help)" >&2; exit 2; }
[[ "$UNSIGNED" == 0 || -z "$TEAM" ]] || { echo "check-release: --unsigned builds carry no team, so --team does not apply" >&2; exit 2; }

FAILS=0; WARNS=0; MOUNTS=""
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
warn() { printf '  warn  %s\n' "$*"; WARNS=$((WARNS + 1)); }
note() { printf '        %s\n' "$*"; }
has_word() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

cleanup() {
    local m
    for m in $MOUNTS; do hdiutil detach "$m" -quiet >/dev/null 2>&1 || hdiutil detach "$m" -force -quiet >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

plist_keys() { { plutil -p "$1" 2>/dev/null || true; } | sed -n 's/^  "\([^"]*\)" =>.*/\1/p'; }

signed_entitlement_keys() {
    local tmp; tmp="$(mktemp)"
    codesign -d --entitlements - --xml "$1" >"$tmp" 2>/dev/null || true
    if [[ -s "$tmp" ]]; then plist_keys "$tmp"; fi
    rm -f "$tmp"
    return 0
}

check_entitlements_source() {
    [[ -f "$ENTITLEMENTS_SOURCE" ]] || return 0
    local keys key
    keys="$(plist_keys "$ENTITLEMENTS_SOURCE")"
    if [[ -z "$keys" ]]; then
        ok "entitlements file Apps/Mail/Entitlements/Mail.entitlements: no keys"
        return 0
    fi
    note "entitlements file Apps/Mail/Entitlements/Mail.entitlements lists:"
    for key in $keys; do
        if has_word "$ALLOWED_ENTITLEMENTS" "$key"; then note "  $key (allowed)"
        else bad "entitlements file asks for $key, which ALLOWED_ENTITLEMENTS in $0 does not allow"; fi
    done
}

check_signed_entitlements() {
    local code="$1" label="$2" keys key
    keys="$(signed_entitlement_keys "$code")"
    if [[ -z "$keys" ]]; then ok "$label: no entitlements in the signature"; return 0; fi
    for key in $keys; do
        if [[ "$key" == com.apple.security.get-task-allow ]]; then
            bad "$label: signed with com.apple.security.get-task-allow (debugger attach). Never in a release. Apple's notary service refuses it"
        elif has_word "$ALLOWED_ENTITLEMENTS" "$key"; then ok "$label: entitlement $key (allowed)"
        elif has_word "$IDENTITY_ENTITLEMENTS" "$key"; then note "$label: identity entry $key (names the signer, grants nothing)"
        else bad "$label: entitlement $key is broader than this app needs (ALLOWED_ENTITLEMENTS in $0)"; fi
    done
}

FIRST_TEAM=""
check_signature() {
    local path="$1" label="$2" needs_runtime="$3" out authority team
    if ! out="$(codesign -dvvv "$path" 2>&1)"; then
        bad "$label: not signed ($(printf '%s\n' "$out" | tail -1))"; return 0
    fi
    authority="$(printf '%s\n' "$out" | sed -n 's/^Authority=//p' | head -1)"
    team="$(printf '%s\n' "$out" | sed -n 's/^TeamIdentifier=//p' | head -1)"
    if [[ "$UNSIGNED" == 1 ]]; then
        if printf '%s\n' "$out" | grep -q '^Signature=adhoc'; then ok "$label: ad-hoc signature (unsigned build: no Developer ID, not notarized)"
        else note "$label: signed by '${authority:-unknown}' (checked as an unsigned build)"; fi
        return 0
    fi
    case "$authority" in
        "Developer ID Application: "*) ok "$label: signed with a Developer ID Application certificate (team $team)" ;;
        "") bad "$label: ad-hoc signature, not Developer ID (Apple only notarizes Developer ID builds)" ;;
        *) bad "$label: signed with '${authority%%:*}', not 'Developer ID Application' (Apple only notarizes Developer ID builds)" ;;
    esac
    if [[ -n "$TEAM" && "$team" != "$TEAM" ]]; then bad "$label: team $team, expected $TEAM"; fi
    if [[ -z "$FIRST_TEAM" ]]; then FIRST_TEAM="$team"
    elif [[ "$team" != "$FIRST_TEAM" ]]; then bad "$label: team $team differs from $FIRST_TEAM elsewhere in this release"; fi
    if printf '%s\n' "$out" | grep -q '^Timestamp='; then ok "$label: secure timestamp"
    else bad "$label: no secure timestamp (sign with --timestamp, the notary service requires it)"; fi
    if [[ "$needs_runtime" == 1 ]]; then
        if printf '%s\n' "$out" | grep -q '^CodeDirectory .*flags=[^ ]*runtime'; then ok "$label: hardened runtime on"
        else bad "$label: hardened runtime off (sign with --options runtime / ENABLE_HARDENED_RUNTIME=YES)"; fi
    fi
}

check_app() {
    local app="${1%/}" plist exe id ver build commit channel nested f desc rel count=0 dr out rc
    echo "check-release: app $app"
    plist="$app/Contents/Info.plist"
    [[ -f "$plist" ]] || { bad "no Contents/Info.plist: not an app bundle"; return 0; }
    exe="$app/Contents/MacOS/$(plist_value "$plist" CFBundleExecutable)"
    [[ -f "$exe" ]] || { bad "main executable missing ($exe)"; return 0; }

    id="$(plist_value "$plist" CFBundleIdentifier)"; ver="$(plist_value "$plist" CFBundleShortVersionString)"
    build="$(plist_value "$plist" CFBundleVersion)"; commit="$(plist_value "$plist" OHGitCommit)"
    channel="$(plist_value "$plist" OHReleaseChannel)"
    note "bundle id $id, version $ver ($build), commit ${commit:-none}, architectures $(lipo -archs "$exe" 2>/dev/null || echo unknown)"

    if [[ "$channel" == "$RELEASE_CHANNEL" ]]; then
        ok "early development build (OHReleaseChannel $channel)"
    else
        bad "OHReleaseChannel is '${channel:-missing}': every release must be marked as an early development build (OH_RELEASE_CHANNEL = $RELEASE_CHANNEL in Apps/Mail/Config/Version.xcconfig)"
    fi

    # A build that leaves this Mac never carries an OAuth client; values are never printed
    if [[ -n "$(plist_value "$plist" OHGoogleClientID)" || -n "$(plist_value "$plist" OHGoogleClientSecret)" ]]; then
        bad "Info.plist carries a Google OAuth client (OHGoogleClientID/OHGoogleClientSecret not empty). A shared build must not: people import their own client in onboarding. Build with Tools/release/make-dmg.sh, which forces both empty"
    else
        ok "no Google OAuth client in Info.plist (people import their own in onboarding)"
    fi

    case "$commit" in
        ""|unknown) bad "OHGitCommit is '${commit:-empty}': the build does not say which commit it is" ;;
        *+dirty) if [[ "$ALLOW_DIRTY" == 1 ]]; then warn "built from uncommitted changes ($commit): rehearsal only, do not hand it out"
                 else bad "built from uncommitted changes ($commit). Commit first, or pass --allow-dirty for a rehearsal"; fi ;;
        *) ok "built from commit $commit" ;;
    esac
    if [[ -n "$EXPECT_COMMIT" && "$commit" != "$EXPECT_COMMIT" ]]; then bad "OHGitCommit $commit, expected $EXPECT_COMMIT"; fi

    if out="$(codesign --verify --deep --strict --verbose=2 "$app" 2>&1)"; then ok "codesign --verify --deep --strict"
    else bad "codesign --verify --deep --strict failed:"; printf '%s\n' "$out" | sed 's/^/          /' | tail -8; fi

    check_signature "$app" "app" 1
    check_entitlements_source
    check_signed_entitlements "$app" "app"

    nested="$(mktemp)"
    find "$app/Contents" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) ! -path "$exe" >"$nested" 2>/dev/null || true
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        desc="$(file -b "$f" 2>/dev/null || true)"
        case "$desc" in *Mach-O*) ;; *) continue ;; esac
        count=$((count + 1)); rel="${f#"$app"/}"
        case "$desc" in *executable*) check_signature "$f" "$rel" 1 ;; *) check_signature "$f" "$rel" 0 ;; esac
        check_signed_entitlements "$f" "$rel"
    done <"$nested"
    rm -f "$nested"
    if [[ "$count" == 0 ]]; then ok "no nested code besides the main executable (the packages link statically)"
    else note "$count nested piece(s) of code checked"; fi

    dr="$({ codesign -d -r- "$app" 2>&1 || true; } | sed -n 's/^designated => //p')"
    note "designated requirement (should match the previous release, or Keychain access is asked again):"
    note "  ${dr:-unknown}"

    if [[ "$PRE" == 1 ]]; then note "notarization checks skipped ($([[ "$UNSIGNED" == 1 ]] && echo --unsigned || echo --pre-notarization))"; return 0; fi
    if xcrun stapler validate -q "$app" >/dev/null 2>&1; then ok "notarization ticket stapled (stapler validate)"
    else bad "no valid stapled ticket (xcrun stapler validate failed: no ticket, or no internet access)"; fi
    rc=0; out="$(spctl --assess --type execute --verbose=4 "$app" 2>&1)" || rc=$?
    if [[ "$rc" == 0 ]] && printf '%s\n' "$out" | grep -q 'source=Notarized Developer ID'; then
        ok "Gatekeeper accepts it (source=Notarized Developer ID)"
    else
        bad "Gatekeeper does not accept it as notarized (spctl exit $rc):"; printf '%s\n' "$out" | sed 's/^/          /' | tail -4
    fi
}

check_dmg() {
    local dmg="$1" out rc mnt apps link
    echo "check-release: disk image $dmg"
    [[ -f "$dmg" ]] || { bad "no such file"; return 0; }
    if [[ "$UNSIGNED" == 1 ]]; then
        note "disk image not signed (unsigned build)"
    else
        if out="$(codesign --verify --strict --verbose=2 "$dmg" 2>&1)"; then ok "codesign --verify --strict"
        else bad "codesign --verify --strict failed:"; printf '%s\n' "$out" | sed 's/^/          /' | tail -6; fi
        check_signature "$dmg" "dmg" 0
    fi
    if [[ "$PRE" == 0 ]]; then
        if xcrun stapler validate -q "$dmg" >/dev/null 2>&1; then ok "notarization ticket stapled to the dmg (stapler validate)"
        else bad "no valid stapled ticket on the dmg (xcrun stapler validate failed: no ticket, or no internet access)"; fi
        rc=0; out="$(spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg" 2>&1)" || rc=$?
        if [[ "$rc" == 0 ]] && printf '%s\n' "$out" | grep -q 'source=Notarized Developer ID'; then ok "Gatekeeper accepts the dmg (source=Notarized Developer ID)"
        elif [[ "$rc" == 2 ]]; then warn "spctl did not accept the disk-image arguments on this macOS. Open the dmg on another Mac instead (RELEASE-HOWTO, 'Signed build')"
        else bad "Gatekeeper does not accept the dmg as notarized (spctl exit $rc):"; printf '%s\n' "$out" | sed 's/^/          /' | tail -4; fi
    fi

    mnt="$(mktemp -d)"
    if ! hdiutil attach -nobrowse -readonly -mountpoint "$mnt" "$dmg" >/dev/null 2>&1; then
        bad "could not attach the dmg read-only"; rmdir "$mnt" 2>/dev/null || true; return 0
    fi
    MOUNTS="$MOUNTS $mnt"
    link="$(readlink "$mnt/Applications" 2>/dev/null || true)"
    if [[ "$link" == /Applications ]]; then ok "dmg has the Applications shortcut"; else warn "dmg has no Applications shortcut"; fi
    apps="$(find "$mnt" -maxdepth 1 -name '*.app' -type d)"
    case "$(printf '%s\n' "$apps" | grep -c . || true)" in
        1) check_app "$apps" ;;
        0) bad "no .app at the top of the dmg" ;;
        *) bad "more than one .app at the top of the dmg" ;;
    esac
    hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || hdiutil detach "$mnt" -force -quiet >/dev/null 2>&1 || true
    MOUNTS="${MOUNTS/ $mnt/}"
    rmdir "$mnt" 2>/dev/null || true
}

check_release_info() {
    local info="$1" version channel prerelease label expected notes
    echo "check-release: release record $info"
    [[ -f "$info" ]] || { bad "no such file"; return 0; }
    version="$(sed -n 's/^version=//p' "$info" | head -1)"
    channel="$(sed -n 's/^channel=//p' "$info" | head -1)"
    prerelease="$(sed -n 's/^prerelease=//p' "$info" | head -1)"
    label="$(sed -n 's/^label=//p' "$info" | head -1)"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "version $version"
    else bad "version is '${version:-missing}', not three numbers such as 0.1.0"; fi
    if [[ "$channel" == "$RELEASE_CHANNEL" ]]; then ok "channel $channel"
    else bad "channel is '${channel:-missing}': every release is an early development build (channel=$RELEASE_CHANNEL)"; fi
    if [[ "$prerelease" == yes ]]; then ok "marked as a pre-release (prerelease=yes)"
    else bad "prerelease is '${prerelease:-missing}': every release is published as a GitHub pre-release (prerelease=yes)"; fi
    expected="$version (${RELEASE_CHANNEL//-/ })"
    if [[ "$label" == "$expected" ]]; then ok "label $label"
    else bad "label is '${label:-missing}', expected '$expected'"; fi
    notes="$(dirname "$info")/release-notes.md"
    if [[ ! -f "$notes" ]]; then warn "no release-notes.md beside it. The notes you publish must say \"$NOTES_MARKER\""
    elif grep -qF "$NOTES_MARKER" "$notes"; then ok "release notes say it is an early development build"
    else bad "release-notes.md does not say \"$NOTES_MARKER\""; fi
}

check_github_release() {
    local tag="$1" out prerelease title
    echo "check-release: GitHub release $tag"
    command -v gh >/dev/null 2>&1 || { bad "the gh command (GitHub CLI) is not installed"; return 0; }
    if ! out="$(gh release view "$tag" --json isPrerelease,name --jq '[.isPrerelease, .name] | @tsv' 2>&1)"; then
        bad "gh release view $tag failed: $(printf '%s\n' "$out" | tail -1)"; return 0
    fi
    prerelease="${out%%$'\t'*}"; title="${out#*$'\t'}"
    if [[ "$prerelease" == true ]]; then ok "GitHub release $tag is marked as a pre-release"
    else bad "GitHub release $tag is not marked as a pre-release (fix: gh release edit $tag --prerelease)"; fi
    case "$title" in
        *"(${RELEASE_CHANNEL//-/ })"*) ok "GitHub release $tag title: $title" ;;
        *) bad "GitHub release $tag title '$title' does not say (${RELEASE_CHANNEL//-/ })" ;;
    esac
}

for t in ${TARGETS[@]+"${TARGETS[@]}"}; do
    case "$t" in
        *.app|*.app/) [[ -d "$t" ]] || { echo "check-release: no such app: $t" >&2; exit 2; }; check_app "$t" ;;
        *.dmg) check_dmg "$t" ;;
        *release-info.txt) check_release_info "$t" ;;
        *) echo "check-release: expected a .app, a .dmg or a release-info.txt: $t" >&2; exit 2 ;;
    esac
done
for r in ${RELEASES[@]+"${RELEASES[@]}"}; do check_github_release "$r"; done

if [[ "$FAILS" -gt 0 ]]; then echo "check-release: $FAILS check(s) failed, $WARNS warning(s)"; exit 1; fi
echo "check-release: all checks passed ($WARNS warning(s))"
