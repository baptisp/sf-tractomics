// Fibre cross-section (FC, Raffelt et al. 2017) of one session on the template fixels, and its
// mean per IIT bundle. FC is the change in a fibre bundle's cross-sectional area needed to warp the
// subject onto the template, read from the subject-to-template warp perpendicular to each template
// fixel: FC > 1 (log FC > 0) where the subject's bundle is wider than the template's, < 1 where
// thinner. Steps follow the MRtrix fixel-based analysis guide: the fODF is warped without
// reorientation, segmented into fixels, the fixels are reoriented with the warp and matched to the
// template fixels (FD); FC comes from warp2metric; FDC = FD x FC.
//
// Output CSV, one row per bundle:
//   sid,session,run,roi,log_fc_mean,log_fc_median,fd_mean,fdc_mean,n_fixels,covered_fraction,
//   unmatched_fraction,registration_corr,min_jacobian,orientation_agreement,qc_flags,in_template,
//   template_hash
// roi: the IIT bundle, named as in the WM tractometry table (AC, AF_L, ...).
// Statistics are over the bundle's template fixels inside the subject's warped brain mask
// (covered_fraction = their share of the bundle). unmatched_fraction: share of those with no
// subject fixel matched (FD = 0); FC is defined there too, FD and FDC are 0.
// registration_corr: correlation of the warped fODF's l = 0 term with the template's, in the
// template mask. qc_flags: folding (min_jacobian <= 0), uncovered (covered_fraction < 0.9),
// empty (no fixel). in_template = 1 when the session built the template: keep it out of test sets.
// Also published: <prefix>__logfc.mif (fixel data on the template fixels).
process STATS_FIBRECROSSSECTION {
    tag "$meta.id"
    label 'process_single'

    container "mrtrix3/mrtrix3:3.0.5"

    input:
    tuple val(meta), path(fod), path(mask), path(warp), path(registration_qc), val(in_template), path(template)

    output:
    tuple val(meta), path("*_fc_stats.csv"), emit: stats
    tuple val(meta), path("*__logfc.mif"),   emit: logfc
    path "versions.yml",                     emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix     = task.ext.prefix ?: "${meta.id}"
    def subject_id = meta.id ?: ""
    def session_id = meta.session ?: ""
    // Same run convention as the other stats files: bare run number, absent run = 1
    def run_id     = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    """
    export MRTRIX_NTHREADS=${task.cpus}
    export MRTRIX_TMPFILE_DIR=\$PWD
    T=${template}
    stat() { mrstats -quiet "\$1" -mask "\$2" -output "\$3" | tr -d ' '; }

    mrtransform -quiet ${fod} -warp ${warp} -reorient_fod no fod_in_template.mif
    mrtransform -quiet ${mask} -warp ${warp} -interp nearest -datatype bit mask_in_template.mif
    fod2fixel -quiet -mask \$T/template_mask.mif fod_in_template.mif fixels_not_reoriented -afd fd.mif
    fixelreorient -quiet fixels_not_reoriented ${warp} fixels_reoriented
    fixelcorrespondence -quiet fixels_reoriented/fd.mif \$T/fixels fd fd.mif
    warp2metric -quiet ${warp} -fc \$T/fixels fc fc.mif
    mrcalc -quiet fc/fc.mif -log ${prefix}__logfc.mif
    mrcalc -quiet fd/fd.mif fc/fc.mif -mult fdc.mif
    mrcalc -quiet fd/fd.mif 0 -eq unmatched.mif
    voxel2fixel -quiet mask_in_template.mif \$T/fixels covered covered.mif

    # Registration QC
    warp2metric -quiet ${warp} -jdet jdet.mif
    min_jacobian=\$(stat jdet.mif \$T/template_mask.mif min)
    mrconvert -quiet -coord 3 0 -axes 0,1,2 fod_in_template.mif l0_subject.mif
    mrconvert -quiet -coord 3 0 -axes 0,1,2 \$T/fod_template.mif l0_template.mif
    mrcalc -quiet \$T/template_mask.mif mask_in_template.mif -mult overlap.mif
    mrcalc -quiet l0_subject.mif l0_template.mif -mult l0_product.mif
    corr=\$(awk -v xy=\$(stat l0_product.mif overlap.mif mean) -v x=\$(stat l0_subject.mif overlap.mif mean) \\
               -v y=\$(stat l0_template.mif overlap.mif mean) -v sx=\$(stat l0_subject.mif overlap.mif std) \\
               -v sy=\$(stat l0_template.mif overlap.mif std) 'BEGIN{ if (sx * sy > 0) printf "%.4f", (xy - x * y) / (sx * sy) }')
    agreement=\$(awk '\$1 == "orientation_agreement" { print \$2 }' ${registration_qc})
    template_hash=\$(sha256sum \$T/manifest.json | cut -c 1-12)

    echo "sid,session,run,roi,log_fc_mean,log_fc_median,fd_mean,fdc_mean,n_fixels,covered_fraction,unmatched_fraction,registration_corr,min_jacobian,orientation_agreement,qc_flags,in_template,template_hash" > ${prefix}_fc_stats.csv
    for b in \$T/fixels/bundle-*.mif; do
        name=\$(basename "\$b" .mif); name=\${name#bundle-}
        mrcalc -quiet -force "\$b" covered/covered.mif -mult in_bundle.mif
        n_bundle=\$(mrstats -quiet "\$b" -ignorezero -output count | tr -d ' ')
        n=\$(mrstats -quiet in_bundle.mif -ignorezero -output count | tr -d ' ')
        flags=""
        awk -v j="\$min_jacobian" 'BEGIN{ exit !(j + 0 <= 0) }' && flags="folding"
        if [ "\${n:-0}" -eq 0 ]; then
            echo "${subject_id},${session_id},${run_id},\$name,,,,,0,0,,\$corr,\$min_jacobian,\$agreement,\${flags:+\$flags;}empty,${in_template},\$template_hash" >> ${prefix}_fc_stats.csv
            continue
        fi
        covered=\$(awk -v n="\$n" -v t="\$n_bundle" 'BEGIN{ printf "%.4f", n / t }')
        awk -v c="\$covered" 'BEGIN{ exit !(c + 0 < 0.9) }' && flags="\${flags:+\$flags;}uncovered"
        echo "${subject_id},${session_id},${run_id},\$name,\$(stat ${prefix}__logfc.mif in_bundle.mif mean),\$(stat ${prefix}__logfc.mif in_bundle.mif median),\$(stat fd/fd.mif in_bundle.mif mean),\$(stat fdc.mif in_bundle.mif mean),\$n,\$covered,\$(stat unmatched.mif in_bundle.mif mean),\$corr,\$min_jacobian,\$agreement,\$flags,${in_template},\$template_hash" >> ${prefix}_fc_stats.csv
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: \$(mrconvert -version 2>&1 | sed -n 's/^== mrconvert \\([0-9.]*\\).*/\\1/p')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo "sid,session,run,roi,log_fc_mean,log_fc_median,fd_mean,fdc_mean,n_fixels,covered_fraction,unmatched_fraction,registration_corr,min_jacobian,orientation_agreement,qc_flags,in_template,template_hash" > ${prefix}_fc_stats.csv
    touch ${prefix}__logfc.mif

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: stub
    END_VERSIONS
    """
}
