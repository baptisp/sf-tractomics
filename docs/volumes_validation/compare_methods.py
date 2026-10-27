"""Compare the precision of two volume methods (SAMSEG longitudinal and SynthSeg) on the same inputs.

Repeat scans (two T1s of one session, true change 0): median and worst |difference| between the two
scans, in % of their mean. Pairs whose two T1s hold the same voxels are excluded: their difference
is 0 by construction.

Follow-up (3 or more sessions per subject): noise = SD of the residuals around each subject's
straight-line trend, in % of the subject's mean, and the median yearly change (% per year) per
group. The group is the diagnosis at the subject's first session in the run, read from the
participants file (HC = healthy, anything else = AD/MCI). Session times come from --days-regex
(OASIS-3 sessions are named d<days>).

Usage (nibabel and numpy are needed):
  python3 compare_methods.py --repeat SAMSEG_OUT SYNTHSEG_OUT --repeat-bids repeat.json \
      --followup SAMSEG_OUT SYNTHSEG_OUT --participants participants.tsv
A repeat-scan BIDS JSON lists each pair as two sessions of one subject (e.g. d0061r01, d0061r02).
"""
import argparse
import csv
import json
import re
from collections import defaultdict

import nibabel as nib
import numpy as np

STRUCTURES = {
    "Hippocampus": ["Left-Hippocampus", "Right-Hippocampus"],
    "Lateral ventricles": ["Left-Lateral-Ventricle", "Right-Lateral-Ventricle"],
    "Inferior lateral ventricles": ["Left-Inf-Lat-Vent", "Right-Inf-Lat-Vent"],
    "Amygdala": ["Left-Amygdala", "Right-Amygdala"],
    "Thalamus": ["Left-Thalamus-Proper", "Right-Thalamus-Proper"],
    "Cerebral white matter": ["Left-Cerebral-White-Matter", "Right-Cerebral-White-Matter"],
    "Cerebral cortex": None,  # SynthSeg: sum of the ctx-* parcels; SAMSEG: Left/Right-Cerebral-Cortex
    "Intracranial volume": "icv",
}
FILES = ["space-native_atlas-iit-gm_desc-roi_volumes.csv",
         "space-native_atlas-freesurfer-csf_desc-roi_volumes.csv",
         "comparison/space-native_atlas-freesurfer-comparison_desc-roi_volumes.csv"]


def load(outdir):
    """{(sid, session): {structure: volume in mm3}}"""
    raw, icv = defaultdict(dict), {}
    for fn in FILES:
        with open(f"{outdir}/metrics/{fn}") as f:
            for r in csv.DictReader(f):
                key = (r["sid"], r["session"])
                if r["volume_mm3"]:  # empty = not measured
                    raw[key][r["roi"]] = float(r["volume_mm3"])
                if r.get("icv_mm3"):
                    icv[key] = float(r["icv_mm3"])
    out = {}
    for key, v in raw.items():
        cortex = [k for k in v if k.startswith("ctx-")] or ["Left-Cerebral-Cortex", "Right-Cerebral-Cortex"]
        out[key] = {g: icv.get(key, np.nan) if rois == "icv" else sum(v[k] for k in (rois or cortex))
                    for g, rois in STRUCTURES.items()}
    return out


def same_voxels(a, b):
    ia, ib = nib.load(a), nib.load(b)
    return ia.shape == ib.shape and np.array_equal(np.asanyarray(ia.dataobj), np.asanyarray(ib.dataobj))


def repeat(outdir, excluded):
    pairs = defaultdict(dict)
    for (sid, ses), v in load(outdir).items():
        if sid not in excluded:
            pairs[sid][ses] = v
    diffs = {g: [] for g in STRUCTURES}
    for sid, sessions in sorted(pairs.items()):
        if len(sessions) != 2:
            continue
        a, b = (sessions[k] for k in sorted(sessions))
        for g in STRUCTURES:
            diffs[g].append(100 * abs(b[g] - a[g]) / ((a[g] + b[g]) / 2))
    return diffs


def followup(outdir, groups, days_regex):
    subjects = defaultdict(list)
    for (sid, ses), v in load(outdir).items():
        subjects[sid].append((int(re.search(days_regex, ses).group(1)) / 365.25, v, ses))
    noise = {g: [] for g in STRUCTURES}
    slopes = {g: defaultdict(list) for g in STRUCTURES}
    for sid, points in subjects.items():
        if len(points) < 3:
            continue
        points.sort(key=lambda p: p[0])
        x = np.array([p[0] for p in points])
        group = groups.get((sid, points[0][2]), "?")
        for g in STRUCTURES:
            y = np.array([p[1][g] for p in points])
            fit = np.polyfit(x, y, 1)
            residuals = y - np.polyval(fit, x)
            noise[g].append(100 * np.sqrt((residuals ** 2).sum() / (len(x) - 2)) / y.mean())
            slopes[g][group].append(100 * fit[0] / y.mean())
    return noise, slopes


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repeat", nargs=2, metavar=("SAMSEG_OUT", "SYNTHSEG_OUT"))
    parser.add_argument("--repeat-bids", help="BIDS JSON of the repeat run, to exclude identical images")
    parser.add_argument("--followup", nargs=2, metavar=("SAMSEG_OUT", "SYNTHSEG_OUT"))
    parser.add_argument("--participants", help="participants.tsv, for the diagnosis groups (column 'disease')")
    parser.add_argument("--days-regex", default=r"d(\d+)", help="days since baseline, from the session name")
    args = parser.parse_args()

    if args.repeat:
        excluded = set()
        if args.repeat_bids:
            with open(args.repeat_bids) as f:
                t1s = defaultdict(list)
                for r in json.load(f):
                    t1s[f"sub-{r['subject']}"].append(r["t1"])
            excluded = {sid for sid, paths in t1s.items() if len(paths) == 2 and same_voxels(*paths)}
        results = [repeat(d, excluded) for d in args.repeat]
        n = len(results[0]["Intracranial volume"])
        print(f"REPEAT SCANS: {n} pairs ({len(excluded)} excluded, same voxels: {', '.join(sorted(excluded)) or 'none'})")
        print(f"{'structure':30s}{'median %':>18s}{'worst pair %':>18s}  (SAMSEG / SynthSeg)")
        for g in STRUCTURES:
            a, b = results[0][g], results[1][g]
            print(f"{g:30s}{np.median(a):9.2f} /{np.median(b):6.2f}{max(a):9.2f} /{max(b):6.2f}")

    if args.followup:
        groups = {}
        if args.participants:
            with open(args.participants) as f:
                for r in csv.DictReader(f, delimiter="\t"):
                    groups[r["participant_id"], r["session"]] = "healthy" if r.get("disease") == "HC" else "AD/MCI"
        results = [followup(d, groups, args.days_regex) for d in args.followup]
        print(f"\nFOLLOW-UP: {len(results[0][0]['Intracranial volume'])} subjects")
        print(f"{'structure':30s}{'noise %':>16s}{'healthy %/year':>20s}{'AD/MCI %/year':>20s}  (SAMSEG / SynthSeg)")
        for g in STRUCTURES:
            na, nb = (np.median(r[0][g]) for r in results)
            rates = [[np.median(r[1][g][grp]) if r[1][g][grp] else np.nan for r in results] for grp in ("healthy", "AD/MCI")]
            print(f"{g:30s}{na:8.2f} /{nb:6.2f}" + "".join(f"{x:+11.2f} /{y:+7.2f}" for x, y in rates))


if __name__ == "__main__":
    main()
