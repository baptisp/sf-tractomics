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

Parameters can be given on the command line, in a `-params-file` (YAML or JSON), in a profile or
in a `-c` config file (`params { ... }`); every step sees the final value. The exceptions are
`outdir`, `publish_dir_mode` and `clean_output`: Nextflow reads them while it loads
`nextflow.config`, before any `-c` file, so give them on the command line or in a `-params-file`
(an `outdir` set only in a `-c` file sends the run reports to `./null`).

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
- `icv_mm3`: total intracranial volume (head size) from SynthSeg, or SAMSEG with `--run_longitudinal_volumes`. Empty for `atlas` and `freesurfer`.
- `volume_icv_fraction`: `volume_mm3 / icv_mm3`, the region's share of the intracranial volume, to compare people with different head sizes (a small head has a small hippocampus without atrophy). Empty when `icv_mm3` is.

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
| `duplicate_of` | The sample whose T1 holds the same voxel data as this one, even when the files differ in header or compression (e.g. a `run-02` exported twice from one acquisition): not an independent measurement |
| `pipeline_revision` | Git commit (or version) of the code that produced the file, in the global CSVs: never mix files of different revisions |

At startup the pipeline also warns when T1s are duplicates and when a subject was scanned on several scanners: a scanner change shifts volumes by itself, so use `scanner` as a covariate.

**Missing sessions fail the run.** Every input session must have volumes of every requested type. Sessions without them (failed or ignored task, missing input) are listed in `metrics/volumes_missing_samples.txt` and the run fails, unless `--allow_missing_volumes true`.

**Lesions.** SAMSEG and FreeSurfer give white-matter hypointensities (lesions) their own label, reported as `WM-hypointensities` in the comparison files. That tissue is not in the white-matter rows: in cohorts with growing lesions, add it back to WM, or lesion growth reads as WM atrophy. SynthSeg has no lesion label (the row is empty) and may mislabel lesions as grey matter or ventricle: prefer SAMSEG or FreeSurfer for such cohorts.

No flag proves a segmentation right: review flagged samples, and visually check outliers.

### Hippocampal occupancy score

`--run_hoc true` computes the hippocampal occupancy score (Heister et al. 2011, Neurology):
hippocampus / (hippocampus + inferior lateral ventricle), for the left and right hemispheres and
bilaterally (both hippocampi over both sums). It captures hippocampal shrinkage together with the
enlargement of the temporal horn next to it, and depends less on head size than the hippocampal
volume.

It is counted on the subject's own segmentation, so it needs `--volume_source synthseg` or
`freesurfer`, or `--run_longitudinal_volumes true`; the run stops otherwise. It needs no other
volume option. As a ratio of two volumes of one segmentation, it does not depend on the voxel size.
It inherits the noise of the small inferior lateral ventricle, and, like the volumes, it must not be
compared across segmentation methods.

### Diffusion metrics in the subject's own regions

`--run_subject_roi_metrics true` averages every diffusion metric map in the subject's own GM regions
(the 84 regions of the GM files with SynthSeg or FreeSurfer, 18 with SAMSEG), instead of the IIT
atlas regions warped from a template. In an atrophied brain the warped atlas region takes in
fluid, which raises its MD whatever the tissue does; the subject's regions follow the tissue.

The segmentation goes to diffusion space through TractoFlow's T1-to-DWI transform. Partial volume
happens at the resolution of the acquired DWI (2 to 2.7 mm in OASIS-3 and ADNI), not of the 1 mm
grid the maps are resampled to, so each acquired voxel gets the fraction of it that lies in each
region, and each metric is averaged with these fractions as weights. A voxel 20% inside the
hippocampus counts 0.2. This reduces partial volume but does not remove it, so keep the volume
in the analysis. `--subject_roi_min_fraction 0.75` uses instead the voxels at least 75% inside,
unweighted, for a sensitivity analysis: cleaner values, but an atrophied region keeps fewer voxels.
The effective size of every region (sum of fractions) is written next to the metrics. Voxels outside the DWI brain mask, where the maps are 0, get no weight;
`in_mask_fraction` gives the share of each region left inside the mask, and `small_region` flags the
regions covering fewer than `--subject_roi_small_region_voxels` (50) acquired voxels, such as the
accumbens or the transverse temporal gyrus at 2.5 mm, whose means are noisy.

Needs `--volume_source synthseg` or `freesurfer`, or `--run_longitudinal_volumes true`. The atlas
GM metrics are still computed when requested, in their own files.

Cortical regions are 2 to 3 mm thick, about one DWI voxel, so their values are dominated by partial
volume: treat them as exploratory, and prefer the deep structures (hippocampus, amygdala, thalamus).
The values depend on the DWI resolution: harmonise across sites and report the voxel size.
Without reverse phase-encoding, TractoFlow's `topup` is skipped and only the registration
compensates the susceptibility distortion of the temporal lobe: check the registration there.

### Cortical thickness

`--run_cortical_thickness true` runs FreeSurfer `recon-all` (7.4.1) on each distinct raw T1 and
reports, for the 68 Desikan cortex regions (`ctx-lh-*`, `ctx-rh-*`, the names of the GM files),
the mean and standard deviation of thickness, the surface area, the grey matter volume and the
number of vertices, read from FreeSurfer's `?h.aparc.stats`. It needs `--freesurfer_license` and
no other option. `recon-all` takes about 7 hours per scan, so plan it as a cluster job.

`recon-all` is the reference used by UK Biobank, ADNI and ENIGMA. It expects T1s of about 1 mm;
thickness from coarser voxels is biased, so inputs with a voxel side above 1.2 mm are flagged
`coarse_t1` in `qc_flags`. Regions with a mean thickness outside 1 to 4.5 mm, the usual sign of a
surface failure (temporal pole and entorhinal cortex first), are flagged `implausible:<regions>`.
Review flagged scans in the published FreeSurfer folder. Thickness is not normalised by head
size; the scanner must be a covariate, as for volumes.

### Diffusion metrics on the cortical surface

`--run_cortical_surface_metrics true` samples every diffusion metric map on the FreeSurfer
surfaces, halfway between the white and the pial surfaces, and averages it over the vertices of
each Desikan region, as the cortical MD studies in Alzheimer's disease do. It runs `recon-all`
like `--run_cortical_thickness` (once per distinct T1, shared when both options are on) and
needs `--freesurfer_license`, but no subject segmentation.

The maps and the DWI brain mask go to T1 space through TractoFlow's DWI-to-T1 transform (linear
interpolation); vertices outside the mask are left out, and `n_vertices` gives how many remain.
Mid-thickness is the point farthest from both CSF and white matter, so these values are less
contaminated than the voxel means over the cortical labels of `--run_subject_roi_metrics`, but a
2 mm diffusion voxel still reaches past both borders of a 2.5 mm cortex: keep the cortical
thickness in the analysis, and harmonise across sites. The sampling depth is
`ext.projfrac` of `STATS_SURFACEMETRICS` (0.5; 0 is the white surface, 1 the pial surface).

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
