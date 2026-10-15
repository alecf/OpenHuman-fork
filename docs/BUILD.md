# Build and test

The application targets Apple silicon and macOS 27. Use Xcode 27 with Swift 6.4
or later; older Swift toolchains cannot parse the package platform declarations.
MLX compiles Metal shaders, which needs Xcode's Metal toolchain component
(`xcodebuild -downloadComponent MetalToolchain` installs it).

Each directory in `Packages/` is an independent SwiftPM package. There is no
root `Package.swift`. Local package dependencies use relative sibling paths.

```sh
xcodebuild -version
xcrun swift --version
Tools/bootstrap.sh
Tools/ci/build-app.sh
```

Bootstrap downloads the pinned, checksum-verified XcodeGen version from
`Tools/versions.env` and generates `Apps/Mail/Mail.xcodeproj`. Generated projects
and downloaded tools are ignored. Local builds use ad-hoc signing by default.
For a development team override, copy
`Apps/Mail/Config/Local.xcconfig.example` to `Local.xcconfig` and edit that local
file. Do not commit signing credentials or OAuth clients.

Open the generated project in Xcode and run the `Mail` scheme. Use `-UseFakeData`
for UI fixtures, or `-UseFakeGmail` for the fake mail backend. First-launch
onboarding explains Google client setup for a real account.

```sh
Tools/ci/check-imports.sh
python3 -B Tools/ci/check-test-patterns.py
Tools/ci/build-all.sh
Tools/ci/test-all.sh
xcodebuild test -skipPackageUpdates -project Apps/Mail/Mail.xcodeproj -scheme Mail \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
```

For a focused loop, run `swift test` inside the package you changed.
`Tools/ThemeCodegen/run.sh --check` verifies generated theme sources.
`Tools/render-sweep.sh --help` describes rendering the UI against fake data.
Tests must use fixtures rather than real mail accounts.

CI runs these same build and test scripts on GitHub's `xcode-27` Apple silicon
runner with a released Xcode (27.0), never the newest installed beta, and installs
the Metal toolchain component when the runner lacks it (MLX compiles Metal
shaders). The repository variables `MACOS_RUNNER_LABEL`, `XCODE_APP` and
`XCODE_VERSION` can select another compatible runner or Xcode. Missing toolchains
and failed checks fail the job.

The project also generates from a source archive without Git metadata (for
example GitHub's Download ZIP); only the build's commit stamp needs Git.

Builds use Xcode's compilation cache, stored in
`~/Library/Caches/OpenHuman/compilation-cache` (override with `OH_COMPILATION_CACHE_PATH`), outside
derived data, so deleting derived data keeps it. It grows to a few GB; delete the folder to reset it.
Hits are per checkout path: another worktree does not reuse them, even with prefix mapping enabled.

Local build output is under `build/`; the app product is
`build/dd/Build/Products/Release/OpenHumanMail.app`. Release signing and binary
distribution are described in [the release guide](release/RELEASE-HOWTO.md).
