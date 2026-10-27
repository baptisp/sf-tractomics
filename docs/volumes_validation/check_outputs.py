"""Check the subject volume files of one sf-tractomics output directory, independently of the
pipeline code.

Checks (any failure is printed and the exit code is 1):
  values     every volume equals a recount of the labels in the sample's own published
             segmentation; ICV and SynthSeg QC equal the segmenter's own tables
  coverage   every input sample is present once, with every region of its LUT, and nothing else
  structure  every line has as many fields as its header, numbers parse, no NaN/None/null text
  empties    every empty cell is an expected one (labels the method cannot produce, no QC flag,
             no duplicate, covariates when no participants file is given)
  names      every LUT label carries FreeSurfer's own name for it, and each Left-/lh region lies
             left of its Right-/rh twin in the segmentation
  combined   every cell of the combined TSV equals the per-type file, region_type matches the
             source file, covariates match participants.tsv, scanner matches the T1 sidecar
  pairing    (with --other-outdir, SAMSEG output only) each SAMSEG segmentation overlaps the
             SynthSeg segmentation of its own session better than any other session's

Usage (nibabel and numpy are needed, e.g. in the pipeline's nibabel_numpy container):
  python3 check_outputs.py --outdir OUT --bids bids.json --method synthseg|samseg_long \
      [--participants participants.tsv] [--fs-lut FreeSurferColorLUT.txt] [--other-outdir SYNTHSEG_OUT]
"""
import argparse
import csv
import glob
import json
import os
import re
import sys
from collections import Counter, defaultdict

import nibabel as nib
import numpy as np

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "assets")
FILES = {"gm": "space-native_atlas-iit-gm_desc-roi_volumes.csv",
         "csf": "space-native_atlas-freesurfer-csf_desc-roi_volumes.csv",
         "comparison": "comparison/space-native_atlas-freesurfer-comparison_desc-roi_volumes.csv"}
COMBINED = "space-native_all-regions_desc-roi_combined.tsv"
REGION_TYPE = {"gm": "GM_region", "csf": "CSF_region"}
# Labels SynthSeg cannot produce (choroid plexus, WM hypointensities): written empty
MISSING = {"synthseg": {"gm": set(), "csf": {31, 63}, "comparison": {31, 63, 77}},
           "samseg_long": {"gm": set(), "csf": set(), "comparison": set()}}
COVARIATES = ["site", "age", "sex", "handedness", "disease"]
NUMERIC = {"volume_voxels", "volume_mm3", "icv_mm3", "qc_score"}
# IIT GM names that differ from FreeSurfer 7's
ALIAS = {"Left-Thalamus-Proper": "Left-Thalamus", "Right-Thalamus-Proper": "Right-Thalamus"}


def lut(typ, method):
    name = "gm_samseg" if typ == "gm" and method == "samseg_long" else typ
    with open(os.path.join(ASSETS, f"freesurfer_{name}_lut.json")) as f:
        return {int(k): v for k, v in json.load(f).items()}


def seg_path(outdir, sid, ses, method):
    tag = "samseglong" if method == "samseg_long" else "synthseg"
    hits = glob.glob(f"{outdir}/{sid}/{ses}/anat/{sid}_{ses}_desc-{tag}_dseg.nii.gz")
    return hits[0] if len(hits) == 1 else None


def scanner_of(t1):
    sidecar = re.sub(r"\.nii(\.gz)?$", ".json", t1)
    if not os.path.isfile(sidecar):
        return ""
    with open(sidecar) as f:
        s = json.load(f)
    field = f"{s['MagneticFieldStrength']}T" if s.get("MagneticFieldStrength") else None
    return " ".join(x for x in [s.get("Manufacturer"), s.get("ManufacturersModelName"), field] if x)


def first_row(path):
    with open(path) as f:
        return {k.strip().lower(): v for k, v in next(csv.DictReader(f)).items()}


def read_table(path):
    delim = "\t" if path.endswith(".tsv") else ","
    with open(path) as f:
        lines = f.read().splitlines()
    with open(path) as f:
        rows = list(csv.DictReader(f, delimiter=delim))
    return lines[0].split(delim), lines, rows, delim


def check(args):
    errors = []
    err = errors.append
    with open(args.bids) as f:
        inputs = {(f"sub-{r['subject']}", f"ses-{r['session']}"): r for r in json.load(f)}
    expected = {key + ("1",) for key in inputs}
    participants = None
    if args.participants:
        with open(args.participants) as f:
            participants = {(r["participant_id"], r["session"]): r for r in csv.DictReader(f, delimiter="\t")}

    # names: LUT labels against FreeSurfer's own table
    if args.fs_lut:
        fs = {}
        with open(args.fs_lut) as f:
            for line in f:
                p = line.split()
                if p and p[0].isdigit():
                    fs[int(p[0])] = p[1]
        for typ in FILES:
            for lid, name in lut(typ, args.method).items():
                if fs.get(lid) not in (name, ALIAS.get(name)):
                    err(f"names: label {lid} is called {name}, FreeSurfer calls it {fs.get(lid)}")

    tables = {}
    for typ, fn in list(FILES.items()) + [("combined", COMBINED)]:
        path = f"{args.outdir}/metrics/{fn}"
        if not os.path.isfile(path):
            err(f"coverage: {fn} is missing")
            continue
        header, lines, rows, delim = read_table(path)
        for i, line in enumerate(lines[1:], 2):
            if len(line.split(delim)) != len(header):
                err(f"structure: {fn} line {i} has {len(line.split(delim))} fields, header has {len(header)}")
            if re.search(r"(^|[,\t])(nan|NaN|None|null|NA)([,\t]|$)", line):
                err(f"structure: {fn} line {i} holds placeholder text")
        for r in rows:
            for c in NUMERIC & set(r):
                if r[c]:
                    try:
                        float(r[c])
                    except ValueError:
                        err(f"structure: {fn} {c}={r[c]!r} is not a number")
        tables[typ] = (header, rows)

    # coverage, values and empties of the per-type files
    nvalues = 0
    by_sample = {}
    for typ in FILES:
        if typ not in tables:
            continue
        header, rows = tables[typ]
        names = lut(typ, args.method)
        keys = Counter((r["sid"], r["session"], r["run"], r["roi"]) for r in rows)
        for k, n in keys.items():
            if n > 1:
                err(f"coverage: {typ} row {k} appears {n} times")
        samples = {k[:3] for k in keys}
        for s in sorted(expected - samples):
            err(f"coverage: {typ} has no rows for {s}")
        for s in sorted(samples - expected):
            err(f"coverage: {typ} has rows for unknown sample {s}")
        sources = {r["volume_source"] for r in rows}
        if sources != {args.method}:
            err(f"values: {typ} volume_source is {sorted(sources)}, expected {args.method}")
        grouped = defaultdict(dict)
        for r in rows:
            grouped[r["sid"], r["session"], r["run"]][r["roi"]] = r
        by_sample[typ] = grouped
        for s, regions in grouped.items():
            if set(regions) != set(names.values()):
                err(f"coverage: {typ} {s} missing {sorted(set(names.values()) - set(regions))}, "
                    f"extra {sorted(set(regions) - set(names.values()))}")
        for r in rows:
            for c in header:
                if r[c] != "" or c in ("qc_flags", "duplicate_of"):
                    continue
                if c in ("volume_voxels", "volume_mm3"):
                    label = {v: k for k, v in names.items()}.get(r["roi"])
                    if label not in MISSING[args.method][typ]:
                        err(f"empties: {typ} {r['sid']} {r['session']} {r['roi']} has no {c}")
                elif not (c == "qc_score" and args.method != "synthseg"):
                    err(f"empties: {typ} {r['sid']} {r['session']} {r['roi']} has no {c}")

    for s in sorted(expected):
        sid, ses, _ = s
        path = seg_path(args.outdir, sid, ses, args.method)
        if path is None:
            err(f"values: no single published segmentation for {sid} {ses}")
            continue
        img = nib.load(path)
        data = np.round(np.asarray(img.dataobj)).astype(np.int32)
        counts = np.bincount(data[data >= 0].ravel())
        voxel = float(np.prod(img.header.get_zooms()[:3]))
        if args.method == "samseg_long":
            icv = float(first_row(path.replace("_dseg.nii.gz", "_icv.csv"))["total intracranial"])
            qc = None
        else:
            icv = float(first_row(path.replace("_dseg.nii.gz", "_volumes.csv"))["total intracranial"])
            qc = min(float(v) for k, v in first_row(path.replace("_dseg.nii.gz", "_qc.csv")).items() if k != "subject")
        for typ, grouped in by_sample.items():
            for lid, name in lut(typ, args.method).items():
                r = grouped.get(s, {}).get(name)
                if r is None or lid in MISSING[args.method][typ]:
                    continue
                nvalues += 1
                n = int(counts[lid]) if lid < counts.size else 0
                if r["volume_voxels"] != str(n) or abs(float(r["volume_mm3"]) - n * voxel) > 1e-3:
                    err(f"values: {typ} {sid} {ses} {name} is {r['volume_voxels']} voxels, segmentation has {n}")
                if abs(float(r["icv_mm3"]) - icv) > 1e-3:
                    err(f"values: {typ} {sid} {ses} ICV {r['icv_mm3']}, segmenter says {icv}")
                if qc is not None and r.get("qc_score") and abs(float(r["qc_score"]) - qc) > 1e-4:
                    err(f"values: {typ} {sid} {ses} QC {r['qc_score']}, segmenter says {qc}")
        # names: each Left-/lh label lies left (lower RAS x) of its Right-/rh twin
        names = {}
        for typ in FILES:
            names.update({v: k for k, v in lut(typ, args.method).items()})
        for name, lid in names.items():
            twin = name.replace("Left-", "Right-").replace("ctx-lh-", "ctx-rh-")
            if twin == name or twin not in names:
                continue
            left, right = np.argwhere(data == lid), np.argwhere(data == names[twin])
            if len(left) and len(right):
                xl = nib.affines.apply_affine(img.affine, left)[:, 0].mean()
                xr = nib.affines.apply_affine(img.affine, right)[:, 0].mean()
                if not xl < xr:
                    err(f"names: {sid} {ses} {name} (x={xl:.1f}) is not left of {twin} (x={xr:.1f})")

    # per-sample values constant across files, scanner from the sidecar
    per = defaultdict(lambda: defaultdict(set))
    for typ in by_sample:
        for r in tables[typ][1]:
            for c in ("icv_mm3", "qc_score", "scanner", "duplicate_of"):
                if c in r:
                    per[r["sid"], r["session"]][c].add(r[c])
    for key, cols in per.items():
        for c, values in cols.items():
            if len(values) != 1:
                err(f"combined: {key} {c} differs between files: {sorted(values)}")
        if "scanner" in cols and key in inputs and cols["scanner"] != {scanner_of(inputs[key]["t1"])}:
            err(f"combined: {key} scanner {sorted(cols['scanner'])}, sidecar says {scanner_of(inputs[key]['t1'])!r}")

    # combined TSV against the per-type files and participants.tsv
    if "combined" in tables:
        header, comb = tables["combined"]
        source = {}
        for typ, region_type in REGION_TYPE.items():
            for r in tables.get(typ, ([], []))[1]:
                source[r["sid"], r["session"], r["run"], r["roi"], region_type] = r
        volume_rows = [r for r in comb if r["region_type"] in REGION_TYPE.values()]
        if len(volume_rows) != len(source):
            err(f"combined: {len(volume_rows)} GM/CSF rows, per-type files have {len(source)}")
        for r in volume_rows:
            s = source.get((r["sid"], r["session"], r["run"], r["roi"], r["region_type"]))
            if s is None:
                err(f"combined: row {r['sid']} {r['session']} {r['roi']} {r['region_type']} has no source row")
                continue
            for c in (set(header) & set(s)) - {"sid", "session", "run", "roi"}:
                if r[c] != s[c]:
                    err(f"combined: {r['sid']} {r['session']} {r['roi']} {c} is {r[c]!r}, source has {s[c]!r}")
            if participants is not None:
                want = participants.get((r["sid"], r["session"]))
                if want is None:
                    err(f"combined: {r['sid']} {r['session']} is not in the participants file")
                else:
                    for c in COVARIATES:
                        if c in r and r[c] != want.get(c, ""):
                            err(f"combined: {r['sid']} {r['session']} {c} is {r[c]!r}, participants file has {want.get(c)!r}")

    # pairing: SAMSEG segmentation against the SynthSeg segmentations of the same subject
    if args.other_outdir and args.method == "samseg_long":
        sessions = defaultdict(list)
        for sid, ses in inputs:
            sessions[sid].append(ses)
        for sid, sess in sessions.items():
            # Two inputs holding the same voxels overlap equally by construction
            if len(sess) == 2 and same_voxels(*(inputs[sid, t]["t1"] for t in sess)):
                print(f"  note: pairing of {sid} skipped, its two T1s hold the same voxels")
                continue
            for ses in sess:
                own = seg_path(args.outdir, sid, ses, "samseg_long")
                dice = {t: wm_dice(own, seg_path(args.other_outdir, sid, t, "synthseg")) for t in sess}
                best_other = max((d for t, d in dice.items() if t != ses), default=0)
                if dice[ses] <= best_other:
                    err(f"pairing: {sid} {ses} overlaps another session as well as its own "
                        f"(Dice {dice[ses]:.3f} vs {best_other:.3f})")

    print(f"{args.outdir}: {len(expected)} samples, {nvalues} volumes recounted")
    for e in errors:
        print("  ERROR", e)
    print("  OK" if not errors else f"  {len(errors)} errors")
    return 1 if errors else 0


def same_voxels(a, b):
    ia, ib = nib.load(a), nib.load(b)
    return ia.shape == ib.shape and np.array_equal(np.asanyarray(ia.dataobj), np.asanyarray(ib.dataobj))


def wm_dice(a_path, b_path):
    """Dice of cerebral white matter (labels 2 and 41) between two segmentations, in world space."""
    ia, ib = nib.load(a_path), nib.load(b_path)
    ma = np.isin(np.round(np.asarray(ia.dataobj)), (2, 41))
    mb = np.isin(np.round(np.asarray(ib.dataobj)), (2, 41))
    world = nib.affines.apply_affine(ia.affine, np.argwhere(ma))
    j = np.round(nib.affines.apply_affine(np.linalg.inv(ib.affine), world)).astype(int)
    inside = np.all((j >= 0) & (j < mb.shape), axis=1)
    hit = np.zeros(len(j), bool)
    hit[inside] = mb[tuple(j[inside].T)]
    va, vb = np.prod(ia.header.get_zooms()[:3]), np.prod(ib.header.get_zooms()[:3])
    return 2 * hit.sum() * va / (ma.sum() * va + mb.sum() * vb)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--bids", required=True, help="the bids_config JSON the run was given")
    parser.add_argument("--method", required=True, choices=["synthseg", "samseg_long"])
    parser.add_argument("--participants", help="the participants_tsv the run was given")
    parser.add_argument("--fs-lut", help="FreeSurferColorLUT.txt, to check the region names")
    parser.add_argument("--other-outdir", help="SynthSeg output of the same inputs, for the pairing check")
    sys.exit(check(parser.parse_args()))
