# sf-tractomics: Usage

## Prerequisites

- [Nextflow](https://www.nextflow.io/) >= 24.04
- [Docker](https://www.docker.com/) or [Singularity](https://sylabs.io/singularity/)

## Running the pipeline

```bash
nextflow run scilus/sf-tractomics \
  --input samplesheet.csv \
  --outdir results \
  -profile docker
```

The pipeline accepts a BIDS-compatible samplesheet CSV as input.

## ROI metrics

### Master switches

Two master switches enable all region types at once:

| Parameter | Effect |
|---|---|
| `--run_roi_metrics` | Extract FA/MD/RD/AD/AFD for all region types (WM, GM, CSF) |
| `--run_roi_volumes` | Compute voxel count and volume (mm³) for all region types |

### Per-type switches

Individual region types can be enabled independently. Per-type switches are ignored when the corresponding master switch is `true`.

| Parameter | Default | Region type | Requires |
|---|---|---|---|
| `--run_wm_metrics` | false | WM bundle diffusion metrics (IIT Atlas v5.0) | `--run_atlas_roimetrics` |
| `--run_gm_metrics` | false | GM Desikan region metrics (IIT Atlas v5.0) | `--run_atlas_roimetrics` |
| `--run_csf_metrics` | false | CSF/ventricle region metrics (FreeSurfer MNI152) | — |
| `--run_wm_volumes` | false | WM bundle volumes | `--run_atlas_roimetrics` |
| `--run_gm_volumes` | false | GM Desikan region volumes | `--run_atlas_roimetrics` (only with `--volume_source atlas`) |
| `--run_csf_volumes` | false | CSF/ventricle volumes | — |

### WM bundle metrics

Requires `--run_atlas_roimetrics true`. Downloads the IIT Atlas v5.0 WM bundle TDI masks (41 bundles) from NITRC and registers them to subject DWI space.

```bash
nextflow run scilus/sf-tractomics \
  --input samplesheet.csv \
  --outdir results \
  --run_atlas_roimetrics \
  --run_wm_metrics \
  -profile docker
```

By default, TDI-weighted masks are used for metric extraction. To use binary masks instead:

```bash
--use_binary_masks true
```

### GM Desikan region metrics

Uses the IIT Atlas v5.0 GM Desikan parcellation (downloaded alongside the WM atlas). Requires `--run_atlas_roimetrics true`.

```bash
nextflow run scilus/sf-tractomics \
  --input samplesheet.csv \
  --outdir results \
  --run_atlas_roimetrics \
  --run_gm_metrics \
  -profile docker
```

Custom atlas and Look-Up Table (LUT) can be provided:

```bash
--atlas_iit_gm_atlas /path/to/custom_gm_atlas.nii.gz
--atlas_iit_gm_lut   /path/to/custom_lut.json
```

### CSF/ventricle metrics

Uses the FreeSurfer `cvs_avg35_inMNI152` parcellation (auto-extracted from the `freesurfer/freesurfer:7.4.1` container). Fully independent from the IIT atlas pipeline — no `--run_atlas_roimetrics` required.

Requires a valid FreeSurfer license file:

```bash
export FS_LICENSE=/path/to/license.txt
nextflow run scilus/sf-tractomics \
  --input samplesheet.csv \
  --outdir results \
  --run_csf_metrics \
  -profile docker
```

Default LUT covers ventricles and choroid plexus (9 regions). Custom LUT:

```bash
--atlas_csf_lut /path/to/custom_csf_lut.json
```

### Comparison output (GM subcortical + WM + ventricles)

Reuses the warped FreeSurfer atlas from the CSF pipeline to extract metrics across GM subcortical structures, WM, and ventricles in a single reference frame. Outputs go to a `comparison/` subdirectory.

```bash
--run_csf_comparison_roimetrics true
--run_csf_comparison_volumes    true
--atlas_csf_comparison_lut      /path/to/custom_comparison_lut.json  # optional
```

### Volume source: atlas or subject segmentation

`--volume_source` chooses where the GM, CSF/ventricle and comparison volumes come from. WM bundle volumes are always atlas-based.

| Value | What is counted | Suitable for atrophy |
|---|---|---|
| `atlas` (default) | Voxels of a template parcellation warped onto the subject B0 (IIT for GM, FreeSurfer `cvs_avg35_inMNI152` for CSF/comparison) | No: the volume is the template region scaled by the registration |
| `synthseg` | SynthSeg (`--parc --robust`) run on the subject's raw T1, counted in native T1 space. Requires `--freesurfer_license` | Yes |
| `freesurfer` | The subject's own `aparc+aseg` given as input (samplesheet or BIDS FreeSurfer derivatives), counted in native T1 space | Yes |

```bash
--run_gm_volumes  true
--run_csf_volumes true
--run_csf_comparison_volumes true
--volume_source   synthseg
--freesurfer_license /path/to/license.txt
```

The output files are the same as with `atlas`, with the same region names, plus two columns:

- `volume_source`: `atlas`, `synthseg` or `freesurfer`.
- `icv_mm3`: total intracranial volume from SynthSeg, for normalising (`volume_mm3 / icv_mm3`). Empty for `atlas` and `freesurfer`.

SynthSeg segments the raw T1, not the brain-extracted one, so the CSF outside the brain stays in the intracranial volume. It has no choroid plexus label, so the two choroid plexus rows of the CSF and comparison files have empty volumes with `synthseg` (not measured, rather than a misleading 0). Its segmentation, soft volumes and QC score are written to `anat/<subject>_desc-synthseg_{dseg.nii.gz,volumes.csv,qc.csv}`; check the QC score before using a subject.

GM or CSF diffusion metrics still use the warped atlases. Volumes from the subject segmentation are joined to them by region name.

> [!WARNING]
> These volumes are **cross-sectional**: each session is segmented on its own. When a subject has several sessions, the session-to-session segmentation noise is of the order of yearly atrophy. When volumes are requested and a subject has several sessions, the pipeline warns at startup that `--run_longitudinal_volumes` is not activated.

### Longitudinal volumes (atrophy over time)

`--run_longitudinal_volumes` (default `false`) segments all sessions of each subject **jointly** with FreeSurfer SAMSEG longitudinal (`run_samseg_long`, Cerri et al. 2023):

1. The raw T1 of every session (the first run when a session has several) is resampled to 1 mm isotropic, so sessions acquired with different voxel sizes can be processed together, then rigidly aligned to the subject's median template with `mri_robust_template`. SAMSEG reads the transforms, so no session is resampled a second time.
2. `run_samseg_long` segments all sessions against a subject-specific latent atlas, which removes most of the noise that independent segmentations add on top of the real change.
3. Each session's labels are counted in that session's T1 space (1 mm grid) and written to the usual GM, CSF and comparison volume files, with `volume_source = samseg_long` and `icv_mm3` (SAMSEG sbTIV).

SAMSEG's atlas is a prior only: every label is fitted to the subject's own intensities, so the volumes measure the subject's WM, GM and ventricles, not a deformed template.

```groovy
params {
    run_gm_volumes             = true
    run_csf_volumes            = true
    run_csf_comparison_volumes = true
    run_longitudinal_volumes   = true
    freesurfer_license         = '/path/to/license.txt'
}
```

- The option overrides `--volume_source` for the GM, CSF and comparison volumes. WM bundle volumes stay atlas-based.
- SAMSEG has no Desikan cortical parcels: the GM file holds `Left-Cerebral-Cortex` and `Right-Cerebral-Cortex` totals instead of the 68 `ctx-*` regions. When GM diffusion metrics are enabled too, those two rows have no IIT GM metric to join to and appear only in the volumes file.
- A subject with a single session is segmented with cross-sectional `run_samseg`.
- One task per subject: measured at about 10 minutes and 8 GB for two sessions, and 42 minutes and 16 GB for six. The config requests 24 GB.
- Absolute volumes differ between methods (SAMSEG, SynthSeg, FreeSurfer): never mix sources within one atrophy analysis.
- A scanner or protocol change during follow-up shifts volumes on its own, and no segmentation method removes that bias. Record the scanner per session (the BIDS JSON `ManufacturersModelName`) and model it as a covariate in the statistics.
- Per-session outputs: `anat/<subject>_<session>_desc-samseglong_dseg.nii.gz` and `_desc-samseglong_icv.csv`.

### Volume quality control

Volumes from the subject's own segmentation (`synthseg`, `freesurfer`, longitudinal SAMSEG) carry columns that make bad or non-independent samples visible instead of silently entering the statistics:

| Column | Content |
|---|---|
| `qc_score` | Lowest SynthSeg QC score over its structure groups (SynthSeg only) |
| `qc_flags` | `;`-separated reasons not to trust the sample, empty when none: `qc_low` (QC score below `--volume_qc_threshold`, default 0.65), `icv_missing`, `icv_implausible` (outside 0.9 to 2.3 L), `icv_drift` (ICV off its subject's median by more than `--volume_icv_drift`, default 3%: ICV is constant in adults, so this points to a failed segmentation or a scanner change), `empty:<regions>` (regions with no voxel), `duplicate` |
| `scanner` | Manufacturer, model and field strength from the T1's BIDS sidecar JSON |
| `duplicate_of` | The sample whose T1 is byte-identical to this one (e.g. a `run-02` copied from `run-01` during conversion): not an independent measurement |
| `pipeline_revision` | Git commit (or version) of the code that produced the file, in the global CSVs: never mix files of different revisions |

At startup the pipeline also warns when T1s are duplicates and when a subject was scanned on several scanners: a scanner change shifts volumes by itself, so use `scanner` as a covariate.

**Missing sessions fail the run.** Every input session must have volumes of every requested type. Sessions without them (failed or ignored task, missing input) are listed in `metrics/volumes_missing_samples.txt` and the run fails, unless `--allow_missing_volumes true`.

**Lesions.** SAMSEG and FreeSurfer give white-matter hypointensities (lesions) their own label, reported as `WM-hypointensities` in the comparison files. That tissue is not in the white-matter rows: in cohorts with growing lesions, add it back to WM, or lesion growth reads as WM atrophy. SynthSeg has no lesion label (the row is empty) and may mislabel lesions as grey matter or ventricle: prefer SAMSEG or FreeSurfer for such cohorts.

No flag proves a segmentation right: review flagged samples, and visually check outliers.

### Merging all stats and volumes

To merge all available data (metrics TSVs and/or volume CSVs) across WM, GM, and CSF region types into a single file:

```bash
--run_merge_all_stats true
```

Output: `metrics/space-native_all-regions_desc-roi_combined.tsv`

For each region type, the pipeline uses the metrics TSV when metrics are enabled (which already includes volume columns if volumes are also active), and falls back to the volume CSV when only volumes are enabled. All inputs are merged with a union column set; missing values are left empty.

## Covariates

To add sample metadata columns (e.g. age, diagnosis) to the output stats TSVs:

```bash
--tractometry_covariates "age,diagnosis"
```

Values are read from the input samplesheet.

## Test profile

```bash
nextflow run scilus/sf-tractomics -profile test,docker --outdir results
```
