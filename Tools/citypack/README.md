# City pack builder

Turns an OpenStreetMap extract into a WalkTracker city pack: one gzipped
SQLite file holding a city's walkable street network, split into one row per
block. The output format is defined by [`docs/city-pack-format.md`](../../docs/city-pack-format.md),
which is authoritative. If this tool and that document ever disagree, the
document wins.

## Status of this code

**The pipeline has been validated only against the synthetic fixture in
`make_fixture.py`.** It has never been run on real OpenStreetMap data, because
the environment it was written in blocks outbound access to `overpass-api.de`
and `download.geofabrik.de` (both return HTTP 403 at the proxy). The fixture
is thorough about the things that are easy to get wrong (multi block way
splitting, interior vertices, exclusions, self touching ways, malformed
input), but a fixture is a fixture.

Before shipping a pack built by this tool, run a real extract through it and
check the output by hand. Specifically:

* Compare the segment count and total length against a known figure for the
  city. A city centre extract that yields ten thousand blocks is plausible; one
  that yields two hundred means the filter threw away something it should have
  kept.
* Open the pack and eyeball a few streets you know. A long avenue should be
  many rows sharing one `way_id`, each running between two real intersections.
* Watch the skip counters printed on stderr. Real extracts always have some
  dangling node refs where the bounding box cut them, which is normal. A
  sudden jump from run to run is not.

## Requirements

Python 3.11, standard library only. No shapely, no osmium, no numpy, no
rtree, nothing to install. That is deliberate: pack builds should work on a
plain checkout with no compiled extensions.

## Getting an extract

This tool reads **OSM XML**, plain or gzipped (`.osm`, `.osm.gz`). It does not
read the binary `.osm.pbf` format, so a Geofabrik download needs one
conversion step first.

### Option A: Overpass API (good for one city)

Overpass returns XML directly and lets you ask only for the ways you want,
which keeps the download to a sensible size. Query for walkable highways in a
bounding box:

```bash
read -r -d '' QUERY <<'EOQ'
[out:xml][timeout:900];
(
  way["highway"~"^(footway|pedestrian|living_street|residential|unclassified|tertiary|tertiary_link|secondary|secondary_link|primary|primary_link|service|track|steps|path)$"]
    (52.3400,4.8200,52.4000,4.9500);
);
(._;>;);
out body;
EOQ

curl -G https://overpass-api.de/api/interpreter \
  --data-urlencode "data=$QUERY" \
  -o amsterdam.osm
gzip amsterdam.osm
```

The bounding box is `(south,west,north,east)`. The `(._;>;)` line is the part
people forget: it pulls in the nodes the matched ways reference. Without it
every way arrives with dangling refs and the pack comes out empty.

Overpass is a shared free service. Use it for one city at a time, respect the
timeout, and switch to Geofabrik for anything larger.

### Option B: Geofabrik regional extract (good for a whole region)

Geofabrik publishes daily regional extracts as `.osm.pbf`. Download the
smallest region that contains your city, filter it down, then convert to XML
with [osmium-tool](https://osmcode.org/osmium-tool/) (a separate command line
program, not a Python package):

```bash
curl -O https://download.geofabrik.de/europe/netherlands/noord-holland-latest.osm.pbf

# Keep only ways with a highway tag, and the nodes they need.
osmium tags-filter noord-holland-latest.osm.pbf w/highway \
  -o noord-holland-highways.osm.pbf

# Cut down to the city.
osmium extract --bbox 4.82,52.34,4.95,52.40 \
  noord-holland-highways.osm.pbf -o amsterdam.osm.pbf

# Convert to the XML this tool reads.
osmium cat amsterdam.osm.pbf -o amsterdam.osm.gz
```

Note the date of the extract you used: it belongs in `--osm-extract` so the
pack can carry its own attribution.

## Worked example: Amsterdam

```bash
cd Tools/citypack

python3 build_pack.py ~/osm/amsterdam.osm.gz \
  --city-id amsterdam \
  --city-name "Amsterdam" \
  --version 1 \
  --districts ~/osm/amsterdam-districts.geojson \
  --out-dir ~/packs \
  --osm-extract "Geofabrik noord-holland, 2026-09-18" \
  --remove-uncompressed
```

Progress and skip counts go to stderr. stdout is a single JSON object, which
is a `City.PackDescriptor` and can be pasted straight into the app's city
catalog:

```json
{
  "version": 1,
  "path": "amsterdam.v1.sqlite.gz",
  "sha256": "4f1c...",
  "compressedBytes": 8123456,
  "segmentCount": 41207,
  "totalLengthMetres": 3284915.2
}
```

Because stdout is nothing but that object, it pipes:

```bash
python3 build_pack.py ... --quiet > amsterdam-pack.json
```

## Options

| flag | meaning |
|---|---|
| `--city-id` | catalog slug, also the output filename stem |
| `--city-name` | display name stored in `meta.city_name` |
| `--version` | pack version, bumped on every rebuild (default 1) |
| `--out-dir` | where to write the pack (default `.`) |
| `--districts` | optional GeoJSON of named polygons |
| `--min-segment-length` | drop split segments below this many metres (default 3) |
| `--osm-extract` | attribution string for `meta.osm_extract` |
| `--built-at` | pin the build timestamp to make a build reproducible |
| `--remove-uncompressed` | delete the intermediate `.sqlite` and keep only the `.gz` |
| `--quiet` | silence the stderr report |

Run `python3 build_pack.py --help` for the full text.

Builds are reproducible: with `--built-at` pinned, the same extract produces a
byte identical `.gz` and therefore the same SHA-256. Ways are processed in
ascending id order and the gzip header carries no timestamp, both for that
reason.

## Districts file

Optional. A GeoJSON `FeatureCollection` of `Polygon` or `MultiPolygon`
features, each with a name in `properties.name` (`Name`, `NAME`, `district`,
`neighbourhood` and `title` are also accepted). Holes are honoured.

Each segment is assigned the district containing the point half way **along**
the segment, tested by ray casting. The half length point is used rather than
the average of the vertices because a bent block's vertex average can fall off
the street and into the wrong neighbourhood. Segments outside every polygon
get a NULL `district_id`, which is fine: the app treats district as optional.

Without `--districts`, `district_id` is NULL on every row and the `district`
table is empty.

## What the builder does

**Way selection** follows the spec. Included by default: `footway`,
`pedestrian`, `living` (from `highway=living_street`), `residential`,
`unclassified`, `tertiary`, `secondary`, `primary`. Included but kept out of
the headline percentage: `service`, `track`, `steps`, `path`. Never included:
motorways, trunk roads, anything tagged `foot=no` or `access=private`, and any
`highway` value that is not one of the `WayClass` cases the app knows. The
`_link` ramps map to their parent class.

**Splitting** is the reason this tool exists. An OSM way is an editing
convenience that can run for thirty blocks; the app needs one row per block so
it can say "8 of the 12 blocks of Bleecker Street" and so the matcher has a
graph whose nodes are real intersections. Every retained way is cut at its two
endpoints and at every node referenced more than once across all retained
ways. Two details matter:

* Only **retained** ways are counted. A residential street crossing a motorway
  at grade must not be split there, because the motorway is not in the pack.
* Repeat visits by the **same** way count separately, so a way that touches its
  own path is split at that junction.

A node referenced only once is an interior shape point, a bend in the road. It
stays inside the segment geometry and is never a cut.

**Lengths** are planar, equirectangular about each segment's first point, with
earth radius 6371008.8 m:

```
x = (lon - lon0) * R * pi/180 * cos(lat0 * pi/180)
y = (lat - lat0) * R * pi/180
```

This is exactly what `GeoMath.project` and `Polyline` do on the Swift side.
The two must agree, or stored lengths will not match the lengths the matcher
computes at run time.

**`meta.total_length_m`** is the sum over default included classes only, per
the spec, so it is the denominator of the completion percentage. `segment_count`
counts every row, optional classes included. The `district` table follows the
same convention: `segment_count` counts all of a district's segments while
`total_length_m` covers the default classes only.

**Malformed input** is skipped and counted, never fatal. Dangling node refs,
consecutive duplicate nodes, ways left with fewer than two usable nodes, and
nodes with NaN or out of range coordinates are all handled, and the totals are
printed at the end of the run. A truncated or non XML file is a hard error,
because that is a broken download rather than a few bad rows.

## Files

| file | what it is |
|---|---|
| `osm.py` | streaming OSM XML reader, gzip transparent, bounded memory |
| `build_pack.py` | the builder; also importable as a module |
| `make_fixture.py` | synthetic OSM fixture generator plus matching districts |
| `test_pipeline.py` | the checks, no pytest needed |

## Tests

```bash
python3 test_pipeline.py
python3 test_pipeline.py --rows 8 --cols 11   # same checks, different grid
```

One PASS or FAIL line per check, non zero exit on failure. The suite builds a
fixture whose correct answer is known by construction and asserts, among other
things: that a way spanning N blocks yields exactly N segments; that an
interior non intersection vertex is not split at and survives in the geometry;
that excluded ways yield nothing; that the geometry blob round trips; that
lengths agree with an independent haversine calculation to within 0.5%; that
every segment has an r-tree row whose box really contains it; that the graph
is connected and shares node ids at intersections; that districts are assigned
correctly; and that the `meta` totals agree with the `segment` table.

To look at a fixture by hand:

```bash
python3 make_fixture.py --out /tmp/fixture.osm --districts-out /tmp/districts.geojson
python3 build_pack.py /tmp/fixture.osm --city-id testville --city-name Testville \
  --districts /tmp/districts.geojson --out-dir /tmp
sqlite3 /tmp/testville.v1.sqlite "SELECT id, way_id, name, class, length_m FROM segment LIMIT 10;"
```

## Attribution

Packs built from OpenStreetMap data are derived works. Any app shipping them
must display:

> © OpenStreetMap contributors, available under the Open Database License (ODbL).

This is a licence obligation, not a courtesy. The source extract and its date
are recorded in `meta.osm_extract` so a shipped pack can always say where it
came from.
