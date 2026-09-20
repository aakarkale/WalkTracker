# City pack format

A **city pack** is the street network of one city, precomputed offline and
downloaded by the app on demand. Packs are read-only: nothing the user does is
ever written back into one.

Distributed as `<city-id>.v<version>.sqlite.gz` (gzip), verified against the
SHA-256 in the bundled catalog before it is opened.

## Why a separate file per city

Twenty cities of street geometry is far too large to embed in an app binary,
and most users track one or two cities. Keeping each city in its own SQLite
file means a pack can be downloaded, verified, replaced or deleted as a unit
without touching the user's own data, which lives in a completely separate
database.

## Tables

### `meta`
Single-row key/value table describing the pack.

| key | meaning |
|---|---|
| `schema_version` | integer, currently `1` |
| `city_id` | slug matching the catalog entry |
| `city_name` | display name |
| `built_at` | ISO 8601 build timestamp |
| `osm_extract` | source extract and its date, for attribution |
| `segment_count` | number of rows in `segment` |
| `total_length_m` | sum of `length_m` over default-included classes |
| `min_lat` / `min_lon` / `max_lat` / `max_lon` | pack boundary |

### `segment`
One row per walkable block: a stretch of one OSM way between two intersections.

| column | type | notes |
|---|---|---|
| `id` | INTEGER PRIMARY KEY | pack-local, stable within a version |
| `way_id` | INTEGER | source OSM way, not unique |
| `name` | TEXT NULL | street name |
| `class` | TEXT | one of the `WayClass` cases |
| `start_node` | INTEGER | OSM node id at one end |
| `end_node` | INTEGER | OSM node id at the other end |
| `length_m` | REAL | planar length in metres |
| `district_id` | INTEGER NULL | references `district.id` |
| `geometry` | BLOB | see below |

`start_node` and `end_node` are what make the network a graph. Two blocks are
adjacent when they share one of these, which is how the matcher tells a real
turn from a GPS jump onto a parallel street.

### `segment_rtree`
`CREATE VIRTUAL TABLE segment_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat)`

Bounding boxes in degrees, `id` matching `segment.id`. Every candidate lookup
during matching goes through this index, so it is not optional.

### `district`
Named sub-areas used for the neighbourhood breakdown.

| column | type |
|---|---|
| `id` | INTEGER PRIMARY KEY |
| `name` | TEXT |
| `min_lat` / `min_lon` / `max_lat` / `max_lon` | REAL |
| `segment_count` | INTEGER |
| `total_length_m` | REAL |

## Geometry encoding

`segment.geometry` is a little-endian binary blob:

```
uint16  point_count            (>= 2)
int32   lat_e7[point_count]    latitude  * 1e7, truncated toward zero
int32   lon_e7[point_count]    longitude * 1e7, truncated toward zero
```

Fixed-point at 1e7 gives about 1.1 cm of resolution, far finer than GPS, and
stores a point in 8 bytes against the 40-odd a text encoding would take. Values
are stored absolutely rather than delta-encoded: blocks carry few vertices, so
delta coding saves little and costs a decode branch on the hot path.

## Way selection

Included by default: `footway`, `pedestrian`, `living`, `residential`,
`unclassified`, `tertiary`, `secondary`, `primary`.

Included but excluded from the default percentage: `service`, `track`, `steps`,
`path`. These are alleys, stairs and dirt tracks. Counting them in the
denominator makes a city look unfinishable, so they are shown on the map and
tracked, but the headline figure ignores them unless the user opts in.

Never included: motorways, trunk roads, and anything tagged `foot=no` or
`access=private`. Walking is either illegal or impossible there.

## Attribution

Pack data is derived from OpenStreetMap, © OpenStreetMap contributors,
available under the Open Database License (ODbL). Any app shipping these packs
must display that attribution. This is a licence obligation, not a courtesy.
