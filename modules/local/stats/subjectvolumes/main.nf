// Volumes of the regions of a subject's own segmentation (SynthSeg, SAMSEG or FreeSurfer
// aparc+aseg), counted in the space the segmentation was produced in (native T1). Unlike
// STATS_ROIVOLUMES on a warped template, nothing here is deformed, so the volumes can be used to
// measure atrophy.
//
// Output CSV:
//   sid,session,run,roi,volume_voxels,volume_mm3,volume_source,icv_mm3,volume_icv_fraction,qc_score,qc_flags,scanner,duplicate_of,t1_shared_with
// The first six columns match STATS_ROIVOLUMES so the existing collectors read it unchanged.
// volume_icv_fraction = volume_mm3 / icv_mm3 (the region's share of the intracranial volume, to
// compare heads of different sizes); empty when icv_mm3 is.
//
// qc_flags lists, separated by ';', every reason not to trust this sample's volumes (empty = no
// reason found): qc_low (SynthSeg QC score below ext.qc_threshold), icv_missing, icv_implausible
// (outside ext.icv_min..ext.icv_max mm3), empty:<regions> (LUT regions with no voxel), duplicate
// (the T1 holds the same voxels as another sample's, see duplicate_of). Flags that need several
// sessions (intracranial volume drifting within a subject) are added when the global CSVs are built.
// t1_shared_with names the first DWI run of the session whose T1 file this run shares (empty on the
// first run and on unshared T1s): with SynthSeg or SAMSEG its rows are copies of that run's, not
// another measurement.
process STATS_SUBJECTVOLUMES {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/../../../nf-neuro/stats/roivolumes/environment.yml"
    container "${ 'community.wave.seqera.io/library/nibabel_numpy:4148b92a8cbc6976' }"

    input:
    tuple val(meta), val(volume_source), path(labelmap), path(lut), path(seg_volumes), path(qc_scores)  /* optional, input = [] */

    output:
    tuple val(meta), val(volume_source), path("*_volumes.csv"), emit: volumes
    path "versions.yml",                    emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix        = task.ext.prefix ?: "${meta.id}"
    // <prefix>__seg-<source>_<ext.first_suffix>_desc-roi_volumes.csv: one file per source, so the
    // volumes of two segmentations of one sample never share a name
    def source_label  = volume_source == "samseg_long" ? "samseg" : volume_source
    def suffix        = "_seg-${source_label}" + (task.ext.first_suffix ? "_${task.ext.first_suffix}" : "") + "_desc-roi_volumes"
    // Labels the segmenter cannot produce (SynthSeg has no choroid plexus): written with empty
    // volumes, so they read as "not measured" instead of a measured 0. ext.missing_labels maps a
    // source to its labels.
    def missing_json  = groovy.json.JsonOutput.toJson(((task.ext.missing_labels ?: [:])[volume_source] ?: []).collect { l -> l as int })
    def qc_threshold  = task.ext.qc_threshold != null ? task.ext.qc_threshold : 0.65
    def icv_min       = task.ext.icv_min ?: 900000
    def icv_max       = task.ext.icv_max ?: 2300000
    def subject_id    = meta.id ?: ""
    def session_id    = meta.session ?: ""
    // Same convention as STATS_METRICSINROI and STATS_ROIVOLUMES: a bare run number, and run 1
    // when the run entity is absent, so stats and volume rows of a sample share one key.
    def run_id        = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    // Commas would break the CSV
    def scanner       = (meta.scanner ?: "").toString().replace(",", " ")
    def duplicate_of  = (meta.duplicate_of ?: "").toString().replace(",", " ")
    def shared_with   = (meta.t1_shared_with ?: "").toString().replace(",", " ")
    """
    python3 << 'PYEOF'
import csv
import json
import os

import nibabel as nib
import numpy as np

img      = nib.load("${labelmap}")
# Round to guard against float-stored labelmaps
data_int = np.round(img.get_fdata()).astype(np.int32)
vox_vol  = float(np.prod(img.header.get_zooms()[:3]))

with open("${lut}") as f:
    lut = json.load(f)

def first_row(path):
    if path and os.path.isfile(path):
        with open(path) as f:
            return next(csv.DictReader(f), {})
    return {}

# Intracranial volume from the segmenter's table (SynthSeg --vol, SAMSEG sbTIV). A FreeSurfer
# aparc+aseg alone does not carry it, so the column is left empty then.
icv = ""
for key, value in first_row("${seg_volumes}").items():
    if key and key.strip().lower() == "total intracranial":
        try:
            icv = f"{float(value):.4f}"
        except (TypeError, ValueError):
            print(f"WARNING: unreadable intracranial volume {value!r}; icv_mm3 left empty")
        break

# SynthSeg QC: one score per structure group, the lowest one is kept
qc_score = ""
scores = []
for key, value in first_row("${qc_scores}").items():
    if key and key.strip().lower() != "subject":
        try:
            scores.append(float(value))
        except (TypeError, ValueError):
            pass
if scores:
    qc_score = f"{min(scores):.4f}"

missing = set(${missing_json})
counts = np.bincount(data_int[data_int >= 0].ravel())

rows, empty = [], []
for label_id, label_name in sorted(lut.items(), key=lambda x: int(x[0])):
    label = int(label_id)
    if label in missing:
        rows.append((label_name, "", ""))
        continue
    count = int(counts[label]) if label < counts.size else 0
    if count == 0:
        empty.append(label_name)
    rows.append((label_name, str(count), f"{count * vox_vol:.4f}"))

flags = []
if qc_score and float(qc_score) < ${qc_threshold}:
    flags.append("qc_low")
if "${volume_source}" in ("synthseg", "samseg_long", "reconall"):
    if not icv:
        flags.append("icv_missing")
    elif not (${icv_min} <= float(icv) <= ${icv_max}):
        flags.append("icv_implausible")
if empty:
    flags.append("empty:" + "|".join(empty))
if "${duplicate_of}":
    flags.append("duplicate")
qc_flags = ";".join(flags)

with open("${prefix}_${suffix}.csv", "w") as out:
    out.write("sid,session,run,roi,volume_voxels,volume_mm3,volume_source,icv_mm3,volume_icv_fraction,qc_score,qc_flags,scanner,duplicate_of,t1_shared_with\\n")
    for name, voxels, mm3 in rows:
        fraction = f"{float(mm3) / float(icv):.8f}" if mm3 and icv and float(icv) > 0 else ""
        out.write(f"${subject_id},${session_id},${run_id},{name},{voxels},{mm3},${volume_source},"
                  f"{icv},{fraction},{qc_score},{qc_flags},${scanner},${duplicate_of},${shared_with}\\n")

with open("versions.yml", "w") as v:
    v.write('"${task.process}":\\n')
    v.write(f"    nibabel: {nib.__version__}\\n")
    v.write(f"    numpy: {np.__version__}\\n")
PYEOF
    """

    stub:
    def prefix       = task.ext.prefix ?: "${meta.id}"
    def source_label = volume_source == "samseg_long" ? "samseg" : volume_source
    def suffix       = "_seg-${source_label}" + (task.ext.first_suffix ? "_${task.ext.first_suffix}" : "") + "_desc-roi_volumes"
    """
    echo "sid,session,run,roi,volume_voxels,volume_mm3,volume_source,icv_mm3,volume_icv_fraction,qc_score,qc_flags,scanner,duplicate_of,t1_shared_with" > ${prefix}_${suffix}.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        nibabel: stub
        numpy: stub
    END_VERSIONS
    """
}
