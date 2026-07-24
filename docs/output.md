# sf-tractomics: Outputs

Output files are written to `--outdir` organised by subject (and session if present):

```
<outdir>/
  <subject_id>/
    [<session_id>/]
      dwi/          per-subject DWI outputs (preprocessed data, metrics, masks)
  metrics/          globally collected stats across all subjects
```

## WM bundle ROI metrics

Enabled by `--run_atlas_roimetrics` + `--run_wm_metrics` (or `--run_roi_metrics`).

Atlas: IIT Atlas v5.0 TDI bundle masks (41 bundles), registered to subject DWI space.

**Per-subject:**

- `dwi/<subject>_atlas-iit_desc-roi_stats.tsv` — FA/MD/RD/AD/AFD mean per WM bundle

**Globally collected:**

- `metrics/space-native_atlas-iit_label-mean_desc-roi_stats.tsv` — all subjects merged

**Volumes** (enabled by `--run_wm_volumes` or `--run_roi_volumes`):

- `dwi/<subject>_atlas-iit_desc-roi_volumes.csv` — voxel count and mm³ per bundle
- `metrics/space-native_atlas-iit_desc-roi_volumes.csv` — all subjects merged

## GM Desikan region ROI metrics

Enabled by `--run_atlas_roimetrics` + `--run_gm_metrics` (or `--run_roi_metrics`).

Atlas: IIT Atlas v5.0 GM Desikan parcellation. Covers 8 subcortical structures × 2 hemispheres and 33 cortical Desikan regions × 2 hemispheres.

**Per-subject:**

- `dwi/<subject>_atlas-iit-gm_desc-roi_stats.tsv` — FA/MD/RD/AD/AFD mean per GM region

**Globally collected:**

- `metrics/space-native_atlas-iit-gm_label-mean_desc-roi_stats.tsv` — all subjects merged

**Volumes** (enabled by `--run_gm_volumes` or `--run_roi_volumes`):

- `dwi/<subject>_atlas-iit-gm_desc-roi_volumes.csv` — voxel count and mm³ per region
- `metrics/space-native_atlas-iit-gm_desc-roi_volumes.csv` — all subjects merged

## CSF/ventricle ROI metrics

Enabled by `--run_csf_metrics` (or `--run_roi_metrics`).

Atlas: FreeSurfer `cvs_avg35_inMNI152` parcellation. Default Look-Up Table (LUT) covers 9 CSF/ventricle regions (lateral ventricles, inferior lateral ventricles, 3rd/4th ventricle, CSF, choroid plexus).

**Per-subject:**

- `dwi/<subject>_atlas-freesurfer-csf_desc-roi_stats.tsv` — FA/MD/RD/AD/AFD mean per CSF region

**Globally collected:**

- `metrics/space-native_atlas-freesurfer-csf_label-mean_desc-roi_stats.tsv` — all subjects merged

**Volumes** (enabled by `--run_csf_volumes` or `--run_roi_volumes`):

- `dwi/<subject>_atlas-freesurfer-csf_desc-roi_volumes.csv` — voxel count and mm³ per region
- `metrics/space-native_atlas-freesurfer-csf_desc-roi_volumes.csv` — all subjects merged

## Comparison output (GM subcortical + WM + ventricles)

Enabled by `--run_csf_comparison_roimetrics` and/or `--run_csf_comparison_volumes`.

Reuses the warped FreeSurfer atlas to extract metrics across GM subcortical structures, WM regions, and ventricles in the same reference frame. Useful for cross-tissue DTI metric comparisons.

**Per-subject:**

- `dwi/comparison/<subject>_atlas-freesurfer-comparison_desc-roi_stats.tsv`

**Globally collected:**

- `metrics/comparison/space-native_atlas-freesurfer-comparison_label-mean_desc-roi_stats.tsv`

**Volumes:**

- `dwi/comparison/<subject>_atlas-freesurfer-comparison_desc-roi_volumes.csv`
- `metrics/comparison/space-native_atlas-freesurfer-comparison_desc-roi_volumes.csv`

## Merged output (metrics and/or volumes)

Enabled by `--run_merge_all_stats`.

Produces a single TSV merging all available data across WM, GM, and CSF region types. For each region type:
- If metrics are enabled (with or without volumes): the collected stats TSV is used — this already includes volume columns when volumes are also enabled.
- If only volumes are enabled: the volume CSV is normalised (`bundle`/`region` → `roi`, `region_type` added) and included.

All inputs are merged with a union column set; cells missing in a particular region type's data are left empty.

- `metrics/space-native_all-regions_desc-roi_combined.tsv`
