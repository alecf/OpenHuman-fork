# Build for iOS

The shared packages in `Packages/` also compile for iOS 27, and `Apps/MailiOS` is the
iPhone app built on them. The iPhone app shows sample mail only for now: signing in to
Gmail on the phone comes later.

## The iPhone app

```sh
Tools/ci/build-ios-app.sh
Tools/ci/build-ios-app.sh --test
Tools/ci/build-ios-app.sh --configuration Release --check-flavour
```

The script generates `Apps/MailiOS/MailiOS.xcodeproj` from `Apps/MailiOS/project.yml`
with the pinned XcodeGen and builds for the iOS Simulator (iPhone only, iOS 27).
`--test` runs `MailiOSTests` hosted in the app on a simulator. The project has the same
three configurations as the Mac app. Debug and DevTools builds open sample mail with
`-UseFakeData` (the fake mail store), `-UseFixtureStore` (the real mail store, seeded) or
`-UseFakeGmail` (the sync engine against an in-process fake Gmail); under tests the app
opens sample mail too. A Release build contains none of these and says that Gmail on
iPhone comes later. `--check-flavour` fails a Release build that still carries a
sample-data launch argument or developer switch.

`Tools/render-ios.sh --app <OpenHumanMail.app> --out <folder>` saves screenshots of the
main screens in light and dark from a Debug build, for a visual check.

A booted simulator keeps its data on the startup disk and grows to about 3 GB within
minutes, mostly system data it downloads after it boots. Check the free space before a
test or render run, and erase the simulator afterwards (`xcrun simctl erase <id>`).

## Compile the packages for iOS

This check keeps the shared code building for iOS while the Mac app changes.
It only compiles. It runs no tests and starts no simulator.

### Requirements

- Xcode 27 with the iOS 27 platform. Check that the iOS Simulator SDK is installed:

  ```sh
  xcrun --sdk iphonesimulator --show-sdk-path
  ```

  If that fails, install the platform with `xcodebuild -downloadPlatform iOS`, or in
  Xcode › Settings › Components.
- The Metal toolchain, as for the Mac build (MLX compiles Metal shaders).

### Run

```sh
Tools/ci/build-packages.sh --platform ios
Tools/ci/build-packages.sh --platform ios OpenHumanMailUI OpenHumanStore
```

For each library product, the script runs
`xcodebuild build -scheme <product> -destination 'generic/platform=iOS Simulator'`
in the product's package. The last line says whether everything compiled; failed
products are listed after `FAILED:`. xcodebuild may print "the following command
failed with exit code 0" for a step that only printed warnings; that line is not a
failure.

Derived data goes to `build/ios-dd/<Package>`, or to `$OH_SCRATCH_ROOT/ios-dd/<Package>`
when `OH_SCRATCH_ROOT` is set. The compilation cache is the same one the app build
uses (`OH_COMPILATION_CACHE_PATH`, default `~/Library/Caches/OpenHuman/compilation-cache`).
The first run compiles every dependency, MLX included, and takes several minutes;
later runs rebuild only what changed. Derived data for all packages takes about 7 GB.
Delete the folder to reset it.

### What it skips

| Skipped | Why |
|---|---|
| `OpenHumanCLI` | The command-line tool is macOS only and its package does not declare iOS. |
| `MailUIMac` | Mac window, menu and AppKit views. |
| `OpenHumanAIAgentCLI` | Runs assistants as child processes; iOS has no `Process`. `OpenHumanAIApple` links it on macOS only. |
| Executables (`ohstore-helper`, `gmail-fixture-recorder`) | Developer tools that run on a Mac. |
| Test targets | The package tests run on macOS. |

### Keeping code building for iOS

- Put macOS-only code (AppKit, `NSEvent`, `NSPasteboard`, `Process`) inside
  `#if os(macOS)`.
- SwiftUI styles that exist only on macOS have helpers in
  `Packages/OpenHumanMailUI/Sources/MailUI/Support/PlatformStyles.swift`. Use
  `ohLinkButtonStyle()`, `ohCheckboxToggleStyle()`, `ohRadioGroupPickerStyle()` and
  `ohBorderlessMenuStyle()` instead of `.buttonStyle(.link)`, `.toggleStyle(.checkbox)`,
  `.pickerStyle(.radioGroup)` and `.menuStyle(.borderlessButton)`. On macOS they apply
  the same style; on iOS they use the nearest equivalent or the default style.
- Every package except `OpenHumanCLI` declares `.iOS(.v27)`, and
  `Tools/ci/check-imports.sh` checks the declaration.
