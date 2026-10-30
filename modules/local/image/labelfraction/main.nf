// Fraction of each acquisition voxel that belongs to each label of a segmentation, written on the
// grid of the metric maps, for partial-volume-weighted region statistics.
//
// The diffusion maps are on a resampled grid (1 mm in TractoFlow) but hold the information of the
// acquired voxels (2 to 2.7 mm): partial volume happens at the acquisition grid. So:
//   1. the labels are warped (exact GenericLabel) onto a copy of the acquisition grid refined
//      ext.supersampling times per axis (4 by default), through the given ANTs transforms;
//   2. per acquisition voxel and label, fraction = refined voxels of that label / supersampling^3;
//   3. each voxel of the target grid takes the fraction of the acquisition voxel holding its centre.
// The acquisition grid comes from acq_reference (the raw DWI or its b0): DWI preprocessing
// (eddy, resampling, cropping) keeps world coordinates, so that grid stays aligned with the maps.
//
// ext.min_fraction = 0 (default) writes the fractions, for weighted means. A value above 0 writes
// binary masks of the voxels at least that much inside the label instead (unweighted means).
//
// brain_mask (optional, on the target grid): the metric maps are 0 outside it, so the maps get no
// weight there; otherwise those zeros pull the region means down (up to 15% of a frontal pole lies
// outside a b0 brain mask). Region statistics then use the voxels of the region inside the mask.
//
// fwc_maps (optional, on the target grid): free-water-corrected AD, RD and MD. scilpy's outlier
// removal sets them to 0 where the corrected fit failed (mostly CSF borders), and a weighted mean
// counts those zeros as values. The share of each region's weight on such voxels is reported, not
// removed, so it can be checked for group differences or used as a covariate.
//
// Outputs:
//   <prefix>__<roi>_fraction.nii.gz   one map per LUT label present in the image (float32); with
//                                     min_fraction, only labels with a voxel above it
//   <prefix>_fraction_sums.csv        sid, session, run, roi, acq_voxels (sum of fractions),
//                                     volume_mm3 (acq_voxels x acquisition voxel volume),
//                                     in_mask_fraction (share of the region's weight on the target
//                                     grid inside brain_mask; 1 without a mask), small_region (1 when
//                                     acq_voxels is below ext.small_region_voxels, 50 by default: a
//                                     mean over so few acquired voxels is noisy; 0 otherwise),
//                                     fwc_failed_fraction (share of the region's weight, as used by
//                                     the statistics, on brain voxels where any of fwc_maps is 0;
//                                     empty without fwc_maps), for every LUT label
process IMAGE_LABELFRACTION {
    tag "$meta.id"
    label 'process_single'

    container "scilus/scilus:2.2.2"

    input:
    tuple val(meta), path(labels), path(acq_reference), path(target_reference), path(transforms), path(lut), path(brain_mask) /* optional, input = [] */, path(fwc_maps) /* optional, input = [] */

    output:
    tuple val(meta), path("*__*_fraction.nii.gz"), emit: fractions
    tuple val(meta), path("*_fraction_sums.csv"),  emit: sums
    path "versions.yml",                           emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix       = task.ext.prefix ?: "${meta.id}"
    def factor       = task.ext.supersampling ?: 4
    def min_fraction = task.ext.min_fraction ?: 0
    def small_voxels = task.ext.small_region_voxels != null ? task.ext.small_region_voxels : 50
    def transform_list = transforms instanceof List ? transforms : [transforms]
    def fwc_list     = fwc_maps instanceof List ? fwc_maps : [fwc_maps]
    def ants_transforms = transform_list.collect { t -> "-t ${t}" }.join(" ")
    def subject_id   = meta.id ?: ""
    def session_id   = meta.session ?: ""
    // Same run convention as the other stats files: bare run number, absent run = 1
    def run_id       = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    """
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=${task.cpus}

    python3 << 'PYEOF'
import nibabel as nib
import numpy as np

# Refined copy of the acquisition grid: k x k x k sub-voxels tile each acquisition voxel
acq = nib.load("${acq_reference}")
k = ${factor}
shape = tuple(int(n) * k for n in acq.shape[:3])
sub = np.diag([1.0 / k, 1.0 / k, 1.0 / k, 1.0])
sub[:3, 3] = -(k - 1) / (2.0 * k)
nib.save(nib.Nifti1Image(np.zeros(shape, np.uint8), acq.affine @ sub), "acq_refined.nii.gz")
PYEOF

    antsApplyTransforms -d 3 -i ${labels} -r acq_refined.nii.gz -o labels_refined.nii.gz \\
        -n GenericLabel -u short ${ants_transforms}

    python3 << 'PYEOF'
import json

import nibabel as nib
import numpy as np

k = ${factor}
acq = nib.load("${acq_reference}")
target = nib.load("${target_reference}")
refined = np.asarray(nib.load("labels_refined.nii.gz").dataobj).astype(np.int32)
nx, ny, nz = acq.shape[:3]
blocks = refined.reshape(nx, k, ny, k, nz, k)

# Acquisition voxel holding the centre of each target voxel
ijk = np.indices(target.shape[:3]).reshape(3, -1).T
to_acq = np.linalg.inv(acq.affine) @ target.affine
idx = np.rint(nib.affines.apply_affine(to_acq, ijk)).astype(int)
inside = np.all((idx >= 0) & (idx < (nx, ny, nz)), axis=1)

acq_voxel_mm3 = float(np.prod(acq.header.get_zooms()[:3]))
lut = json.load(open("${lut}"))
brain = np.ones(len(ijk), bool)
if "${brain_mask}":
    mask_img = nib.load("${brain_mask}")
    if mask_img.shape[:3] != target.shape[:3] or not np.allclose(mask_img.affine, target.affine, atol=1e-3):
        raise SystemExit("ERROR: brain_mask must be on the grid of target_reference")
    brain = np.asarray(mask_img.dataobj).reshape(-1) > 0
fwc_files = "${fwc_list.join(' ')}".split()
failed = np.zeros(len(ijk), bool)
for f in fwc_files:
    img = nib.load(f)
    if img.shape[:3] != target.shape[:3] or not np.allclose(img.affine, target.affine, atol=1e-3):
        raise SystemExit(f"ERROR: {f} must be on the grid of target_reference")
    failed |= np.asarray(img.dataobj).reshape(-1) == 0
failed &= brain
with open("${prefix}_fraction_sums.csv", "w") as sums:
    sums.write("sid,session,run,roi,acq_voxels,volume_mm3,in_mask_fraction,small_region,fwc_failed_fraction\\n")
    for label_id, name in sorted(lut.items(), key=lambda x: int(x[0])):
        fraction = (blocks == int(label_id)).sum(axis=(1, 3, 5)) / float(k ** 3)
        total = float(fraction.sum())
        out = np.zeros(len(ijk), np.float32)
        out[inside] = fraction[idx[inside, 0], idx[inside, 1], idx[inside, 2]]
        in_mask = float(out[brain].sum() / out.sum()) if out.sum() > 0 else None
        out[~brain] = 0
        in_mask_str = "" if in_mask is None else f"{in_mask:.4f}"
        small = 1 if total < ${small_voxels} else 0
        if ${min_fraction} > 0:
            out = (out >= ${min_fraction}).astype(np.float32)
        # share of the weight the statistics use (fractions, or the binary mask) on failed voxels
        failed_str = f"{float(out[failed].sum() / out.sum()):.4f}" if fwc_files and out.sum() > 0 else ""
        sums.write(f"${subject_id},${session_id},${run_id},{name},{total:.4f},{total * acq_voxel_mm3:.4f},{in_mask_str},{small},{failed_str}\\n")
        if not out.any():
            continue   # absent, entirely outside the brain mask, or no voxel above min_fraction: no map
        nib.save(nib.Nifti1Image(out.reshape(target.shape[:3]), target.affine),
                 f"${prefix}__{name}_fraction.nii.gz")

with open("versions.yml", "w") as v:
    v.write('"${task.process}":\\n')
    v.write(f"    nibabel: {nib.__version__}\\n")
    v.write(f"    numpy: {np.__version__}\\n")
PYEOF
    echo "    ants: \$(antsRegistration --version | grep '^ANTs Version' | sed -E 's/.*: v?([0-9.a-zA-Z-]+).*/\\1/')" >> versions.yml
    """

    stub:
    def prefix       = task.ext.prefix ?: "${meta.id}"
    def factor       = task.ext.supersampling ?: 4
    def min_fraction = task.ext.min_fraction ?: 0
    def small_voxels = task.ext.small_region_voxels != null ? task.ext.small_region_voxels : 50
    """
    # settings: supersampling ${factor} min_fraction ${min_fraction} small_region_voxels ${small_voxels}
    touch ${prefix}__Left-Hippocampus_fraction.nii.gz
    echo "sid,session,run,roi,acq_voxels,volume_mm3,in_mask_fraction,small_region,fwc_failed_fraction" > ${prefix}_fraction_sums.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        nibabel: stub
        numpy: stub
        ants: stub
    END_VERSIONS
    """
}
