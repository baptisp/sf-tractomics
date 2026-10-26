// Volumes of the regions of a subject's own segmentation (SynthSeg or FreeSurfer aparc+aseg),
// counted in the space the segmentation was produced in (native T1). Unlike STATS_ROIVOLUMES on
// a warped template, nothing here is deformed, so the volumes can be used to measure atrophy.
//
// Output CSV: sid,session,run,roi,volume_voxels,volume_mm3,volume_source,icv_mm3
// The first six columns match STATS_ROIVOLUMES so the existing collectors read it unchanged.
process STATS_SUBJECTVOLUMES {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/../../../nf-neuro/stats/roivolumes/environment.yml"
    container "${ 'community.wave.seqera.io/library/nibabel_numpy:4148b92a8cbc6976' }"

    input:
    tuple val(meta), path(labelmap), path(lut), path(synthseg_volumes)  /* optional, input = [] */

    output:
    tuple val(meta), path("*_volumes.csv"), emit: volumes
    path "versions.yml",                    emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix        = task.ext.prefix ?: "${meta.id}"
    def suffix        = task.ext.first_suffix ? "${task.ext.first_suffix}_volumes" : "volumes"
    def volume_source = task.ext.volume_source ?: "subject"
    def subject_id    = meta.id ?: ""
    def session_id    = meta.session ?: ""
    def run_id        = meta.run ?: ""
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

# Intracranial volume from SynthSeg's --vol table (computed from its soft posteriors).
# A FreeSurfer aparc+aseg alone does not carry it, so the column is left empty then.
icv = ""
vol_csv = "${synthseg_volumes}"
if vol_csv and os.path.isfile(vol_csv):
    with open(vol_csv) as f:
        row = next(csv.DictReader(f))
    for key, value in row.items():
        if key and key.strip().lower() == "total intracranial":
            icv = f"{float(value):.4f}"
            break

counts = np.bincount(data_int[data_int >= 0].ravel())

with open("${prefix}_${suffix}.csv", "w") as out:
    out.write("sid,session,run,roi,volume_voxels,volume_mm3,volume_source,icv_mm3\\n")
    for label_id, label_name in sorted(lut.items(), key=lambda x: int(x[0])):
        label = int(label_id)
        count = int(counts[label]) if label < counts.size else 0
        out.write(f"${subject_id},${session_id},${run_id},{label_name},{count},"
                  f"{count * vox_vol:.4f},${volume_source},{icv}\\n")

with open("versions.yml", "w") as v:
    v.write('"${task.process}":\\n')
    v.write(f"    nibabel: {nib.__version__}\\n")
    v.write(f"    numpy: {np.__version__}\\n")
PYEOF
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def suffix = task.ext.first_suffix ? "${task.ext.first_suffix}_volumes" : "volumes"
    """
    echo "sid,session,run,roi,volume_voxels,volume_mm3,volume_source,icv_mm3" > ${prefix}_${suffix}.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        nibabel: stub
        numpy: stub
    END_VERSIONS
    """
}
