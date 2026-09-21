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
# else. Order is: south west north east city-id description.
#
# The city id is what the app matches a pack against, so every preset uses an
# id that exists in WalkTracker/Resources/cities.json. Building a pack under
# an id the catalog has never heard of produces a file the app will refuse,
# which is a confusing way to learn this.
preset() {
    case "$1" in
        manhattan)    echo "40.6980 -74.0250 40.8850 -73.9060 new-york Manhattan only, installs as New York" ;;
        brooklyn)     echo "40.5700 -74.0420 40.7400 -73.8330 new-york Brooklyn only, installs as New York" ;;
        new-york)     echo "40.4774 -74.2591 40.9176 -73.7004 new-york All five boroughs, large and slow" ;;
        paris)        echo "48.8156 2.2242 48.9022 2.4699 paris Paris" ;;
        *)            return 1 ;;
    esac
}

if [ "${1:-}" = "--list" ] || [ $# -eq 0 ]; then
    echo "Presets:"
    for p in manhattan brooklyn new-york paris; do
        printf "  %-12s %s\n" "$p" "$(preset "$p" | cut -d' ' -f6-)"
    done
    echo
    echo "Start with manhattan. It is the smallest useful piece of New York and"
    echo "finishes in a couple of minutes; all five boroughs can take much longer"
    echo "and the public Overpass servers may refuse a query that size."
    exit 0
fi

AREA="$1"

if [ $# -ge 6 ]; then
    # Explicit: area name doubles as the city id, and the catalog must have it.
    CITY_ID="$1"; CITY_NAME="${2:-$1}"
    SOUTH="$3"; WEST="$4"; NORTH="$5"; EAST="$6"
elif BOX=$(preset "$AREA"); then
    read -r SOUTH WEST NORTH EAST CITY_ID _ <<<"$BOX"
    CITY_NAME="${2:-}"
    if [ -z "$CITY_NAME" ]; then
        CITY_NAME=$(python3 -c '
import json, sys
cities = json.load(open("../../WalkTracker/Resources/cities.json"))["cities"]
print(next((c["name"] for c in cities if c["id"] == sys.argv[1]), sys.argv[1]))' "$CITY_ID")
    fi
else
    echo "No preset named '$AREA'. Run with --list, or pass a bounding box:" >&2
    echo "  $0 CITY_ID \"City Name\" SOUTH WEST NORTH EAST" >&2
    echo "CITY_ID must be one in WalkTracker/Resources/cities.json." >&2
    exit 1
fi

# Checked before spending minutes on a download that produces an unusable file.
if ! python3 -c '
import json, sys
cities = json.load(open("../../WalkTracker/Resources/cities.json"))["cities"]
sys.exit(0 if any(c["id"] == sys.argv[1] for c in cities) else 1)' "$CITY_ID" 2>/dev/null; then
    echo "'$CITY_ID' is not a city in WalkTracker/Resources/cities.json." >&2
    echo "The app refuses a pack whose city does not match the one you pick it" >&2
    echo "for, so add an entry there first or use an id that already exists." >&2
    exit 1
fi

OSM_FILE="${AREA}.osm"
ENDPOINT="${OVERPASS_URL:-https://overpass-api.de/api/interpreter}"

# The way filter matches the pack format's selection rules, so the download
# carries roughly what the pack will keep rather than the whole map.
QUERY="[out:xml][timeout:900];
(
  way[\"highway\"~\"^(footway|pedestrian|living_street|residential|unclassified|tertiary|secondary|primary|service|track|steps|path)\$\"](${SOUTH},${WEST},${NORTH},${EAST});
);
(._;>;);
out body;"

echo "Fetching ${CITY_NAME} (${AREA}) from ${ENDPOINT}"
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
