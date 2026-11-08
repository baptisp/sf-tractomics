// recon-all again on a T1 whose first recon-all failed or gave wrong volumes, with extra options
// (params.reconall_rerun). Same command and outputs as the nf-neuro SEGMENTATION_FSRECONALL, plus
// the options. It is a process of its own so that the T1s not listed keep the cached tasks of
// SEGMENTATION_FSRECONALL: Nextflow hashes a task's script source, so adding the options to that
// module would run recon-all again on every T1. The options are an input, so a listed T1 runs
// again whenever they change.
process SEGMENTATION_RECONALLRERUN {
    tag "$meta.id"
    label 'process_single'

    container "freesurfer/freesurfer:7.4.1"

    input:
        tuple val(meta), path(anat), path(fs_license), val(args)

    output:
        tuple val(meta), path("*__recon_all")   , emit: recon_all_out_folder
        path "versions.yml"                     , emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    export OMP_NUM_THREADS=${task.ext.single_thread ? 1 : task.cpus}

    cp "$fs_license" .license
    export FS_LICENSE=\$(pwd)/.license
    export SUBJECTS_DIR=\$(pwd)
    recon-all -i $anat -s ${prefix}__recon_all -all ${args}
    rm .license

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        freesurfer: \$(mri_convert -version | grep "freesurfer" | sed -E 's/.* ([0-9.]+).*/\\1/')
        recon_all_options: "${args}"
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    mkdir ${prefix}__recon_all
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        freesurfer: 7.4.1
        recon_all_options: "${args}"
    END_VERSIONS
    """
}
