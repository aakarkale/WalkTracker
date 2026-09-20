#!/usr/bin/env python3
"""End to end checks for the city pack pipeline.

Run it directly:

    python3 test_pipeline.py

No pytest, no third party anything: plain asserts, one PASS or FAIL line per
check, and a non zero exit status if any check fails.

What this is really for: the pipeline cannot be validated against a real
OpenStreetMap extract on a host with no network access to OSM, so the
synthetic fixture in make_fixture.py is the ground truth instead. Its correct
answer is known by construction, which lets these checks assert exact segment
counts, exact split points and exact skip counts rather than plausibility.
"""

from __future__ import annotations

import json
import math
import os
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
import traceback
from typing import Callable, Dict, List, Optional, Sequence, Tuple

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import build_pack
import make_fixture
import osm

EARTH_RADIUS_M = 6_371_008.8

# Every WayClass case in StreetSegment.swift. A class outside this set would
# fail to decode in the app.
WAY_CLASSES = frozenset(
    (
        "footway", "residential", "tertiary", "secondary", "primary", "pedestrian",
        "living", "steps", "path", "track", "service", "unclassified",
    )
)

CHECKS: List[Tuple[str, Callable]] = []


def check(name: str):
    def decorate(fn):
        CHECKS.append((name, fn))
        return fn
    return decorate


def haversine(a: Tuple[float, float], b: Tuple[float, float]) -> float:
    """Great circle distance, computed independently of anything in build_pack.

    Mirrors GeoMath.haversine on the Swift side. Used to confirm that the
    equirectangular lengths the builder stores are not quietly wrong: at block
    scale the two must agree to a fraction of a percent.
    """
    phi1 = a[0] * math.pi / 180.0
    phi2 = b[0] * math.pi / 180.0
    d_phi = (b[0] - a[0]) * math.pi / 180.0
    d_lambda = (b[1] - a[1]) * math.pi / 180.0
    h = math.sin(d_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(max(0.0, h))))


def haversine_length(points: Sequence[Tuple[float, float]]) -> float:
    return sum(haversine(points[i - 1], points[i]) for i in range(1, len(points)))


class Context:
    """The one shared build every check reads from."""

    def __init__(self, work_dir: str, rows: int = 5, cols: int = 6):
        self.work_dir = work_dir
        self.fixture = make_fixture.generate(rows=rows, cols=cols)

        self.osm_path = os.path.join(work_dir, "fixture.osm")
        self.osm_gz_path = os.path.join(work_dir, "fixture.osm.gz")
        self.districts_path = os.path.join(work_dir, "districts.geojson")

        xml = self.fixture.to_osm_xml()
        with open(self.osm_path, "w", encoding="utf-8") as handle:
            handle.write(xml)
        import gzip
        with gzip.open(self.osm_gz_path, "wt", encoding="utf-8") as handle:
            handle.write(xml)
        with open(self.districts_path, "w", encoding="utf-8") as handle:
            json.dump(self.fixture.to_districts_geojson(), handle)

        self.out_dir = os.path.join(work_dir, "pack")
        self.result = build_pack.build(
            input_path=self.osm_path,
            city_id="testville",
            city_name="Testville",
            version=3,
            out_dir=self.out_dir,
            districts_path=self.districts_path,
            built_at="2026-01-02T03:04:05+00:00",
            osm_extract="synthetic fixture (2026-01-02)",
            log=lambda message: None,
        )
        self.db = sqlite3.connect(self.result.sqlite_path)
        self.db.row_factory = sqlite3.Row

        self.segments = [dict(row) for row in self.db.execute("SELECT * FROM segment ORDER BY id")]
        self.geometry: Dict[int, List[Tuple[float, float]]] = {
            row["id"]: build_pack.decode_geometry(row["geometry"]) for row in self.segments
        }

    def segments_for_way(self, way_id: int) -> List[dict]:
        return [s for s in self.segments if s["way_id"] == way_id]

    def close(self) -> None:
        self.db.close()


# --------------------------------------------------------------------------
# Splitting: the behaviour the whole pipeline exists for
# --------------------------------------------------------------------------


@check("way spanning N blocks produces exactly N segments")
def test_multi_block_split(ctx: Context) -> None:
    fixture = ctx.fixture
    expected_per_row = fixture.cols - 1
    for row in range(fixture.rows):
        way_id = fixture.row_way_id(row)
        found = ctx.segments_for_way(way_id)
        assert len(found) == expected_per_row, (
            f"row way {way_id} spans {expected_per_row} blocks but produced {len(found)} segments"
        )

    expected_per_col = fixture.rows - 1
    for col in range(fixture.cols):
        way_id = fixture.col_way_id(col)
        found = ctx.segments_for_way(way_id)
        assert len(found) == expected_per_col, (
            f"column way {way_id} spans {expected_per_col} blocks but produced {len(found)} segments"
        )

    assert len(ctx.segments) == fixture.expected_segment_count, (
        f"expected {fixture.expected_segment_count} segments in total, got {len(ctx.segments)}"
    )


@check("consecutive segments of one way chain end node to start node")
def test_split_chain(ctx: Context) -> None:
    fixture = ctx.fixture
    for row in range(fixture.rows):
        pieces = ctx.segments_for_way(fixture.row_way_id(row))
        for index in range(1, len(pieces)):
            assert pieces[index - 1]["end_node"] == pieces[index]["start_node"], (
                f"row way {fixture.row_way_id(row)} piece {index} does not continue from the previous one"
            )
        assert pieces[0]["start_node"] == fixture.grid_node_id(row, 0)
        assert pieces[-1]["end_node"] == fixture.grid_node_id(row, fixture.cols - 1)


@check("interior non-intersection vertex does not split and stays in the geometry")
def test_interior_vertex_preserved(ctx: Context) -> None:
    fixture = ctx.fixture
    endpoints = set()
    for segment in ctx.segments:
        endpoints.add(segment["start_node"])
        endpoints.add(segment["end_node"])

    for node_id in fixture.interior_vertex_node_ids:
        assert node_id not in endpoints, (
            f"node {node_id} is a plain bend but was used as a segment endpoint, so the way was split there"
        )

        target = fixture.coord_of(node_id)
        holders = []
        for segment in ctx.segments:
            for point in ctx.geometry[segment["id"]]:
                if abs(point[0] - target[0]) < 1e-6 and abs(point[1] - target[1]) < 1e-6:
                    holders.append(segment["id"])
                    break
        assert len(holders) == 1, (
            f"bend node {node_id} should appear inside exactly one segment, found {len(holders)}"
        )

        points = ctx.geometry[holders[0]]
        assert len(points) == 3, (
            f"segment {holders[0]} should be start, bend, end but has {len(points)} points"
        )
        middle = points[1]
        assert abs(middle[0] - target[0]) < 1e-6 and abs(middle[1] - target[1]) < 1e-6, (
            "the bend is not the interior vertex of its segment"
        )


@check("self touching way splits at its own repeated node")
def test_self_touching_way(ctx: Context) -> None:
    fixture = ctx.fixture
    pieces = ctx.segments_for_way(make_fixture.WAY_LOOP)
    assert len(pieces) == 3, f"the park loop should split into 3 segments, got {len(pieces)}"

    anchor = fixture.grid_node_id(fixture.rows - 1, fixture.cols - 1)
    loop_a = make_fixture.NODE_LOOP_A

    tail, ring, spur = pieces
    assert (tail["start_node"], tail["end_node"]) == (anchor, loop_a)
    assert ring["start_node"] == loop_a and ring["end_node"] == loop_a, (
        "the closed part of the loop should start and end at the node the way revisits"
    )
    assert len(ctx.geometry[ring["id"]]) == 4, (
        "the ring should be A, B, C, A: the duplicated B must have been collapsed"
    )
    assert (spur["start_node"], spur["end_node"]) == (loop_a, make_fixture.NODE_LOOP_D)


@check("split_way unit cases: plain, lollipop and closed loop")
def test_split_way_units(ctx: Context) -> None:
    # A plain run with one shared node in the middle.
    node_ids = [1, 2, 3, 4, 5]
    counts = {1: 1, 2: 1, 3: 2, 4: 1, 5: 1}
    assert build_pack.split_way(node_ids, counts) == [(0, 2), (2, 4)]

    # No shared nodes at all: one segment, bends preserved.
    assert build_pack.split_way(node_ids, {n: 1 for n in node_ids}) == [(0, 4)]

    # Lollipop: A B C D B E, with B revisited by the same way.
    lollipop = [10, 11, 12, 13, 11, 14]
    counts = build_pack.build_reference_counts([(None, lollipop)])
    assert counts[11] == 2, "a node the way visits twice must count twice"
    assert build_pack.split_way(lollipop, counts) == [(0, 1), (1, 4), (4, 5)]

    # A closed ring touched by nothing else stays one segment.
    ring = [20, 21, 22, 20]
    counts = build_pack.build_reference_counts([(None, ring)])
    assert build_pack.split_way(ring, counts) == [(0, 3)]

    # Two nodes cannot be split further.
    assert build_pack.split_way([30, 31], {30: 2, 31: 2}) == [(0, 1)]
    # Fewer than two nodes yields nothing rather than raising.
    assert build_pack.split_way([30], {30: 5}) == []


# --------------------------------------------------------------------------
# Filtering
# --------------------------------------------------------------------------


@check("excluded highway types and foot=no / access=private produce zero segments")
def test_excluded_ways(ctx: Context) -> None:
    fixture = ctx.fixture
    for way_id in fixture.excluded_way_ids:
        found = ctx.segments_for_way(way_id)
        assert not found, f"way {way_id} must be excluded but produced {len(found)} segments"

    # And nothing else crept in either: the segment table holds exactly the
    # ways that should have survived.
    expected_ways = set()
    for row in range(fixture.rows):
        expected_ways.add(fixture.row_way_id(row))
    for col in range(fixture.cols):
        expected_ways.add(fixture.col_way_id(col))
    expected_ways.add(make_fixture.WAY_LOOP)
    expected_ways.add(make_fixture.WAY_MISSING_REF)
    expected_ways.add(make_fixture.WAY_INVALID_COORD_NODES)

    actual_ways = {segment["way_id"] for segment in ctx.segments}
    assert actual_ways == expected_ways, (
        f"unexpected ways in the pack: extra={sorted(actual_ways - expected_ways)}, "
        f"missing={sorted(expected_ways - actual_ways)}"
    )

    counters = ctx.result.counters
    assert counters["ways_excluded_class"] == 3, counters
    assert counters["ways_excluded_tag"] == 2, counters
    assert counters["ways_not_highway"] == 1, counters


@check("classify_way applies the spec's selection rules")
def test_classify_rules(ctx: Context) -> None:
    assert build_pack.classify_way({"highway": "living_street"})[0] == "living"
    assert build_pack.classify_way({"highway": "residential"})[0] == "residential"
    assert build_pack.classify_way({"highway": "primary_link"})[0] == "primary"
    assert build_pack.classify_way({"highway": "service"})[0] == "service"

    assert build_pack.classify_way({"highway": "motorway"}) == (None, "excluded_class")
    assert build_pack.classify_way({"highway": "trunk"}) == (None, "excluded_class")
    assert build_pack.classify_way({"highway": "cycleway"}) == (None, "excluded_class")
    assert build_pack.classify_way({"building": "yes"}) == (None, "not_highway")
    assert build_pack.classify_way({"highway": "footway", "foot": "no"}) == (None, "excluded_tag")
    assert build_pack.classify_way({"highway": "residential", "access": "private"}) == (None, "excluded_tag")

    # The optional classes are kept, just not counted in the headline figure.
    for name in ("service", "track", "steps", "path"):
        assert build_pack.classify_way({"highway": name})[0] == name
    assert build_pack.OPTIONAL_CLASSES | build_pack.DEFAULT_CLASSES == WAY_CLASSES


@check("every stored class is a WayClass case the app knows")
def test_classes_valid(ctx: Context) -> None:
    stored = {row[0] for row in ctx.db.execute("SELECT DISTINCT class FROM segment")}
    unknown = stored - WAY_CLASSES
    assert not unknown, f"classes the app cannot decode: {sorted(unknown)}"
    assert "living" in stored, "the fixture has a living_street row way, so 'living' must appear"
    assert "service" in stored, "the fixture has a service column, so an optional class must appear"


@check("segments shorter than the minimum are dropped")
def test_short_segments_dropped(ctx: Context) -> None:
    assert not ctx.segments_for_way(make_fixture.WAY_SHORT_STUB), (
        "the 1 m kerb link should have been dropped"
    )
    assert ctx.result.counters["segments_dropped_short"] == 1, ctx.result.counters

    shortest = min(segment["length_m"] for segment in ctx.segments)
    assert shortest >= 3.0, f"a {shortest:.3f} m segment survived the 3 m minimum"

    # And the threshold really is configurable.
    relaxed = build_pack.build(
        input_path=ctx.osm_path,
        city_id="relaxed",
        city_name="Relaxed",
        out_dir=os.path.join(ctx.work_dir, "relaxed"),
        min_segment_length_m=0.5,
        built_at="2026-01-02T03:04:05+00:00",
        log=lambda message: None,
    )
    assert relaxed.counters["segments_dropped_short"] == 0, relaxed.counters
    assert relaxed.segment_count == ctx.result.segment_count + 1, (
        "lowering the minimum should keep the 1 m stub"
    )


# --------------------------------------------------------------------------
# Geometry
# --------------------------------------------------------------------------


@check("geometry blob round trips to within 1e-6 degrees")
def test_geometry_round_trip(ctx: Context) -> None:
    fixture = ctx.fixture
    checked = 0
    for row in range(fixture.rows):
        pieces = ctx.segments_for_way(fixture.row_way_id(row))
        for index, segment in enumerate(pieces):
            expected_start = fixture.grid_coord(row, index)
            actual_start = ctx.geometry[segment["id"]][0]
            assert abs(actual_start[0] - expected_start[0]) < 1e-6, (
                f"segment {segment['id']} start latitude drifted: {actual_start[0]} vs {expected_start[0]}"
            )
            assert abs(actual_start[1] - expected_start[1]) < 1e-6, (
                f"segment {segment['id']} start longitude drifted: {actual_start[1]} vs {expected_start[1]}"
            )
            checked += 1
    assert checked == fixture.rows * (fixture.cols - 1)

    # Re-encoding what we decoded must reproduce the stored bytes exactly.
    for segment in ctx.segments:
        again = build_pack.encode_geometry(ctx.geometry[segment["id"]])
        assert again == segment["geometry"], f"segment {segment['id']} does not re-encode to itself"


@check("geometry blob matches the spec's byte layout")
def test_geometry_layout(ctx: Context) -> None:
    # Decoded by hand here rather than through build_pack, so that the check
    # is against the spec and not against the encoder's own opinion.
    for segment in ctx.segments:
        blob = segment["geometry"]
        (count,) = struct.unpack_from("<H", blob, 0)
        assert count >= 2, f"segment {segment['id']} claims {count} points"
        assert len(blob) == 2 + 8 * count, (
            f"segment {segment['id']}: blob is {len(blob)} bytes, spec says {2 + 8 * count}"
        )
        lats = struct.unpack_from("<%di" % count, blob, 2)
        lons = struct.unpack_from("<%di" % count, blob, 2 + 4 * count)
        for value in lats:
            assert -900_000_000 <= value <= 900_000_000, "latitude * 1e7 out of range"
        for value in lons:
            assert -1_800_000_000 <= value <= 1_800_000_000, "longitude * 1e7 out of range"
        decoded = [(lats[i] / 1e7, lons[i] / 1e7) for i in range(count)]
        assert decoded == ctx.geometry[segment["id"]]

    assert build_pack.encode_geometry([(1.0, 2.0), (3.0, 4.0)]) == (
        struct.pack("<H", 2) + struct.pack("<2i", 10_000_000, 30_000_000) + struct.pack("<2i", 20_000_000, 40_000_000)
    )

    for bad in ([(1.0, 2.0)], []):
        try:
            build_pack.encode_geometry(bad)
        except ValueError:
            pass
        else:
            raise AssertionError("encode_geometry accepted fewer than two points")


@check("length_m agrees with an independent haversine length to within 0.5%")
def test_lengths(ctx: Context) -> None:
    worst = 0.0
    worst_id = None
    for segment in ctx.segments:
        points = ctx.geometry[segment["id"]]
        reference = haversine_length(points)
        assert reference > 0, f"segment {segment['id']} has zero haversine length"
        error = abs(segment["length_m"] - reference) / reference
        if error > worst:
            worst = error
            worst_id = segment["id"]
    assert worst < 0.005, f"segment {worst_id} is off by {worst * 100:.4f}%, over the 0.5% budget"

    # And the absolute scale is right, not just self consistent: a plain grid
    # block was generated at exactly the configured spacing.
    fixture = ctx.fixture
    straight = [
        segment
        for segment in ctx.segments_for_way(fixture.row_way_id(0))
    ][0]
    assert abs(straight["length_m"] - fixture.spacing_m) < 0.5, (
        f"a {fixture.spacing_m} m block measured {straight['length_m']:.3f} m"
    )


@check("planar_length_m uses the agreed equirectangular formula")
def test_planar_formula(ctx: Context) -> None:
    # Recomputed straight from the formula in the spec, independently of the
    # implementation, because the Swift side depends on this exact expression.
    lat0, lon0 = 40.7, -74.0
    points = [(lat0, lon0), (lat0 + 0.001, lon0 + 0.002), (lat0 + 0.0005, lon0 + 0.003)]
    radius = 6_371_008.8
    to_rad = math.pi / 180.0
    expected = 0.0
    previous = None
    for lat, lon in points:
        x = (lon - lon0) * radius * to_rad * math.cos(lat0 * to_rad)
        y = (lat - lat0) * radius * to_rad
        if previous is not None:
            expected += math.hypot(x - previous[0], y - previous[1])
        previous = (x, y)
    actual = build_pack.planar_length_m(points)
    assert abs(actual - expected) < 1e-9, f"{actual} != {expected}"
    assert build_pack.planar_length_m([(1.0, 1.0)]) == 0.0


@check("every segment has an r-tree row whose bbox contains all its points")
def test_rtree(ctx: Context) -> None:
    rtree_rows = {
        row[0]: (row[1], row[2], row[3], row[4])
        for row in ctx.db.execute("SELECT id, min_lon, max_lon, min_lat, max_lat FROM segment_rtree")
    }
    assert len(rtree_rows) == len(ctx.segments), (
        f"{len(ctx.segments)} segments but {len(rtree_rows)} r-tree rows"
    )
    assert set(rtree_rows) == {segment["id"] for segment in ctx.segments}

    for segment in ctx.segments:
        min_lon, max_lon, min_lat, max_lat = rtree_rows[segment["id"]]
        assert min_lon <= max_lon and min_lat <= max_lat, f"segment {segment['id']} has an inverted bbox"
        for lat, lon in ctx.geometry[segment["id"]]:
            assert min_lat <= lat <= max_lat, (
                f"segment {segment['id']}: latitude {lat} outside r-tree bbox {min_lat}..{max_lat}"
            )
            assert min_lon <= lon <= max_lon, (
                f"segment {segment['id']}: longitude {lon} outside r-tree bbox {min_lon}..{max_lon}"
            )

    # The index has to actually answer a query, which is the only reason it
    # exists: every candidate lookup in the matcher goes through it.
    sample = ctx.segments[len(ctx.segments) // 2]
    lat, lon = ctx.geometry[sample["id"]][0]
    hits = [
        row[0]
        for row in ctx.db.execute(
            "SELECT id FROM segment_rtree WHERE max_lon >= ? AND min_lon <= ? AND max_lat >= ? AND min_lat <= ?",
            (lon - 1e-7, lon + 1e-7, lat - 1e-7, lat + 1e-7),
        )
    ]
    assert sample["id"] in hits, "an r-tree window around a segment's own vertex did not return it"


# --------------------------------------------------------------------------
# Graph
# --------------------------------------------------------------------------


@check("segments meeting at an intersection share a node id")
def test_shared_nodes(ctx: Context) -> None:
    fixture = ctx.fixture
    row, col = 2, 3
    node_id = fixture.grid_node_id(row, col)
    touching = [
        segment
        for segment in ctx.segments
        if node_id in (segment["start_node"], segment["end_node"])
    ]
    assert len(touching) == 4, (
        f"a mid grid crossroads should join 4 blocks, found {len(touching)}"
    )
    way_ids = sorted(segment["way_id"] for segment in touching)
    assert way_ids == sorted([fixture.row_way_id(row)] * 2 + [fixture.col_way_id(col)] * 2), (
        f"the wrong ways meet at the crossroads: {way_ids}"
    )

    corner = fixture.grid_node_id(0, 0)
    corner_touching = [
        segment for segment in ctx.segments if corner in (segment["start_node"], segment["end_node"])
    ]
    # Row 0, column 0, and the way whose middle ref dangled and was repaired.
    assert len(corner_touching) == 3, f"corner should join 3 blocks, found {len(corner_touching)}"


@check("the fixture's street graph is fully connected")
def test_graph_connected(ctx: Context) -> None:
    parent: Dict[int, int] = {}

    def find(node: int) -> int:
        parent.setdefault(node, node)
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    def union(a: int, b: int) -> None:
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[ra] = rb

    for segment in ctx.segments:
        union(segment["start_node"], segment["end_node"])

    roots = {find(node) for node in parent}
    assert len(roots) == 1, (
        f"the grid should be one connected component, found {len(roots)}"
    )

    # Every segment endpoint must be a node the extract actually described.
    known = {node.id for node in ctx.fixture.nodes if node.valid}
    for segment in ctx.segments:
        assert segment["start_node"] in known, f"segment {segment['id']} starts at an unknown node"
        assert segment["end_node"] in known, f"segment {segment['id']} ends at an unknown node"


# --------------------------------------------------------------------------
# Districts
# --------------------------------------------------------------------------


@check("district assignment puts each segment in the polygon holding its midpoint")
def test_district_assignment(ctx: Context) -> None:
    districts = build_pack.load_districts(ctx.districts_path)
    by_id = {district.id: district for district in districts}
    by_name = {district.name: district for district in districts}
    assert set(by_name) == {"West Side", "East Side", "Riverside"}, sorted(by_name)

    for segment in ctx.segments:
        mid_lat, mid_lon = build_pack.midpoint(ctx.geometry[segment["id"]])
        expected = build_pack.district_for_point(mid_lat, mid_lon, districts)
        expected_id = expected.id if expected else None
        assert segment["district_id"] == expected_id, (
            f"segment {segment['id']} was filed under {segment['district_id']}, "
            f"but its midpoint ({mid_lat:.6f}, {mid_lon:.6f}) is in {expected_id}"
        )

    fixture = ctx.fixture

    def segment_between(way_id: int, start_node: int, end_node: int) -> dict:
        for segment in ctx.segments:
            if segment["way_id"] == way_id and segment["start_node"] == start_node and segment["end_node"] == end_node:
                return segment
        raise AssertionError(f"no segment on way {way_id} from {start_node} to {end_node}")

    west_block = segment_between(
        fixture.row_way_id(0), fixture.grid_node_id(0, 0), fixture.grid_node_id(0, 1)
    )
    east_block = segment_between(
        fixture.row_way_id(0),
        fixture.grid_node_id(0, fixture.cols - 2),
        fixture.grid_node_id(0, fixture.cols - 1),
    )
    assert by_id[west_block["district_id"]].name == "West Side", (
        "a block west of the divider was not filed under West Side"
    )
    assert by_id[east_block["district_id"]].name == "East Side", (
        "a block east of the divider was not filed under East Side"
    )

    stored = {
        row["name"]: row
        for row in ctx.db.execute("SELECT * FROM district")
    }
    assert len(stored) == 3
    assert stored["Riverside"]["segment_count"] == 0, "Riverside holds no streets"
    assert stored["Riverside"]["total_length_m"] == 0.0

    total_assigned = sum(row["segment_count"] for row in stored.values())
    assert total_assigned == len(ctx.segments), (
        f"{total_assigned} segments were assigned a district out of {len(ctx.segments)}"
    )
    assert stored["West Side"]["segment_count"] > 0 and stored["East Side"]["segment_count"] > 0

    # Each district's stored bounds must really hold the midpoints filed under it.
    for segment in ctx.segments:
        row = None
        for candidate in stored.values():
            if candidate["id"] == segment["district_id"]:
                row = candidate
        assert row is not None
        mid_lat, mid_lon = build_pack.midpoint(ctx.geometry[segment["id"]])
        assert row["min_lat"] <= mid_lat <= row["max_lat"], "district bounds do not contain a member midpoint"
        assert row["min_lon"] <= mid_lon <= row["max_lon"], "district bounds do not contain a member midpoint"

    # District lengths use the same default-class rule as meta.total_length_m.
    for name, row in stored.items():
        expected_length = sum(
            segment["length_m"]
            for segment in ctx.segments
            if segment["district_id"] == row["id"] and segment["class"] in build_pack.DEFAULT_CLASSES
        )
        assert abs(row["total_length_m"] - expected_length) < 1e-6, (
            f"district {name} total is {row['total_length_m']}, expected {expected_length}"
        )


@check("point in polygon handles holes, multipolygons and outside points")
def test_point_in_polygon(ctx: Context) -> None:
    square = [(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0), (0.0, 0.0)]
    hole = [(4.0, 4.0), (6.0, 4.0), (6.0, 6.0), (4.0, 6.0), (4.0, 4.0)]

    assert build_pack.point_in_ring(5.0, 5.0, square) is True
    assert build_pack.point_in_ring(15.0, 5.0, square) is False
    assert build_pack.point_in_ring(-1.0, 5.0, square) is False
    assert build_pack.point_in_ring(5.0, 20.0, square) is False

    assert build_pack.point_in_polygon(1.0, 1.0, [square, hole]) is True
    assert build_pack.point_in_polygon(5.0, 5.0, [square, hole]) is False, "a point in a hole is outside"
    assert build_pack.point_in_polygon(5.0, 5.0, [square]) is True

    # A concave ring: the classic case a bounding box test gets wrong.
    ell = [(0.0, 0.0), (10.0, 0.0), (10.0, 4.0), (4.0, 4.0), (4.0, 10.0), (0.0, 10.0), (0.0, 0.0)]
    assert build_pack.point_in_ring(2.0, 2.0, ell) is True
    assert build_pack.point_in_ring(8.0, 8.0, ell) is False

    far = [(100.0, 100.0), (101.0, 100.0), (101.0, 101.0), (100.0, 101.0), (100.0, 100.0)]
    districts = [
        build_pack.District(
            id=1, name="Two Parts", polygons=[[square], [far]],
            min_lat=0.0, min_lon=0.0, max_lat=101.0, max_lon=101.0,
        )
    ]
    assert build_pack.district_for_point(5.0, 5.0, districts).name == "Two Parts"
    assert build_pack.district_for_point(100.5, 100.4, districts).name == "Two Parts"
    assert build_pack.district_for_point(50.0, 50.0, districts) is None


@check("midpoint is half way along the line, not the mean of the vertices")
def test_midpoint(ctx: Context) -> None:
    straight = [(40.0, -74.0), (40.0, -73.999)]
    mid = build_pack.midpoint(straight)
    assert abs(mid[1] - (-73.9995)) < 1e-9

    # An L shape: the vertex mean would sit off the line entirely.
    bent = [(40.0, -74.0), (40.0, -73.99), (40.01, -73.99)]
    mid = build_pack.midpoint(bent)
    on_line = abs(mid[0] - 40.0) < 1e-9 or abs(mid[1] - (-73.99)) < 1e-9
    assert on_line, f"midpoint {mid} is not on the polyline"


@check("without a districts file every district_id is NULL and the table is empty")
def test_no_districts(ctx: Context) -> None:
    result = build_pack.build(
        input_path=ctx.osm_path,
        city_id="nodistricts",
        city_name="No Districts",
        out_dir=os.path.join(ctx.work_dir, "nodistricts"),
        districts_path=None,
        built_at="2026-01-02T03:04:05+00:00",
        log=lambda message: None,
    )
    connection = sqlite3.connect(result.sqlite_path)
    try:
        assert connection.execute("SELECT count(*) FROM district").fetchone()[0] == 0
        nulls = connection.execute("SELECT count(*) FROM segment WHERE district_id IS NULL").fetchone()[0]
        total = connection.execute("SELECT count(*) FROM segment").fetchone()[0]
        assert nulls == total == ctx.result.segment_count, (
            f"{nulls} of {total} segments had a NULL district"
        )
    finally:
        connection.close()


# --------------------------------------------------------------------------
# Pack level invariants
# --------------------------------------------------------------------------


@check("the schema matches the spec's tables, columns and types")
def test_schema(ctx: Context) -> None:
    def columns(table: str) -> List[Tuple[str, str]]:
        return [(row[1], row[2].upper()) for row in ctx.db.execute(f"PRAGMA table_info({table})")]

    assert columns("meta") == [("key", "TEXT"), ("value", "TEXT")], columns("meta")
    assert columns("segment") == [
        ("id", "INTEGER"),
        ("way_id", "INTEGER"),
        ("name", "TEXT"),
        ("class", "TEXT"),
        ("start_node", "INTEGER"),
        ("end_node", "INTEGER"),
        ("length_m", "REAL"),
        ("district_id", "INTEGER"),
        ("geometry", "BLOB"),
    ], columns("segment")
    assert columns("district") == [
        ("id", "INTEGER"),
        ("name", "TEXT"),
        ("min_lat", "REAL"),
        ("min_lon", "REAL"),
        ("max_lat", "REAL"),
        ("max_lon", "REAL"),
        ("segment_count", "INTEGER"),
        ("total_length_m", "REAL"),
    ], columns("district")

    rtree_sql = ctx.db.execute(
        "SELECT sql FROM sqlite_master WHERE name = 'segment_rtree'"
    ).fetchone()[0]
    normalised = " ".join(rtree_sql.split()).lower()
    assert "using rtree(id, min_lon, max_lon, min_lat, max_lat)" in normalised, rtree_sql

    names = {
        row[0]
        for row in ctx.db.execute("SELECT name FROM sqlite_master WHERE type in ('table','view')")
    }
    for required in ("meta", "segment", "district", "segment_rtree"):
        assert required in names, f"{required} is missing from the pack"


@check("meta totals agree with the segment table")
def test_meta(ctx: Context) -> None:
    meta = {row[0]: row[1] for row in ctx.db.execute("SELECT key, value FROM meta")}

    assert meta["schema_version"] == "1"
    assert meta["city_id"] == "testville"
    assert meta["city_name"] == "Testville"
    assert meta["built_at"] == "2026-01-02T03:04:05+00:00"
    assert meta["osm_extract"] == "synthetic fixture (2026-01-02)"

    row_count = ctx.db.execute("SELECT count(*) FROM segment").fetchone()[0]
    assert int(meta["segment_count"]) == row_count == len(ctx.segments)

    default_total = ctx.db.execute(
        "SELECT sum(length_m) FROM segment WHERE class NOT IN (%s)"
        % ",".join("?" * len(build_pack.OPTIONAL_CLASSES)),
        tuple(sorted(build_pack.OPTIONAL_CLASSES)),
    ).fetchone()[0]
    assert abs(float(meta["total_length_m"]) - default_total) < 1e-6, (
        f"meta.total_length_m is {meta['total_length_m']}, segment table says {default_total}"
    )

    every_total = ctx.db.execute("SELECT sum(length_m) FROM segment").fetchone()[0]
    assert default_total < every_total, (
        "the fixture has optional-class segments, so the default total must be smaller "
        "than the total over every class"
    )

    lats = [lat for points in ctx.geometry.values() for lat, _ in points]
    lons = [lon for points in ctx.geometry.values() for _, lon in points]
    assert abs(float(meta["min_lat"]) - min(lats)) < 1e-6, "meta.min_lat does not match the geometry"
    assert abs(float(meta["max_lat"]) - max(lats)) < 1e-6, "meta.max_lat does not match the geometry"
    assert abs(float(meta["min_lon"]) - min(lons)) < 1e-6, "meta.min_lon does not match the geometry"
    assert abs(float(meta["max_lon"]) - max(lons)) < 1e-6, "meta.max_lon does not match the geometry"

    assert abs(ctx.result.total_length_m - default_total) < 1e-6


@check("malformed input is skipped, counted and never fatal")
def test_malformed_counted(ctx: Context) -> None:
    counters = ctx.result.counters
    parse = ctx.result.parse_counters

    # One dangling ref in WAY_MISSING_REF, two in WAY_ALL_REFS_DANGLE, and two
    # nodes in WAY_INVALID_COORD_NODES that were rejected for bad coordinates.
    assert counters["way_refs_unresolved"] == 5, counters
    # The doubled node in the park loop, plus two in the all-duplicates way.
    assert counters["nodes_duplicate_consecutive"] == 3, counters
    # WAY_ALL_REFS_DANGLE and WAY_ALL_DUPLICATE_NODES.
    assert counters["ways_too_few_nodes"] == 2, counters
    assert counters["segments_dropped_oversize"] == 0, counters
    assert counters["segments_written"] == len(ctx.segments), counters

    assert parse["nodes_invalid_coords"] == 2, parse
    assert parse["nodes_missing_attrs"] == 0, parse
    assert parse["ways_missing_id"] == 0, parse
    assert parse["way_refs_unparsable"] == 0, parse
    assert parse["relations_skipped"] == 1, parse
    assert parse["nodes_seen"] == len(ctx.fixture.nodes), parse
    assert parse["ways_seen"] == len(ctx.fixture.ways), parse

    # The way with a dangling middle ref still produced a segment, joining the
    # two nodes that did resolve rather than being thrown away wholesale.
    repaired = ctx.segments_for_way(make_fixture.WAY_MISSING_REF)
    assert len(repaired) == 1, f"expected the repaired way to yield 1 segment, got {len(repaired)}"
    assert repaired[0]["start_node"] == ctx.fixture.grid_node_id(0, 0)
    assert repaired[0]["end_node"] == make_fixture.NODE_MISSING_REF_END
    assert len(ctx.geometry[repaired[0]["id"]]) == 2, "the dangling ref should not appear in the geometry"

    invalid = ctx.segments_for_way(make_fixture.WAY_INVALID_COORD_NODES)
    assert len(invalid) == 1
    assert len(ctx.geometry[invalid[0]["id"]]) == 2, "NaN and out of range nodes must not reach the geometry"

    for points in ctx.geometry.values():
        for lat, lon in points:
            assert math.isfinite(lat) and math.isfinite(lon), "a non finite coordinate reached the pack"
            assert -90.0 <= lat <= 90.0 and -180.0 <= lon <= 180.0, "an out of range coordinate reached the pack"


@check("the gzipped pack matches the reported hash and size and has no sidecar files")
def test_gzip_and_hashes(ctx: Context) -> None:
    import gzip
    import hashlib

    assert os.path.basename(ctx.result.gzip_path) == "testville.v3.sqlite.gz", ctx.result.gzip_path
    assert os.path.getsize(ctx.result.gzip_path) == ctx.result.compressed_bytes

    digest = hashlib.sha256()
    with open(ctx.result.gzip_path, "rb") as handle:
        digest.update(handle.read())
    assert digest.hexdigest() == ctx.result.sha256, "reported SHA-256 does not match the file"

    with gzip.open(ctx.result.gzip_path, "rb") as handle:
        payload = handle.read()
    with open(ctx.result.sqlite_path, "rb") as handle:
        assert payload == handle.read(), "the gzip does not decompress to the built database"
    assert payload[:15] == b"SQLite format 3", "the gzip does not contain a SQLite database"

    for suffix in ("-wal", "-shm", "-journal"):
        sidecar = ctx.result.sqlite_path + suffix
        assert not os.path.exists(sidecar), f"{sidecar} was left behind; the pack must ship as one file"

    connection = sqlite3.connect(ctx.result.sqlite_path)
    try:
        mode = connection.execute("PRAGMA journal_mode").fetchone()[0]
        assert mode.lower() == "delete", f"journal_mode is {mode}, expected delete"
        assert connection.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
        assert connection.execute("PRAGMA freelist_count").fetchone()[0] == 0, (
            "the pack was not vacuumed: it still has free pages"
        )
    finally:
        connection.close()


@check("the catalog JSON is a City.PackDescriptor")
def test_catalog_entry(ctx: Context) -> None:
    entry = ctx.result.catalog_entry
    assert set(entry) == {
        "version", "path", "sha256", "compressedBytes", "segmentCount", "totalLengthMetres"
    }, sorted(entry)
    assert entry["version"] == 3
    assert entry["path"] == "testville.v3.sqlite.gz"
    assert len(entry["sha256"]) == 64 and all(c in "0123456789abcdef" for c in entry["sha256"])
    assert entry["compressedBytes"] == os.path.getsize(ctx.result.gzip_path)
    assert entry["segmentCount"] == len(ctx.segments)
    assert abs(entry["totalLengthMetres"] - ctx.result.total_length_m) < 0.001
    json.dumps(entry)


@check("gzipped input produces an identical pack")
def test_gzipped_input(ctx: Context) -> None:
    result = build_pack.build(
        input_path=ctx.osm_gz_path,
        city_id="testville",
        city_name="Testville",
        version=3,
        out_dir=os.path.join(ctx.work_dir, "fromgz"),
        districts_path=ctx.districts_path,
        built_at="2026-01-02T03:04:05+00:00",
        osm_extract="synthetic fixture (2026-01-02)",
        log=lambda message: None,
    )
    assert result.segment_count == ctx.result.segment_count
    assert abs(result.total_length_m - ctx.result.total_length_m) < 1e-9
    assert result.sha256 == ctx.result.sha256, (
        "a gzipped extract produced a different pack than the same XML uncompressed"
    )


@check("rebuilding the same extract is byte for byte reproducible")
def test_reproducible(ctx: Context) -> None:
    result = build_pack.build(
        input_path=ctx.osm_path,
        city_id="testville",
        city_name="Testville",
        version=3,
        out_dir=os.path.join(ctx.work_dir, "again"),
        districts_path=ctx.districts_path,
        built_at="2026-01-02T03:04:05+00:00",
        osm_extract="synthetic fixture (2026-01-02)",
        log=lambda message: None,
    )
    assert result.sha256 == ctx.result.sha256, "two identical builds produced different files"


@check("the command line tool runs and prints pasteable catalog JSON")
def test_cli(ctx: Context) -> None:
    out_dir = os.path.join(ctx.work_dir, "cli")
    process = subprocess.run(
        [
            sys.executable,
            os.path.join(HERE, "build_pack.py"),
            ctx.osm_gz_path,
            "--city-id", "cliville",
            "--city-name", "CLI Ville",
            "--version", "7",
            "--districts", ctx.districts_path,
            "--out-dir", out_dir,
            "--min-segment-length", "3",
            "--built-at", "2026-01-02T03:04:05+00:00",
            "--remove-uncompressed",
        ],
        capture_output=True,
        text=True,
    )
    assert process.returncode == 0, f"build_pack.py exited {process.returncode}:\n{process.stderr}"

    entry = json.loads(process.stdout)
    assert entry["path"] == "cliville.v7.sqlite.gz"
    assert entry["version"] == 7
    assert entry["segmentCount"] == ctx.result.segment_count
    assert os.path.exists(os.path.join(out_dir, "cliville.v7.sqlite.gz"))
    assert not os.path.exists(os.path.join(out_dir, "cliville.v7.sqlite")), (
        "--remove-uncompressed should have deleted the intermediate database"
    )
    assert "segments" in process.stderr, "the human readable report should go to stderr"

    help_process = subprocess.run(
        [sys.executable, os.path.join(HERE, "build_pack.py"), "--help"],
        capture_output=True,
        text=True,
    )
    assert help_process.returncode == 0
    for flag in ("--city-id", "--districts", "--min-segment-length", "--version"):
        assert flag in help_process.stdout, f"{flag} is missing from --help"

    for script in ("make_fixture.py", "osm.py"):
        other = subprocess.run(
            [sys.executable, os.path.join(HERE, script), "--help"], capture_output=True, text=True
        )
        assert other.returncode == 0, f"{script} --help failed:\n{other.stderr}"


@check("a corrupt extract fails cleanly instead of crashing")
def test_bad_input(ctx: Context) -> None:
    broken = os.path.join(ctx.work_dir, "broken.osm")
    with open(broken, "w", encoding="utf-8") as handle:
        handle.write('<?xml version="1.0"?>\n<osm version="0.6">\n  <node id="1" lat="1.0" lon="2.0"')

    try:
        list(osm.iter_ways(broken))
    except osm.OSMParseError as exc:
        assert "broken.osm" in str(exc)
    else:
        raise AssertionError("a truncated file should raise OSMParseError")

    process = subprocess.run(
        [
            sys.executable, os.path.join(HERE, "build_pack.py"), broken,
            "--city-id", "broken", "--city-name", "Broken",
            "--out-dir", os.path.join(ctx.work_dir, "broken-out"),
        ],
        capture_output=True,
        text=True,
    )
    assert process.returncode == 1, "a corrupt extract should exit 1"
    assert "build failed" in process.stderr
    assert "Traceback" not in process.stderr, "the tool should report the error, not dump a traceback"

    # An extract with no walkable ways at all still produces a valid, empty pack.
    empty = os.path.join(ctx.work_dir, "empty.osm")
    with open(empty, "w", encoding="utf-8") as handle:
        handle.write('<?xml version="1.0"?>\n<osm version="0.6"></osm>\n')
    result = build_pack.build(
        input_path=empty,
        city_id="empty",
        city_name="Empty",
        out_dir=os.path.join(ctx.work_dir, "empty-out"),
        built_at="2026-01-02T03:04:05+00:00",
        log=lambda message: None,
    )
    assert result.segment_count == 0
    connection = sqlite3.connect(result.sqlite_path)
    try:
        assert connection.execute("SELECT count(*) FROM segment").fetchone()[0] == 0
        assert connection.execute("SELECT value FROM meta WHERE key='segment_count'").fetchone()[0] == "0"
    finally:
        connection.close()


def main(argv: Optional[List[str]] = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(
        prog="test_pipeline.py",
        description="Run the city pack pipeline checks against the synthetic fixture.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--rows", type=int, default=5, help="fixture grid rows")
    parser.add_argument("--cols", type=int, default=6, help="fixture grid columns")
    args = parser.parse_args(argv)

    work_dir = tempfile.mkdtemp(prefix="citypack-test-")
    failures = 0
    context: Optional[Context] = None
    try:
        try:
            context = Context(work_dir, rows=args.rows, cols=args.cols)
        except Exception:
            print("FAIL - fixture build and pack build")
            traceback.print_exc()
            return 1

        print(f"fixture: {context.fixture.rows} x {context.fixture.cols} grid, "
              f"{len(context.fixture.nodes)} nodes, {len(context.fixture.ways)} ways")
        print(f"pack:    {context.result.segment_count} segments, "
              f"{context.result.total_length_m:.1f} m in default classes")
        print("")

        for name, function in CHECKS:
            try:
                function(context)
            except Exception as exc:
                failures += 1
                print(f"FAIL - {name}")
                for line in traceback.format_exc().splitlines():
                    print(f"       {line}")
            else:
                print(f"PASS - {name}")

        print("")
        print(f"{len(CHECKS) - failures}/{len(CHECKS)} checks passed")
        if failures:
            print(f"{failures} FAILED")
        return 1 if failures else 0
    finally:
        if context is not None:
            context.close()
        shutil.rmtree(work_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
