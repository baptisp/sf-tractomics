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
| `--run_gm_volumes` | false | GM Desikan region volumes | `--run_atlas_roimetrics` |
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

### Merging all stats

To merge WM + GM + CSF stats TSVs into a single file (adds a `region_type` column):

```bash
--run_merge_all_stats true
```

Output: `metrics/space-native_all-regions_label-mean_desc-roi_stats.tsv`

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
