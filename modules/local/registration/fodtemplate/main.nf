// fODF registration of one session to the study template (mrregister, affine then non-linear),
// the step that defines fibre cross-section. Also checks the fODF orientation against the DWI
// itself: mean |cos| between the fODF peak and the tensor main eigenvector where FA > 0.7
// (orientation_agreement; about 0.94 measured on OASIS-3, 0.59 with the axes mirrored, 0.5 at
// random). Below ext.min_orientation_agreement the task fails: every fixel would be wrong.
// Output: <prefix>__subject2template.mif (MRtrix deformation, template grid),
//         <prefix>__fc_registration.txt (orientation_agreement on one line)
process REGISTRATION_FODTEMPLATE {
    tag "$meta.id"
    label 'process_medium'

    container "mrtrix3/mrtrix3:3.0.5"

    input:
    tuple val(meta), path(fod), path(mask), path(dwi), path(bval), path(bvec), path(template)

    output:
    tuple val(meta), path("*__subject2template.mif"), emit: warp
    tuple val(meta), path("*__fc_registration.txt"),  emit: qc
    path "versions.yml",                              emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix    = task.ext.prefix ?: "${meta.id}"
    def min_agree = task.ext.min_orientation_agreement != null ? task.ext.min_orientation_agreement : 0.8
    """
    export MRTRIX_NTHREADS=${task.cpus}
    export MRTRIX_TMPFILE_DIR=\$PWD

    # Orientation check, in the subject's DWI space
    mrconvert -quiet ${dwi} -fslgrad ${bvec} ${bval} dwi.mif
    dwi2tensor -quiet -mask ${mask} dwi.mif dt.mif
    tensor2metric -quiet dt.mif -mask ${mask} -fa fa.mif -vector v1.mif -modulate none
    sh2peaks -quiet ${fod} -num 1 -mask ${mask} peak.mif
    mrcalc -quiet v1.mif peak.mif -mult - | mrmath -quiet - sum -axis 3 dot.mif
    mrmath -quiet peak.mif norm -axis 3 peak_norm.mif
    mrcalc -quiet dot.mif peak_norm.mif -div -abs cos.mif
    mrcalc -quiet fa.mif 0.7 -gt ${mask} -mult single_fibre.mif
    agreement=\$(mrstats -quiet cos.mif -mask single_fibre.mif -output mean | tr -d ' ')
    echo "orientation_agreement \$agreement" > ${prefix}__fc_registration.txt
    if awk -v a="\$agreement" -v m="${min_agree}" 'BEGIN{ exit !(a == "" || a == "nan" || a + 0 < m + 0) }'; then
        echo "fODF orientation does not match the DWI (agreement \$agreement < ${min_agree}): check the fODF basis and axes" >&2
        exit 1
    fi

    mrregister -quiet ${fod} -mask1 ${mask} ${template}/fod_template.mif -mask2 ${template}/template_mask.mif \\
        -nl_warp ${prefix}__subject2template.mif template2subject.mif -nthreads ${task.cpus}

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: \$(mrconvert -version 2>&1 | sed -n 's/^== mrconvert \\([0-9.]*\\).*/\\1/p')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}__subject2template.mif
    echo "orientation_agreement 1" > ${prefix}__fc_registration.txt

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: stub
    END_VERSIONS
    """
}
