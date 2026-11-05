# sf-tractomics: Outputs

Output files are written to `--outdir` organised by subject (and session if present):

```
<outdir>/
  <subject_id>/
    [<session_id>/]
      dwi/          per-subject DWI outputs (preprocessed data, metrics, masks)
  metrics/          globally collected stats across all subjects
```

- `metrics/dwi_input_report.tsv`: decision for every input DWI (kept, merged from split parts,
  skipped with its T1), with its shells, largest DTI shell, fODF volumes and the reason or
  warning; see [usage](usage.md#dwi-input-check).
- `dwi/<sample>_desc-concatenatedparts.csv`: for a sample built from split parts, each part's
  file, volumes, b0 volumes and the intensity scale applied to it.
- `dwi/<sample>_desc-fodfthreshold.csv`: the fODF peak threshold of the sample (`threshold`,
  `source` = `ventricles` or `fixed`) and the one its ventricles give (`ventricle_max`,
  `a_factor`, `ventricle_threshold`).

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

## Atlas registration QC

Written whenever an atlas is registered to a DWI run: the IIT atlas (`--run_atlas_roimetrics`, WM
bundles and GM regions) and the CSF atlas (CSF and comparison metrics or volumes). Each has its own
ANTs registration of the IIT mean b0 onto the run's b0, which places all of its regions; the check
compares the warped IIT b0 with that b0. A flagged run keeps its rows (nothing fails); the run log
lists the flagged runs.

- `dwi/<sample>_atlas-iit_desc-registration_qc.csv`, `dwi/<sample>_atlas-freesurfer-csf_desc-registration_qc.csv` — one row: `sid, session, run, registration` (`iit` or `csf`), `atlas_b0_corr` (correlation of the warped IIT b0 with the run's b0 inside the run's brain mask), `brain_dice` (Dice of the warped atlas brain, IIT b0 above 10 % of its mean, with the brain mask), `qc_flags`: `misaligned` (`atlas_b0_corr` < `--atlas_min_registration_corr`, 0.6), `brain_mismatch` (`brain_dice` < `--atlas_min_brain_dice`, 0.85), `empty`.
- `metrics/space-native_desc-atlasregistration_qc.csv` — all runs merged

On 4 OASIS-3 sessions `atlas_b0_corr` was 0.77–0.79 and `brain_dice` 0.94–0.95; the same warps
shifted by 2, 4 and 8 mm gave a correlation of 0.70, 0.54 and 0.34 (Dice 0.94, 0.93, 0.89). The
correlation catches a misplacement of a few millimetres, the Dice only a gross failure. The b0
contrast differs between scanners: check the distribution on a new cohort before trusting the
default threshold.

## Volume source

The GM, CSF and comparison volume files above are the atlas ones. `--volume_source` lists the sources (several, comma-separated, to compare them); each writes its own files:

- `atlas` (default): voxel count of the warped template in DWI space. The volumes reflect the registration and are not suited to measuring atrophy.
- `synthseg` / `reconall` / `freesurfer`: voxel count of the subject's own segmentation in native T1 space (`reconall`: `aparc+aseg` of the pipeline's recon-all), in `anat/<subject>_seg-<source>_label-{gm,csf}_desc-roi_volumes.csv`, `anat/comparison/<subject>_seg-<source>_label-comparison_desc-roi_volumes.csv` and, for all samples, `metrics/space-native_seg-<source>_label-{gm,csf}_desc-roi_volumes.csv` and `metrics/comparison/space-native_seg-<source>_label-comparison_desc-roi_volumes.csv`.
- `samseg_long` (`--run_longitudinal_volumes`): voxel count of the SAMSEG longitudinal segmentation, all sessions of a subject segmented jointly. The GM file holds cortex totals (`Left/Right-Cerebral-Cortex`) instead of the Desikan parcels. Per session: `anat/<subject>_<session>_desc-samseglong_dseg.nii.gz` and `_desc-samseglong_icv.csv`; volume files named `seg-samseg`. Every source's files have the same region names and columns, with `volume_source` and `icv_mm3` (intracranial volume: SynthSeg's, FreeSurfer eTIV with `reconall`, SAMSEG sbTIV; empty with `freesurfer`).

The global volume files (`metrics/...desc-roi_volumes.csv`) always carry `volume_source` and `icv_mm3`.

With `synthseg`, the segmentation itself is published per subject:

- `anat/<subject>_desc-synthseg_dseg.nii.gz` — SynthSeg labelmap with Desikan cortical parcels (native T1 space)
- `anat/<subject>_desc-synthseg_volumes.csv` — SynthSeg's own soft volumes, including total intracranial
- `anat/<subject>_desc-synthseg_qc.csv` — SynthSeg QC scores

With `reconall`, per subject:

- `anat/<subject>_desc-reconall_dseg.nii.gz` — recon-all `aparc+aseg` (1 mm conformed grid, T1 world coordinates)
- `anat/<subject>_desc-reconall_icv.csv` — FreeSurfer eTIV, the `icv_mm3` of the volume files
- `anat/freesurfer/<subject>/` — the recon-all directory (also with `--run_cortical_thickness`)

With `--run_hippocampal_subfields true` (on the same recon-all):

- `anat/<subject>_seg-reconall_desc-hippoamyg_volumes.csv` — hippocampal subfields and amygdala nuclei per side (`sid, session, run, roi, structure, volume_mm3, volume_source, icv_mm3, volume_icv_fraction, t1_shared_with`; `roi` = `Left-CA1-head`, `Right-Whole_amygdala`...)
- `anat/freesurfer/<subject>_hippoamyg/` — `segment_subregions` label maps and volume tables
- `metrics/space-native_seg-reconall_desc-hippoamyg_volumes.csv` — all samples merged

## Diffusion metrics in the subject's own regions

With `--run_subject_roi_metrics true`, on the first subject source of `volume_source` (`<seg>` = `synthseg`, `reconall`, `freesurfer` or `samseg`):

- `dwi/<subject>_seg-<seg>_desc-roi_stats.tsv` — fraction-weighted mean of each metric per region, same layout as the GM file (`sid, session, run, roi, covariates..., metrics...`); `dwi/<subject>_seg-<seg>_label-std_desc-roi_stats.tsv` holds the standard deviations
- `dwi/<subject>_seg-<seg>_desc-roi_fractions.csv` — effective size of each region: `acq_voxels` (sum of the voxel fractions), `volume_mm3`, `in_mask_fraction`, the share of the region inside the DWI brain mask (the statistics use only that part; a low value, e.g. a frontal pole cut by the mask, means a less reliable region), and `small_region` (1 when `acq_voxels` is below `--subject_roi_small_region_voxels`, 50 by default: a mean over so few acquired voxels is noisy; a flag only), and `fwc_failed_fraction` (with free water: share of the region's weight on brain voxels where the free-water-corrected fit failed and scilpy set AD, RD or MD to 0; these zeros stay in the `adt`, `rdt`, `mdt` means, which they lower by about that share; empty without free water)
- `metrics/space-native_seg-<seg>_label-mean_desc-roi_stats.tsv` and `metrics/space-native_seg-<seg>_desc-roi_fractions.csv` — all samples merged, `region_type = GM_subject`

In the combined TSV they are rows of their own source (`source = <seg>`), with that segmentation's GM volumes; they never merge with the atlas GM rows of the same names.

## Cortical thickness

With `--run_cortical_thickness true`:

- `anat/freesurfer/<subject>/` — the FreeSurfer `recon-all` subject folder (surfaces, labels, stats), for visual checks
- `anat/<subject>_desc-thickness.csv` — one row per Desikan region: `sid, session, run, roi, thickness_mm, thickness_std_mm, surface_area_mm2, gm_volume_mm3, num_vertices, thickness_method, qc_flags`
- `metrics/space-native_desc-cortical-thickness.csv` — all samples merged

## Diffusion metrics on the cortical surface

With `--run_cortical_surface_metrics true`:

- `dwi/<subject>_surf-freesurfer_desc-roi_stats.tsv` — mean of each metric over the vertices of each Desikan region, sampled at mid-thickness: `sid, session, run, roi, covariates..., metrics..., fwc_failed_fraction, n_vertices` (`fwc_failed_fraction`: mean share of the samples from voxels where the free-water-corrected fit failed, as in the fractions file); `dwi/<subject>_surf-freesurfer_label-std_desc-roi_stats.tsv` holds the standard deviations. A region with no vertex inside the DWI brain mask has no row.
- `metrics/space-native_surf-freesurfer_label-mean_desc-roi_stats.tsv` — all samples merged, `region_type = GM_surface`
- `anat/freesurfer/<subject>/` — the `recon-all` folder, as for the thickness

These rows are not added to the combined TSV (same region names as the atlas GM rows).

## Fibre cross-section

With `--fc_build_template true`:

- `fc_template/` — the study template, given to later runs with `--fc_template`: `fod_template.mif`, `template_mask.mif`, `template_b0.nii.gz` (mean b0 of the template sessions), `iit_b0_in_template.nii.gz` (the IIT b0 after its registration, for a visual check), `fixels/` (template fixels, `fd.mif`, and `bundle-<name>.mif` = 1 on the fixels of each IIT bundle), `bundles.tsv` (fixels per bundle), `sessions.tsv`, `manifest.json` (parameters, sessions, SHA-256 of every file)

With `--run_fibre_cross_section true`:

- `dwi/<sample>_space-fctemplate_desc-fc_stats.csv` — one row per IIT bundle: `sid, session, run, roi, log_fc_mean, log_fc_median, fd_mean, fdc_mean, n_fixels, covered_fraction, unmatched_fraction, registration_corr, min_jacobian, orientation_agreement, qc_flags, in_template, template_hash`. Statistics over the bundle's template fixels inside the run's warped brain mask (`covered_fraction` of the bundle); `unmatched_fraction`: share with no subject fixel matched (FD 0 there, FC defined); `registration_corr`: correlation of the warped fODF's l = 0 term with the template's; `min_jacobian` of the deformation; `orientation_agreement`: mean \|cos\| between fODF peak and tensor main eigenvector where FA > 0.7. `qc_flags`: `folding` (minimum Jacobian ≤ 0), `uncovered` (coverage < 0.9), `empty`. `in_template = 1` for the sessions that built the template; `template_hash`: first 12 characters of the SHA-256 of its `manifest.json`.
- `dwi/<sample>_space-fctemplate_desc-logfc.mif` — log FC on the template fixels (fixel data file of `fc_template/fixels`)
- `metrics/space-template_desc-fc_stats.csv` — all runs merged

## Hippocampal occupancy score

With `--run_hoc true`:

For each subject source of `volume_source`:

- `anat/<subject>_seg-<source>_desc-hoc.csv` — one row per `roi` (`Left`, `Right`, `Bilateral`): `sid, session, run, roi, hoc, hippocampus_mm3, inf_lat_vent_mm3, volume_source`. `hoc` is empty when the segmentation has neither structure.
- `metrics/space-native_seg-<source>_desc-hoc.csv` — all samples merged

## Merged output (metrics and/or volumes)

Enabled by `--run_merge_all_stats`.

Produces a single TSV merging all available data across WM, GM, and CSF region types, with one row per sample, region and source: `sid, session, run, roi, region_type, source, covariates..., metrics and volumes...`. `source` is the method that produced every value of the row:

- `atlas`: the atlas metrics (WM bundles, IIT GM regions, CSF regions) with the atlas volumes when `atlas` is a volume source, or the atlas volumes alone.
- `synthseg`, `reconall`, `freesurfer`, `samseg_long`: that segmentation's GM and CSF volumes, and, for the first subject source, its subject-region diffusion metrics.

Rows of different sources are never merged, and two files giving different values for one cell of one row stop the run. All inputs are merged with a union column set; cells missing in a source's data are left empty. The per-source files listed above are written in any case: they are the independent copy to check the combined table against (`docs/volumes_validation/check_outputs.py` does).

- `metrics/space-native_all-regions_desc-roi_combined.tsv`
