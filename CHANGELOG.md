# scilus/sf-tractomics: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.0dev - 2026-07-25

Initial release of scilus/sf-tractomics, created with the [nf-core](https://nf-co.re/) template.

### `Added`

- `fwc_failed_fraction` in the subject-region fractions and the surface stats: share of each region on voxels where the free-water-corrected fit failed (AD, RD or MD set to 0 by scilpy's outlier removal), reported and not removed, so its link with diagnosis can be checked.
- `volume_icv_fraction` (volume / intracranial volume) next to `icv_mm3` in every volume file and table.
- `small_region` flag and `--subject_roi_small_region_voxels` (50) for subject regions covering few acquired DWI voxels.
- Warnings when free water is fitted on single-shell data and when cortical thickness is computed session by session on subjects with several sessions.
- `--run_cortical_surface_metrics` (default `false`): diffusion metrics of the cortex sampled on the FreeSurfer surfaces at mid-thickness and averaged per Desikan region (new `STATS_SURFACEMETRICS` module), sharing `recon-all` with `--run_cortical_thickness`, in `dwi/*_surf-freesurfer_desc-roi_stats.tsv` and `metrics/space-native_surf-freesurfer_label-mean_desc-roi_stats.tsv`.
- `--run_subject_roi_metrics` (default `false`) and `--subject_roi_min_fraction`: diffusion metrics in the subject's own GM regions, weighted by the fraction of each acquired DWI voxel inside the region (new `IMAGE_LABELFRACTION` module), in `dwi/*_seg-<seg>_desc-roi_stats.tsv` and `metrics/space-native_seg-<seg>_label-mean_desc-roi_stats.tsv`, with the effective region sizes in `*_desc-roi_fractions.csv`.
- `--run_cortical_thickness` (default `false`): FreeSurfer `recon-all` (nf-neuro `segmentation/fsreconall`) on each distinct T1, thickness, area, grey matter volume and vertex count per Desikan region in `anat/*_desc-thickness.csv` and `metrics/space-native_desc-cortical-thickness.csv`, with `coarse_t1` and `implausible:<regions>` QC flags.
- `--run_hoc` (default `false`): hippocampal occupancy score (hippocampus / (hippocampus + inferior lateral ventricle)), left, right and bilateral, from the subject's own segmentation, in `anat/*_desc-hoc.csv` and `metrics/space-native_desc-hoc.csv`.
- Volume quality control: `qc_score`, `qc_flags` (`qc_low`, `icv_missing`, `icv_implausible`, `icv_drift`, `empty:<regions>`, `duplicate`), `scanner`, `duplicate_of` and `pipeline_revision` columns; warnings for duplicate T1s (same voxel data, even when header or compression differ) and subjects scanned on several scanners; the run fails when a session has no volumes unless `--allow_missing_volumes` (`--volume_qc_threshold`, `--volume_icv_drift`). `WM-hypointensities` row in the comparison files.
- Label warps use `GenericLabel` instead of `MultiLabel`, which altered label volumes even under an identity transform.
- `--run_longitudinal_volumes` (default `false`): FreeSurfer SAMSEG longitudinal segmentation of all sessions of a subject for GM, CSF/ventricle and comparison volumes, written to the same files with `volume_source = samseg_long`. When volumes are requested on subjects with several sessions and the option is off, a startup warning says it is not activated.
- `--volume_source` (`atlas` | `synthseg` | `freesurfer`) to compute GM, CSF/ventricle and comparison volumes from the subject's own segmentation in native T1 space instead of a warped template. Same output files, plus `volume_source` and `icv_mm3` columns. A warning recommends a longitudinal method when subjects have several sessions. The atlas-only version is tagged `v1.0dev-atlas-volumes`.
- GM Desikan parcellation ROI metrics pipeline using IIT Atlas v5.0 (`--run_gm_metrics`, `--run_gm_volumes`).
- CSF/ventricle ROI metrics pipeline using FreeSurfer `cvs_avg35_inMNI152` atlas (`--run_csf_metrics`, `--run_csf_volumes`).
- Cross-tissue comparison output (GM subcortical + WM + ventricles) using the FreeSurfer atlas (`--run_csf_comparison_roimetrics`, `--run_csf_comparison_volumes`).
- ROI volume computation (voxel count + mm³) for WM, GM, and CSF regions via new `stats/roivolumes` module.
- Master param switches `--run_roi_metrics` and `--run_roi_volumes` to enable all region types at once.
- Per-type param switches `--run_wm_metrics`, `--run_gm_metrics`, `--run_csf_metrics`, `--run_wm_volumes`, `--run_gm_volumes`, `--run_csf_volumes`.
- `--run_merge_all_stats` option to merge all available metrics and/or volumes into a single file (`space-native_all-regions_desc-roi_combined.tsv`); uses the collected stats TSV when metrics are enabled (with volumes joined when both active), falls back to the volume CSV when only volumes are enabled.
- `region_type` column in all stats output files.
- `CLAUDE.md` codebase documentation.

### `Fixed`

- Region statistics (nf-neuro `stats/metricsinroi`) failed at random with exit status 141: `head -n 1` closed the pipe while `printf` was writing the region names. They are now read with `awk`.
- Subject-region diffusion metrics: voxels outside the DWI brain mask (where the maps are 0) kept their weight and pulled region means down (up to 15% of a frontal pole); they now get none, as in the atlas tables, and `in_mask_fraction` reports the share kept. Same correction for the surface sampling (maps masked before the warp, samples normalised by the mask).
- WM bundle volumes with `--use_binary_masks`: border voxels of the linearly warped masks counted as whole voxels (+40 to +125%); `stats/roivolumes` gets `ext.mask_volume` (`nonzero` | `fraction`).
- RECONST_FRF received no shell or b0 settings (it used DTI shells up to 1500 and fODF shells from 100), and the DTI fits no b0 threshold or shell tolerance; they now follow the pipeline parameters. A misnamed N4 setting that was never read was removed.
- Parameters set in a `-c` config file or in a profile (`test`, `iit_tractometry`, `legacy`, `full_pipeline`, `skip_preproc`) did not reach the module settings (`ext.*`): `conf/modules/*.config` copied them while `nextflow.config` was read, before those values were applied, so steps silently used the defaults (for example `max_dti_shell_value` 1200 instead of the value set). The module settings now read the parameters when each task runs. `outdir`, `publish_dir_mode` and `clean_output` still have to be given on the command line or in a `-params-file`.
- The per-sample WM, GM, CSF and comparison stats tables were published under one name for both the mean and the std table, so either could overwrite the other. The std table is now `*_label-std_desc-roi_stats.tsv`; the mean keeps its name.
- Global stats and stats+volumes files list samples in sid / session / run order; they followed work directory names before.
- `--run_t1_resampling` never reached TractoFlow: its option list and its code used different names, so the T1 was never resampled whatever the setting. Fixed; the default is now `false`, which keeps results identical to previous runs.
- Nextflow 26 compatibility: fixed dynamic `errorStrategy` closures, `_` placeholder variables in `preproc_t1`, and groovy import in `atlas_iit`.

### `Dependencies`

### `Deprecated`

- `--run_gm_roimetrics` replaced by `--run_gm_metrics`.
- `--run_csf_roimetrics` replaced by `--run_csf_metrics`.
