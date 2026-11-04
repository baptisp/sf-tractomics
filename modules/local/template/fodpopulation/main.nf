// Study fODF template for fibre cross-section (MRtrix population_template on the fODFs of the
// template sessions), with what the next steps need in the same space:
//   fod_template.mif     population fODF template
//   template_mask.mif    intersection of the sessions' brain masks in template space
//   template_b0.nii.gz   mean of the sessions' b0, warped to the template (to place the IIT bundles)
//   fixels/              template fixels (fod2fixel; FD in fixels/fd.mif)
//   sessions.tsv         the sessions used, in input order
// Inputs are the fODFs from RECONST_FODTOMRTRIX (RAS, tournier07), the DWI brain masks and b0s,
// one per session, named by label.
process TEMPLATE_FODPOPULATION {
    tag "${labels.size()} sessions"
    label 'process_high'

    container "mrtrix3/mrtrix3:3.0.5"

    input:
    tuple val(labels), path(fods, stageAs: "in_fod/*"), path(masks, stageAs: "in_mask/*"), path(b0s, stageAs: "in_b0/*")

    output:
    tuple path("fod_template.mif"), path("template_mask.mif"), path("template_b0.nii.gz"), path("fixels"), path("sessions.tsv"), emit: template
    path "versions.yml", emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def voxel_size = task.ext.voxel_size ?: 1.25
    def peak_value = task.ext.fmls_peak_value ?: 0.06
    def fod_list   = fods.collect { f -> f.toString() }.join(" ")
    def mask_list  = masks.collect { f -> f.toString() }.join(" ")
    def b0_list    = b0s.collect { f -> f.toString() }.join(" ")
    """
    export MRTRIX_NTHREADS=${task.cpus}
    export MRTRIX_TMPFILE_DIR=\$PWD
    labels=(${labels.join(" ")})
    fods=(${fod_list}); masks=(${mask_list}); b0s=(${b0_list})
    mkdir -p fod mask
    printf "label\\n" > sessions.tsv
    for i in "\${!labels[@]}"; do
        # population_template pairs fODF and mask by file name
        mrconvert -quiet "\${fods[i]}" fod/\${labels[i]}.mif
        mrconvert -quiet "\${masks[i]}" -datatype bit mask/\${labels[i]}.mif
        printf "%s\\n" "\${labels[i]}" >> sessions.tsv
    done

    population_template fod -mask_dir mask fod_template.mif -template_mask template_mask.mif \\
        -warp_dir warps -voxel_size ${voxel_size} -nthreads ${task.cpus}

    # Mean b0 in template space: each session's b0 through its own warp
    for i in "\${!labels[@]}"; do
        mrtransform -quiet "\${b0s[i]}" -warp_full warps/\${labels[i]}.mif -from 1 \\
            -template fod_template.mif b0_\${labels[i]}.mif
    done
    mrmath -quiet b0_*.mif mean template_b0.nii.gz

    fod2fixel -quiet -mask template_mask.mif -fmls_peak_value ${peak_value} fod_template.mif fixels -afd fd.mif

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: \$(mrconvert -version 2>&1 | sed -n 's/^== mrconvert \\([0-9.]*\\).*/\\1/p')
    END_VERSIONS
    """

    stub:
    """
    touch fod_template.mif template_mask.mif template_b0.nii.gz
    mkdir fixels && touch fixels/index.mif fixels/directions.mif fixels/fd.mif
    printf "label\\n%s\\n" ${labels.join(" ")} > sessions.tsv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        mrtrix: stub
    END_VERSIONS
    """
}
