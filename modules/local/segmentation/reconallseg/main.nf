// Subject segmentation taken from a FreeSurfer recon-all run (volume_source = 'reconall'): the
// same recon-all that gives the cortical thickness and the surfaces, so volumes, HOC, thickness
// and the subject-region metrics all come from one segmentation of the T1.
//
// aparc+aseg.mgz is converted to NIfTI without resampling (nibabel, so no FreeSurfer licence is
// needed): it stays on recon-all's 1 mm conformed grid, in the T1's world coordinates (as the
// SynthSeg labelmap stays on its own 1 mm grid). Labels are the FreeSurfer codes, so the
// FreeSurfer LUTs of the volume files apply. Cortical parcels are the volume version of the
// surface parcellation.
//
// Outputs (prefix = id_session[_run] of the T1):
//   <prefix>__reconall_seg.nii.gz  aparc+aseg on the conformed grid
//   <prefix>__reconall_icv.csv     total intracranial volume = FreeSurfer eTIV (aseg.stats), mm3,
//                                  in the 'total intracranial' column read by STATS_SUBJECTVOLUMES
process SEGMENTATION_RECONALLSEG {
    tag "$meta.id"
    label 'process_single'

    container "community.wave.seqera.io/library/nibabel_numpy:4148b92a8cbc6976"

    input:
    tuple val(meta), path(recon_all)

    output:
    tuple val(meta), path("*__reconall_seg.nii.gz"), path("*__reconall_icv.csv"), emit: seg
    path "versions.yml",                                                         emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    python3 << 'PYEOF'
import re

import nibabel as nib
import numpy as np

img = nib.load("${recon_all}/mri/aparc+aseg.mgz")
labels = np.asarray(img.dataobj).astype(np.int32)
out = nib.Nifti1Image(labels, img.affine)
out.set_qform(img.affine, code=1)
out.set_sform(img.affine, code=1)
nib.save(out, "${prefix}__reconall_seg.nii.gz")

etiv = None
with open("${recon_all}/stats/aseg.stats") as f:
    for line in f:
        m = re.match(r"# Measure EstimatedTotalIntraCranialVol, eTIV, [^,]*, ([0-9.eE+-]+), mm\\^3", line)
        if m:
            etiv = float(m.group(1))
if etiv is None:
    raise SystemExit("No eTIV in ${recon_all}/stats/aseg.stats")
with open("${prefix}__reconall_icv.csv", "w") as f:
    f.write(f"subject,total intracranial\\n${prefix},{etiv}\\n")

with open("versions.yml", "w") as v:
    v.write('"${task.process}":\\n')
    v.write(f"    nibabel: {nib.__version__}\\n")
PYEOF
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}__reconall_seg.nii.gz
    printf "subject,total intracranial\\n%s,1500000\\n" "${prefix}" > ${prefix}__reconall_icv.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        nibabel: stub
    END_VERSIONS
    """
}
