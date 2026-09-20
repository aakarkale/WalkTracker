import math, random, sys
sys.path.insert(0, '.')
from matcher_ref import *

LAT0, LON0 = 40.7500, -73.9800
SPACING = 80.0          # metres between parallel streets: Manhattan cross-town spacing
N = 12

def node_coord(r, c):
    return (LAT0 + (r*SPACING)/MPD_LAT, LON0 + (c*SPACING)/mpd_lon(LAT0))

def build_grid():
    segs, sid = [], 1
    for r in range(N):
        for c in range(N):
            if c+1 < N:
                segs.append(Segment(sid, f"E {r} St", r*100+c, r*100+c+1,
                                    [node_coord(r,c), node_coord(r,c+1)])); sid += 1
            if r+1 < N:
                segs.append(Segment(sid, f"Ave {c}", r*100+c, (r+1)*100+c,
                                    [node_coord(r,c), node_coord(r+1,c)])); sid += 1
    return segs

def seg_lookup(segs):
    m = {}
    for s in segs: m[(s.start, s.end)] = s; m[(s.end, s.start)] = s
    return m

def random_walk_route(rng, steps=40):
    r, c = N//2, N//2
    route = [(r, c)]
    for _ in range(steps):
        opts = []
        if r+1 < N: opts.append((r+1,c))
        if r-1 >= 0: opts.append((r-1,c))
        if c+1 < N: opts.append((r,c+1))
        if c-1 >= 0: opts.append((r,c-1))
        nxt = rng.choice(opts)
        if len(route) > 1 and nxt == route[-2] and len(opts) > 1:
            opts.remove(nxt); nxt = rng.choice(opts)
        route.append(nxt)
        r, c = nxt
    return route

def simulate(route, rng, noise_sigma, speed=1.4, hz=1.0):
    pts, t = [], 0.0
    for i in range(len(route)-1):
        a = node_coord(*route[i]); b = node_coord(*route[i+1])
        d = haversine(a,b); n = max(2, int(d/(speed/hz)))
        brg = bearing(a,b)
        for k in range(n):
            u = k/n
            true = (a[0]+(b[0]-a[0])*u, a[1]+(b[1]-a[1])*u)
            nlat = rng.gauss(0, noise_sigma)/MPD_LAT
            nlon = rng.gauss(0, noise_sigma)/mpd_lon(LAT0)
            pts.append({"t": t, "coord": (true[0]+nlat, true[1]+nlon),
                        "acc": max(5.0, rng.gauss(noise_sigma, noise_sigma*0.25)),
                        "speed": speed, "course": (brg + rng.gauss(0, 20)) % 360})
            t += 1.0/hz
    return pts

def true_segments(route, lut):
    out = {}
    for i in range(len(route)-1):
        a = route[i][0]*100+route[i][1]; b = route[i+1][0]*100+route[i+1][1]
        s = lut[(a,b)]
        out[s.id] = s.geo.length          # unique blocks: revisits must not inflate the denominator
    return out

def run(noise, seed, steps=40):
    rng = random.Random(seed)
    segs = build_grid(); lut = seg_lookup(segs); ix = Index(segs)
    route = random_walk_route(rng, steps)
    truth = true_segments(route, lut)
    pts = simulate(route, rng, noise)
    m = Matcher(ix)
    claims = []
    for p in pts: claims.extend(m.ingest(p))
    claims.extend(m.flush())

    covered = {}
    for sid, f0, f1, _ in claims:
        covered.setdefault(sid, IntervalSetLite()).insert(f0, f1)

    claimed_m = {sid: iv.coverage*ix.get(sid).geo.length for sid, iv in covered.items()}
    tp = sum(v for sid, v in claimed_m.items() if sid in truth)
    fp = sum(v for sid, v in claimed_m.items() if sid not in truth)
    total_truth = sum(truth.values())
    recall = tp/total_truth if total_truth else 0
    precision = tp/(tp+fp) if (tp+fp) else 0
    wrong_streets = len([sid for sid in claimed_m if sid not in truth])
    return precision, recall, wrong_streets, len(truth)

class IntervalSetLite:
    EPS=1e-3
    def __init__(self): self.iv=[]
    def insert(self,a,b):
        lo,hi=max(0,min(a,b)),min(1,max(a,b))
        if hi-lo<=0: return
        merged=(lo,hi); res=[]; ins=False
        for e in self.iv:
            if e[1]+self.EPS<merged[0]: res.append(e)
            elif merged[1]+self.EPS<e[0]:
                if not ins: res.append(merged); ins=True
                res.append(e)
            else: merged=(min(merged[0],e[0]),max(merged[1],e[1]))
        if not ins: res.append(merged)
        res.sort(); self.iv=res
    @property
    def coverage(self): return sum(b-a for a,b in self.iv)

if __name__ == "__main__":
    print(f"{'noise':>6} {'precision':>10} {'recall':>8} {'wrong streets':>14}  (10 routes each, 80m grid)")
    print("-"*56)
    for noise in (5, 10, 15, 20, 25):
        ps, rs, ws = [], [], []
        for seed in range(10):
            p, r, w, nt = run(noise, seed)
            ps.append(p); rs.append(r); ws.append(w)
        print(f"{noise:>5}m {sum(ps)/len(ps):>10.3f} {sum(rs)/len(rs):>8.3f} {sum(ws)/len(ws):>14.1f}")

