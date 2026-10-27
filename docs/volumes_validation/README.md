# Subject volumes for atrophy studies

Validation on OASIS-3 of the subject volumes computed by sf-tractomics
(branch `volumes-iit-roi-gm-wm`, commit `d7b2e09`, 27 October 2026).

The pipeline now measures white matter, grey matter and ventricles on each subject's own scan
instead of reporting the size of a warped atlas. On OASIS-3, both new methods are precise enough to
detect atrophy at group level. Neither method is the most precise for every structure, so choose
the method from the structures your study is about. Measurement error between two scans of the
same session is about 0.1 to 3%, which is enough for group comparisons but too large to follow a
single subject over one or two years.

## Why the old volumes could not measure atrophy

Before this change, every region volume came from a standard atlas warped onto the subject. The
number mostly reflected how much the registration stretched the atlas, not the size of the
subject's own structure. The label warp also used `MultiLabel` interpolation, which changes label
sizes even under an identity transform. The smallest ventricles lost up to 71% of their volume that
way.

That version is kept as tag `v1.0dev-atlas-volumes` for reproducibility. Its volumes should not be
used for atrophy, and they are not comparable with the new ones.

## What the pipeline does now

Volumes are counted in the subject's native T1 space from one of three segmentations. The results
land in the same CSV files as before.

| Setting | Segmentation | Use when |
|---|---|---|
| `volume_source = 'synthseg'` | SynthSeg 2.0, each scan alone | Cross-sectional data, or WM and cortex outcomes |
| `run_longitudinal_volumes = true` | FreeSurfer SAMSEG longitudinal, all sessions of a subject together | Repeated sessions, ventricle, amygdala or ICV outcomes |
| `volume_source = 'freesurfer'` | Your existing FreeSurfer `aparc+aseg` | FreeSurfer already run outside the pipeline |
| `volume_source = 'atlas'` (default) | Warped atlas, previous behaviour | Not for atrophy |

When the input holds several sessions per subject and `run_longitudinal_volumes` is off, the run
prints a warning recommending it.

## How the two methods were compared

A method is precise when its volumes do not move when the brain has not changed. Two tests measure
that:

- **Repeat scans.** 8 OASIS-3 subjects with two different T1 acquisitions in the same session.
  Any difference between the two volumes is measurement error. Reported as the median
  |difference| in % of the pair mean. 4 more pairs were run but excluded: their two files hold the
  same voxels (the same acquisition exported twice), so their difference is 0 by construction.
- **Follow-up.** 8 subjects (4 healthy, 2 MCI, 2 AD) with 3 sessions over 3 to 8 years on the same
  scanner. Noise is the scatter around each subject's straight-line trend, in % of the subject's
  mean. The slope gives a yearly rate of change.

All 4 pipeline runs finished with no failure. Every SynthSeg QC score was 0.66 or above, and no
sample received a QC flag. The 4 excluded pairs should have been flagged as duplicates: the
duplicate check then compared file bytes only, and it now compares voxel data (see Safeguards).

## Results

Values in %, given as SAMSEG longitudinal / SynthSeg cross-sectional. Lower is better.
"More precise" names a winner only when both tests agree; otherwise it reads "mixed".

| Structure | Repeat median | Repeat worst pair | Follow-up noise | More precise |
|---|---|---|---|---|
| Hippocampus | 0.94 / 1.18 | 3.39 / 5.42 | 1.45 / 0.92 | mixed |
| Lateral ventricles | 0.93 / 0.73 | 4.04 / 0.98 | 2.04 / 2.67 | mixed |
| Inferior lateral ventricles | 2.91 / 1.91 | 16.43 / 10.78 | 6.63 / 3.19 | SynthSeg |
| Amygdala | 0.89 / 2.21 | 6.37 / 11.95 | 0.63 / 1.91 | SAMSEG |
| Thalamus | 0.48 / 1.12 | 0.81 / 2.47 | 0.63 / 0.54 | mixed |
| Cerebral white matter | 1.42 / 0.14 | 2.50 / 0.58 | 0.71 / 0.21 | SynthSeg |
| Cerebral cortex | 1.71 / 0.80 | 2.83 / 2.35 | 0.53 / 0.29 | SynthSeg |
| Intracranial volume | 0.10 / 0.37 | 0.63 / 1.20 | 0.19 / 0.16 | mixed |

Thalamus and intracranial volume favour SAMSEG on repeat scans and are about equal on follow-up.

## Yearly change

Median % change per year, SAMSEG / SynthSeg.

| Structure | Healthy (n=4) | AD/MCI (n=4) |
|---|---|---|
| Hippocampus | -0.33 / -0.40 | -0.95 / -1.08 |
| Lateral ventricles | +3.22 / +4.91 | +1.98 / +2.71 |
| Inferior lateral ventricles | +3.03 / +1.67 | +2.42 / +3.36 |
| Amygdala | -0.19 / -0.55 | -0.30 / -0.41 |
| Thalamus | -0.47 / -0.56 | -0.61 / -0.92 |
| Cerebral white matter | -0.38 / -0.39 | -0.28 / -0.51 |
| Cerebral cortex | -0.38 / -0.32 | -0.92 / -0.66 |
| Intracranial volume | -0.02 / -0.10 | -0.09 / -0.22 |

Both methods find the expected direction of change: ventricles grow and tissue shrinks. The
hippocampus shrinks about three times faster in AD/MCI than in healthy subjects with both methods,
the clearest disease signal in this sample.

With 4 subjects per group, these rates show plausibility only; they are not effect sizes. For
example, the lateral ventricles grow faster in the healthy group here, which would need a larger
sample to confirm or refute.

## What this means for a study

**Choose the method from your main outcome, then use only that method for the whole analysis.**
SAMSEG longitudinal is more precise for the amygdala, and on repeat scans for the thalamus and
intracranial volume. SynthSeg is more precise for cerebral white matter, cortex and the inferior
lateral ventricles. The hippocampus and lateral ventricles favour one method on each test, so
neither has a clear advantage there.

1. **Never mix methods.** Absolute volumes differ between them: the lateral ventricles of one
   subject measured about 8 mL with one method and 13 mL with the other. The `volume_source`
   column records which method produced each row.
2. **Atrophy is detectable in groups, but single-subject change over a short time is not
   reliable.** Typical repeat error is about 1% for the hippocampus, while healthy hippocampal loss
   is about 0.35% per year, so one subject's change over one or two years is mostly noise.
   Worst-case pairs reach 3 to 5% for the hippocampus and 16% for the small inferior lateral
   ventricles. Group comparisons and longer follow-up are much more robust than individual
   trajectories.
3. **Model the scanner.** In one subject, a scanner change moved volumes by 2.5 to 3.5% at once
   (ICV +2.5%), more than several years of atrophy. Add the `scanner` column as a covariate or keep
   each subject on one scanner. The run warns when a subject changes scanner.
4. **Exclude duplicated scans.** In this copy of OASIS-3, 1050 of the 1628 sessions with two T1
   runs (64%) hold the same voxels in run-01 and run-02; 20 of them differ only in header or
   compression bytes. They are not independent measurements. The pipeline fills `duplicate_of`
   and flags them.
5. **Review flagged samples.** The `qc_flags` column lists low SynthSeg QC, missing or implausible
   ICV, ICV drifting across sessions (over 3%), empty regions and duplicates. A clean flag is not
   proof of a correct segmentation, so inspect outliers visually.
6. **Add white-matter lesions back to white matter where lesions grow.** SAMSEG and FreeSurfer
   report `WM-hypointensities` as their own region. In one MCI subject they grew 34%. Left out,
   that growth looks like white-matter loss.
7. **Normalise by intracranial volume** from the `icv_mm3` column. It is the most stable measure
   here (repeat error 0.1 to 0.4%).

## Safeguards added to the pipeline

The work also looked for errors that would silently corrupt an atrophy analysis. Each one below is
now fixed and covered by a test.

- **Mixed subjects.** Volumes are paired with their own subject, session and run, never by file
  path alone. An integrity test runs the full pipeline on several subjects, sessions and runs and
  checks every row against a known answer.
- **Missing samples.** A session without a segmentation stops the run and is listed in
  `metrics/volumes_missing_samples.txt`. `allow_missing_volumes = true` accepts the gap but still
  lists it.
- **Fake zeros.** Regions a method cannot produce, such as choroid plexus with SynthSeg, are left
  empty instead of written as 0.
- **Label distortion.** All label warps now use `GenericLabel`. A test checks that an identity warp
  keeps every voxel and that a one-voxel shift keeps every count.
- **Lost rows.** Diffusion statistics of a sample without volumes are kept. Covariates are filled
  for volume rows in the combined table. Row order is deterministic.
- **Duplicates.** A T1 whose voxel data match another sample's T1 is flagged, even when the two
  files differ in header or compression. The integrity test uses such a re-exported file.
- **Traceability.** Each row carries `volume_source`, `scanner`, `qc_score`, `qc_flags`,
  `duplicate_of` and `pipeline_revision`.

21 automated tests pass. They include known-answer tests for ROI volumes, ROI metrics, label warps,
DTI metrics and CSV concatenation.

## Checks of the OASIS-3 output files

Every CSV and the combined TSV of the 4 runs were checked independently of the pipeline code:

- **Values.** Each of the 8874 volumes equals a recount of the labels in that sample's own
  published segmentation, and each ICV and QC score equals the segmenter's own table.
- **Pairing.** In the follow-up runs, each SAMSEG segmentation overlaps the SynthSeg segmentation
  of its own session best (white-matter Dice at least 0.85, against at most 0.71 for another
  session of the same subject), so no session received another session's segmentation.
- **Missing values.** No sample, region or row is missing or duplicated, and every line has as many
  fields as its header. Empty cells are only the expected ones: choroid plexus and lesions with
  SynthSeg, no QC flag, no duplicate, no SynthSeg score with SAMSEG, and covariates in the
  repeat-scan runs, which were given no participants file.
- **Region names.** Every label number has FreeSurfer's own name for it, and in every
  segmentation each Left- or lh region lies to the left of its Right- or rh twin.
- **Rows and columns.** Every cell of the combined TSV equals the same cell in the per-type file,
  `region_type` matches the file each row came from, covariates match `participants.tsv`, and the
  scanner matches each T1's sidecar.

## Limits

- Small sample: 8 repeat pairs and 8 follow-up subjects, all from OASIS-3 (Siemens scanners).
- Three sessions per follow-up subject leave one degree of freedom per noise estimate, so
  follow-up noise is itself noisy.
- These tests measure precision, not accuracy. Which method is closest to true anatomy would need
  a reference such as manual tracing.
- SAMSEG resamples every session to 1 mm, and SynthSeg works at 1 mm internally, so neither result
  says anything about sub-millimetre detail.
