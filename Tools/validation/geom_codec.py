"""Encode per docs/city-pack-format.md, decode with a faithful port of
CityPackStore.decodeGeometry, and fuzz the pair. Validates the decoder's
bounds checks, which are the app's defence against a malformed pack."""
import struct, random, sys

def encode(coords):
    n = len(coords)
    out = struct.pack("<H", n)
    out += b"".join(struct.pack("<i", int(lat * 1e7)) for lat, _ in coords)
    out += b"".join(struct.pack("<i", int(lon * 1e7)) for _, lon in coords)
    return out

def decode(blob):
    """Port of the Swift decoder. Returns None on anything unexpected."""
    if len(blob) < 2: return None
    count = struct.unpack_from("<H", blob, 0)[0]
    if count < 2: return None
    if len(blob) != 2 + count * 8: return None
    lat_off, lon_off = 2, 2 + count * 4
    out = []
    for i in range(count):
        lat = struct.unpack_from("<i", blob, lat_off + i * 4)[0] / 1e7
        lon = struct.unpack_from("<i", blob, lon_off + i * 4)[0] / 1e7
        if not (-90 <= lat <= 90 and -180 <= lon <= 180): return None
        out.append((lat, lon))
    return out

fails = 0
rng = random.Random(11)

# Round trip at 1e-7 resolution
for _ in range(3000):
    n = rng.randint(2, 40)
    coords = [(rng.uniform(-89, 89), rng.uniform(-179, 179)) for _ in range(n)]
    got = decode(encode(coords))
    if got is None: print("FAIL: round trip returned None"); fails += 1; break
    worst = max(max(abs(a[0]-b[0]), abs(a[1]-b[1])) for a, b in zip(coords, got))
    if worst > 1.1e-7:
        print(f"FAIL: round trip error {worst:.2e} exceeds 1.1e-7"); fails += 1; break
else:
    print("PASS round trip: 3000 random polylines within 1.1e-7 degrees (about 1.1 cm)")

# Extremes and the stated minimum
for name, coords in [("poles/antimeridian", [(90.0,180.0),(-90.0,-180.0)]),
                     ("null island pair", [(0.0,0.0),(0.0,0.0)]),
                     ("two points (minimum)", [(40.7,-74.0),(40.71,-74.01)])]:
    got = decode(encode(coords))
    ok = got is not None and len(got) == len(coords)
    print(("PASS " if ok else "FAIL ") + name)
    fails += not ok

# Malformed blobs must be rejected, never crash or over-read
valid = encode([(40.7,-74.0),(40.71,-74.01),(40.72,-74.02)])
bad = {
    "empty": b"",
    "one byte": b"\x00",
    "count 0": struct.pack("<H", 0),
    "count 1 (below minimum)": struct.pack("<H", 1) + b"\x00"*8,
    "truncated body": valid[:-4],
    "trailing garbage": valid + b"\xff\xff",
    "count overstates buffer": struct.pack("<H", 9999) + valid[2:],
    "count understates buffer": struct.pack("<H", 2) + valid[2:],
    "latitude out of range": encode([(40.7,-74.0),(40.71,-74.01)])[:2] + struct.pack("<i", 950000000) + encode([(40.7,-74.0),(40.71,-74.01)])[6:],
}
crashes = rejected = 0
for name, blob in bad.items():
    try:
        r = decode(blob)
        if r is None: rejected += 1
        else: print(f"  ACCEPTED malformed input: {name} -> {len(r)} points"); fails += 1
    except Exception as e:
        print(f"  CRASH on {name}: {type(e).__name__}"); crashes += 1; fails += 1
print(f"{'PASS' if crashes==0 and rejected==len(bad) else 'FAIL'} malformed blobs: "
      f"{rejected}/{len(bad)} rejected cleanly, {crashes} crashes")

# Size claim in the spec: 8 bytes per point
blob = encode([(40.7,-74.0)]*100)
print(f"{'PASS' if len(blob)==2+100*8 else 'FAIL'} encoding size: 100 points = {len(blob)} bytes (2 header + 8/point)")

print("\nALL PASS" if fails == 0 else f"\n{fails} FAILURES")
sys.exit(1 if fails else 0)
