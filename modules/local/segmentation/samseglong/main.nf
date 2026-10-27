// Longitudinal segmentation of all T1 sessions of one subject with FreeSurfer SAMSEG
// (Cerri et al. 2023, NeuroImage). Sessions are rigidly aligned with mri_robust_template, then
// segmented jointly against a subject-specific latent atlas, which removes most of the
// session-to-session noise that independent (cross-sectional) segmentations add on top of the
// real change. A subject with a single session falls back to cross-sectional run_samseg.
//
// The atlas here is only a prior: every label comes from fitting the subject's own intensities,
// so the volumes measure the subject's anatomy, not a warped template.
//
// Every session is first resampled to 1 mm isotropic (cubic): mri_robust_template refuses
// sessions with different voxel sizes, which happens whenever the scanner or protocol changes
// during follow-up, and identical grids keep the processing the same for all sessions.
//
// Outputs, per session (prefix = id_session[_run]):
//   <prefix>__samseg_seg.nii.gz  labelmap in that session's T1 space, resampled to 1 mm
//   <prefix>__samseg_icv.csv     total intracranial volume (SAMSEG sbTIV), mm3
process SEGMENTATION_SAMSEGLONG {
    tag "$meta.id"
    label 'process_high'

    container "freesurfer/freesurfer:7.4.1"

    input:
    tuple val(meta), val(session_metas), path(t1s, stageAs: "tp*/t1.nii.gz"), path(fs_license)

    output:
    tuple val(meta), val(session_metas), path("*__samseg_seg.nii.gz"), path("*__samseg_icv.csv"), emit: seg
    path "versions.yml",                                                                            emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def t1_list   = t1s instanceof List ? t1s : [t1s]
    def prefixes  = session_metas.collect { m -> [m.id, m.session, m.run].findAll { x -> x }.join("_") }
    def threads   = task.cpus
    def resampled = (1..t1_list.size()).collect { i -> "tp${i}_1mm.nii.gz" }
    def timepoints = resampled.collect { t1 -> "--timepoint ${t1}" }.join(" ")
    def ltas      = (1..t1_list.size()).collect { i -> "tp${i}_to_base.lta" }.join(" ")
    """
    export FS_LICENSE=\$(realpath $fs_license)
    export OMP_NUM_THREADS=${threads}

    t1s=(${t1_list.join(' ')})
    resampled=(${resampled.join(' ')})
    for i in "\${!t1s[@]}"; do
        mri_convert \${t1s[\$i]} \${resampled[\$i]} -vs 1 1 1 -rt cubic
    done

    if [ ${t1_list.size()} -gt 1 ]; then
        # Rigid, inverse-consistent alignment of the sessions to their median. SAMSEG reads the
        # transforms, so no session is resampled a second time.
        mri_robust_template --mov ${resampled.join(' ')} --template base.mgz \\
            --satit --average 1 --lta ${ltas}

        run_samseg_long ${timepoints} --tp-to-base-transform ${ltas} \\
            --output samseg --threads ${threads}
    else
        mkdir -p samseg
        run_samseg --input ${resampled[0]} --output samseg/tp001 --threads ${threads}
    fi

    prefixes=(${prefixes.join(' ')})
    for i in "\${!prefixes[@]}"; do
        tp=\$(printf "samseg/tp%03d" \$((i + 1)))
        mri_convert \$tp/seg.mgz \${prefixes[\$i]}__samseg_seg.nii.gz
        # sbtiv.stats: "# Measure Intra-Cranial, <volume>, mm^3"
        icv=\$(grep -i "Intra-Cranial" \$tp/sbtiv.stats | cut -d, -f2 | tr -d ' ')
        printf "subject,total intracranial\\n%s,%s\\n" "\${prefixes[\$i]}" "\$icv" > \${prefixes[\$i]}__samseg_icv.csv
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        Freesurfer: \$(mri_convert -version | grep "freesurfer" | sed -E 's/.* ([0-9.]+).*/\\1/')
    END_VERSIONS
    """

    stub:
    def prefixes = session_metas.collect { m -> [m.id, m.session, m.run].findAll { x -> x }.join("_") }
    """
    for p in ${prefixes.join(' ')}; do
        touch \${p}__samseg_seg.nii.gz
        printf "subject,total intracranial\\n%s,0\\n" "\$p" > \${p}__samseg_icv.csv
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        Freesurfer: 7.4.1
    END_VERSIONS
    """
}
