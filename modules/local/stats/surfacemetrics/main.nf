// Diffusion metrics of the cortex sampled on the FreeSurfer surfaces, per Desikan region.
//
// A voxel-wise mean over a cortical label mixes the cortex with CSF and WM: the cortex is 2 to 3 mm
// thick and a diffusion voxel 2 to 2.7 mm wide. Sampling the metrics on the surface halfway between
// the white and the pial surfaces, as cortical MD studies in AD do (Montal 2018, Sun 2024; see
// docs/plans/diagnosis_markers.md), keeps each value as far as possible from both borders:
//   1. the metric maps and the DWI brain mask go to T1 space through TractoFlow's DWI-to-T1
//      transform (linear interpolation);
//   2. every vertex is placed at white + ext.projfrac x (pial - white), 0.5 by default (mid-thickness),
//      and the maps are sampled there (trilinear), in scanner coordinates of orig.mgz;
//   3. vertices outside the DWI brain mask (mask < 0.5) are left out; each region of
//      label/?h.aparc.annot gets the mean and std over its vertices (unknown and corpuscallosum skipped).
//
// Metric names follow STATS_METRICSINROI: the part after "__" in the file name, plus "t" for the
// free-water-corrected maps (desc-fwc), so the columns match the volume stats files.
//
// Outputs (TSV): <prefix>_desc-mean_surface_stats.tsv and <prefix>_desc-std_surface_stats.tsv
//   sid, session, run, roi, <ext.meta_columns>, <metrics, alphabetical>, n_vertices
// A region with no vertex inside the mask has no row.
process STATS_SURFACEMETRICS {
    tag "$meta.id"
    label 'process_single'

    container "scilus/scilus:2.2.2"

    input:
    tuple val(meta), path(metrics), path(dwi_mask), path(t1_reference), path(transforms), path(recon_all)

    output:
    tuple val(meta), path("*_desc-mean_surface_stats.tsv"), emit: stats_mean
    tuple val(meta), path("*_desc-std_surface_stats.tsv"),  emit: stats_std
    path "versions.yml",                                    emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix         = task.ext.prefix ?: "${meta.id}"
    def projfrac       = task.ext.projfrac != null ? task.ext.projfrac : 0.5
    def meta_columns   = task.ext.meta_columns ?: []
    def meta_values    = meta_columns.collect { col -> meta.containsKey(col) && meta[col] != null ? "${meta[col]}" : "" }
    def metric_list    = metrics instanceof List ? metrics : [metrics]
    def transform_list = transforms instanceof List ? transforms : [transforms]
    def ants_transforms = transform_list.collect { t -> "-t ${t}" }.join(" ")
    def subject_id     = meta.id ?: ""
    def session_id     = meta.session ?: ""
    // Same run convention as the other stats files: bare run number, absent run = 1
    def run_id         = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    """
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=${task.cpus}
    mkdir t1_space
    for image in ${metric_list.join(' ')} ${dwi_mask}; do
        antsApplyTransforms -d 3 -i \$image -r ${t1_reference} -o t1_space/\$image \\
            -n Linear -u float ${ants_transforms}
    done

    python3 << 'PYEOF'
import os

import nibabel as nib
import numpy as np
from scipy.ndimage import map_coordinates

recon = "${recon_all}"
frac = float(${projfrac})
meta_columns = ${groovy.json.JsonOutput.toJson(meta_columns)}
meta_values = ${groovy.json.JsonOutput.toJson(meta_values)}


def metric_name(file_name):
    # As STATS_METRICSINROI: "<prefix>[_desc-<d>]__<metric>.nii.gz" -> <metric>, plus "t" for fwc
    head, metric = file_name[:-len(".nii.gz")].split("__", 1)
    if "_desc-" in head:
        desc = head.split("_desc-")[1].split("_")[0]
        metric += "t" if desc == "fwc" else "_" + desc
    return metric


metrics = {metric_name(f): np.asarray(nib.load(f"t1_space/{f}").dataobj, dtype=np.float64)
           for f in "${metric_list.join(' ')}".split()}
names = sorted(metrics)
mask_img = nib.load("t1_space/${dwi_mask}")
mask = np.asarray(mask_img.dataobj, dtype=np.float64)

# FreeSurfer surfaces are in tkregister coordinates of orig.mgz; the maps are in scanner coordinates
orig = nib.load(os.path.join(recon, "mri", "orig.mgz"))
tkr_to_voxel = np.linalg.inv(mask_img.affine) @ orig.affine @ np.linalg.inv(orig.header.get_vox2ras_tkr())

rows = []
for hemi in ("lh", "rh"):
    white, _ = nib.freesurfer.read_geometry(os.path.join(recon, "surf", f"{hemi}.white"))
    pial, _ = nib.freesurfer.read_geometry(os.path.join(recon, "surf", f"{hemi}.pial"))
    labels, _, regions = nib.freesurfer.read_annot(os.path.join(recon, "label", f"{hemi}.aparc.annot"))
    ijk = nib.affines.apply_affine(tkr_to_voxel, white + frac * (pial - white)).T
    inside = map_coordinates(mask, ijk, order=1, cval=0.0) >= 0.5
    values = {m: map_coordinates(metrics[m], ijk, order=1, cval=np.nan) for m in names}
    for index, region in enumerate(regions):
        region = region.decode()
        if region in ("unknown", "corpuscallosum"):
            continue
        keep = (labels == index) & inside
        if keep.any():
            rows.append((f"ctx-{hemi}-{region}", {m: values[m][keep] for m in names}, int(keep.sum())))

header = ["sid", "session", "run", "roi"] + meta_columns + names + ["n_vertices"]
for stat, function in (("mean", np.mean), ("std", np.std)):
    with open(f"${prefix}_desc-{stat}_surface_stats.tsv", "w") as out:
        out.write("\\t".join(header) + "\\n")
        for roi, v, n in sorted(rows):
            line = ["${subject_id}", "${session_id}", "${run_id}", roi] + meta_values
            out.write("\\t".join(line + [repr(float(function(v[m]))) for m in names] + [str(n)]) + "\\n")

with open("versions.yml", "w") as v:
    v.write('"${task.process}":\\n')
    v.write(f"    nibabel: {nib.__version__}\\n")
    v.write(f"    numpy: {np.__version__}\\n")
PYEOF
    echo "    ants: \$(antsRegistration --version | grep '^ANTs Version' | sed -E 's/.*: v?([0-9.a-zA-Z-]+).*/\\1/')" >> versions.yml
    """

    stub:
    def prefix   = task.ext.prefix ?: "${meta.id}"
    def projfrac = task.ext.projfrac != null ? task.ext.projfrac : 0.5
    def run_id   = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    """
    # settings: projfrac ${projfrac}
    for stat in mean std; do
        printf "sid\\tsession\\trun\\troi\\tn_vertices\\n${meta.id}\\t${meta.session ?: ""}\\t${run_id}\\tctx-lh-bankssts\\t0\\n" \\
            > ${prefix}_desc-\${stat}_surface_stats.tsv
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        nibabel: stub
        numpy: stub
        ants: stub
    END_VERSIONS
    """
}
