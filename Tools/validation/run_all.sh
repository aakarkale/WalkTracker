#!/usr/bin/env bash
# Runs every check that can run without Xcode.
#
# This is not a build. There is no Swift toolchain here, so nothing in
# WalkTracker/ is compiled by this script. What it does check is the
# algorithms, the data pipeline, and that the two agree with each other.
set -uo pipefail

cd "$(dirname "$0")/../.." || exit 1
fail=0
run() {
    echo
    echo "=== $1 ==="
    shift
    if "$@"; then echo "OK"; else echo "FAILED"; fail=1; fi
}

echo "WalkTracker verification"
echo "Swift is not compiled here; see docs/building.md for that."

run "Swift structure and style" python3 - <<'PY'
import pathlib, re, sys
def strip(src):
    out,i,n=[],0,len(src); in_s=in_line=in_block=False
    while i<n:
        c=src[i]; nxt=src[i:i+2]
        if in_line:
            if c=="\n": in_line=False
        elif in_block:
            if nxt=="*/": in_block=False; i+=1
        elif in_s:
            if c=="\\": i+=1
            elif c=='"': in_s=False
        else:
            if nxt=="//": in_line=True
            elif nxt=="/*": in_block=True; i+=1
            elif c=='"':
                if src[i:i+3]=='"""':
                    j=src.find('"""',i+3); i=(j+3) if j!=-1 else n; continue
                in_s=True
            else: out.append(c)
        i+=1
    return "".join(out)

files = sorted(list(pathlib.Path("WalkTracker").rglob("*.swift")) +
               list(pathlib.Path("Tests").rglob("*.swift")))
bad = 0
for f in files:
    src = strip(f.read_text())
    for o,c,n in (("{","}","brace"),("(",")","paren"),("[","]","bracket")):
        d = src.count(o) - src.count(c)
        if d:
            print(f"  unbalanced {n} {d:+d}: {f}"); bad += 1

imports = set()
for f in files:
    imports |= set(re.findall(r'^\s*import\s+(\w+)', f.read_text(), re.M))
allowed = {"Foundation","SwiftUI","MapKit","CoreLocation","CoreMotion","Combine",
           "SQLite3","Compression","CryptoKit","XCTest","UIKit","os","OSLog",
           "UniformTypeIdentifiers","Darwin"}
third = imports - allowed
if third:
    print(f"  third-party imports present: {sorted(third)}"); bad += 1

# Numbers that get persisted or parsed must not be locale-formatted.
for f in pathlib.Path("WalkTracker/Core").rglob("*.swift"):
    for i, line in enumerate(f.read_text().splitlines()):
        if "String(format:" in line and "locale:" not in line and "%02x" not in line:
            print(f"  unlocalised number format: {f}:{i+1}"); bad += 1

print(f"  {len(files)} Swift files, "
      f"{sum(len(f.read_text().splitlines()) for f in files)} lines")
sys.exit(1 if bad else 0)
PY

run "Interval merging" python3 Tools/validation/interval_ref.py
run "Pack geometry codec" python3 Tools/validation/geom_codec.py
run "City pack pipeline" python3 Tools/citypack/test_pipeline.py
run "Map matching accuracy" python3 Tools/validation/final_eval.py

echo
echo "=== End to end: pipeline output read by the app's decoder ==="
tmp=$(mktemp -d)
if python3 Tools/citypack/make_fixture.py --rows 20 --cols 20 --spacing 80 \
        --out "$tmp/grid.osm" --districts-out "$tmp/grid-districts.geojson" >/dev/null 2>&1 \
   && python3 Tools/citypack/build_pack.py "$tmp/grid.osm" --city-id testville \
        --city-name Testville --districts "$tmp/grid-districts.geojson" \
        --out-dir "$tmp" --quiet >/dev/null 2>&1; then
    cp Tools/validation/{matcher_ref.py,smoother.py,geom_codec.py,e2e_pack.py} "$tmp/"
    if (cd "$tmp" && python3 e2e_pack.py); then echo "OK"; else echo "FAILED"; fail=1; fi
else
    echo "FAILED to build the test pack"; fail=1
fi
rm -rf "$tmp"

echo
if [ "$fail" -eq 0 ]; then
    echo "ALL CHECKS PASSED"
else
    echo "SOME CHECKS FAILED"
fi
exit "$fail"
