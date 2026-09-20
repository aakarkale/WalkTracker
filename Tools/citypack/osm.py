#!/usr/bin/env python3
"""Minimal streaming reader for the OpenStreetMap XML format.

Scope: the subset of OSM XML that the Overpass API and osmconvert emit, which
is the `<osm>` root holding `<node>`, `<way>` and `<relation>` children, with
`<tag k= v=>` and `<nd ref=>` inside them. Relations are recognised so that
they can be skipped and their memory released; nothing here interprets them.

Why hand rolled instead of a library: the build machine for city packs is
expected to be a plain checkout with no compiled extensions, so osmium, pyrosm
and lxml are all off the table. Everything below is standard library.

Why streaming: a single city extract is hundreds of megabytes of XML and
`ET.parse` would hold the whole DOM. `iterparse` hands us one element at a
time, and clearing both the element and the root after each top level child
keeps the live tree at roughly one element regardless of input size.

Why counters instead of exceptions: real OSM extracts are always slightly
broken at the edges. A bounding box cut by Overpass leaves ways pointing at
nodes that were never sent, and a handful of nodes carry coordinates that are
out of range. A pack build that aborts on the first of those is useless, so bad
input is skipped and tallied, and the caller reports the tally.
"""

from __future__ import annotations

import contextlib
import dataclasses
import gzip
import math
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from typing import Dict, Iterator, List, Optional, Tuple

GZIP_MAGIC = b"\x1f\x8b"

# Children of <osm> that we recognise. Anything at this level gets cleared once
# it ends, whether or not the caller asked for it, so memory stays bounded.
TOP_LEVEL_TAGS = frozenset(("node", "way", "relation"))


class OSMParseError(Exception):
    """The XML stream itself could not be read.

    This is deliberately distinct from the per element problems tracked in
    `ParseCounters`. A truncated or non XML file is a broken input that the
    operator has to fix, not a handful of dropped nodes we can work around.
    """


@dataclass(frozen=True)
class Node:
    """An OSM node reduced to the only three fields a city pack needs."""

    id: int
    lat: float
    lon: float


@dataclass
class Way:
    """An OSM way: an ordered list of node ids plus its tags."""

    id: int
    refs: List[int] = field(default_factory=list)
    tags: Dict[str, str] = field(default_factory=dict)


@dataclass
class ParseCounters:
    """Tally of input we had to skip, reported at the end of a build."""

    nodes_seen: int = 0
    nodes_missing_attrs: int = 0
    nodes_invalid_coords: int = 0
    ways_seen: int = 0
    ways_missing_id: int = 0
    way_refs_unparsable: int = 0
    relations_skipped: int = 0

    def as_dict(self) -> Dict[str, int]:
        return dataclasses.asdict(self)

    def any_problems(self) -> bool:
        d = self.as_dict()
        for key in ("nodes_seen", "ways_seen", "relations_skipped"):
            d.pop(key, None)
        return any(v for v in d.values())


def is_valid_coordinate(lat: float, lon: float) -> bool:
    """Reject coordinates that cannot describe a place on Earth.

    NaN and infinity get through `float()` happily ("nan" parses), and OSM
    extracts do occasionally carry a latitude past the poles from a bad import.
    Note that (0, 0) is deliberately *not* rejected here even though the app
    treats it as a no fix sentinel on the GPS side: in source data it is a real
    place, and the sentinel rule belongs to live location input, not to OSM.
    """
    if not (math.isfinite(lat) and math.isfinite(lon)):
        return False
    if lat < -90.0 or lat > 90.0:
        return False
    if lon < -180.0 or lon > 180.0:
        return False
    return True


@contextlib.contextmanager
def open_osm(path: str):
    """Open an .osm or .osm.gz file as a binary stream.

    Detection is by magic bytes rather than by extension, because extracts get
    renamed in transit often enough that trusting ".gz" is a way to fail on a
    Friday afternoon.
    """
    raw = open(path, "rb")
    try:
        magic = raw.read(len(GZIP_MAGIC))
        raw.seek(0)
        if magic == GZIP_MAGIC:
            stream = gzip.GzipFile(fileobj=raw, mode="rb")
            try:
                yield stream
            finally:
                stream.close()
        else:
            yield raw
    finally:
        raw.close()


def _node_from_element(elem: ET.Element, counters: ParseCounters) -> Optional[Node]:
    counters.nodes_seen += 1
    raw_id = elem.get("id")
    raw_lat = elem.get("lat")
    raw_lon = elem.get("lon")
    if raw_id is None or raw_lat is None or raw_lon is None:
        counters.nodes_missing_attrs += 1
        return None
    try:
        node_id = int(raw_id)
        lat = float(raw_lat)
        lon = float(raw_lon)
    except (TypeError, ValueError):
        counters.nodes_missing_attrs += 1
        return None
    if not is_valid_coordinate(lat, lon):
        counters.nodes_invalid_coords += 1
        return None
    return Node(id=node_id, lat=lat, lon=lon)


def _way_from_element(elem: ET.Element, counters: ParseCounters) -> Optional[Way]:
    counters.ways_seen += 1
    raw_id = elem.get("id")
    if raw_id is None:
        counters.ways_missing_id += 1
        return None
    try:
        way_id = int(raw_id)
    except (TypeError, ValueError):
        counters.ways_missing_id += 1
        return None

    refs: List[int] = []
    for nd in elem.findall("nd"):
        raw_ref = nd.get("ref")
        if raw_ref is None:
            counters.way_refs_unparsable += 1
            continue
        try:
            refs.append(int(raw_ref))
        except (TypeError, ValueError):
            counters.way_refs_unparsable += 1

    tags: Dict[str, str] = {}
    for tag in elem.findall("tag"):
        key = tag.get("k")
        value = tag.get("v")
        if key is None or value is None:
            continue
        tags[key] = value

    return Way(id=way_id, refs=refs, tags=tags)


def iter_elements(
    path: str,
    want: Tuple[str, ...] = ("node", "way"),
    counters: Optional[ParseCounters] = None,
) -> Iterator[Tuple[str, object]]:
    """Yield `(kind, obj)` for every wanted element, streaming and bounded.

    `kind` is "node" or "way"; `obj` is a `Node` or `Way`. Elements the caller
    did not ask for are still cleared, so passing `want=("way",)` costs a scan
    of the file but not the memory of its nodes.

    Including "relation" in `want` tallies relations in the counters. They are
    never yielded: nothing in a city pack is built from a relation.
    """
    if counters is None:
        counters = ParseCounters()
    wanted = frozenset(want)

    with open_osm(path) as stream:
        context = ET.iterparse(stream, events=("start", "end"))
        try:
            _, root = next(iter(context))
        except StopIteration:
            raise OSMParseError(f"{path}: file contains no XML elements")
        except ET.ParseError as exc:
            raise OSMParseError(f"{path}: not readable as XML ({exc})") from exc

        try:
            for event, elem in context:
                if event != "end":
                    continue
                tag = elem.tag
                if tag not in TOP_LEVEL_TAGS:
                    # <tag> and <nd> are read through their parent, and are
                    # freed when the parent is cleared just below.
                    continue

                if tag in wanted:
                    if tag == "node":
                        node = _node_from_element(elem, counters)
                        if node is not None:
                            yield ("node", node)
                    elif tag == "way":
                        way = _way_from_element(elem, counters)
                        if way is not None:
                            yield ("way", way)
                    elif tag == "relation":
                        # Tallied but never yielded, and only when the caller
                        # asked for relations, so that a caller making two
                        # passes over one file (ways, then nodes) does not
                        # count the same relations twice.
                        counters.relations_skipped += 1

                # Drop the element and detach it from the root. Without the
                # root clear, ElementTree keeps every finished child attached
                # and the "streaming" parse quietly builds the whole document.
                elem.clear()
                root.clear()
        except ET.ParseError as exc:
            raise OSMParseError(f"{path}: XML ended badly ({exc})") from exc


def iter_nodes(path: str, counters: Optional[ParseCounters] = None) -> Iterator[Node]:
    """Stream only the nodes of an extract."""
    for _, obj in iter_elements(path, want=("node",), counters=counters):
        yield obj  # type: ignore[misc]


def iter_ways(path: str, counters: Optional[ParseCounters] = None) -> Iterator[Way]:
    """Stream only the ways of an extract, tallying relations on the way past."""
    for _, obj in iter_elements(path, want=("way", "relation"), counters=counters):
        yield obj  # type: ignore[misc]


if __name__ == "__main__":
    import argparse
    import json
    import sys

    parser = argparse.ArgumentParser(
        description="Summarise an OSM XML or OSM XML gzip file without loading it into memory.",
    )
    parser.add_argument("input", help="path to a .osm or .osm.gz file")
    parser.add_argument(
        "--sample",
        type=int,
        default=0,
        metavar="N",
        help="also print the first N ways with their tags (default: 0)",
    )
    args = parser.parse_args()

    counts = ParseCounters()
    shown = 0
    for kind, obj in iter_elements(args.input, want=("node", "way"), counters=counts):
        if kind == "way" and shown < args.sample:
            shown += 1
            print(f"way {obj.id}: {len(obj.refs)} refs, tags={obj.tags}", file=sys.stderr)
    print(json.dumps(counts.as_dict(), indent=2))
