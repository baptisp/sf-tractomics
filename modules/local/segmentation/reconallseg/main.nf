// Subject segmentation taken from a FreeSurfer recon-all run (volume_source = 'reconall'): the
// same recon-all that gives the cortical thickness and the surfaces, so volumes, HOC, thickness
// and the subject-region metrics all come from one segmentation of the T1.
//
// aparc+aseg.mgz is converted to NIfTI without resampling: it stays on recon-all's 1 mm
// conformed grid, in the T1's world coordinates (as the SynthSeg labelmap stays on its own 1 mm
// grid). Labels are the FreeSurfer codes, so the FreeSurfer LUTs of the volume files apply.
// Cortical parcels are the volume version of the surface parcellation: their voxel counts differ
// from aparc.stats GrayVol (between the white and pial surfaces), which the thickness file reports.
//
// Outputs (prefix = id_session[_run] of the T1):
//   <prefix>__reconall_seg.nii.gz  aparc+aseg on the conformed grid
//   <prefix>__reconall_icv.csv     total intracranial volume = FreeSurfer eTIV (aseg.stats), mm3,
//                                  in the 'total intracranial' column read by STATS_SUBJECTVOLUMES
process SEGMENTATION_RECONALLSEG {
    tag "$meta.id"
    label 'process_single'

    container "freesurfer/freesurfer:7.4.1"

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
    mri_convert --resample_type nearest ${recon_all}/mri/aparc+aseg.mgz ${prefix}__reconall_seg.nii.gz > /dev/null
    etiv=\$(awk -F', ' '/^# Measure EstimatedTotalIntraCranialVol/ { print \$4 }' ${recon_all}/stats/aseg.stats)
    if [ -z "\$etiv" ]; then
        echo "No eTIV in ${recon_all}/stats/aseg.stats" >&2
        exit 1
    fi
    printf "subject,total intracranial\\n%s,%s\\n" "${prefix}" "\$etiv" > ${prefix}__reconall_icv.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        freesurfer: \$(mri_convert -version | grep "freesurfer" | sed -E 's/.* ([0-9.]+).*/\\1/')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}__reconall_seg.nii.gz
    printf "subject,total intracranial\\n%s,1500000\\n" "${prefix}" > ${prefix}__reconall_icv.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        freesurfer: stub
    END_VERSIONS
    """
}
