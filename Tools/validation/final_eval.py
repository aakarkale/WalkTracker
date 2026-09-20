import sys, random; sys.path.insert(0,'.')
from matcher_ref import *
from smoother import Smoother
from sim import build_grid, seg_lookup, random_walk_route, simulate, true_segments, IntervalSetLite

BEST = dict(CFG, bear_mode="cos", bear_w=5.0, adj_pen=2.0)
SMOOTH = 8.0

def run(noise, seed, steps=40, cfg=BEST, smooth=SMOOTH):
    rng = random.Random(seed)
    segs = build_grid(); lut = seg_lookup(segs); ix = Index(segs)
    route = random_walk_route(rng, steps)
    truth = true_segments(route, lut)
    pts = simulate(route, rng, noise)
    m = Matcher(ix, cfg); claims=[]
    sm = Smoother(smooth) if smooth else None
    for p in pts:
        for q in (sm.push(p) if sm else [p]): claims.extend(m.ingest(q))
    if sm:
        for q in sm.flush(): claims.extend(m.ingest(q))
    claims.extend(m.flush())
    cov={}
    for sid,f0,f1,_ in claims: cov.setdefault(sid, IntervalSetLite()).insert(f0,f1)
    cm={sid: iv.coverage*ix.get(sid).geo.length for sid,iv in cov.items()}
    tp=sum(v for sid,v in cm.items() if sid in truth)
    fp=sum(v for sid,v in cm.items() if sid not in truth)
    tt=sum(truth.values())
    blocks_found = len([s for s in cm if s in truth and cm[s]/ix.get(s).geo.length >= 0.7])
    return (tp/(tp+fp) if tp+fp else 0), (tp/tt if tt else 0), blocks_found, len(truth)

print("Chosen config: cosine bearing term, 8s pre-smoothing, adjacent-turn penalty 2.0")
print("30 random routes per noise level, 80 m grid (Manhattan cross-street spacing)\n")
print(f"{'GPS noise':>10} {'precision':>10} {'recall':>8} {'blocks >=70% done':>19}")
print("-"*52)
for noise in (5,10,15,20,25):
    ps,rs,bf,bt=[],[],0,0
    for sd in range(30):
        p,r,b,t=run(noise,sd); ps.append(p); rs.append(r); bf+=b; bt+=t
    print(f"{noise:>9}m {sum(ps)/len(ps):>10.3f} {sum(rs)/len(rs):>8.3f} {bf}/{bt:>13}")

print("\nStress cases at 20 m noise:")
for name, kw in [("short walk (8 blocks)", dict(steps=8)),
                 ("long walk (120 blocks)", dict(steps=120))]:
    ps,rs=[],[]
    for sd in range(20):
        p,r,_,_=run(20,sd,**kw); ps.append(p); rs.append(r)
    print(f"  {name:<24} precision {sum(ps)/len(ps):.3f}  recall {sum(rs)/len(rs):.3f}")

# Degenerate inputs must not crash or claim anything absurd.
segs=build_grid(); ix=Index(segs); m=Matcher(ix,BEST)
edge=[{"t":0,"coord":(0,0),"acc":10,"speed":1,"course":0},
      {"t":1,"coord":(40.75,-73.98),"acc":-1,"speed":1,"course":0},
      {"t":2,"coord":(40.75,-73.98),"acc":500,"speed":1,"course":0},
      {"t":3,"coord":(40.75,-73.98),"acc":10,"speed":30,"course":0},
      {"t":4,"coord":(91,200),"acc":10,"speed":1,"course":0}]
got=[]
for p in edge:
    try: got.extend(m.ingest(p))
    except Exception as e: print("  CRASH on degenerate input:", e); break
else:
    got.extend(m.flush())
    print(f"\nDegenerate inputs (null island, negative/huge accuracy, vehicle speed,")
    print(f"  out-of-range coords): no crash, {len(got)} claims emitted")
