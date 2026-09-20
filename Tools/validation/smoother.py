
import math
from matcher_ref import haversine, MPD_LAT, mpd_lon, bearing

class Smoother:
    """Averages fixes into short time buckets before matching.

    At 1 Hz a walker covers 1.4 m between fixes while GPS noise is 10-25 m, so
    each individual fix carries almost no along-track information. Averaging a
    few seconds together cuts the noise by sqrt(n) while the walker moves far
    enough to establish a direction, which is the regime the matcher needs.
    """
    def __init__(self, window_seconds=5.0):
        self.w = window_seconds
        self.buf = []

    def push(self, pt):
        out = []
        if self.buf and pt["t"] - self.buf[0]["t"] >= self.w:
            out.append(self._emit())
        self.buf.append(pt)
        return out

    def flush(self):
        return [self._emit()] if self.buf else []

    def _emit(self):
        b = self.buf; n = len(b)
        lat = sum(p["coord"][0] for p in b)/n
        lon = sum(p["coord"][1] for p in b)/n
        t   = sum(p["t"] for p in b)/n
        acc = (sum(p["acc"] for p in b)/n)/math.sqrt(n)
        spd = sum(max(0.0,p["speed"]) for p in b)/n
        crs = self._mean_course(b)
        self.buf = []
        return {"t":t,"coord":(lat,lon),"acc":max(3.0,acc),"speed":spd,"course":crs,"n":n}

    @staticmethod
    def _mean_course(b):
        xs = [p for p in b if p["course"] >= 0]
        if not xs: return -1.0
        sx = sum(math.sin(math.radians(p["course"])) for p in xs)
        sy = sum(math.cos(math.radians(p["course"])) for p in xs)
        if abs(sx) < 1e-9 and abs(sy) < 1e-9: return -1.0
        d = math.degrees(math.atan2(sx, sy))
        return d+360 if d < 0 else d
