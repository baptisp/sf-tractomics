// Steps run on a T1 before its recon-all rerun (params.reconall_rerun, words 'crop' and 'n4' in the
// options column), for T1s whose recon-all intensity normalisation fails.
//   crop: cut the field of view to SynthSeg's brain box plus task.ext.crop_margin_mm (20 mm). The
//         header is kept, so world coordinates do not change; only the grid's extent does.
//   n4:   N4 bias field correction inside SynthSeg's brain mask, dilated by 3 voxels.
// Found on ADNI (2026-11-17/18): on Siemens Skyra runs with a large head-and-neck field of view,
// mri_normalize put the white matter at 90 instead of 110 and recon-all lost about a third of the
// cortex. N4 alone or cropping alone did not move the peak; both together brought it back to 110.
// A strong bias field (GE runs) was fixed by n4 alone.
process SEGMENTATION_T1PREP {
    tag "$meta.id"
    label 'process_single'

    container "freesurfer/freesurfer:7.4.1"

    input:
        tuple val(meta), path(anat), path(fs_license), val(steps)

    output:
        tuple val(meta), path("*__t1prep.nii.gz"), emit: t1
        tuple val(meta), path("*__t1prep.txt")   , emit: report
        path "versions.yml"                      , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    def margin = task.ext.crop_margin_mm ?: 20
    def words = steps.tokenize(" ")
    def unknown = words - ["crop", "n4"]
    if ( !words || unknown ) {
        error "SEGMENTATION_T1PREP ${meta.id}: steps '${steps}' (crop and/or n4 expected)"
    }
    def do_crop = "crop" in words
    def do_n4 = "n4" in words
    """
    export OMP_NUM_THREADS=${task.cpus}
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=${task.cpus}
    cp "$fs_license" .license
    export FS_LICENSE=\$(pwd)/.license

    mri_synthseg --i $anat --o seg.nii.gz --threads ${task.cpus} --robust --cpu

    cat > prep.py << 'PYEOF'
import sys

import nibabel as nib
import numpy as np
from nibabel.processing import resample_from_to
from scipy.ndimage import binary_dilation

anat, do_crop, margin_mm, report = sys.argv[1], sys.argv[2] == "true", float(sys.argv[3]), sys.argv[4]
raw = nib.load(anat)
brain = np.asarray(resample_from_to(nib.load("seg.nii.gz"), raw, order=0).dataobj) > 0
lines = [f"input {anat} shape {raw.shape} voxel {tuple(float(z) for z in raw.header.get_zooms()[:3])}"]
img = raw
if do_crop:
    m = np.ceil(margin_mm / np.array(raw.header.get_zooms()[:3])).astype(int)
    idx = np.argwhere(brain)
    lo = np.maximum(idx.min(0) - m, 0)
    hi = np.minimum(idx.max(0) + m + 1, brain.shape)
    img = raw.slicer[lo[0]:hi[0], lo[1]:hi[1], lo[2]:hi[2]]
    brain = brain[lo[0]:hi[0], lo[1]:hi[1], lo[2]:hi[2]]
    kept = np.prod(img.shape) / np.prod(raw.shape)
    lines.append(f"crop margin {margin_mm} mm: voxels {lo.tolist()} to {(hi - 1).tolist()}, shape {img.shape}, {kept:.0%} of the field of view kept")
nib.save(img, "t1_grid.nii.gz")
header = img.header.copy()   # the T1's own header: N4 refuses a mask whose spacing differs by 1e-6
header.set_data_dtype(np.uint8)
mask = binary_dilation(brain, iterations=3)
nib.save(nib.Nifti1Image(mask.astype(np.uint8), None, header), "mask.nii.gz")
lines.append(f"brain mask (SynthSeg, dilated 3 voxels): {int(mask.sum())} voxels")
with open(report, "w") as f:
    f.write("\\n".join(lines) + "\\n")
PYEOF
    fspython prep.py $anat ${do_crop} ${margin} ${prefix}__t1prep.txt

    if ${do_n4}; then
        AntsN4BiasFieldCorrectionFs -i t1_grid.nii.gz -o ${prefix}__t1prep.nii.gz -m mask.nii.gz -s 2 -t 100 100 100 100
        echo "n4: AntsN4BiasFieldCorrectionFs -s 2 -t 100 100 100 100 inside the brain mask" >> ${prefix}__t1prep.txt
    else
        mv t1_grid.nii.gz ${prefix}__t1prep.nii.gz
    fi
    rm -f .license seg.nii.gz t1_grid.nii.gz mask.nii.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        freesurfer: \$(mri_convert -version | grep "freesurfer" | sed -E 's/.* ([0-9.]+).*/\\1/')
        t1prep_steps: "${steps}"
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    cp $anat ${prefix}__t1prep.nii.gz
    echo "stub ${steps}" > ${prefix}__t1prep.txt
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        freesurfer: 7.4.1
        t1prep_steps: "${steps}"
    END_VERSIONS
    """
}
