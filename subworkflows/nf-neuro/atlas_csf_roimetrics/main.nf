include { REGISTRATION_ANTS              as REGISTER_CSF_REF             } from '../../../modules/nf-neuro/registration/ants/main'
include { REGISTRATION_ANTSAPPLYTRANSFORMS as TRANSFORM_CSF_ATLAS         } from '../../../modules/nf-neuro/registration/antsapplytransforms/main.nf'
include { STATS_METRICSINROI             as STATS_CSF_ROIMETRICS          } from '../../../modules/nf-neuro/stats/metricsinroi/main'
include { STATS_ROIVOLUMES               as STATS_CSF_VOLUMES             } from '../../../modules/nf-neuro/stats/roivolumes/main'
include { STATS_METRICSINROI             as STATS_CSF_COMPARISON          } from '../../../modules/nf-neuro/stats/metricsinroi/main'
include { STATS_ROIVOLUMES               as STATS_CSF_COMPARISON_VOLUMES  } from '../../../modules/nf-neuro/stats/roivolumes/main'
include { UTILS_OPTIONS } from '../utils_options/main'

// ----- Atlas fetch helpers (mirrors atlas_iit pattern) -----

def download_file_csf(url, output_path) {
    HttpURLConnection connection = new URL(url).openConnection()
    connection.setInstanceFollowRedirects(true)
    connection.setRequestProperty("User-Agent", "nf-neuro/atlas_csf_roimetrics (subworkflow)")
    connection.setRequestProperty("Accept", "*/*")
    connection.setRequestProperty("Accept-Encoding", "identity")
    connection.setRequestProperty("Connection", "Keep-Alive")
    connection.connect()

    if (connection.responseCode != 200) {
        error "Failed to download file from ${url}: HTTP ${connection.responseCode}"
    }

    new File(output_path).withOutputStream { out ->
        out << connection.inputStream
    }
}

def fetch_iit_b0_for_csf(dest) {
    new File(dest).mkdirs()
    def outFile = new File("${dest}/IITmean_b0.nii.gz")
    if (!outFile.exists()) {
        download_file_csf(
            "https://www.nitrc.org/frs/download.php/11266/IITmean_b0.nii.gz",
            outFile.absolutePath
        )
    }
    return outFile
}

// Extract the FreeSurfer cvs_avg35_inMNI152 parcellation from the container.
// storeDir prevents re-extraction across pipeline runs.
process EXTRACT_FREESURFER_MNI_ATLAS {
    storeDir "${launchDir}/.atlas_cache/freesurfer"
    container "freesurfer/freesurfer:7.4.1"

    output:
    path "mni152_aparc_aseg.nii.gz", emit: aparc_aseg
    path "versions.yml",             emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    """
    mri_convert \$FREESURFER_HOME/subjects/cvs_avg35_inMNI152/mri/aparc+aseg.mgz mni152_aparc_aseg.nii.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        Freesurfer: \$(mri_convert --version 2>&1 | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+' | head -1 || echo "7.4.1")
    END_VERSIONS
    """

    stub:
    """
    touch mni152_aparc_aseg.nii.gz
    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        Freesurfer: 7.4.1
    END_VERSIONS
    """
}

workflow ATLAS_CSF_ROIMETRICS {
    take:
        ch_subject_reference  // channel : [required] meta, subject_ref_image (B0)
        ch_metrics            // channel : [required] meta, [metrics]
        options               // channel : [optional] map of options

    main:
        ch_versions = channel.empty()

        UTILS_OPTIONS("${moduleDir}/meta.yml", options, true)
        options = UTILS_OPTIONS.out.options.value

        // ----- Resolve atlas image -----
        if (options.atlas_csf_atlas) {
            ch_csf_atlas = channel.fromPath(options.atlas_csf_atlas, checkIfExists: true)
        }
        else {
            EXTRACT_FREESURFER_MNI_ATLAS()
            ch_versions = ch_versions.mix(EXTRACT_FREESURFER_MNI_ATLAS.out.versions)
            ch_csf_atlas = EXTRACT_FREESURFER_MNI_ATLAS.out.aparc_aseg
        }

        // ----- Resolve LUT -----
        def lut_path = options.atlas_csf_lut
            ?: "${projectDir}/assets/freesurfer_csf_lut.json"
        ch_csf_lut = channel.fromPath(lut_path, checkIfExists: true)

        // ----- Fetch IIT B0 as registration reference (isolated: own copy) -----
        def b0File = fetch_iit_b0_for_csf("${launchDir}/.atlas_cache/freesurfer")
        ch_template_ref = channel.fromPath(b0File.absolutePath, checkIfExists: true)

        // ----- Register atlas B0 reference → subject B0 -----
        ch_input_register = ch_subject_reference
            .combine(ch_template_ref)
            .map { meta, subject_ref, template_ref -> [meta, subject_ref, template_ref, []] }
        REGISTER_CSF_REF(ch_input_register)
        ch_versions = ch_versions.mix(REGISTER_CSF_REF.out.versions)

        // ----- Warp CSF atlas to subject DWI space -----
        ch_transform_csf = ch_subject_reference
            .join(REGISTER_CSF_REF.out.forward_image_transform)
            .combine(ch_csf_atlas)
            .map { meta, subject_ref, transform, atlas ->
                [meta, atlas, subject_ref, transform]
            }
        TRANSFORM_CSF_ATLAS(ch_transform_csf)
        ch_versions = ch_versions.mix(TRANSFORM_CSF_ATLAS.out.versions)

        // ----- CSF diffusion metrics per region -----
        ch_csf_stats_json = channel.empty()
        ch_csf_stats_mean = channel.empty()
        ch_csf_stats_std  = channel.empty()

        if (options.run_roi_metrics != false) {
            ch_csf_metrics_input = ch_metrics
                .join(TRANSFORM_CSF_ATLAS.out.warped_image)
                .combine(ch_csf_lut)
                .map { meta, metrics, atlas, lut -> [meta, metrics, atlas, lut] }

            STATS_CSF_ROIMETRICS(ch_csf_metrics_input)
            ch_versions = ch_versions.mix(STATS_CSF_ROIMETRICS.out.versions)

            ch_csf_stats_json = STATS_CSF_ROIMETRICS.out.stats_json
            ch_csf_stats_mean = STATS_CSF_ROIMETRICS.out.stats_mean
            ch_csf_stats_std  = STATS_CSF_ROIMETRICS.out.stats_std
        }

        // ----- CSF region volumes -----
        ch_csf_volumes = channel.empty()

        if (options.run_roi_volumes) {
            ch_csf_volumes_input = TRANSFORM_CSF_ATLAS.out.warped_image
                .combine(ch_csf_lut)
                .map { meta, atlas, lut -> [meta, atlas, lut] }
            STATS_CSF_VOLUMES(ch_csf_volumes_input)
            ch_versions = ch_versions.mix(STATS_CSF_VOLUMES.out.versions)
            ch_csf_volumes = STATS_CSF_VOLUMES.out.volumes
        }

        // ----- Comparison extraction (GM subcortical + WM + ventricles → comparison/ subdir) -----
        ch_comparison_stats_json = channel.empty()
        ch_comparison_stats_mean = channel.empty()
        ch_comparison_stats_std  = channel.empty()
        ch_comparison_volumes    = channel.empty()

        if (options.run_csf_comparison_roimetrics || options.run_csf_comparison_volumes) {
            def comparison_lut_path = options.atlas_csf_comparison_lut
                ?: "${projectDir}/assets/freesurfer_comparison_lut.json"
            ch_comparison_lut = channel.fromPath(comparison_lut_path, checkIfExists: true)

            if (options.run_csf_comparison_roimetrics) {
                ch_comparison_metrics_input = ch_metrics
                    .join(TRANSFORM_CSF_ATLAS.out.warped_image)
                    .combine(ch_comparison_lut)
                    .map { meta, metrics, atlas, lut -> [meta, metrics, atlas, lut] }
                STATS_CSF_COMPARISON(ch_comparison_metrics_input)
                ch_versions = ch_versions.mix(STATS_CSF_COMPARISON.out.versions)
                ch_comparison_stats_json = STATS_CSF_COMPARISON.out.stats_json
                ch_comparison_stats_mean = STATS_CSF_COMPARISON.out.stats_mean
                ch_comparison_stats_std  = STATS_CSF_COMPARISON.out.stats_std
            }

            if (options.run_csf_comparison_volumes) {
                ch_comparison_volumes_input = TRANSFORM_CSF_ATLAS.out.warped_image
                    .combine(ch_comparison_lut)
                    .map { meta, atlas, lut -> [meta, atlas, lut] }
                STATS_CSF_COMPARISON_VOLUMES(ch_comparison_volumes_input)
                ch_versions = ch_versions.mix(STATS_CSF_COMPARISON_VOLUMES.out.versions)
                ch_comparison_volumes = STATS_CSF_COMPARISON_VOLUMES.out.volumes
            }
        }

    emit:
        stats_json                  = ch_csf_stats_json
        stats_tab_mean              = ch_csf_stats_mean
        stats_tab_std               = ch_csf_stats_std
        volumes                     = ch_csf_volumes
        comparison_stats_json       = ch_comparison_stats_json
        comparison_stats_tab_mean   = ch_comparison_stats_mean
        comparison_stats_tab_std    = ch_comparison_stats_std
        comparison_volumes          = ch_comparison_volumes
        versions                    = ch_versions
}
