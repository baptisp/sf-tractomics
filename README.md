# scilus/sf-tractomics

[![Open in GitHub Codespaces](https://img.shields.io/badge/Open_In_GitHub_Codespaces-black?labelColor=grey&logo=github)](https://github.com/codespaces/new/scilus/sf-tractomics)
[![GitHub Actions CI Status](https://github.com/scilus/sf-tractomics/actions/workflows/nf-test.yml/badge.svg)](https://github.com/scilus/sf-tractomics/actions/workflows/nf-test.yml)
[![GitHub Actions Linting Status](https://github.com/scilus/sf-tractomics/actions/workflows/linting.yml/badge.svg)](https://github.com/scilus/sf-tractomics/actions/workflows/linting.yml)
[![nf-test](https://img.shields.io/badge/unit_tests-nf--test-337ab7.svg)](https://www.nf-test.com)
[![Deploy documentation](https://github.com/scilus/sf-tractomics/actions/workflows/deploy.yml/badge.svg?branch=main)](https://github.com/scilus/sf-tractomics/actions/workflows/deploy.yml)

[![Nextflow](https://img.shields.io/badge/version-%E2%89%A525.04.6-green?style=flat&logo=nextflow&logoColor=white&color=%230DC09D&link=https%3A%2F%2Fnextflow.io)](https://www.nextflow.io/)
[![nf-core template version](https://img.shields.io/badge/nf--core_template-3.5.1-green?style=flat&logo=nfcore&logoColor=white&color=%2324B064&link=https%3A%2F%2Fnf-co.re)](https://github.com/nf-core/tools/releases/tag/3.5.1)
[![run with conda](http://img.shields.io/badge/run%20with-conda-3EB049?labelColor=000000&logo=anaconda)](https://docs.conda.io/en/latest/)
[![run with docker](https://img.shields.io/badge/run%20with-docker-0db7ed?labelColor=000000&logo=docker)](https://www.docker.com/)
[![run with singularity](https://img.shields.io/badge/run%20with-singularity-1d355c.svg?labelColor=000000)](https://sylabs.io/docs/)
[![Launch on Seqera Platform](https://img.shields.io/badge/Launch%20%F0%9F%9A%80-Seqera%20Platform-%234256e7)](https://cloud.seqera.io/launch?pipeline=https://github.com/scilus/sf-tractomics)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/sf-tractomics-white-logo.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/sf-tractomics-dark-logo.png">
  <img alt="sf-tractomics logo" src="assets/sf-tractomics-dark-logo.png" width="30%">
</picture>

## Introduction

**scilus/sf-tractomics** is a medical imaging pipeline that processes diffusion MRI images of human brains and reconstructs white matter pathways using tractography.

<!-- TODO nf-neuro : create a tube map for the pipeline -->

1. Read Inputs
2. Preprocess DWI
3. Preprocess T1
4. Segment T1
5. Reconstruct diffusion profiles
6. Run tractography

## Usage

> [!NOTE]
> If you are new to Nextflow and nf-core, please refer to [this page](https://nf-co.re/docs/usage/installation) on how to set-up Nextflow. Make sure to [test your setup](https://nf-co.re/docs/usage/introduction#how-to-run-a-pipeline) with `-profile test` before running the workflow on actual data.

You can run the pipeline using:

```bash
nextflow run scilus/sf-tractomics \
   -profile <docker/singularity/.../institute> \
   --input <samplesheet.csv|/path/to/bids> \
   --outdir <OUTDIR>
```

Refer to [the usage](./docs/usage.md) to see how to format your samplesheet or for extended informations.

> [!WARNING]
> Prefer the CLI or the Nextflow `-params-file` option for pipeline parameters. Parameters set in a `-c` config file or a profile do reach every step, except `outdir`, `publish_dir_mode` and `clean_output`, which Nextflow reads before any `-c` file: always give those on the command line or in a `-params-file` (see [usage](./docs/usage.md#running-the-pipeline)).

## Computed values and their limitations

Each value below has its own option, output files and caveats; [usage](./docs/usage.md) and
[output](./docs/output.md) give the details. Every value depends on the scanner, the protocol and
the voxel size: compare across sites only after harmonisation, and keep the scanner as a covariate.

### Diffusion maps (TractoFlow preprocessing and models)

| Values | Limitations |
|---|---|
| DTI: FA, MD, RD, AD, GA, mode, tensor (also free-water corrected: `fat`, `mdt`, ...) | Fitted on the b0 and the shells up to `max_dti_shell_value` (1200 by default): the values depend on the b-values used. Gibbs ringing is removed with MRtrix `mrdegibbs` (`run_gibbs_correction`, on by default), which assumes full k-space coverage; OASIS-3 DWI is partial Fourier (0.75 on Biograph and TrioTim, down to 0.37 on Vida), so part of the ringing next to CSF (hippocampus, fornix) remains, by an amount that depends on the protocol. Without a reverse phase-encoding scan, `topup` is skipped and the susceptibility distortion (frontal and temporal poles) is only absorbed by the T1-to-DWI registration. Acquisitions with one direction per b-value (b-series, as in 2126 OASIS-3 scans) are not supported: eddy fails on them. |
| fODF and AFD (total, sum, max), NuFO, peaks | Fitted on the shells from `min_fodf_shell_value` (700). The spherical harmonic order `sh_order` (8 by default, 45 coefficients) needs about 45 diffusion directions or more: fine for OASIS-3 Biograph (about 64), too high for ADNI2 (about 41), where the fit becomes unstable; when datasets are combined, use one order for all (6 needs 28 directions), otherwise AFD differs by method. The fibre response is fixed by default for every subject (`manual_frf = "15,4,4"`: eigenvalues 1.5, 0.4, 0.4 ×10⁻³ mm²/s; only the mean b0 is the subject's), which keeps AFD comparable across subjects; report it as such in methods, or set `manual_frf` to null (and `mean_frf`) for an estimated response. `afd_max`, `afd_sum` and NuFO are 0 where no fibre peak is found (most grey-matter voxels), with a peak threshold set per subject from its ventricles: use `afd_total` in grey matter. |
| Free-water fraction (`fwf`) | Reliable with several b-values. From a single shell the fit is driven by its regularisation and its fixed diffusivity priors (`para_diff` 1.5, `iso_diff` 3.0, `perp_diff` 0.1 to 0.7 ×10⁻³ mm²/s, the same for every subject; `average_diff_priors` has no effect while these are set) and cannot fully separate free water from tissue MD: treat single-shell free water as exploratory (the run warns). |
| NODDI (ICVF, ODI, ISOVF) | Needs multi-shell data with a high b-value (about 2000 s/mm² or more). Not valid on single-shell b = 1000 data such as OASIS-3 Biograph or ADNI2. |
| Tractography, bundles, tractometry | See the TractoFlow and RecoBundles documentation; bundle profiles inherit the limitations of the maps above. |

### Diffusion metrics in regions

| Values | Limitations |
|---|---|
| Atlas regions: IIT WM bundles and GM Desikan regions, FreeSurfer CSF/ventricle regions, warped from a template (`--run_atlas_roimetrics`, `--run_wm_metrics`, `--run_gm_metrics`, `--run_csf_metrics`) | A warped atlas region does not follow the subject's anatomy: in an atrophied brain it takes in CSF, which raises MD and free water whatever the tissue does (left hippocampus of an AD subject: MD 1.79 vs 1.28 ×10⁻³ mm²/s, free water 0.54 vs 0.31, atlas vs the subject's own region). |
| Subject's own GM regions, weighted by the fraction of each acquired DWI voxel inside the region (`--run_subject_roi_metrics`) | Needs a subject segmentation (`--volume_source synthseg` or `freesurfer`, or SAMSEG longitudinal). The weighting reduces partial volume but does not remove it, and depends on the DWI voxel size. The labels reach DWI space through TractoFlow's SyN T1-to-DWI transform, which aligned them better than an affine one on OASIS-3, but changes region sizes in DWI space (cortex +16 to 21%, WM −8 to 14%, frontal and temporal poles up to +88%): use the T1 volumes, not these sizes. Cortical regions are about one DWI voxel thick: treat them as exploratory, prefer the deep structures. |
| Cortex sampled on the FreeSurfer surfaces at mid-thickness, per Desikan region (`--run_cortical_surface_metrics`) | Runs `recon-all` (about 7 h per scan) and inherits its surface errors. A 2 mm diffusion voxel still reaches past both borders of a 2.5 mm cortex, though values hold about 30% less free water than the voxel means of the cortical labels. Mid-thickness is the average of the white and pial surfaces; FreeSurfer's `--projfrac 0.5` gives values 2 to 11% different, so do not mix conventions. No surface smoothing. |

### Morphometry

| Values | Limitations |
|---|---|
| Volumes from a warped atlas (`--volume_source atlas`, default) | The template region scaled by the registration: not a measure of atrophy. |
| Volumes from the subject's segmentation: SynthSeg, FreeSurfer `aparc+aseg`, or SAMSEG longitudinal (`--volume_source`, `--run_longitudinal_volumes`), with `icv_mm3` and QC columns | Repeat-scan error is about 0.1 to 3% (about 1% for the hippocampus), while healthy hippocampal loss is about 0.35% per year: one subject's change over one or two years is mostly noise, and cross-sectional segmentations of several sessions add more (use SAMSEG longitudinal). A scanner change shifts volumes by several % at once. Absolute volumes differ between methods: never mix them. Compare people through `volume_icv_fraction` (volume / intracranial volume, `icv_mm3`) or with the intracranial volume as a covariate: raw volumes mix atrophy with head size. SynthSeg has no choroid plexus and no lesion label; SAMSEG has no Desikan cortical parcels. QC flags point to likely failures; a clean flag does not prove a segmentation right. See [the validation report](./docs/volumes_validation/README.md). |
| Hippocampal occupancy score, left, right and bilateral (`--run_hoc`) | A ratio of two volumes of the same segmentation, so independent of voxel size and less dependent on head size; it inherits the noise of the small inferior lateral ventricle (repeat differences up to 16% for that structure) and differs between segmentation methods. |
| Cortical thickness, area, grey matter volume per Desikan region (`--run_cortical_thickness`) | FreeSurfer `recon-all` 7.4.1, about 7 h per scan. Biased on T1s coarser than about 1 mm (voxel side above 1.2 mm flagged `coarse_t1`); mean thickness outside 1 to 4.5 mm flagged `implausible`, usually a surface failure in the temporal pole or entorhinal cortex. Not normalised by head size. |

### Validation status

The outputs of the subject-region, HOC, thickness and surface options are checked on 4 OASIS-3
subjects (AD, MCI, two healthy): every value present, every parameter reaching its step, and each
value recomputed independently (FreeSurfer's `mri_vol2surf` for the surface values). This checks
that the pipeline computes what it claims, not that the values separate diagnoses: their
diagnostic value has to be established on a cohort.

Not yet run on real data (covered by stub or synthetic tests only), to check before relying on them:

- Subjects with several sessions or runs: one `recon-all` shared by the runs of a T1, and SAMSEG
  longitudinal combined with `--run_subject_roi_metrics`.
- `--volume_source freesurfer` (the subject's own `aparc+aseg`) for HOC and the subject-region
  metrics; only SynthSeg was run.
- Multi-shell data (e.g. OASIS-3 Vida), where free water is reliable and NODDI valid; the 4
  subjects are single-shell b = 1000.
- Data with a reverse phase-encoding scan, so `topup` runs before the label transfer and the
  surface sampling.
- Clusters (Slurm, Singularity/Apptainer); the checks ran locally with Docker.
- Profiles `legacy`, `full_pipeline`, `skip_preproc` and `test` now apply their parameters to the
  module settings, which they silently did not before (see the changelog): runs made with them
  before this fix can differ from new ones.
- Runs made before this fix with parameters in a `-c` config file used the defaults for the
  module settings (e.g. `max_dti_shell_value` 1200): look for the value in their `.command.sh`
  files (`grep -l "v<=1200" work/*/*/.command.sh`) before reusing their results. Single-shell
  b = 1000 data is not affected by that one.

## Credits

scilus/sf-tractomics is a port by @AlexVCaron of tractoflow, originally written by @GuillaumeTh.

We thank the following people for their extensive assistance in the development of this pipeline:

- @jchoude
- @frheault
- @arnaudbore
- @mdesco

## Contributions and Support

If you would like to contribute to this pipeline, please see the [contributing guidelines](.github/CONTRIBUTING.md).

## Citations

An extensive list of references for the tools used by the pipeline can be found in the [`CITATIONS.md`](CITATIONS.md) file.

This pipeline uses code and infrastructure developed and maintained by the [nf-core](https://nf-co.re) community, reused here under the [MIT license](https://github.com/nf-core/tools/blob/main/LICENSE).

> **The nf-core framework for community-curated bioinformatics pipelines.**
>
> Philip Ewels, Alexander Peltzer, Sven Fillinger, Harshil Patel, Johannes Alneberg, Andreas Wilm, Maxime Ulysse Garcia, Paolo Di Tommaso & Sven Nahnsen.
>
> _Nat Biotechnol._ 2020 Feb 13. doi: [10.1038/s41587-020-0439-x](https://dx.doi.org/10.1038/s41587-020-0439-x).
