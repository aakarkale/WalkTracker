# WalkTracker

An iOS app for tracking which streets of a city you have actually walked.

Coverage is recorded block by block against the real street network, so the
percentage means something. Walk half of Bleecker Street and half of it counts.

- **Record a walk** by hand, or let the app start one itself when it notices
  you walking. Automatic recording is off until you turn it on.
- **Watch the map fill in** as blocks turn from grey to green, with the count
  and the percentage always on screen. On the dark map the walked streets are
  drawn as a bright neon line over a faint halo, which is the best-looking
  thing the app does; the theme is its own setting, not tied to the system.
- **See what a walk earned** the moment it ends: new street unlocked, not just
  distance covered.
- **Import what you have already walked** from GPX, so ten years in a city
  does not start at zero.
- **Narrow the target** to the neighbourhoods you care about, because four
  percent of Tokyo is discouraging and forty percent of one neighbourhood is
  a goal.
- **Keep a backup**, because coverage takes a year to build and lives only on
  your phone.

---

## Read this first

Three things about the state of this repository, stated up front because they
change what you should do next.

**It compiles now, but it did not for most of its life.** This was built in a
Linux container with no Swift toolchain, so nothing was ever checked against a
compiler until CI was added. The first CI run found two compile errors across
roughly fifteen thousand lines, and the first test run found twelve failures,
eleven of them real bugs in the backup path. All are fixed. CI builds on macOS
and runs the tests on every push.

**No reference screenshots were received.** The request mentioned attaching
screenshots of an existing app for reference, but none arrived with the
message. The interface here was designed from the described concept alone. If
you still want a specific visual direction matched, send the screenshots.

**No city packs exist yet.** Every city in the catalog has a null pack
descriptor. The app will list all twenty cities and let you download none of
them until you build packs with the pipeline and host them. That is deliberate:
a digest and file size can only come from a real build, and inventing them
would produce a catalog that fails verification on first download.

## What was actually verified

The parts that carry real algorithmic risk were ported to Python and tested,
since the Swift could not be run.

| Area | How it was checked | Result |
|---|---|---|
| Interval merging | Line-for-line Python port, unit cases plus 2000-trial fuzz | Disjoint invariant held, coverage correct |
| Map matching | Python port, simulated walks on an 80 m grid with realistic GPS noise | Precision 0.994 to 1.000, recall 0.997 at 5 to 25 m noise |
| Gzip framing | Header parser checked against real gzip files and 8 malformed inputs | Correct, no crashes |
| GPX parsing | Namespaced and bare GPX, gap splitting, 5 kinds of malformed point | Correct, nothing fatal |
| Pack pipeline | 29 checks on splitting, byte layout, connectivity, malformed input | All pass |
| Pipeline to app | A built pack read by a port of the app's decoder, then walked | 765 of 765 blocks, precision 0.997 |
| Everything else | Not executed | Unverified |

Run it all with `Tools/validation/run_all.sh`.

The matching numbers are from simulation, not from a real walk with a real
phone. Treat them as evidence the algorithm is sound, not as field results.

## How coverage works

The obvious approach is a fog-of-war grid: chop the city into squares and light
them up as you enter them. It was rejected. Most squares in a city are
buildings, water and rooftops you cannot walk on, so "23% of the city" would
mean nothing, and there would be no way to say you had finished a street.

Instead every walkable OpenStreetMap way is split at its intersections into
blocks, and coverage is stored per block as a set of merged intervals along it.
That gives an honest denominator, street names, neighbourhood completion, and a
sensible answer to "what should I walk next".

### Matching GPS to streets

Snapping each fix to the nearest street fails in exactly the cities this app is
for. With 20 m of urban-canyon error and streets 60 m apart, nearest-street
flickers between parallel roads and paints streets nobody walked.

The pipeline instead runs:

1. **Gating.** Drop fixes with bad accuracy, implausible speed, or invalid
   coordinates.
2. **Smoothing.** Average fixes into 8-second buckets. This is the stage that
   matters most. At 1 Hz a walker covers 1.4 m between fixes while error runs
   10 to 25 m, so a single fix says almost nothing about direction. Averaging
   cuts noise by the square root of the sample count while the walker moves far
   enough to establish a heading. Adding it moved precision from 0.67 to 0.99
   in simulation.
3. **Hidden Markov matching.** Each smoothed fix gets candidate blocks scored
   by distance from the block and by how well movement along the network
   matches movement on the ground, with a directional term and a cost for
   turning. A sliding-window Viterbi pass picks the best sequence.
4. **Despeckling.** A one-fix hop onto a side street with the same block either
   side is noise, not a detour, and gets pulled back.

The matcher is deliberately biased toward under-reporting. When it cannot
explain how you got from one fix to the next, it claims nothing. A missing
block is a much smaller harm than a street wrongly marked walked, because the
first is fixed by walking it again and the second is invisible and permanent.

### Why raw traces are kept forever

Coverage is an opinion derived from the trace, the matcher and the pack
version. All three change. Keeping every fix means coverage can be rebuilt,
which is what makes a pack update or a matcher improvement safe rather than
destructive. `CoverageRebuilder` does this, and it runs automatically when a
pack version changes, because segment ids are pack-local and stale ids would
silently credit the wrong streets.

## Interface direction

Light and modern, in the vein of Strava and Nike Run Club. Concretely that
means white backgrounds with soft-shadowed cards rather than grey fills, one
vivid green accent used sparingly, and numbers as the main event: the hero
figure on any screen is very large, rounded and monospaced-digit, with a small
letter-spaced uppercase label beneath it.

Green rather than the warmer accent those two apps use, because on a coverage
map green reads as "done" instantly and nothing else does. It stays inside the
Nike Run Club family rather than departing from it, and it matches the
reference app.

The interaction patterns borrowed from those apps are the ones that actually
fit a coverage app rather than a pace app:

- **A summary when a walk ends**, leading with new street unlocked rather than
  distance walked. Distance is the ordinary number here; new coverage is the
  one that means something.
- **Milestones** at thresholds that thin out as they grow, so early ones build
  momentum and later ones stay rare.
- **A weekly coverage goal**, because on most days the city percentage barely
  moves and a completionist app needs a shorter feedback loop than "0.1% of
  Paris".
- **Auto-pause**, which both apps do and users now expect.
- **Automatic recording**, gated on the pedometer rather than on GPS, so the
  app can notice a walk without being opened and without flattening the
  battery. Off until switched on.
- **Import of existing history** from GPX, which is what Strava, Google
  Timeline and most other tools export.
- **Route thumbnails** in the history list, drawn as lightweight paths rather
  than map snapshots so the list stays scrollable.

What was deliberately not borrowed: the social layer. No feed, no following,
no accounts, no leaderboards against other people. Sharing is a locally
rendered image and nothing more. That follows from the privacy position below
rather than from a lack of ambition, and it is the one place where copying
those apps would undermine the product.

## Privacy and security

Location history is about as sensitive as personal data gets. The decisions
that follow from that:

- **Nothing leaves the device unless you send it.** No account, no analytics,
  no sync, no crash reporting. The only network request the app makes on its
  own is fetching a city pack, which reveals only which city you picked.
  Backup and GPX export write a file and hand it to the share sheet; where it
  goes after that is the user's choice, and iCloud Drive is a normal one. The
  app never uploads anything itself.
- **Backups exist because local-only is otherwise fragile.** Coverage takes a
  year to build and cannot be recreated, so deleting the app or losing the
  phone would destroy it. Keeping data on device while offering no way to keep
  a copy is not a privacy position.
- **Zero third-party dependencies.** Every line that touches location data is
  in this repository. SQLite is wrapped directly, gzip is decoded directly.
- **Data protection** is set to complete-until-first-user-authentication on the
  database and its write-ahead log. Not the stronger complete setting, which
  would make the file unreadable while the screen is locked and break the
  entire point of background tracking. This is the strongest level compatible
  with recording in your pocket.
- **Deletion is real.** Delete runs `VACUUM`, because without it the freed
  pages keep your old coordinates on disk until something happens to overwrite
  them. A backup the user has already exported is outside the app and is not
  reached by this, which the Settings copy says.
- **Packs are not trusted.** Each is verified against a SHA-256 digest that
  ships inside the signed binary, before decompression and before SQLite is
  pointed at it. A compromised or intercepted CDN can serve a wrong file but
  cannot get it opened. Decompression is capped so a small archive cannot
  expand without bound, and packs are opened read-only with every field
  bounds-checked.
- **The background location indicator defaults to on.** An app that records
  where you walk should be visibly recording. It is a preference rather than a
  rule, because the person whose phone it is may have their own reasons for
  not wanting a permanent badge, and overriding that is paternalism rather
  than privacy.
- **Vehicle travel is recorded but never credited**, and the app says so while
  it happens. Otherwise someone who rides a bus along a street they also walk
  concludes it is broken.

## Measured, for once

The only pack ever built here is a synthetic 20 by 20 grid, 765 blocks and
56 km, which compressed to 22 KB. That is about 29 bytes per block. A city
with 50,000 blocks would be roughly 1.5 MB. Treat it as a lower bound: the
fixture has short street names and no districts.

Everything else about performance, battery above all, is unmeasured.

## The twenty cities

New York, Paris, Barcelona, Amsterdam, Tokyo, London, Hong Kong, Copenhagen,
Vienna, Prague, Boston, San Francisco, Florence, Venice, Lisbon, Berlin,
Madrid, Singapore, Seoul, Montreal.

This is a curated list, not a citation. There is no single authoritative
ranking of the world's most walkable cities: published indexes disagree with
each other and use different methodologies, so presenting any list as "the top
twenty" would be dressing up an editorial choice as a fact. Edit
`WalkTracker/Resources/cities.json` to change it. Nothing in the code depends
on which cities are in the list.

Coordinates in the catalog are approximate and frame the opening map view only.
Each city's real boundary comes from its pack.

## Layout

```
WalkTracker/
  App/            app entry point and wiring
  Core/
    Geo/          coordinates, bounding boxes, polylines, geodesy
    Model/        City, StreetSegment, WalkSession, TrackPoint
    Matching/     interval sets, smoothing, the map matcher
    Store/        SQLite wrapper, user database, coverage and session stores
    Location/     CoreLocation and CoreMotion, the tracking engine
    CityPack/     catalog, downloader, gzip, read-only pack access
    Coverage/     statistics and rebuilding
  Features/       SwiftUI screens
  Resources/      cities.json
Tools/citypack/   OpenStreetMap to pack pipeline
Tests/            unit tests
docs/             pack format, build instructions
```

## Getting it running

See `docs/building.md`. In short: install XcodeGen, run `xcodegen generate`,
open the project, set your own bundle identifier and signing team.

The bundle identifier in `project.yml` is the placeholder
`com.example.walktracker` (and `com.example.walktracker.tests` for the test
target). `com.example.` is a reserved example domain: it will not code sign and
will not install on a device, so change it to your own before building for
anything but the simulator.

To get past an empty city list, build a pack with `Tools/citypack` and load
the file straight into the app from the Cities screen. No hosting required,
which is the quickest way to see it working.

To ship packs to other people, host them over HTTPS and paste the descriptor
the pipeline prints into `cities.json`.

## Attribution

Street data comes from OpenStreetMap, © OpenStreetMap contributors, licensed
under the Open Database License. Any build that ships packs must display that
attribution. It is a licence obligation, not a courtesy.
