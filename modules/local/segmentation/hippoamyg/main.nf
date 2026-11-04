// Hippocampal subfields and amygdala nuclei of a recon-all run (FreeSurfer 7
// segment_subregions hippo-amygdala, Iglesias et al. 2015 and Saygin et al. 2017; the Python
// version, which needs no MATLAB runtime). About 5 min per T1 with 4 threads (measured on OASIS-3).
//
// The recon-all directory is read, not written: outputs go to <prefix>__hippoamyg/ (--out-dir),
// so the published recon-all directory is unchanged.
//
// Output, per distinct T1: <prefix>__hippoamyg/ with {lh,rh}.hippoSfVolumes.txt,
// {lh,rh}.amygNucVolumes.txt (name, volume in mm3) and the label maps
// {lh,rh}.hippoAmygLabels*.mgz (0.333 mm, and *.FSvoxelSpace.mgz on recon-all's grid).
process SEGMENTATION_HIPPOAMYG {
    tag "$meta.id"
    label 'process_medium'

    container "freesurfer/freesurfer:7.4.1"

    input:
    tuple val(meta), path(recon_all), path(fs_license)

    output:
    tuple val(meta), path("*__hippoamyg"), emit: subfields
    path "versions.yml",                   emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    export FS_LICENSE=\$PWD/${fs_license}
    # segment_subregions looks the subject up in a subjects directory
    mkdir subjects
    ln -s \$(readlink -f ${recon_all}) subjects/subject
    segment_subregions hippo-amygdala --cross subject --sd \$PWD/subjects \\
        --out-dir \$PWD/${prefix}__hippoamyg --temp-dir \$PWD/tmp --threads ${task.cpus}
    for f in lh.hippoSfVolumes.txt rh.hippoSfVolumes.txt lh.amygNucVolumes.txt rh.amygNucVolumes.txt; do
        [ -s ${prefix}__hippoamyg/\$f ] || { echo "segment_subregions wrote no \$f" >&2; exit 1; }
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        freesurfer: \$(mri_convert -version | grep "freesurfer" | sed -E 's/.* ([0-9.]+).*/\\1/')
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    mkdir ${prefix}__hippoamyg
    for h in lh rh; do
        printf "Whole_hippocampus 3000.0\\n" > ${prefix}__hippoamyg/\$h.hippoSfVolumes.txt
        printf "Whole_amygdala 1500.0\\n" > ${prefix}__hippoamyg/\$h.amygNucVolumes.txt
    done

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        freesurfer: stub
    END_VERSIONS
    """
}
