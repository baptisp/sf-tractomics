# scilus/sf-tractomics: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.0dev - 2026-07-25

Initial release of scilus/sf-tractomics, created with the [nf-core](https://nf-co.re/) template.

### `Added`

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

- `--run_t1_resampling` never reached TractoFlow: its option list and its code used different names, so the T1 was never resampled whatever the setting. Fixed; the default is now `false`, which keeps results identical to previous runs.
- Nextflow 26 compatibility: fixed dynamic `errorStrategy` closures, `_` placeholder variables in `preproc_t1`, and groovy import in `atlas_iit`.

### `Dependencies`

### `Deprecated`

- `--run_gm_roimetrics` replaced by `--run_gm_metrics`.
- `--run_csf_roimetrics` replaced by `--run_csf_metrics`.
