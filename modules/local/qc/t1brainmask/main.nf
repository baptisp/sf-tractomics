// Size of the T1 brain mask that preproc_t1 handed to the T1-to-DWI registration. ANTs BET can
// return a mask of the whole head (7 to 14 L) or of a patch of the face (0.4 L) without failing;
// the T1 then reaches the registration with its skull, is misplaced in DWI space, and every
// metric read through that registration (subject GM regions, surface metrics) is wrong. Nothing
// fails here: a flagged run keeps its rows; list it in params.t1_bet_rerun to brain-extract it
// with SynthStrip instead.
//
// Output CSV, one row:
//   sid,session,run,brain_mask_ml,bet_method,qc_flags
// brain_mask_ml: mask volume in mL. bet_method: antsbet or synthstrip (input bet_method).
// qc_flags: mask_too_large (above ext.max_ml, 2500), mask_too_small (below ext.min_ml, 900),
// empty (no voxel). ADNI, 2026-11-24: good runs 1.26 to 1.97 L; the 11 failed masks 0.42 L and
// 7.2 to 14.1 L.
process QC_T1BRAINMASK {
    tag "$meta.id"
    label 'process_single'

    container "mrtrix3/mrtrix3:3.0.5"

    input:
    tuple val(meta), path(mask), val(bet_method)

    output:
    tuple val(meta), path("*_t1brainmask_qc.csv"), emit: qc
    path "versions.yml",                           emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix     = task.ext.prefix ?: "${meta.id}"
    def min_ml     = task.ext.min_ml != null ? task.ext.min_ml : 900
    def max_ml     = task.ext.max_ml != null ? task.ext.max_ml : 2500
    def subject_id = meta.id ?: ""
    def session_id = meta.session ?: ""
    // Same run convention as the other stats files: bare run number, absent run = 1
    def run_id     = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    """
    export MRTRIX_NTHREADS=${task.cpus}
    n=\$(mrstats -quiet ${mask} -ignorezero -output count | tr -d ' ')
    voxel=\$(mrinfo -quiet ${mask} -spacing | awk '{ print \$1 * \$2 * \$3 }')
    ml=\$(awk -v n="\$n" -v v="\$voxel" 'BEGIN{ printf "%.1f", n * v / 1000 }')

    flags=""
    if [ -z "\$n" ] || [ "\$n" = 0 ]; then
        flags="empty"
    else
        awk -v x="\$ml" -v m="${max_ml}" 'BEGIN{ exit !(x + 0 > m + 0) }' && flags="mask_too_large"
        awk -v x="\$ml" -v m="${min_ml}" 'BEGIN{ exit !(x + 0 < m + 0) }' && flags="mask_too_small"
    fi

    echo "sid,session,run,brain_mask_ml,bet_method,qc_flags" > ${prefix}_t1brainmask_qc.csv
    echo "${subject_id},${session_id},${run_id},\$ml,${bet_method},\$flags" >> ${prefix}_t1brainmask_qc.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: \$(mrconvert -version 2>&1 | sed -n 's/^== mrconvert \\([0-9.]*\\).*/\\1/p')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo "sid,session,run,brain_mask_ml,bet_method,qc_flags" > ${prefix}_t1brainmask_qc.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: stub
    END_VERSIONS
    """
}
