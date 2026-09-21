#!/usr/bin/env bash
# Fetches street data for a city and builds a pack from it, in one step.
#
# Uses the Overpass API rather than a Geofabrik extract, because Overpass
# returns OSM XML, which is what build_pack.py reads. Geofabrik's downloads
# are PBF, which would need osmium or osmconvert in between.
#
#   ./fetch_and_build.sh manhattan "Manhattan"
#   ./fetch_and_build.sh --list
#
# A bounding box can also be given directly:
#   ./fetch_and_build.sh mycity "My City" 40.70 -74.02 40.88 -73.90
set -euo pipefail

cd "$(dirname "$0")"

# Bounding boxes are approximate and deliberately generous. Overpass clips to
# the box, so a little slack costs a few extra streets at the edge and nothing
# else. Order is south, west, north, east.
preset() {
    case "$1" in
        manhattan)    echo "40.6980 -74.0250 40.8850 -73.9060  Manhattan" ;;
        brooklyn)     echo "40.5700 -74.0420 40.7400 -73.8330  Brooklyn" ;;
        new-york)     echo "40.4774 -74.2591 40.9176 -73.7004  New York (all five boroughs, large)" ;;
        paris)        echo "48.8156 -2.2242 48.9022 2.4699  Paris" ;;
        *)            return 1 ;;
    esac
}

if [ "${1:-}" = "--list" ] || [ $# -eq 0 ]; then
    echo "Presets:"
    for p in manhattan brooklyn new-york paris; do
        printf "  %-12s %s\n" "$p" "$(preset "$p" | awk '{$1="";$2="";$3="";$4="";print substr($0,5)}')"
    done
    echo
    echo "Start with manhattan. It is the smallest useful piece of New York and"
    echo "finishes in a couple of minutes; all five boroughs can take much longer"
    echo "and the public Overpass servers may refuse a query that size."
    exit 0
fi

CITY_ID="$1"
CITY_NAME="${2:-$1}"

if [ $# -ge 6 ]; then
    SOUTH="$3"; WEST="$4"; NORTH="$5"; EAST="$6"
elif BOX=$(preset "$CITY_ID"); then
    read -r SOUTH WEST NORTH EAST _ <<<"$BOX"
else
    echo "No preset named '$CITY_ID'. Run with --list, or pass a bounding box:" >&2
    echo "  $0 $CITY_ID \"$CITY_NAME\" SOUTH WEST NORTH EAST" >&2
    exit 1
fi

OSM_FILE="${CITY_ID}.osm"
ENDPOINT="${OVERPASS_URL:-https://overpass-api.de/api/interpreter}"

# The way filter matches the pack format's selection rules, so the download
# carries roughly what the pack will keep rather than the whole map.
QUERY="[out:xml][timeout:900];
(
  way[\"highway\"~\"^(footway|pedestrian|living_street|residential|unclassified|tertiary|secondary|primary|service|track|steps|path)\$\"](${SOUTH},${WEST},${NORTH},${EAST});
);
(._;>;);
out body;"

echo "Fetching ${CITY_NAME} from ${ENDPOINT}"
echo "  bounding box: S ${SOUTH}  W ${WEST}  N ${NORTH}  E ${EAST}"
echo "  This can take several minutes. Overpass queues large queries."
echo

if ! curl --fail --show-error --location \
        --retry 2 --retry-delay 30 --max-time 1800 \
        --data-urlencode "data=${QUERY}" \
        -o "${OSM_FILE}" \
        "${ENDPOINT}"; then
    echo >&2
    echo "The download failed. Overpass rate-limits and rejects oversized queries." >&2
    echo "Try a smaller area, wait a few minutes, or set OVERPASS_URL to a mirror:" >&2
    echo "  OVERPASS_URL=https://overpass.kumi.systems/api/interpreter $0 $*" >&2
    exit 1
fi

SIZE=$(wc -c < "${OSM_FILE}")
if [ "${SIZE}" -lt 100000 ]; then
    echo >&2
    echo "Only ${SIZE} bytes came back, which is too small to be a city." >&2
    echo "Overpass usually explains why in the file itself:" >&2
    head -c 600 "${OSM_FILE}" >&2
    exit 1
fi

echo
echo "Downloaded ${SIZE} bytes. Building the pack."
echo
python3 build_pack.py "${OSM_FILE}" --city-id "${CITY_ID}" --city-name "${CITY_NAME}"

echo
echo "Done. To use it:"
echo "  1. Get ${CITY_ID}.v1.sqlite.gz onto your phone (AirDrop or iCloud Drive)."
echo "  2. In the app, open Cities, tap the city, and pick the file."
echo
echo "To publish it instead, host the file over HTTPS and paste the JSON above"
echo "into that city's \"pack\" field in WalkTracker/Resources/cities.json."
