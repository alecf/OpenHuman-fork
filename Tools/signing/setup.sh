#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Tools/signing/setup.sh [--commits | --builds] [--rotate-commit-key [--compromised]] [--dry-run]

One-time setup so that signed commits and Developer ID signed, notarized builds need no prompts
afterwards, including from SSH logins, scripts and other non-interactive shells
(docs/release/LOCAL-SIGNING.md). Run it yourself in Terminal.app on the Mac's desktop. It explains
each change and asks before making it. Steps that are already done are skipped, so running it again
is safe. It never publishes anything; uploading a release stays a separate manual step
(Tools/release/publish-github.sh).

Commits (--commits):
  - a new ed25519 key used only to sign commits, kept in ~/.local/share/git-signing, never used to log
    in anywhere; your existing SSH keys are not used or changed
  - optional passphrase, saved in your login keychain
  - a launchd service started at login that holds only this key, on a fixed socket
  - git settings (global): sign every commit with this key through that socket, verify with an
    allowed-signers file, and hooks that warn after an unsigned commit and refuse to push commits you
    made without a good signature
  - the public key added to your GitHub account as a signing key (asks first, needs gh)
Builds (--builds):
  - a separate keychain, ~/Library/Keychains/openhuman-signing.keychain-db, with a random password
    kept in ~/.config/openhuman/signing-keychain.password (readable only by you)
  - one Developer ID Application identity imported from a .p12 you export, as a non-extractable key
    that only codesign may use; a separate certificate for this Mac is recommended
  - a notarytool profile stored in that keychain
  - ~/.config/openhuman/release.env, which Tools/release/make-dmg.sh reads, and a launchd job that
    unlocks the keychain at login

  --commits             only the commit-signing part
  --builds              only the build-signing part
  --rotate-commit-key   replace the commit-signing key with a new one (old signatures stay valid
                        locally; GitHub is updated after asking)
  --compromised         with --rotate-commit-key: also mark the old key as revoked locally, so no
                        signature made with it verifies any more
  --dry-run             show the current state and what would change; change nothing
  -h, --help            show this help

Check the result from any shell, including SSH: Tools/signing/verify.sh
EOF
}

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBEXEC="$HERE/libexec"
DO_COMMITS=1; DO_BUILDS=1; ROTATE=0; COMPROMISED=0; DRY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --commits) DO_BUILDS=0; shift ;;
        --builds) DO_COMMITS=0; shift ;;
        --rotate-commit-key) ROTATE=1; DO_BUILDS=0; DO_COMMITS=1; shift ;;
        --compromised) COMPROMISED=1; shift ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "setup: unknown argument $1 (see --help)" >&2; exit 2 ;;
    esac
done
[[ "$COMPROMISED" == 0 || "$ROTATE" == 1 ]] || { echo "setup: --compromised goes with --rotate-commit-key" >&2; exit 2; }

UIDN="$(id -u)"
GS_DIR="$HOME/.local/share/git-signing"
KEY="$GS_DIR/signing_ed25519"
SOCK="$GS_DIR/agent.sock"
ALLOWED="$GS_DIR/allowed_signers"
REVOKED="$GS_DIR/revoked_keys"
GS_LABEL=local.git-signing
GS_PLIST="$HOME/Library/LaunchAgents/$GS_LABEL.plist"
CONF_DIR="$HOME/.config/openhuman"
USER_ENV="${OH_RELEASE_ENV:-$CONF_DIR/release.env}"
PWFILE="$CONF_DIR/signing-keychain.password"
KC_BASE="$HOME/Library/Keychains/openhuman-signing.keychain"
KC="$KC_BASE-db"
KC_LABEL=dev.openhuman.signing-keychain
KC_PLIST="$HOME/Library/LaunchAgents/$KC_LABEL.plist"
LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

say()  { printf 'setup: %s\n' "$*"; }
note() { printf '       %s\n' "$*"; }
ok()   { printf 'setup: ok: %s\n' "$*"; }
warn() { printf 'setup: warning: %s\n' "$*" >&2; }
die()  { printf 'setup: %s\n' "$*" >&2; exit 1; }
step() { printf '\nsetup: == %s\n' "$*"; }
show() { printf '         $'; printf ' %q' "$@"; printf '\n'; }
ask() {
    local answer
    if [[ "$DRY" == 1 ]]; then say "$1 [dry run: not changed]"; return 1; fi
    read -r -p "setup: $1 [y/N] " answer </dev/tty || return 1
    case "$answer" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}
would() { [[ "$DRY" == 1 ]] || return 1; say "dry run: would $*"; }
prompt() {
    local answer=""
    read -r -p "setup: $1${2:+ [$2]} " answer </dev/tty || answer=""
    printf '%s' "${answer:-${2:-}}"
}
unquote_path() {
    local p="$1"
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    p="${p#\'}"; p="${p%\'}"; p="${p#\"}"; p="${p%\"}"
    printf '%s' "${p//\\ / }"
}
xml_escape() { local s="$1"; s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; printf '%s' "$s"; }
loaded_service() { launchctl print "gui/$UIDN/$1" >/dev/null 2>&1; }
pub_of() { /usr/bin/awk '{ print $1 " " $2; exit }' "$1"; }

install_launch_agent() {
    local label="$1" plist="$2" content="$3"
    if [[ -f "$plist" && "$(cat "$plist")" == "$content" ]] && loaded_service "$label"; then
        ok "launchd job $label is installed and loaded"
        return 0
    fi
    would "install and start the launchd job $label ($plist)" && return 0
    say "launchd job $label ($plist):"
    printf '%s\n' "$content" | sed 's/^/         /'
    ask "Install and start it?" || { warn "skipped $label"; return 1; }
    mkdir -p "$(dirname "$plist")"
    local tmp; tmp="$(mktemp "$plist.XXXXXX")"
    printf '%s\n' "$content" >"$tmp"
    plutil -lint "$tmp" >/dev/null || { rm -f "$tmp"; die "the generated $plist is not a valid property list."; }
    mv "$tmp" "$plist"
    if loaded_service "$label"; then launchctl bootout "gui/$UIDN/$label" 2>/dev/null || true; fi
    local attempt
    for attempt in 1 2 3; do
        launchctl bootstrap "gui/$UIDN" "$plist" 2>/dev/null && break
        [[ "$attempt" == 3 ]] && die "launchctl could not load $plist (run this from the Mac's desktop, not over SSH)."
        sleep 1
    done
    ok "launchd job $label loaded"
    note "If macOS reports new background items, keep them allowed (System Settings > General > Login Items & Extensions)."
}

wait_for() {
    local i tries=$(($1 * 5))
    shift
    for ((i = 0; i < tries; i++)); do
        if "$@"; then return 0; fi
        sleep 0.2
    done
    return 1
}

preflight() {
    [[ "$(uname -s)" == Darwin ]] || die "run this on a Mac."
    [[ "$DRY" == 1 ]] && { say "dry run: nothing is changed."; return 0; }
    [[ -t 0 ]] || die "run this yourself in Terminal.app on the Mac: it asks questions and macOS shows dialogs."
    [[ -z "${SSH_CONNECTION:-}${SSH_TTY:-}" ]] || die "this is an SSH login. Run it in Terminal.app on the Mac's desktop: an SSH login cannot use the login keychain or start launchd jobs for your desktop. After the setup, SSH logins sign without prompts."
    local manager; manager="$(launchctl managername 2>/dev/null || true)"
    if [[ "$manager" != Aqua ]]; then
        warn "launchctl reports the session type '${manager:-unknown}', not Aqua (the Mac's desktop)."
        ask "Continue anyway?" || exit 1
    fi
}

git_at_least() {
    local v major minor
    v="$(git version | sed -n 's/^git version \([0-9][0-9]*\)\.\([0-9][0-9]*\).*/\1 \2/p')"
    read -r major minor <<<"$v"
    [[ -n "${major:-}" ]] && (( major > $1 || (major == $1 && minor >= $2) ))
}

config_hooks_supported() {
    local tmp out
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/git-signing-probe.XXXXXX")"
    git init -q "$tmp" 2>/dev/null
    out="$(git -C "$tmp" -c hook.signing-probe.event=pre-push -c hook.signing-probe.command=true hook list pre-push 2>/dev/null || true)"
    rm -rf "$tmp"
    [[ "$out" == *signing-probe* ]]
}

key_has_passphrase() { ! /usr/bin/ssh-keygen -y -P '' -f "$KEY" >/dev/null 2>&1; }

agent_has_key() {
    local listed blob
    blob="$(/usr/bin/awk '{ print $2; exit }' "$KEY.pub" 2>/dev/null)"
    listed="$(SSH_AUTH_SOCK="$SOCK" /usr/bin/ssh-add -L 2>/dev/null)" || return 1
    [[ -n "$blob" && "$listed" == *"$blob"* ]]
}

install_helpers() {
    local name src dst changed=0
    for name in ssh-keygen-signing signing-key-service signature-check; do
        src="$LIBEXEC/$name"; dst="$GS_DIR/bin/$name"
        [[ -f "$dst" ]] && cmp -s "$src" "$dst" && continue
        changed=1
        if [[ -f "$dst" ]]; then diff -u "$dst" "$src" | sed 's/^/         /' || true
        else say "new helper: $dst"; fi
    done
    if [[ "$changed" == 0 ]]; then ok "helpers in $GS_DIR/bin are current"; return 0; fi
    would "install the helpers into $GS_DIR/bin" && return 0
    ask "Install these helpers into $GS_DIR/bin?" || die "the helpers are needed; stopping."
    mkdir -p "$GS_DIR/bin"
    for name in ssh-keygen-signing signing-key-service signature-check; do
        install -m 0755 "$LIBEXEC/$name" "$GS_DIR/bin/$name"
    done
    ok "helpers installed"
}

make_key() {
    if [[ -f "$KEY" && -f "$KEY.pub" ]]; then
        ok "commit-signing key exists: $(/usr/bin/ssh-keygen -l -f "$KEY.pub")"
        return 0
    fi
    [[ ! -f "$KEY" && ! -f "$KEY.pub" ]] || die "$KEY or $KEY.pub is missing its other half. Move both away and run this again."
    say "A new ed25519 key will be created at $KEY, only for signing commits."
    note "It is never added to ~/.ssh or to any server as a login key."
    would "create the key" && return 0
    ask "Create it?" || die "no signing key; stopping."
    local comment
    comment="git commit signing ($(scutil --get LocalHostName 2>/dev/null || hostname -s), $(date +%Y-%m-%d))"
    say "Choose a passphrase to encrypt the key file on disk (recommended), or press Return twice for none."
    note "You type it only now: it is saved in your login keychain and the launchd service loads the key at login."
    /usr/bin/ssh-keygen -q -t ed25519 -C "$comment" -f "$KEY" </dev/tty
    chmod 600 "$KEY"
    ok "created $(/usr/bin/ssh-keygen -l -f "$KEY.pub")"
}

start_service() {
    local content
    content="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$GS_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>$(xml_escape "$GS_DIR/bin/signing-key-service")</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$GS_DIR/service.log")</string>
</dict>
</plist>
EOF
)"
    install_launch_agent "$GS_LABEL" "$GS_PLIST" "$content" || die "the key service is needed for signing; stopping."
    [[ "$DRY" == 1 ]] && return 0
    wait_for 10 test -S "$SOCK" || die "the key service did not create $SOCK. See $GS_DIR/service.log."
    ok "key service is listening on $SOCK"
}

load_key_once() {
    [[ "$DRY" == 1 ]] && { say "dry run: would make sure the key service holds the key"; return 0; }
    if agent_has_key; then ok "the key service holds the signing key"; return 0; fi
    if key_has_passphrase; then
        say "Saving the key's passphrase in your login keychain and loading the key (ssh-add --apple-use-keychain):"
        SSH_AUTH_SOCK="$SOCK" /usr/bin/ssh-add --apple-use-keychain "$KEY" </dev/tty || die "ssh-add failed."
    else
        SSH_AUTH_SOCK="$SOCK" /usr/bin/ssh-add "$KEY" </dev/null || die "ssh-add failed."
    fi
    say "Restarting the key service to check that it loads the key by itself, as it will at login."
    launchctl kickstart -k "gui/$UIDN/$GS_LABEL"
    if wait_for 15 agent_has_key; then
        ok "the key service loads the key without asking"
    else
        warn "the key service could not load the key on its own (see $GS_DIR/service.log)."
        note "Commits will fail loudly until it does. Either run: SSH_AUTH_SOCK=$SOCK ssh-add $KEY after each login,"
        note "or remove the file's passphrase (ssh-keygen -p -f $KEY) and run this setup again."
    fi
}

write_allowed_signers() {
    local email="$1" new_pub old_key old_pub existing_file tmp line
    new_pub="$(pub_of "$KEY.pub")"
    tmp="$(mktemp "${TMPDIR:-/tmp}/allowed_signers.XXXXXX")"
    if [[ -f "$ALLOWED" ]]; then cat "$ALLOWED" >"$tmp"; fi
    existing_file="$(git config --global --get gpg.ssh.allowedSignersFile || true)"
    existing_file="${existing_file/#\~/$HOME}"
    if [[ -n "$existing_file" && "$existing_file" != "$ALLOWED" && -f "$existing_file" ]]; then
        say "keeping the entries of your current allowed-signers file $existing_file"
        grep -v '^[[:space:]]*#' "$existing_file" | grep . >>"$tmp" || true
    fi
    old_key="$(git config --global --get user.signingkey || true)"
    old_key="${old_key/#\~/$HOME}"
    old_pub=""
    case "$old_key" in
        key::*) old_pub="${old_key#key::}" ;;
        ssh-*|sk-*|ecdsa-*) old_pub="$old_key" ;;
        *.pub) if [[ -f "$old_key" ]]; then old_pub="$(pub_of "$old_key")"; fi ;;
    esac
    old_pub="$(printf '%s' "$old_pub" | /usr/bin/awk '{ print $1 " " $2 }')"
    for line in "$new_pub" "$old_pub"; do
        [[ -n "${line// /}" ]] || continue
        grep -qF -- "${line#* }" "$tmp" 2>/dev/null || printf '%s namespaces="git" %s\n' "$email" "$line" >>"$tmp"
    done
    if [[ -f "$ALLOWED" ]] && cmp -s "$tmp" "$ALLOWED"; then rm -f "$tmp"; ok "allowed-signers file is current"; return 0; fi
    say "allowed-signers file $ALLOWED (public keys whose signatures git accepts as yours):"
    sed 's/^/         /' "$tmp"
    if would "write $ALLOWED"; then rm -f "$tmp"; return 0; fi
    if ask "Write it?"; then mv "$tmp" "$ALLOWED"; chmod 644 "$ALLOWED"; ok "wrote $ALLOWED"
    else rm -f "$tmp"; die "git cannot verify signatures without it; stopping."; fi
}

configure_git() {
    local email="$1" hooks="$2" pub prev entry key value current
    pub="$(pub_of "$KEY.pub")"
    local -a settings=(
        "gpg.format=ssh"
        "user.signingkey=key::$pub"
        "gpg.ssh.program=$GS_DIR/bin/ssh-keygen-signing"
        "gpg.ssh.allowedSignersFile=$ALLOWED"
        "commit.gpgsign=true"
    )
    if [[ "$hooks" == 1 ]]; then
        settings+=(
            "hook.signed-commit-warning.event=post-commit"
            "hook.signed-commit-warning.command=$GS_DIR/bin/signature-check post-commit"
            "hook.signed-push-guard.event=pre-push"
            "hook.signed-push-guard.command=$GS_DIR/bin/signature-check pre-push"
        )
    fi
    [[ "$COMPROMISED" == 0 && ! -s "$REVOKED" ]] || settings+=("gpg.ssh.revocationFile=$REVOKED")
    local -a pending=()
    for entry in "${settings[@]}"; do
        key="${entry%%=*}"; value="${entry#*=}"
        current="$(git config --global --get-all "$key" 2>/dev/null || true)"
        [[ "$current" == "$value" ]] || pending+=("$entry")
    done
    if [[ ${#pending[@]} == 0 ]]; then ok "git settings are current"; return 0; fi
    say "git settings to change in your global config ($(git config --global --show-origin --get user.email | cut -f1)):"
    for entry in "${pending[@]}"; do
        key="${entry%%=*}"
        printf '         %s\n           was: %s\n           new: %s\n' "$key" "$(git config --global --get-all "$key" 2>/dev/null | tr '\n' ' ' || true)" "${entry#*=}"
    done
    would "apply these git settings" && return 0
    ask "Apply them?" || die "git is not configured; stopping."
    prev="$GS_DIR/previous-git-config"
    if [[ ! -f "$prev" ]]; then
        for entry in "${settings[@]}"; do
            key="${entry%%=*}"
            printf '%s\t%s\n' "$key" "$(git config --global --get-all "$key" 2>/dev/null | tr '\n' ' ' || true)"
        done >"$prev"
        note "previous values saved in $prev"
    fi
    for entry in "${pending[@]}"; do
        git config --global --replace-all "${entry%%=*}" "${entry#*=}"
    done
    [[ -f "$GS_DIR/enforce-since" ]] || date -u +%Y-%m-%dT%H:%M:%SZ >"$GS_DIR/enforce-since"
    ok "git now signs every commit with the dedicated key"
}

github_keys() { gh api --paginate user/ssh_signing_keys --jq '.[] | "\(.id) \(.key)"' 2>/dev/null; }

register_on_github() {
    local pub blob listed title
    pub="$(pub_of "$KEY.pub")"; blob="${pub#* }"
    if ! command -v gh >/dev/null 2>&1; then
        warn "gh is not installed. Add the key yourself: https://github.com/settings/ssh/new, Key type: Signing Key, key:"
        note "$pub"
        return 0
    fi
    if ! listed="$(github_keys)"; then
        say "gh cannot list your SSH signing keys yet; it needs the read:ssh_signing_key and write:ssh_signing_key scopes."
        show gh auth refresh -h github.com -s read:ssh_signing_key,write:ssh_signing_key
        if ask "Run that now (it opens a GitHub sign-in in your browser)?"; then
            gh auth refresh -h github.com -s read:ssh_signing_key,write:ssh_signing_key </dev/tty
            listed="$(github_keys)" || { warn "still cannot list signing keys; add the key at https://github.com/settings/ssh/new (Signing Key):"; note "$pub"; return 0; }
        else
            note "Add it yourself at https://github.com/settings/ssh/new as a Signing Key:"; note "$pub"; return 0
        fi
    fi
    if [[ "$listed" == *"$blob"* ]]; then ok "GitHub already has this key as a signing key"; return 0; fi
    title="Commit signing ($(scutil --get LocalHostName 2>/dev/null || hostname -s), $(date +%Y-%m-%d))"
    say "Your GitHub account does not have this signing key yet. This uploads the PUBLIC key only, as a signing key:"
    show gh ssh-key add "$KEY.pub" --type signing --title "$title"
    if ask "Upload it?"; then
        gh ssh-key add "$KEY.pub" --type signing --title "$title"
        ok "added to GitHub. Commits show Verified when the committer email ($(git config --global user.email)) is a verified address of your account."
    else
        note "Not uploaded. GitHub will show your new commits as Unverified until you add it as a Signing Key."
    fi
}

test_commit_signing() {
    [[ "$DRY" == 1 ]] && return 0
    local tmp status
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/git-signing-check.XXXXXX")"
    git init -q "$tmp"
    if git -C "$tmp" commit -q --allow-empty -m "signing check" </dev/null \
        && status="$(git -C "$tmp" log -1 --format=%G?)" && [[ "$status" == G ]]; then
        rm -rf "$tmp"; ok "a test commit was signed and verifies (status G)"
    else
        rm -rf "$tmp"; die "the test commit was not signed and verified (status ${status:-none}). Run Tools/signing/verify.sh --commits for details."
    fi
}

retire_commit_key() {
    [[ -f "$KEY.pub" ]] || die "there is no commit-signing key at $KEY to rotate."
    local old_pub stamp
    old_pub="$(pub_of "$KEY.pub")"
    stamp="$(date -u +%Y%m%d%H%M%SZ)"
    step "Retire the current commit-signing key"
    say "Current key: $(/usr/bin/ssh-keygen -l -f "$KEY.pub")"
    if [[ "$COMPROMISED" == 1 ]]; then
        note "Marked compromised: it goes into $REVOKED (gpg.ssh.revocationFile), so git treats every signature it made as invalid."
    else
        note "Its allowed-signers entry gets valid-before=$stamp: signatures dated before now still verify locally."
    fi
    note "The private key file is deleted and its saved passphrase is removed from the login keychain."
    would "retire this key and create a new one" && exit 0
    ask "Retire it now?" || exit 1
    if [[ -S "$SOCK" ]]; then
        SSH_AUTH_SOCK="$SOCK" /usr/bin/ssh-add -d --apple-use-keychain "$KEY" >/dev/null 2>&1 || true
    fi
    mkdir -p "$GS_DIR/retired"
    mv "$KEY.pub" "$GS_DIR/retired/signing_ed25519.$stamp.pub"
    rm -f "$KEY"
    if [[ -f "$ALLOWED" ]]; then
        local tmp; tmp="$(mktemp "$ALLOWED.XXXXXX")"
        /usr/bin/awk -v blob="${old_pub#* }" -v stamp="$stamp" '
            index($0, blob) && $2 ~ /^namespaces=/ && $2 !~ /valid-before=/ { $2 = $2 ",valid-before=" stamp }
            { print }' "$ALLOWED" >"$tmp"
        mv "$tmp" "$ALLOWED"
    fi
    if [[ "$COMPROMISED" == 1 ]]; then printf '%s\n' "$old_pub" >>"$REVOKED"; fi
    RETIRED_PUB="$old_pub"
    ok "retired; a new key is created next"
}

remove_old_key_from_github() {
    local blob id
    [[ -n "${RETIRED_PUB:-}" ]] && command -v gh >/dev/null 2>&1 || return 0
    blob="${RETIRED_PUB#* }"
    id="$(github_keys | /usr/bin/awk -v blob="$blob" 'index($0, blob) { print $1; exit }' || true)"
    [[ -n "$id" ]] || { note "the old key is not on GitHub (or gh cannot list signing keys)."; return 0; }
    say "The retired key is still a signing key on GitHub (id $id)."
    note "GitHub keeps the Verified status it already recorded for pushed commits when a key is rotated or revoked;"
    note "removing the key stops commits signed with it from being verified from now on."
    show gh api -X DELETE "user/ssh_signing_keys/$id"
    if ask "Remove it from GitHub (needs the admin:ssh_signing_key scope)?"; then
        gh api -X DELETE "user/ssh_signing_keys/$id" || {
            warn "gh could not delete it. Grant the scope with: gh auth refresh -h github.com -s admin:ssh_signing_key"
            note "or remove it at https://github.com/settings/keys"; }
    fi
}

setup_commits() {
    step "Commit signing"
    command -v git >/dev/null 2>&1 || die "git is missing."
    git_at_least 2 34 || die "git $(git version) is too old for SSH commit signing (2.34 or later)."
    local tool email hooks=1
    for tool in /usr/bin/ssh-keygen /usr/bin/ssh-agent /usr/bin/ssh-add; do
        [[ -x "$tool" ]] || die "$tool is missing."
    done
    email="$(git config --global user.email || true)"
    [[ -n "$email" ]] || die "set your commit email first (git config --global user.email ...). It must be a verified address of your GitHub account."
    if ! config_hooks_supported; then
        hooks=0
        warn "this git ($(git version)) has no config-based hooks; the unsigned-push guard is not installed."
    fi
    if [[ "$ROTATE" == 1 ]]; then retire_commit_key; fi
    if [[ ! -d "$GS_DIR" ]]; then
        if would "create $GS_DIR, a key, the key service and the git settings"; then return 0; fi
        ask "Create $GS_DIR (readable only by you)?" || die "stopping."
        mkdir -p "$GS_DIR"
    fi
    [[ "$DRY" == 1 ]] || chmod 700 "$GS_DIR"
    install_helpers
    make_key
    if [[ ! -f "$KEY.pub" ]]; then say "dry run: the remaining steps need the key."; return 0; fi
    start_service
    load_key_once
    write_allowed_signers "$email"
    configure_git "$email" "$hooks"
    register_on_github
    remove_old_key_from_github
    test_commit_signing
}

keychain_password() { cat "$PWFILE"; }

unlock_keychain() { security unlock-keychain -p "$(keychain_password)" "$KC"; }

make_keychain() {
    if [[ ! -f "$KC" && -f "$KC_BASE" ]]; then KC="$KC_BASE"; fi
    if [[ -f "$KC" ]]; then
        [[ -f "$PWFILE" ]] || die "$KC exists but its password file $PWFILE is missing. Restore the file, or delete the keychain (security delete-keychain $KC) and run this again."
        [[ "$DRY" == 1 ]] && { ok "signing keychain exists: $KC"; return 0; }
        unlock_keychain || die "the password in $PWFILE does not unlock $KC."
        ok "signing keychain exists and unlocks: $KC"
        return 0
    fi
    say "A separate keychain will be created: $KC"
    note "Its password is random and stored in $PWFILE (mode 600). Anything running as you can read that file;"
    note "that is what lets SSH logins and scripts sign without prompts. It holds only the identity you import next"
    note "(non-extractable) and the notarytool profile. It never locks on its own while you are logged in."
    would "create the keychain, import an identity and store a notarytool profile" && return 0
    ask "Create it?" || die "stopping."
    mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"
    local pw
    pw="$(head -c 30 /dev/urandom | base64 | tr -d '/+=\n')"
    (umask 077; printf '%s' "$pw" >"$PWFILE")
    security create-keychain -p "$pw" "$KC_BASE"
    [[ -f "$KC" ]] || { [[ -f "$KC_BASE" ]] && KC="$KC_BASE"; }
    [[ -f "$KC" ]] || die "security create-keychain did not create $KC."
    security set-keychain-settings "$KC"
    unlock_keychain
    ok "created $KC"
}

add_to_search_list() {
    local line found=0
    local -a current=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
        [[ -n "$line" ]] || continue
        current+=("$line")
        if [[ "$line" == "$KC" ]]; then found=1; fi
    done < <(security list-keychains -d user)
    if [[ "$found" == 1 ]]; then ok "the signing keychain is in your keychain search list"; return 0; fi
    say "Xcode finds signing identities through your keychain search list, so the signing keychain is added at its end:"
    show security list-keychains -d user -s ${current[@]+"${current[@]}"} "$KC"
    would "add it" && return 0
    ask "Add it?" || die "stopping: Xcode would not find the identity."
    security list-keychains -d user -s ${current[@]+"${current[@]}"} "$KC"
    ok "added to the search list"
}

developer_ids() {
    security find-identity -v -p codesigning "$@" 2>/dev/null \
        | sed -n 's/^[[:space:]]*[0-9][0-9]*)[[:space:]]*\([0-9A-Fa-f]\{40\}\)[[:space:]]*"\(Developer ID Application: .*\)"[[:space:]]*$/\1 \2/p'
}

import_identity() {
    local ids count p12 choice
    ids="$(developer_ids "$KC" || true)"
    if [[ -z "$ids" ]]; then
        say "The signing keychain has no Developer ID Application identity yet."
        note "Recommended: a separate Developer ID Application certificate for this Mac's automated builds, so that"
        note "revoking it never affects apps signed with your main certificate (Apple allows five; the Account"
        note "Holder creates them in Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application)."
        note "Then in Keychain Access, login keychain, My Certificates: select that certificate, File > Export Items,"
        note "and save a .p12 with a temporary password. Your main certificate's .p12 also works."
        [[ "$DRY" == 1 ]] && return 0
        p12="$(unquote_path "$(prompt "Drag the .p12 file here and press Return (Return alone stops):")")"
        [[ -n "$p12" ]] || die "no .p12 given; stopping."
        [[ -f "$p12" ]] || die "$p12 is not a file."
        say "Importing it as non-extractable, usable without prompts only by codesign:"
        show security import "$p12" -k "$KC" -f pkcs12 -x -T /usr/bin/codesign
        note "macOS asks for the .p12's password in a dialog."
        ask "Import it?" || die "stopping."
        security import "$p12" -k "$KC" -f pkcs12 -x -T /usr/bin/codesign
        security set-key-partition-list -S apple-tool:,apple: -s -k "$(keychain_password)" "$KC" >/dev/null
        ok "imported; Apple tools may use the key without a dialog (partition list apple-tool:,apple:)"
        if ask "Delete $p12 now? (Keep it only as an encrypted backup you store elsewhere.)"; then rm -f "$p12"; fi
        ids="$(developer_ids "$KC" || true)"
    fi
    if [[ -z "$ids" ]]; then
        [[ "$DRY" == 1 ]] && return 0
        if [[ "$(security find-identity -p codesigning "$KC" 2>/dev/null || true)" == *"Developer ID Application"* ]]; then
            die "the identity is there but not valid: macOS cannot build its certificate chain. Install the Developer ID intermediate certificates (Developer ID - G1 and G2) from https://www.apple.com/certificateauthority/ and run this again."
        fi
        die "the .p12 did not contain a Developer ID Application identity."
    fi
    count="$(printf '%s\n' "$ids" | grep -c .)"
    if [[ "$count" == 1 ]]; then
        SIGN_HASH="${ids%% *}"; SIGN_NAME="${ids#* }"
    else
        printf '%s\n' "$ids" | /usr/bin/awk '{ printf "         %d) %s\n", NR, $0 }'
        choice="$(prompt "Which identity should builds use (number)?" 1)"
        [[ "$choice" =~ ^[0-9]+$ ]] || die "not a number."
        ids="$(printf '%s\n' "$ids" | sed -n "${choice}p")"
        [[ -n "$ids" ]] || die "no identity $choice."
        SIGN_HASH="${ids%% *}"; SIGN_NAME="${ids#* }"
    fi
    TEAM="$(printf '%s\n' "$SIGN_NAME" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')"
    ok "builds sign with $SIGN_NAME ($SIGN_HASH)"
}

copy_intermediates() {
    local ca="Developer ID Certification Authority" pem
    [[ -z "$(security find-certificate -a -c "$ca" "$KC" 2>/dev/null || true)" ]] || { ok "the signing keychain has the $ca certificates"; return 0; }
    pem="$(security find-certificate -a -c "$ca" -p 2>/dev/null || true)"
    if [[ -z "$pem" ]]; then
        warn "no '$ca' certificates found. If verification fails, install Developer ID - G1 and G2 from https://www.apple.com/certificateauthority/"
        return 0
    fi
    say "SSH logins cannot read the login keychain, so the signing keychain also gets the public '$ca' certificates, to build the chain."
    would "copy them" && return 0
    ask "Copy them?" || { warn "not copied; an SSH login may find the identity not valid."; return 0; }
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/developer-id-ca.XXXXXX")"
    printf '%s\n' "$pem" >"$tmp"
    security import "$tmp" -k "$KC" -t cert -f pemseq >/dev/null 2>&1 || true
    rm -f "$tmp"
    ok "copied the intermediate certificates"
}

remove_login_duplicate() {
    [[ -n "${SIGN_HASH:-}" && -f "$LOGIN_KC" ]] || return 0
    [[ "$(security find-identity -p codesigning "$LOGIN_KC" 2>/dev/null || true)" == *"$SIGN_HASH"* ]] \
        || { ok "the identity is only in the signing keychain"; return 0; }
    say "The same identity is also in your login keychain. Xcode's export step searches every keychain, and an SSH"
    note "login cannot use the login keychain's copy, so builds over SSH can fail with errSecInternalComponent."
    note "Remove it there only if it is the separate automation certificate, or if you keep a .p12 backup."
    show security delete-identity -Z "$SIGN_HASH" "$LOGIN_KC"
    if ask "Remove the login keychain's copy?"; then
        security delete-identity -Z "$SIGN_HASH" "$LOGIN_KC"
        ok "removed from the login keychain"
    else
        warn "kept both copies. If an SSH build fails during export, use Tools/release/make-dmg.sh --from-archive."
    fi
}

setup_notary() {
    local profile method key key_id issuer apple_id team
    profile="${OH_NOTARY_PROFILE:-openhuman-notary}"
    [[ "$DRY" == 1 ]] && { say "dry run: would check the notarytool profile '$profile' in $KC"; NOTARY_PROFILE="$profile"; return 0; }
    if xcrun notarytool history --keychain-profile "$profile" --keychain "$KC" >/dev/null 2>&1; then
        ok "notarytool profile '$profile' in the signing keychain works"
        NOTARY_PROFILE="$profile"; return 0
    fi
    say "The signing keychain has no working notarytool profile '$profile'."
    note "Profiles cannot be copied between keychains, so enter the credentials once more. An App Store Connect"
    note "API key (.p8) can be revoked on its own; an app-specific password is the other choice."
    profile="$(prompt "Profile name:" "$profile")"
    method="$(prompt "Use an API key (k) or Apple ID with app-specific password (a)?" k)"
    case "$method" in
        k|K)
            key="$(unquote_path "$(prompt "Drag the AuthKey_XXXX.p8 file here:")")"
            [[ -f "$key" ]] || die "$key is not a file."
            key_id="$(prompt "Key ID:")"
            issuer="$(prompt "Issuer ID (Return for an individual key):")"
            local -a args=(store-credentials "$profile" --keychain "$KC" --key "$key" --key-id "$key_id")
            [[ -z "$issuer" ]] || args+=(--issuer "$issuer")
            show xcrun notarytool "${args[@]}"
            ask "Store it?" || die "stopping."
            xcrun notarytool "${args[@]}" </dev/tty
            note "notarytool keeps its own copy; store the .p8 in your password manager and delete it from disk." ;;
        a|A)
            apple_id="$(prompt "Apple ID email:")"
            team="$(prompt "Team ID:" "${TEAM:-}")"
            show xcrun notarytool store-credentials "$profile" --keychain "$KC" --apple-id "$apple_id" --team-id "$team"
            note "notarytool asks for the app-specific password itself."
            ask "Store it?" || die "stopping."
            xcrun notarytool store-credentials "$profile" --keychain "$KC" --apple-id "$apple_id" --team-id "$team" </dev/tty ;;
        *) die "choose k or a." ;;
    esac
    xcrun notarytool history --keychain-profile "$profile" --keychain "$KC" >/dev/null 2>&1 \
        || die "the new profile does not work (xcrun notarytool history --keychain-profile $profile --keychain $KC)."
    ok "notarytool profile '$profile' stored in the signing keychain"
    NOTARY_PROFILE="$profile"
}

write_user_env() {
    local content tmp
    content="$(cat <<EOF
# Written by Tools/signing/setup.sh and read by Tools/release/make-dmg.sh. Names and paths only.
: "\${OH_SIGNING_KEYCHAIN=$KC}"
: "\${OH_SIGNING_KEYCHAIN_PASSWORD_FILE=$PWFILE}"
: "\${OH_SIGN_IDENTITY:=${SIGN_HASH:-}}"
: "\${OH_NOTARY_PROFILE:=${NOTARY_PROFILE:-openhuman-notary}}"
EOF
)"
    if [[ -f "$USER_ENV" && "$(cat "$USER_ENV")" == "$content" ]]; then ok "$USER_ENV is current"; return 0; fi
    [[ ! -f "$USER_ENV" ]] || diff -u "$USER_ENV" <(printf '%s\n' "$content") | sed 's/^/         /' || true
    say "release settings for every checkout ($USER_ENV):"
    printf '%s\n' "$content" | sed 's/^/         /'
    would "write them" && return 0
    ask "Write them?" || die "make-dmg.sh would not use the signing keychain; stopping."
    mkdir -p "$(dirname "$USER_ENV")"
    tmp="$(mktemp "$USER_ENV.XXXXXX")"
    printf '%s\n' "$content" >"$tmp"
    mv "$tmp" "$USER_ENV"
    ok "wrote $USER_ENV"
}

unlock_at_login() {
    local content
    content="$(cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$KC_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/bash</string>
		<string>-c</string>
		<string>exec /usr/bin/security unlock-keychain -p "\$(/bin/cat "\$1")" "\$2"</string>
		<string>unlock-signing-keychain</string>
		<string>$(xml_escape "$PWFILE")</string>
		<string>$(xml_escape "$KC")</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>$(xml_escape "$HOME/Library/Logs/openhuman-signing-keychain.log")</string>
</dict>
</plist>
EOF
)"
    say "So that apps on the desktop never ask for the signing keychain's password, a launchd job unlocks it at login."
    install_launch_agent "$KC_LABEL" "$KC_PLIST" "$content" || warn "not installed; the keychain stays locked after a restart until make-dmg.sh unlocks it."
}

setup_builds() {
    step "Build signing and notarization"
    local tool
    for tool in security codesign xcrun plutil; do command -v "$tool" >/dev/null 2>&1 || die "'$tool' is missing. Install Xcode 27 and open it once."; done
    xcrun notarytool --version >/dev/null 2>&1 || die "xcrun cannot find notarytool. Select Xcode with xcode-select."
    [[ "$KC" != *[[:space:]]* ]] || die "your home folder path contains a space; the signing keychain path must not."
    if [[ -f "$USER_ENV" ]]; then
        # shellcheck disable=SC1090
        source "$USER_ENV"
    fi
    make_keychain
    if [[ ! -f "$KC" ]]; then say "dry run: the remaining steps need the keychain."; return 0; fi
    add_to_search_list
    import_identity
    copy_intermediates
    remove_login_duplicate
    setup_notary
    write_user_env
    unlock_at_login
    if [[ "$DRY" == 0 ]]; then
        "$HERE/verify.sh" --builds || die "the build-signing check failed (above)."
    fi
    note "Building with iCloud entitlements? A new certificate must also be in your Developer ID provisioning profile."
}

preflight
if [[ "$DO_COMMITS" == 1 ]]; then setup_commits; fi
if [[ "$DO_BUILDS" == 1 ]]; then setup_builds; fi
step "Done"
if [[ "$DRY" == 1 ]]; then say "dry run: nothing was changed."; exit 0; fi
say "Check from any shell, including an SSH login: Tools/signing/verify.sh"
say "Publishing stays manual: Tools/release/publish-github.sh asks you to confirm in a terminal."
