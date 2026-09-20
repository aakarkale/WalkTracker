"""Faithful Python port of MapMatcher.swift, exercised on a synthetic grid city.

Purpose: this environment has no Swift toolchain, so the matching algorithm is
validated here instead. The port mirrors the Swift structure 1:1 so a defect in
the algorithm shows up in both.
"""
import math, random

R = 6371008.8
MPD_LAT = R * math.pi / 180
def mpd_lon(lat): return R * math.pi / 180 * math.cos(math.radians(lat))

def haversine(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp = math.radians(b[0]-a[0]); dl = math.radians(b[1]-a[1])
    h = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return 2*R*math.asin(min(1, math.sqrt(max(0,h))))

def bearing(a, b):
    p1, p2 = math.radians(a[0]), math.radians(b[0]); dl = math.radians(b[1]-a[1])
    y = math.sin(dl)*math.cos(p2)
    x = math.cos(p1)*math.sin(p2)-math.sin(p1)*math.cos(p2)*math.cos(dl)
    d = math.degrees(math.atan2(y,x))
    return d+360 if d < 0 else d

def bearing_delta(a,b):
    d = abs(a-b) % 360
    return 360-d if d > 180 else d

def project(c, origin):
    return ((c[1]-origin[1])*mpd_lon(origin[0]), (c[0]-origin[0])*MPD_LAT)

def unproject(p, origin):
    return (origin[0]+p[1]/MPD_LAT, origin[1]+p[0]/mpd_lon(origin[0]))

def proj_seg(p, a, b):
    vx, vy = b[0]-a[0], b[1]-a[1]
    L2 = vx*vx+vy*vy
    if L2 < 1e-12: return 0.0, math.hypot(p[0]-a[0], p[1]-a[1])
    t = max(0.0, min(1.0, ((p[0]-a[0])*vx + (p[1]-a[1])*vy)/L2))
    cx, cy = a[0]+t*vx, a[1]+t*vy
    return t, math.hypot(p[0]-cx, p[1]-cy)

class Polyline:
    def __init__(self, coords):
        self.coords = coords; self.origin = coords[0]
        self.pts = [project(c, coords[0]) for c in coords]
        self.cum = [0.0]
        for i in range(1, len(self.pts)):
            self.cum.append(self.cum[-1] + math.hypot(self.pts[i][0]-self.pts[i-1][0],
                                                      self.pts[i][1]-self.pts[i-1][1]))
        self.length = self.cum[-1]

    def project_point(self, c):
        p = project(c, self.origin)
        best = (float('inf'), 0.0, 1)
        for i in range(1, len(self.pts)):
            t, d = proj_seg(p, self.pts[i-1], self.pts[i])
            if d < best[0]:
                off = self.cum[i-1] + t*(self.cum[i]-self.cum[i-1])
                best = (d, off, i)
        d, off, idx = best
        frac = min(1.0, max(0.0, off/self.length)) if self.length > 0 else 0.0
        return {"distance": d, "offset": off, "fraction": frac,
                "bearing": bearing(self.coords[idx-1], self.coords[idx])}

    def coord_at(self, f):
        t = max(0.0, min(1.0, f))*self.length
        if t <= 0: return self.coords[0]
        if t >= self.length: return self.coords[-1]
        lo, hi = 1, len(self.cum)-1
        while lo < hi:
            mid = (lo+hi)//2
            if self.cum[mid] < t: lo = mid+1
            else: hi = mid
        span = self.cum[lo]-self.cum[lo-1]
        u = (t-self.cum[lo-1])/span if span > 1e-9 else 0
        a, b = self.pts[lo-1], self.pts[lo]
        return unproject((a[0]+u*(b[0]-a[0]), a[1]+u*(b[1]-a[1])), self.origin)

class Segment:
    def __init__(self, sid, name, n0, n1, coords):
        self.id=sid; self.name=name; self.start=n0; self.end=n1; self.geo=Polyline(coords)
    def shared(self, o):
        if self.start in (o.start,o.end): return self.start
        if self.end in (o.start,o.end): return self.end
        return None

class Index:
    def __init__(self, segs):
        self.segs = {s.id: s for s in segs}
    def near(self, c, radius):
        out = []
        for s in self.segs.values():
            if s.geo.project_point(c)["distance"] <= radius: out.append(s)
        return out
    def get(self, sid): return self.segs.get(sid)

CFG = dict(radius=60.0, max_acc=30.0, min_sigma=8.0, beta=12.0, window=12,
           max_gap=90.0, max_speed=4.5, min_spacing=2.0,
           disc_pen=4.0, adj_pen=0.4, bear_tol=55.0, bear_pen=1.2, noise_k=3.0, despeckle=True,
           bear_mode="step", bear_w=5.0)

class Matcher:
    def __init__(self, index, cfg=CFG):
        self.ix=index; self.c=cfg; self.win=[]; self.last_pt=None; self.last_fin=None
        self.dec=[]   # settled decisions awaiting despeckle + bridging

    def _cands(self, pt):
        out=[]
        for s in self.ix.near(pt["coord"], self.c["radius"]):
            pr = s.geo.project_point(pt["coord"])
            if pr["distance"] <= self.c["radius"]: out.append((s, pr))
        return out

    def _emission(self, cand, sigma, pt):
        s, pr = cand
        z = pr["distance"]/sigma
        score = -0.5*z*z
        if pt["course"] >= 0 and pt["speed"] > 0.5:
            d = bearing_delta(pt["course"], pr["bearing"])
            if self.c["bear_mode"] == "cos":
                # (1-cos 2d)/2 is 0 when aligned and 1 when perpendicular, and
                # has period 180 so a two-way street scores the same either way.
                score -= self.c["bear_w"]*(1-math.cos(2*math.radians(d)))/2
            else:
                d = min(d, 180-d)
                if d > self.c["bear_tol"]: score -= self.c["bear_pen"]
        return score

    def _dist_to_node(self, node, seg, pr):
        return pr["offset"] if node == seg.start else max(0.0, seg.geo.length-pr["offset"])

    def _transition(self, prev, cur, gps_delta):
        ps, ppr = prev; cs, cpr = cur
        if ps.id == cs.id:
            route = abs(cpr["offset"]-ppr["offset"]); pen = 0.0
        else:
            node = ps.shared(cs)
            if node is not None:
                route = self._dist_to_node(node, ps, ppr) + self._dist_to_node(node, cs, cpr)
                pen = self.c["adj_pen"]
            else:
                a = ps.geo.coord_at(ppr["fraction"]); b = cs.geo.coord_at(cpr["fraction"])
                route = haversine(a,b); pen = self.c["disc_pen"]
        return -abs(gps_delta-route)/self.c["beta"] - pen

    def _advance(self, pt, cands):
        sigma = max(self.c["min_sigma"], pt["acc"])
        if not self.win:
            self.win.append({"pt":pt,"states":[{"cand":c,"score":self._emission(c,sigma,pt),"bp":None} for c in cands]})
            return
        prev = self.win[-1]
        gps = haversine(prev["pt"]["coord"], pt["coord"])
        states=[]
        for c in cands:
            em = self._emission(c, sigma, pt)
            best, bp = -float('inf'), None
            for i, st in enumerate(prev["states"]):
                tot = st["score"] + self._transition(st["cand"], c, gps)
                if tot > best: best, bp = tot, i
            if bp is None: continue
            states.append({"cand":c,"score":best+em,"bp":bp})
        if not states: return
        m = max(s["score"] for s in states)
        for s in states: s["score"] -= m
        self.win.append({"pt":pt,"states":states})

    def ingest(self, pt):
        if not (0 <= pt["acc"] <= self.c["max_acc"]): return []
        if pt["speed"] >= 0 and pt["speed"] > self.c["max_speed"]: return []
        if self.last_pt:
            el = pt["t"]-self.last_pt["t"]; mv = haversine(self.last_pt["coord"], pt["coord"])
            if el <= 0: return []
            if mv < self.c["min_spacing"] and el < 30: return []
            noise_allow = self.c["noise_k"]*(self.last_pt["acc"]+pt["acc"])
            if el > self.c["max_gap"] or mv > self.c["max_speed"]*el + noise_allow:
                f = self.flush(); self.last_pt = pt
                self.win=[]; self.last_fin=None; self.dec=[]
                cs = self._cands(pt)
                if cs: self._advance(pt, cs)
                return f
        cands = self._cands(pt)
        if not cands:
            f = self.flush(); self.last_pt = pt; return f
        self._advance(pt, cands); self.last_pt = pt
        if len(self.win) > self.c["window"]:
            return self._finalize_oldest() or []
        return []

    def _backtrace(self):
        if not self.win or not self.win[-1]["states"]: return None
        cur = max(range(len(self.win[-1]["states"])), key=lambda i: self.win[-1]["states"][i]["score"])
        for i in range(len(self.win)-1, 0, -1):
            if cur is None or cur >= len(self.win[i]["states"]): return None
            cur = self.win[i]["states"][cur]["bp"]
            if cur is None: return None
        if cur >= len(self.win[0]["states"]): return None
        return self.win[0]["states"][cur]["cand"]

    def _finalize_oldest(self):
        if not self.win: return None
        dec = self._backtrace()
        if dec is None:
            self.win.pop(0); return None
        step = self.win.pop(0)
        seg, pr = dec
        self.dec.append({"seg":seg,"frac":pr["fraction"],"t":step["pt"]["t"],
                         "coord":step["pt"]["coord"]})
        return self._drain(final=False)

    def _despeckle(self):
        # An isolated one-fix hop onto a different block, with the same block
        # either side, is GPS noise rather than a detour. Pull it back.
        if not self.c["despeckle"]: return
        i = len(self.dec)-2
        if i < 1: return
        a,b,c = self.dec[i-1], self.dec[i], self.dec[i+1]
        if a["seg"].id == c["seg"].id and b["seg"].id != a["seg"].id:
            pr = a["seg"].geo.project_point(b["coord"])
            self.dec[i] = {"seg":a["seg"],"frac":pr["fraction"],"t":b["t"],"coord":b["coord"]}

    def _drain(self, final):
        out=[]
        self._despeckle()
        keep = 1 if final else 3
        while len(self.dec) > keep:
            a, b = self.dec[0], self.dec[1]
            out.extend(self._bridge(a["seg"].id, a["frac"], b["seg"], b["frac"], b["t"]))
            self.dec.pop(0)
            if not final: break
        return out

    def _bridge(self, fid, ff, tseg, tf, ts):
        if fid == tseg.id:
            return [(fid, min(ff,tf), max(ff,tf), ts)]
        ps = self.ix.get(fid)
        node = ps.shared(tseg) if ps else None
        if node is None: return []
        exit_f = 1.0 if node == ps.end else 0.0
        entry_f = 0.0 if node == tseg.start else 1.0
        out = [(fid, min(ff,exit_f), max(ff,exit_f), ts),
               (tseg.id, min(entry_f,tf), max(entry_f,tf), ts)]
        return [c for c in out if c[2]-c[1] > 0]

    def flush(self):
        out=[]
        while self.win:
            r = self._finalize_oldest()
            if r: out.extend(r)
        out.extend(self._drain(final=True))
        self.dec=[]; self.last_fin=None; self.last_pt=None
        return [c for c in out if c[2]-c[1] > 0]

