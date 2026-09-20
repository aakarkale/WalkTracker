# Algorithm validation

Reference implementations in Python of the algorithms in `WalkTracker/Core`,
plus the harnesses used to test them.

## Why this exists

The app was built in an environment with no Swift toolchain, so the Swift could
not be compiled or run. The parts carrying real algorithmic risk were therefore
ported line for line to Python and tested here. A defect in the algorithm shows
up in both; a defect in the Swift syntax shows up in neither, which is why the
Swift still needs a first build in Xcode.

These are not a substitute for the XCTest suite in `Tests/`. They test the
algorithm; the XCTests test the code that ships.

## Running

Python 3.11, standard library only.

```
cd Tools/validation
python3 interval_ref.py     # interval merging, unit cases plus fuzz
python3 geom_codec.py       # pack geometry encode/decode and malformed input
python3 final_eval.py       # map matching against simulated walks
python3 sweep.py            # compares matcher variants (slow, a few minutes)
```

## What each covers

| File | Covers | Swift it mirrors |
|---|---|---|
| `interval_ref.py` | Merging, coverage, gaps, 2000-trial fuzz | `Matching/IntervalSet.swift` |
| `geom_codec.py` | Pack geometry round trip, bounds checks on malformed blobs | `Store/CityPackStore.swift` decoder |
| `matcher_ref.py` | Port of the matcher, imported by the harnesses | `Matching/MapMatcher.swift` |
| `smoother.py` | Port of the pre-smoother | `Matching/LocationSmoother.swift` |
| `sim.py` | Synthetic grid city and walk simulator | test fixture |
| `final_eval.py` | Precision and recall of the chosen configuration | end to end |
| `sweep.py` | The variant comparison the configuration was chosen from | tuning record |

## Results as of the last run

`final_eval.py`, 30 random routes per noise level on an 80 m grid, which is
roughly Manhattan cross-street spacing:

| GPS noise | Precision | Recall |
|---|---|---|
| 5 m | 1.000 | 0.997 |
| 10 m | 1.000 | 0.997 |
| 15 m | 1.000 | 0.997 |
| 20 m | 0.997 | 0.997 |
| 25 m | 0.994 | 0.997 |

Precision is the share of claimed distance that was actually walked. It is the
number that matters, because a wrongly credited street is invisible and
permanent.

`sweep.py` is the record of how that configuration was reached. Two findings
from it are worth keeping:

- Pre-smoothing was the dominant factor, moving precision at 20 m noise from
  0.67 to 0.96. Every probability weight tuned together was worth far less.
- Before smoothing was added, a bug in the speed gate was differencing raw
  noisy fixes, so GPS noise alone implied 20 m/s and reset the matching chain
  on almost every fix. Recall was 2%. The gate now budgets for the reported
  accuracy of both fixes.

## Caveats

These are simulations. The street network is a perfect grid, the noise is
Gaussian and independent between fixes, and the walker moves at a constant
speed. Real GPS error is correlated over time and biased by buildings, real
street networks are irregular, and real walkers stop at crossings and go into
shops. Treat these numbers as evidence the algorithm is sound, not as field
results. Nothing substitutes for walking a real city with a real phone.
