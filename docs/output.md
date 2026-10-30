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

- `dwi/<subject>_atlas-iit-wm_desc-roi_stats.tsv` — FA/MD/RD/AD/AFD mean per WM bundle

**Globally collected:**

- `metrics/space-native_atlas-iit-wm_label-mean_desc-roi_stats.tsv` — all subjects merged

**Volumes** (enabled by `--run_wm_volumes` or `--run_roi_volumes`):

- `dwi/<subject>_atlas-iit-wm_desc-roi_volumes.csv` — voxel count and mm³ per bundle
- `metrics/space-native_atlas-iit-wm_desc-roi_volumes.csv` — all subjects merged

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

## Volume source

The GM, CSF and comparison volume files above are filled according to `--volume_source`:

- `atlas` (default): voxel count of the warped template in DWI space. The volumes reflect the registration and are not suited to measuring atrophy.
- `synthseg` / `freesurfer`: voxel count of the subject's own segmentation in native T1 space.
- `samseg_long` (`--run_longitudinal_volumes`): voxel count of the SAMSEG longitudinal segmentation, all sessions of a subject segmented jointly. The GM file holds cortex totals (`Left/Right-Cerebral-Cortex`) instead of the Desikan parcels. Per session: `anat/<subject>_<session>_desc-samseglong_dseg.nii.gz` and `_desc-samseglong_icv.csv`. The files keep their names, region names and columns, and add `volume_source` and `icv_mm3` (intracranial volume, `synthseg` only).

The global volume files (`metrics/...desc-roi_volumes.csv`) always carry `volume_source` and `icv_mm3`.

With `synthseg`, the segmentation itself is published per subject:

- `anat/<subject>_desc-synthseg_dseg.nii.gz` — SynthSeg labelmap with Desikan cortical parcels (native T1 space)
- `anat/<subject>_desc-synthseg_volumes.csv` — SynthSeg's own soft volumes, including total intracranial
- `anat/<subject>_desc-synthseg_qc.csv` — SynthSeg QC scores

## Diffusion metrics in the subject's own regions

With `--run_subject_roi_metrics true` (`<seg>` = `synthseg`, `freesurfer` or `samseg`):

- `dwi/<subject>_seg-<seg>_desc-roi_stats.tsv` — fraction-weighted mean of each metric per region, same layout as the GM file (`sid, session, run, roi, covariates..., metrics...`); `dwi/<subject>_seg-<seg>_label-std_desc-roi_stats.tsv` holds the standard deviations
- `dwi/<subject>_seg-<seg>_desc-roi_fractions.csv` — effective size of each region: `acq_voxels` (sum of the voxel fractions), `volume_mm3`, `in_mask_fraction`, the share of the region inside the DWI brain mask (the statistics use only that part; a low value, e.g. a frontal pole cut by the mask, means a less reliable region), and `small_region` (1 when `acq_voxels` is below `--subject_roi_small_region_voxels`, 50 by default: a mean over so few acquired voxels is noisy; a flag only)
- `metrics/space-native_seg-<seg>_label-mean_desc-roi_stats.tsv` and `metrics/space-native_seg-<seg>_desc-roi_fractions.csv` — all samples merged, `region_type = GM_subject`

These rows are not added to the combined TSV, which keys rows by region name: they would merge with the atlas GM rows of the same names.

## Cortical thickness

With `--run_cortical_thickness true`:

- `anat/freesurfer/<subject>/` — the FreeSurfer `recon-all` subject folder (surfaces, labels, stats), for visual checks
- `anat/<subject>_desc-thickness.csv` — one row per Desikan region: `sid, session, run, roi, thickness_mm, thickness_std_mm, surface_area_mm2, gm_volume_mm3, num_vertices, thickness_method, qc_flags`
- `metrics/space-native_desc-cortical-thickness.csv` — all samples merged

## Diffusion metrics on the cortical surface

With `--run_cortical_surface_metrics true`:

- `dwi/<subject>_surf-freesurfer_desc-roi_stats.tsv` — mean of each metric over the vertices of each Desikan region, sampled at mid-thickness: `sid, session, run, roi, covariates..., metrics..., n_vertices`; `dwi/<subject>_surf-freesurfer_label-std_desc-roi_stats.tsv` holds the standard deviations. A region with no vertex inside the DWI brain mask has no row.
- `metrics/space-native_surf-freesurfer_label-mean_desc-roi_stats.tsv` — all samples merged, `region_type = GM_surface`
- `anat/freesurfer/<subject>/` — the `recon-all` folder, as for the thickness

These rows are not added to the combined TSV (same region names as the atlas GM rows).

## Hippocampal occupancy score

With `--run_hoc true`:

- `anat/<subject>_desc-hoc.csv` — one row per `roi` (`Left`, `Right`, `Bilateral`): `sid, session, run, roi, hoc, hippocampus_mm3, inf_lat_vent_mm3, volume_source`. `hoc` is empty when the segmentation has neither structure.
- `metrics/space-native_desc-hoc.csv` — all samples merged

## Merged output (metrics and/or volumes)

Enabled by `--run_merge_all_stats`.

Produces a single TSV merging all available data across WM, GM, and CSF region types. For each region type:
- If metrics are enabled (with or without volumes): the collected stats TSV is used — this already includes volume columns when volumes are also enabled.
- If only volumes are enabled: the volume CSV is normalised (`bundle`/`region` → `roi`, `region_type` added) and included.

All inputs are merged with a union column set; cells missing in a particular region type's data are left empty.

- `metrics/space-native_all-regions_desc-roi_combined.tsv`
