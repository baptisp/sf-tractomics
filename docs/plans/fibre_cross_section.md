# Plan: fibre cross-section (log FC) per WM bundle

Status: v1 implemented on branch `samseg-fc-runs` (2026-11-04), as described in the README (section Fibre cross-section). Differences from this plan: TractoFlow's fODF is reused with `fodf_shells 1000` (no dedicated CSD module, no group response); the template is built inside the pipeline (`--fc_build_template`); bundle membership is v1 (every fixel of a voxel inside the mask); covariates are not merged into the FC CSV (join on sid, session, run); a template of fewer than 10 sessions is accepted with a warning (tests). The bundle column is `roi`, with the names of the WM tractometry table (`AC`, not `AC_mask`), so the tables join on (sid, session, run, roi). Not done yet: the prototype on the ADNI test (Phase 1 now runs the pipeline itself), the cohort template, the validation (Phase 4).

Goal: one log fibre cross-section value per IIT bundle and per DWI run, as a WM atrophy feature
that replaces the atlas WM bundle volumes. FC is the deformation of an fODF registration to a
study template, measured perpendicular to each fibre direction (Raffelt et al. 2017). A bundle
that has lost axons is thinner: FC below 1, log FC below 0. No tractography of the subjects.

Everything is behind options that are off by default, so existing runs and outputs do not change.

## Why not reuse what exists

- The atlas bundle volumes come from a b0 registration, which has no contrast inside the WM; they
  measure the registration (README of the ADNI test, decision 1).
- TractoFlow's fODFs are, by default, fitted on every shell at or above `min_fodf_shell_value`
  (700), so on ADNI the multi-shell sessions (b500/1000/2000) would be fitted on b1000 + b2000 and
  the single-shell ones on b1000 only, and the fODF shapes would differ by protocol. The pipeline
  already has the option to avoid it: `fodf_shells: "1000"` (with `dwi_shell_tolerance` 20) fits
  every session on b0 + b1000 only. The response is already fixed for every subject
  (`manual_frf = "15,4,4"`). So the FC module reuses TractoFlow's fODFs, run with
  `fodf_shells: "1000"` and one `sh_order` for the whole study, and only converts them from the
  scilpy `descoteaux07` basis to MRtrix's (`scil_sh_convert`). This also makes AFD and NuFO
  consistent across protocols.

## Design

Two steps, because a template is a cohort-level object and the per-session step must use the same
template for every session of a study.

1. **Template build (once per study):** a pipeline mode, `--fc_build_template`, given the list of
   template sessions. Output: a versioned template directory, given as input to every later run.
2. **Per session:** `--run_fibre_cross_section --fc_template <dir>`, inside the normal run, after
   TractoFlow.

### Template directory (output of step 1, input of step 2)

| File | Content |
|---|---|
| `fod_template.mif` | population fODF template (`population_template`) |
| `template_mask.mif` | intersection of the warped brain masks |
| `fixels/` | template fixels (`fod2fixel` on the template, peak threshold as in the MRtrix FBA guide) |
| `bundles/<bundle>.mif` | one fixel mask per IIT bundle (see decision D3) |
| `template_fa.nii.gz` | mean FA of the template sessions in template space (for the IIT registration and QC) |
| `manifest.json` | template sessions, software versions, parameters, SHA-256 of every file |

The per-session CSV carries the manifest's hash, so values from two templates can never be pooled
by mistake.

### Per-session steps (MRtrix 3.0.5, `mrtrix3/mrtrix3:3.0.5`, already on vitalTour)

1. TractoFlow's fODF (fitted on b0 + b1000 with `fodf_shells: "1000"`) and brain mask.
2. Convert the fODF to MRtrix's basis (`scil_sh_convert descoteaux07 tournier07`, legacy flags
   to check in the prototype). A run that has no b≈1000 shell (ADNI GE b1300-only runs) is
   refused at startup with a clear message rather than failing in TractoFlow.
3. Registration: `mrregister` fODF to `fod_template.mif`, affine + non-linear, with masks.
   Output: subject-to-template and template-to-subject warps.
4. `mrtransform` the fODF into template space without reorientation, `fod2fixel` in the template
   mask, `fixelreorient` with the warp, `fixelcorrespondence` to the template fixels.
5. `warp2metric -fc` on the subject-to-template warp, then log FC (`mrcalc -log`).
   Also FD (from step 4) and FDC = FD x FC, kept as secondary outputs.
6. Per bundle: mean and median log FC over the bundle's template fixels (`mrstats -mask`), and
   the number of fixels with a correspondence.
7. QC per session:
   - correlation between the warped fODF's l=0 image and the template's, in the template mask;
   - fraction of template fixels without correspondence, per bundle;
   - minimum Jacobian determinant of the warp (`warp2metric -jdet`), folding flagged below 0.
   Flags in a `qc_flags` column, as in the volume files.

Output per run: `<prefix>_space-template_desc-fc_stats.csv` with
`sid, session, run, bundle, log_fc_mean, log_fc_median, fd_mean, fdc_mean, n_fixels,
fixels_unmatched_fraction, registration_corr, min_jacobian, qc_flags, in_template,
template_hash`, collected into `metrics/space-template_desc-fc_stats.csv` with the participants'
covariates, like the other metric files.

`in_template = 1` marks sessions used to build the template: normativeGNN must keep them out of
the test folds (they shaped the reference).

### Template build steps

1. Read the list of template sessions (TSV: sid, session, run), check each one exists.
2. Per template session: steps 1-2 above (TractoFlow's fODF, converted).
3. `population_template` on the fODFs and masks (16 CPUs, several hours for 40 sessions).
4. Template fixels: `fod2fixel` on the template.
5. Template FA and mean b0: warp each template session's FA and b0 with its warp, average.
6. IIT to template: the pipeline fetches the IIT mean b0 (`IITmean_b0.nii.gz`), not an IIT FA.
   Register it to the template's mean b0 once with ANTs SyN (one registration for the whole study,
   checked visually), warp the IIT bundle maps, threshold each at the IIT recommended value.
   This is still a b0 registration, but done once on a sharp group average, and it only places the
   bundles: the per-session FC comes from the fODF registration.
7. Bundle fixel masks (decision D3).
8. Write `manifest.json`.

## Decisions needed before coding

| | Question | Recommendation |
|---|---|---|
| D1 | Which fODF | TractoFlow's, with `fodf_shells: "1000"` for every session (fixed response already). Then choose one `sh_order` for the study: 6 (stable with ADNI2's 32-41 directions) or 8 (the default, unstable there according to the pipeline README); the same choice also sets AFD and NuFO. |
| D2 | Template sessions | About 40 HC from the normativeGNN reference partition, one session per person, balanced across single-/multi-shell protocol, vendor, sex and age; excluded from test folds. |
| D3 | Which template fixels belong to a bundle | v1: every template fixel inside the thresholded bundle mask (simple, but a crossing region counts both bundles' fixels in each). v2: only fixels aligned with the bundle, through a template tractogram filtered by the bundle masks and `tck2fixel`. Start with v1, add v2 if crossing contamination shows in the prototype. |
| D4 | Template build inside the pipeline or as a separate script | Inside, as a mode: same containers, same versions, checksummed output. |
| D5 | Branch | `samseg-fc-runs`, as renamed. |

## Files

| File | Content |
|---|---|
| `modules/local/image/shconvert/main.nf` | step 2 (basis conversion), unless an nf-neuro module already does it |
| `modules/local/registration/fodtemplate/main.nf` | step 3 (`mrregister`) |
| `modules/local/stats/fibrecrosssection/main.nf` | steps 4-7, writes the CSV |
| `modules/local/template/fodpopulation/main.nf` | template build steps 2-4, 8 |
| `modules/local/template/bundlefixels/main.nf` | template build steps 5-7 |
| `subworkflows/local/fc_template/main.nf` | the template build mode |
| `subworkflows/local/fibre_cross_section/main.nf` | the per-session chain |
| `workflows/sf-tractomics.nf` | params, wiring, collection, coverage check (as `checkVolumeCoverage`) |
| `nextflow.config`, `nextflow_schema.json` | `run_fibre_cross_section`, `fc_template`, `fc_build_template`, `fc_template_sessions`, `fc_shell` (startup check only) |
| `conf/modules/*.config` | resources: per session 8 CPUs, 8 GB, about 30 min; template 16 CPUs, 32 GB, 24 h |
| `docs/usage.md`, `docs/output.md`, `CHANGELOG.md`, `README.md` | options, outputs, limits |

Validation errors at startup: `run_fibre_cross_section` without `fc_template`; a template whose
manifest hashes do not match; `fc_build_template` without a session list.

## Tests

1. Module stub tests for each module (outputs and names).
2. Known answer, aggregation: synthetic fixel data with known values and bundle masks; the CSV must
   give the exact mean, median and counts.
3. Known answer, FC: a synthetic warp that scales uniformly by s gives FC = s² on every fixel
   (cross-section area); a scaling along the fixel direction only gives FC = 1.
4. Pipeline stub tests: the mode builds a template directory; a run with a template writes one
   CSV row set per DWI run, `in_template` set on the template sessions, the hash present.
5. Startup errors above.

## Phases and decision gates

1. **Prototype script** (bash, the two containers) on the 10 DWI runs of the ADNI test, after its
   stage 2. Template from those 8 sessions (too small to be a reference, enough to run every
   command). Checks: commands, runtimes, memory, lmax 8 on 32-41 directions, single- vs
   multi-shell values, plausible log FC (near 0 in HC; AD below in cingulum, fornix region,
   posterior callosum).
   **Gate 1:** runs and values plausible.
2. **Modules and tests** (above), on `samseg-fc-runs`; all pipeline tests pass.
3. **Template** of about 40 HC on a cluster.
4. **Validation** on a few hundred ADNI sessions (cluster): test-retest ICC per bundle on
   short-interval repeats; AD vs HC effect size per bundle after ICV; correlation with T1 total WM
   (positive), ventricular volume (moderate, not near 1), FA (moderate); comparison with the
   atlas bundle volumes on the same checks.
   **Gate 2:** reproducible and a disease signal, better than the atlas volumes; otherwise stop.
5. **Cohort** (3,600 sessions, about 1,000-2,000 CPU-hours), then normativeGNN: normative model on
   HC (age, sex, ICV), ComBat as for FA/MD, node feature on the bundle nodes, AUC with and without.

## Risks

- **Distortion:** most ADNI sessions have no reverse b0, so EPI distortion stays in the temporal
  lobe; the fODF registration absorbs part of it into FC there.
- **Protocols:** b1000-only fitting removes the shell difference but not the resolution and
  direction-count differences (ADNI2 vs ADNI3); compare distributions by protocol (validation).
- **Global atrophy:** FC tracks global atrophy strongly, so 42 bundle values may carry few
  independent signals; test with and without adjustment.
- **Template from HC only:** large AD deformations are within `mrregister`'s range in published
  AD work (Mito 2018, Dewenter 2023), but check registration QC by diagnosis.
