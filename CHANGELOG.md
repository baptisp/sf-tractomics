# scilus/sf-tractomics: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.0dev - [date]

Initial release of scilus/sf-tractomics, created with the [nf-core](https://nf-co.re/) template.

### `Added`

- GM Desikan parcellation ROI metrics pipeline using IIT Atlas v5.0 (`--run_gm_metrics`, `--run_gm_volumes`).
- CSF/ventricle ROI metrics pipeline using FreeSurfer `cvs_avg35_inMNI152` atlas (`--run_csf_metrics`, `--run_csf_volumes`).
- Cross-tissue comparison output (GM subcortical + WM + ventricles) using the FreeSurfer atlas (`--run_csf_comparison_roimetrics`, `--run_csf_comparison_volumes`).
- ROI volume computation (voxel count + mm³) for WM, GM, and CSF regions via new `stats/roivolumes` module.
- Master param switches `--run_roi_metrics` and `--run_roi_volumes` to enable all region types at once.
- Per-type param switches `--run_wm_metrics`, `--run_gm_metrics`, `--run_csf_metrics`, `--run_wm_volumes`, `--run_gm_volumes`, `--run_csf_volumes`.
- `--run_merge_all_stats` option to concatenate WM + GM + CSF stats into a single TSV with a `region_type` column.
- `--run_merge_all_volumes` option to merge all available metrics and/or volumes into a single file (`space-native_all-regions_desc-roi_combined.tsv`); uses the collected stats TSV when metrics are enabled (with volumes joined when both active), falls back to the volume CSV when only volumes are enabled.
- `region_type` column in all stats output files.
- `CLAUDE.md` codebase documentation.

### `Fixed`

- Nextflow 26 compatibility: fixed dynamic `errorStrategy` closures, `_` placeholder variables in `preproc_t1`, and groovy import in `atlas_iit`.

### `Dependencies`

### `Deprecated`

- `--run_gm_roimetrics` replaced by `--run_gm_metrics`.
- `--run_csf_roimetrics` replaced by `--run_csf_metrics`.
