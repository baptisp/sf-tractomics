process STATS_ROIVOLUMES {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/environment.yml"
    container "${ 'community.wave.seqera.io/library/nibabel_numpy:4148b92a8cbc6976' }"

    input:
    tuple val(meta), path(rois), path(rois_lut)  /* optional, input = [] */

    output:
    tuple val(meta), path("*_volumes.csv"), emit: volumes
    path "versions.yml",                    emit: versions, topic: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix            = task.ext.prefix ?: "${meta.id}"
    def suffix            = task.ext.first_suffix ? "${task.ext.first_suffix}_volumes" : "volumes"
    def use_label         = task.ext.use_label ? true : false
    def use_label_py      = use_label ? "True" : "False"
    def mask_volume       = task.ext.mask_volume ?: "nonzero"
    assert mask_volume in ["nonzero", "fraction"] : "ext.mask_volume must be 'nonzero' or 'fraction', not '${mask_volume}'"
    def substrs_to_remove = task.ext.key_substrs_to_remove ?: []
    def substrs_json      = groovy.json.JsonOutput.toJson(substrs_to_remove)
    // For labels mode: rois is a list; join paths as space-separated string for Python to split
    def rois_str          = rois instanceof List ? rois.join(' ') : "${rois}"
    def subject_id        = meta.id ?: ""
    def session_id        = meta.session ?: ""
    // Bare run number ("6", not "run-6"), matching participants.tsv's own 'run'
    // column convention and metricsinroi/main.nf's identical treatment. Absent run
    // entity (single-run subject/session) canonicalizes to run 1, matching the
    // "run-1" default used when joining participants.tsv covariates (see
    // canonicalTsvRun in utils_nfcore_sf-tractomics_pipeline) -- the "run-" prefix
    // only matters for that internal join key, not for this output column.
    def run_id            = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    """
    python3 << 'PYEOF'
import nibabel as nib
import numpy as np
import json
import os

prefix     = "${prefix}"
suffix     = "${suffix}"
use_label  = ${use_label_py}
substrs    = ${substrs_json}
mask_volume = "${mask_volume}"
subject_id = "${subject_id}"
session_id = "${session_id}"
run_id     = "${run_id}"

output_file = f"{prefix}_{suffix}.csv"

if use_label:
    # Labelmap mode: single atlas/labelmap image — load once, count all labels in one pass.
    # Equivalent per label to:
    #   mrcalc atlas <label_id> -eq mask + mrstats mask -mask mask -output count
    img  = nib.load("${rois}")
    data = img.get_fdata()
    # Round to nearest integer to guard against MultiLabel warp float precision
    data_int = np.round(data).astype(np.int32)
    vox_vol  = float(np.prod(img.header.get_zooms()[:3]))

    with open("${rois_lut}") as f:
        lut = json.load(f)

    with open(output_file, 'w') as out:
        out.write("sid,session,run,roi,volume_voxels,volume_mm3\\n")
        for label_id, label_name in sorted(lut.items(), key=lambda x: int(x[0])):
            count   = int(np.sum(data_int == int(label_id)))
            vol_mm3 = count * vox_vol
            out.write(f"{subject_id},{session_id},{run_id},{label_name},{count},{vol_mm3:.4f}\\n")
else:
    # Labels mode: list of binary/weighted ROI masks, one file per label.
    # ext.mask_volume = "nonzero" (default): every non-zero voxel counts once.
    # ext.mask_volume = "fraction": each voxel counts by its value, which must lie in [0, 1]: the
    # covered fraction of the border voxels of a binary mask warped with linear interpolation
    # (counting those as whole voxels inflates thin structures by 40% or more).
    # NaN voxels are excluded.
    mask_files = sorted("${rois_str}".split())

    with open(output_file, 'w') as out:
        out.write("sid,session,run,roi,volume_voxels,volume_mm3\\n")
        for mask_file in mask_files:
            roi_name = os.path.basename(mask_file)
            for ext in ('.nii.gz', '.nii'):
                if roi_name.endswith(ext):
                    roi_name = roi_name[:-len(ext)]
                    break
            for s in substrs:
                roi_name = roi_name.removeprefix(s).removesuffix(s)

            img     = nib.load(mask_file)
            data    = np.nan_to_num(img.get_fdata(), nan=0.0)
            vox_vol = float(np.prod(img.header.get_zooms()[:3]))
            if mask_volume == "fraction":
                if data.min() < 0 or data.max() > 1:
                    raise SystemExit(f"ERROR: {mask_file} has values outside [0, 1] "
                                     f"({data.min():g} to {data.max():g}); ext.mask_volume = 'fraction' "
                                     "needs fractional masks, use 'nonzero' for other maps")
                count = float(data.sum())
            else:
                count = float(np.sum(data > 0))
            count_str = str(int(round(count))) if abs(count - round(count)) < 1e-6 else f"{count:.4f}"
            vol_mm3 = count * vox_vol
            out.write(f"{subject_id},{session_id},{run_id},{roi_name},{count_str},{vol_mm3:.4f}\\n")

with open("versions.yml", "w") as v:
    v.write('"${task.process}":\\n')
    v.write(f"    nibabel: {nib.__version__}\\n")
    v.write(f"    numpy: {np.__version__}\\n")
PYEOF
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def suffix = task.ext.first_suffix ? "${task.ext.first_suffix}_volumes" : "volumes"
    def mask_volume = task.ext.mask_volume ?: "nonzero"
    """
    # settings: mask_volume ${mask_volume}
    touch ${prefix}_${suffix}.csv

    python3 -c "
with open('versions.yml', 'w') as v:
    import nibabel, numpy
    v.write('\"${task.process}\":\\n')
    v.write(f'    nibabel: {nibabel.__version__}\\n')
    v.write(f'    numpy: {numpy.__version__}\\n')
"
    """
}
