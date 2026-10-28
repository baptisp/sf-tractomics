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
assets/freesurfer_gm_lut.json               FreeSurfer ids → IIT GM region names (subject-segmentation GM volumes)
modules/local/stats/subjectvolumes/         Volumes of a subject segmentation (+ volume_source, icv_mm3)
conf/modules/stats_subjectvolumes.config    SynthSeg/SAMSEG + subject volume config (volume_source != atlas)
modules/local/segmentation/samseglong/      SAMSEG longitudinal segmentation of all sessions of a subject
modules/local/stats/hoc/                    Hippocampal occupancy score from the subject segmentation (run_hoc)
docs/nf-neuro-patches/                      Diffs of every vendored nf-neuro file changed here (make_patches.py)
assets/freesurfer_gm_samseg_lut.json        GM LUT for SAMSEG (subcortical + cerebral cortex totals)
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
2. `REGISTER_IIT_REF`: ANTs registers atlas B0 → subject B0.
3. `TRANSFORM_IIT_BUNDLES`: warps all bundle masks to subject DWI space (MultiLabel).
4. `STATS_MASK_METRICS`: extracts FA/MD/RD/AD/AFD per bundle using `scil_volume_stats_in_ROI`.
5. `STATS_MASK_VOLUMES` (optional): computes voxel count + mm³ per bundle.

Config: `conf/modules/stats_metricsinroi.config` (`.*:ATLAS_ROIMETRICS:STATS_MASK_METRICS`).
- `key_substrs_to_remove = ["prefix_", "_mask_warped", "_warped"]` (single `_` — bundle masks use single underscore separator)
- `value_substrs_to_remove = ["prefix__", "prefix_desc-fwc__"]` (double `__` — metric files)

Output per subject: `*_atlas-iit-wm_desc-roi_stats.tsv`
Global collected: `metrics/space-native_atlas-iit-wm_label-mean_desc-roi_stats.tsv`

## GM region ROI metrics pipeline

**Atlas: IIT Atlas v5.0 GM Desikan parcellation** (`IIT_GM_Desikan_atlas.nii.gz`, MNI152, same download as WM).

1. Reuses the IIT B0 registration transform from WM pipeline — no second registration.
2. `TRANSFORM_IIT_GM_ATLAS`: warps GM atlas to subject DWI space (MultiLabel).
3. `STATS_LABELMAP_METRICS` (`use_label = true`): calls `scil_volume_stats_in_labels`; module transposes to region-centric. TSV rows = GM regions, cols = metrics.
4. `STATS_LABELMAP_VOLUMES` (optional).

Config: `conf/modules/stats_metricsinroi.config` (`.*:ATLAS_ROIMETRICS:STATS_LABELMAP_METRICS`).
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

**Output schema** — one row per subject × ROI, each metric as a column:
```
sid  session  run  roi  region_type  [covariates]  [metrics]
```

**How it works**: each input is tagged with its type before being passed to the function:
- `"STATS_WM_bundle:::path"` — TSV: rows=bundles, cols=metrics (roi=bundle name)
- `"STATS_GM_region:::path"` — TSV: rows=GM regions, cols=metrics (roi=region name) — same orientation as WM
- `"STATS_CSF_region:::path"` — TSV: rows=CSF regions, cols=metrics (roi=region name) — same orientation as WM
- `"VOLS_*:::path"` — CSV: `sid,session,run,roi,volume_voxels,volume_mm3` → `volume_voxels` and `volume_mm3` become additional metric columns. The legacy `bundle` / `region` headers are still accepted by the parser.

All three STATS types have identical orientation since the module transposes GM/CSF. The function reconstructs the subject key from `sid+session+run` columns (new module format) or falls back to `sample` (legacy).

**Do not** use the old `"STATS:::"` tag — it was the bug: the function could not distinguish WM vs GM/CSF orientations (before the module transposition was added).

**Note**: `collectUnifiedFiles` and `collectStatsFiles` are Groovy closures, not Nextflow processes — they always re-execute even with `-resume`. Only the upstream stats processes (STATS_*_ROIMETRICS) are cached.

## Volumes module (`roivolumes`)

Already outputs `sid`, `session`, `run` as separate columns (not a combined `sample`). No `key_substrs_to_remove` for metric names (volumes don't extract metrics).

The ROI column is named `roi` in **both** modes — labels mode (`use_label = false`, one file per ROI) and atlas/labelmap mode (`use_label = true`, one image plus a LUT). It used to be `bundle` and `region` respectively; `collectStatsFilesWithVolumes` and `collectUnifiedFiles` still accept the old headers.

## Volume source (`volume_source`)

`params.volume_source` = `atlas` (default) | `synthseg` | `freesurfer` picks where GM, CSF and
comparison volumes come from. WM bundle volumes are always atlas-based.

- `atlas`: `STATS_ROIVOLUMES` on the warped template (DWI space). Only reflects the registration.
- `synthseg`: `SYNTHSEG_VOLUMES` (SEGMENTATION_SYNTHSEG alias, `--parc --robust --vol --qc`) on the
  **raw** `ch_t1` (not `t1_native`: BET would drop extra-cerebral CSF from the ICV), then
  `STATS_SUBJECT_{GM,CSF,COMPARISON}_VOLUMES` count labels in native T1 space.
- `freesurfer`: same counting on the input `ch_aparc_aseg` (native space, before TractoFlow's warp).

The subject branch fills `ch_gm_volumes` / `ch_csf_volumes` / `ch_cmp_volumes`, which replace the
atlas volume channels in the existing collectors, so the output file names do not change. The
`do_*_atlas_volumes` flags keep the atlas subworkflows from computing unused volumes, and GM-only
subject volumes no longer require `run_atlas_roimetrics`.

`assets/freesurfer_gm_lut.json` maps FreeSurfer ids to the **IIT GM names** (`Left-Thalamus-Proper`,
`ctx-lh-*`), so subject GM volumes join on IIT GM metrics by region name. SynthSeg has no choroid
plexus label (31/63): `ext.missing_labels` leaves those rows empty.

Global volume CSVs are written by `collectVolumeFiles` (not `collectFile`) and always carry
`volume_source` and `icv_mm3`; `collectStatsFilesWithVolumes` adds them when given a `volumeSource`
(not for WM, whose TSV feeds HARMONIZATION).

`params.run_longitudinal_volumes` (default false) sets `volume_source = "samseg_long"`, overriding
`params.volume_source`: `ch_t1` is grouped per subject (one T1 per session, first run, sessions in
name order) into `SAMSEG_LONG_VOLUMES` (`modules/local/segmentation/samseglong`:
`mri_robust_template` LTAs + `run_samseg_long --tp-to-base-transform`, so no resampling), whose
per-session files `<id_session[_run]>__samseg_{seg.nii.gz,icv.csv}` are mapped back to session metas
by name with `flatMap`. GM uses `assets/freesurfer_gm_samseg_lut.json` (cortex totals, no Desikan
parcels). When any volumes are requested, subjects have several sessions and the option is false,
a startup `log.warn` says `run_longitudinal_volumes` is not activated.

Volume QC: `annotateT1s` (workflows/sf-tractomics.nf) adds `meta.scanner` (BIDS sidecar) and
`meta.duplicate_of` (T1 with the same voxel data as another sample: header and gzip bytes ignored, hashed only among same-shape images) to
`ch_t1_vol`; STATS_SUBJECTVOLUMES writes `qc_score`, `qc_flags`, `scanner`, `duplicate_of`;
`collectVolumeFiles` adds the `icv_drift` flag (needs all sessions) and `pipeline_revision`.
`checkVolumeCoverage` fails the run when a session has no volumes of a requested type (report in
`metrics/volumes_missing_samples.txt`) unless `allow_missing_volumes`. Label warps use
GenericLabel (MultiLabel alters volumes even under identity; tests/known_answer). Run convention
everywhere: bare run number, absent = 1.

`collectStatsFilesWithVolumes` pairs stats and volumes on `(id, session, run)` (absent run = run 1),
falling back to the session's CSV (SAMSEG has one per session), and keeps subject-segmentation ROIs
missing from the atlas stats as volume-only rows. SynthSeg runs once per distinct T1 file and its
result is fanned out to every DWI run sharing it. The flag is checked with
`== true`: a CLI value arrives as a string and `"false" as boolean` is true.

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
| `volume_source` | `'atlas'` | GM/CSF/comparison volumes from `atlas`, `synthseg` or `freesurfer` (see above) |
| `run_longitudinal_volumes` | false | SAMSEG longitudinal GM/CSF/comparison volumes; overrides `volume_source` |
| `run_hoc` | false | Hippocampal occupancy score (STATS_HOC on `ch_subject_seg`); needs a subject segmentation |
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

**How the params map onto `ATLAS_ROIMETRICS`**: the subworkflow is not driven by per-tissue
flags. It takes two independent axes — `roi_sources` (`masks`, `labelmap`) for which ROI
representation to warp and analyse, and `roi_outputs` (`metrics`, `volumes`) for what to compute
on it. WM bundles are the `masks` representation, the IIT GM Desikan parcellation is the
`labelmap` one. `workflows/sf-tractomics.nf` builds both lists from the four `do_*` flags.

Consequence: asking for GM only genuinely skips the 41 bundle warps and all mask statistics —
the source axis is exact. The **outputs** axis is still shared, so `run_wm_metrics` with
`run_gm_volumes` computes all four combinations. The extra channels are not consumed downstream;
the cost is compute, not wrong output.

The CSF pipeline (`ATLAS_CSF_ROIMETRICS`) is a separate subworkflow and keeps its own
`run_roi_metrics` / `run_roi_volumes` booleans.

## Adding new metrics to ROI extraction

All three pipelines use `ch_input_metrics` from `workflows/sf-tractomics.nf`. This channel collects DTI metrics (FA/MD/RD/AD, AFD) and optionally NODDI/FW metrics. Any metric added there is automatically extracted in all ROI pipelines.

## Process naming convention for config selectors

Nextflow process names follow the call hierarchy:
- `SF_TRACTOMICS:ATLAS_ROIMETRICS:STATS_MASK_METRICS`
- `SF_TRACTOMICS:ATLAS_ROIMETRICS:STATS_LABELMAP_METRICS`
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
