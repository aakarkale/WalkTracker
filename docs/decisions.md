# Design decisions

The choices worth arguing about, and what each one costs.

## Street segments, not a fog-of-war grid

**Decision.** Coverage is stored against blocks of the real street network,
split from OpenStreetMap ways at their intersections.

**The alternative.** Divide the city into squares and light them up as you
enter. Far simpler, no data pipeline, works in any city on day one.

**Why it was rejected.** Most squares in a city are buildings, water and
rooftops. A percentage over them is not a fact about anything, so "23% of Paris"
would be a number with no referent. Nor can a grid say you finished a street,
name what you walked, or suggest what to walk next. Those are the product.

**What it costs.** A data pipeline, a per-city download, and map matching, which
is the hardest code in the repository. Cities without good OpenStreetMap
coverage will be worse served.

## Under-report rather than over-report

**Decision.** When the matcher cannot explain how you got from one fix to the
next, it claims nothing.

**Why.** The two errors are not symmetric. A block missed is fixed by walking
it again and you will notice. A block wrongly credited is invisible, permanent,
and quietly corrupts the one number the app exists to produce. Given a choice
the app should be pessimistic.

**What it costs.** Walking through a park, a plaza or an arcade that is not in
the pack yields no credit, and the user cannot tell that from a tracking bug.

## Raw traces kept forever

**Decision.** Every GPS fix is stored permanently. Coverage is derived and
disposable.

**Why.** Coverage is a function of the trace, the matching algorithm and the
pack version. The last two change. Without the trace, a pack update would
either corrupt coverage silently, since segment ids are pack-local, or force
throwing it away. With it, coverage is rebuilt, and improvements to the matcher
apply retroactively to walks already taken.

**What it costs.** Storage, roughly 40 bytes per fix, so about 1.4 MB per 10
hours of walking at 1 Hz. More importantly it is a permanent, detailed record
of someone's movements, which raises the stakes on everything in the privacy
section of the README. That is a real cost and it is the reason the app has no
network sync at all.

## Smoothing before matching

**Decision.** Fixes are averaged into 8-second buckets before the matcher sees
them.

**Why.** At 1 Hz a walker covers 1.4 m between fixes while urban GPS error runs
10 to 25 m. An individual fix carries almost no information about direction.
Averaging cuts noise by the square root of the sample count while the walker
moves far enough to establish a heading.

**Evidence.** On simulated walks over an 80 m grid at 20 m noise, adding this
stage moved precision from 0.67 to 0.99. It was by far the largest single
improvement, well ahead of tuning any probability weight.

**What it costs.** Eight seconds of lag and slightly blurred corners at
intersections. A sharp turn is smeared across one bucket.

## Zero third-party dependencies

**Decision.** No packages at all. SQLite is wrapped directly against the system
library, gzip is decoded by hand.

**Why.** This app holds a detailed record of where someone walks. Every
dependency is code with access to that which nobody on the project has read. A
database wrapper and a decompressor are both small enough to own outright.

**What it costs.** Several hundred lines that a library would have provided,
and the bugs that come with hand-rolled parsing. The gzip decoder in particular
is exactly the kind of code that historically goes wrong, which is why its
framing logic was tested against malformed inputs and why decompressed output
is capped.

## Packs verified against digests in the binary

**Decision.** Each pack's SHA-256 ships in the app. The file is checked before
it is decompressed and before SQLite opens it.

**Why.** Otherwise the content delivery network is fully trusted to serve a
file that the app then parses as a database. Digests in the signed binary mean
a compromised or intercepted CDN can serve the wrong bytes but cannot get them
opened.

**What it costs.** Packs cannot be updated without shipping an app update,
since a new pack means a new digest. A signed manifest fetched at runtime would
lift that, at the price of key management. For twenty cities that rarely change,
shipping digests is the better trade, and it can be revisited.

## Data protection set below the maximum

**Decision.** The database is marked complete-until-first-user-authentication,
not complete.

**Why.** Complete protection makes the file unreadable whenever the screen is
locked. The entire point of this app is recording while the phone is in a
pocket, so complete protection would break it.

**What it costs.** On a device that has been unlocked once since boot, the
database is readable to anything that can reach the app container. It still
protects a powered-off or freshly rebooted device. This is the strongest
setting compatible with the feature, and the tradeoff should be stated to users
rather than buried.

## Motion activity gates coverage

**Decision.** When Core Motion reports driving or cycling, fixes are recorded
but no street is credited.

**Why.** Riding a bus down a street is not walking it, and speed alone cannot
separate the two in traffic, where a bus averages walking pace.

**What it costs.** Another permission to ask for, and the gate is permissive
when Core Motion is unsure, which it often is indoors. A slow crawl in traffic
can still be credited.

## Gate GPS on the pedometer, do not run it continuously

**Decision.** Automatic tracking holds only a significant-change subscription
until the motion coprocessor reports enough steps without a vehicle
classification, and only then starts real positioning.

**Why.** The obvious build keeps GPS running and flattens the battery. The
reference app records walks without being opened and still costs under three
percent of battery a day, which is only possible if the expensive hardware
stays off until something cheap says it is worth turning on. Step counting
runs continuously on a dedicated coprocessor for almost nothing.

**What it costs.** The first stretch of a walk can be missed, because the
gate needs about a minute of steps before it fires. Some coverage at the
start of an automatic walk will be lost that a manual start would have
caught, which is why the manual button stays.

**Still off by default.** An app that starts recording someone's movements
without being asked is not something to opt people into silently, however
good the battery numbers are.

## Import existing history

**Decision.** GPX import, writing through the same matcher as live walks.

**Why.** Someone who has lived in a city for ten years opens this app and
sees 0%. That is discouraging and it is also false. GPX is what almost
everything exports, so their real coverage can be filled in on day one.

**Why through the same pipeline.** If imports took a shortcut, a street
credited from an import and one walked today would mean different things and
the percentage would stop being a single number.

**Not built.** Apple Health import, which is the better source because it
needs no file wrangling. It requires a HealthKit entitlement and usage
strings that could not be verified in this environment, so it is a documented
next step rather than untested code touching health data.

## No social layer

**Decision.** No feed, no accounts, no following, no leaderboards against
other people. Sharing produces an image on the device.

**Why.** The app holds a permanent, detailed record of where someone walks.
Every social feature needs that record, or a summary of it, on a server. A
walking-coverage feed is also uniquely revealing: unlike a run route, city
coverage over months describes where somebody lives, works and shops.

**What it costs.** The strongest growth loop those apps have. A completionist
app with friends in it would spread faster. This is a real cost and it is
accepted rather than overlooked.

**Worth revisiting, and here is the shape.** The reference app has a
leaderboard and manages it without giving up much: the server sees only
aggregate figures, total blocks and distance and walking time, never
coordinates, and there is no sign-up or name unless the user chooses one.
That is a genuinely privacy-preserving design and it is a better answer than
the flat refusal recorded above. It was not built here because it needs a
server, and standing up a backend is a decision for the product owner rather
than something to add quietly. If it is wanted, that aggregate-only shape is
the one to build, and the coverage statistics are already computed in a form
that can be sent without any location data attached.

## Open questions

- **Neighbourhood boundaries.** The pack format supports districts but no
  source is wired up. OpenStreetMap administrative relations are the obvious
  candidate and vary a lot in quality between cities.
- **Pack size.** Unmeasured. No pack has been built, since OpenStreetMap hosts
  were unreachable from the build environment. If packs turn out large enough
  to matter, splitting cities into downloadable districts is the fallback.
- **The completion threshold.** A block counts as done at 70% covered. That
  number is a guess chosen to stop GPS trimming at block ends leaving every
  street at 97% forever. It should be revisited against real traces.
- **Battery.** Continuous GPS is expensive and the cost here is unmeasured.
  Auto-pause now drops to coarse accuracy after two minutes without movement,
  which should help, but nobody has put a meter on it.
- **Milestone thresholds.** The block and distance thresholds are judgement,
  not data. Whether 10 blocks feels like an achievement or a participation
  prize is a question for real users.
