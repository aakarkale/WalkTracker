#!/usr/bin/env python3
"""Build a WalkTracker city pack (SQLite, gzipped) from an OpenStreetMap extract.

The output format is defined by docs/city-pack-format.md, which is the
authoritative spec; this tool exists to produce exactly that and nothing else.

Pipeline, in order:

  1. Pass one over the extract reads *ways only*, keeps the walkable ones and
     records which node ids they need.
  2. Pass two reads *nodes only*, keeping just the ones pass one asked for.
     Two passes rather than one because a city extract holds far more nodes
     than walkable ways touch, and holding all of them would dominate memory.
  3. Way node lists are cleaned: unresolvable refs dropped, consecutive
     duplicates collapsed, ways with fewer than two surviving nodes skipped.
  4. A reference count is built over the cleaned ways, and every way is split
     at its endpoints and at every node that is referenced more than once.
  5. Each resulting block becomes one `segment` row with encoded geometry, a
     planar length, an r-tree bounding box and an optional district.

Everything here is standard library: the build host is assumed to be a plain
checkout with no compiled extensions available.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import gzip
import hashlib
import json
import math
import os
import shutil
import sqlite3
import struct
import sys
from dataclasses import dataclass
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

import osm

# --------------------------------------------------------------------------
# Constants fixed by the spec and by the Swift side
# --------------------------------------------------------------------------

SCHEMA_VERSION = 1

# IUGG mean Earth radius, matching GeoMath.earthRadius in the app. Changing
# this on one side only would make every stored length disagree with the
# lengths the matcher computes at run time.
EARTH_RADIUS_M = 6_371_008.8
DEG_TO_RAD = math.pi / 180.0
METRES_PER_DEGREE_LAT = EARTH_RADIUS_M * DEG_TO_RAD

# OSM `highway` values mapped to WayClass cases (see StreetSegment.swift).
# The `_link` ramps map to their parent class: they are short connectors that
# carry the same footway rules as the road they join, and WayClass has no
# separate case for them.
HIGHWAY_TO_CLASS: Dict[str, str] = {
    "footway": "footway",
    "pedestrian": "pedestrian",
    "living_street": "living",
    "residential": "residential",
    "unclassified": "unclassified",
    "tertiary": "tertiary",
    "tertiary_link": "tertiary",
    "secondary": "secondary",
    "secondary_link": "secondary",
    "primary": "primary",
    "primary_link": "primary",
    "service": "service",
    "track": "track",
    "steps": "steps",
    "path": "path",
}

# Counted in the headline percentage.
DEFAULT_CLASSES = frozenset(
    ("footway", "pedestrian", "living", "residential", "unclassified", "tertiary", "secondary", "primary")
)

# Stored and shown, but kept out of the denominator: alleys, stairs and dirt
# tracks would make a city look unfinishable.
OPTIONAL_CLASSES = frozenset(("service", "track", "steps", "path"))

# Spelled out even though none of them appear in HIGHWAY_TO_CLASS, so that the
# spec's "never included" rule is visible in the code rather than implied by
# an omission someone could later "fix".
NEVER_INCLUDED_HIGHWAY = frozenset(("motorway", "motorway_link", "trunk", "trunk_link"))

# Walking is illegal or impossible on these, whatever the highway value says.
EXCLUDING_TAGS: Tuple[Tuple[str, str], ...] = (("foot", "no"), ("access", "private"))

# uint16 point count in the geometry blob.
MAX_GEOMETRY_POINTS = 65_535

SCHEMA_SQL = """
CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

CREATE TABLE district (
    id             INTEGER PRIMARY KEY,
    name           TEXT NOT NULL,
    min_lat        REAL NOT NULL,
    min_lon        REAL NOT NULL,
    max_lat        REAL NOT NULL,
    max_lon        REAL NOT NULL,
    segment_count  INTEGER NOT NULL,
    total_length_m REAL NOT NULL
);

CREATE TABLE segment (
    id          INTEGER PRIMARY KEY,
    way_id      INTEGER NOT NULL,
    name        TEXT,
    class       TEXT NOT NULL,
    start_node  INTEGER NOT NULL,
    end_node    INTEGER NOT NULL,
    length_m    REAL NOT NULL,
    district_id INTEGER REFERENCES district(id),
    geometry    BLOB NOT NULL
);

CREATE VIRTUAL TABLE segment_rtree USING rtree(id, min_lon, max_lon, min_lat, max_lat);
"""


# --------------------------------------------------------------------------
# Counters
# --------------------------------------------------------------------------


@dataclass
class BuildCounters:
    """Everything skipped along the way, reported at the end of a build.

    Real extracts are always a little broken (a bounding box cut leaves ways
    pointing at nodes that were never sent), so these are expected to be
    non zero. They are printed so an operator can see a *sudden* change.
    """

    ways_not_highway: int = 0
    ways_excluded_class: int = 0
    ways_excluded_tag: int = 0
    ways_retained: int = 0
    way_refs_unresolved: int = 0
    nodes_duplicate_consecutive: int = 0
    ways_too_few_nodes: int = 0
    segments_dropped_short: int = 0
    segments_dropped_oversize: int = 0
    segments_written: int = 0

    def as_dict(self) -> Dict[str, int]:
        return dataclasses.asdict(self)


# --------------------------------------------------------------------------
# Way selection
# --------------------------------------------------------------------------


def classify_way(tags: Dict[str, str]) -> Tuple[Optional[str], str]:
    """Decide whether a way is walkable, and as what class.

    Returns `(class, "")` when kept, or `(None, reason)` when dropped, where
    reason is one of "not_highway", "excluded_class", "excluded_tag".

    The order matters only for which counter a way lands in: a motorway is
    reported as excluded by class even if it also carries foot=no.
    """
    highway = tags.get("highway")
    if highway is None:
        return None, "not_highway"
    if highway in NEVER_INCLUDED_HIGHWAY:
        return None, "excluded_class"
    way_class = HIGHWAY_TO_CLASS.get(highway)
    if way_class is None:
        # Anything not in the map (cycleway, construction, raceway, bus_stop
        # mis-tagged onto a way) is not one of the WayClass cases the app
        # knows, so it cannot be stored even if a pedestrian could use it.
        return None, "excluded_class"
    for key, value in EXCLUDING_TAGS:
        if tags.get(key) == value:
            return None, "excluded_tag"
    return way_class, ""


def way_name(tags: Dict[str, str]) -> Optional[str]:
    """Street name, or None. Empty and whitespace-only names become None so
    the app's `displayName` fallback kicks in rather than showing a blank."""
    name = tags.get("name")
    if name is None:
        return None
    name = name.strip()
    return name or None


# --------------------------------------------------------------------------
# Geometry
# --------------------------------------------------------------------------


def planar_length_m(points: Sequence[Tuple[float, float]]) -> float:
    """Length in metres of a (lat, lon) polyline, equirectangular about its
    first point.

    This must agree with `Polyline.cumulative` on the Swift side, which
    projects every vertex about `coordinates[0]` via `GeoMath.project` and
    sums `hypot`. Same origin, same radius, same formula:

        x = (lon - lon0) * R * pi/180 * cos(lat0 * pi/180)
        y = (lat - lat0) * R * pi/180

    Anchoring at the first point rather than at the city centre is what keeps
    the two sides identical: the app has no idea what the city centre is when
    it measures a single block.
    """
    if len(points) < 2:
        return 0.0
    lat0, lon0 = points[0]
    kx = EARTH_RADIUS_M * DEG_TO_RAD * math.cos(lat0 * DEG_TO_RAD)
    ky = METRES_PER_DEGREE_LAT

    total = 0.0
    prev_x = 0.0
    prev_y = 0.0
    for index, (lat, lon) in enumerate(points):
        x = (lon - lon0) * kx
        y = (lat - lat0) * ky
        if index:
            total += math.hypot(x - prev_x, y - prev_y)
        prev_x = x
        prev_y = y
    return total


def midpoint(points: Sequence[Tuple[float, float]]) -> Tuple[float, float]:
    """The point half way *along* the polyline, not the average of vertices.

    Used for district assignment. A bent block's vertex average can fall off
    the street entirely (and out of the right neighbourhood), whereas the
    half length point is always on the geometry. This mirrors the app's
    `Polyline.coordinate(atFraction: 0.5)`.

    Interpolating latitude and longitude linearly inside the containing span
    is exact here: the projection is affine in lat and lon about a fixed
    origin, so a constant fraction in the plane is the same fraction in
    degrees.
    """
    if not points:
        raise ValueError("midpoint of an empty polyline")
    if len(points) == 1:
        return points[0]

    total = planar_length_m(points)
    if total <= 0.0:
        return points[0]

    target = total / 2.0
    walked = 0.0
    for index in range(1, len(points)):
        span = planar_length_m((points[index - 1], points[index]))
        if walked + span >= target:
            t = (target - walked) / span if span > 0 else 0.0
            lat_a, lon_a = points[index - 1]
            lat_b, lon_b = points[index]
            return (lat_a + t * (lat_b - lat_a), lon_a + t * (lon_b - lon_a))
        walked += span
    return points[-1]


class GeometryTooLong(ValueError):
    """More vertices than the uint16 count in the blob header can express."""


def encode_geometry(points: Sequence[Tuple[float, float]]) -> bytes:
    """Pack a (lat, lon) polyline into the spec's little-endian blob.

        uint16  point_count
        int32   lat_e7[point_count]
        int32   lon_e7[point_count]

    Values are truncated toward zero, which is what `int()` does in Python,
    giving about 1.1 cm of resolution. The two coordinate arrays are stored
    separately rather than interleaved because that is what the spec says and
    what the Swift decoder will read.
    """
    count = len(points)
    if count < 2:
        raise ValueError(f"geometry needs at least 2 points, got {count}")
    if count > MAX_GEOMETRY_POINTS:
        raise GeometryTooLong(f"{count} points exceeds the uint16 header limit")

    blob = bytearray(struct.pack("<H", count))
    blob += struct.pack(f"<{count}i", *(int(lat * 1e7) for lat, _ in points))
    blob += struct.pack(f"<{count}i", *(int(lon * 1e7) for _, lon in points))
    return bytes(blob)


def decode_geometry(blob: bytes) -> List[Tuple[float, float]]:
    """Inverse of `encode_geometry`. Lives here so the encoder and decoder
    cannot drift apart, and so the test suite checks the real format rather
    than its own idea of it."""
    if len(blob) < 2:
        raise ValueError("geometry blob is too short to hold a point count")
    (count,) = struct.unpack_from("<H", blob, 0)
    expected = 2 + 8 * count
    if len(blob) != expected:
        raise ValueError(f"geometry blob is {len(blob)} bytes, expected {expected} for {count} points")
    lats = struct.unpack_from(f"<{count}i", blob, 2)
    lons = struct.unpack_from(f"<{count}i", blob, 2 + 4 * count)
    return [(lats[i] / 1e7, lons[i] / 1e7) for i in range(count)]


# --------------------------------------------------------------------------
# Districts
# --------------------------------------------------------------------------

# A ring is a list of (lon, lat) pairs, in GeoJSON order.
Ring = List[Tuple[float, float]]
# A polygon is an exterior ring followed by zero or more holes.
Polygon = List[Ring]


@dataclass
class District:
    id: int
    name: str
    polygons: List[Polygon]
    min_lat: float
    min_lon: float
    max_lat: float
    max_lon: float
    segment_count: int = 0
    total_length_m: float = 0.0


def point_in_ring(lon: float, lat: float, ring: Ring) -> bool:
    """Ray casting (crossing number) point in polygon for one ring.

    Cast a ray in +lon from the point and count edge crossings; odd means
    inside. Implemented here rather than pulled from shapely because the build
    host has no compiled extensions, and because a city district test is a few
    thousand points against a few dozen rings, so the naive version is fine.

    Edges are treated as half open in latitude (`(y_i > lat) != (y_j > lat)`),
    which is the standard trick that counts a vertex exactly once and keeps a
    point from being reported inside two neighbouring districts at once.
    Points exactly on a boundary are undefined, as they are in every
    implementation of this test; callers that care should not put boundaries
    through the middle of their data.
    """
    inside = False
    count = len(ring)
    if count < 3:
        return False
    j = count - 1
    for i in range(count):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > lat) != (yj > lat):
            # Longitude where edge j->i crosses this latitude.
            crossing = (xj - xi) * (lat - yi) / (yj - yi) + xi
            if lon < crossing:
                inside = not inside
        j = i
    return inside


def point_in_polygon(lon: float, lat: float, polygon: Polygon) -> bool:
    """Inside the exterior ring and outside every hole."""
    if not polygon:
        return False
    if not point_in_ring(lon, lat, polygon[0]):
        return False
    for hole in polygon[1:]:
        if point_in_ring(lon, lat, hole):
            return False
    return True


def district_for_point(lat: float, lon: float, districts: Sequence[District]) -> Optional[District]:
    """First district containing the point, or None.

    The bounding box is checked first: it rejects almost every district for
    almost every segment at a fraction of the cost of the ring walk.
    """
    for district in districts:
        if lat < district.min_lat or lat > district.max_lat:
            continue
        if lon < district.min_lon or lon > district.max_lon:
            continue
        for polygon in district.polygons:
            if point_in_polygon(lon, lat, polygon):
                return district
    return None


def _ring_from_geojson(raw: Iterable) -> Ring:
    ring: Ring = []
    for position in raw:
        if not isinstance(position, (list, tuple)) or len(position) < 2:
            continue
        try:
            lon = float(position[0])
            lat = float(position[1])
        except (TypeError, ValueError):
            continue
        if not osm.is_valid_coordinate(lat, lon):
            continue
        ring.append((lon, lat))
    return ring


def _polygons_from_geometry(geometry: Optional[dict]) -> List[Polygon]:
    """Accept Polygon, MultiPolygon and GeometryCollection; ignore the rest."""
    if not isinstance(geometry, dict):
        return []
    kind = geometry.get("type")
    coordinates = geometry.get("coordinates")

    if kind == "Polygon" and isinstance(coordinates, list):
        rings = [_ring_from_geojson(r) for r in coordinates if isinstance(r, list)]
        rings = [r for r in rings if len(r) >= 3]
        return [rings] if rings else []

    if kind == "MultiPolygon" and isinstance(coordinates, list):
        polygons: List[Polygon] = []
        for raw_polygon in coordinates:
            if not isinstance(raw_polygon, list):
                continue
            rings = [_ring_from_geojson(r) for r in raw_polygon if isinstance(r, list)]
            rings = [r for r in rings if len(r) >= 3]
            if rings:
                polygons.append(rings)
        return polygons

    if kind == "GeometryCollection":
        polygons = []
        for sub in geometry.get("geometries") or []:
            polygons.extend(_polygons_from_geometry(sub))
        return polygons

    return []


def _name_from_feature(feature: dict, fallback_index: int) -> str:
    properties = feature.get("properties")
    if isinstance(properties, dict):
        for key in ("name", "Name", "NAME", "district", "neighbourhood", "neighborhood", "title"):
            value = properties.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    identifier = feature.get("id")
    if isinstance(identifier, str) and identifier.strip():
        return identifier.strip()
    return f"District {fallback_index}"


def load_districts(path: str) -> List[District]:
    """Read named polygons from a GeoJSON file.

    Accepts a FeatureCollection, a single Feature, or a bare geometry.
    Features without usable polygon geometry are skipped rather than failing
    the build: neighbourhood files from open data portals routinely carry a
    stray point or an empty geometry.
    """
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)

    if not isinstance(data, dict):
        raise ValueError(f"{path}: top level GeoJSON value is not an object")

    kind = data.get("type")
    if kind == "FeatureCollection":
        raw_features = data.get("features") or []
    elif kind == "Feature":
        raw_features = [data]
    else:
        raw_features = [{"type": "Feature", "properties": {}, "geometry": data}]

    districts: List[District] = []
    for index, feature in enumerate(raw_features, start=1):
        if not isinstance(feature, dict):
            continue
        polygons = _polygons_from_geometry(feature.get("geometry"))
        if not polygons:
            continue

        lats: List[float] = []
        lons: List[float] = []
        for polygon in polygons:
            for lon, lat in polygon[0]:
                lons.append(lon)
                lats.append(lat)
        if not lats:
            continue

        districts.append(
            District(
                id=len(districts) + 1,
                name=_name_from_feature(feature, index),
                polygons=polygons,
                min_lat=min(lats),
                min_lon=min(lons),
                max_lat=max(lats),
                max_lon=max(lons),
            )
        )
    return districts


# --------------------------------------------------------------------------
# Way cleaning and splitting
# --------------------------------------------------------------------------


@dataclass
class RetainedWay:
    id: int
    way_class: str
    name: Optional[str]
    refs: List[int]


@dataclass
class Segment:
    id: int
    way_id: int
    name: Optional[str]
    way_class: str
    start_node: int
    end_node: int
    length_m: float
    district_id: Optional[int]
    points: List[Tuple[float, float]]


def clean_refs(
    refs: Sequence[int],
    nodes: Dict[int, Tuple[float, float]],
    counters: BuildCounters,
) -> List[int]:
    """Drop refs we have no coordinates for and collapse repeats.

    Dedup runs *after* the drop, so A, missing, A collapses to a single A.
    That is the right order: once the unusable node is gone the two A entries
    really are consecutive, and leaving both would create a zero length span
    in the middle of a block.
    """
    cleaned: List[int] = []
    for ref in refs:
        if ref not in nodes:
            counters.way_refs_unresolved += 1
            continue
        if cleaned and cleaned[-1] == ref:
            counters.nodes_duplicate_consecutive += 1
            continue
        cleaned.append(ref)
    return cleaned


def build_reference_counts(cleaned_ways: Iterable[Tuple[RetainedWay, List[int]]]) -> Dict[int, int]:
    """Count how many times each node is referenced across *retained* ways.

    Two subtleties, both load bearing:

    * Only retained ways are counted. A residential street crossing a motorway
      at grade must not be split there: the motorway is not in the pack, so
      that node is not an intersection as far as this app is concerned.
    * Repeat visits by the same way count separately. A way that touches its
      own path (a lollipop or a figure eight) has a genuine junction at that
      node even though only one way is involved, and a degree computed over
      distinct ways would miss it.
    """
    counts: Dict[int, int] = {}
    for _, node_ids in cleaned_ways:
        for node_id in node_ids:
            counts[node_id] = counts.get(node_id, 0) + 1
    return counts


def split_positions(node_ids: Sequence[int], reference_counts: Dict[int, int]) -> List[int]:
    """Indices at which a way must be cut.

    A cut goes at both endpoints and at every node another retained way also
    uses. This is the whole point of the pipeline: an OSM way is an editing
    convenience that can run for thirty blocks, while the app needs one row
    per block so it can say "8 of the 12 blocks of Bleecker Street" and so the
    matcher has a graph whose nodes are real intersections.

    A node with only one reference is an interior shape point: a bend in the
    road, not a junction. It stays *inside* the segment geometry, and cutting
    there would invent an intersection that does not exist.
    """
    last = len(node_ids) - 1
    positions: List[int] = []
    for index, node_id in enumerate(node_ids):
        if index == 0 or index == last or reference_counts.get(node_id, 0) >= 2:
            positions.append(index)
    return positions


def split_way(node_ids: Sequence[int], reference_counts: Dict[int, int]) -> List[Tuple[int, int]]:
    """Cut a way into (start_index, end_index) spans, one per block.

    Spans share their boundary node with their neighbour, which is exactly
    what makes the result a graph: `segment[i].end_node == segment[i+1].start_node`.
    """
    if len(node_ids) < 2:
        return []
    positions = split_positions(node_ids, reference_counts)
    return [(positions[i], positions[i + 1]) for i in range(len(positions) - 1)]


# --------------------------------------------------------------------------
# Reading the extract
# --------------------------------------------------------------------------


def read_walkable_ways(
    path: str,
    counters: BuildCounters,
    parse_counters: osm.ParseCounters,
) -> Tuple[List[RetainedWay], set]:
    """Pass one: keep the walkable ways and note which nodes they need."""
    retained: List[RetainedWay] = []
    needed: set = set()
    for way in osm.iter_ways(path, counters=parse_counters):
        way_class, reason = classify_way(way.tags)
        if way_class is None:
            if reason == "not_highway":
                counters.ways_not_highway += 1
            elif reason == "excluded_tag":
                counters.ways_excluded_tag += 1
            else:
                counters.ways_excluded_class += 1
            continue
        if len(way.refs) < 2:
            counters.ways_too_few_nodes += 1
            continue
        counters.ways_retained += 1
        retained.append(
            RetainedWay(id=way.id, way_class=way_class, name=way_name(way.tags), refs=list(way.refs))
        )
        needed.update(way.refs)
    return retained, needed


def read_needed_nodes(
    path: str,
    needed: set,
    parse_counters: osm.ParseCounters,
) -> Dict[int, Tuple[float, float]]:
    """Pass two: coordinates for the nodes pass one asked for, and no others."""
    nodes: Dict[int, Tuple[float, float]] = {}
    if not needed:
        return nodes
    for node in osm.iter_nodes(path, counters=parse_counters):
        if node.id in needed:
            nodes[node.id] = (node.lat, node.lon)
    return nodes


# --------------------------------------------------------------------------
# Segment construction
# --------------------------------------------------------------------------


def build_segments(
    retained_ways: List[RetainedWay],
    nodes: Dict[int, Tuple[float, float]],
    counters: BuildCounters,
    min_segment_length_m: float,
    districts: Sequence[District],
) -> List[Segment]:
    """Clean, split and measure every retained way.

    Ways are processed in ascending id order so that segment ids, and
    therefore the SHA-256 of the finished pack, are reproducible for a given
    extract.
    """
    ordered = sorted(retained_ways, key=lambda w: w.id)

    cleaned: List[Tuple[RetainedWay, List[int]]] = []
    for way in ordered:
        node_ids = clean_refs(way.refs, nodes, counters)
        if len(node_ids) < 2:
            # Either the extract was cut through this way or it was a closed
            # loop of one repeated node. Nothing walkable survives. Note that
            # `ways_retained` deliberately keeps counting it: that counter
            # means "passed the tag filter", and this one means "and then had
            # nothing left to build from".
            counters.ways_too_few_nodes += 1
            continue
        cleaned.append((way, node_ids))

    reference_counts = build_reference_counts(cleaned)

    segments: List[Segment] = []
    next_id = 1
    for way, node_ids in cleaned:
        for start_index, end_index in split_way(node_ids, reference_counts):
            piece = node_ids[start_index : end_index + 1]
            points = [nodes[node_id] for node_id in piece]

            length = planar_length_m(points)
            if length < min_segment_length_m:
                # Sub-metre stubs are almost always junction artifacts: a
                # kerb link, a duplicated crossing node, a way that was split
                # one vertex early. They add graph noise and no walkable
                # distance.
                counters.segments_dropped_short += 1
                continue

            if len(points) > MAX_GEOMETRY_POINTS:
                # The blob header counts points in a uint16. Nothing between
                # two real intersections comes close, but a mis-tagged way
                # that never gets split could, and silently truncating it
                # would ship a street that stops in mid air.
                counters.segments_dropped_oversize += 1
                continue

            district_id: Optional[int] = None
            if districts:
                mid_lat, mid_lon = midpoint(points)
                district = district_for_point(mid_lat, mid_lon, districts)
                if district is not None:
                    district_id = district.id
                    district.segment_count += 1
                    if way.way_class in DEFAULT_CLASSES:
                        district.total_length_m += length

            segments.append(
                Segment(
                    id=next_id,
                    way_id=way.id,
                    name=way.name,
                    way_class=way.way_class,
                    start_node=piece[0],
                    end_node=piece[-1],
                    length_m=length,
                    district_id=district_id,
                    points=points,
                )
            )
            next_id += 1
            counters.segments_written += 1

    return segments


# --------------------------------------------------------------------------
# Writing the pack
# --------------------------------------------------------------------------


def _remove_if_present(path: str) -> None:
    for candidate in (path, path + "-wal", path + "-shm", path + "-journal"):
        if os.path.exists(candidate):
            os.remove(candidate)


def write_pack(
    sqlite_path: str,
    segments: Sequence[Segment],
    districts: Sequence[District],
    city_id: str,
    city_name: str,
    osm_extract: str,
    built_at: str,
) -> Tuple[float, Tuple[float, float, float, float]]:
    """Write the SQLite file and return (default-class length, bounds)."""
    _remove_if_present(sqlite_path)

    total_default_length = 0.0
    min_lat = min_lon = math.inf
    max_lat = max_lon = -math.inf

    connection = sqlite3.connect(sqlite_path)
    try:
        # Autocommit: VACUUM and `PRAGMA journal_mode` cannot run inside the
        # transaction Python would otherwise open for us.
        connection.isolation_level = None
        connection.execute("PRAGMA journal_mode=DELETE")
        connection.executescript(SCHEMA_SQL)

        connection.execute("BEGIN")

        segment_rows = []
        rtree_rows = []
        for segment in segments:
            lats = [lat for lat, _ in segment.points]
            lons = [lon for _, lon in segment.points]
            seg_min_lat, seg_max_lat = min(lats), max(lats)
            seg_min_lon, seg_max_lon = min(lons), max(lons)

            min_lat = min(min_lat, seg_min_lat)
            max_lat = max(max_lat, seg_max_lat)
            min_lon = min(min_lon, seg_min_lon)
            max_lon = max(max_lon, seg_max_lon)

            if segment.way_class in DEFAULT_CLASSES:
                total_default_length += segment.length_m

            segment_rows.append(
                (
                    segment.id,
                    segment.way_id,
                    segment.name,
                    segment.way_class,
                    segment.start_node,
                    segment.end_node,
                    segment.length_m,
                    segment.district_id,
                    encode_geometry(segment.points),
                )
            )
            rtree_rows.append((segment.id, seg_min_lon, seg_max_lon, seg_min_lat, seg_max_lat))

        connection.executemany(
            "INSERT INTO segment (id, way_id, name, class, start_node, end_node, length_m, district_id, geometry)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            segment_rows,
        )
        connection.executemany(
            "INSERT INTO segment_rtree (id, min_lon, max_lon, min_lat, max_lat) VALUES (?, ?, ?, ?, ?)",
            rtree_rows,
        )
        connection.executemany(
            "INSERT INTO district (id, name, min_lat, min_lon, max_lat, max_lon, segment_count, total_length_m)"
            " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            [
                (d.id, d.name, d.min_lat, d.min_lon, d.max_lat, d.max_lon, d.segment_count, d.total_length_m)
                for d in districts
            ],
        )

        if not segments:
            min_lat = min_lon = max_lat = max_lon = 0.0

        meta = {
            "schema_version": str(SCHEMA_VERSION),
            "city_id": city_id,
            "city_name": city_name,
            "built_at": built_at,
            "osm_extract": osm_extract,
            "segment_count": str(len(segments)),
            "total_length_m": repr(total_default_length),
            "min_lat": repr(min_lat),
            "min_lon": repr(min_lon),
            "max_lat": repr(max_lat),
            "max_lon": repr(max_lon),
        }
        connection.executemany(
            "INSERT INTO meta (key, value) VALUES (?, ?)", sorted(meta.items())
        )
        connection.execute("COMMIT")

        # VACUUM rewrites the file without free pages; on a freshly built
        # database it mostly recovers what the r-tree left behind. Combined
        # with journal_mode=DELETE it guarantees the shipped file is one file.
        connection.execute("VACUUM")
    finally:
        connection.close()

    return total_default_length, (min_lat, min_lon, max_lat, max_lon)


def gzip_file(source_path: str, target_path: str) -> None:
    """Gzip with a fixed mtime and no stored filename.

    Both are for reproducibility: the catalog records a SHA-256 of this file,
    and rebuilding the same extract twice should produce the same hash rather
    than differing only in a timestamp header.
    """
    with open(source_path, "rb") as source, open(target_path, "wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", compresslevel=9, fileobj=raw, mtime=0) as target:
            shutil.copyfileobj(source, target, 1024 * 1024)


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


# --------------------------------------------------------------------------
# Build entry point
# --------------------------------------------------------------------------


@dataclass
class BuildResult:
    sqlite_path: str
    gzip_path: str
    sha256: str
    compressed_bytes: int
    uncompressed_bytes: int
    segment_count: int
    total_length_m: float
    bounds: Tuple[float, float, float, float]
    district_count: int
    counters: Dict[str, int]
    parse_counters: Dict[str, int]
    catalog_entry: Dict[str, object]


def build(
    input_path: str,
    city_id: str,
    city_name: str,
    version: int = 1,
    out_dir: str = ".",
    districts_path: Optional[str] = None,
    min_segment_length_m: float = 3.0,
    osm_extract: Optional[str] = None,
    built_at: Optional[str] = None,
    keep_uncompressed: bool = True,
    log: Optional[Callable[[str], None]] = None,
) -> BuildResult:
    """Build one city pack. Importable so the tests can drive it directly."""
    if log is None:
        def log(message: str) -> None:
            print(message, file=sys.stderr)

    os.makedirs(out_dir, exist_ok=True)

    if built_at is None:
        built_at = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
    if osm_extract is None:
        try:
            stamp = datetime.datetime.fromtimestamp(
                os.path.getmtime(input_path), datetime.timezone.utc
            ).date().isoformat()
        except OSError:
            stamp = "unknown"
        osm_extract = f"{os.path.basename(input_path)} ({stamp})"

    counters = BuildCounters()
    parse_counters = osm.ParseCounters()

    districts: List[District] = []
    if districts_path:
        districts = load_districts(districts_path)
        log(f"districts: {len(districts)} loaded from {districts_path}")

    log(f"pass 1/2: reading ways from {input_path}")
    retained_ways, needed = read_walkable_ways(input_path, counters, parse_counters)
    log(f"  {counters.ways_retained} walkable ways, {len(needed)} node ids needed")

    log("pass 2/2: reading nodes")
    nodes = read_needed_nodes(input_path, needed, parse_counters)
    log(f"  {len(nodes)} node coordinates resolved")

    segments = build_segments(retained_ways, nodes, counters, min_segment_length_m, districts)
    log(f"  {len(segments)} segments after splitting")

    sqlite_path = os.path.join(out_dir, f"{city_id}.v{version}.sqlite")
    gzip_path = sqlite_path + ".gz"

    total_length, bounds = write_pack(
        sqlite_path=sqlite_path,
        segments=segments,
        districts=districts,
        city_id=city_id,
        city_name=city_name,
        osm_extract=osm_extract,
        built_at=built_at,
    )

    gzip_file(sqlite_path, gzip_path)
    uncompressed_bytes = os.path.getsize(sqlite_path)
    compressed_bytes = os.path.getsize(gzip_path)
    digest = sha256_of(gzip_path)

    if not keep_uncompressed:
        os.remove(sqlite_path)

    catalog_entry = {
        "version": version,
        "path": os.path.basename(gzip_path),
        "sha256": digest,
        "compressedBytes": compressed_bytes,
        "segmentCount": len(segments),
        # Rounded to the millimetre so the catalog stays readable. The exact
        # sum is in the pack's own meta table.
        "totalLengthMetres": round(total_length, 3),
    }

    return BuildResult(
        sqlite_path=sqlite_path,
        gzip_path=gzip_path,
        sha256=digest,
        compressed_bytes=compressed_bytes,
        uncompressed_bytes=uncompressed_bytes,
        segment_count=len(segments),
        total_length_m=total_length,
        bounds=bounds,
        district_count=len(districts),
        counters=counters.as_dict(),
        parse_counters=parse_counters.as_dict(),
        catalog_entry=catalog_entry,
    )


def make_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="build_pack.py",
        description="Convert an OpenStreetMap extract into a WalkTracker city pack.",
        epilog=(
            "The JSON printed on stdout is a City.PackDescriptor and can be pasted "
            "straight into the app's city catalog. Progress and skip counts go to stderr."
        ),
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("input", help="OSM XML extract, plain or gzipped (.osm / .osm.gz)")
    parser.add_argument("--city-id", required=True, help='catalog slug, for example "new-york"')
    parser.add_argument("--city-name", required=True, help='display name, for example "New York"')
    parser.add_argument("--version", type=int, default=1, help="pack version, bumped on every rebuild")
    parser.add_argument("--out-dir", default=".", help="directory for the built pack")
    parser.add_argument("--districts", default=None, help="optional GeoJSON file of named district polygons")
    parser.add_argument(
        "--min-segment-length",
        type=float,
        default=3.0,
        metavar="METRES",
        help="drop split segments shorter than this; they are junction artifacts",
    )
    parser.add_argument(
        "--osm-extract",
        default=None,
        help="attribution string for meta.osm_extract (default: input filename and its date)",
    )
    parser.add_argument(
        "--built-at",
        default=None,
        help="ISO 8601 build timestamp; pin it to make a build byte-for-byte reproducible",
    )
    parser.add_argument(
        "--remove-uncompressed",
        action="store_true",
        help="delete the intermediate .sqlite file and keep only the .sqlite.gz",
    )
    parser.add_argument("--quiet", action="store_true", help="suppress progress output on stderr")
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = make_arg_parser().parse_args(argv)

    def log(message: str) -> None:
        if not args.quiet:
            print(message, file=sys.stderr)

    try:
        result = build(
            input_path=args.input,
            city_id=args.city_id,
            city_name=args.city_name,
            version=args.version,
            out_dir=args.out_dir,
            districts_path=args.districts,
            min_segment_length_m=args.min_segment_length,
            osm_extract=args.osm_extract,
            built_at=args.built_at,
            keep_uncompressed=not args.remove_uncompressed,
            log=log,
        )
    except (osm.OSMParseError, OSError, ValueError) as exc:
        print(f"build failed: {exc}", file=sys.stderr)
        return 1

    log("")
    log(f"wrote {result.gzip_path}")
    log(f"  uncompressed {result.uncompressed_bytes} bytes, compressed {result.compressed_bytes} bytes")
    log(f"  {result.segment_count} segments, {result.total_length_m:.1f} m in default classes")
    log(f"  bounds lat {result.bounds[0]:.6f}..{result.bounds[2]:.6f}, lon {result.bounds[1]:.6f}..{result.bounds[3]:.6f}")
    log(f"  districts {result.district_count}")
    log("skipped input:")
    for key, value in sorted(result.counters.items()):
        log(f"  {key}: {value}")
    for key, value in sorted(result.parse_counters.items()):
        log(f"  {key}: {value}")

    print(json.dumps(result.catalog_entry, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
