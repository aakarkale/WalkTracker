# Building WalkTracker

The Xcode project is generated from `project.yml` rather than committed, so the
first build takes one extra step.

Nothing in this repository has been compiled. It was written in a Linux
container with no Swift toolchain and no Xcode, so expect to fix compile errors
on the first build.

## Requirements

- macOS with Xcode 15 or later, which is where the iOS 17 SDK and Swift 5.9
  live. The deployment target is iOS 17.0.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), to turn `project.yml` into
  `WalkTracker.xcodeproj`.
- Python 3.9 or later, only if you are building city packs with
  `Tools/citypack`. The app itself needs nothing beyond Xcode.

There are no third-party Swift dependencies, so there is no package resolution
step and no workspace.

## Generate and open the project

```sh
brew install xcodegen
cd /path/to/WalkTracker
xcodegen generate
open WalkTracker.xcodeproj
```

`xcodegen generate` writes `WalkTracker.xcodeproj` from `project.yml`. The
generated project is in `.gitignore` on purpose: it is a build artefact, and
committing it would mean resolving merge conflicts in a pbxproj nobody reads.

`project.yml` points at directories rather than listing files, so adding a
Swift file anywhere under `WalkTracker/` or `Tests/WalkTrackerTests/` needs no
edit to the spec. Re-run `xcodegen generate` after adding, moving or deleting
files so the project picks them up. Anything you change by hand in the Xcode
project inspector is lost on the next generate, so make build setting changes
in `project.yml` instead.

## Set your own bundle identifier and team

`project.yml` ships with a placeholder identifier:

```
PRODUCT_BUNDLE_IDENTIFIER: com.example.walktracker
```

`com.example.` is a reserved example domain. It will not code sign, it will not
install on a device, and it must be changed before anything is built for a real
device or submitted anywhere. Change it in `project.yml` (both the app target
and the `com.example.walktracker.tests` identifier on the test target), then
re-run `xcodegen generate`.

Signing is set to automatic with no team, so pick your team in Xcode under the
app target's Signing and Capabilities tab, or set `DEVELOPMENT_TEAM` in
`project.yml` if you would rather keep it in the spec.

The simulator will run the app without any of this. A device will not.

## Run the tests

The test target is `WalkTrackerTests`, hosted by the app. Command-U in Xcode,
or:

```sh
xcodebuild test \
  -project WalkTracker.xcodeproj \
  -scheme WalkTracker \
  -destination 'platform=iOS Simulator,name=iPhone 15'
```

Tests run against the Debug configuration because they use
`@testable import WalkTracker`, which needs `ENABLE_TESTABILITY`. Pick any
simulator you have installed; the name above is only an example.

## City packs

The app ships with a catalog of twenty cities and no street data. Every `pack`
field in `WalkTracker/Resources/cities.json` is `null`, so the city list shows
all twenty and offers no downloads. That is deliberate: a pack descriptor
carries a SHA-256 digest and a file size, both of which can only come from a
real build, and inventing them would produce a catalog that fails verification
the first time a download is attempted.

To make downloads work:

1. Build a pack from an OpenStreetMap extract with `Tools/citypack` (see
   `Tools/citypack/README.md` and `docs/city-pack-format.md`).
2. Host the resulting `<city-id>.v<version>.sqlite.gz` over HTTPS. Plain HTTP
   is rejected when the catalog is decoded, not later at download time.
3. Point `packBaseURL` in `cities.json` at where you hosted it, and paste the
   descriptor the build printed into that city's `pack` field.

Until all three are done, the city list is browsable and nothing is
downloadable. Tracking needs an installed pack, because coverage is recorded
against the blocks in it.

## Permissions while testing

Tracking needs location access, and the background mode needs Always. On the
simulator, use Features > Location > City Run or a custom GPX file to generate
movement; the app records nothing while the simulated device is stationary.

Motion activity is only available on a real device. Without it the walking
versus riding gate is skipped rather than failing, so the simulator behaves as
though every fix is on foot.
