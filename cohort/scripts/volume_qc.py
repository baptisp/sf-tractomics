"""merged/volume_qc.tsv: runs whose recon-all and SynthSeg volumes disagree, for review.

Usage: python3 scripts/volume_qc.py [MERGED_DIR]      (default: merged/, after merge_batches.py)

The pipeline's own flags (qc_flags of the volume tables) compare a run with itself or with its
subject: they miss a recon-all failure that still gives plausible totals. The first ADNI batches
had one run whose right cortex recon-all lost entirely (34 regions at a third of their volume) and
two whose eTIV was 2.3 and 3.3 L, unflagged or flagged only as implausible. Both segmentations read
the same raw T1, so their ratio is steady across the cohort, and a run far off it points to the
segmentation that failed. One row per run that has both sources:

  cortex_ratio_lh / _rh  recon-all over SynthSeg cortical volume (sum of the ctx-<h>-* regions)
  icv_ratio              recon-all eTIV over SynthSeg ICV
  flags                  ;-separated: cortex_mismatch_lh, cortex_mismatch_rh, icv_mismatch, when
                         the log ratio is more than MAX_ROBUST_Z robust SD (1.4826 MAD) from the
                         cohort's median; empty otherwise

Flags are computed only over at least MIN_RUNS runs (else empty, and said so). Nothing is dropped:
a flagged run is for review (see the README, ADNI run: recon-all reruns). Exit status 0.
"""

import csv
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GM = "space-native_seg-{}_label-gm_desc-roi_volumes.csv"
MAX_ROBUST_Z = 6.0
MIN_RUNS = 30
MEASURES = ["cortex_ratio_lh", "cortex_ratio_rh", "icv_ratio"]
FLAG = {"cortex_ratio_lh": "cortex_mismatch_lh", "cortex_ratio_rh": "cortex_mismatch_rh",
        "icv_ratio": "icv_mismatch"}


def read_source(path):
    """{(sid, session, run): {"lh": cortex mm3, "rh": cortex mm3, "icv": mm3}}"""
    runs = defaultdict(lambda: {"lh": 0.0, "rh": 0.0, "icv": None})
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            r = runs[(row["sid"], row["session"], row["run"])]
            for h in ("lh", "rh"):
                if row["roi"].startswith(f"ctx-{h}-") and row["volume_mm3"]:
                    r[h] += float(row["volume_mm3"])
            if row["icv_mm3"]:
                r["icv"] = float(row["icv_mm3"])
    return runs


def ratio(a, b):
    return a / b if a and b else None


def main():
    merged = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "merged"
    paths = [merged / GM.format(s) for s in ("reconall", "synthseg")]
    if not all(p.exists() for p in paths):
        print(f"volume_qc: no recon-all and SynthSeg tables in {merged}: nothing written")
        return 0
    ra, ss = (read_source(p) for p in paths)
    rows = []
    for key in sorted(set(ra) & set(ss)):
        a, s = ra[key], ss[key]
        rows.append(dict(zip(("sid", "session", "run"), key),
                         cortex_ratio_lh=ratio(a["lh"], s["lh"]), cortex_ratio_rh=ratio(a["rh"], s["rh"]),
                         icv_ratio=ratio(a["icv"], s["icv"]), flags=[]))
    if len(rows) >= MIN_RUNS:
        for m in MEASURES:
            logs = [math.log(r[m]) for r in rows if r[m]]
            med = statistics.median(logs)
            mad = 1.4826 * statistics.median(abs(x - med) for x in logs)
            for r in rows:
                if not r[m]:
                    r["flags"].append(FLAG[m].replace("mismatch", "missing"))
                elif mad > 0 and abs(math.log(r[m]) - med) / mad > MAX_ROBUST_Z:
                    r["flags"].append(FLAG[m])
    else:
        print(f"volume_qc: {len(rows)} runs, fewer than {MIN_RUNS}: no flags")
    out = merged / "volume_qc.tsv"
    with open(out, "w", newline="") as fh:
        w = csv.writer(fh, delimiter="\t", lineterminator="\n")
        w.writerow(["sid", "session", "run"] + MEASURES + ["flags"])
        for r in rows:
            w.writerow([r["sid"], r["session"], r["run"]]
                       + ["" if r[m] is None else f"{r[m]:.4f}" for m in MEASURES] + [";".join(r["flags"])])
    flagged = [r for r in rows if r["flags"]]
    print(f"volume_qc: {len(rows)} runs, {len(flagged)} flagged: {out}")
    for r in flagged:
        print(f"  {r['sid']} {r['session']} run {r['run']}: {';'.join(r['flags'])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
