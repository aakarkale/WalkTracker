"""Python port of IntervalSet.swift merge logic, used to validate the algorithm
since no Swift toolchain exists in this environment."""
EPS = 1e-3

def clamp(v): return min(1.0, max(0.0, v))

class IntervalSet:
    def __init__(self, intervals=None):
        self.intervals = []
        for a, b in (intervals or []):
            self.insert(a, b)

    def insert(self, start, end):
        lo, hi = clamp(min(start, end)), clamp(max(start, end))
        if hi - lo <= 0:
            return
        merged = (lo, hi)
        result, inserted = [], False
        for ex in self.intervals:
            if ex[1] + EPS < merged[0]:
                result.append(ex)
            elif merged[1] + EPS < ex[0]:
                if not inserted:
                    result.append(merged); inserted = True
                result.append(ex)
            else:
                merged = (min(merged[0], ex[0]), max(merged[1], ex[1]))
        if not inserted:
            result.append(merged)
        result.sort()
        self.intervals = result

    @property
    def coverage(self):
        return sum(b - a for a, b in self.intervals)

    @property
    def gaps(self):
        if not self.intervals: return [(0.0, 1.0)]
        out, cursor = [], 0.0
        for a, b in self.intervals:
            if a - cursor > EPS: out.append((cursor, a))
            cursor = max(cursor, b)
        if 1.0 - cursor > EPS: out.append((cursor, 1.0))
        return out

def check(name, got, want):
    ok = got == want
    print(("PASS " if ok else "FAIL ") + name, "" if ok else f"got={got} want={want}")
    return ok

fails = 0
s = IntervalSet(); s.insert(0.0, 0.5); s.insert(0.5, 1.0)
fails += not check("adjacent halves merge", s.intervals, [(0.0, 1.0)])

s = IntervalSet(); s.insert(0.0, 0.3); s.insert(0.6, 1.0)
fails += not check("disjoint stay apart", s.intervals, [(0.0, 0.3), (0.6, 1.0)])
fails += not check("disjoint coverage", round(s.coverage, 6), 0.7)
fails += not check("gap found", [(round(a,6), round(b,6)) for a,b in s.gaps], [(0.3, 0.6)])

s = IntervalSet([(0.0,0.1),(0.2,0.3)]); s.insert(0.15, 0.25)
fails += not check("partial bridge", s.intervals, [(0.0,0.1),(0.15,0.3)])

s = IntervalSet([(0.0,0.1),(0.2,0.3)]); s.insert(0.1005, 0.25)
fails += not check("epsilon fuses", s.intervals, [(0.0,0.3)])

s = IntervalSet(); s.insert(0.9, 0.2)
fails += not check("reversed normalises", s.intervals, [(0.2,0.9)])

s = IntervalSet(); s.insert(0.4, 0.4)
fails += not check("zero-length dropped", s.intervals, [])

s = IntervalSet(); s.insert(-5, 7)
fails += not check("out of range clamps", s.intervals, [(0.0,1.0)])
fails += not check("full gaps empty", s.gaps, [])

s = IntervalSet([(0.1,0.2),(0.3,0.4),(0.5,0.6),(0.7,0.8)]); s.insert(0.15, 0.75)
fails += not check("swallow many", s.intervals, [(0.1,0.8)])

import random
random.seed(7)
for trial in range(2000):
    s = IntervalSet(); truth = set()
    for _ in range(random.randint(1, 12)):
        a = random.randrange(0, 100); b = random.randrange(0, 100)
        lo, hi = min(a,b), max(a,b)
        if hi == lo: continue
        s.insert(lo/100, hi/100)
        truth.update(range(lo, hi))
    for i in range(len(s.intervals)-1):
        assert s.intervals[i][1] < s.intervals[i+1][0], "overlap leaked"
    if abs(s.coverage - len(truth)/100) > 0.02:
        print("FAIL fuzz coverage", trial, s.coverage, len(truth)/100); fails += 1; break
else:
    print("PASS fuzz 2000 trials: disjoint invariant + coverage within tolerance")

print("\nFAILURES:", fails)
