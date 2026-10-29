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
include { SEGMENTATION_SYNTHSEG as SYNTHSEG_VOLUMES } from '../modules/nf-neuro/segmentation/synthseg/main'
include { SEGMENTATION_SAMSEGLONG as SAMSEG_LONG_VOLUMES } from '../modules/local/segmentation/samseglong/main'
include { STATS_SUBJECTVOLUMES as STATS_SUBJECT_GM_VOLUMES         } from '../modules/local/stats/subjectvolumes/main'
include { STATS_SUBJECTVOLUMES as STATS_SUBJECT_CSF_VOLUMES        } from '../modules/local/stats/subjectvolumes/main'
include { STATS_SUBJECTVOLUMES as STATS_SUBJECT_COMPARISON_VOLUMES } from '../modules/local/stats/subjectvolumes/main'
include { STATS_HOC              } from '../modules/local/stats/hoc/main'
include { SEGMENTATION_FSRECONALL as RECONALL_THICKNESS } from '../modules/nf-neuro/segmentation/fsreconall/main'
include { STATS_THICKNESS        } from '../modules/local/stats/thickness/main'
include { STATS_SURFACEMETRICS   } from '../modules/local/stats/surfacemetrics/main'
include { IMAGE_LABELFRACTION as SUBJECT_ROI_FRACTIONS } from '../modules/local/image/labelfraction/main'
include { STATS_METRICSINROI as STATS_SUBJECT_ROI_METRICS } from '../modules/nf-neuro/stats/metricsinroi/main'
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
            "preproc_t1_run_resampling": params.run_t1_resampling,
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
    def do_cmp_volumes = params.run_csf_comparison_volumes

    // Where GM, CSF and comparison volumes come from. 'atlas' counts voxels of a template warped
    // onto the subject B0, so it only reflects the registration. 'synthseg' and 'freesurfer'
    // count the subject's own segmentation in native T1 space. WM bundles are always atlas-based.
    def volume_source = params.volume_source ?: "atlas"
    if ( !(volume_source in ["atlas", "synthseg", "freesurfer"]) ) {
        error "volume_source must be 'atlas', 'synthseg' or 'freesurfer', but got '${volume_source}'."
    }
    // run_longitudinal_volumes segments all sessions of a subject jointly (SAMSEG longitudinal)
    // and takes precedence over volume_source for the GM, CSF and comparison volumes.
    def do_longitudinal = params.run_longitudinal_volumes == true
    if ( do_longitudinal ) {
        if ( volume_source != "atlas" ) {
            log.info "run_longitudinal_volumes = true: volume_source = '${volume_source}' is replaced by SAMSEG longitudinal."
        }
        volume_source = "samseg_long"
    }
    def subject_volumes = volume_source != "atlas"
    // Hippocampal occupancy score, counted on the subject's own segmentation
    def do_hoc = params.run_hoc == true
    def do_thickness = params.run_cortical_thickness == true
    // Cortical diffusion metrics sampled on the recon-all surfaces, at mid-thickness
    def do_surface_metrics = params.run_cortical_surface_metrics == true
    // Diffusion metrics in the subject's own GM regions, weighted by voxel fraction
    def do_subject_metrics = params.run_subject_roi_metrics == true
    if ( do_subject_metrics && !subject_volumes ) {
        error "run_subject_roi_metrics = true needs the subject's own segmentation: set volume_source to 'synthseg' " +
              "or 'freesurfer', or run_longitudinal_volumes = true."
    }
    if ( do_thickness && !params.freesurfer_license ) {
        error "run_cortical_thickness = true requires params.freesurfer_license (recon-all runs from the FreeSurfer container)."
    }
    if ( do_surface_metrics && !params.freesurfer_license ) {
        error "run_cortical_surface_metrics = true requires params.freesurfer_license (recon-all runs from the FreeSurfer container)."
    }
    if ( do_hoc && !subject_volumes ) {
        error "run_hoc = true needs the subject's own segmentation: set volume_source to 'synthseg' or " +
              "'freesurfer', or run_longitudinal_volumes = true."
    }
    // Code revision written into the volume CSVs, so results of different versions are never mixed
    // unknowingly: the git commit when run from a repository, else the pipeline version.
    def pipeline_revision = workflow.commitId ?: gitRevision(projectDir) ?: workflow.manifest.version
    def do_gm_atlas_volumes  = do_gm_volumes  && !subject_volumes
    def do_csf_atlas_volumes = do_csf_volumes && !subject_volumes
    def do_cmp_atlas_volumes = do_cmp_volumes && !subject_volumes

    if ( (do_wm_metrics || do_wm_volumes || do_gm_metrics || do_gm_atlas_volumes) && !params.run_atlas_roimetrics ) {
        error "IIT atlas metrics/volumes (WM or GM) require run_atlas_roimetrics = true."
    }
    if ( params.run_atlas_roimetrics && !(do_wm_metrics || do_wm_volumes || do_gm_metrics || do_gm_atlas_volumes) ) {
        log.warn "run_atlas_roimetrics = true but no IIT atlas output is requested, so nothing is computed with it. " +
                 "Enable run_wm_metrics, run_gm_metrics, run_wm_volumes or run_gm_volumes (or run_roi_metrics / run_roi_volumes)."
    }

    // ATLAS_ROIMETRICS is driven by two independent axes rather than per-tissue flags:
    // which ROI representation to warp and analyse, and what to compute on it. WM bundles
    // are the 'masks' representation, the IIT GM Desikan parcellation is the 'labelmap' one.
    def roi_sources = []
    if ( do_wm_metrics || do_wm_volumes ) { roi_sources << "masks" }
    if ( do_gm_metrics || do_gm_atlas_volumes ) { roi_sources << "labelmap" }

    def roi_outputs = []
    if ( do_wm_metrics || do_gm_metrics ) { roi_outputs << "metrics" }
    if ( do_wm_volumes || do_gm_atlas_volumes ) { roi_outputs << "volumes" }

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
    // Per-subject volume CSVs, filled either by the atlas subworkflows or by the
    // subject-segmentation branch below, depending on volume_source.
    ch_wm_volumes  = channel.empty()
    ch_gm_volumes  = channel.empty()
    ch_csf_volumes = channel.empty()
    ch_cmp_volumes = channel.empty()
    ch_hoc         = channel.empty()
    ch_subject_roi_stats = channel.empty()

    // Every T1 annotated once: scanner (BIDS sidecar) and duplicates (same voxel data). Used by the
    // volume branches and by the warnings below.
    ch_t1_annotated = ch_t1.toList().flatMap { items -> annotateT1s(items) }
    ch_t1_vol       = ch_t1_annotated.map { _orig, meta, t1 -> [meta, t1] }
    ch_t1_annotated.toList().subscribe { items -> warnT1Annotations(items) }

    if ( subject_volumes && (do_gm_volumes || do_csf_volumes || do_cmp_volumes || do_hoc || do_subject_metrics) ) {
        if ( volume_source == "samseg_long" ) {
            if ( !params.freesurfer_license ) {
                error "run_longitudinal_volumes = true requires params.freesurfer_license (SAMSEG runs from the FreeSurfer container)."
            }
            // One task per subject with one T1 per session (the first run when a session has
            // several), sessions in name order. The raw T1 is used, as for SynthSeg.
            ch_t1_by_subject = ch_t1_vol
                .map { meta, t1 -> [meta.id, meta, t1] }
                .groupTuple()
                .map { id, metas, t1s ->
                    def per_session = [metas, t1s].transpose()
                        .groupBy { pair -> pair[0].session ?: "" }
                        .collect { _ses, pairs -> pairs.sort { pair -> pair[0].run ?: "" }[0] }
                        .sort { pair -> pair[0].session ?: "" }
                    [[id: id], per_session.collect { pair -> pair[0] }, per_session.collect { pair -> pair[1] }]
                }
            SAMSEG_LONG_VOLUMES(
                ch_t1_by_subject.combine(channel.fromPath(params.freesurfer_license, checkIfExists: true))
            )
            ch_versions = ch_versions.mix(SAMSEG_LONG_VOLUMES.out.versions.first())

            // Back to one item per session: files are named <id_session[_run]>__samseg_*.
            ch_subject_seg = SAMSEG_LONG_VOLUMES.out.seg
                .flatMap { _meta, session_metas, segs, icvs ->
                    def seg_list = segs instanceof List ? segs : [segs]
                    def icv_list = icvs instanceof List ? icvs : [icvs]
                    session_metas.collect { m ->
                        def prefix = [m.id, m.session, m.run].findAll { x -> x }.join("_")
                        [
                            m,
                            seg_list.find { f -> f.name == "${prefix}__samseg_seg.nii.gz" },
                            icv_list.find { f -> f.name == "${prefix}__samseg_icv.csv" },
                            []   // SAMSEG has no QC score
                        ]
                    }
                }
        }
        else if ( volume_source == "synthseg" ) {
            if ( !params.freesurfer_license ) {
                error "volume_source = 'synthseg' requires params.freesurfer_license (SynthSeg runs from the FreeSurfer container)."
            }
            // The raw T1 is segmented, not TRACTOFLOW.out.t1_native: brain extraction removes the
            // extra-cerebral CSF (intracranial volume too small) and any BET error trims cortex.
            // Segment each distinct T1 once (~26 GB, minutes per scan), see distinctT1s
            ch_t1_unique = distinctT1s(ch_t1_vol)
            SYNTHSEG_VOLUMES(
                ch_t1_unique
                    .map { meta, _metas, t1 -> [meta, t1, []] }
                    .combine(channel.fromPath(params.freesurfer_license, checkIfExists: true))
            )
            ch_versions = ch_versions.mix(SYNTHSEG_VOLUMES.out.versions.first())

            ch_subject_seg = ch_t1_unique
                .map { meta, metas, _t1 -> [meta, metas] }
                .join(SYNTHSEG_VOLUMES.out.aparc_aseg.join(SYNTHSEG_VOLUMES.out.volume).join(SYNTHSEG_VOLUMES.out.qc_score))
                .flatMap { _meta, metas, seg, seg_volumes, qc -> metas.collect { m -> [m, seg, seg_volumes, qc] } }
        }
        else {
            // Native-space aparc+aseg given as input (samplesheet or BIDS FreeSurfer derivatives),
            // before TractoFlow warps it to DWI space.
            ch_subject_seg = ch_aparc_aseg
                .filter { it -> it[1] }
                .join(ch_t1_annotated.map { orig, meta, _t1 -> [orig, meta] })
                .map { _orig, aparc_aseg, meta -> [meta, aparc_aseg, [], []] }

            // Without its aparc+aseg a sample would just be missing from the volume files.
            ch_t1
                .join(ch_aparc_aseg.filter { it -> it[1] }, remainder: true)
                .filter { _meta, _t1, aparc_aseg -> !aparc_aseg }
                .map { meta, _t1, _aparc_aseg -> [meta.id, meta.session].findAll { x -> x }.join("_") }
                .unique()
                .collect()
                .subscribe { samples ->
                    log.warn "volume_source = 'freesurfer' but ${samples.size()} sample(s) have no aparc+aseg input " +
                             "(e.g. ${samples.take(3).join(', ')}): they get no GM/CSF/comparison volumes."
                }
        }

        def subjectVolumesInput = { lut_path ->
            ch_subject_seg
                .combine(channel.fromPath(lut_path, checkIfExists: true))
                .map { meta, seg, seg_volumes, qc, lut -> [meta, seg, lut, seg_volumes, qc] }
        }

        if ( do_gm_volumes ) {
            // SAMSEG has no Desikan parcels: its GM file holds the cortex totals instead of 68
            // parcels that would all read 0.
            def gm_lut = volume_source == "samseg_long" ? "freesurfer_gm_samseg_lut.json" : "freesurfer_gm_lut.json"
            STATS_SUBJECT_GM_VOLUMES(subjectVolumesInput.call("${projectDir}/assets/${gm_lut}"))
            ch_versions = ch_versions.mix(STATS_SUBJECT_GM_VOLUMES.out.versions.first())
            ch_gm_volumes = STATS_SUBJECT_GM_VOLUMES.out.volumes
        }
        if ( do_csf_volumes ) {
            STATS_SUBJECT_CSF_VOLUMES(subjectVolumesInput.call(params.atlas_csf_lut ?: "${projectDir}/assets/freesurfer_csf_lut.json"))
            ch_versions = ch_versions.mix(STATS_SUBJECT_CSF_VOLUMES.out.versions.first())
            ch_csf_volumes = STATS_SUBJECT_CSF_VOLUMES.out.volumes
        }
        if ( do_cmp_volumes ) {
            STATS_SUBJECT_COMPARISON_VOLUMES(subjectVolumesInput.call(params.atlas_csf_comparison_lut ?: "${projectDir}/assets/freesurfer_comparison_lut.json"))
            ch_versions = ch_versions.mix(STATS_SUBJECT_COMPARISON_VOLUMES.out.versions.first())
            ch_cmp_volumes = STATS_SUBJECT_COMPARISON_VOLUMES.out.volumes
        }
        if ( do_hoc ) {
            STATS_HOC(ch_subject_seg.map { meta, seg, _seg_volumes, _qc -> [meta, seg] })
            ch_versions = ch_versions.mix(STATS_HOC.out.versions.first())
            ch_hoc = STATS_HOC.out.hoc
            collectSampleCsvs(ch_hoc, "space-native_desc-hoc.csv", "${params.outdir}/metrics/")
        }
        if ( do_subject_metrics ) {
            // The segmentation is in native T1 space. Its labels go to diffusion space through
            // TractoFlow's T1-to-DWI transform, as fractions of the acquired DWI voxels (the raw DWI
            // grid), so each metric is averaged with every voxel weighted by how much of it lies in
            // the region (see IMAGE_LABELFRACTION). The GM LUT gives the region names of the GM files.
            def subject_lut = volume_source == "samseg_long" ? "freesurfer_gm_samseg_lut.json" : "freesurfer_gm_lut.json"
            def ch_seg_tractoflow_meta = ch_subject_seg
                .map { meta, seg, _seg_volumes, _qc -> [meta, seg] }
                .join(ch_t1_annotated.map { orig, meta, _t1 -> [meta, orig] })
                .map { _meta, seg, orig -> [orig, seg] }
            SUBJECT_ROI_FRACTIONS(
                ch_seg_tractoflow_meta
                    .join(ch_dwi_bval_bvec.map { meta, dwi, _bval, _bvec -> [meta, dwi] })
                    .join(TRACTOFLOW.out.dti_fa)
                    .join(TRACTOFLOW.out.anatomical_to_diffusion)
                    .combine(channel.fromPath("${projectDir}/assets/${subject_lut}", checkIfExists: true))
            )
            ch_versions = ch_versions.mix(SUBJECT_ROI_FRACTIONS.out.versions.first())
            STATS_SUBJECT_ROI_METRICS(
                mergeCovariatesIntoMeta(
                    ch_input_metrics
                        .join(SUBJECT_ROI_FRACTIONS.out.fractions)
                        .map { meta, metrics, fractions -> [meta, metrics, fractions, []] },
                    ch_covariates)
            )
            ch_versions = ch_versions.mix(STATS_SUBJECT_ROI_METRICS.out.versions.first())
            ch_subject_roi_stats = STATS_SUBJECT_ROI_METRICS.out.stats_mean
            def seg_name = volume_source == "samseg_long" ? "samseg" : volume_source
            collectStatsFiles(ch_subject_roi_stats, "space-native_seg-${seg_name}_label-mean_desc-roi_stats.tsv",
                              "${params.outdir}/metrics/", "GM_subject")
            collectSampleCsvs(SUBJECT_ROI_FRACTIONS.out.sums, "space-native_seg-${seg_name}_desc-roi_fractions.csv",
                              "${params.outdir}/metrics/")
        }
    }

    // FreeSurfer recon-all on the raw T1, for cortical thickness and surface sampling
    ch_thickness = channel.empty()
    ch_surface_stats = channel.empty()
    if ( do_thickness || do_surface_metrics ) {
        // recon-all takes hours per scan: run each distinct T1 once, share it with every run
        def ch_t1_recon = distinctT1s(ch_t1_vol)
        RECONALL_THICKNESS(
            ch_t1_recon
                .map { meta, _metas, t1 -> [meta, t1] }
                .combine(channel.fromPath(params.freesurfer_license, checkIfExists: true))
        )
        ch_versions = ch_versions.mix(RECONALL_THICKNESS.out.versions.first())
        def ch_recon_per_sample = ch_t1_recon
            .map { meta, metas, _t1 -> [meta, metas] }
            .join(RECONALL_THICKNESS.out.recon_all_out_folder)
            .flatMap { _meta, metas, recon_all -> metas.collect { m -> [m, recon_all] } }

        // Thickness per Desikan region, read from the recon-all stats
        if ( do_thickness ) {
            STATS_THICKNESS(ch_recon_per_sample)
            ch_versions = ch_versions.mix(STATS_THICKNESS.out.versions.first())
            ch_thickness = STATS_THICKNESS.out.thickness
            collectSampleCsvs(ch_thickness, "space-native_desc-cortical-thickness.csv", "${params.outdir}/metrics/")
        }

        // Diffusion metrics on the surfaces: maps and DWI mask to T1 space with TractoFlow's
        // DWI-to-T1 transform, sampled at mid-thickness, averaged per Desikan region
        if ( do_surface_metrics ) {
            // Reference grid: the raw T1 given to recon-all (full field of view; TractoFlow's T1
            // is cropped to the brain and can cut the edge of the cortex). Same world coordinates.
            def ch_recon_tractoflow_meta = ch_recon_per_sample
                .join(ch_t1_annotated.map { orig, meta, t1 -> [meta, orig, t1] })
                .map { _meta, recon_all, orig, t1 -> [orig, t1, recon_all] }
            STATS_SURFACEMETRICS(
                mergeCovariatesIntoMeta(
                    ch_input_metrics
                        .join(TRACTOFLOW.out.b0_mask)
                        .join(ch_recon_tractoflow_meta)
                        .join(TRACTOFLOW.out.diffusion_to_anatomical)
                        .map { meta, metrics, mask, t1, recon_all, transforms -> [meta, metrics, mask, t1, transforms, recon_all] },
                    ch_covariates)
            )
            ch_versions = ch_versions.mix(STATS_SURFACEMETRICS.out.versions.first())
            ch_surface_stats = STATS_SURFACEMETRICS.out.stats_mean
            collectStatsFiles(ch_surface_stats, "space-native_surf-freesurfer_label-mean_desc-roi_stats.tsv",
                              "${params.outdir}/metrics/", "GM_surface")
        }
    }

    // Volumes are requested on longitudinal data without the longitudinal option: each session
    // is then measured on its own (or from a warped atlas), and that session-to-session noise is
    // of the order of yearly atrophy.
    if ( (do_wm_volumes || do_gm_volumes || do_csf_volumes || do_cmp_volumes) && !do_longitudinal ) {
        ch_t1
            .map { meta, _t1 -> [meta.id, meta.session ?: ""] }
            .unique()
            .groupTuple()
            .filter { _id, sessions -> sessions.size() > 1 }
            .map { id, _sessions -> id }
            .collect()
            .subscribe { ids ->
                log.warn "Longitudinal data detected: ${ids.size()} subject(s) have several sessions " +
                         "(e.g. ${ids.take(3).join(', ')}), but run_longitudinal_volumes is not activated (false). " +
                         "Volumes are computed for each session independently (volume_source = '${volume_source}'), " +
                         "which adds session-to-session noise comparable to yearly atrophy. " +
                         "Set run_longitudinal_volumes = true to measure atrophy over time. See docs/usage.md."
            }
    }

    if ( params.run_atlas_roimetrics && roi_sources && roi_outputs ) {
        ATLAS_ROIMETRICS(
            mergeCovariatesIntoMeta(TRACTOFLOW.out.b0, ch_covariates),
            mergeCovariatesIntoMeta(ch_input_metrics, ch_covariates),
            channel.empty(),  // no pre-registered atlas: the IIT atlas is fetched and registered internally
            [
                use_atlas_iit: params.use_atlas_iit,
                use_binary_masks: params.use_binary_masks,
                atlas_iit_b0: params.atlas_iit_b0,
                atlas_iit_bundle_masks_dir: params.atlas_iit_bundle_masks_dir,
                atlas_iit_gm_atlas: params.atlas_iit_gm_atlas,
                atlas_iit_gm_lut: params.atlas_iit_gm_lut,
                roi_sources: roi_sources,
                // The outputs axis is shared by both representations, so asking for WM
                // metrics and GM volumes computes all four. The unwanted channels are
                // simply not consumed below.
                roi_outputs: roi_outputs
            ]
        )
        ch_versions = ch_versions.mix(ATLAS_ROIMETRICS.out.versions)

        if ( do_wm_metrics ) {
            if ( do_wm_volumes ) {
                ch_collection_mean_input = collectStatsFilesWithVolumes(
                    ATLAS_ROIMETRICS.out.mask_stats_tab_mean,
                    ATLAS_ROIMETRICS.out.mask_volumes,
                    "space-native_atlas-iit-wm_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/",
                    "WM_bundle"
                )
            } else {
                ch_collection_mean_input = collectStatsFiles(ATLAS_ROIMETRICS.out.mask_stats_tab_mean, "space-native_atlas-iit-wm_label-mean_desc-roi_stats.tsv", "${params.outdir}/metrics/", "WM_bundle")
            }
            ch_global_multiqc_files = ch_global_multiqc_files.mix(ch_collection_mean_input)
        }

        if ( do_gm_atlas_volumes ) {
            ch_gm_volumes = ATLAS_ROIMETRICS.out.labelmap_volumes
        }
        if ( do_wm_volumes ) {
            ch_wm_volumes = ATLAS_ROIMETRICS.out.mask_volumes
        }

        if ( do_gm_metrics ) {
            if ( do_gm_volumes ) {
                ch_collection_gm_mean = collectStatsFilesWithVolumes(
                    ATLAS_ROIMETRICS.out.labelmap_stats_tab_mean,
                    ch_gm_volumes,
                    "space-native_atlas-iit-gm_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/",
                    "GM_region",
                    volume_source
                )
            } else {
                ch_collection_gm_mean = collectStatsFiles(
                    ATLAS_ROIMETRICS.out.labelmap_stats_tab_mean,
                    "space-native_atlas-iit-gm_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/",
                    "GM_region"
                )
            }
            ch_global_multiqc_files = ch_global_multiqc_files.mix(ch_collection_gm_mean)
        }

        if ( do_wm_volumes && !do_wm_metrics ) {
            ch_wm_vols_collected = ATLAS_ROIMETRICS.out.mask_volumes
                .map { _meta, csv -> csv }
                .collectFile(
                    storeDir: "${params.outdir}/metrics/",
                    name: "space-native_atlas-iit-wm_desc-roi_volumes.csv",
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

    // GM volumes alone may come from the subject's segmentation without running ATLAS_ROIMETRICS,
    // so they are collected outside its block.
    if ( do_gm_volumes && !do_gm_metrics ) {
        ch_gm_vols_collected = collectVolumeFiles(
            ch_gm_volumes,
            "space-native_atlas-iit-gm_desc-roi_volumes.csv",
            "${params.outdir}/metrics/",
            volume_source,
            params.volume_icv_drift,
            pipeline_revision
        )
    }

    if ( do_csf_metrics || do_csf_atlas_volumes || params.run_csf_comparison_roimetrics || do_cmp_atlas_volumes ) {
        ATLAS_CSF_ROIMETRICS(
            mergeCovariatesIntoMeta(TRACTOFLOW.out.b0, ch_covariates),
            mergeCovariatesIntoMeta(ch_input_metrics, ch_covariates),
            [
                fs_license:                    params.freesurfer_license,
                atlas_csf_atlas:               params.atlas_csf_atlas,
                atlas_csf_lut:                 params.atlas_csf_lut,
                run_roi_metrics:               do_csf_metrics,
                run_roi_volumes:               do_csf_atlas_volumes,
                run_csf_comparison_roimetrics: params.run_csf_comparison_roimetrics,
                run_csf_comparison_volumes:    do_cmp_atlas_volumes,
                atlas_csf_comparison_lut:      params.atlas_csf_comparison_lut
            ]
        )
        ch_versions = ch_versions.mix(ATLAS_CSF_ROIMETRICS.out.versions)

        if ( do_csf_atlas_volumes ) {
            ch_csf_volumes = ATLAS_CSF_ROIMETRICS.out.volumes
        }
        if ( do_cmp_atlas_volumes ) {
            ch_cmp_volumes = ATLAS_CSF_ROIMETRICS.out.comparison_volumes
        }

        if ( do_csf_metrics ) {
            if ( do_csf_volumes ) {
                ch_csf_stats_merged = collectStatsFilesWithVolumes(
                    ATLAS_CSF_ROIMETRICS.out.stats_tab_mean,
                    ch_csf_volumes,
                    "space-native_atlas-freesurfer-csf_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/",
                    "CSF_region",
                    volume_source
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

        if ( params.run_csf_comparison_roimetrics ) {
            // Per-row type map: maps each region name to WM/GM/CSF for the region_type column
            def comparison_type_map = new groovy.json.JsonSlurper()
                .parse(new File("${projectDir}/assets/freesurfer_comparison_type_map.json"))
                .collectEntries { k, v -> [(k): v] }
            if ( do_cmp_volumes ) {
                collectStatsFilesWithVolumes(
                    ATLAS_CSF_ROIMETRICS.out.comparison_stats_tab_mean,
                    ch_cmp_volumes,
                    "space-native_atlas-freesurfer-comparison_label-mean_desc-roi_stats.tsv",
                    "${params.outdir}/metrics/comparison/",
                    comparison_type_map,
                    volume_source
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
    }

    // Every input session must have volumes of every requested type. A failed task (out of
    // memory, bad image) dropped under errorStrategy 'ignore' would otherwise just be missing
    // from the CSVs. SAMSEG keeps one run per session, so the check is per session.
    def ch_expected_sessions = ch_t1_vol.map { meta, _t1 -> volumeSampleKey(meta)[0..1] }.unique().toList()
    [["WM bundle", do_wm_volumes ? ch_wm_volumes : null],
     ["GM", do_gm_volumes ? ch_gm_volumes : null],
     ["CSF", do_csf_volumes ? ch_csf_volumes : null],
     ["comparison", do_cmp_volumes ? ch_cmp_volumes : null],
     ["HOC", do_hoc ? ch_hoc : null],
     ["cortical thickness", do_thickness ? ch_thickness : null],
     ["cortical surface metrics", do_surface_metrics ? ch_surface_stats : null],
     ["subject-region metrics", do_subject_metrics ? ch_subject_roi_stats : null]].findAll { entry -> entry[1] != null }.each { entry ->
        checkVolumeCoverage(entry[0], entry[1], ch_expected_sessions, "${params.outdir}/metrics", params.allow_missing_volumes == true)
    }

    // CSF and comparison volumes alone may come from the subject's segmentation without
    // running ATLAS_CSF_ROIMETRICS, so they are collected outside its block.
    if ( do_csf_volumes && !do_csf_metrics ) {
        ch_csf_vols_collected = collectVolumeFiles(
            ch_csf_volumes,
            "space-native_atlas-freesurfer-csf_desc-roi_volumes.csv",
            "${params.outdir}/metrics/",
            volume_source,
            params.volume_icv_drift,
            pipeline_revision
        )
    }

    if ( do_cmp_volumes && !params.run_csf_comparison_roimetrics ) {
        collectVolumeFiles(
            ch_cmp_volumes,
            "space-native_atlas-freesurfer-comparison_desc-roi_volumes.csv",
            "${params.outdir}/metrics/comparison/",
            volume_source,
            params.volume_icv_drift,
            pipeline_revision
        )
    }

    if ( params.run_merge_all_stats ) {
        def ch_for_unified = channel.empty()
        // For each region type: use the collected stats TSV when metrics are enabled
        // (already includes volumes if collectStatsFilesWithVolumes was used),
        // otherwise fall back to the volumes-only CSV when only volumes are enabled.
        if ( params.run_atlas_roimetrics ) {
            if ( do_wm_metrics ) {
                ch_for_unified = ch_for_unified.mix(
                    ch_collection_mean_input.map { p -> "STATS_WM_bundle:::${toAbsFile(p.toString()).absolutePath}" }
                )
            } else if ( do_wm_volumes ) {
                ch_for_unified = ch_for_unified.mix(
                    ch_wm_vols_collected.map { p -> "VOLS_WM_bundle:::${toAbsFile(p.toString()).absolutePath}" }
                )
            }
        }
        if ( do_gm_metrics ) {
            ch_for_unified = ch_for_unified.mix(
                ch_collection_gm_mean.map { p -> "STATS_GM_region:::${toAbsFile(p.toString()).absolutePath}" }
            )
        } else if ( do_gm_volumes ) {
            ch_for_unified = ch_for_unified.mix(
                ch_gm_vols_collected.map { p -> "VOLS_GM_region:::${toAbsFile(p.toString()).absolutePath}" }
            )
        }
        if ( do_csf_metrics ) {
            ch_for_unified = ch_for_unified.mix(
                ch_csf_stats_merged.map { p -> "STATS_CSF_region:::${toAbsFile(p.toString()).absolutePath}" }
            )
        } else if ( do_csf_volumes ) {
            ch_for_unified = ch_for_unified.mix(
                ch_csf_vols_collected.map { p -> "VOLS_CSF_region:::${toAbsFile(p.toString()).absolutePath}" }
            )
        }
        collectUnifiedFiles(
            ch_for_unified,
            "space-native_all-regions_desc-roi_combined.tsv",
            "${params.outdir}/metrics/",
            params.tractometry_covariates ? params.tractometry_covariates.split(",").toList() : [],
            mergeCovariatesIntoMeta(ch_t1, ch_covariates).map { meta, _t1 -> meta }
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

def gitRevision(dir) {
    try {
        def p = ["git", "-C", dir.toString(), "rev-parse", "--short", "HEAD"].execute()
        p.waitFor()
        def rev = p.text.trim()
        if (p.exitValue() != 0 || !rev) return null
        def dirty = ["git", "-C", dir.toString(), "status", "--porcelain", "--untracked-files=no"].execute().text.trim()
        return dirty ? "${rev}-modified" : rev
    } catch (Exception ignored) {
        return null
    }
}

// Order of per-sample files in the global files: by file name, which starts with sid, session and
// run, so rows follow the samples whatever the task finishing order or work directory names.
// Accepts paths and the "<path>:::<path>" pairs of collectStatsFilesWithVolumes.
def bySampleFileName(a, b) {
    def name = { x -> new File(x.toString().split(':::')[0]).name }
    return name.call(a) <=> name.call(b) ?: a.toString() <=> b.toString()
}

// One item per distinct T1 file of a session: [first meta, every meta sharing it, t1]. A T1 shared
// by several DWI runs is processed once and its result given to every run. The key keeps subject
// and session, so a T1 file reused across subjects (copy, symlink, config typo) can never hand one
// subject's result to another.
def distinctT1s(ch_t1) {
    return ch_t1
        .map { meta, t1 -> [[meta.id, meta.session ?: "", t1.toString()], meta, t1] }
        .groupTuple()
        .map { _key, metas, t1s -> [metas[0], metas, t1s[0]] }
}

// Concatenate per-sample CSVs that share one header into <dir>/<name>, in file name order
// (sid, session, run), so the global file is the same from run to run.
def collectSampleCsvs(ch_csvs, String name, String dir) {
    return ch_csvs
        .map { _meta, csv -> csv }
        .collectFile(storeDir: dir, name: name, skip: 1, keepHeader: true, sort: { csv -> csv.name })
}

// Sample key used by the volume checks: subject, session, bare run number (absent run = 1)
def volumeSampleKey(meta) {
    return [meta.id, meta.session ?: "", (meta.run ?: "run-1").toString().replaceFirst(/^run-/, "")]
}

// Scanner of a T1 from its BIDS sidecar (<image>.json next to it, or next to the file it links
// to): manufacturer, model and field strength. Empty when there is no sidecar.
def t1Scanner(t1) {
    def path = java.nio.file.Paths.get(t1.toString())
    def candidates = [path, java.nio.file.Paths.get(realPathString(t1))].unique()
    def json = candidates
        .collect { c -> c.resolveSibling(c.fileName.toString().replaceFirst(/\.nii(\.gz)?$/, ".json")) }
        .find { j -> java.nio.file.Files.isRegularFile(j) }
    if (!json) return ""
    try {
        def side = new groovy.json.JsonSlurper().parse(json.toFile())
        def field = side.MagneticFieldStrength ? "${side.MagneticFieldStrength}T" : null
        return [side.Manufacturer, side.ManufacturersModelName, field].findAll { x -> x }.join(" ")
    } catch (Exception ignored) {
        return ""
    }
}

def realPathString(t1) {
    try {
        return java.nio.file.Paths.get(t1.toString()).toRealPath().toString()
    } catch (Exception ignored) {
        return t1.toString()
    }
}

def fileMd5(path) {
    def digest = java.security.MessageDigest.getInstance("MD5")
    new File(realPathString(path)).eachByte(1 << 20) { buffer, n -> digest.update(buffer, 0, n) }
    return digest.digest().encodeHex().toString()
}

// Decompressed stream of an image (.nii or .nii.gz, detected from the gzip magic bytes)
def openImageStream(path) {
    def raw = new BufferedInputStream(new FileInputStream(realPathString(path)), 1 << 16)
    raw.mark(2)
    def gzip = raw.read() == 0x1f && raw.read() == 0x8b
    raw.reset()
    return gzip ? new BufferedInputStream(new java.util.zip.GZIPInputStream(raw, 1 << 16), 1 << 16) : raw
}

// Reads the NIfTI-1/2 header at the start of the stream and leaves the stream at the first voxel.
// Returns the shape and datatype as a string, or null when the file is not a readable NIfTI.
def readNiftiShape(InputStream stream) {
    def header = stream.readNBytes(348)
    if (header.length < 348) return null
    def buf = java.nio.ByteBuffer.wrap(header).order(java.nio.ByteOrder.LITTLE_ENDIAN)
    if (buf.getInt(0) != 348 && buf.getInt(0) != 540) buf.order(java.nio.ByteOrder.BIG_ENDIAN)
    if (buf.getInt(0) == 348) {
        def offset = Math.max(352L, buf.getFloat(108) as long)
        stream.skipNBytes(offset - 348)
        return (["nifti1", buf.getShort(70)] + (0..7).collect { i -> buf.getShort(40 + 2 * i) }).join("x")
    }
    if (buf.getInt(0) == 540) {
        def rest = stream.readNBytes(540 - 348)
        if (rest.length < 540 - 348) return null
        def buf2 = java.nio.ByteBuffer.allocate(540).put(header).put(rest).order(buf.order())
        def offset = Math.max(544L, buf2.getLong(168))
        stream.skipNBytes(offset - 540)
        return (["nifti2", buf2.getShort(12)] + (0..7).collect { i -> buf2.getLong(16 + 8 * i) }).join("x")
    }
    return null
}

// Cheap key read from the header only: images that differ in it cannot hold the same voxels
def imageShapeKey(path) {
    try {
        def shape = openImageStream(path).withCloseable { stream -> readNiftiShape(stream) }
        return shape ?: "file:${new File(realPathString(path)).length()}"
    } catch (Exception ignored) {
        return "file:${new File(realPathString(path)).length()}"
    }
}

// Fingerprint of the image content: shape, datatype and MD5 of the voxel data only. Two exports of
// one acquisition often differ in the header (affine rounding, description) or in the gzip stream
// while holding the same voxels, and hashing the file bytes misses them. Falls back to the file
// MD5 when the file is not a readable NIfTI.
def imageContentHash(path) {
    try {
        def hash = openImageStream(path).withCloseable { stream ->
            def shape = readNiftiShape(stream)
            if (!shape) return null
            def digest = java.security.MessageDigest.getInstance("MD5")
            stream.transferTo(new java.security.DigestOutputStream(OutputStream.nullOutputStream(), digest))
            return shape + ":" + digest.digest().encodeHex().toString()
        }
        return hash ?: "file:" + fileMd5(path)
    } catch (Exception ignored) {
        return "file:" + fileMd5(path)
    }
}

// Annotate every [meta, t1] with meta.scanner and meta.duplicate_of. A T1 is a duplicate when its
// voxels are identical to the T1 of another subject/session (e.g. run-02 exported twice from one
// acquisition): it would be counted as an independent measurement. Files are grouped by image shape
// first, so only candidates that could match are hashed. The same file shared by several DWI runs
// of one session is not a duplicate. Returns [original meta, annotated meta, t1] for each item.
def annotateT1s(List items) {
    def byShape = items.groupBy { item -> imageShapeKey(item[1]) }
    def duplicateOf = [:]   // real path -> sample label of the first file with the same content
    byShape.values().findAll { group -> group.collect { item -> realPathString(item[1]) }.unique().size() > 1 }.each { group ->
        def byHash = group.collect { item -> realPathString(item[1]) }.unique().groupBy { path -> imageContentHash(path) }
        byHash.values().findAll { paths -> paths.size() > 1 }.each { paths ->
            def labels = paths.collectEntries { path ->
                def m = group.find { item -> realPathString(item[1]) == path }[0]
                [(path): [m.id, m.session, m.run].findAll { x -> x }.join("_")]
            }
            def first = paths.min { path -> labels[path] }
            paths.findAll { path -> path != first }.each { path -> duplicateOf[path] = labels[first] }
        }
    }
    return items.collect { meta, t1 ->
        def annotated = meta + [scanner: t1Scanner(t1), duplicate_of: duplicateOf.getOrDefault(realPathString(t1), "")]
        [meta, annotated, t1]
    }
}

// Startup-time warnings about the T1s: duplicates, and subjects scanned on several scanners
// (a scanner change shifts volumes by itself and must be modelled as a covariate).
def warnT1Annotations(List items) {
    def duplicates = items.collect { item -> item[1] }.findAll { m -> m.duplicate_of }
        .collect { m -> "${[m.id, m.session, m.run].findAll { x -> x }.join('_')} = ${m.duplicate_of}" }.unique()
    if (duplicates) {
        log.warn "${duplicates.size()} T1 image(s) hold the same voxels as another sample's T1 " +
                 "(e.g. ${duplicates.take(3).join('; ')}). They are not independent measurements: their volume rows " +
                 "carry duplicate_of and the qc flag 'duplicate'. Exclude them from repeatability or atrophy statistics."
    }
    def multi = items.collect { item -> item[1] }.groupBy { m -> m.id }
        .findAll { _id, metas -> metas*.scanner.findAll { x -> x }.unique().size() > 1 }
    if (multi) {
        log.warn "${multi.size()} subject(s) were scanned on several scanners across sessions " +
                 "(e.g. ${multi.keySet().take(3).join(', ')}: ${multi.values()[0]*.scanner.unique().join(' / ')}). " +
                 "A scanner change shifts volumes on its own: use the 'scanner' column as a covariate."
    }
}

// Report sessions that have no volumes of one type: written to <outdir>/volumes_missing_samples.txt,
// then a pipeline error unless allowMissing.
def checkVolumeCoverage(String type, ch_volumes, ch_expected_sessions, String outdir, boolean allowMissing) {
    ch_volumes
        .map { meta, _f -> volumeSampleKey(meta)[0..1] }
        .unique()
        .toList()
        .map { got -> [got: got] }
        .combine(ch_expected_sessions.map { expected -> [expected: expected] })
        .subscribe { got_item, expected_item ->
            def missing = (expected_item.expected - got_item.got).collect { k -> k.findAll { x -> x }.join("_") }.sort()
            if (!missing) return
            def report = new File("${outdir}/volumes_missing_samples.txt")
            report.parentFile.mkdirs()
            report << missing.collect { m -> "${type}\t${m}" }.join("\n") + "\n"
            def message = "${missing.size()} session(s) have no ${type} volumes (e.g. ${missing.take(5).join(', ')}): their " +
                          "segmentation or volume task failed or had no input. Listed in ${report}."
            if (allowMissing) {
                log.warn message
            } else {
                log.error message + " Fix them, or set allow_missing_volumes = true to accept incomplete volume files."
                throw new IllegalStateException("Missing ${type} volumes for ${missing.size()} session(s)")
            }
        }
}

// Nextflow 26.x channel serialization strips the leading '/' from Path objects that cross
// a .collect() boundary. Relative paths (e.g. --outdir ./foo) are resolved against the JVM CWD.
def toAbsFile(p) {
    def s = p.toString()
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
        .collect(sort: { a, b -> bySampleFileName(a, b) })
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
// The volumes CSV names its ROI column "roi" in both modes; the legacy "region" (GM/CSF)
// and "bundle" (WM) headers are still accepted so older CSVs keep merging.
// regionType behaves the same as in collectStatsFiles (String, Map, or null).
// volumeSource: when set ('atlas', 'synthseg', 'freesurfer'), volume_source and icv_mm3 columns
// are appended too. Values come from the volumes CSV when it has them (subject segmentation),
// otherwise volume_source falls back to volumeSource and icv_mm3 is left empty.
def collectStatsFilesWithVolumes(ch_stats_files, ch_volumes, name, storeDir, regionType = null, volumeSource = null) {

    def output_file_path = "${storeDir}/${name}"

    // Pair on (id, session, run), not on the whole meta: subject-segmentation volumes carry the
    // T1 meta, which lacks the covariates the stats meta carries. An absent run is run 1. When no
    // volume CSV has the stats' run (SAMSEG keeps one T1 per session), the session's CSV is used:
    // it measures the same session.
    def runKey = { r ->
        def bare = (r ?: "").toString().replaceFirst(/^run-/, "").replaceFirst(/^0+/, "")
        bare ?: "1"
    }
    def bySession = { meta, f -> [[meta.id, meta.session ?: ""], runKey.call(meta.run), toAbsFile(f.toString()).absolutePath] }
    def ch_stats_keyed = ch_stats_files.map(bySession)
    def ch_paired = ch_stats_keyed
        .combine(ch_volumes.map(bySession), by: 0)
        .map { key, stats_run, stats_file, vol_run, vol_file -> [[key, stats_run, stats_file], vol_run, vol_file] }
        .groupTuple()
        .map { stats_key, vol_runs, vol_files ->
            def i = vol_runs.indexOf(stats_key[1])
            // Paths encoded as one string BEFORE collect so no Path objects cross the
            // collect boundary (Nextflow channel serialisation corrupts them).
            "${stats_key[2]}:::${vol_files[i >= 0 ? i : 0]}"
        }
    // A sample with stats but no volume CSV (e.g. its segmentation failed and was ignored) keeps
    // its stats rows, with empty volume columns, instead of silently disappearing.
    def ch_vol_sessions = ch_volumes
        .map { meta, _f -> [meta.id, meta.session ?: ""] }
        .unique()
        .toList()
        .map { keys -> [sessions: keys] }
    def ch_unpaired = ch_stats_keyed
        .combine(ch_vol_sessions)
        .filter { key, _run, _stats_file, vols -> !(key in vols.sessions) }
        .map { _key, _run, stats_file, _vols -> "${stats_file}:::" }
    return ch_paired
        .mix(ch_unpaired)
        .collect(sort: { a, b -> bySampleFileName(a, b) })
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
            def QC_COLS = ["qc_score", "qc_flags", "scanner", "duplicate_of"]
            if (volumeSource != null) {
                all_columns.add("volume_source")
                all_columns.add("icv_mm3")
                QC_COLS.each { c -> all_columns.add(c) }
            }
            all_columns = all_columns.toList()

            def output_file = new File(output_file_path).absoluteFile
            output_file.getParentFile().mkdirs()
            def fw = output_file.newWriter()

            encoded_pairs.each { encoded ->
                def parts    = encoded.toString().split(':::')
                def stats_f  = new File(parts[0])
                def vols_f   = parts.size() > 1 && parts[1] ? new File(parts[1]) : null

                def stats_lines = stats_f.readLines()
                if (stats_lines.size() < 2) return

                def stats_cols = stats_lines[0].split('\t').toList()
                def stats_idx  = stats_cols.withIndex().collectEntries { c, i -> [c, i] }

                def vol_map = [:]
                def vol_lines = vols_f ? vols_f.readLines() : []
                if (vol_lines.size() >= 2) {
                    def vol_cols = vol_lines[0].split(',').toList()
                    def roi_col  = vol_cols.find { it in ["roi", "region", "bundle"] }
                    def roi_i    = vol_cols.indexOf(roi_col)
                    def vox_i    = vol_cols.indexOf("volume_voxels")
                    def mm3_i    = vol_cols.indexOf("volume_mm3")
                    def src_i    = vol_cols.indexOf("volume_source")
                    def icv_i    = vol_cols.indexOf("icv_mm3")
                    def qc_i     = QC_COLS.collect { c -> vol_cols.indexOf(c) }
                    vol_lines[1..-1].each { line ->
                        if (!line.trim()) return
                        def v = line.split(',', -1)
                        def src = (src_i >= 0 && src_i < v.size()) ? v[src_i] : (volumeSource ?: "")
                        def icv = (icv_i >= 0 && icv_i < v.size()) ? v[icv_i] : ""
                        def qc  = qc_i.collect { i -> (i >= 0 && i < v.size()) ? v[i] : "" }
                        vol_map[v[roi_i]] = [v[vox_i], v[mm3_i], src, icv] + qc
                    }
                }

                if (!header_written) {
                    log.debug("Writing header with columns: ${all_columns.join(', ')}")
                    fw.write(all_columns.join('\t') + '\n')
                    header_written = true
                }

                def stats_rois = [] as Set
                stats_lines[1..-1].each { line ->
                    if (!line.trim()) return
                    def vals = line.split('\t', -1)
                    def roi  = stats_idx.containsKey("roi") ? vals[stats_idx["roi"]] : ""
                    stats_rois << roi
                    def rt   = regionType instanceof Map ? regionType.getOrDefault(roi, "") : (regionType ?: "")
                    def vd   = vol_map.getOrDefault(roi, [""] * (4 + QC_COLS.size()))
                    def row  = all_columns.collect { col ->
                        if (col == "region_type")   return rt
                        if (col == "volume_voxels") return vd[0]
                        if (col == "volume_mm3")    return vd[1]
                        if (col == "volume_source") return vd[2]
                        if (col == "icv_mm3")       return vd[3]
                        if (col in QC_COLS)         return vd[4 + QC_COLS.indexOf(col)]
                        stats_idx.containsKey(col) ? (stats_idx[col] < vals.size() ? vals[stats_idx[col]] : '') : ''
                    }
                    fw.write(row.join('\t') + '\n')
                }

                // Subject segmentations can have regions the atlas stats lack (SAMSEG cortex totals
                // instead of the IIT Desikan parcels): keep them as volume-only rows rather than
                // dropping them. Atlas volumes keep the previous output unchanged.
                if (volumeSource != null && volumeSource != "atlas") {
                    def first = stats_lines[1].split('\t', -1)
                    vol_map.findAll { roi, _vd -> !(roi in stats_rois) }.each { roi, vd ->
                        def rt  = regionType instanceof Map ? regionType.getOrDefault(roi, "") : (regionType ?: "")
                        def row = all_columns.collect { col ->
                            if (col in ["sid", "session", "run"]) return stats_idx.containsKey(col) ? first[stats_idx[col]] : ''
                            if (col == "roi")           return roi
                            if (col == "region_type")   return rt
                            if (col == "volume_voxels") return vd[0]
                            if (col == "volume_mm3")    return vd[1]
                            if (col == "volume_source") return vd[2]
                            if (col == "icv_mm3")       return vd[3]
                            if (col in QC_COLS)         return vd[4 + QC_COLS.indexOf(col)]
                            ''
                        }
                        fw.write(row.join('\t') + '\n')
                    }
                }
            }

            fw.close()
            return output_file.toPath()
        }
}

// Collect per-subject volume CSVs into one global CSV with a volume_source and an icv_mm3
// column. Subject-segmentation CSVs already carry both; atlas CSVs (STATS_ROIVOLUMES) get
// volume_source = volumeSource and an empty icv_mm3. Replaces a plain collectFile so the global
// file says where its volumes come from whichever source produced it.
//
// Also carried: qc_score, qc_flags, scanner, duplicate_of (subject segmentations) and
// pipeline_revision (the code that produced the file, so results of different versions are never
// mixed unknowingly). The intracranial volume is constant in adults: a session whose ICV differs
// from its subject's median by more than icvDrift (fraction) gets the 'icv_drift' flag, which
// catches failed segmentations and scanner-induced shifts.
def collectVolumeFiles(ch_volumes, name, storeDir, volumeSource, icvDrift = 0.03, revision = "") {

    def output_file_path = "${storeDir}/${name}"
    def out_cols = ["sid", "session", "run", "roi", "volume_voxels", "volume_mm3", "volume_source", "icv_mm3",
                    "qc_score", "qc_flags", "scanner", "duplicate_of", "pipeline_revision"]

    return ch_volumes
        .map { _meta, csv -> toAbsFile(csv.toString()).absolutePath }
        .collect()
        .map { path_strings ->
            def rows = []
            path_strings.each { path_str ->
                def lines = new File(path_str.toString()).readLines()
                if (lines.size() < 2) {
                    log.warn("No data rows in file ${path_str}. Skipping.")
                    return
                }
                def cols = lines[0].split(',').toList()
                // Legacy STATS_ROIVOLUMES headers named the ROI column bundle/region
                def roi_col = cols.find { it in ["roi", "region", "bundle"] }
                lines[1..-1].each { line ->
                    if (!line.trim()) return
                    def vals = line.split(',', -1)
                    def value = { col ->
                        def i = cols.indexOf(col == "roi" ? roi_col : col)
                        (i >= 0 && i < vals.size()) ? vals[i] : null
                    }
                    rows << out_cols.collect { col ->
                        def v = value.call(col)
                        if (col == "pipeline_revision") return revision ?: ""
                        (v == null && col == "volume_source") ? volumeSource : (v ?: "")
                    }
                }
            }

            // ICV drift within a subject (needs every session, so done here)
            def icv_i = out_cols.indexOf("icv_mm3"); def flags_i = out_cols.indexOf("qc_flags")
            rows.groupBy { row -> row[0] }.each { _sid, subject_rows ->
                def per_session = subject_rows.findAll { row -> row[icv_i] }
                    .collectEntries { row -> [(row[1..2].join("_")): row[icv_i] as double] }
                if (per_session.size() < 2) return
                def sorted = per_session.values().sort()
                def mid = sorted.size().intdiv(2)
                def median = sorted.size() % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
                subject_rows.each { row ->
                    def icv = per_session[row[1..2].join("_")]
                    if (icv != null && Math.abs(icv / median - 1) > icvDrift) {
                        row[flags_i] = [row[flags_i], "icv_drift"].findAll { x -> x }.join(";")
                    }
                }
            }

            def output_file = new File(output_file_path).absoluteFile
            output_file.getParentFile().mkdirs()
            output_file.withWriter { fw ->
                fw.write(out_cols.join(',') + '\n')
                // Stable sort on the subject key only, so rows keep the LUT order within a subject
                rows.sort { a, b -> a[0..2].join(',') <=> b[0..2].join(',') }.each { row -> fw.write(row.join(',') + '\n') }
            }
            return output_file.toPath()
        }
}

// Merge WM bundle stats, GM region stats, CSF region stats, and optional volumes into one
// wide TSV where each row is a (subject × ROI) and each metric is a column.
//
// Encoded items in ch_files:
//   "STATS_WM_bundle:::abs_path"  — TSV: rows=bundles, cols=metrics (fa, md, …)
//   "STATS_GM_region:::abs_path"  — TSV: rows=GM regions, cols=metrics
//   "STATS_CSF_region:::abs_path" — TSV: rows=CSF regions, cols=metrics
//   "VOLS_WM_bundle:::abs_path"   — CSV: sid,session,run,roi,volume_voxels,volume_mm3
//   "VOLS_GM_region:::abs_path"   — CSV: sid,session,run,roi,volume_voxels,volume_mm3
//   "VOLS_CSF_region:::abs_path"  — CSV: sid,session,run,roi,volume_voxels,volume_mm3
//   VOLS_* CSVs may also carry volume_source and icv_mm3 (collectVolumeFiles); both are kept.
//
// Output schema: sid  session  run  roi  region_type  [covariates]  [metrics as cols]
//
// ch_cov_metas: metas carrying the participants.tsv covariates. Volume CSVs have no covariate
// columns, so a sample whose rows are all volumes takes its covariates from there.
def collectUnifiedFiles(ch_files, name, storeDir, List covariate_cols = [], ch_cov_metas = channel.empty()) {

    def output_file_path = "${storeDir}/${name}"
    def cov_set          = covariate_cols as Set
    // Covers both old format (sample, roi) and new module format (sid, session, run, roi)
    def FIXED_COLS       = ["sample", "sid", "session", "run", "roi", "region_type"] as Set

    // Wrapped in maps so combine() does not spread the two lists into one tuple
    def ch_cov_lookup = ch_cov_metas
        // Same run convention as the stats and volume CSVs: bare number, absent = 1
        .map { m -> [[m.id, m.session ?: "", (m.run ?: "run-1").replaceFirst(/^run-/, "")].findAll { x -> x }.join("_"),
                     covariate_cols.collectEntries { c -> [(c): m[c] != null ? m[c].toString() : ""] }] }
        .toList()
        .map { pairs -> [cov: pairs.collectEntries { p -> [(p[0]): p[1]] }] }

    return ch_files
        .collect()
        .map { encoded -> [files: encoded] }
        .combine(ch_cov_lookup)
        .map { files_item, cov_item ->
            def encoded_list = files_item.files
            def cov_lookup   = cov_item.cov

            def subjects    = new LinkedHashSet<String>()
            def all_metrics = new LinkedHashSet<String>()
            def wm_bundles  = new LinkedHashSet<String>()
            def gm_regions  = new LinkedHashSet<String>()
            def csf_regions = new LinkedHashSet<String>()

            // data[subject_key][roi][metric] = value_string
            def data     = [:]
            def cov_data = [:]  // subject_key → covariate col → value
            // subject_key → [sid, session, run] as actually read from the input files.
            // Stored directly rather than re-derived later from the joined sample string
            // (regex-matching sid-/ses-/run- prefixes back out of it) -- that reconstruction
            // is fragile by construction: it silently breaks the moment any of those values
            // don't carry the prefix it looks for (e.g. a bare run number instead of "run-N").
            def sample_meta = [:]

            encoded_list.each { encoded ->
                def parts = encoded.toString().split(':::')
                def type  = parts[0]
                def f     = new File(parts[1])
                def lines = f.readLines()
                if (lines.size() < 2) {
                    log.warn("collectUnifiedFiles: no data rows in ${f}, skipping")
                    return
                }

                if (type in ["STATS_WM_bundle", "STATS_GM_region", "STATS_CSF_region"]) {
                    def cols    = lines[0].split('\t').toList()
                    // New module outputs sid/session/run/roi; old format used sample/roi — handle both
                    def sid_idx = cols.indexOf("sid")
                    def ses_idx = cols.indexOf("session")
                    def run_idx = cols.indexOf("run")
                    def sam_idx = cols.indexOf("sample")
                    def roi_idx = cols.indexOf("roi")

                    // Identify data columns (not fixed, not covariates)
                    def data_indices = []
                    def data_names   = []
                    cols.eachWithIndex { col, idx ->
                        if (!(col in FIXED_COLS) && !(col in cov_set)) {
                            data_indices << idx
                            data_names   << col
                        }
                    }
                    def cov_indices = covariate_cols.collect { c -> cols.indexOf(c) }

                    all_metrics.addAll(data_names)

                    lines[1..-1].each { line ->
                        if (!line.trim()) return
                        def vals = line.split('\t', -1)

                        // Reconstruct subject key from sid+session+run (new format) or sample (old format)
                        def sample
                        if (sid_idx >= 0) {
                            def sid  = (sid_idx < vals.size()) ? vals[sid_idx] : ""
                            def ses  = (ses_idx >= 0 && ses_idx < vals.size()) ? vals[ses_idx] : ""
                            def run_ = (run_idx >= 0 && run_idx < vals.size()) ? vals[run_idx] : ""
                            sample = [sid, ses, run_].findAll { it }.join("_")
                            // Store the actual values read, not a format re-derived from `sample`
                            // later (see sample_meta declaration above for why).
                            if (!sample_meta.containsKey(sample)) {
                                sample_meta[sample] = [sid: sid, session: ses, run: run_]
                            }
                        } else {
                            sample = (sam_idx >= 0 && sam_idx < vals.size()) ? vals[sam_idx] : ""
                        }
                        def roi = (roi_idx >= 0 && roi_idx < vals.size()) ? vals[roi_idx] : ""

                        if (!data.containsKey(sample))     data[sample]     = [:]
                        if (!cov_data.containsKey(sample)) cov_data[sample] = [:]
                        subjects.add(sample)

                        // Store covariate values for this subject
                        covariate_cols.eachWithIndex { cov, ci ->
                            def idx = cov_indices[ci]
                            if (!cov_data[sample].containsKey(cov)) {
                                cov_data[sample][cov] = (idx >= 0 && idx < vals.size()) ? vals[idx] : ""
                            }
                        }

                        // Add ROI to its type-specific set and store metric values keyed by roi
                        if (type == "STATS_WM_bundle")       wm_bundles.add(roi)
                        else if (type == "STATS_GM_region")  gm_regions.add(roi)
                        else                                 csf_regions.add(roi)

                        if (!data[sample].containsKey(roi)) data[sample][roi] = [:]
                        data_names.eachWithIndex { metric, mi ->
                            def idx = data_indices[mi]
                            def val = (idx < vals.size()) ? vals[idx] : ""
                            data[sample][roi][metric] = val
                        }
                    }

                } else if (type in ["VOLS_WM_bundle", "VOLS_GM_region", "VOLS_CSF_region"]) {
                    def cols    = lines[0].split(',').toList()
                    def sid_idx = cols.indexOf("sid")
                    def ses_idx = cols.indexOf("session")
                    def run_idx = cols.indexOf("run")
                    def roi_col = cols.find { it in ["roi", "bundle", "region"] }
                    def roi_idx = roi_col ? cols.indexOf(roi_col) : -1
                    def vox_idx = cols.indexOf("volume_voxels")
                    def mm3_idx = cols.indexOf("volume_mm3")
                    // Carried as is: provenance and QC columns of the volume CSVs
                    def extra = ["volume_source", "icv_mm3", "qc_score", "qc_flags", "scanner", "duplicate_of", "pipeline_revision"]
                        .collectEntries { c -> [(c): cols.indexOf(c)] }.findAll { _c, i -> i >= 0 }

                    all_metrics.addAll(["volume_voxels", "volume_mm3"])
                    all_metrics.addAll(extra.keySet())

                    lines[1..-1].each { line ->
                        if (!line.trim()) return
                        def vals   = line.split(',', -1)
                        def sid    = (sid_idx >= 0 && sid_idx < vals.size()) ? vals[sid_idx] : ""
                        def ses    = (ses_idx >= 0 && ses_idx < vals.size()) ? vals[ses_idx] : ""
                        def run    = (run_idx >= 0 && run_idx < vals.size()) ? vals[run_idx] : ""
                        def sample = [sid, ses, run].findAll { it }.join("_")
                        if (!sample_meta.containsKey(sample)) {
                            sample_meta[sample] = [sid: sid, session: ses, run: run]
                        }
                        def roi    = (roi_idx >= 0 && roi_idx < vals.size()) ? vals[roi_idx] : ""
                        def vox    = (vox_idx >= 0 && vox_idx < vals.size()) ? vals[vox_idx] : ""
                        def mm3    = (mm3_idx >= 0 && mm3_idx < vals.size()) ? vals[mm3_idx] : ""

                        if (!data.containsKey(sample))     data[sample]     = [:]
                        if (!cov_data.containsKey(sample)) cov_data[sample] = [:]
                        subjects.add(sample)
                        cov_lookup.getOrDefault(sample, [:]).each { cov, value ->
                            if (!cov_data[sample][cov]) cov_data[sample][cov] = value
                        }

                        if (type == "VOLS_WM_bundle")       wm_bundles.add(roi)
                        else if (type == "VOLS_GM_region")  gm_regions.add(roi)
                        else                                 csf_regions.add(roi)

                        if (!data[sample].containsKey(roi)) data[sample][roi] = [:]
                        data[sample][roi]["volume_voxels"] = vox
                        data[sample][roi]["volume_mm3"]    = mm3
                        extra.each { c, i -> if (i < vals.size()) data[sample][roi][c] = vals[i] }
                    }
                }
            }

            // Build roi_type_map: roi → "WM_bundle" / "GM_region" / "CSF_region"
            def roi_type_map = [:]
            wm_bundles.each  { roi -> roi_type_map[roi] = "WM_bundle" }
            gm_regions.each  { roi -> roi_type_map[roi] = "GM_region" }
            csf_regions.each { roi -> roi_type_map[roi] = "CSF_region" }

            // Build ordered ROI list: WM bundles first, then GM, then CSF
            def all_rois     = wm_bundles.toList() + gm_regions.toList() + csf_regions.toList()
            def all_m_sorted = all_metrics.sort().toList()
            def header       = ["sid", "session", "run", "roi", "region_type"] + covariate_cols + all_m_sorted

            def output_file = new File(output_file_path).absoluteFile
            output_file.getParentFile().mkdirs()
            def fw = output_file.newWriter()
            fw.write(header.join('\t') + '\n')

            subjects.sort().each { sample ->
                // Prefer the sid/session/run actually read from the input file
                // (sample_meta, populated above) over re-deriving them from the joined
                // `sample` string, which only works when every part still carries the
                // sub-/ses-/run- prefix it looks for -- true for the legacy "sample"
                // column format this regex fallback exists for, but not guaranteed for
                // any given value in the new sid/session/run column format (e.g. a bare
                // run number).
                def meta_here = sample_meta[sample]
                def sid
                def session
                def run
                if (meta_here) {
                    sid     = meta_here.sid ?: sample
                    session = meta_here.session ?: ""
                    run     = meta_here.run ?: ""
                } else {
                    def m_sub = (sample =~ /(?:^|_)(sub-[^_]+)/)
                    def m_ses = (sample =~ /(?:^|_)(ses-[^_]+)/)
                    def m_run = (sample =~ /(?:^|_)(run-[^_]+)/)
                    sid     = m_sub ? m_sub[0][1] : sample
                    session = m_ses ? m_ses[0][1] : ""
                    run     = m_run ? m_run[0][1] : ""
                }
                all_rois.each { roi ->
                    if (!data[sample]?.containsKey(roi)) return
                    def roi_data    = data[sample][roi]
                    def region_type = roi_type_map.getOrDefault(roi, "")
                    def covs        = covariate_cols.collect { cov -> cov_data[sample]?.get(cov) ?: "" }
                    def metric_vals = all_m_sorted.collect { metric -> roi_data?.get(metric) ?: "" }
                    fw.write(([sid, session, run, roi, region_type] + covs + metric_vals).join('\t') + '\n')
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
