"""SynthSeg vs FreeSurfer recon-all on the same raw T1s, from sf-tractomics outputs.

Usage: python3 compare_segmentations.py SYNTHSEG_OUT RESULT_DIR [RECONALL_OUT]
SYNTHSEG_OUT: a pipeline output directory with, per session, anat/*_desc-synthseg_dseg.nii.gz and
anat/*_desc-synthseg_volumes.csv (volume_source synthseg). RECONALL_OUT (default SYNTHSEG_OUT): one
with the same sessions' anat/freesurfer/<T1>/ recon-all directories (run_cortical_thickness or
volume_source reconall).

Per session and region in common (FreeSurfer label codes, which SynthSeg uses too):
  - volume_synthseg: voxel count of the SynthSeg segmentation (what the pipeline's volume tables
    count), volume_synthseg_soft: SynthSeg's own posterior-weighted volume;
  - volume_fs: aseg.stats Volume_mm3 (partial-volume corrected) for subcortical structures,
    aparc.stats GrayVol (between the white and pial surfaces) for cortical parcels,
    and volume_fs_voxels: voxel count of aparc+aseg;
  - dice: overlap of the two labels after resampling aparc+aseg onto the SynthSeg grid (nearest
    neighbour, both images are in scanner coordinates).
Also ICV (SynthSeg total intracranial vs FreeSurfer eTIV) and the hippocampal occupancy score.
Writes RESULT_DIR/regions.csv (one row per session and region) and prints a summary.
"""
import csv
import re
import statistics
import sys
from pathlib import Path

import nibabel as nib
import numpy as np
from scipy import ndimage

SUBCORTICAL = {
    "Left-Hippocampus": 17, "Right-Hippocampus": 53, "Left-Amygdala": 18, "Right-Amygdala": 54,
    "Left-Thalamus": 10, "Right-Thalamus": 49, "Left-Caudate": 11, "Right-Caudate": 50,
    "Left-Putamen": 12, "Right-Putamen": 51, "Left-Pallidum": 13, "Right-Pallidum": 52,
    "Left-Accumbens-area": 26, "Right-Accumbens-area": 58, "Left-VentralDC": 28, "Right-VentralDC": 60,
    "Left-Lateral-Ventricle": 4, "Right-Lateral-Ventricle": 43, "Left-Inf-Lat-Vent": 5, "Right-Inf-Lat-Vent": 44,
    "3rd-Ventricle": 14, "4th-Ventricle": 15, "Brain-Stem": 16,
    "Left-Cerebellum-Cortex": 8, "Right-Cerebellum-Cortex": 47,
    "Left-Cerebellum-White-Matter": 7, "Right-Cerebellum-White-Matter": 46,
}
# SynthSeg CSV column of each structure
SYNTHSEG_COLUMN = {name: name.lower().replace("-", " ").replace("ventraldc", "ventral dc")
                   .replace("inf lat vent", "inferior lateral ventricle").replace("accumbens area", "accumbens area")
                   .replace("brain stem", "brain-stem") for name in SUBCORTICAL}


def aseg_stats(path):
    vols, etiv = {}, None
    for line in path.read_text().splitlines():
        m = re.match(r"# Measure EstimatedTotalIntraCranialVol, eTIV, .*, ([0-9.]+), mm\^3", line)
        if m:
            etiv = float(m.group(1))
        if line.startswith("#") or not line.strip():
            continue
        f = line.split()
        vols[f[4]] = float(f[3])
    return vols, etiv


def aparc_stats(path, hemi):
    out = {}
    for line in path.read_text().splitlines():
        if line.startswith("#") or not line.strip():
            continue
        f = line.split()  # StructName NumVert SurfArea GrayVol ThickAvg ...
        out[f"ctx-{hemi}-{f[0]}"] = (float(f[3]), float(f[4]))
    return out


def ctx_labels(lut_names):
    """FreeSurfer codes of the Desikan parcels: 1000 + index (lh), 2000 + index (rh)."""
    names = ["unknown", "bankssts", "caudalanteriorcingulate", "caudalmiddlefrontal", "corpuscallosum", "cuneus",
             "entorhinal", "fusiform", "inferiorparietal", "inferiortemporal", "isthmuscingulate", "lateraloccipital",
             "lateralorbitofrontal", "lingual", "medialorbitofrontal", "middletemporal", "parahippocampal",
             "paracentral", "parsopercularis", "parsorbitalis", "parstriangularis", "pericalcarine", "postcentral",
             "posteriorcingulate", "precentral", "precuneus", "rostralanteriorcingulate", "rostralmiddlefrontal",
             "superiorfrontal", "superiorparietal", "superiortemporal", "supramarginal", "frontalpole", "temporalpole",
             "transversetemporal", "insula"]
    return {f"ctx-{h}-{n}": base + i for h, base in (("lh", 1000), ("rh", 2000)) for i, n in enumerate(names)
            if f"ctx-{h}-{n}" in lut_names}


def main():
    out_dir, result_dir = Path(sys.argv[1]), Path(sys.argv[2])
    recon_dir = Path(sys.argv[3]) if len(sys.argv) > 3 else out_dir
    result_dir.mkdir(parents=True, exist_ok=True)
    rows, icv, hoc = [], [], []
    for dseg in sorted(out_dir.glob("sub-*/ses-*/anat/*_desc-synthseg_dseg.nii.gz")):
        anat = dseg.parent
        session = dseg.name.replace("_desc-synthseg_dseg.nii.gz", "")
        # The recon-all of this session's T1 (one per distinct T1, named after one of its runs)
        found = sorted((recon_dir / anat.relative_to(out_dir) / "freesurfer").glob("*/mri/aparc+aseg.mgz"))
        if len(found) != 1:
            print(f"{session}: {len(found)} recon-all directories, skipped")
            continue
        fs = found[0].parent.parent
        syn_img = nib.load(dseg)
        syn = np.asarray(syn_img.dataobj).astype(np.int32)
        fs_img = nib.load(fs / "mri/aparc+aseg.mgz")
        # aparc+aseg on the SynthSeg grid: voxel of SynthSeg -> scanner -> voxel of aparc+aseg
        m = np.linalg.inv(fs_img.affine) @ syn_img.affine
        fs_on_syn = ndimage.affine_transform(np.asarray(fs_img.dataobj).astype(np.int32), m[:3, :3], m[:3, 3],
                                             output_shape=syn.shape, order=0, mode="constant", cval=0)
        voxel_syn = float(np.prod(syn_img.header.get_zooms()[:3]))
        voxel_fs = float(np.prod(fs_img.header.get_zooms()[:3]))
        fs_labels = np.asarray(fs_img.dataobj).astype(np.int32)
        with open(anat / f"{session}_desc-synthseg_volumes.csv") as f:
            soft = {k.lower(): float(v) for k, v in list(csv.DictReader(f))[0].items() if k != "subject"}
        fs_vols, etiv = aseg_stats(fs / "stats/aseg.stats")
        fs_ctx = {**aparc_stats(fs / "stats/lh.aparc.stats", "lh"), **aparc_stats(fs / "stats/rh.aparc.stats", "rh")}

        def add(region, kind, code, vol_fs, soft_vol):
            a, b = syn == code, fs_on_syn == code
            dice = 2 * np.logical_and(a, b).sum() / max(a.sum() + b.sum(), 1)
            rows.append({"session": session, "region": region, "kind": kind,
                         "volume_synthseg": round(a.sum() * voxel_syn, 1),
                         "volume_synthseg_soft": round(soft_vol, 1) if soft_vol is not None else "",
                         "volume_fs": round(vol_fs, 1), "volume_fs_voxels": round((fs_labels == code).sum() * voxel_fs, 1),
                         "dice": round(float(dice), 4)})

        for name, code in SUBCORTICAL.items():
            add(name, "subcortical", code, fs_vols[name], soft.get(SYNTHSEG_COLUMN[name]))
        for name, code in ctx_labels(set(fs_ctx)).items():
            add(name, "cortical", code, fs_ctx[name][0], soft.get(name.lower()))
        icv.append((session, soft["total intracranial"], etiv))
        h = {}
        for side, hip, ilv in (("Left", "Left-Hippocampus", "Left-Inf-Lat-Vent"), ("Right", "Right-Hippocampus", "Right-Inf-Lat-Vent")):
            r = {x["region"]: x for x in rows if x["session"] == session}
            h[side] = (r[hip]["volume_synthseg"] / (r[hip]["volume_synthseg"] + r[ilv]["volume_synthseg"]),
                       fs_vols[hip] / (fs_vols[hip] + fs_vols[ilv]))
        hoc.append((session, h))

    with open(result_dir / "regions.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    def ratio(r):
        return r["volume_synthseg"] / r["volume_fs"] if r["volume_fs"] else float("nan")

    print("Hippocampus and amygdala, per session (mm3): SynthSeg voxels | SynthSeg soft | FreeSurfer aseg.stats | "
          "FreeSurfer aparc+aseg voxels | ratio SynthSeg voxels / aseg.stats | Dice")
    for r in rows:
        if "Hippocampus" in r["region"] or "Amygdala" in r["region"]:
            print(f"  {r['session'][:22]:22} {r['region']:18} {r['volume_synthseg']:8.0f} {r['volume_synthseg_soft']:8.0f} "
                  f"{r['volume_fs']:8.0f} {r['volume_fs_voxels']:8.0f}  {ratio(r):.3f}  {r['dice']:.3f}")
    print("\nHOC (hippocampus / (hippocampus + inferior lateral ventricle)): SynthSeg | FreeSurfer aseg.stats")
    for s, h in hoc:
        print(f"  {s[:22]:22} " + "  ".join(f"{side} {a:.3f} | {b:.3f}" for side, (a, b) in h.items()))
    print("\nICV (mm3): SynthSeg total intracranial | FreeSurfer eTIV | ratio")
    for s, a, b in icv:
        print(f"  {s[:22]:22} {a:10.0f} {b:10.0f}  {a / b:.3f}")

    print("\nPer region over sessions: median ratio SynthSeg/FreeSurfer, median Dice")
    for kind in ("subcortical", "cortical"):
        regions = sorted({r["region"] for r in rows if r["kind"] == kind})
        stats = []
        for reg in regions:
            rr = [r for r in rows if r["region"] == reg]
            stats.append((statistics.median(ratio(r) for r in rr), statistics.median(r["dice"] for r in rr), reg))
        print(f"  {kind}: median over regions of the ratio {statistics.median(s[0] for s in stats):.3f}, of Dice {statistics.median(s[1] for s in stats):.3f}")
        if kind == "subcortical":
            for ra, d, reg in stats:
                print(f"    {reg:30} ratio {ra:.3f}  Dice {d:.3f}")
        else:
            stats.sort()
            for ra, d, reg in stats[:5] + stats[-5:]:
                print(f"    {reg:30} ratio {ra:.3f}  Dice {d:.3f}")
            low = sorted(stats, key=lambda s: s[1])[:5]
            print("    lowest Dice: " + ", ".join(f"{reg} {d:.2f}" for _, d, reg in low))

    # Do the two methods rank the sessions the same way? (4 sessions: an indication only)
    print("\nRegion by region, correlation over sessions of the two volumes (needs variation between sessions)")
    for reg in ("Left-Hippocampus", "Right-Hippocampus", "Left-Amygdala", "Right-Amygdala", "ctx-lh-entorhinal", "ctx-rh-entorhinal"):
        rr = [r for r in rows if r["region"] == reg]
        a, b = [r["volume_synthseg"] for r in rr], [r["volume_fs"] for r in rr]
        print(f"  {reg:20} r = {np.corrcoef(a, b)[0, 1]:.3f}   SynthSeg {[round(x) for x in a]}   FreeSurfer {[round(x) for x in b]}")


main()
