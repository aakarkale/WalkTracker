import sys, random; sys.path.insert(0,'.')
from matcher_ref import *
from smoother import Smoother
from sim import build_grid, seg_lookup, random_walk_route, simulate, true_segments, IntervalSetLite

def run(cfg, noise, seed, smooth_seconds):
    rng = random.Random(seed)
    segs = build_grid(); lut = seg_lookup(segs); ix = Index(segs)
    route = random_walk_route(rng, 40)
    truth = true_segments(route, lut)
    pts = simulate(route, rng, noise)

    m = Matcher(ix, cfg); claims=[]
    if smooth_seconds:
        sm = Smoother(smooth_seconds)
        for p in pts:
            for q in sm.push(p): claims.extend(m.ingest(q))
        for q in sm.flush(): claims.extend(m.ingest(q))
    else:
        for p in pts: claims.extend(m.ingest(p))
    claims.extend(m.flush())

    cov={}
    for sid,f0,f1,_ in claims: cov.setdefault(sid, IntervalSetLite()).insert(f0,f1)
    cm = {sid: iv.coverage*ix.get(sid).geo.length for sid,iv in cov.items()}
    tp = sum(v for sid,v in cm.items() if sid in truth)
    fp = sum(v for sid,v in cm.items() if sid not in truth)
    tt = sum(truth.values())
    return (tp/(tp+fp) if tp+fp else 0), (tp/tt if tt else 0)

def evaluate(name, cfg, smooth_seconds, noises=(10,15,20,25), seeds=12):
    rows=[]
    for noise in noises:
        ps, rs = [], []
        for sd in range(seeds):
            p, r = run(cfg, noise, sd, smooth_seconds)
            ps.append(p); rs.append(r)
        rows.append((noise, sum(ps)/len(ps), sum(rs)/len(rs)))
    f1s = [2*p*r/(p+r) if p+r else 0 for _,p,r in rows]
    print(f"{name:<34}", " ".join(f"{n}m P{p:.2f}/R{r:.2f}" for n,p,r in rows),
          f"  meanF1={sum(f1s)/len(f1s):.3f}")

base = dict(CFG)
variants = [
    ("baseline (step bearing, no smooth)", dict(base), 0),
    ("+ cos bearing w=5",                  dict(base, bear_mode="cos", bear_w=5.0), 0),
    ("+ smoothing 5s",                     dict(base), 5.0),
    ("+ cos bearing + smooth 5s",          dict(base, bear_mode="cos", bear_w=5.0), 5.0),
    ("+ cos + smooth 8s",                  dict(base, bear_mode="cos", bear_w=5.0), 8.0),
    ("+ cos + smooth 8s + adj_pen 2.0",    dict(base, bear_mode="cos", bear_w=5.0, adj_pen=2.0), 8.0),
    ("+ cos + smooth 8s + adj 2 + beta 8", dict(base, bear_mode="cos", bear_w=5.0, adj_pen=2.0, beta=8.0), 8.0),
    ("+ cos w=8 + smooth 8s + adj 2",      dict(base, bear_mode="cos", bear_w=8.0, adj_pen=2.0), 8.0),
]
print("P=precision (share of claimed distance actually walked), R=recall\n")
for n,c,s in variants: evaluate(n,c,s)
