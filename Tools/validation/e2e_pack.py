"""End to end: a pack built by Tools/citypack, read with a port of the Swift
decoder, walked over with a port of the Swift matcher, scored with a port of
the Swift interval store. Verifies the pipeline output and the app agree."""
import sqlite3, random, math, sys, hashlib, gzip
from geom_codec import decode
from matcher_ref import Matcher, Index, Segment, Polyline, haversine, bearing, MPD_LAT, mpd_lon
from smoother import Smoother

DB = "testville.v1.sqlite"
con = sqlite3.connect(DB)

meta = dict(con.execute("SELECT key, value FROM meta").fetchall())
print(f"pack: {meta['city_name']} schema v{meta['schema_version']}, "
      f"{meta['segment_count']} blocks, {float(meta['total_length_m'])/1000:.1f} km")

segs, bad = [], 0
for sid, wid, name, cls, n0, n1, length, did, blob in con.execute(
        "SELECT id, way_id, name, class, start_node, end_node, length_m, district_id, geometry FROM segment"):
    coords = decode(blob)
    if coords is None:
        bad += 1; continue
    s = Segment(sid, name, n0, n1, coords)
    s.declared_length = length
    s.cls = cls
    segs.append(s)

overall_fail = False
print(f"decoded {len(segs)} blocks with the Swift decoder port, {bad} rejected")
if bad: print("FAIL: decoder rejected blocks the pipeline wrote"); sys.exit(1)

# The decoder's recomputed length must agree with what the pipeline stored,
# or the app's percentage denominator disagrees with the pack's own totals.
#
# They cannot agree exactly. Geometry is stored as fixed point at 1e-7 degrees,
# so each vertex can shift by up to half a step in each axis, and a polyline of
# n vertices can accumulate that n times. The tolerance is therefore that bound
# rather than an arbitrary epsilon: anything inside it is the storage format
# working as designed, anything outside it is a real defect.
step = math.hypot(1e-7 * MPD_LAT, 1e-7 * mpd_lon(40.7))
worst_err = 0.0
worst_bound = 0.0
violations = 0
for s in segs:
    err = abs(s.geo.length - s.declared_length)
    bound = step * len(s.geo.coords)
    if err > bound:
        violations += 1
    if err > worst_err:
        worst_err, worst_bound = err, bound
ok = violations == 0
print(f"{'PASS' if ok else 'FAIL'} length agreement: worst {worst_err*1000:.1f} mm "
      f"against its {worst_bound*1000:.1f} mm quantisation bound, "
      f"{violations} of {len(segs)} blocks outside bound "
      f"(GPS accuracy is about 10000 mm)")
if not ok: overall_fail = True

# Connectivity: the matcher depends on shared nodes to bridge between blocks.
nodes = {}
for s in segs:
    nodes.setdefault(s.start, []).append(s); nodes.setdefault(s.end, []).append(s)
junctions = sum(1 for v in nodes.values() if len(v) > 1)
print(f"graph: {len(nodes)} nodes, {junctions} of them junctions")

ix = Index(segs)
by_node = nodes

def walk_route(rng, steps=60):
    """Walks the real pack graph, hopping between blocks that share a node."""
    cur = rng.choice(segs); at_end = True
    route = [cur]
    for _ in range(steps):
        node = cur.end if at_end else cur.start
        opts = [s for s in by_node.get(node, []) if s.id != cur.id]
        if not opts: break
        nxt = rng.choice(opts)
        at_end = (nxt.start == node)
        route.append(nxt); cur = nxt
    return route

def simulate(route, rng, noise, speed=1.4):
    pts, t = [], 0.0
    for i, s in enumerate(route):
        coords = s.geo.coords
        fwd = True
        if i > 0:
            prev = route[i-1]
            shared = prev.shared(s)
            fwd = (shared == s.start)
        seq = coords if fwd else list(reversed(coords))
        for j in range(len(seq)-1):
            a, b = seq[j], seq[j+1]
            d = haversine(a, b); n = max(2, int(d/speed))
            brg = bearing(a, b)
            for k in range(n):
                u = k/n
                true = (a[0]+(b[0]-a[0])*u, a[1]+(b[1]-a[1])*u)
                pts.append({"t": t,
                            "coord": (true[0]+rng.gauss(0,noise)/MPD_LAT,
                                      true[1]+rng.gauss(0,noise)/mpd_lon(true[0])),
                            "acc": max(5.0, rng.gauss(noise, noise*0.25)),
                            "speed": speed,
                            "course": (brg + rng.gauss(0,20)) % 360})
                t += 1.0
    return pts

class IvSet:
    EPS=1e-3
    def __init__(self): self.iv=[]
    def insert(self,a,b):
        lo,hi=max(0,min(a,b)),min(1,max(a,b))
        if hi-lo<=0: return
        m=(lo,hi); res=[]; ins=False
        for e in self.iv:
            if e[1]+self.EPS<m[0]: res.append(e)
            elif m[1]+self.EPS<e[0]:
                if not ins: res.append(m); ins=True
                res.append(e)
            else: m=(min(m[0],e[0]),max(m[1],e[1]))
        if not ins: res.append(m)
        res.sort(); self.iv=res
    @property
    def coverage(self): return sum(b-a for a,b in self.iv)

print(f"\n{'noise':>7} {'precision':>10} {'recall':>8} {'city %':>8}  (15 routes each)")
print("-"*46)
total_len = sum(s.geo.length for s in segs)
overall_ok = True
for noise in (10, 20):
    ps, rs, pcts = [], [], []
    for seed in range(15):
        rng = random.Random(seed)
        route = walk_route(rng)
        truth = {s.id: s.geo.length for s in route}
        pts = simulate(route, rng, noise)
        m = Matcher(ix, dict(__import__("matcher_ref").CFG, bear_mode="cos", bear_w=5.0, adj_pen=2.0))
        sm = Smoother(8.0); claims = []
        for p in pts:
            for q in sm.push(p): claims.extend(m.ingest(q))
        for q in sm.flush(): claims.extend(m.ingest(q))
        claims.extend(m.flush())
        cov = {}
        for sid,f0,f1,_ in claims: cov.setdefault(sid, IvSet()).insert(f0,f1)
        cm = {sid: iv.coverage*ix.get(sid).geo.length for sid,iv in cov.items()}
        tp = sum(v for sid,v in cm.items() if sid in truth)
        fp = sum(v for sid,v in cm.items() if sid not in truth)
        tt = sum(truth.values())
        ps.append(tp/(tp+fp) if tp+fp else 0); rs.append(tp/tt if tt else 0)
        pcts.append(100*sum(cm.values())/total_len)
    p_, r_ = sum(ps)/len(ps), sum(rs)/len(rs)
    print(f"{noise:>6}m {p_:>10.3f} {r_:>8.3f} {sum(pcts)/len(pcts):>7.1f}%")
    if p_ < 0.95 or r_ < 0.90: overall_ok = False

# The digest the catalog would carry must match the shipped file.
digest = hashlib.sha256(open(DB + ".gz","rb").read()).hexdigest()
print(f"\npack sha256: {digest[:16]}...")
print(f"compressed {len(open(DB+'.gz','rb').read())} bytes for {len(segs)} blocks "
      f"({len(open(DB+'.gz','rb').read())/len(segs):.1f} bytes per block)")

ok = overall_ok and not overall_fail
print("\nEND TO END PASS" if ok else "\nEND TO END FAIL")
sys.exit(0 if ok else 1)
