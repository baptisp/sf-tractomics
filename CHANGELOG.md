# scilus/sf-tractomics: Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v1.0dev - 2026-07-25

Initial release of scilus/sf-tractomics, created with the [nf-core](https://nf-co.re/) template.

### `Added`

- `cohort/`: runs the pipeline on a list of sessions in passes (`params/passes/`, each pass reusing the earlier ones' tasks, a later pass may only add parameters or turn one on), on vitalTour or an Alliance cluster (Slurm CPU jobs, nothing heavy on the login node). With `BATCH=true` the subjects are split into batches, each packed into one archive between passes (scratch inode quota), with a crash-safe state, a per-batch lock and a merge of the batches' tables. Each run folder pins its inputs, the pipeline version and its Nextflow session. Tests in `cohort/tests/` (no cluster needed).
- `--volume_source` takes several sources, comma-separated (e.g. `atlas,synthseg,reconall`), to compare them. Each source writes its own files (`seg-<source>` for a subject segmentation, per sample in `anat/`), and its own rows in the combined TSV, which gains a `source` column (one row per sample, region and source; two files disagreeing on a cell stop the run). The atlas volume files are always written standalone, and the atlas metrics tables carry atlas volumes only. HOC is computed per subject source; the subject-region metrics use the first one. `--run_longitudinal_volumes` adds `samseg_long` as one more source.
- `--run_hippocampal_subfields`: hippocampal subfields and amygdala nuclei (FreeSurfer 7 `segment_subregions hippo-amygdala`, no MATLAB) on the pipeline's recon-all, in `anat/*_seg-reconall_desc-hippoamyg_volumes.csv` with eTIV. New modules `SEGMENTATION_HIPPOAMYG`, `STATS_HIPPOAMYG`.
- `--run_dwi_processing false`: only the T1 branch runs (subject-segmentation volumes, HOC, recon-all, thickness, subfields); a later run with `true` and `-resume` reuses it and adds the DWI outputs.

- Atlas registration QC (new module `QC_ATLASREGISTRATION`): for every DWI run and each atlas registration (IIT regions, CSF atlas), the correlation of the warped IIT b0 with the run's b0 and the Dice of the atlas brain with the brain mask, flagged `misaligned` / `brain_mismatch` below `--atlas_min_registration_corr` (0.6) / `--atlas_min_brain_dice` (0.85), in `dwi/*_atlas-{iit,freesurfer-csf}_desc-registration_qc.csv` and `metrics/space-native_desc-atlasregistration_qc.csv`; flagged runs are listed in the log. The atlas registrations had no automatic check.

### `Changed`

- recon-all (`RECONALL_THICKNESS`) runs on one CPU instead of four: the module sets `OMP_NUM_THREADS` to the task's CPUs, and FreeSurfer's multithreaded steps are not reproducible from run to run. On ADNI it used about one core of the four anyway (2 h 20 per T1 on Fir). Changes the task's script, so recon-all runs again on a resumed run.
- Subject-segmentation volume and HOC files are named after their source: `anat/<sample>_seg-<source>_label-{gm,csf}_desc-roi_volumes.csv`, `anat/comparison/..._label-comparison_...`, `anat/<sample>_seg-<source>_desc-hoc.csv`, and `metrics/space-native_seg-<source>_...`; they used to take the atlas file names (`dwi/<sample>_atlas-iit-gm_desc-roi_volumes.csv`, `metrics/space-native_desc-hoc.csv`).

### `Fixed`

- With several sources in `--volume_source` (e.g. `atlas,reconall,synthseg`), the per-sample subject-region files were named after the whole list (`dwi/*_seg-atlas,reconall,synthseg_desc-roi_stats.tsv`); they now carry the source the metrics use, the first subject source (`seg-reconall`), as the merged `metrics/` files already did.
- `docs/volumes_validation/check_outputs.py`: `--no-comparison` for runs without comparison volumes; the ICV fraction of a label the method cannot segment (SynthSeg choroid plexus) is expected empty.
- `SEGMENTATION_RECONALLSEG` converts `aparc+aseg` with nibabel: `mri_convert` asked for a FreeSurfer licence the module did not have, so every `volume_source reconall` run failed. Its ICV is QC-flagged like SynthSeg's.
- `--fc_template` stops when the template's recorded fODF parameters (`sh_order`, `basis`, `fodf_shells`, `manual_frf`, `mean_frf`, ...) differ from the run's. A warning when neither `manual_frf` nor `mean_frf` is set (FD and FDC are then not comparable between subjects). Run numbers in `fc_template_sessions` compare as integers. `RECONST_FODTOMRTRIX` uses the full rotation of the affine (identical on axis-aligned images, correct on oblique ones). An empty overlap no longer crashes the FC statistics. recon-all runs for `volume_source reconall` only when an output reads it. `REGISTRATION_FODTEMPLATE` runs on one thread: `mrregister` on several threads gave different warps for identical inputs (log FC up to 0.0016 apart between two runs), on one thread the same warp, for the same throughput.

- `--volume_source reconall`: GM, CSF and comparison volumes, HOC and subject-region metrics from the `aparc+aseg` of the pipeline's own FreeSurfer recon-all, the run that also gives the cortical thickness and surface metrics (one recon-all per T1); `icv_mm3` is FreeSurfer's eTIV. New module `SEGMENTATION_RECONALLSEG`.
- `--run_fibre_cross_section`, `--fc_build_template`, `--fc_template`, `--fc_template_sessions`, `--fc_template_voxel_size`, `--fc_min_orientation_agreement`: log fibre cross-section (FC), FD and FDC per IIT bundle on a study fODF template (MRtrix fixel-based analysis steps, no subject tractography), in `dwi/*_space-fctemplate_desc-fc_stats.csv` and `metrics/space-template_desc-fc_stats.csv`. New modules `RECONST_FODTOMRTRIX` (scilpy fODF to MRtrix: RAS order and tournier07 basis, checked against each run's tensor), `TEMPLATE_FODPOPULATION`, `TEMPLATE_IITBUNDLES`, `TEMPLATE_FCBUNDLEFIXELS`, `REGISTRATION_FODTEMPLATE`, `STATS_FIBRECROSSSECTION`. The template directory is checksummed (`manifest.json`) and every row carries its hash. Bundles are in column `roi`, named as in the WM tractometry table.
- A DWI sample with no fODF shell (for example an ADNI GE b1300 run under `--fodf_shells 1000`) is processed without fibre response, fODF, AFD, NuFO or peaks instead of failing in the fODF step, and is reported as `no fODF shell` in `metrics/dwi_input_report.tsv` with a startup warning; its statistics keep every other metric.
- `t1_shared_with` column in the subject volume files, the global volume files, the combined TSV and the HOC file: the first DWI run of the session whose T1 file a run shares, so the copied rows of a session with several DWI runs and one T1 can be left out of volume statistics.
- DWI input check (`DWI_INPUT_CHECK`, `metrics/dwi_input_report.tsv`): the parts of a split series (`<name>_k_of_N`, OASIS-3 Vida) are concatenated into one DWI, each scaled to the b0 of part 1 (`--merge_split_dwi`, new `PREPROC_DWICONCATENATE` module); DWIs whose largest DTI shell has fewer than `--dwi_min_shell_directions` (6) volumes (b-series) are skipped with their T1 instead of failing the run; a warning when the fODF shells hold fewer volumes than `sh_order` needs; two samples with the same subject, session and run stop the run.
- `--fodf_absolute_threshold` (default none: per-subject threshold from the ventricles, unchanged): one fODF peak threshold for all subjects; each sample's threshold is written to `dwi/*_desc-fodfthreshold.csv`.
- `fwc_failed_fraction` in the subject-region fractions and the surface stats: share of each region on voxels where the free-water-corrected fit failed (AD, RD or MD set to 0 by scilpy's outlier removal), reported and not removed, so its link with diagnosis can be checked.
- `volume_icv_fraction` (volume / intracranial volume) next to `icv_mm3` in every volume file and table.
- `small_region` flag and `--subject_roi_small_region_voxels` (50) for subject regions covering few acquired DWI voxels.
- Warnings when free water is fitted on single-shell data and when cortical thickness is computed session by session on subjects with several sessions.
- `--run_cortical_surface_metrics` (default `false`): diffusion metrics of the cortex sampled on the FreeSurfer surfaces at mid-thickness and averaged per Desikan region (new `STATS_SURFACEMETRICS` module), sharing `recon-all` with `--run_cortical_thickness`, in `dwi/*_surf-freesurfer_desc-roi_stats.tsv` and `metrics/space-native_surf-freesurfer_label-mean_desc-roi_stats.tsv`.
- `--run_subject_roi_metrics` (default `false`) and `--subject_roi_min_fraction`: diffusion metrics in the subject's own GM regions, weighted by the fraction of each acquired DWI voxel inside the region (new `IMAGE_LABELFRACTION` module), in `dwi/*_seg-<seg>_desc-roi_stats.tsv` and `metrics/space-native_seg-<seg>_label-mean_desc-roi_stats.tsv`, with the effective region sizes in `*_desc-roi_fractions.csv`.
- `--run_cortical_thickness` (default `false`): FreeSurfer `recon-all` (nf-neuro `segmentation/fsreconall`) on each distinct T1, thickness, area, grey matter volume and vertex count per Desikan region in `anat/*_desc-thickness.csv` and `metrics/space-native_desc-cortical-thickness.csv`, with `coarse_t1` and `implausible:<regions>` QC flags.
- `--run_hoc` (default `false`): hippocampal occupancy score (hippocampus / (hippocampus + inferior lateral ventricle)), left, right and bilateral, from the subject's own segmentation, in `anat/*_desc-hoc.csv` and `metrics/space-native_desc-hoc.csv`.
- Volume quality control: `qc_score`, `qc_flags` (`qc_low`, `icv_missing`, `icv_implausible`, `icv_drift`, `empty:<regions>`, `duplicate`), `scanner`, `duplicate_of` and `pipeline_revision` columns; warnings for duplicate T1s (same voxel data, even when header or compression differ) and subjects scanned on several scanners; the run fails when a session has no volumes unless `--allow_missing_volumes` (`--volume_qc_threshold`, `--volume_icv_drift`). `WM-hypointensities` row in the comparison files.
- Label warps use `GenericLabel` instead of `MultiLabel`, which altered label volumes even under an identity transform.
- `--run_longitudinal_volumes` (default `false`): FreeSurfer SAMSEG longitudinal segmentation of all sessions of a subject for GM, CSF/ventricle and comparison volumes, written to the same files with `volume_source = samseg_long`. When volumes are requested on subjects with several sessions and the option is off, a startup warning says it is not activated.
- `--volume_source` (`atlas` | `synthseg` | `freesurfer`) to compute GM, CSF/ventricle and comparison volumes from the subject's own segmentation in native T1 space instead of a warped template. Same output files, plus `volume_source` and `icv_mm3` columns. A warning recommends a longitudinal method when subjects have several sessions. The atlas-only version is tagged `v1.0dev-atlas-volumes`.
- GM Desikan parcellation ROI metrics pipeline using IIT Atlas v5.0 (`--run_gm_metrics`, `--run_gm_volumes`).
- CSF/ventricle ROI metrics pipeline using FreeSurfer `cvs_avg35_inMNI152` atlas (`--run_csf_metrics`, `--run_csf_volumes`).
- Cross-tissue comparison output (GM subcortical + WM + ventricles) using the FreeSurfer atlas (`--run_csf_comparison_roimetrics`, `--run_csf_comparison_volumes`).
- ROI volume computation (voxel count + mm³) for WM, GM, and CSF regions via new `stats/roivolumes` module.
- Master param switches `--run_roi_metrics` and `--run_roi_volumes` to enable all region types at once.
- Per-type param switches `--run_wm_metrics`, `--run_gm_metrics`, `--run_csf_metrics`, `--run_wm_volumes`, `--run_gm_volumes`, `--run_csf_volumes`.
- `--run_merge_all_stats` option to merge all available metrics and/or volumes into a single file (`space-native_all-regions_desc-roi_combined.tsv`); uses the collected stats TSV when metrics are enabled (with volumes joined when both active), falls back to the volume CSV when only volumes are enabled.
- `region_type` column in all stats output files.
- `CLAUDE.md` codebase documentation.

### `Fixed`

- SAMSEG longitudinal (`--run_longitudinal_volumes`) gave its segmentation only to the first DWI run of a session: the other runs had no volumes, HOC or subject-region metrics, and the per-session check did not notice. It now reaches every run that uses the segmented T1 file; a run with another T1 file of the session is listed in a startup warning. Subject-region metrics are checked per DWI run.
- `duplicate_of` could name a later run instead of the first when a T1 file shared by several runs had a duplicate, depending on the order of the inputs.
- `docs/volumes_validation/check_outputs.py` assumed one sample per session (run 1) and matched `participants.tsv` sessions only when written with `ses-`: it now checks every DWI run, `t1_shared_with`, and reads sessions without the prefix and the run column.
- Region statistics (nf-neuro `stats/metricsinroi`) failed at random with exit status 141: `head -n 1` closed the pipe while `printf` was writing the region names. They are now read with `awk`.
- Subject-region diffusion metrics: voxels outside the DWI brain mask (where the maps are 0) kept their weight and pulled region means down (up to 15% of a frontal pole); they now get none, as in the atlas tables, and `in_mask_fraction` reports the share kept. Same correction for the surface sampling (maps masked before the warp, samples normalised by the mask).
- WM bundle volumes with `--use_binary_masks`: border voxels of the linearly warped masks counted as whole voxels (+40 to +125%); `stats/roivolumes` gets `ext.mask_volume` (`nonzero` | `fraction`).
- RECONST_FRF received no shell or b0 settings (it used DTI shells up to 1500 and fODF shells from 100), and the DTI fits no b0 threshold or shell tolerance; they now follow the pipeline parameters. A misnamed N4 setting that was never read was removed.
- Parameters set in a `-c` config file or in a profile (`test`, `iit_tractometry`, `legacy`, `full_pipeline`, `skip_preproc`) did not reach the module settings (`ext.*`): `conf/modules/*.config` copied them while `nextflow.config` was read, before those values were applied, so steps silently used the defaults (for example `max_dti_shell_value` 1200 instead of the value set). The module settings now read the parameters when each task runs. `outdir`, `publish_dir_mode` and `clean_output` still have to be given on the command line or in a `-params-file`.
- The per-sample WM, GM, CSF and comparison stats tables were published under one name for both the mean and the std table, so either could overwrite the other. The std table is now `*_label-std_desc-roi_stats.tsv`; the mean keeps its name.
- Global stats and stats+volumes files list samples in sid / session / run order; they followed work directory names before.
- `--run_t1_resampling` never reached TractoFlow: its option list and its code used different names, so the T1 was never resampled whatever the setting. Fixed; the default is now `false`, which keeps results identical to previous runs.
- Nextflow 26 compatibility: fixed dynamic `errorStrategy` closures, `_` placeholder variables in `preproc_t1`, and groovy import in `atlas_iit`.

### `Dependencies`

### `Deprecated`

- `--run_gm_roimetrics` replaced by `--run_gm_metrics`.
- `--run_csf_roimetrics` replaced by `--run_csf_metrics`.
