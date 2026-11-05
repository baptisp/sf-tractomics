// How well an atlas registration placed the atlas on one DWI run. Every atlas region in the
// subject's DWI space (IIT WM bundles, IIT GM regions, FreeSurfer CSF atlas) is placed by one
// ANTs registration of the IIT mean b0 onto the run's b0; this compares the warped atlas b0 with
// that b0. Nothing fails here: a flagged run keeps its rows, to be left out downstream.
//
// Output CSV, one row:
//   sid,session,run,registration,atlas_b0_corr,brain_dice,qc_flags
// registration: which registration (ext.registration: iit for the WM bundles and GM regions, csf
// for the CSF atlas). atlas_b0_corr: correlation of the warped atlas b0 with the run's b0 inside
// the run's brain mask (0.77-0.79 on 4 OASIS-3 sessions; the same warps shifted by 2 mm gave about
// 0.70, by 4 mm about 0.54). brain_dice: Dice of the atlas brain (warped b0 above 10 % of its mean
// over non-zero voxels) with the brain mask (0.94 measured, 0.89 at an 8 mm shift): it catches a
// gross failure, the correlation a misplacement of a few millimetres.
// qc_flags: misaligned (atlas_b0_corr < ext.min_atlas_corr, 0.6), brain_mismatch
// (brain_dice < ext.min_brain_dice, 0.85), empty (no voxel to compare).
process QC_ATLASREGISTRATION {
    tag "$meta.id"
    label 'process_single'

    container "mrtrix3/mrtrix3:3.0.5"

    input:
    tuple val(meta), path(b0), path(atlas_b0), path(mask)

    output:
    tuple val(meta), path("*_atlasreg_qc.csv"), emit: qc
    path "versions.yml",                        emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix       = task.ext.prefix ?: "${meta.id}"
    def registration = task.ext.registration ?: "iit"
    def min_corr     = task.ext.min_atlas_corr != null ? task.ext.min_atlas_corr : 0.6
    def min_dice     = task.ext.min_brain_dice != null ? task.ext.min_brain_dice : 0.85
    def subject_id   = meta.id ?: ""
    def session_id   = meta.session ?: ""
    // Same run convention as the other stats files: bare run number, absent run = 1
    def run_id       = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    """
    export MRTRIX_NTHREADS=${task.cpus}
    export MRTRIX_TMPFILE_DIR=\$PWD
    stat() { mrstats -quiet "\$1" -mask "\$2" -output "\$3" | tr -d ' '; }
    count() { mrstats -quiet "\$1" -ignorezero -output count | tr -d ' '; }

    mrcalc -quiet ${mask} 0 -gt -datatype bit brain.mif
    mrcalc -quiet ${b0} ${atlas_b0} -mult product.mif
    corr=\$(awk -v xy=\$(stat product.mif brain.mif mean) -v x=\$(stat ${b0} brain.mif mean) \\
               -v y=\$(stat ${atlas_b0} brain.mif mean) -v sx=\$(stat ${b0} brain.mif std) \\
               -v sy=\$(stat ${atlas_b0} brain.mif std) 'BEGIN{ if (sx * sy > 0) printf "%.4f", (xy - x * y) / (sx * sy) }')

    atlas_level=\$(mrstats -quiet ${atlas_b0} -ignorezero -output mean | tr -d ' ')
    mrcalc -quiet ${atlas_b0} \$(awk -v m="\$atlas_level" 'BEGIN{ print 0.1 * m }') -gt -datatype bit atlas_brain.mif
    mrcalc -quiet atlas_brain.mif brain.mif -mult -datatype bit overlap.mif
    dice=\$(awk -v o=\$(count overlap.mif) -v a=\$(count atlas_brain.mif) -v m=\$(count brain.mif) \\
               'BEGIN{ if (a + m > 0) printf "%.4f", 2 * o / (a + m) }')

    flags=""
    if [ -z "\$corr" ] || [ -z "\$dice" ]; then
        flags="empty"
    else
        awk -v c="\$corr" -v m="${min_corr}" 'BEGIN{ exit !(c + 0 < m + 0) }' && flags="misaligned"
        awk -v d="\$dice" -v m="${min_dice}" 'BEGIN{ exit !(d + 0 < m + 0) }' && flags="\${flags:+\$flags;}brain_mismatch"
    fi

    echo "sid,session,run,registration,atlas_b0_corr,brain_dice,qc_flags" > ${prefix}_${registration}_atlasreg_qc.csv
    echo "${subject_id},${session_id},${run_id},${registration},\$corr,\$dice,\$flags" >> ${prefix}_${registration}_atlasreg_qc.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: \$(mrconvert -version 2>&1 | sed -n 's/^== mrconvert \\([0-9.]*\\).*/\\1/p')
    END_VERSIONS
    """

    stub:
    def prefix       = task.ext.prefix ?: "${meta.id}"
    def registration = task.ext.registration ?: "iit"
    """
    echo "sid,session,run,registration,atlas_b0_corr,brain_dice,qc_flags" > ${prefix}_${registration}_atlasreg_qc.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: stub
    END_VERSIONS
    """
}
