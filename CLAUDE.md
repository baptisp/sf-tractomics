# sf-tractomics — Codebase Guide

## What this pipeline does

sf-tractomics is a Nextflow DSL2 pipeline for diffusion MRI tractography analysis. It preprocesses DWI and T1 images, performs tractography, extracts white matter bundle metrics, grey matter regional metrics, and CSF/ventricle metrics.

## Key directory layout

```
workflows/sf-tractomics.nf                  Main workflow: orchestrates all subworkflows
main.nf                                     Entry point: reads BIDS input, calls SF_TRACTOMICS
nextflow.config                             All user-facing params with defaults
conf/modules.config                         Top-level includeConfig list (order matters)
conf/modules/*.config                       Per-feature process configs (publishDir, ext.*)
subworkflows/nf-neuro/tractoflow/           Core DWI+T1 preprocessing → tractography
subworkflows/nf-neuro/atlas_iit/            Downloads IIT WM bundle atlas from NITRC
subworkflows/nf-neuro/atlas_roimetrics/     WM bundle + GM Desikan ROI metrics (IIT atlas)
subworkflows/nf-neuro/atlas_csf_roimetrics/ CSF/ventricle ROI metrics (FreeSurfer MNI152)
modules/nf-neuro/segmentation/synthseg/     SynthSeg T1 segmentation
modules/nf-neuro/stats/metricsinroi/        Extracts FA/MD/etc. within ROI masks
modules/nf-neuro/stats/roivolumes/          Computes ROI volumes (voxel count + mm³)
assets/freesurfer_csf_lut.json              FreeSurfer CSF label LUT (ventricles, choroid plexus)
assets/freesurfer_comparison_lut.json       FreeSurfer LUT for GM/WM/ventricles comparison output
```

## Atlas overview — which atlas is used where

| Pipeline | Atlas | Space | Download / Source |
|---|---|---|---|
| **WM bundles** | IIT Atlas v5.0 — TDI bundle masks | MNI152 | NITRC (auto-downloaded) |
| **GM Desikan** | IIT Atlas v5.0 — `IIT_GM_Desikan_atlas.nii.gz` | MNI152 | NITRC (auto-downloaded, same run as WM) |
| **CSF / ventricles** | FreeSurfer `cvs_avg35_inMNI152` `aparc+aseg.mgz` | MNI152 | Extracted from `freesurfer/freesurfer:7.4.1` container |
| **Comparison (GM/WM/ventricles)** | Same FreeSurfer `cvs_avg35_inMNI152` atlas | MNI152 | Same extraction as CSF pipeline |

The IIT and FreeSurfer atlases are both in MNI152 space but built from different cohorts. Each pipeline performs its **own independent ANTs registration** (IIT B0 → subject B0 for WM/GM; IIT B0 → subject B0 again for CSF/comparison — same reference but separate registration run to keep pipelines fully isolated).

## Segmentation architecture

All segmentation runs inside `TRACTOFLOW → ANATOMICAL_SEGMENTATION`.

Three backends, selected by params:
- **SynthSeg** (`params.run_synthseg = true`, default): FreeSurfer 7.4.1 container. Fast (~5 min). Produces WM/GM/CSF masks from a deep-learning segmentation.
  - With `--parc` flag (`task.ext.gm_parc = true`): also outputs `*__aparc_aseg.nii.gz` with full Desikan-Killiany cortical parcels (labels 1001-1035 left, 2001-2035 right) and subcortical regions.
  - Controlled in `subworkflows/nf-neuro/tractoflow/modules.config`.
- **FSL FAST** (fallback): tissue segmentation only (no parcellation).
- **FreeSurfer** (from BIDS input): uses externally computed `aparc_aseg` + `wmparc`.

SynthSeg runs on the **T1 already registered to DWI space**, so all its outputs are natively in DWI space.

## WM bundle ROI metrics pipeline

**Atlas: IIT Atlas v5.0 WM bundle TDI masks** (41 bundles, MNI152 space, downloaded from NITRC).

1. `ATLAS_IIT` downloads 41 WM bundle TDI masks from NITRC (IIT Atlas v5.0, MNI space).
2. `REGISTER_ATLAS_REF`: ANTs registers atlas B0 → subject B0.
3. `TRANSFORM_ATLAS_BUNDLES`: warps all bundle masks to subject DWI space (MultiLabel interpolation).
4. `STATS_METRICSINROI`: extracts FA/MD/RD/AD/AFD per bundle using `scil_volume_stats_in_ROI`.
5. `STATS_WM_VOLUMES` (optional): computes voxel count + mm³ per bundle.

Enabled by `params.run_atlas_roimetrics = true`.
Config: `conf/modules/stats_metricsinroi.config`.
Output per subject: `*_atlas-iit_desc-roi_stats.tsv`
Global collected: `metrics/space-native_atlas-iit_label-mean_desc-roi_stats.tsv`
Volumes: `metrics/space-native_atlas-iit_desc-roi_volumes.csv`

## GM region ROI metrics pipeline

**Atlas: IIT Atlas v5.0 GM Desikan parcellation** (`IIT_GM_Desikan_atlas.nii.gz`, MNI152 space, same download as WM pipeline).

1. `ATLAS_IIT` downloads `IIT_GM_Desikan_atlas.nii.gz` and `LUT_GM_Desikan_0to1.txt` from NITRC. The LUT (tab-separated: `index R G B "name"`) is converted to JSON at runtime in Groovy inside `atlas_iit/main.nf`.
2. The IIT atlas B0 registration transform (already computed for WM) is **reused** — no second registration.
3. `TRANSFORM_GM_ATLAS` (alias of `REGISTRATION_ANTSAPPLYTRANSFORMS`, MultiLabel) warps the GM atlas to subject DWI space.
4. `STATS_GM_ROIMETRICS` (alias of `STATS_METRICSINROI`, `use_label = true`) calls `scil_volume_stats_in_labels` with the JSON LUT to extract per-region FA/MD/RD/AD/AFD.
5. `STATS_GM_VOLUMES` (optional): computes voxel count + mm³ per GM region.

Enabled by `params.run_gm_metrics = true` or `params.run_roi_metrics = true` (requires `run_atlas_roimetrics = true`).
Config: `conf/modules/stats_metricsinroi.config` (selector `.*:ATLAS_ROIMETRICS:STATS_GM_ROIMETRICS`).
Output per subject: `*_atlas-iit-gm_desc-roi_stats.tsv`
Global collected: `metrics/space-native_atlas-iit-gm_label-mean_desc-roi_stats.tsv`
Volumes: `metrics/space-native_atlas-iit-gm_desc-roi_volumes.csv`

**IIT GM Desikan LUT coverage**: 8 subcortical GM structures × 2 hemispheres (thalamus, caudate, putamen, pallidum, hippocampus, amygdala, accumbens, cerebellum cortex) + 33 cortical Desikan regions × 2 hemispheres. **No ventricles or CSF.**

## CSF region ROI metrics pipeline

**Atlas: FreeSurfer `cvs_avg35_inMNI152` whole-brain parcellation** (`aparc+aseg.mgz` extracted from the `freesurfer/freesurfer:7.4.1` container). Completely independent from the IIT atlas pipeline — separate registration, separate outputs.

### Atlas source

By default, the subworkflow auto-extracts `cvs_avg35_inMNI152/mri/aparc+aseg.mgz` from the `freesurfer/freesurfer:7.4.1` container (which ships the subject). A custom atlas can be provided via `params.atlas_csf_atlas`.

### Pipeline steps

1. `EXTRACT_FREESURFER_MNI_ATLAS` (process, runs once, cached with `storeDir`): extracts `aparc+aseg.mgz` → NIfTI from the FreeSurfer container.
2. `REGISTER_CSF_REF`: ANTs registers IIT B0 (downloaded separately) → subject B0. Independent from the IIT WM/GM registration.
3. `TRANSFORM_CSF_ATLAS`: warps the FreeSurfer parcellation to subject DWI space (MultiLabel).
4. `STATS_CSF_ROIMETRICS` (alias of `STATS_METRICSINROI`, `use_label = true`): extracts per-region FA/MD/RD/AD/AFD for CSF regions.
5. `STATS_CSF_VOLUMES` (optional): computes voxel count + mm³ per CSF region.

### LUT: `assets/freesurfer_csf_lut.json`

Default LUT covers all CSF-related FreeSurfer labels — **main output files**:

| Label | Region |
|-------|--------|
| 4 | Left-Lateral-Ventricle |
| 5 | Left-Inf-Lat-Vent |
| 14 | 3rd-Ventricle |
| 15 | 4th-Ventricle |
| 24 | CSF |
| 31 | Left-choroid-plexus |
| 43 | Right-Lateral-Ventricle |
| 44 | Right-Inf-Lat-Vent |
| 63 | Right-choroid-plexus |

Enabled by `params.run_csf_metrics = true` (or `params.run_roi_metrics = true`) and/or `params.run_csf_volumes = true` (or `params.run_roi_volumes = true`).
Config: `conf/modules/stats_csfroi.config`.
Output per subject: `*_atlas-freesurfer-csf_desc-roi_stats.tsv`
Global collected: `metrics/space-native_atlas-freesurfer-csf_label-mean_desc-roi_stats.tsv`
Volumes: `metrics/space-native_atlas-freesurfer-csf_desc-roi_volumes.csv`

### Why a separate registration?

The IIT atlas and the FreeSurfer `cvs_avg35_inMNI152` are both in MNI152 space but were built from different cohorts with slightly different alignment. Keeping a separate registration ensures accuracy and makes the CSF pipeline fully independent — it does not require `run_atlas_roimetrics = true`.

## Comparison extraction (GM subcortical + WM + ventricles)

**Same atlas as CSF pipeline**: FreeSurfer `cvs_avg35_inMNI152`. The warped atlas produced by `TRANSFORM_CSF_ATLAS` is reused with a broader LUT.

Purpose: allows researchers to compare DTI metrics between CSF spaces, GM subcortical structures, and WM regions — all in the same reference frame. Outputs go to `comparison/` subdirectories to keep them clearly separate from the main clinical outputs.

### LUT: `assets/freesurfer_comparison_lut.json`

Covers GM subcortical structures (bilateral), WM regions, and ventricles/CSF:

| Category | Labels | Regions |
|----------|--------|---------|
| WM | 2, 41 | Left/Right Cerebral White Matter |
| WM | 7, 46 | Left/Right Cerebellum White Matter |
| WM | 16 | Brain Stem |
| GM | 8, 47 | Left/Right Cerebellum Cortex |
| GM | 10, 49 | Left/Right Thalamus |
| GM | 11, 50 | Left/Right Caudate |
| GM | 12, 51 | Left/Right Putamen |
| GM | 13, 52 | Left/Right Pallidum |
| GM | 17, 53 | Left/Right Hippocampus |
| GM | 18, 54 | Left/Right Amygdala |
| GM | 26, 58 | Left/Right Accumbens area |
| GM | 28, 60 | Left/Right VentralDC |
| Ventricles/CSF | 4, 43 | Left/Right Lateral Ventricle |
| Ventricles/CSF | 5, 44 | Left/Right Inf Lat Vent |
| Ventricles/CSF | 14, 15 | 3rd/4th Ventricle |
| Ventricles/CSF | 24 | CSF |
| Ventricles/CSF | 31, 63 | Left/Right Choroid Plexus |

### Pipeline steps

Reuses the warped FreeSurfer atlas from `TRANSFORM_CSF_ATLAS` (no extra registration).

4. `STATS_CSF_COMPARISON` (alias of `STATS_METRICSINROI`): extracts per-region FA/MD/RD/AD/AFD using `assets/freesurfer_comparison_lut.json`.
5. `STATS_CSF_COMPARISON_VOLUMES` (optional): computes voxel count + mm³ per comparison region.

Enabled by `params.run_csf_comparison_roimetrics = true` and/or `params.run_csf_comparison_volumes = true`.
Does **not** require `run_csf_metrics = true` — the atlas extraction and registration run as long as any CSF or comparison param is enabled.
Config: `conf/modules/stats_csfroi.config` (selectors `.*:STATS_CSF_COMPARISON` and `.*:STATS_CSF_COMPARISON_VOLUMES`).
Output per subject: `comparison/*_atlas-freesurfer-comparison_desc-roi_stats.tsv`
Global collected: `metrics/comparison/space-native_atlas-freesurfer-comparison_label-mean_desc-roi_stats.tsv`
Volumes: `metrics/comparison/space-native_atlas-freesurfer-comparison_desc-roi_volumes.csv`

## Important params

| Param | Default | Effect |
|---|---|---|
| `run_synthseg` | true | Use SynthSeg for tissue segmentation |
| `run_atlas_roimetrics` | false | Enable WM bundle ROI metrics (IIT Atlas v5.0) |
| `run_roi_metrics` | false | Master switch: extract FA/MD/RD/AD/AFD for **all** region types (WM, GM, CSF) |
| `run_wm_metrics` | false | WM bundle diffusion metrics only (IIT atlas, requires `run_atlas_roimetrics`) |
| `run_gm_metrics` | false | GM Desikan region metrics only (IIT atlas, requires `run_atlas_roimetrics`) |
| `run_csf_metrics` | false | CSF/ventricle region metrics only (FreeSurfer MNI152) |
| `run_roi_volumes` | false | Master switch: compute volumes for **all** region types (WM, GM, CSF) |
| `run_wm_volumes` | false | WM bundle volumes only (IIT atlas, requires `run_atlas_roimetrics`) |
| `run_gm_volumes` | false | GM Desikan region volumes only (IIT atlas, requires `run_atlas_roimetrics`) |
| `run_csf_volumes` | false | CSF/ventricle region volumes only (FreeSurfer MNI152) |
| `use_binary_masks` | false | Use binary masks instead of TDI-weighted for WM extraction |
| `atlas_iit_gm_atlas` | null | Custom IIT GM atlas path; null = download from NITRC |
| `atlas_iit_gm_lut` | null | Custom IIT GM LUT path (JSON or raw .txt); null = download + convert from NITRC |
| `atlas_csf_atlas` | null | Custom labeled atlas in MNI space; null = auto-extract from FreeSurfer container |
| `atlas_csf_lut` | null | Custom CSF LUT (.json); null = use `assets/freesurfer_csf_lut.json` |
| `run_csf_comparison_roimetrics` | false | Extract FA/MD/RD/AD/AFD for GM/WM/ventricles (FreeSurfer) → `comparison/` subdir |
| `run_csf_comparison_volumes` | false | Compute comparison region volumes → `comparison/` subdir |
| `atlas_csf_comparison_lut` | null | Custom comparison LUT (.json); null = use `assets/freesurfer_comparison_lut.json` |
| `run_merge_all_stats` | false | Merge WM + GM + CSF stats TSVs into `metrics/space-native_all-regions_label-mean_desc-roi_stats.tsv` |

## Adding new metrics to ROI extraction

All three pipelines (WM, GM, CSF) use `ch_input_metrics` from `workflows/sf-tractomics.nf` (lines 194-246). This channel collects DTI metrics (FA/MD/RD/AD, AFD) and optionally NODDI/FW metrics. Any new metric added there is automatically extracted in all ROI pipelines.

## Process naming convention for config selectors

Nextflow process names follow the call hierarchy:
- `SF_TRACTOMICS:ATLAS_ROIMETRICS:STATS_METRICSINROI`
- `SF_TRACTOMICS:ATLAS_ROIMETRICS:STATS_GM_ROIMETRICS`
- `SF_TRACTOMICS:ATLAS_CSF_ROIMETRICS:STATS_CSF_ROIMETRICS`
- `SF_TRACTOMICS:ATLAS_CSF_ROIMETRICS:STATS_CSF_VOLUMES`
- `SF_TRACTOMICS:ATLAS_CSF_ROIMETRICS:STATS_CSF_COMPARISON`
- `SF_TRACTOMICS:ATLAS_CSF_ROIMETRICS:STATS_CSF_COMPARISON_VOLUMES`

Config files use `withName: ".*:PROCESS_NAME"` to match any depth.

## LUT format for `scil_volume_stats_in_labels`

The LUT is a JSON file mapping integer label indices (as strings) to region names:
```json
{
    "4":  "Left-Lateral-Ventricle",
    "17": "Left-Hippocampus",
    "1024": "ctx-lh-precentral"
}
```

The SCILPY command produces per-region mean/std for each metric.
