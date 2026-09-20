"""Port of GPXImporter's parsing and gap-splitting rules, checked against GPX
shapes real exporters produce. No Swift toolchain here, so this is the check."""
import xml.etree.ElementTree as ET
from datetime import datetime, timezone, timedelta

SESSION_GAP = 30*60

def parse_ts(t):
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S.%fZ"):
        try: return datetime.strptime(t, fmt).replace(tzinfo=timezone.utc)
        except ValueError: pass
    return None

def parse(xml):
    """Mirrors the delegate: trk boundaries flush, trkpt needs lat/lon/time."""
    tracks, skipped = [], 0
    root = ET.fromstring(xml)
    ns = {"g": root.tag.split("}")[0][1:]} if "}" in root.tag else {}
    def find(el, name):
        return el.findall(f".//g:{name}", ns) if ns else el.findall(f".//{name}")
    for trk in (find(root, "trk") or []):
        name_el = (find(trk, "name") or [None])[0]
        name = name_el.text.strip() if name_el is not None and name_el.text else None
        pts = []
        for p in find(trk, "trkpt"):
            lat, lon = p.get("lat"), p.get("lon")
            t_el = (find(p, "time") or [None])[0]
            if lat is None or lon is None or t_el is None or not t_el.text:
                skipped += 1; continue
            ts = parse_ts(t_el.text.strip())
            if ts is None: skipped += 1; continue
            la, lo = float(lat), float(lon)
            if not (-90 <= la <= 90 and -180 <= lo <= 180) or (la == 0 and lo == 0):
                skipped += 1; continue
            pts.append((ts, la, lo))
        pts.sort(key=lambda x: x[0])
        if len(pts) > 1: tracks.append((name, pts))
    return tracks, skipped

def split_on_gaps(tracks):
    out = []
    for name, pts in tracks:
        run = [pts[0]]
        for p in pts[1:]:
            gap = (p[0]-run[-1][0]).total_seconds()
            if gap > SESSION_GAP or gap < 0:
                if len(run) > 1: out.append((name, run))
                run = [p]
            else: run.append(p)
        if len(run) > 1: out.append((name, run))
    return out

def gpx(segments, ns=True, name="Morning walk"):
    head = '<gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1">' if ns else '<gpx version="1.1">'
    body = ""
    for seg in segments:
        body += f"<trk><name>{name}</name><trkseg>"
        for ts, la, lo, extra in seg:
            body += f'<trkpt lat="{la}" lon="{lo}">{extra}<time>{ts}</time></trkpt>'
        body += "</trkseg></trk>"
    return head + body + "</gpx>"

base = datetime(2024, 5, 1, 9, 0, tzinfo=timezone.utc)
def seq(n, start_min=0, step_s=5):
    return [((base+timedelta(minutes=start_min, seconds=i*step_s)).strftime("%Y-%m-%dT%H:%M:%SZ"),
             40.75+i*0.0001, -73.98+i*0.0001, "<ele>10.0</ele>") for i in range(n)]

fails = 0
def check(name, cond, extra=""):
    global fails
    print(("PASS " if cond else "FAIL ")+name+("" if cond else "  "+extra))
    if not cond: fails += 1

# Namespaced GPX (what Strava, Garmin and Apple export)
t, s = parse(gpx([seq(20)]))
check("namespaced GPX parses", len(t) == 1 and len(t[0][1]) == 20, f"{len(t)} tracks")
check("track name read", t and t[0][0] == "Morning walk")

# Namespace-less GPX (some tools omit it)
t, s = parse(gpx([seq(20)], ns=False))
check("GPX without a namespace parses", len(t) == 1 and len(t[0][1]) == 20)

# Gap splitting: one segment containing a whole day
t, _ = parse(gpx([seq(10) + seq(10, start_min=120)]))
split = split_on_gaps(t)
check("a 2 hour gap splits into two walks", len(split) == 2, f"{len(split)}")
t, _ = parse(gpx([seq(10) + seq(10, start_min=10)]))
check("a 10 minute gap stays one walk", len(split_on_gaps(t)) == 1)

# Malformed points are skipped, not fatal
bad = ('<gpx version="1.1"><trk><trkseg>'
       '<trkpt lat="40.7" lon="-74.0"><time>2024-05-01T09:00:00Z</time></trkpt>'
       '<trkpt lat="40.7"><time>2024-05-01T09:00:05Z</time></trkpt>'          # no lon
       '<trkpt lat="40.7" lon="-74.0"></trkpt>'                                # no time
       '<trkpt lat="91.0" lon="-74.0"><time>2024-05-01T09:00:15Z</time></trkpt>'  # out of range
       '<trkpt lat="0" lon="0"><time>2024-05-01T09:00:20Z</time></trkpt>'      # null island
       '<trkpt lat="40.7" lon="-74.0"><time>garbage</time></trkpt>'            # bad time
       '<trkpt lat="40.71" lon="-74.01"><time>2024-05-01T09:00:30Z</time></trkpt>'
       '</trkseg></trk></gpx>')
t, s = parse(bad)
check("malformed points skipped and counted", len(t) == 1 and len(t[0][1]) == 2 and s == 5, f"pts={len(t[0][1]) if t else 0} skipped={s}")

# Fractional seconds (Apple Health and some loggers)
frac = gpx([[("2024-05-01T09:00:0%d.500Z" % i, 40.75, -73.98, "") for i in range(5)]])
t, s = parse(frac)
check("fractional second timestamps parse", len(t) == 1 and len(t[0][1]) == 5, f"skipped={s}")

# Out of order points get sorted
unordered = ('<gpx version="1.1"><trk><trkseg>'
   '<trkpt lat="40.70" lon="-74.0"><time>2024-05-01T09:00:20Z</time></trkpt>'
   '<trkpt lat="40.71" lon="-74.0"><time>2024-05-01T09:00:10Z</time></trkpt>'
   '</trkseg></trk></gpx>')
t, _ = parse(unordered)
check("out of order points are sorted", t and t[0][1][0][0] < t[0][1][1][0])

# Single-point track is dropped (cannot describe a route)
t, _ = parse(gpx([seq(1)]))
check("single point track dropped", len(t) == 0)

# Multiple trk elements
t, _ = parse(gpx([seq(10), seq(10, start_min=200)]))
check("multiple trk elements become separate tracks", len(t) == 2, f"{len(t)}")

print(f"\n{'ALL PASS' if fails==0 else str(fails)+' FAILURES'}")
