// A step run on a T1 before its recon-all rerun (params.reconall_rerun, word 'n4' in the options
// column), for T1s whose recon-all intensity normalisation fails on a strong bias field:
//   n4: N4 bias field correction inside SynthSeg's brain mask, dilated by 3 voxels.
// Found on ADNI (2026-11-17/18): with a strong bias field, mri_normalize put the white matter at 90
// instead of 110 and the volumes were wrong; n4 brought it back to 110 and the volumes in range
// (two runs). Cropping the field of view was also tried and fixed nothing, so it is not offered.
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
    if ( steps != "n4" ) {
        error "SEGMENTATION_T1PREP ${meta.id}: steps '${steps}' (n4 expected)"
    }
    """
    export OMP_NUM_THREADS=${task.cpus}
    export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=${task.cpus}
    cp "$fs_license" .license
    export FS_LICENSE=\$(pwd)/.license

    mri_synthseg --i $anat --o seg.nii.gz --threads ${task.cpus} --robust --cpu

    cat > mask.py << 'PYEOF'
import sys

import nibabel as nib
import numpy as np
from nibabel.processing import resample_from_to
from scipy.ndimage import binary_dilation

anat, report = sys.argv[1], sys.argv[2]
raw = nib.load(anat)
brain = np.asarray(resample_from_to(nib.load("seg.nii.gz"), raw, order=0).dataobj) > 0
header = raw.header.copy()   # the T1's own header: N4 refuses a mask whose spacing differs by 1e-6
header.set_data_dtype(np.uint8)
mask = binary_dilation(brain, iterations=3)
nib.save(nib.Nifti1Image(mask.astype(np.uint8), None, header), "mask.nii.gz")
with open(report, "w") as f:
    f.write(f"input {anat} shape {raw.shape} voxel {tuple(float(z) for z in raw.header.get_zooms()[:3])}\\n")
    f.write(f"brain mask (SynthSeg, dilated 3 voxels): {int(mask.sum())} voxels\\n")
PYEOF
    fspython mask.py $anat ${prefix}__t1prep.txt

    AntsN4BiasFieldCorrectionFs -i $anat -o ${prefix}__t1prep.nii.gz -m mask.nii.gz -s 2 -t 100 100 100 100
    echo "n4: AntsN4BiasFieldCorrectionFs -s 2 -t 100 100 100 100 inside the brain mask" >> ${prefix}__t1prep.txt
    rm -f .license seg.nii.gz mask.nii.gz

    # END_VERSIONS at column 0: the Python heredoc above is at column 0, so Nextflow strips no
    # indentation from this script, and <<- strips tabs only
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
