/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { QC_MULTIQC as MULTIQC  } from '../modules/nf-neuro/qc/multiqc/main'
include { QC_MULTIQC as MULTIQC_GLOBAL  } from '../modules/nf-neuro/qc/multiqc/main'
include { paramsSummaryMap       } from 'plugin/nf-schema'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_sf-tractomics_pipeline'
include { TRACTOFLOW             } from '../subworkflows/nf-neuro/tractoflow'
include { TRACTOGRAM_MATH as ENSEMBLE_TRACKING } from '../modules/nf-neuro/tractogram/math/main'
include { QC_TRACTOGRAM as QC_ENSEMBLE } from '../modules/nf-neuro/qc/tractogram/main'
include { ATLAS_IIT              } from '../subworkflows/nf-neuro/atlas_iit/main'
include { RECONST_SHSIGNAL       } from '../modules/nf-neuro/reconst/shsignal'
include { RECONST_FW_NODDI       } from '../subworkflows/nf-neuro/reconst_fw_noddi/main'
include { BUNDLE_SEG             } from '../subworkflows/nf-neuro/bundle_seg/main'
include { ATLAS_ROIMETRICS       } from '../subworkflows/nf-neuro/atlas_roimetrics/main'
include { ATLAS_CSF_ROIMETRICS   } from '../subworkflows/nf-neuro/atlas_csf_roimetrics/main'
include { TRACTOMETRY            } from '../subworkflows/nf-neuro/tractometry/main'
include { REGISTRATION_ANTSAPPLYTRANSFORMS as REGISTRATION_METRICS_TO_ORIG } from '../modules/nf-neuro/registration/antsapplytransforms/main'
include { REGISTRATION_TRACTOGRAM as REGISTRATION_TRACTOGRAM_TO_ORIG } from '../modules/nf-neuro/registration/tractogram/main'
include { OUTPUT_TEMPLATE_SPACE  } from '../subworkflows/nf-neuro/output_template_space/main'
include { HARMONIZATION          } from '../subworkflows/nf-neuro/harmonization/main'
include { mergeCovariatesIntoMeta } from '../subworkflows/local/utils_nfcore_sf-tractomics_pipeline/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow SF_TRACTOMICS {
    take:
    ch_t1
    ch_wmparc
    ch_aparc_aseg
    ch_dwi_bval_bvec
    ch_b0
    ch_rev_dwi_bval_bvec
    ch_rev_b0
    ch_lesion
    ch_covariates
    main:

    ch_versions = channel.empty()
    ch_sub_multiqc_files = channel.empty()
    ch_global_multiqc_files = channel.empty()
    ch_topup_config = channel.empty()
    ch_bet_template = channel.empty()
    ch_bet_probability = channel.empty()
    ch_synthstrip_weights = channel.empty()

    if (workflow.profile.contains('reproducible') && workflow.profile.contains('gpu')) {
        error "\033[0;31mERROR: Profiles 'reproducible' and 'gpu' are not compatible and cannot be used together. Please remove gpu if you want reproducible results.\033[0m"
    }

    /* Load topup config if provided */
    if ( params.config_topup ) {
        if ( file(params.config_topup).exists()) {
            ch_topup_config = channel.fromPath(params.config_topup, checkIfExists: true)
        }
        else {
            ch_topup_config = channel.value( params.config_topup )
        }
    }

    /* Load bet template */
    template_directory = file(params.template_t1 ?: "$projectDir/assets/templates/mni_152_sym_09c/t1")
    if ( template_directory.exists() && template_directory.isDirectory() ){
        ch_bet_template = ch_t1.map{ meta, _t1 ->  meta}
            .combine(channel.fromPath(template_directory / "t1_template.nii.gz"))
        ch_bet_probability = ch_t1.map{ meta, _t1 ->  meta }
            .combine(channel.fromPath(template_directory / "t1_brain_probability_map.nii.gz"))
    }
    else {
        error "A T1w template is required for brain extraction. Provide its directory with params.template_t1."
    }

    if ( params.synthstrip_weights ) {
        ch_synthstrip_weights = channel.fromPath(params.synthstrip_weights, checkIfExists: true)
    }

    TRACTOFLOW(
        ch_dwi_bval_bvec,
        ch_t1,
        ch_b0
            .filter{ it -> it[1] },
        ch_rev_dwi_bval_bvec
            .filter{ it -> it[1] },
        ch_rev_b0
            .filter{ it -> it[1] },
        ch_wmparc
            .filter{ it -> it[1] },
        ch_aparc_aseg
            .filter{ it -> it[1] },
        ch_topup_config,
        ch_bet_template,
        ch_bet_probability,
        ch_synthstrip_weights,
        ch_lesion
            .filter{ it -> it[1] },
        [
            "preproc_dwi_run_denoising": params.run_dwi_denoising,
            "preproc_dwi_run_degibbs": params.run_gibbs_correction,
            "eddy_nan_threshold": params.eddy_nan_threshold,
            "topup_eddy_run_topup": params.run_topup,
            "topup_eddy_run_eddy": params.run_eddy,
            "preproc_dwi_run_synthstrip": params.run_dwi_synthstrip,
            "preproc_dwi_keep_dwi_with_skull": params.keep_dwi_with_skull,
            "preproc_dwi_run_N4": params.run_dwi_N4,
            "preproc_dwi_run_normalize": params.run_dwi_normalize,
            "preproc_dwi_run_resampling": params.run_dwi_resampling,
            "preproc_t1_run_denoising": params.run_t1_denoising,
            "preproc_t1_run_N4": params.run_t1_N4,
            "preproc_t1_run_resample": params.run_t1_resampling,
            "preproc_t1_run_synthstrip": params.run_t1_synthstrip,
            "preproc_t1_run_ants_bet": params.run_t1_ants_bet,
            "preproc_t1_run_crop": params.run_t1_crop,
            "frf_average_from_data": params.mean_frf,
            "run_qball": params.run_qball,
            "use_qball_for_tracking": params.use_qball_for_tracking,
            "run_pft_tracking": params.run_pft_tracking,
            "run_local_tracking": params.run_local_tracking
        ]
    )
    ch_versions = ch_versions.mix(TRACTOFLOW.out.versions)
    ch_sub_multiqc_files = ch_sub_multiqc_files.mix(TRACTOFLOW.out.mqc)
    // ch_global_multiqc_files = ch_global_multiqc_files.mix(TRACTOFLOW.out.global_mqc)

    //
    // Ensemble tracking
    //
    ch_input_tracking_qc = channel.empty()
    if ( params.run_local_tracking && params.run_pft_tracking ) {
        ch_tractogram_math_input = TRACTOFLOW.out.pft_tractogram
            .join(TRACTOFLOW.out.local_tractogram)
            .map {
                meta, pft_tractogram, local_tractogram ->
                    [meta, [pft_tractogram, local_tractogram], []]}
        ENSEMBLE_TRACKING(ch_tractogram_math_input)
        ch_input_tracking_qc = ENSEMBLE_TRACKING.out.trk
    }
    else if ( params.run_local_tracking || params.run_pft_tracking ) {
        ch_input_tracking_qc = TRACTOFLOW.out.pft_tractogram
            .mix(TRACTOFLOW.out.local_tractogram)
            .groupTuple()
    }

    QC_ENSEMBLE(ch_input_tracking_qc
        .join(TRACTOFLOW.out.wm_mask)
        .join(TRACTOFLOW.out.gm_mask))
    ch_sub_multiqc_files = ch_sub_multiqc_files.mix(QC_ENSEMBLE.out.mqc)
    ch_global_multiqc_files = ch_global_multiqc_files.mix(
        QC_ENSEMBLE.out.dice.map { _meta, dice_file -> dice_file } )
    ch_global_multiqc_files = ch_global_multiqc_files.mix(
        QC_ENSEMBLE.out.sc.map { _meta, sc_file -> sc_file } )

    //
    // Run RECONST/SH_METRICS
    //
    if ( params.sh_fitting ) {
        RECONST_SHSIGNAL(
            TRACTOFLOW.out.dwi
                .map{ it -> it + [[]] }
        )
    }

    //
    // Run BundleSeg
    //
    ch_bundle_seg = channel.empty()
    if ( params.run_bundle_seg ) {
        BUNDLE_SEG(
            TRACTOFLOW.out.dti_fa,
            ch_input_tracking_qc.map { meta, trk -> [meta, (trk instanceof List ? trk : [trk])] },
            channel.empty(),
            [
                "run_easyreg": false, // BundleSeg does not support easyreg, so we set it to false to avoid confusion
                "run_synthmorph": params.run_synthmorph,
                "atlas_directory": params.atlas_directory
            ]
        )

        ch_versions = ch_versions.mix(BUNDLE_SEG.out.versions)
        ch_sub_multiqc_files = ch_sub_multiqc_files.mix(BUNDLE_SEG.out.mqc)
        ch_sub_multiqc_files = ch_sub_multiqc_files.mix(BUNDLE_SEG.out.bundles_mqc)
        ch_bundle_seg = BUNDLE_SEG.out.bundles
    }

    // Prepare volume ROI metric extraction
    // Start by collecting DTI metrics
    ch_input_metrics = TRACTOFLOW.out.dti_fa
        .join(TRACTOFLOW.out.dti_md)
        .join(TRACTOFLOW.out.dti_rd)
        .join(TRACTOFLOW.out.dti_ad)
        .join(TRACTOFLOW.out.afd_total)
        .join(TRACTOFLOW.out.afd_sum)
        .join(TRACTOFLOW.out.afd_max)

    //
    // Run RECONST/NODDI & RECONST/FREEWATER
    //
    if ( params.run_noddi || params.run_freewater ) {
        // TODO: support subject-specific diffusivity options
        RECONST_FW_NODDI(
            TRACTOFLOW.out.dwi,
            TRACTOFLOW.out.b0_mask,
            TRACTOFLOW.out.dti_fa
                .join(TRACTOFLOW.out.dti_ad)
                .join(TRACTOFLOW.out.dti_rd)
                .join(TRACTOFLOW.out.dti_md),
            [
                para_diff: params.para_diff ? channel.value(params.para_diff) : channel.empty(),
                iso_diff: params.iso_diff ? channel.value(params.iso_diff) : channel.empty(),
                perp_diff_min: params.perp_diff_min ? channel.value(params.perp_diff_min) : channel.empty(),
                perp_diff_max: params.perp_diff_max ? channel.value(params.perp_diff_max) : channel.empty()
            ],
            [
                run_noddi: params.run_noddi,
                run_freewater: params.run_freewater,
                silence_single_shell_warnings: params.noddi_silence_single_shell_warnings
            ]
        )
        ch_versions = ch_versions.mix(RECONST_FW_NODDI.out.versions)

        // Add FW/NODDI metrics to the volume
        // ROI extraction.
        ch_input_metrics = ch_input_metrics
            .join(RECONST_FW_NODDI.out.fw_fwf, remainder: true)
            .join(RECONST_FW_NODDI.out.fw_dti_fa, remainder: true)
            .join(RECONST_FW_NODDI.out.fw_dti_md, remainder: true)
            .join(RECONST_FW_NODDI.out.fw_dti_rd, remainder: true)
            .join(RECONST_FW_NODDI.out.fw_dti_ad, remainder: true)
            .join(RECONST_FW_NODDI.out.noddi_isovf, remainder: true)
            .join(RECONST_FW_NODDI.out.noddi_icvf, remainder: true)
            .join(RECONST_FW_NODDI.out.noddi_ecvf, remainder: true)
            .join(RECONST_FW_NODDI.out.noddi_odi, remainder: true)
    }

    ch_input_metrics = ch_input_metrics.map {tuple ->
        def meta = tuple[0]
        def metrics = tuple[1..-1].findAll { metric -> metric != null }
        return [meta, metrics]
    }

    // Derive per-type computation flags: master switches enable all types;
    // per-type switches enable individual types when the master is false.
    def do_wm_metrics  = params.run_roi_metrics || params.run_wm_metrics
    def do_gm_metrics  = params.run_roi_metrics || params.run_gm_metrics
    def do_csf_metrics = params.run_roi_metrics || params.run_csf_metrics
    def do_wm_volumes  = params.run_roi_volumes || params.run_wm_volumes
    def do_gm_volumes  = params.run_roi_volumes || params.run_gm_volumes
    def do_csf_volumes = params.run_roi_volumes || params.run_csf_volumes

    if ( (do_wm_metrics || do_wm_volumes || do_gm_metrics || do_gm_volumes) && !params.run_atlas_roimetrics ) {
        error "IIT atlas metrics/volumes (WM or GM) require run_atlas_roimetrics = true."
    }

    if ( params.run_merge_all_stats &&
         !do_wm_metrics && !do_gm_metrics && !do_csf_metrics &&
         !do_wm_volumes && !do_gm_volumes && !do_csf_volumes ) {
        log.warn "run_merge_all_stats is enabled but no metrics or volume pipelines are active. The merged file will be empty."
    }

    ch_collection_mean_input = channel.empty()
    ch_collection_gm_mean = channel.empty()
    ch_csf_stats_merged = channel.empty()
    ch_wm_vols_collected  = channel.empty()
    ch_gm_vols_collected  = channel.empty()
    ch_csf_vols_collected = channel.empty()

    if ( params.run_atlas_roimetrics ) {
        ATLAS_ROIMETRICS(
            mergeCovariatesIntoMeta(TRACTOFLOW.out.b0, ch_covariates),
            mergeCovariatesIntoMeta(ch_input_metrics, ch_covariates),
            [
                use_atlas_iit: params.use_atlas_iit,
                use_binary_masks: params.use_binary_masks,
                atlas_iit_b0: params.atlas_iit_b0,
                atlas_iit_bundle_masks_dir: params.atlas_iit_bundle_masks_dir,
                run_wm_metrics: do_wm_metrics,
                run_gm_metrics: do_gm_metrics,
                atlas_iit_gm_atlas: params.atlas_iit_gm_atlas,
                atlas_iit_gm_lut: params.atlas_iit_gm_lut,
                run_wm_volumes: do_wm_volumes,
                run_gm_volumes: do_gm_volumes
            ]
        )
        ch_versions = ch_versions.mix(ATLAS_ROIMETRICS.out.versions)

        if ( do_wm_metrics ) {
            if ( do_wm_volumes ) {
                ch_collection_mean_input = collectStatsFilesWithVolumes(
                    ATLAS_ROIMETRICS.out.stats_tab_mean,
                    ATLAS_ROIMETRICS.out.wm_volumes,
                    "space-native_atlas-iit-wm_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/",
                    "WM_bundle"
                )
            } else {
                ch_collection_mean_input = collectStatsFiles(ATLAS_ROIMETRICS.out.stats_tab_mean, "space-native_atlas-iit-wm_label-mean_desc-roi_stats.tsv", "${params.outdir}/metrics/", "WM_bundle")
            }
            ch_global_multiqc_files = ch_global_multiqc_files.mix(ch_collection_mean_input)
        }

        if ( do_gm_metrics ) {
            if ( do_gm_volumes ) {
                ch_collection_gm_mean = collectStatsFilesWithVolumes(
                    ATLAS_ROIMETRICS.out.gm_stats_tab_mean,
                    ATLAS_ROIMETRICS.out.gm_volumes,
                    "space-native_atlas-iit-gm_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/",
                    "GM_region"
                )
            } else {
                ch_collection_gm_mean = collectStatsFiles(
                    ATLAS_ROIMETRICS.out.gm_stats_tab_mean,
                    "space-native_atlas-iit-gm_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/",
                    "GM_region"
                )
            }
            ch_global_multiqc_files = ch_global_multiqc_files.mix(ch_collection_gm_mean)
        }

        if ( do_wm_volumes && !do_wm_metrics ) {
            ch_wm_vols_collected = ATLAS_ROIMETRICS.out.wm_volumes
                .map { _meta, csv -> csv }
                .collectFile(
                    storeDir: "${params.outdir}/metrics/",
                    name: "space-native_atlas-iit-wm_desc-roi_volumes.csv",
                    skip: 1, keepHeader: true, sort: true
                )
        }

        if ( do_gm_volumes && !do_gm_metrics ) {
            ch_gm_vols_collected = ATLAS_ROIMETRICS.out.gm_volumes
                .map { _meta, csv -> csv }
                .collectFile(
                    storeDir: "${params.outdir}/metrics/",
                    name: "space-native_atlas-iit-gm_desc-roi_volumes.csv",
                    skip: 1, keepHeader: true, sort: true
                )
        }

        if ( params.harmonization_reference ) {
            // The QC expects the harmonization reference to have the following pattern: *.reference.tsv
            // So we copy the file in the workflow workdir with the expected name pattern. If the file
            // already has the expected name pattern, this step will simply create a copy of the file.
            ch_harmonization_reference = channel.fromPath(params.harmonization_reference, checkIfExists: true)
                .map{ ref_file ->
                    def dest_name = ref_file.name.endsWith('.reference.tsv') ? ref_file.name : ref_file.name.replaceAll(/\.tsv$/, '.reference.tsv')
                    def dest_file = file("${workflow.workDir}/${dest_name}")

                    if ( !dest_file.exists() ) {
                        ref_file.copyTo(dest_file)
                    }

                    return dest_file
                }

            HARMONIZATION(
                ch_harmonization_reference,
                ch_collection_mean_input
            )
            ch_versions = ch_versions.mix(HARMONIZATION.out.versions)
            ch_global_multiqc_files = ch_global_multiqc_files.mix(
                ch_harmonization_reference,
                HARMONIZATION.out.harmonized_stats,
                HARMONIZATION.out.qc_plot_data_json,
                HARMONIZATION.out.qc_reports
            )
        }
    }

    if ( do_csf_metrics || do_csf_volumes || params.run_csf_comparison_roimetrics || params.run_csf_comparison_volumes ) {
        ATLAS_CSF_ROIMETRICS(
            mergeCovariatesIntoMeta(TRACTOFLOW.out.b0, ch_covariates),
            mergeCovariatesIntoMeta(ch_input_metrics, ch_covariates),
            [
                fs_license:                    params.freesurfer_license,
                atlas_csf_atlas:               params.atlas_csf_atlas,
                atlas_csf_lut:                 params.atlas_csf_lut,
                run_roi_metrics:               do_csf_metrics,
                run_roi_volumes:               do_csf_volumes,
                run_csf_comparison_roimetrics: params.run_csf_comparison_roimetrics,
                run_csf_comparison_volumes:    params.run_csf_comparison_volumes,
                atlas_csf_comparison_lut:      params.atlas_csf_comparison_lut
            ]
        )
        ch_versions = ch_versions.mix(ATLAS_CSF_ROIMETRICS.out.versions)

        if ( do_csf_metrics ) {
            if ( do_csf_volumes ) {
                ch_csf_stats_merged = collectStatsFilesWithVolumes(
                    ATLAS_CSF_ROIMETRICS.out.stats_tab_mean,
                    ATLAS_CSF_ROIMETRICS.out.volumes,
                    "space-native_atlas-freesurfer-csf_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/",
                    "CSF_region"
                )
            } else {
                ch_csf_stats_merged = collectStatsFiles(
                    ATLAS_CSF_ROIMETRICS.out.stats_tab_mean,
                    "space-native_atlas-freesurfer-csf_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/",
                    "CSF_region"
                )
            }
        }

        if ( do_csf_volumes && !do_csf_metrics ) {
            ch_csf_vols_collected = ATLAS_CSF_ROIMETRICS.out.volumes
                .map { _meta, csv -> csv }
                .collectFile(
                    storeDir: "${params.outdir}/metrics/",
                    name: "space-native_atlas-freesurfer-csf_desc-roi_volumes.csv",
                    skip: 1, keepHeader: true, sort: true
                )
        }

        if ( params.run_csf_comparison_roimetrics ) {
            // Per-row type map: maps each region name to WM/GM/CSF for the region_type column
            def comparison_type_map = new groovy.json.JsonSlurper()
                .parse(new File("${projectDir}/assets/freesurfer_comparison_type_map.json"))
                .collectEntries { k, v -> [(k): v] }
            if ( params.run_csf_comparison_volumes ) {
                collectStatsFilesWithVolumes(
                    ATLAS_CSF_ROIMETRICS.out.comparison_stats_tab_mean,
                    ATLAS_CSF_ROIMETRICS.out.comparison_volumes,
                    "space-native_atlas-freesurfer-comparison_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/comparison/",
                    comparison_type_map
                )
            } else {
                collectStatsFiles(
                    ATLAS_CSF_ROIMETRICS.out.comparison_stats_tab_mean,
                    "space-native_atlas-freesurfer-comparison_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/comparison/",
                    comparison_type_map
                )
            }
        }

        if ( params.run_csf_comparison_volumes && !params.run_csf_comparison_roimetrics ) {
            ATLAS_CSF_ROIMETRICS.out.comparison_volumes
                .map { _meta, csv -> csv }
                .collectFile(
                    storeDir: "${params.outdir}/metrics/comparison/",
                    name: "space-native_atlas-freesurfer-comparison_desc-roi_volumes.csv",
                    skip: 1, keepHeader: true, sort: true
                )
        }
    }

    if ( params.run_merge_all_stats ) {
        def ch_for_unified = channel.empty()
        // For each region type: use the collected stats TSV when metrics are enabled
        // (already includes volumes if collectStatsFilesWithVolumes was used),
        // otherwise fall back to the volumes-only CSV when only volumes are enabled.
        if ( params.run_atlas_roimetrics ) {
            if ( do_wm_metrics ) {
                ch_for_unified = ch_for_unified.mix(
                    ch_collection_mean_input.map { p -> "STATS:::${toAbsFile(p.toString()).absolutePath}" }
                )
            } else if ( do_wm_volumes ) {
                ch_for_unified = ch_for_unified.mix(
                    ch_wm_vols_collected.map { p -> "VOLS_WM_bundle:::${toAbsFile(p.toString()).absolutePath}" }
                )
            }
            if ( do_gm_metrics ) {
                ch_for_unified = ch_for_unified.mix(
                    ch_collection_gm_mean.map { p -> "STATS:::${toAbsFile(p.toString()).absolutePath}" }
                )
            } else if ( do_gm_volumes ) {
                ch_for_unified = ch_for_unified.mix(
                    ch_gm_vols_collected.map { p -> "VOLS_GM_region:::${toAbsFile(p.toString()).absolutePath}" }
                )
            }
        }
        if ( do_csf_metrics ) {
            ch_for_unified = ch_for_unified.mix(
                ch_csf_stats_merged.map { p -> "STATS:::${toAbsFile(p.toString()).absolutePath}" }
            )
        } else if ( do_csf_volumes ) {
            ch_for_unified = ch_for_unified.mix(
                ch_csf_vols_collected.map { p -> "VOLS_CSF_region:::${toAbsFile(p.toString()).absolutePath}" }
            )
        }
        collectUnifiedFiles(
            ch_for_unified,
            "space-native_all-regions_desc-roi_combined.tsv",
            "${params.outdir}/metrics/"
        )
    }

    if ( params.run_tractometry ) {
        TRACTOMETRY(
            mergeCovariatesIntoMeta(ch_bundle_seg, ch_covariates),
            channel.empty(),
            mergeCovariatesIntoMeta(ch_input_metrics, ch_covariates),
            channel.empty(),
            mergeCovariatesIntoMeta(TRACTOFLOW.out.fodf, ch_covariates))
        ch_versions = ch_versions.mix(TRACTOMETRY.out.versions)

        ch_tractometry_mqc = TRACTOMETRY.out.mean_tsv
            .map{ _meta, stats -> stats }
            .collectFile(
                storeDir: "${params.outdir}/metrics/",
                name: "bundles_mean_stats.tsv",
                skip: 1,
                keepHeader: true
            )
        ch_global_multiqc_files = ch_global_multiqc_files.mix(ch_tractometry_mqc)
    }

    if ( params.output_orig_space ) {
        REGISTRATION_METRICS_TO_ORIG(ch_input_metrics
            .join(TRACTOFLOW.out.t1_native)
            .join(TRACTOFLOW.out.diffusion_to_anatomical)
        )

        REGISTRATION_TRACTOGRAM_TO_ORIG(
            ch_bundle_seg
                .join(TRACTOFLOW.out.t1_native)
                .join(TRACTOFLOW.out.diffusion_to_anatomical)
                .map{ meta, bundle, t1, transfo -> [meta, bundle, [], t1, transfo] }
        )
    }

    if ( params.output_template_space && ( !params.template || !params.templateflow_resolution ) ) {
        error "Both params.template and params.templateflow_resolution must be provided to output data in template space."
    }
    else if ( params.output_template_space ) {
        OUTPUT_TEMPLATE_SPACE(
            TRACTOFLOW.out.t1,
            ch_input_metrics,
            channel.empty(),
            channel.empty(),
            ch_bundle_seg,
            channel.empty(),
            [
                template: params.template,
                templateflow_home: params.templateflow_home,
                templateflow_res: params.templateflow_resolution,
                templateflow_cohort: params.templateflow_cohort,
                run_easyreg: params.run_easyreg,
                run_synthmorph: params.run_synthmorph
            ]
        )
        ch_versions = ch_versions.mix(OUTPUT_TEMPLATE_SPACE.out.versions)
    }

    //
    // Collate and save software versions
    //
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry ->
            versions_file: entry instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':')+1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by:0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    softwareVersionsToYAML(ch_versions.mix(topic_versions.versions_file))
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name:  'sf-tractomics_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }

    //
    // MODULE: MultiQC
    //
    ch_multiqc_files = channel.empty() // To store versions, methods description, etc.

    ch_multiqc_config_subject = channel.fromPath(
        "$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_config_global = channel.fromPath(
        "$projectDir/assets/multiqc_config_global.yml", checkIfExists: true)
    ch_multiqc_custom_config = params.multiqc_config ?
        channel.fromPath(params.multiqc_config, checkIfExists: true) :
        channel.empty()
    ch_multiqc_logo          = params.multiqc_logo ?
        channel.fromPath(params.multiqc_logo, checkIfExists: true) :
        channel.fromPath("$projectDir/assets/sf-tractomics-multiqc-logo.png", checkIfExists: true)

    summary_params      = paramsSummaryMap(
        workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary = channel.value(paramsSummaryMultiqc(summary_params))
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_custom_methods_description = params.multiqc_methods_description ?
        file(params.multiqc_methods_description, checkIfExists: true) :
        file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description))

    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_methods_description.collectFile(
            name: 'methods_description_mqc.yaml',
            sort: true
        )
    )

    // Reorganizing subject-specific multiqc files here.
    qc_files = ch_sub_multiqc_files
        .groupTuple()
        .map{ meta, files ->
            def f = files.flatten().findAll { it -> it != null }
            return tuple(meta, f)
        }

    MULTIQC (
        qc_files,
        ch_multiqc_files.collect(),
        ch_multiqc_config_subject.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList(),
        [],
        []
    )

    ch_fd_files = ch_sub_multiqc_files
        .filter { _meta, files ->
            files.any { it -> it.name.contains("dwi_eddy_restricted_movement_rms") }
        }
        .map{ it -> it[1] }
    ch_global_multiqc_files = ch_global_multiqc_files.mix(ch_fd_files.flatten())
    ch_global_multiqc_files = ch_global_multiqc_files.mix(ch_multiqc_files)

    // Global multiqc
    MULTIQC_GLOBAL (
        channel.of([meta:[id: 'global'], qc_images: []]),
        ch_global_multiqc_files.collect(),
        ch_multiqc_config_global.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList(),
        [],
        []
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]

}

// Nextflow 26.x channel serialization strips the leading '/' from Path objects that cross
// a .collect() boundary. This top-level helper restores it before the path becomes a String.
def toAbsFile(p) {
    def s = p.toString()
    // Nextflow 26.x channel serialization strips the leading '/' from Path objects that cross
    // a .collect() boundary. This helper restores it before the path becomes a String.
    // Relative paths (e.g. when --outdir is relative) are resolved against the JVM CWD instead.
    if (s.startsWith('./') || s.startsWith('../')) {
        return new File(s).absoluteFile
    }
    return new File(s.startsWith('/') ? s : '/' + s)
}

// Collect per-subject stats TSV files into a single global file.
// Handles unequal column sets across files: builds a union header and fills missing values
// with empty strings. Paths are converted to absolute strings before .collect() to avoid
// the Nextflow 26.x Path serialization bug.
//
// regionType: String (fixed for all rows), Map<roi_name, type> (per-row lookup), or null (no column).
// When provided, a region_type column is inserted right after the roi column.
def collectStatsFiles(ch_stats_files, name, storeDir, regionType = null) {

    def output_file_path = "${storeDir}/${name}"

    return ch_stats_files
        .map { _meta, stats_file ->
            // Convert to absolute path string BEFORE collect so no Path object crosses
            // the collect boundary (Nextflow channel serialisation corrupts Path objects).
            toAbsFile(stats_file.toString()).absolutePath
        }
        .collect()
        .map { path_strings ->
            def header_written = false
            def all_columns = new LinkedHashSet()

            // Collect all column names across all files
            path_strings.each { path_str ->
                def lines = new File(path_str.toString()).readLines()
                if (lines.size() < 2) {
                    log.warn("No data rows in file ${path_str}. Skipping.")
                    return
                }
                def file_columns = lines[0].split('\t').toList()
                all_columns.addAll(file_columns)
            }

            // Insert region_type right after roi
            if (regionType != null) {
                def cols = all_columns.toList()
                def roi_pos = cols.indexOf("roi")
                cols.add(roi_pos >= 0 ? roi_pos + 1 : cols.size(), "region_type")
                all_columns = new LinkedHashSet(cols)
            }
            all_columns = all_columns.toList()

            // Create file writer for new file
            def output_file = new File(output_file_path).absoluteFile
            output_file.getParentFile().mkdirs()
            def file_writer = output_file.newWriter()

            // Read all stats files to write rows with all columns, filling missing values with no value
            path_strings.each { path_str ->
                def lines = new File(path_str.toString()).readLines()
                if (lines.size() < 2) {
                    return
                }
                def file_columns = lines[0].split('\t').toList()
                def column_indices = file_columns.withIndex().collectEntries { col, idx -> [col, idx] }
                if (!header_written) {
                    log.debug("Writing header with columns: ${all_columns.join(', ')}")
                    file_writer.write(all_columns.join('\t') + '\n')
                    header_written = true
                }

                lines[1..-1].each { line ->
                    def values = line.split('\t', -1)
                    def roi_val = column_indices.containsKey("roi") ? values[column_indices["roi"]] : ""
                    def rt = regionType instanceof Map ? regionType.getOrDefault(roi_val, "") : (regionType ?: "")
                    def row = all_columns.collect { col ->
                        if (col == "region_type") return rt
                        column_indices.containsKey(col) ? values[column_indices[col]] : ''
                    }
                    file_writer.write(row.join('\t') + '\n')
                }
            }

            // Close the file writer
            file_writer.close()

            return output_file.toPath()
        }
}

// Variant of collectStatsFiles that also joins per-subject volumes (CSV) into the stats
// (TSV) as extra columns (volume_voxels, volume_mm3), merging on the roi column.
// The volumes CSV uses "region" (GM/CSF) or "bundle" (WM) — both are matched to "roi".
// regionType behaves the same as in collectStatsFiles (String, Map, or null).
def collectStatsFilesWithVolumes(ch_stats_files, ch_volumes, name, storeDir, regionType = null) {

    def output_file_path = "${storeDir}/${name}"

    return ch_stats_files
        .join(ch_volumes)
        .map { _meta, stats_file, volumes_file ->
            // Encode both paths as a single string BEFORE collect so no Path objects
            // cross the collect boundary (Nextflow channel serialisation corrupts them).
            def sf = toAbsFile(stats_file.toString()).absolutePath
            def vf = toAbsFile(volumes_file.toString()).absolutePath
            "${sf}:::${vf}"
        }
        .collect()
        .map { encoded_pairs ->
            def header_written = false
            def all_columns = new LinkedHashSet()

            encoded_pairs.each { encoded ->
                def sf = new File(encoded.toString().split(':::')[0])
                def lines = sf.readLines()
                if (lines.size() < 2) {
                    log.warn("No data rows in file ${sf}. Skipping.")
                    return
                }
                lines[0].split('\t').each { all_columns.add(it) }
            }

            // Insert region_type right after roi, then append volume columns
            if (regionType != null) {
                def cols = all_columns.toList()
                def roi_pos = cols.indexOf("roi")
                cols.add(roi_pos >= 0 ? roi_pos + 1 : cols.size(), "region_type")
                all_columns = new LinkedHashSet(cols)
            }
            all_columns.add("volume_voxels")
            all_columns.add("volume_mm3")
            all_columns = all_columns.toList()

            def output_file = new File(output_file_path).absoluteFile
            output_file.getParentFile().mkdirs()
            def fw = output_file.newWriter()

            encoded_pairs.each { encoded ->
                def parts    = encoded.toString().split(':::')
                def stats_f  = new File(parts[0])
                def vols_f   = new File(parts[1])

                def stats_lines = stats_f.readLines()
                if (stats_lines.size() < 2) return

                def stats_cols = stats_lines[0].split('\t').toList()
                def stats_idx  = stats_cols.withIndex().collectEntries { c, i -> [c, i] }

                def vol_map = [:]
                def vol_lines = vols_f.readLines()
                if (vol_lines.size() >= 2) {
                    def vol_cols = vol_lines[0].split(',').toList()
                    def roi_col  = vol_cols.find { it in ["region", "bundle"] }
                    def roi_i    = vol_cols.indexOf(roi_col)
                    def vox_i    = vol_cols.indexOf("volume_voxels")
                    def mm3_i    = vol_cols.indexOf("volume_mm3")
                    vol_lines[1..-1].each { line ->
                        if (!line.trim()) return
                        def v = line.split(',')
                        vol_map[v[roi_i]] = [v[vox_i], v[mm3_i]]
                    }
                }

                if (!header_written) {
                    log.debug("Writing header with columns: ${all_columns.join(', ')}")
                    fw.write(all_columns.join('\t') + '\n')
                    header_written = true
                }

                stats_lines[1..-1].each { line ->
                    if (!line.trim()) return
                    def vals = line.split('\t', -1)
                    def roi  = stats_idx.containsKey("roi") ? vals[stats_idx["roi"]] : ""
                    def rt   = regionType instanceof Map ? regionType.getOrDefault(roi, "") : (regionType ?: "")
                    def vd   = vol_map.getOrDefault(roi, ["", ""])
                    def row  = all_columns.collect { col ->
                        if (col == "region_type")   return rt
                        if (col == "volume_voxels") return vd[0]
                        if (col == "volume_mm3")    return vd[1]
                        stats_idx.containsKey(col) ? (stats_idx[col] < vals.size() ? vals[stats_idx[col]] : '') : ''
                    }
                    fw.write(row.join('\t') + '\n')
                }
            }

            fw.close()
            return output_file.toPath()
        }
}

// Merge per-atlas collected stats TSVs and/or volume CSVs into one global file.
// Encoded items in ch_files:
//   "STATS:::abs_path"          — TSV already containing roi + region_type + metric cols (± volume cols)
//   "VOLS_<region_type>:::path" — CSV with bundle/region col; normalized to roi + region_type on the fly
// Output is a TSV with the union of all columns (missing values filled with empty string).
def collectUnifiedFiles(ch_files, name, storeDir) {

    def output_file_path = "${storeDir}/${name}"

    return ch_files
        .collect()
        .map { encoded_list ->
            def header_written = false
            def all_columns = new LinkedHashSet()

            // First pass: build the union of all columns
            encoded_list.each { encoded ->
                def parts = encoded.toString().split(':::')
                def type  = parts[0]
                def f     = new File(parts[1])
                def lines = f.readLines()
                if (lines.size() < 2) return

                if (type == "STATS") {
                    lines[0].split('\t').each { all_columns.add(it) }
                } else {
                    // Volume CSV: rename bundle/region → roi, inject region_type after roi
                    def cols = lines[0].split(',').toList()
                    cols.each { col -> all_columns.add(col in ["bundle", "region"] ? "roi" : col) }
                    if (!all_columns.contains("region_type")) {
                        def list = all_columns.toList()
                        def roi_pos = list.indexOf("roi")
                        list.add(roi_pos >= 0 ? roi_pos + 1 : list.size(), "region_type")
                        all_columns = new LinkedHashSet(list)
                    }
                }
            }
            all_columns = all_columns.toList()

            def output_file = new File(output_file_path).absoluteFile
            output_file.getParentFile().mkdirs()
            def fw = output_file.newWriter()

            // Second pass: write rows
            encoded_list.each { encoded ->
                def parts = encoded.toString().split(':::')
                def type  = parts[0]
                def f     = new File(parts[1])
                def lines = f.readLines()
                if (lines.size() < 2) {
                    log.warn("No data rows in file ${f}. Skipping.")
                    return
                }

                if (!header_written) {
                    fw.write(all_columns.join('\t') + '\n')
                    header_written = true
                }

                if (type == "STATS") {
                    def file_cols = lines[0].split('\t').toList()
                    def col_idx   = file_cols.withIndex().collectEntries { col, i -> [col, i] }
                    lines[1..-1].each { line ->
                        if (!line.trim()) return
                        def vals = line.split('\t', -1)
                        def row = all_columns.collect { col ->
                            col_idx.containsKey(col) ? (col_idx[col] < vals.size() ? vals[col_idx[col]] : '') : ''
                        }
                        fw.write(row.join('\t') + '\n')
                    }
                } else {
                    // "VOLS_WM_bundle", "VOLS_GM_region", "VOLS_CSF_region"
                    def region_type = type.replaceFirst(/^VOLS_/, "")
                    def file_cols   = lines[0].split(',').toList()
                    def roi_src     = file_cols.find { it in ["bundle", "region"] }
                    def col_idx     = file_cols.withIndex().collectEntries { col, i -> [col, i] }
                    lines[1..-1].each { line ->
                        if (!line.trim()) return
                        def vals = line.split(',', -1)
                        def roi  = roi_src ? (col_idx[roi_src] < vals.size() ? vals[col_idx[roi_src]] : '') : ''
                        def row  = all_columns.collect { col ->
                            if (col == "roi")         return roi
                            if (col == "region_type") return region_type
                            if (col in ["bundle", "region"]) return ''
                            col_idx.containsKey(col) ? (col_idx[col] < vals.size() ? vals[col_idx[col]] : '') : ''
                        }
                        fw.write(row.join('\t') + '\n')
                    }
                }
            }

            fw.close()
            return output_file.toPath()
        }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
