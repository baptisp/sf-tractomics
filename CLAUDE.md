# sf-tractomics — Codebase Guide

## What this pipeline does

sf-tractomics is a Nextflow DSL2 pipeline for diffusion MRI tractography analysis. It preprocesses DWI and T1 images, performs tractography, extracts white matter bundle metrics, grey matter regional metrics, and CSF/ventricle metrics.

## Key directory layout

```
workflows/sf-tractomics.nf                  Main workflow: orchestrates all subworkflows
main.nf                                     Entry point: reads BIDS input, calls SF_TRACTOMICS
nextflow.config                             All user-facing params with defaults
conf/base.config                            Global ext.prefix default (see below)
conf/modules.config                         Top-level includeConfig list (order matters)
conf/modules/*.config                       Per-feature process configs (publishDir, ext.*)
subworkflows/nf-neuro/tractoflow/           Core DWI+T1 preprocessing → tractography
subworkflows/nf-neuro/atlas_iit/            Downloads IIT WM bundle atlas from NITRC
subworkflows/nf-neuro/atlas_roimetrics/     WM bundle + GM Desikan ROI metrics (IIT atlas)
subworkflows/nf-neuro/atlas_csf_roimetrics/ CSF/ventricle ROI metrics (FreeSurfer MNI152)
modules/nf-neuro/stats/metricsinroi/        Extracts FA/MD/etc. within ROI masks or labels
modules/nf-neuro/stats/roivolumes/          Computes ROI volumes (voxel count + mm³)
assets/freesurfer_csf_lut.json              FreeSurfer CSF label LUT (ventricles, choroid plexus)
assets/freesurfer_comparison_lut.json       FreeSurfer LUT for GM/WM/ventricles comparison output
```

## Global ext.prefix convention

`conf/base.config` sets a global default for all processes:
```groovy
ext.prefix = { [meta.id, meta.session?: "", meta.run ?: ""].findAll { x -> x }.join("_") }
```
So `task.ext.prefix` = `sub-027S6001_ses-20170111` (combined). This is used as the `sample` column in stats TSVs and to build `key_substrs_to_remove` patterns.

**Metric file naming**: output metric files use **double underscore** before the metric name:
`sub-027S6001_ses-20170111__fa.nii.gz`. So `key_substrs_to_remove = ["${task.ext.prefix}__"]` (double `__`) strips cleanly to `fa`, `md`, etc. Using single `_` would leave a leading underscore (`_fa`).

## Atlas overview — which atlas is used where

| Pipeline | Atlas | Space | Download / Source |
|---|---|---|---|
| **WM bundles** | IIT Atlas v5.0 — TDI bundle masks | MNI152 | NITRC (auto-downloaded) |
| **GM Desikan** | IIT Atlas v5.0 — `IIT_GM_Desikan_atlas.nii.gz` | MNI152 | NITRC (auto-downloaded, same run as WM) |
| **CSF / ventricles** | FreeSurfer `cvs_avg35_inMNI152` `aparc+aseg.mgz` | MNI152 | Extracted from `freesurfer/freesurfer:7.4.1` container |
| **Comparison (GM/WM/ventricles)** | Same FreeSurfer `cvs_avg35_inMNI152` atlas | MNI152 | Same extraction as CSF pipeline |

Each pipeline performs its **own independent ANTs registration** (IIT B0 → subject B0 for WM/GM; separate for CSF/comparison).

## Stats module orientation (unified)

`modules/nf-neuro/stats/metricsinroi/main.nf` produces a **consistent TSV orientation for all modes**:

| Mode | SCILPY command | Module step | TSV result |
|---|---|---|---|
| `use_label = false` (WM) | `scil_volume_stats_in_ROI` | Raw output is already ROI-centric | rows = bundles, cols = metrics |
| `use_label = true` (GM/CSF) | `scil_volume_stats_in_labels` | Module transposes metric-centric JSON → region-centric | rows = regions, cols = metrics |

**Both modes produce `sid  session  run  roi  [meta_cols]  [metrics]`.** `roi` = bundle name (WM) or region name (GM/CSF).

**FW-corrected metrics** (`_desc-fwc__`): the module's internal `extract_desc` jq step renames these automatically (e.g., `prefix_desc-fwc__fa` → `prefix__fat`). So `value_substrs_to_remove = ["prefix__"]` alone is sufficient for all cases — the `_desc-fwc__` entry is no longer needed.

`key_substrs_to_remove` cleans **outer keys** (ROI names before TSV output):
- WM: bundle mask filenames → bundle names (`["prefix_", "_mask_warped", "_warped"]`)
- GM/CSF: region names from LUT → already clean → `[]`

`value_substrs_to_remove` cleans **inner keys** (metric filenames → metric names):
- All modes: `["${task.ext.prefix}__"]`

## WM bundle ROI metrics pipeline

**Atlas: IIT Atlas v5.0 WM bundle TDI masks** (41 bundles, MNI152 space, downloaded from NITRC).

1. `ATLAS_IIT` downloads 41 WM bundle TDI masks from NITRC.
2. `REGISTER_ATLAS_REF`: ANTs registers atlas B0 → subject B0.
3. `TRANSFORM_ATLAS_BUNDLES`: warps all bundle masks to subject DWI space (MultiLabel).
4. `STATS_WM_ROIMETRICS`: extracts FA/MD/RD/AD/AFD per bundle using `scil_volume_stats_in_ROI`.
5. `STATS_WM_VOLUMES` (optional): computes voxel count + mm³ per bundle.

Config: `conf/modules/stats_metricsinroi.config` (`.*:STATS_WM_ROIMETRICS`).
- `key_substrs_to_remove = ["prefix_", "_mask_warped", "_warped"]` (single `_` — bundle masks use single underscore separator)
- `value_substrs_to_remove = ["prefix__", "prefix_desc-fwc__"]` (double `__` — metric files)

Output per subject: `*_atlas-iit-wm_desc-roi_stats.tsv`
Global collected: `metrics/space-native_atlas-iit-wm_label-mean_desc-roi_stats.tsv`

## GM region ROI metrics pipeline

**Atlas: IIT Atlas v5.0 GM Desikan parcellation** (`IIT_GM_Desikan_atlas.nii.gz`, MNI152, same download as WM).

1. Reuses the IIT B0 registration transform from WM pipeline — no second registration.
2. `TRANSFORM_GM_ATLAS`: warps GM atlas to subject DWI space (MultiLabel).
3. `STATS_GM_ROIMETRICS` (`use_label = true`): calls `scil_volume_stats_in_labels`; module transposes to region-centric. TSV rows = GM regions, cols = metrics.
4. `STATS_GM_VOLUMES` (optional).

Config: `conf/modules/stats_metricsinroi.config` (`.*:ATLAS_ROIMETRICS:STATS_GM_ROIMETRICS`).
- `key_substrs_to_remove = []` (region names from LUT are already clean)
- `value_substrs_to_remove = ["prefix__"]` (strips metric filename prefix; `_desc-fwc__` handled internally by module)

Output per subject: `*_atlas-iit-gm_desc-roi_stats.tsv`
Global collected: `metrics/space-native_atlas-iit-gm_label-mean_desc-roi_stats.tsv`

**IIT GM Desikan LUT**: 8 subcortical GM structures × 2 hemispheres + 33 cortical Desikan regions × 2 hemispheres. No ventricles or CSF.

## CSF region ROI metrics pipeline

**Atlas: FreeSurfer `cvs_avg35_inMNI152`** (`aparc+aseg.mgz`, auto-extracted from the FreeSurfer container). Independent from IIT pipeline — separate registration.

1. `EXTRACT_FREESURFER_MNI_ATLAS`: extracts atlas NIfTI from FreeSurfer container (cached with `storeDir`).
2. `REGISTER_CSF_REF`: ANTs registers IIT B0 → subject B0 (independent run).
3. `TRANSFORM_CSF_ATLAS`: warps FreeSurfer parcellation to subject DWI space (MultiLabel).
4. `STATS_CSF_ROIMETRICS` (`use_label = true`): same as GM — module transposes, TSV rows = CSF regions, cols = metrics.
5. `STATS_CSF_VOLUMES` (optional).

Config: `conf/modules/stats_csfroi.config` (`.*:ATLAS_CSF_ROIMETRICS:STATS_CSF_ROIMETRICS`).
- `key_substrs_to_remove = []` (region names from LUT are already clean)
- `value_substrs_to_remove = ["prefix__"]`

Default LUT (`assets/freesurfer_csf_lut.json`): labels 4, 5, 14, 15, 24, 31, 43, 44, 63 (ventricles + choroid plexus + CSF).

Output per subject: `*_atlas-freesurfer-csf_desc-roi_stats.tsv`
Global collected: `metrics/space-native_atlas-freesurfer-csf_label-mean_desc-roi_stats.tsv`

## Comparison extraction (GM subcortical + WM + ventricles)

Reuses `TRANSFORM_CSF_ATLAS` warped atlas with `assets/freesurfer_comparison_lut.json` (broader LUT covering WM, GM subcortical, and ventricles/CSF). Outputs to `comparison/` subdirectory.

Config: `conf/modules/stats_csfroi.config` (`.*:STATS_CSF_COMPARISON`).
- `key_substrs_to_remove = []`, `value_substrs_to_remove = ["prefix__"]`

## Combined stats file (`run_merge_all_stats`)

`collectUnifiedFiles` in `workflows/sf-tractomics.nf` merges WM, GM, and CSF stats into one wide TSV.

**Output schema** — one row per subject × metric, each ROI as a column:
```
sid  session  run  metric  [covariates]  [WM bundles]  [GM regions]  [CSF regions]
```

**How it works**: each input is tagged with its type before being passed to the function:
- `"STATS_WM_bundle:::path"` — TSV: rows=bundles, cols=metrics (roi=bundle name)
- `"STATS_GM_region:::path"` — TSV: rows=GM regions, cols=metrics (roi=region name) — same orientation as WM
- `"STATS_CSF_region:::path"` — TSV: rows=CSF regions, cols=metrics (roi=region name) — same orientation as WM
- `"VOLS_*:::path"` — CSV: `sid,session,run,bundle/region,volume_voxels,volume_mm3` → `volume_voxels` and `volume_mm3` become additional metric rows

All three STATS types have identical orientation since the module transposes GM/CSF. The function reconstructs the subject key from `sid+session+run` columns (new module format) or falls back to `sample` (legacy).

**Do not** use the old `"STATS:::"` tag — it was the bug: the function could not distinguish WM vs GM/CSF orientations (before the module transposition was added).

**Note**: `collectUnifiedFiles` and `collectStatsFiles` are Groovy closures, not Nextflow processes — they always re-execute even with `-resume`. Only the upstream stats processes (STATS_*_ROIMETRICS) are cached.

## Volumes module (`roivolumes`)

Already outputs `sid`, `session`, `run` as separate columns (not a combined `sample`). No `key_substrs_to_remove` for metric names (volumes don't extract metrics).

## Important params

| Param | Default | Effect |
|---|---|---|
| `run_synthseg` | true | Use SynthSeg for tissue segmentation |
| `run_atlas_roimetrics` | false | Enable WM bundle ROI metrics (IIT Atlas v5.0) |
| `run_roi_metrics` | false | Master switch: extract FA/MD/RD/AD/AFD for **all** region types (WM, GM, CSF) |
| `run_wm_metrics` | false | WM bundle diffusion metrics only |
| `run_gm_metrics` | false | GM Desikan region metrics only (requires `run_atlas_roimetrics`) |
| `run_csf_metrics` | false | CSF/ventricle region metrics only (FreeSurfer MNI152) |
| `run_roi_volumes` | false | Master switch: compute volumes for **all** region types |
| `run_wm_volumes` | false | WM bundle volumes only |
| `run_gm_volumes` | false | GM Desikan region volumes only |
| `run_csf_volumes` | false | CSF/ventricle region volumes only |
| `run_merge_all_stats` | false | Produce `metrics/space-native_all-regions_desc-roi_combined.tsv` — wide format with ROIs as columns |
| `tractometry_covariates` | `'site,age,sex,handedness,disease'` | Comma-separated covariate column names embedded in stats TSVs via `ext.meta_columns` and used by `collectUnifiedFiles` to separate covariates from data columns |
| `use_binary_masks` | false | Use binary masks instead of TDI-weighted for WM extraction |
| `atlas_iit_gm_atlas` | null | Custom IIT GM atlas path; null = download from NITRC |
| `atlas_iit_gm_lut` | null | Custom IIT GM LUT (JSON or .txt); null = download + convert |
| `atlas_csf_atlas` | null | Custom labeled atlas in MNI space; null = auto-extract from FreeSurfer container |
| `atlas_csf_lut` | null | Custom CSF LUT (.json); null = use `assets/freesurfer_csf_lut.json` |
| `run_csf_comparison_roimetrics` | false | Extract metrics for GM/WM/ventricles (FreeSurfer) → `comparison/` subdir |
| `run_csf_comparison_volumes` | false | Compute comparison region volumes → `comparison/` subdir |
| `atlas_csf_comparison_lut` | null | Custom comparison LUT; null = use `assets/freesurfer_comparison_lut.json` |

## Adding new metrics to ROI extraction

All three pipelines use `ch_input_metrics` from `workflows/sf-tractomics.nf`. This channel collects DTI metrics (FA/MD/RD/AD, AFD) and optionally NODDI/FW metrics. Any metric added there is automatically extracted in all ROI pipelines.

## Process naming convention for config selectors

Nextflow process names follow the call hierarchy:
- `SF_TRACTOMICS:ATLAS_ROIMETRICS:STATS_WM_ROIMETRICS`
- `SF_TRACTOMICS:ATLAS_ROIMETRICS:STATS_GM_ROIMETRICS`
- `SF_TRACTOMICS:ATLAS_CSF_ROIMETRICS:STATS_CSF_ROIMETRICS`
- `SF_TRACTOMICS:ATLAS_CSF_ROIMETRICS:STATS_CSF_VOLUMES`
- `SF_TRACTOMICS:ATLAS_CSF_ROIMETRICS:STATS_CSF_COMPARISON`
- `SF_TRACTOMICS:ATLAS_CSF_ROIMETRICS:STATS_CSF_COMPARISON_VOLUMES`

Config files use `withName: ".*:PROCESS_NAME"` to match any depth.

## LUT format for `scil_volume_stats_in_labels`

```json
{
    "4":  "Left-Lateral-Ventricle",
    "17": "Left-Hippocampus",
    "1024": "ctx-lh-precentral"
}
```
