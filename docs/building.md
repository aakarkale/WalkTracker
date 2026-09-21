# Building WalkTracker

The Xcode project is generated from `project.yml` rather than committed, so the
first build takes one extra step.

This was written in a Linux container with no Swift toolchain, so for most of
its life none of it had been compiled. That is no longer true: CI now builds
it on a macOS runner and runs the test suite on every push, and the first run
found exactly two compile errors across roughly fifteen thousand lines, both
since fixed. See `.github/workflows/ci.yml`.

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

### Building a pack

One command, which downloads the street data and builds the pack:

```sh
cd Tools/citypack
./fetch_and_build.sh manhattan
```

`./fetch_and_build.sh --list` shows the presets. Start with Manhattan: it is
the smallest useful piece of New York and takes a couple of minutes. All five
boroughs is a much larger query and the public Overpass servers may refuse it.

Presets carry the catalog city id, so the Manhattan preset builds
`new-york.v1.sqlite.gz` and installs against New York. That matters because
the app checks a pack's city against the one you picked it for, and a pack
built under an id the catalog has never heard of is refused on install.

Any area works with a bounding box, given as south, west, north, east. The
first argument is the catalog city id, which must already exist in
`WalkTracker/Resources/cities.json`:

```sh
./fetch_and_build.sh lisbon "Lisbon" 38.69 -9.23 38.80 -9.09
```

The script uses the Overpass API rather than a Geofabrik extract, because
Overpass returns OSM XML and that is what the builder reads. Geofabrik serves
PBF, which would need osmium or osmconvert in between.

### Trying a pack without hosting anything

For a local look, you do not need a server at all. Build a pack, then load the
file straight into the app:

1. Build one as above.
2. Run the app, open Cities, and tap the city. Every city is currently under
   "Not yet available", and tapping one opens a file picker. On the simulator,
   drag the `.sqlite.gz` into it first so Files can see it.
3. The pack installs and that city becomes trackable.

The app checks that the file decompresses, opens as a pack of a schema it
understands, and carries the city you picked it for. What it cannot check is a
published digest, because the catalog has none for a city whose pack has not
been built. A side-loaded pack is trusted because you chose it, and it is
stored under a different filename so a glance at the packs directory says
which packs were verified and which were taken on your word.

### Publishing packs properly

To make downloads work:

1. Build a pack from an OpenStreetMap extract with `Tools/citypack` (see
   `Tools/citypack/README.md` and `docs/city-pack-format.md`).
2. Host the resulting `<city-id>.v<version>.sqlite.gz` over HTTPS. Plain HTTP
   is rejected when the catalog is decoded, not later at download time.
3. Point `packBaseURL` in `cities.json` at where you hosted it, and paste the
   descriptor the build printed into that city's `pack` field.

Until all three are done, nothing is downloadable, though a pack can still be
loaded from a file as above. Tracking needs an installed pack either way,
because coverage is recorded against the blocks in it.

## Permissions while testing

Tracking needs location access, and the background mode needs Always. On the
simulator, use Features > Location > City Run or a custom GPX file to generate
movement; the app records nothing while the simulated device is stationary.

Motion activity is only available on a real device. Without it the walking
versus riding gate is skipped rather than failing, so the simulator behaves as
though every fix is on foot.
