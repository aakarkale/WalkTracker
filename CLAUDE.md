# Working agreement for this repository

## Landing changes

Standing instruction from the repository owner: commit and merge changes
without waiting to be asked. In practice that means work on the assigned
branch, open a pull request, and merge it once the checks pass, rather than
leaving it open for review.

One condition attached to that, because it is what makes the rest safe:
**do not merge with the checks red or unrun.** Auto-merge without checks is
not speed, it is just shipping unread code to `main`. The workflow in
`.github/workflows/ci.yml` is the gate.

Still worth pausing for, even under auto-merge:

- Deleting or overwriting the user's data, or anything that changes what
  the app stores about someone's location.
- A change to the privacy posture: anything that sends data off the device,
  adds an account, or weakens the pack verification.
- Rewriting published history, force-pushing, or changing repository
  settings.
- A genuine change of scope rather than a continuation of the current work.

## What the checks actually cover

`Tools/validation/run_all.sh` runs on Linux and covers the algorithms:
interval merging, map matching accuracy, the pack pipeline, the geometry and
gzip codecs, GPX parsing, and an end to end pass where a built pack is read
back by a port of the app's own decoder. It does not compile Swift.

The macOS job does compile, and runs the XCTest suite. That job is the only
thing in this project that has ever put a compiler near the Swift, so treat
its first red run as information rather than a setback.

## Conventions

- **No third-party dependencies.** Not in Swift, not in the Python tooling.
  This app holds a detailed record of where someone walks, and every
  dependency is code with access to that which nobody here has read. SQLite
  is wrapped directly and gzip is coded by hand for that reason.
- **No em-dashes** anywhere: code, comments, documentation or user-facing
  strings.
- **Comment the why, not the what.** Most of the non-obvious code here has a
  reason recorded above it, and those reasons are the useful part.
- **User-facing strings** go through `String(localized:)`.
- **Persisted numbers** are formatted with an explicit POSIX locale. A device
  set to a comma decimal separator would otherwise write values that cannot
  be parsed back.
- **Core knows nothing about SwiftUI.** The engine is testable on its own and
  should stay that way.

## Things that are load-bearing and easy to break

- **Coverage is derived, traces are the source of truth.** Never discard raw
  points. Coverage can always be rebuilt from them, which is what makes pack
  updates and matcher changes safe.
- **Segment ids are pack-local.** Coverage carried across a pack version
  change credits the wrong streets. `CoverageRebuilder` exists for this.
- **The matcher under-reports on purpose.** A missing block is fixed by
  walking it again; a wrongly credited block is invisible and permanent. If a
  change trades precision for recall, say so explicitly.
- **Pre-smoothing is what makes matching work,** not the probability weights.
  Removing it took precision from 0.99 to 0.67 in simulation.
- **Packs are untrusted input.** They arrive over the network and are parsed
  on a hot path. Keep the digest check, the size caps and the bounds checks.

## Where things are

`WalkTracker/Core` is the engine, `WalkTracker/Features` the SwiftUI screens,
`Tools/citypack` the OpenStreetMap pipeline, `Tools/validation` the Python
ports used to test the algorithms. `docs/decisions.md` records the design
choices and what each one costs; read it before reversing one.
