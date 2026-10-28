# Plan: diagnosis markers for AD vs HC and MCI vs HC

Status: proposal, not started. Branch: `diagnosis-markers`, from `main`.

Goal: add single-visit markers that may separate AD and MCI from healthy controls better than
hippocampal volume alone, and judge each one by whether it raises the AUC of a model that already
holds hippocampal volume, age, sex and ICV, on OASIS-3 and ADNI.

Every new feature is behind an option that is off by default, so existing runs and their outputs
do not change.

## Data the plan must work with

| | OASIS-3 (checked) | ADNI (to check) |
|---|---|---|
| T1 | MPRAGE, 1 mm isotropic | MPRAGE, about 1 mm, several scanner vendors |
| DWI | 2 mm isotropic, 25 directions, one direction per b-value from 50 to 1000 s/mm² | ADNI2 about 2.7 mm and b=1000 only; ADNI3 2 mm, some multi-shell |
| Reverse phase-encoding (for distortion correction) | none | none in ADNI2, mostly none in ADNI3 |
| TractoFlow resampling | DWI resampled to 1 mm (`dwi_resolution = 1`) | same |

Two consequences matter throughout the plan.
- The diffusion maps are on a 1 mm grid but hold 2 to 2.7 mm information. Interpolation hides
  partial volume, it does not remove it.
- Without reverse phase-encoding, susceptibility distortion is not corrected. TractoFlow's
  `topup` step needs a reverse b0 or DWI and is skipped for subjects without one
  (`subworkflows/nf-neuro/topup_eddy/main.nf:44`); `eddy` still runs but corrects motion and eddy
  currents only. The nonlinear T1-to-DWI registration absorbs part of the distortion. It is
  strongest in the mesial and inferior temporal lobe, where the AD regions are.

## How the reference pipelines compare

| Pipeline | GM / subcortical diffusion | Partial volume handling | Thickness |
|---|---|---|---|
| UK Biobank (Alfaro-Almagro 2018, docs v1.10 2024) | none: diffusion only in WM tracts (TBSS skeleton, AutoPtx) | not applicable | FreeSurfer 6 |
| ENIGMA-DTI (Jahanshad 2013) | none: WM skeleton only | not applicable | FreeSurfer (structural protocols) |
| ADNI DTI (Nir 2013; Zavaliangos-Petropulu 2019) | none: WM ROIs and TBSS | not applicable | FreeSurfer |
| QSIRecon (PennLINC) | atlas parcels warped to subject, including subcortical and hippocampus | none: unweighted mean per parcel | not included |
| TractoFlow / scilpy, MRtrix | none built in | none | not included |
| Cortical MD studies in AD (Montal 2018; Illán-Gala 2019; Sun 2024 on ADNI; Perera-Cruz 2026) | cortex, sampled on the FreeSurfer surface at mid-thickness | sampling at mid-cortex, surface smoothing, `bbregister` b0-to-T1, sometimes a GM partial volume correction | FreeSurfer `recon-all` |
| Deep GM MD studies (Weston 2020) | labels from the T1 interpolated into diffusion space | mean weighted by the tissue fraction of each voxel | thickness as covariate |

What this means for the plan.
- No mainstream released pipeline measures grey-matter diffusion with partial volume control. The
  closest released tool, QSIRecon, takes an unweighted mean in warped atlas parcels, which is
  what sf-tractomics already does with the IIT atlas. That is the naive baseline to beat.
- For the cortex, the accepted method is surface sampling at mid-thickness, which needs FreeSurfer
  surfaces. For deep grey matter, the accepted method is a tissue-fraction-weighted mean.
- Every large cohort pipeline uses FreeSurfer `recon-all` for thickness.

## Evidence on added value, to set expectations

- **For:** cortical MD effect sizes 2 to 3 times larger than thickness for cognitively impaired
  vs unimpaired in ADNI (Sun 2024, surface method). Hippocampal MD AUC 0.85 to 0.92 for dementia
  and 0.83 to 0.86 for MCI in memory-clinic samples (Brueggen 2018).
- **Against:** GM MD is strongly confounded by partial volume in atrophied brains, and both
  corrected and uncorrected MD classified worse than regional volume (Henf 2018). In a multi-shell
  study, MD was higher in AD but free-water-corrected MD showed no difference, so the signal was
  the fluid (Nakaya 2024). Hippocampal MD fell to chance for MCI in primary care (Brueggen 2018).
- **Expectation:** little gain over volume for AD vs HC; any gain most likely for MCI vs HC, and
  contested. The analysis must keep volume in every model, so a gain cannot come from atrophy
  measured twice.

## 1. Hippocampal occupancy score (HOC)

**Definition** (Heister et al. 2011, Neurology, NeuroQuant on ADNI): HOC = hippocampus /
(hippocampus + inferior lateral ventricle), per hemisphere. Bilateral = (left + right
hippocampus) / (left + right hippocampus + left + right inferior lateral ventricle). Heister
reported it beating hippocampal volume for MCI outcome. A smaller 2025 study (Schaffert, n=181)
found the two similar. The advantage is modest; the cost is near zero.

**Pipeline.** A small module reads the subject volume CSV the pipeline already writes.
- Option: `run_hoc` (false). Requires a subject segmentation (`volume_source = synthseg` or
  `freesurfer`, or `run_longitudinal_volumes`); otherwise the run stops with a clear message.
- Per-sample file: `*_desc-hoc.csv` with `sid, session, run, roi, hoc, hippocampus_mm3,
  inf_lat_vent_mm3, volume_source`, roi = `Left`, `Right`, `Bilateral`.
- Global file: `metrics/space-native_desc-hoc.csv`.

**Voxel size.** A ratio of two volumes from one segmentation, so the voxel volume cancels.
SynthSeg, SAMSEG and FreeSurfer all segment on a 1 mm grid, so HOC does not depend on the input
voxel size.

**Side effects.** HOC inherits the noise of the inferior lateral ventricle (repeat error 2 to 3%,
worst pair 16%), reduced about 5 times in the ratio. Measure it on the repeat-scan pairs. Never
mix HOC from different segmentation methods.

## 2. Cortical thickness: FreeSurfer `recon-all`

**Choice and reasons.**
- `recon-all` (FreeSurfer 7.4.1) is the accepted standard: UK Biobank, ADNI analyses and ENIGMA
  all use FreeSurfer.
- `recon-all-clinical` is not suited here: it was designed for clinical scans of any resolution,
  has no AD or MCI validation, its thickness disagrees with `recon-all` in the AD regions in a
  memory-clinic cohort (R² 3 to 34% for temporal pole, inferior temporal and entorhinal; Rudolph
  2025), and it cannot be used longitudinally.
- FastSurfer is a validated faster alternative with equal or better test-retest reliability
  (Henschel 2020), but less used in AD studies. It can be added later as a second option for a
  sensitivity analysis; it must never be mixed with `recon-all` in one analysis.

**Bonus.** `recon-all` also produces the surfaces needed for the accepted cortical diffusion
method (section 3), and an `aparc+aseg` that the pipeline already accepts as
`volume_source = freesurfer`.

**Pipeline.** The nf-neuro module `segmentation/fsreconall` exists (FreeSurfer 7.4.1 container) and
is reused.
- Option: `run_cortical_thickness` (false). Runs on the raw T1.
- Per-sample file: `*_desc-thickness.csv` with `sid, session, run, roi, thickness_mm,
  thickness_std_mm, surface_area_mm2, gm_volume_mm3`, roi = the 68 Desikan `ctx-lh-*` /
  `ctx-rh-*` names used in the GM files, read from `lh.aparc.stats` and `rh.aparc.stats`.
- Global file: `metrics/space-native_desc-cortical-thickness.csv`. Not added to the combined TSV
  for now (its own file, as for HOC). The FreeSurfer subject folder is published for visual QC.
- Run time: about 7 h per scan on one CPU (Henschel 2020 benchmark), a cluster job.

**Voxel size.** `recon-all` expects about 1 mm isotropic. Thicker voxels bias thickness. The
module warns when the T1 voxel size is above 1.2 mm in any direction.

**Side effects.** Thickness is not ICV-normalised (normalising it is a common error). The scanner
must be a covariate. Surface failures hit the temporal pole and entorhinal cortex first: flag
outlier regions in `qc_flags` and review flagged scans.

## 3. Diffusion metrics in the subject's own regions

### 3a. Deep grey matter (hippocampus, amygdala, thalamus, caudate, putamen, pallidum, accumbens)

**Method: tissue-fraction-weighted mean by default, threshold as an option.**
- For each label, compute in diffusion space the fraction of each voxel that belongs to it: warp
  the T1 labels with TractoFlow's existing T1-to-DWI transform onto a finer copy of the diffusion
  grid (exact `GenericLabel`), then count per diffusion voxel at the acquisition resolution.
- Average each metric with these fractions as weights. The existing metrics module already does a
  weighted mean with weight masks (it is how the WM bundles are measured).
- Report the effective size of each region (sum of the weights) next to the means.

**Why not a threshold.** A threshold looks clean but has three problems.
1. The voxels kept depend on the resolution: at 2 to 2.7 mm few voxels are mostly inside a thin
   structure, so the same threshold keeps different tissue in OASIS-3 and ADNI2.
2. It depends on atrophy: an atrophied hippocampus keeps proportionally fewer core voxels, so the
   region samples different tissue in AD than in HC. That bias is correlated with the diagnosis,
   which is what we are testing.
3. It discards information near the edges instead of down-weighting it.

A weighted mean keeps every voxel in proportion to how much of it belongs to the region. Example:
three voxels 60%, 100% and 20% inside the hippocampus with MD 1.2, 0.8 and 2.5 give
(0.6 × 1.2 + 1 × 0.8 + 0.2 × 2.5) / 1.8 = 1.12, where a 0.75 threshold keeps only the second
voxel (0.8). The weight says how much of a voxel belongs to the region, not how clean its value
is: the 20% voxel still brings fluid in, with less weight. So the weighted mean reduces partial
volume without removing it (no volume-based method does), and the analysis must keep volume as a
covariate.

The threshold stays available as an option, so that results can be shown not to depend on the
choice (sensitivity analysis): weighted means are consistent across groups, thresholded means are
cleaner but sample AD and HC differently.

- Options: `run_subject_roi_metrics` (false), same requirement as HOC;
  `subject_roi_min_fraction` (0, meaning weighted mean over every voxel with any overlap; a value
  such as 0.75 keeps only voxels at least that much inside the region, unweighted).
- Per-sample file: `*_seg-synthseg_desc-roi_stats.tsv` (`seg-samseg`, `seg-freesurfer`), same
  layout as the GM file plus `n_voxels_effective`.
- Global file: `metrics/space-native_seg-synthseg_label-mean_desc-roi_stats.tsv`
  (`region_type = GM_subject`). Not in the combined TSV: it keys rows by region name, so these rows
  would merge with the atlas GM rows of the same names.

### 3b. Cortex: surface sampling (needs section 2)

The accepted cortical method samples each metric on the FreeSurfer surface at mid-thickness
(`bbregister` b0-to-T1, `mri_vol2surf` at half the white-to-pial distance, surface smoothing),
then averages per Desikan region. A volume-based mean over the cortex labels is not used: at 2 mm
almost no cortical voxel is mostly cortex.
- Option: `run_cortical_diffusion` (false), requires `run_cortical_thickness`.
- Per-sample file: `*_desc-cortex-midthickness_stats.tsv`, same layout as the GM file.
- This is implemented after 2 and 3a, and only if 3a shows the pipeline gives sensible values.

### Metrics and their limits
- DTI metrics (FA, MD, RD, AD) are valid on both datasets.
- Free water: OASIS-3 has several b-values from 50 to 1000, which suits the free-water fit.
  ADNI2 has a single shell: the fit is driven by its regularisation and cannot separate free water
  from tissue MD (Golub 2021; Correia 2024), so ADNI2 free-water results are exploratory.
- NODDI is not valid on either dataset (no high b-value).

### Distortion
OASIS-3 and ADNI have no reverse phase-encoding, so TractoFlow's `topup` is skipped for them and
only the registration compensates the distortion, which is worst in the temporal lobe. The accepted remedy is Synb0-DisCo (Schilling 2019, 2020): a synthetic
undistorted b0 made from the T1, then used by topup. It is not in nf-neuro or TractoFlow today, so
it is a separate step after this plan. Meanwhile, every subject gets a QC image (labels over FA and
b0), and registration accuracy in the temporal lobe is checked on a few subjects before results
are interpreted.

### Voxel size
These metrics depend on the DWI voxel size. OASIS-3 (2 mm) and ADNI2 (2.7 mm) give different
partial volume, so cross-dataset models need harmonisation per site and resolution (ComBat or the
pipeline's harmonisation step), and the DWI voxel size is reported with the results.

## 4. Bug fix: `run_t1_resampling`

The workflow passes `preproc_t1_run_resample` (`workflows/sf-tractomics.nf:122`) but the T1
preprocessing reads `preproc_t1_run_resampling` (`subworkflows/nf-neuro/preproc_t1/main.nf:65`).
The value set by the user is ignored and the default (true) always applies. Harmless with the
default settings; with `run_t1_resampling = false` the T1 is resampled anyway, without any error.
Fix the key in the workflow. The TractoFlow `meta.yml` documents the wrong name, which is an
nf-neuro fix (see "Where the code lives").

## 5. Where the code lives

sf-tractomics vendors nf-neuro modules and subworkflows (`modules/nf-neuro/`,
`subworkflows/nf-neuro/`, tracked in `modules.json`) and keeps pipeline-specific code in
`modules/local/`. The nf-neuro repository is cloned next to the pipeline
(`../modules`, fork `baptisp/modules`). Rule: code that any nf-neuro pipeline could use goes to
nf-neuro as a module with its own tests; code tied to sf-tractomics files and options stays local.

| Piece | Where | Why |
|---|---|---|
| `recon-all` | existing nf-neuro `segmentation/fsreconall`, installed into sf-tractomics | Already exists. It runs single-threaded (about 7 h); an upstream change to pass `ext.args` (e.g. `-parallel -openmp N`) is worth proposing. |
| Parse `aparc.stats` to a CSV | `modules/local/stats/thickness` (changed from the first plan) | nf-neuro tables use a `sample` column while sf-tractomics keys on `sid, session, run`; an nf-neuro version would need an extra conversion step. Can move upstream once the conventions are aligned. |
| Label fraction maps on a target grid | `modules/local/image/labelfraction`, in nf-neuro layout (changed from the first plan) | Generic, so a good nf-neuro candidate, but an nf-neuro module needs tests on the nf-neuro test data: a separate contribution. Fractions are computed on the acquisition grid (the raw DWI), not on the 1 mm grid of the maps, because partial volume happens at the acquired resolution. |
| Weighted metrics in regions | existing nf-neuro `stats/metricsinroi` (mask mode) | Already does weighted means; check that it reports the sum of weights, or add it upstream. |
| Diffusion on the cortical surface (3b) | new nf-neuro module, later | Generic (`bbregister` + `mri_vol2surf` + per-region average). |
| HOC | `modules/local/` | Reads the pipeline's own subject volume CSV. |
| Options, collectors, combined TSV | `workflows/sf-tractomics.nf` | Pipeline-specific. |

New nf-neuro modules follow the nf-neuro conventions (`main.nf`, `meta.yml`, `environment.yml`,
nf-test tests with snapshots), are developed on a branch of the fork, and are installed into
sf-tractomics from that branch, so the pipeline is not blocked by the upstream review. Once merged
upstream, they are reinstalled from nf-neuro. The known-answer fixtures stay in the sf-tractomics
tests; the nf-neuro tests use the nf-neuro test data.

**Divergences from nf-neuro already in sf-tractomics.** Earlier work changed vendored nf-neuro
code. Each should be proposed upstream, or recorded as a module patch, so that a future
`modules update` does not silently undo it:
- `segmentation/synthseg`: `--parc` was defined but never passed to `mri_synthseg` (upstream bug),
  and the licence is copied into the read-only `$FREESURFER_HOME` (fails when the container runs as
  the host user).
- `atlas_roimetrics` and `tractoflow` configs: label warps use `GenericLabel` instead of
  `MultiLabel`, which changes label volumes even under an identity transform (known-answer test in
  `tests/known_answer`).
- `tractoflow/meta.yml`: documents `preproc_t1_run_resample` instead of
  `preproc_t1_run_resampling`.
- `stats/roivolumes` is vendored but not listed in `modules.json`: it comes from the open nf-neuro
  pull request on `feat/stats-roivolumes`. Once merged, install it properly so `modules.json`
  tracks it.

## 6. Not on this branch

- White-matter lesions from FLAIR (for MS): a later option.
- Synb0-DisCo distortion correction: a later step, see above.
- FastSurfer as a second thickness option.

## Checks

| Requirement | How it is checked |
|---|---|
| No bugs introduced | The full test suite passes before and after each feature; the default pipeline snapshot is unchanged with all new options off. |
| Known-answer tests | **HOC:** synthetic segmentation with known voxel counts, exact ratios. **Deep GM diffusion:** synthetic labels and metric maps where the expected weighted mean is computed by hand, through the warp (identity and one-voxel shift) and the fraction step; exact fractions, effective sizes and means. **Thickness:** the stats parser on a real `aparc.stats` with known values; stub test of the module. **Cortical diffusion:** a synthetic metric map constant inside the cortex ribbon, sampled on a real FreeSurfer subject, must return that constant. |
| Voxel size | **HOC:** the same segmentation stored at two voxel sizes gives the same ratio. **Deep GM diffusion:** the same synthetic tissue sampled on 1 mm and 2 mm diffusion grids gives the same weighted mean in a region of uniform value. **Thickness:** warning tested on a 1 × 1 × 2 mm header. |
| Options passed and used | Each option on and off (files appear only when on), each value checked to reach its command, CLI string values handled (`== true`), invalid combinations stop the run with a clear message, every option in `nextflow_schema.json`. |
| Values land in the final CSVs | The integrity test (several subjects, sessions, runs) extended to the new files: each row carries its own sample's values, every region present once, the combined TSV equal to the per-sample files cell by cell. |
| Simple code | One small module and one workflow call per feature, reusing the existing modules (`fsreconall`, `STATS_METRICSINROI`, `antsapplytransforms`) and collectors. |
| nf-neuro modules | Each new nf-neuro module passes the nf-neuro lint and its own nf-test tests in the fork, and the sf-tractomics tests pass with the installed copy. `modules.json` matches the installed versions. |
| Real data | A few OASIS-3 subjects, with `check_outputs.py` extended to the new files. Plausibility: HOC about 0.8 to 0.9 in healthy subjects and lower in AD; thickness 2 to 3 mm, thinner in AD in the temporal regions; subject-region hippocampal MD lower than atlas MD in atrophied subjects; QC images reviewed. |

## Order

1. `run_t1_resampling` fix.
2. Record the existing nf-neuro divergences as module patches (or upstream PRs).
3. HOC (local module).
4. Cortical thickness: install `fsreconall`, new nf-neuro `stats/fsstats`.
5. Deep grey matter diffusion (3a): new nf-neuro `image/labelfraction`, then `stats/metricsinroi`.
6. Cortical diffusion on the surface (3b), if 3a gives sensible values.

Each step is committed separately once its tests pass.

## References

- Alfaro-Almagro et al. 2018, NeuroImage 166:400. UK Biobank Brain Imaging Documentation v1.10, 2024.
- Brueggen et al. 2018, Curr Alzheimer Res, doi:10.2174/1567205015666180613114829.
- Correia et al. 2024, Imaging Neuroscience 2, PMC12272235.
- Golub et al. 2021, Magn Reson Med, doi:10.1002/mrm.28599.
- Gopinath et al. 2025, Medical Image Analysis 103:103608 (recon-all-clinical).
- Heister et al. 2011, Neurology 77:1619, doi:10.1212/WNL.0b013e3182343314.
- Henf et al. 2018, NeuroImage: Clinical 17:579, doi:10.1016/j.nicl.2017.10.005.
- Henschel et al. 2020, NeuroImage 219:117012 (FastSurfer).
- Illán-Gala et al. 2019, Brain 142:1121, doi:10.1093/brain/awz031.
- Jahanshad et al. 2013, NeuroImage 81:455 (ENIGMA-DTI).
- Montal et al. 2018, Alzheimer's & Dementia 14:340, doi:10.1016/j.jalz.2017.09.013.
- Nakaya et al. 2024, J Alzheimer's Dis, doi:10.3233/JAD-231416.
- Nir et al. 2013, NeuroImage: Clinical, PMC3792746.
- Perera-Cruz et al. 2026, Brain Communications 8:fcaf511, PMC12933213.
- Rudolph et al. 2025, Alzheimer's & Dementia, doi:10.1002/alz70856_107027 (abstract).
- Schaffert et al. 2025, Cogn Behav Neurol, doi:10.1097/WNN.0000000000000390.
- Schilling et al. 2020, PLoS One, doi:10.1371/journal.pone.0236418 (Synb0-DisCo).
- Sun et al. 2024, Alzheimer's & Dementia 20:7048, PMC11485315.
- Weston et al. 2020, Alzheimer's Research & Therapy, PMC7499910.
- Zavaliangos-Petropulu et al. 2019, Front Neuroinform, doi:10.3389/fninf.2019.00002.

Some sources were read as abstracts only (Montal 2018, Henf 2018, Nakaya 2024, Brueggen 2018,
Rudolph 2025, Schaffert 2025); their figures should be checked in the full text before being
quoted in a paper.
