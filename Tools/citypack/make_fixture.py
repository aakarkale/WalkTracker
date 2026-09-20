#!/usr/bin/env python3
"""Generate a synthetic OSM XML extract that exercises the pack pipeline.

Why this exists: the pack builder's hardest job is splitting long OSM ways
into one row per block, and a real extract is a terrible place to discover you
got that wrong. It has no ground truth, it is hundreds of megabytes, and it
cannot be fetched at all from a sandboxed build host. This module emits a
small street grid whose correct answer is known by construction, so the test
suite can assert exact segment counts rather than "looks about right".

Deliberately included, because each one has broken a pipeline of this shape
before:

  * Ways that span many blocks. A row way crosses every column way, so it must
    split into exactly `cols - 1` segments.
  * Interior vertices that are *not* intersections. One is a plain bend; three
    more are touched only by a way that the filter must throw away, so a
    builder that counts references before filtering will wrongly split there.
  * Excluded ways: motorway, trunk, an unmapped highway value, foot=no,
    access=private, and a way with no highway tag at all.
  * A way that touches its own path, which has a real junction at that node
    even though only one way is involved.
  * A sub-metre stub that the minimum length filter must drop.
  * Malformed input: a missing node ref, a way whose refs all dangle, a way of
    one repeated node, and nodes with NaN and out of range coordinates.
  * A relation and a bounds element, so the parser proves it skips what it
    does not understand.

A matching districts GeoJSON is emitted alongside. Its dividing line sits at
0.37 of a block rather than on a column, so that no segment midpoint lands
exactly on a boundary, where point in polygon is undefined for everyone.
"""

from __future__ import annotations

import argparse
import gzip
import json
import math
import os
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple
from xml.sax.saxutils import quoteattr

EARTH_RADIUS_M = 6_371_008.8
DEG_TO_RAD = math.pi / 180.0
METRES_PER_DEGREE_LAT = EARTH_RADIUS_M * DEG_TO_RAD

# The fixture places specific features at specific grid positions, so it needs
# a grid at least this big. Smaller is rejected rather than silently degraded.
MIN_ROWS = 5
MIN_COLS = 6

GRID_NODE_BASE = 100_000
ROW_WAY_BASE = 1_000
COL_WAY_BASE = 2_000

WAY_MOTORWAY = 3_001
WAY_FOOT_NO = 3_002
WAY_ACCESS_PRIVATE = 3_003
WAY_TRUNK = 3_004
WAY_CYCLEWAY = 3_005
WAY_NOT_A_HIGHWAY = 3_006

WAY_LOOP = 4_001
WAY_SHORT_STUB = 5_001

WAY_MISSING_REF = 6_001
WAY_ALL_REFS_DANGLE = 6_002
WAY_ALL_DUPLICATE_NODES = 6_003
WAY_INVALID_COORD_NODES = 6_004

# Node ids for the non grid features.
NODE_BEND_PLAIN = 900_001
NODE_BEND_MOTORWAY = 900_002
NODE_BEND_FOOT_NO = 900_003
NODE_BEND_ACCESS_PRIVATE = 900_004

NODE_LOOP_A = 900_101
NODE_LOOP_B = 900_102
NODE_LOOP_C = 900_103
NODE_LOOP_D = 900_104

NODE_SHORT_STUB_END = 900_201
NODE_MISSING_REF_END = 900_301
NODE_LONELY_DUPLICATE = 900_401
NODE_NAN_LAT = 900_501
NODE_LAT_OUT_OF_RANGE = 900_502
NODE_INVALID_WAY_END = 900_503

DANGLING_REFS = (999_999_901, 999_999_902, 999_999_903)

# Classes are cycled if the grid is larger than these lists. Column 4 is a
# service road on purpose: it is an optional class, so the meta table's
# total_length_m must exclude it while segment_count includes it.
ROW_HIGHWAYS = ("primary", "secondary", "residential", "tertiary", "living_street")
COL_HIGHWAYS = ("unclassified", "residential", "footway", "pedestrian", "service", "residential")

ORDINALS = (
    "First", "Second", "Third", "Fourth", "Fifth",
    "Sixth", "Seventh", "Eighth", "Ninth", "Tenth",
)


@dataclass
class FixtureNode:
    """A node as it will be written, keeping the raw attribute text so that
    deliberately unparsable coordinates survive to the XML."""

    id: int
    lat_text: str
    lon_text: str
    valid: bool = True
    lat: float = 0.0
    lon: float = 0.0


@dataclass
class FixtureWay:
    id: int
    refs: List[int]
    tags: Dict[str, str] = field(default_factory=dict)


@dataclass
class Fixture:
    rows: int
    cols: int
    spacing_m: float
    lat0: float
    lon0: float
    nodes: List[FixtureNode] = field(default_factory=list)
    ways: List[FixtureWay] = field(default_factory=list)
    split_lon: float = 0.0

    # ---------------- grid helpers, used by the tests ----------------

    @property
    def d_lat(self) -> float:
        return self.spacing_m / METRES_PER_DEGREE_LAT

    @property
    def d_lon(self) -> float:
        return self.spacing_m / (METRES_PER_DEGREE_LAT * math.cos(self.lat0 * DEG_TO_RAD))

    def grid_node_id(self, row: int, col: int) -> int:
        return GRID_NODE_BASE + row * 1000 + col

    def grid_coord(self, row: int, col: int) -> Tuple[float, float]:
        return (self.lat0 + row * self.d_lat, self.lon0 + col * self.d_lon)

    def row_way_id(self, row: int) -> int:
        return ROW_WAY_BASE + row

    def col_way_id(self, col: int) -> int:
        return COL_WAY_BASE + col

    def row_highway(self, row: int) -> str:
        return ROW_HIGHWAYS[row % len(ROW_HIGHWAYS)]

    def col_highway(self, col: int) -> str:
        return COL_HIGHWAYS[col % len(COL_HIGHWAYS)]

    def coord_of(self, node_id: int) -> Tuple[float, float]:
        for node in self.nodes:
            if node.id == node_id:
                if not node.valid:
                    raise KeyError(f"node {node_id} has deliberately invalid coordinates")
                return (node.lat, node.lon)
        raise KeyError(f"no node {node_id} in fixture")

    # ---------------- expectations the tests assert against ----------------

    @property
    def excluded_way_ids(self) -> Tuple[int, ...]:
        return (
            WAY_MOTORWAY,
            WAY_FOOT_NO,
            WAY_ACCESS_PRIVATE,
            WAY_TRUNK,
            WAY_CYCLEWAY,
            WAY_NOT_A_HIGHWAY,
        )

    @property
    def interior_vertex_node_ids(self) -> Tuple[int, ...]:
        """Vertices that must stay inside a segment and never cause a split."""
        return (
            NODE_BEND_PLAIN,
            NODE_BEND_MOTORWAY,
            NODE_BEND_FOOT_NO,
            NODE_BEND_ACCESS_PRIVATE,
        )

    @property
    def expected_grid_segment_count(self) -> int:
        return self.rows * (self.cols - 1) + self.cols * (self.rows - 1)

    @property
    def expected_segment_count(self) -> int:
        # Grid, plus three from the self touching loop, plus one each from the
        # two malformed ways that still have two usable nodes. The short stub
        # contributes nothing because the minimum length filter drops it.
        return self.expected_grid_segment_count + 3 + 1 + 1

    # ---------------- emission ----------------

    def to_osm_xml(self) -> str:
        parts: List[str] = [
            '<?xml version="1.0" encoding="UTF-8"?>',
            '<osm version="0.6" generator="make_fixture.py">',
            '  <note>Synthetic fixture. Not derived from OpenStreetMap data.</note>',
            '  <meta osm_base="2026-01-01T00:00:00Z"/>',
            "  <bounds{}/>".format(self._bounds_attributes()),
        ]
        for node in self.nodes:
            parts.append(
                f'  <node id="{node.id}" lat="{node.lat_text}" lon="{node.lon_text}" version="1"/>'
            )
        for way in self.ways:
            parts.append(f'  <way id="{way.id}" version="1">')
            for ref in way.refs:
                parts.append(f'    <nd ref="{ref}"/>')
            for key, value in way.tags.items():
                parts.append(f"    <tag k={quoteattr(key)} v={quoteattr(value)}/>")
            parts.append("  </way>")

        # One relation, so the parser proves it skips and frees what it does
        # not understand instead of choking on it.
        parts.append('  <relation id="7001" version="1">')
        parts.append(f'    <member type="way" ref="{self.row_way_id(0)}" role="outer"/>')
        parts.append('    <tag k="type" v="multipolygon"/>')
        parts.append("  </relation>")
        parts.append("</osm>")
        return "\n".join(parts) + "\n"

    def _bounds_attributes(self) -> str:
        lats = [n.lat for n in self.nodes if n.valid]
        lons = [n.lon for n in self.nodes if n.valid]
        return (
            f' minlat="{min(lats):.7f}" minlon="{min(lons):.7f}"'
            f' maxlat="{max(lats):.7f}" maxlon="{max(lons):.7f}"'
        )

    def to_districts_geojson(self) -> dict:
        """Two adjacent districts covering the grid, plus an empty one.

        "Riverside" is a MultiPolygon well away from any street: it checks
        that MultiPolygon parsing works and that a district with no segments
        still gets a row with zero totals.
        """
        west_edge = self.lon0 - 5 * self.d_lon
        east_edge = self.lon0 + (self.cols - 1 + 10) * self.d_lon
        south_edge = self.lat0 - 5 * self.d_lat
        north_edge = self.lat0 + (self.rows - 1 + 5) * self.d_lat
        split = self.split_lon

        def rectangle(min_lon: float, min_lat: float, max_lon: float, max_lat: float) -> List[List[List[float]]]:
            return [[
                [min_lon, min_lat],
                [max_lon, min_lat],
                [max_lon, max_lat],
                [min_lon, max_lat],
                [min_lon, min_lat],
            ]]

        far_south = self.lat0 - 20 * self.d_lat
        return {
            "type": "FeatureCollection",
            "features": [
                {
                    "type": "Feature",
                    "properties": {"name": "West Side"},
                    "geometry": {
                        "type": "Polygon",
                        "coordinates": rectangle(west_edge, south_edge, split, north_edge),
                    },
                },
                {
                    "type": "Feature",
                    "properties": {"name": "East Side"},
                    "geometry": {
                        "type": "Polygon",
                        "coordinates": rectangle(split, south_edge, east_edge, north_edge),
                    },
                },
                {
                    "type": "Feature",
                    "properties": {"name": "Riverside"},
                    "geometry": {
                        "type": "MultiPolygon",
                        "coordinates": [
                            rectangle(west_edge, far_south, west_edge + 2 * self.d_lon, far_south + 2 * self.d_lat),
                            rectangle(west_edge + 3 * self.d_lon, far_south, west_edge + 5 * self.d_lon, far_south + 2 * self.d_lat),
                        ],
                    },
                },
            ],
        }


def _ordinal(index: int) -> str:
    return ORDINALS[index] if index < len(ORDINALS) else f"Number {index + 1}"


def generate(
    rows: int = 5,
    cols: int = 6,
    spacing_m: float = 100.0,
    lat0: float = 40.7000,
    lon0: float = -74.0000,
) -> Fixture:
    """Build the fixture in memory. Deterministic: no randomness anywhere."""
    if rows < MIN_ROWS or cols < MIN_COLS:
        raise ValueError(
            f"fixture needs at least {MIN_ROWS} rows and {MIN_COLS} columns "
            "so that its bends, loop and malformed ways have room"
        )

    fixture = Fixture(rows=rows, cols=cols, spacing_m=spacing_m, lat0=lat0, lon0=lon0)
    d_lat = fixture.d_lat
    d_lon = fixture.d_lon

    def metres_to_lat(metres: float) -> float:
        return metres / METRES_PER_DEGREE_LAT

    def metres_to_lon(metres: float) -> float:
        return metres / (METRES_PER_DEGREE_LAT * math.cos(lat0 * DEG_TO_RAD))

    def add_node(node_id: int, lat: float, lon: float) -> None:
        fixture.nodes.append(
            FixtureNode(
                id=node_id,
                lat_text=f"{lat:.7f}",
                lon_text=f"{lon:.7f}",
                valid=True,
                lat=lat,
                lon=lon,
            )
        )

    def add_raw_node(node_id: int, lat_text: str, lon_text: str) -> None:
        fixture.nodes.append(
            FixtureNode(id=node_id, lat_text=lat_text, lon_text=lon_text, valid=False)
        )

    def offset(base: Tuple[float, float], east_m: float, north_m: float) -> Tuple[float, float]:
        return (base[0] + metres_to_lat(north_m), base[1] + metres_to_lon(east_m))

    # ---- the grid itself ----
    for row in range(rows):
        for col in range(cols):
            lat, lon = fixture.grid_coord(row, col)
            add_node(fixture.grid_node_id(row, col), lat, lon)

    # ---- interior vertices that must never become split points ----
    # Each sits half way along a block and is pushed sideways so it is a real
    # bend, which also makes the block measurably longer than the straight
    # line between its ends.
    bend_offset = 0.25 * spacing_m

    def midpoint_of(a: Tuple[float, float], b: Tuple[float, float]) -> Tuple[float, float]:
        return ((a[0] + b[0]) / 2.0, (a[1] + b[1]) / 2.0)

    bend_plain = offset(midpoint_of(fixture.grid_coord(1, 2), fixture.grid_coord(1, 3)), 0.0, bend_offset)
    bend_motorway = offset(midpoint_of(fixture.grid_coord(3, 1), fixture.grid_coord(3, 2)), 0.0, bend_offset)
    bend_foot_no = offset(midpoint_of(fixture.grid_coord(2, 3), fixture.grid_coord(2, 4)), 0.0, bend_offset)
    bend_private = offset(midpoint_of(fixture.grid_coord(1, 1), fixture.grid_coord(2, 1)), bend_offset, 0.0)

    add_node(NODE_BEND_PLAIN, *bend_plain)
    add_node(NODE_BEND_MOTORWAY, *bend_motorway)
    add_node(NODE_BEND_FOOT_NO, *bend_foot_no)
    add_node(NODE_BEND_ACCESS_PRIVATE, *bend_private)

    # ---- row ways: one way spanning every column ----
    for row in range(rows):
        refs: List[int] = []
        for col in range(cols):
            refs.append(fixture.grid_node_id(row, col))
            if row == 1 and col == 2:
                refs.append(NODE_BEND_PLAIN)
            if row == 3 and col == 1:
                refs.append(NODE_BEND_MOTORWAY)
            if row == 2 and col == 3:
                refs.append(NODE_BEND_FOOT_NO)
        fixture.ways.append(
            FixtureWay(
                id=fixture.row_way_id(row),
                refs=refs,
                tags={"highway": fixture.row_highway(row), "name": f"{_ordinal(row)} Street"},
            )
        )

    # ---- column ways: one way spanning every row ----
    for col in range(cols):
        refs = []
        for row in range(rows):
            refs.append(fixture.grid_node_id(row, col))
            if col == 1 and row == 1:
                refs.append(NODE_BEND_ACCESS_PRIVATE)
        fixture.ways.append(
            FixtureWay(
                id=fixture.col_way_id(col),
                refs=refs,
                tags={"highway": fixture.col_highway(col), "name": f"{_ordinal(col)} Avenue"},
            )
        )

    # ---- ways that must be excluded ----
    # The first three run through a bend on a kept way. If the builder counted
    # node references before applying the filter, those bends would look like
    # intersections and the kept way would be split one block too many.
    #
    # Helper nodes get ids from a single counter so that two features can
    # never be handed the same id, which is the kind of quiet collision that
    # makes a fixture lie to you.
    next_helper_id = [950_000]

    def new_node(lat: float, lon: float) -> int:
        node_id = next_helper_id[0]
        next_helper_id[0] += 1
        add_node(node_id, lat, lon)
        return node_id

    def crossing(node_id: int, centre: Tuple[float, float], east_m: float, north_m: float) -> List[int]:
        """A two block way passing straight through an existing node."""
        before = new_node(*offset(centre, -east_m, -north_m))
        after = new_node(*offset(centre, east_m, north_m))
        return [before, node_id, after]

    fixture.ways.append(
        FixtureWay(
            id=WAY_MOTORWAY,
            refs=crossing(NODE_BEND_MOTORWAY, bend_motorway, 0.0, 60.0),
            tags={"highway": "motorway", "name": "Cross Town Expressway"},
        )
    )
    fixture.ways.append(
        FixtureWay(
            id=WAY_FOOT_NO,
            refs=crossing(NODE_BEND_FOOT_NO, bend_foot_no, 0.0, 60.0),
            tags={"highway": "residential", "foot": "no", "name": "No Pedestrians Road"},
        )
    )
    fixture.ways.append(
        FixtureWay(
            id=WAY_ACCESS_PRIVATE,
            refs=crossing(NODE_BEND_ACCESS_PRIVATE, bend_private, 60.0, 0.0),
            tags={"highway": "residential", "access": "private", "name": "Private Drive"},
        )
    )

    def standalone_pair(base: Tuple[float, float]) -> List[int]:
        """Two nodes 90 m apart, touching nothing else in the fixture."""
        return [new_node(*base), new_node(*offset(base, 90.0, 0.0))]

    fixture.ways.append(
        FixtureWay(
            id=WAY_TRUNK,
            refs=standalone_pair(offset(fixture.grid_coord(0, 0), -300.0, -300.0)),
            tags={"highway": "trunk", "name": "Trunk Road"},
        )
    )
    fixture.ways.append(
        FixtureWay(
            id=WAY_CYCLEWAY,
            refs=standalone_pair(offset(fixture.grid_coord(0, 0), -300.0, -200.0)),
            tags={"highway": "cycleway", "name": "Canal Cycleway"},
        )
    )
    building_base = offset(fixture.grid_coord(0, 0), -300.0, -100.0)
    building_refs = standalone_pair(building_base)
    building_refs.append(new_node(*offset(building_base, 90.0, 90.0)))
    fixture.ways.append(
        FixtureWay(
            id=WAY_NOT_A_HIGHWAY,
            # A closed ring with no highway tag: a building outline, which the
            # filter must reject before it ever looks at geometry.
            refs=building_refs + [building_refs[0]],
            tags={"building": "yes", "name": "Corner Warehouse"},
        )
    )

    # ---- self touching loop, anchored to the grid so the graph stays whole ----
    anchor = fixture.grid_coord(rows - 1, cols - 1)
    loop_a = offset(anchor, 60.0, 0.0)
    loop_b = offset(loop_a, 50.0, 60.0)
    loop_c = offset(loop_a, 90.0, -10.0)
    loop_d = offset(loop_a, 0.0, -70.0)
    add_node(NODE_LOOP_A, *loop_a)
    add_node(NODE_LOOP_B, *loop_b)
    add_node(NODE_LOOP_C, *loop_c)
    add_node(NODE_LOOP_D, *loop_d)
    fixture.ways.append(
        FixtureWay(
            id=WAY_LOOP,
            # B is repeated on purpose: consecutive duplicates must collapse.
            # A appears twice non consecutively, which is a genuine junction.
            refs=[
                fixture.grid_node_id(rows - 1, cols - 1),
                NODE_LOOP_A,
                NODE_LOOP_B,
                NODE_LOOP_B,
                NODE_LOOP_C,
                NODE_LOOP_A,
                NODE_LOOP_D,
            ],
            tags={"highway": "path", "name": "Park Loop"},
        )
    )

    # ---- a stub below the minimum segment length ----
    add_node(NODE_SHORT_STUB_END, *offset(fixture.grid_coord(0, 0), 1.0, 0.0))
    fixture.ways.append(
        FixtureWay(
            id=WAY_SHORT_STUB,
            refs=[fixture.grid_node_id(0, 0), NODE_SHORT_STUB_END],
            tags={"highway": "footway", "name": "Kerb Link"},
        )
    )

    # ---- malformed ways ----
    add_node(NODE_MISSING_REF_END, *offset(fixture.grid_coord(0, 0), 0.0, -80.0))
    fixture.ways.append(
        FixtureWay(
            id=WAY_MISSING_REF,
            refs=[fixture.grid_node_id(0, 0), DANGLING_REFS[0], NODE_MISSING_REF_END],
            tags={"highway": "residential", "name": "Broken Ref Lane"},
        )
    )
    fixture.ways.append(
        FixtureWay(
            id=WAY_ALL_REFS_DANGLE,
            refs=[DANGLING_REFS[1], DANGLING_REFS[2]],
            tags={"highway": "footway", "name": "Ghost Path"},
        )
    )
    add_node(NODE_LONELY_DUPLICATE, *offset(fixture.grid_coord(0, 0), -200.0, -200.0))
    fixture.ways.append(
        FixtureWay(
            id=WAY_ALL_DUPLICATE_NODES,
            refs=[NODE_LONELY_DUPLICATE, NODE_LONELY_DUPLICATE, NODE_LONELY_DUPLICATE],
            tags={"highway": "footway", "name": "Pinhead Path"},
        )
    )
    add_raw_node(NODE_NAN_LAT, "nan", f"{lon0:.7f}")
    add_raw_node(NODE_LAT_OUT_OF_RANGE, "91.5000000", f"{lon0:.7f}")
    add_node(NODE_INVALID_WAY_END, *offset(fixture.grid_coord(2, 0), -90.0, 0.0))
    fixture.ways.append(
        FixtureWay(
            id=WAY_INVALID_COORD_NODES,
            refs=[
                fixture.grid_node_id(2, 0),
                NODE_NAN_LAT,
                NODE_LAT_OUT_OF_RANGE,
                NODE_INVALID_WAY_END,
            ],
            tags={"highway": "residential", "name": "Bad Coordinate Row"},
        )
    )

    # District divider: 0.37 of a block west of a column, so that no segment
    # midpoint (which lands on a column or half way between two) can sit
    # exactly on it and make the point in polygon test a coin toss.
    fixture.split_lon = lon0 + (cols // 2 - 0.37) * d_lon

    return fixture


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="make_fixture.py",
        description="Write a synthetic OSM XML fixture and a matching districts GeoJSON.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    parser.add_argument("--rows", type=int, default=5, help=f"grid rows (minimum {MIN_ROWS})")
    parser.add_argument("--cols", type=int, default=6, help=f"grid columns (minimum {MIN_COLS})")
    parser.add_argument("--spacing", type=float, default=100.0, metavar="METRES", help="block length")
    parser.add_argument("--lat", type=float, default=40.7000, help="latitude of the grid origin")
    parser.add_argument("--lon", type=float, default=-74.0000, help="longitude of the grid origin")
    parser.add_argument("--out", default="fixture.osm", help="path for the OSM XML output")
    parser.add_argument(
        "--districts-out",
        default="fixture-districts.geojson",
        help="path for the districts GeoJSON output",
    )
    parser.add_argument("--gzip", action="store_true", help="gzip the XML output as well")
    args = parser.parse_args(argv)

    try:
        fixture = generate(
            rows=args.rows, cols=args.cols, spacing_m=args.spacing, lat0=args.lat, lon0=args.lon
        )
    except ValueError as exc:
        print(f"cannot generate fixture: {exc}", file=sys.stderr)
        return 1

    xml = fixture.to_osm_xml()
    out_dir = os.path.dirname(os.path.abspath(args.out))
    os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write(xml)
    if args.gzip:
        with gzip.open(args.out + ".gz", "wt", encoding="utf-8") as handle:
            handle.write(xml)

    with open(args.districts_out, "w", encoding="utf-8") as handle:
        json.dump(fixture.to_districts_geojson(), handle, indent=2)
        handle.write("\n")

    print(
        f"wrote {args.out} ({len(fixture.nodes)} nodes, {len(fixture.ways)} ways) "
        f"and {args.districts_out}",
        file=sys.stderr,
    )
    print(f"expected segments after build: {fixture.expected_segment_count}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
