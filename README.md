# OpenHuman

OpenHuman is an open-source, clean-room clone of Superhuman.

It is Swift-native, runs locally (including its AI features), and is agent-ready, with a command-line interface for external AI agents.

It has only been tested on Apple silicon, macOS 27, Xcode 27, and Swift 6.4.

This is early software under active development. Unsigned builds and source builds are available now. Signed binary downloads and Homebrew installation will be announced when ready.

## Opening an unsigned build

macOS may block unsigned builds because they are not notarized by Apple. To open one, try to open the app once. Then open System Settings, click Privacy & Security, and scroll to Security. Click Open Anyway, enter your login password, and click OK. The Open Anyway button stays available for about an hour after you first try to open the app.

## Build

```sh
Tools/bootstrap.sh
Tools/ci/build-app.sh
open Apps/Mail/Mail.xcodeproj
```

For the CLI:

```sh
cd Packages/OpenHumanCLI
swift build -c release --product openhuman
.build/release/openhuman --help
```

See [Build and test](docs/BUILD.md), [CLI documentation](docs/cli/README.md),
and [Contributing](CONTRIBUTING.md). First-launch onboarding explains how to
create and import your own Google Desktop OAuth client. Mail and settings are stored locally on your Mac. Sign-in credentials are kept in your Keychain.

## Source layout

| Directory | Contents |
| --- | --- |
| `Apps/Mail/` | macOS application, XcodeGen project, and application tests |
| `Packages/` | Shared Swift packages, mail storage and sync, UI, AI, and CLI |
| `Tools/ci/` | Build, test, packaging, and architecture checks |
| `Tools/release/` | Versioning, Developer ID signing, notarization, and DMG tooling |
| `docs/cli/` | CLI user guide, agent guide, and JSON schema |
| `skills/openhuman-mail/` | Agent integration for the local CLI |

## License

[Apache License 2.0](LICENSE).
