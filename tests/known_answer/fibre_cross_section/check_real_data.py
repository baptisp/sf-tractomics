"""Check the fibre cross-section of real sessions against the known effect of real_data.nf.

Usage: python3 check_real_data.py FC_STATS_CSV SCALES (e.g. 1.05,0.95)

For each session copied with its voxel size multiplied by s, log FC per bundle must exceed the
original's by 2 ln s. Prints, per scale, the expected shift and the median, 5th and 95th percentile
of the measured shift over the bundles, plus the QC columns of every session. Exits 1 when a median
shift is off by more than 10 % of the expected one.
"""
import csv
import math
import statistics
import sys

rows = list(csv.DictReader(open(sys.argv[1])))
scales = [s for s in sys.argv[2].split(",")]
by = {}
for r in rows:
    by.setdefault(r["sid"], {})[r["roi"]] = r

print("session          orientation  corr    min_jac  uncovered  flags")
for sid, bundles in sorted(by.items()):
    first = next(iter(bundles.values()))
    flagged = sorted({r["qc_flags"] for r in bundles.values() if r["qc_flags"]})
    covered = statistics.median(float(r["covered_fraction"]) for r in bundles.values())
    print(f"{sid:16} {first['orientation_agreement']:>11}  {first['registration_corr']:>6}  {first['min_jacobian']:>7}  "
          f"{1 - covered:9.3f}  {';'.join(flagged)}")

failed = False
for sid in sorted(by):
    for s in scales:
        copy = f"{sid}x{s}"
        if copy not in by:
            continue
        expected = 2 * math.log(float(s))
        shifts = sorted(float(by[copy][b]["log_fc_mean"]) - float(by[sid][b]["log_fc_mean"])
                        for b in by[sid] if by[sid][b]["log_fc_mean"] and by[copy].get(b, {}).get("log_fc_mean"))
        med = statistics.median(shifts)
        p5, p95 = shifts[int(0.05 * (len(shifts) - 1))], shifts[int(0.95 * (len(shifts) - 1))]
        ok = abs(med - expected) <= 0.1 * abs(expected)
        failed |= not ok
        print(f"{copy}: expected {expected:+.4f}, median {med:+.4f} (5-95 %: {p5:+.4f} to {p95:+.4f}) over {len(shifts)} bundles "
              f"{'OK' if ok else 'OFF'}")
sys.exit(1 if failed else 0)
