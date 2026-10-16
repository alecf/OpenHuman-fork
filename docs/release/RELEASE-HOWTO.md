# Releasing OpenHuman Mail

Build each distributed binary from a clean public source commit. Keep the
source and build scripts in Git. Publish the compiled DMG, its SHA-256 file and
its `release-info.txt` as release assets. Do not commit archives, credentials,
or compiled binaries.

There are two ways to make a release:

- **Unsigned.** An ad-hoc signed DMG that is not notarized. It needs no Apple
  Developer account, and macOS blocks it at first open until the person allows
  it in System Settings. Use it until signed builds exist.
- **Signed.** Developer ID signing, hardened runtime, notarization and
  stapling. A successful dry run does not establish that a binary has been
  signed or notarized.

## Every release is an early development build

`Apps/Mail/Config/Version.xcconfig` holds the version (`MARKETING_VERSION`,
three numbers) and the release channel (`OH_RELEASE_CHANNEL = early-development`).

```sh
Tools/release/bump-version.sh            # 0.1.0
Tools/release/bump-version.sh --label    # 0.1.0 (early development)
Tools/release/bump-version.sh patch      # raise the version, keep the channel
```

The channel reaches the app's Info.plist as `OHReleaseChannel`. About and
Settings show "Early development build — expect rough edges. Please send
feedback." under the version. `make-dmg.sh` records `channel`, `label` and
`prerelease=yes` in `release-info.txt` and starts a `release-notes.md` that
begins with the same notice. The DMG keeps its name,
`OpenHuman-Mail-<version>.dmg`.

`check-release.sh` fails a build whose Info.plist, `release-info.txt` or
release notes lack the marker, and a GitHub release that is not a pre-release
or whose title lacks "(early development)":

```sh
Tools/release/check-release.sh build/release/OpenHuman-Mail-0.1.0-1001-unsigned/release-info.txt
Tools/release/check-release.sh --github-release v0.1.0
```

Releases use the tag `v<version>`.

## How the app sees a new release

Check for Updates… (in the app menu, Settings › General and the command
palette) reads the releases of `michaelmagan/OpenHuman` from GitHub's public
API (`UpdateFeed.openHuman` in
`Packages/OpenHumanMailCore/Sources/MailFeatures/System/Updates/UpdateFeed.swift`)
and compares the newest tag with the running version and build. It sends one
GET request, only when someone clicks, with no account data, and never
downloads or installs anything: Download opens the release page in the
browser. Drafts are ignored, so a release is seen once it is published. While
the repository has no published release, or cannot be read without signing in,
the app says it couldn't check yet.

## Unsigned release

From your Mac, on a clean checkout of the commit to release:

```sh
Tools/release/publish-github.sh --dry-run 0.1.0   # print every command
Tools/release/publish-github.sh 0.1.0
```

`publish-github.sh` builds with `make-dmg.sh --unsigned`, checks the result,
and creates (or updates) the GitHub release for `v0.1.0` as a **draft
pre-release**. It uploads the DMG, its `.sha256` and `release-info.txt`, and
uses `release-notes.md` from the build folder as the notes, which include the
early development notice and the steps for opening an unsigned build. It prints
the release's URL. Review the draft and publish it in the GitHub UI, or pass
`--publish` to publish it from the script. It uses the `gh` command and your
`gh auth login`. It refuses to run when the working tree has changes, when the
version is not the one in `Version.xcconfig`, or when a local `v<version>` tag
names another commit.

To upload a DMG built earlier, finish its `release-notes.md` first:

```sh
Tools/release/make-dmg.sh --unsigned --build-number 1001
Tools/release/publish-github.sh \
  --dmg build/release/OpenHuman-Mail-0.1.0-1001-unsigned/OpenHuman-Mail-0.1.0.dmg 0.1.0
```

The **Unsigned release** workflow (`.github/workflows/release-unsigned.yml`)
does the same on a GitHub macOS runner. Run it from the Actions tab, or push a
`v<version>` tag that matches `Version.xcconfig`. It always leaves a draft.

## Signing setup

Obtain a Developer ID Application certificate through the Apple Developer
Program and install the certificate and private key in your signing Mac's
keychain. Follow [Apple's Developer ID instructions](https://developer.apple.com/developer-id/).
An Apple Development certificate or ad-hoc signature is insufficient for this
distribution path.

Store notarization credentials in the keychain rather than in the repository:

```sh
xcrun notarytool store-credentials openhuman-notary \
  --apple-id you@example.com --team-id YOUR_TEAM_ID
cp Tools/release/release.env.example Tools/release/release.env
```

The command prompts for an app-specific password. The ignored `release.env`
contains profile and identity names and the provisioning profile's path only.
See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## iCloud entitlements

A signed build carries the iCloud entitlements in
`Apps/Mail/Entitlements/Mail-iCloud.entitlements`: CloudKit with the container
`iCloud.dev.openhuman.mail`, push notifications (`production`), the `Production`
iCloud environment and the keychain group `<TEAMID>.dev.openhuman.shared` that the
Mac and iPhone apps share. A Developer ID app may use them only with a
Developer ID provisioning profile that grants them. macOS checks that profile
when the app is installed and at every launch, and an app whose profile is
missing, expired or does not match does not open.

Set up once in the Apple Developer portal (Certificates, Identifiers & Profiles):

1. Register the iCloud container `iCloud.dev.openhuman.mail`.
2. Register the explicit App ID `dev.openhuman.mail` with iCloud (CloudKit, using
   that container) and Push Notifications.
3. Create a Developer ID provisioning profile for that App ID with your Developer
   ID Application certificate, and download it.
4. Keep the file outside the repository and set its path in
   `Tools/release/release.env`:

   ```sh
   : "${OH_PROVISIONING_PROFILE:=$HOME/Documents/OpenHuman_Mail_Developer_ID.provisionprofile}"
   ```

Before it builds anything, `make-dmg.sh` decodes the profile with
`security cms -D -i` and checks that it is a macOS Developer ID profile (it lists
no devices) for your team and App ID, that it has not expired, that it lists the
certificate you sign with, and that it grants every entitlement in
`Mail-iCloud.entitlements` once `$(AppIdentifierPrefix)`, `$(DEVELOPMENT_TEAM)`
and `$(PRODUCT_BUNDLE_IDENTIFIER)` are filled in. It stops and names each
mismatch otherwise. After Xcode exports the app, the script copies the profile to
`Contents/embedded.provisionprofile` and signs the app again with those
entitlements, the hardened runtime and a secure timestamp.

`check-release.sh` fails an app signed with any entitlement that needs a
provisioning profile when the embedded profile is missing or does not grant it,
an app with an entitlement outside its allowed list, nested code that carries
one, an unsigned build that carries one, and an app whose `OHKeychainAccessGroup`
in `Info.plist` is not a keychain group its signature grants.
`make-dmg.sh` passes it `--icloud`, so a signed build that lost these
entitlements fails too.

`make-dmg.sh --no-icloud` signs and notarizes without these entitlements and
without a profile. Unsigned builds never carry them, and Xcode, CI and contributor
builds use the empty `Mail.entitlements` (see [Entitlements](../BUILD.md#entitlements)).
Open the first build signed with a new profile on another Mac before handing it
out: only macOS can tell whether it accepts the profile at launch.

## Signed build

Update the version and commit it before releasing:

```sh
Tools/release/bump-version.sh patch
# Review, test, and commit the version change.
Tools/release/make-dmg.sh --dry-run --build-number 1001
Tools/release/make-dmg.sh --build-number 1001
```

Choose a build number greater than all previously distributed builds. Set it
explicitly when changing repositories or CI systems. A fresh repository's
commit count starts over. Run signing in a shell that can access the signing
keychain. Credentials stay on that machine. The script sends the app and DMG
to Apple's notary service. The script does not publish or push.

The output directory is
`build/release/OpenHuman-Mail-<version>-<build>/`. It contains the DMG, checksum,
archive, logs, `release-info.txt` and `release-notes.md`. The DMG contains
`OpenHuman Mail.app` and an Applications shortcut.

```sh
Tools/release/check-release.sh build/release/OpenHuman-Mail-0.1.0-1001/OpenHuman-Mail-0.1.0.dmg
```

Verify browser download, checksum, Gatekeeper acceptance, sign-in, relaunch,
message rendering, and the features affected by the change on another Mac or
user account. The app and DMG must retain their signatures and stapled tickets.
Users import their own Google client. Release builds must not embed a client.

`check-release.sh` also searches every file in the app for the sample-data
launch arguments and developer variables that only Debug and DevTools builds
compile (see [Build flavours](../BUILD.md#build-flavours)). A DevTools build fails
this check by design; hand out Release builds only.

Finish `release-notes.md` (requirements, changes, known limitations, the Google
client setup step), keeping its first lines, then upload it as a draft
pre-release:

```sh
Tools/release/publish-github.sh \
  --dmg build/release/OpenHuman-Mail-0.1.0-1001/OpenHuman-Mail-0.1.0.dmg 0.1.0
```

CI's ad-hoc signed ZIP artifacts are development builds.

## Homebrew

Start with a tap named `homebrew-openhuman`. Generate its
`Casks/openhuman-mail.rb` from the final signed DMG:

```sh
python3 Tools/release/make-cask.py --repository michaelmagan/OpenHuman \
  --version 0.1.0 \
  --dmg build/release/OpenHuman-Mail-0.1.0-1001/OpenHuman-Mail-0.1.0.dmg \
  --output /path/to/homebrew-openhuman/Casks/openhuman-mail.rb
```

The generator accepts only a signed, notarized DMG whose `release-info.txt`
marks it as an early development pre-release. It checks the DMG and that record
using `check-release.sh` and calculates the checksum. The cask's description
and caveats say it is an early development build. Commit that cask in the tap
after publishing the matching GitHub release. Test it with Homebrew's
`brew style`, `brew audit`, and an actual install before announcing:

```sh
brew install --cask michaelmagan/openhuman/openhuman-mail
```

This command becomes available after the tap and release are published. The
cask installs the app. The CLI can currently be built separately from source.
See the [Homebrew Cask Cookbook](https://docs.brew.sh/Cask-Cookbook).
