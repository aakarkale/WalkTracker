"""Validates the byte framing GzipEncoder.swift writes and GzipDecoder.swift
reads, by building the same container here and checking both the system gzip
reader and the app's own header walk accept it.

Backups depend on this pair being correct in both directions. A decoder bug
loses a city pack, which is re-downloadable; an encoder bug loses the user's
walk history, which is not.
"""
import gzip, zlib, struct, os, sys

def swift_encoder(data):
    out = bytes([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])
    if not data:
        out += bytes([0x03, 0x00])
    else:
        co = zlib.compressobj(6, zlib.DEFLATED, -zlib.MAX_WBITS)
        out += co.compress(data) + co.flush()
    return out + struct.pack("<II", zlib.crc32(data) & 0xffffffff, len(data) & 0xffffffff)

def swift_decoder_header(b):
    if len(b) < 18: return None
    if b[0] != 0x1f or b[1] != 0x8b or b[2] != 0x08: return None
    flags = b[3]
    if flags & 0xE0: return None
    i = 10
    if flags & 0x04:
        i += 2 + (b[i] | (b[i+1] << 8))
    for bit in (0x08, 0x10):
        if flags & bit:
            while i < len(b) and b[i] != 0: i += 1
            i += 1
    if flags & 0x02: i += 2
    if i >= len(b) - 8: return None
    return i, len(b) - 8

def main():
    fails = 0
    def check(name, cond, extra=""):
        nonlocal fails
        print(("PASS " if cond else "FAIL ") + name + ("" if cond else "  " + extra))
        if not cond: fails += 1

    cases = {
        "empty": b"",
        "single byte": b"x",
        "sqlite-shaped": b"SQLite format 3\x00" + os.urandom(4000),
        "repetitive, like a real database": (b"SQLite format 3\x00" + b"\x00"*200 + b"walktracker"*500) * 40,
        "incompressible": os.urandom(200_000),
        "one megabyte": os.urandom(64) * 16384,
    }

    for name, payload in cases.items():
        blob = swift_encoder(payload)
        try:
            check(f"system gzip reads {name}", gzip.decompress(blob) == payload)
        except Exception as e:
            check(f"system gzip reads {name}", False, str(e)); continue
        r = swift_decoder_header(blob)
        if not r:
            check(f"app decoder accepts {name}", False, "header rejected"); continue
        s, e = r
        inflated = zlib.decompress(blob[s:e], -zlib.MAX_WBITS) if e > s else b""
        crc, size = struct.unpack("<II", blob[-8:])
        check(f"app decoder round trips {name}",
              inflated == payload
              and (zlib.crc32(inflated) & 0xffffffff) == crc
              and (len(inflated) & 0xffffffff) == size)

    db_like = (b"SQLite format 3\x00" + b"\x00"*200 + b"walktracker"*500) * 40
    ratio = len(swift_encoder(db_like)) / len(db_like)
    check(f"database-shaped data compresses to {ratio*100:.1f}% of original", ratio < 0.2)
    check("output is deterministic, no clock written into the header",
          swift_encoder(db_like) == swift_encoder(db_like))

    print(f"\n{'ALL PASS' if fails == 0 else str(fails) + ' FAILURES'}")
    return 1 if fails else 0

if __name__ == "__main__":
    sys.exit(main())
