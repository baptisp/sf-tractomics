# sf-tractomics in passes, with or without batches (cohort/)

This repository runs sf-tractomics on the sessions listed in `inputs/participants.tsv`. Metrics
are turned on in successive **passes**, and each pass reuses everything earlier passes computed.

It runs in two modes:

- **Without batches** (`BATCH=false`, the default) it works as on vitalTour: one folder, one
  `work/` and nothing packed.
- **With batches** (`BATCH=true`, Rorqual or Fir) the subjects are split into batches. Each batch is
  packed into one archive file between passes, because the scratch inode quota cannot hold the whole
  cohort's `work/`.

The pipeline is the same in both modes. A session run alone on vitalTour and the same session
run in a batch on a cluster go through the same tasks with the same parameters.

On a cluster, nothing heavy runs on the login node. Every download, copy and pipeline run is a
Slurm CPU job; no step needs a GPU.

## Layout

```
run.sh                    entry point: ./run.sh [--batch|--no-batch] setup | submit PASS | status | merge
config.env                machine, BATCH, BATCH_SIZE, MAX_UNPACKED, account, pipeline commit, input folder
params/shared.yaml        parameters of every pass (anything that changes a task an early pass computes)
params/passes/<k>_*.yaml  what pass k turns on, run in the order of k
configs/vitaltour.config  local executor + Docker      configs/alliance.config  Slurm + Apptainer
inputs/participants.tsv   the sessions to process (subject, session, run, covariates); not in git
                          (participant data, and the fork is public): format in participants.example.tsv
scripts/                  setup_steps.sh, lib.sh (one pass in one folder), batch.sh (lock, pack,
                          unpack), passes.py, make_batches.py, merge_batches.py, reuse_report.py,
                          setup.sbatch, head.sbatch, batch_job.sbatch
tests/                    test_python.py, test_batch.sh, test_flow.sh (no cluster needed)
```

## Use

```bash
git clone -b samseg-fc-runs https://github.com/baptisp/sf-tractomics.git && cd sf-tractomics/cohort
# edit config.env; put the FreeSurfer licence (license_freesurfer.txt) and inputs/participants.tsv here
./run.sh setup              # cluster: a job (~1-2 h); vitalTour: in the foreground
./run.sh submit 1_volumes   # cluster: one head job, or one array task per batch; vitalTour: foreground (tmux)
./run.sh status
./run.sh submit 2_metrics   # once 1_volumes is done
./run.sh merge              # batches: the cohort tables in merged/
```

The pipeline is the sf-tractomics checkout this folder sits in. Each launch folder pins the
pipeline version of its first pass: the last commit that changed a file outside `cohort/`. Editing
the wrapper is not a new pipeline version; a pipeline change, committed or not, is refused.

Setup does the following:
- installs Nextflow `NXF_VER` in this folder;
- pulls the images (clusters, one at a time; Docker pulls them itself on vitalTour);
- checks the parameters of every pass with `-preview`, which also downloads the atlases and the
  Nextflow plugin.

Without batches it also copies every session into `data_bids/`. The setup job first checks that the
compute node reaches the internet. Fir's compute nodes do.

Rorqual's compute nodes do not (`OFFLINE=true` in `config.env`). Run setup on Fir first, then copy
these items of its `cohort/` into the same place on Rorqual (Globus; about 16 GB, mostly images):
`containers/`, `.nextflow_home/`, `bin/`, `.atlas_cache/`, `work/atlas_iit/` and
`license_freesurfer.txt`. Nothing else: `config.env` and the scripts come from git, and the rest is
Fir's runs. Setup on Rorqual then downloads nothing: it checks that each copied item is there, and
runs the previews with `NXF_OFFLINE=true`, as every later run does. The pipeline skips an atlas
download when the file is already there, and each batch takes the atlases from this folder.

## Passes

Pass k runs with `params/shared.yaml` and passes 1 to k together. Every task of an earlier pass is
therefore asked for again with the same parameters, and Nextflow reuses it instead of computing
it. `scripts/passes.py` enforces the rules that make this hold, on every pass file at every call:

- **A pass may not set a parameter of `shared.yaml`.**
- **A parameter set by two passes keeps its value, or goes from `false` to `true`.** Changing a
  value or turning a metric off would change, or drop, what an earlier pass computed.
- **Passes run in order.** Pass k is refused in a folder where pass k−1 has not ended with exit 0.

After each pass, `logs/reuse_<pass>_<id>.txt` lists the tasks of earlier runs that were computed
again, which should be none. To add metrics later, add `params/passes/3_<name>.yaml`.

## Launch folders and what they pin

A launch folder is where one Nextflow history lives: the root folder without batches, or each
`batches/bNNNN/` with them. Its `meta/` records:

| File | Purpose | Refused when |
|---|---|---|
| `inputs.sha256` | checksums of `data_bids/`, including `participants.tsv` | the inputs change. The covariates are in every task's metadata, so any change would recompute everything |
| `pipeline_commit` | the pipeline version of its first pass | another version is used, or a pipeline file is modified. A changed module recomputes, and the cohort would mix versions; `ALLOW_COMMIT_CHANGE=1` overrides |
| `session_id` | the Nextflow session of its first run | — every later run resumes it, never a plain `-resume` (which could pick a `-preview`) |
| `passes_done` | the passes that ended with exit 0 | — |
| `params_<pass>.yaml` | the parameters each pass ran with | — |

The mode is pinned too: a root folder set up with one `BATCH` value refuses the other.

## Batches (`BATCH=true`)

- **Which subjects go where.** `batches/list.tsv` assigns subjects to batches, never splitting a
  subject, until a batch holds `BATCH_SIZE` sessions. Once written, the list never changes. New
  subjects go to new batches; a subject removed from `inputs/participants.tsv` is an error.
- **One job per batch and pass.** `./run.sh submit PASS` submits a Slurm array with one task per
  batch that hasn't done PASS (`FORCE=1` to rerun them; `BATCHES="b0001 b0002"` for those batches only), at most `MAX_UNPACKED` at once. Set it from
  the free inodes divided by the inodes of one unpacked batch. Each task does:
  1. lock the batch;
  2. the first time, copy its subjects' sessions from `INPUT_BIDS` (or extract
     `inputs/batch_tars/bNNNN.tar`) and hard-link the atlases; later, unpack its archive;
  3. run the pass;
  4. pack, even after a failure;
  5. unlock.
- **A failed session does not stop the others.** A task that still fails after its retries
  (memory, time, node: see `configs/*.config`) is left (`errorStrategy 'ignore'`), so the other
  sessions of its batch finish. Each run lists those tasks in `out/metrics/failed_tasks.tsv` (also
  `logs/failed_tasks_<pass>_<job>.tsv`): batch, pass, run name, subject, session, run, process,
  exit status, attempts, last error line and work folder, one row per task. The file is in the
  archive and the extracted results, and `./run.sh merge` gathers it into
  `merged/failed_tasks.tsv`; the sessions left without volumes are in
  `metrics/volumes_missing_samples.txt` (`allow_missing_volumes: true` in `params/shared.yaml`).
  The pass counts as done, so a later pass goes on with the other sessions (and tries the failed
  tasks again: a failure is not cached). When more than `MAX_FAILED_FRACTION` (default 0.5) of a
  batch's DWI runs failed, the cause is a bug rather than a run: the pass is not marked done.
  Once a failure is fixed, rerun the batch with `FORCE=1 BATCHES="bNNNN" ./run.sh --batch submit PASS`.
- **What is packed.** `.nextflow/`, `work/`, `.atlas_cache/`, `data_bids/` and `out/` go into
  `archives/bNNNN.tar`; `meta/` and `logs/` stay. Results are published as hard links into `work/`,
  which tar stores once, so `out/` costs the archive almost nothing, and after an unpack its files
  are hard links again. The inputs are packed too: a batch's input data costs inodes only while it
  runs. A packed batch is about 25 files whatever its size.
- **Extracted results.** Each pack also writes `batches/bNNNN/extracted_results.tar.gz`: the files of
  `out/` matching `EXTRACT_PATTERNS` (`config.env`; by default the `metrics/` tables and the global
  MultiQC report; add per-session patterns such as `**/*_desc-thickness.csv`). It is a copy, replaced
  at every pack, so a later pass updates it; the full results stay in the archive
  (`scripts/extract_results.sh` in a job reads one back, see below).
- **No two jobs in one folder.** `./run.sh submit` refuses while any job of this root folder is
  queued. Each batch also has a lock that holds even if two jobs take over a dead job's lock at the
  same moment.
- **Crash safety.** `meta/state` (`unpacked`, `packing`, `packed`) is always written whole. Packing
  goes in this order:
  1. write the archive as `.part`;
  2. check its entries against the folder;
  3. rename it over the previous archive;
  4. set the state to `packing`;
  5. delete the folders;
  6. set the state to `packed`.

  Unpacking first removes what a killed extraction left. The archive is never deleted, only replaced
  by a newer verified one. A job killed at any step leaves a state the next job completes.
- **Walltime.** 30 minutes before a job's walltime, Nextflow is asked to stop. It cancels its task
  jobs and keeps its cache, and the batch is still packed. Every task job carries the batch in its
  Slurm comment, so packing also cancels, and waits for, any task job left behind.
- **Merging.** `./run.sh merge` concatenates the batches' `metrics/` tables, read from their
  `extracted_results.tar.gz`, into `merged/`, one header each. A table whose header differs between
  batches is refused.
- **Fixed paths.** A batch folder never changes path: Nextflow's cache and links hold absolute
  paths. It can change cluster, at the same path (next section).

- **Finished archives leave scratch.** A batch done with every pass of `params/passes/` moves its
  archive to `ARCHIVE_STORE` (`config.env`; on Rorqual
  `/project/rrg-descotea/vitalab/pierrard/adni/finished_archives/<COHORT_NAME>`: batch names restart at
  `b0001` in every cohort, so cohorts never share a folder), with a copy of its
  `extracted_results.tar.gz` and of its `meta/` and `logs/` (`bNNNN_meta.tar`), so the store alone
  can resume it after a scratch purge. The copy is compared byte for byte before the scratch archive
  is deleted; any failure keeps it on scratch. `meta/archive_location` records where it went. A pass
  added later unpacks straight from the store and stores the new archive over the old one.

**Not yet automated:**
- **The scratch purge of unfinished batches.** Archives waiting for a later pass stay on scratch and
  must not sit unused past the purge window.
- **Inputs on a cluster without ADNI (Fir).** Copy them into `INPUT_BIDS`, or as per-batch archives
  in `inputs/batch_tars/`, one file per batch.

## Moving batches between clusters

A batch can run its passes on several clusters, one at a time, and resume on each from where the
other stopped. The FreeSurfer steps and every other finished task are reused, not recomputed.

**Why it works.** Nextflow reuses a task when its hash matches an entry of the run's cache. With the
pipeline's `cache = 'lenient'` (Slurm profile), the hash holds:
- the session id;
- the task's script;
- the container image's path;
- each input file's absolute path and size (not its date).

Everything that varies by cluster is kept the same:
- **Path.** The cohort folder has the same absolute path on every cluster:
  `/scratch/pierrard/sf-tractomics/cohort`, a real path on both Rorqual and Fir.
- **The batch's own files.** Its cache (`.nextflow/`), `work/`, inputs and atlases travel inside
  its archive.
- **The shared files.** These must be identical on both clusters: the pipeline commit, the
  Nextflow version and its plugin (`.nextflow_home/`), the images in `containers/` (same names),
  `license_freesurfer.txt`, and the atlases of `setup`.

**One owner at a time.**
- A batch runs only on the machine recorded in its `meta/owner`. Without that file, the owner is
  `HOME_CLUSTER` (`config.env`).
- Taking a batch's lock (`batch_lock`) checks the owner, before and once held. Every job that
  touches a batch takes that lock, so a batch that left never runs again where it was. This holds
  even for an array task queued before it left, or before this check existed: Slurm keeps the job
  script, but the scripts it sources are read when it starts.
- Every change of owner is appended to `meta/owner_history`.

**Moving batches:**
1. On the cluster that has them:
   ```
   ./run.sh --batch handoff fir b0230 b0231 ...
   ```
   - Only packed or never-prepared batches can move, never one in use.
   - Each batch becomes `transit:fir`, and then runs nowhere.
   - What to copy is staged in one folder, `transfers/<date>_<from>_to_fir/`, laid out like the
     cohort folder:
     - the batch folders;
     - their archives and input tars, as hard links (no space, no inode);
     - `manifest.tsv`, which `adopt` checks.
2. Copy that folder, with Globus and its checksum verification, to **the same path** on the other
   cluster.
3. On the other cluster:
   ```
   ./run.sh --batch adopt transfers/<date>_<from>_to_fir
   ```
   - It first checks that both clusters run the same cohort: `batches/list.tsv`, `inputs/*.tsv`,
     `params/`, `configs/alliance.config`, the pipeline commit and the Nextflow version.
   - It checks that every archive and input tar arrived complete (sizes from the manifest).
   - It checks that every batch is in transit to this cluster, and that none it already runs would
     be overwritten.
   - Only if everything is right, it moves each batch's folder, archive and input tar into place.
     What they replace is kept in the transfer folder's `replaced/`: for a batch coming back, these
     are this cluster's copies from before it left.
4. `./run.sh submit PASS` there runs it. `submit` only lists batches this machine owns, and
   `./run.sh status` shows each batch's owner.

**Afterwards:**
- Delete the transfer folder on both sides once the batches run (`replaced/` included).
- On the sending side, the batch's own `archives/bNNNN.tar` is stale and can be deleted too.
- A batch never prepared needs its input tar (`inputs/batch_tars/bNNNN.tar`), or an `INPUT_BIDS`
  on the receiving cluster.

## Using the results downstream

What the tables mean, and what not to do with them. Numbers in brackets were measured on one ADNI
subject (88 years, AD, Siemens Prisma, 2 sessions a year apart; Fir test of 2026-11-05): they show
the size of each effect, not cohort values.

**Tables.** `merged/` (`./run.sh merge`) holds the cohort tables;
`space-native_all-regions_desc-roi_combined.tsv` is the one to start from: one row per
`(sid, session, run, roi, region_type, source)`, volumes and diffusion metrics side by side. Every
other table is a cross-check of it (each volume of the combined table equals its source table).
Sessions with several DWI runs have one row per run: pick or average runs explicitly.

### Volumes: which source

- **Use `source == "reconall"` for GM regions and ventricles.** recon-all is the main source;
  SynthSeg (`synthseg`) is a second opinion. Never mix sources in one analysis: they differ
  systematically by region (SynthSeg cortex +20 %, pallidum −50 %, accumbens +60 to +90 % relative to
  recon-all), while ranking regions alike (Spearman 0.96).
- **Normalise by the ICV of the same source** (`volume_icv_fraction`, `icv_mm3`). The ICVs of the two
  sources differ (SynthSeg −4 %); the atlas rows have no ICV.
- **Do not use the atlas volumes (`source == "atlas"`) of the ventricles, nor of the regions next to
  them.** Atlas regions are the MNI152 FreeSurfer labels (CSF atlas) or IIT labels (GM regions, WM
  bundles) warped onto the subject's b0 by an ANTs SyN registration of the IIT b0 template; they are
  not a segmentation of the subject. Measured against the subject's recon-all ventricles in DWI space:
  - the atlas ventricles are in the right place (99 % of their voxels lie inside the subject's
    ventricles, centroids within 2 mm, 95 % of their voxels have CSF intensity on the b0), and the
    registration checks pass (b0 correlation 0.88, brain Dice 0.96);
  - but they cover only part of the subject's ventricles: lateral ventricles 49–58 %, 3rd 40 %,
    4th 26 %, inferior lateral ventricles 1–11 % (atlas 37 mm³ against 2,666 mm³);
  - the cause is the template, not a misregistration: the template's ventricles are those of young
    adults, and the regularised registration does not stretch them to an enlarged ventricle (age,
    atrophy). The gap therefore grows with ventricle size, that is with age and disease.
  - the rest of the subject's ventricles falls in the atlas caudate, cerebral WM, WM hypointensity and
    choroid plexus labels. Those atlas regions hold CSF in an atrophied brain: their volumes are
    wrong, and their diffusion metrics mix in CSF.
- **The `CSF` region is not the same structure in each source**: SynthSeg's covers all the external
  CSF (260,000 mm³), FreeSurfer's label 24 a small region (1,000 mm³). Never compare or pool it.
- **SynthSeg has no choroid plexus**: those rows have an empty volume.

### Diffusion metrics: where they come from

- **WM bundles, atlas GM regions, atlas CSF regions**: atlas route (`source == "atlas"`), so the
  caveat above applies to every region bordering a ventricle (caudate, thalamus, corpus callosum,
  fornix, periventricular WM). In those regions prefer the free-water-corrected metrics (`fat`,
  `mdt`, `rdt`, `adt`) and keep `fwf` as a covariate: an uncorrected FA or MD there partly measures
  ventricle size, which tracks age and diagnosis, a confound for a classifier.
- **Subject GM regions** (`region_type == "GM_region"`, `source == "reconall"`): fraction-weighted
  means in the subject's own recon-all regions (the first subject source of `volume_source`). The
  SynthSeg rows carry volumes only.
- **Ventricles have diffusion metrics from the atlas route only** (`source == "atlas"`,
  `region_type == "CSF_region"`); the subject-segmentation metrics cover GM regions. Inside CSF the
  tensor measures free water, not tissue, so these rows are a quality check rather than a feature:
  in the atlas lateral ventricles MD ≈ 2.9·10⁻³ mm²/s and `fwf` ≈ 0.93, as expected for labels lying
  inside the ventricle. A clearly lower `fwf` there means the label reaches tissue (misregistration).
- **The same metrics reveal the atlas problem above in the regions next to the ventricles**: the atlas
  caudate has `fwf` 0.38–0.46 and MD 1.2–1.4·10⁻³ mm²/s, against 0.11–0.13 and 0.8·10⁻³ in the
  thalamus: a third of its signal is CSF. Use the `fwf` of the atlas caudate as a per-session index
  of that contamination (it grows with ventricle size).

### Longitudinal use

Each session is processed on its own (`run_longitudinal_volumes: false`), so a difference between two
sessions holds segmentation noise of the size of a year of atrophy (recon-all GM regions: median
−1 % a year, but single regions from −28 % to +9 %, e.g. the temporal pole). Ventricles are steadier
(+4 to +6 % a year, both segmentations agreeing). For atrophy rates, fit a slope over several
sessions rather than a difference of two, or add a later pass with `run_longitudinal_volumes: true`
(SAMSEG longitudinal, one subject template). For a prediction from the baseline visit, do not use
values from a longitudinal template: it is built with the follow-up scans, information the
prediction must not have.

### Quality flags: exclude, the pipeline never does

- `metrics/space-native_desc-atlasregistration_qc.csv`: `misaligned` (b0 correlation below 0.6) or
  `brain_mismatch` (brain Dice below 0.85) for an atlas registration. Drop the atlas rows of a
  flagged run.
- `qc_flags` of the volume tables: `icv_drift` (a session's ICV more than the allowed fraction away
  from its subject's median, `volume_icv_drift`: a failed segmentation or a scanner change).
- `metrics/dwi_input_report.tsv`: which DWI runs were kept or dropped, and why.

### Acquisition differences to model

ADNI mixes GE and Siemens scanners, sessions with and without a reverse phase-encoding field map
(without one, no susceptibility distortion correction: frontal and temporal regions near air keep
their distortion) and single- or multi-shell protocols (NODDI only on multi-shell). Carry the
scanner (`scanner` column), the protocol and the presence of a field map into the harmonisation and
the models as batch variables.

### Provenance

`pipeline_revision` is the commit of the pipeline code that produced a table. Results of different
revisions must not be mixed unknowingly; `meta/pipeline_commit` (and `pipeline_commit_history`) of
each batch says which commit each batch ran.

### Reading a result that is not in `extracted_results.tar.gz`

In a Slurm job (never on a login node):
`scripts/extract_results.sh bNNNN DEST 'out/sub-*/ses-*/anat/*_desc-thickness.csv'` extracts the
matching files of the batch archive into `DEST`.

## The ADNI run (Rorqual, November 2026)

The choices made for the full ADNI cohort, and why. Participant identifiers stay out of this public
file: the lists that name runs are in `/scratch/pierrard/adni_prep/` on Rorqual (also kept with the
batches' `meta/` in the archive store).

- **Inputs.** The lab's ADNI BIDS folder (`INPUT_BIDS`, `config.env`). `inputs/participants.tsv`
  keeps the rows whose DWI run exists (`_run-0N_`, or run 1 for a file without a run entity) and
  whose session has a T1: 3775 DWI runs, 3639 sessions, 1491 subjects (3507 sessions with 1 run, 128
  with 2, 4 with 3). The rows dropped, and why, are in `adni_prep/dropped.tsv`. The pipeline's unit
  is the DWI run: each run is a sample, paired with a T1 by run number (`match_t1_run`).
- **Batches.** `COHORT_NAME=adni`, `BATCH_SIZE=10` sessions (a subject is never split: 7 to 22
  sessions, 11.4 on average), 319 batches, run with `./run.sh --batch`. Pass 1 (`1_volumes`, about
  5 h per batch) then pass 2 (`2_metrics`). Finished archives in
  `/project/rrg-descotea/vitalab/pierrard/adni/finished_archives/adni/`.
- **Batches at once.** Scratch allows 1000K inodes; one unpacked batch costs about 1.8K inodes per
  session in pass 1 and 2.6K in pass 2. 10 at once while scratch held 540-590K, 30 once it was freed
  (262K used). Change it on a submitted array with `scontrol update JobId=<array> ArrayTaskThrottle=N`.
  The other limit is Slurm's 1000 queued jobs per user, which counts every batch job, every task job
  and every waiting task of the array: `queueSize` is 20 per batch (`configs/alliance.config`) so
  that 30 batches at once and 300 waiting stay under it (with 50, the limit was close at 12
  batches, and a refused submission is a failed, then skipped, task).
- **Requests sized from the first day.** Memory about 1.4x the largest peak and time 2.5 to 4x the
  longest run of about 10,000 tasks (`configs/alliance.config`, values in the comments), so most
  tasks fit under 3 h and fill scheduling gaps; both grow on a retry. CPUs unchanged: several
  modules write the thread count into their script (task hash) and ANTs results depend on it. A
  batch job asks 24 h (it took 5 to 9 h); one that runs over is stopped and packed 30 min before, and
  resumes when submitted again.
- **Hung containers.** Some tasks hang at container start on Rorqual: Apptainer's processes wait on
  each other, the task's command never starts, 0 CPU. 24 of the first day's 12,558 tasks, but 13 of
  the 150 started in its busiest hour; on any node, the node running other tasks normally; mostly
  the `nibabel_numpy` and MultiQC images. Not reproduced by 1,120 test starts of that image (one
  job and 16 one-core jobs, with and without `--pid`, image on scratch or node-local). A hung task
  is retried only at its time limit and holds its batch until then, so:
  - every batch job runs a watchdog (`watch_hung_tasks`, `scripts/lib.sh`): a task job of its batch
    past 10 min with only Apptainer and the job's wrappers in it, at two checks 5 min apart, is
    cancelled, logged and listed in `batches/bNNNN/logs/hung_tasks.tsv`. Nextflow retries it 30 min
    later (`exitReadTimeout`; a job gone without an exit code is in the retry list);
  - tasks of seconds to minutes get 1 h per attempt instead of the 4 h default.
- **A failed run does not stop its batch** (errorStrategy `ignore` after the retries,
  `allow_missing_volumes: true`): the first two batches lost to one run each (b0010, b0014) are why.
  Failures are in each batch's `out/metrics/failed_tasks.tsv`, merged into `merged/failed_tasks.tsv`;
  fix them and rerun the batch with `FORCE=1 BATCHES=...`.
- **T1 bias correction with a mask.** The pipeline ran N4 on the denoised T1 without a mask. The
  denoising sets the background (about 75 % of the volume) to exactly 0 on every run, and without a
  mask N4's overall level drifts (its `--rescale-intensities` only acts within a mask): over 179 runs
  the corrected T1 came out 0.002 to 12619 times its input, the level changed with the thread count,
  and on two runs (one site, GE Signa HDxt) the image overflowed or collapsed and brain extraction
  crashed. The fix, adopted for the whole cohort: N4 inside the denoised T1's nonzero voxels (`-x`),
  ANTs' documented use. It was checked before adoption on 24 runs (3 scanners) replayed with the
  pipeline's own task scripts, unchanged and masked:
  - N4 scale with the mask 0.50 to 1.15 times the input (unmasked: 6e-9 to 8e34);
  - brain masks: Dice with SynthSeg 0.9677 masked vs 0.9675 unmasked (median over 22 runs), with recon-all 0.856
    both; brain volume across a subject's sessions as consistent or more (3 of 4 subjects);
  - FAST tissue masks in DWI space against SynthSeg and recon-all classes (from the raw T1, so
    independent of N4; 17 runs): median Dice differences within 0.02 in both directions, every worst run
    better masked (e.g. GM 0.435 to 0.485, CSF 0.416 to 0.548);
  - but a run's FAST masks do change (Dice 0.90 to 0.95 between the two calls): FAST is sensitive to
    its input, the change redraws that noise without shifting a tissue one way.
  recon-all and SynthSeg read the raw T1, so their volumes and thickness never depended on N4; the
  atlas WM bundles go through the b0. The batches that ran pass 1 before the fix recompute their T1
  branch (N4, brain extraction, crop, T1 to DWI registration, FAST) when pass 2 resumes them
  (`ALLOW_COMMIT_CHANGE=1`), so the whole cohort's diffusion metrics use the masked N4. The replay
  and its tables: `/scratch/pierrard/sft_n4cmp/` (`comparison.tsv`, `refcheck.tsv`,
  `tissuecheck.tsv`).
- **Runs to leave out downstream.** One run acquired with a spine coil (all its diffusion values
  wrong, e.g. GM AFD ten times the others) and every run flagged `misaligned` by the atlas
  registration QC: listed in `adni_prep/runs_to_drop.tsv`.

## Tests

```bash
python3 tests/test_python.py   # pass rules, batch list
bash tests/test_batch.sh       # pack/unpack identical, every crash point, locks and lock races
bash tests/test_flow.sh        # two passes over a pack with a fake nextflow; the refusals
bash tests/test_handoff.sh     # batches moved between two machines and back: owner check, refusals
```

On a cluster, the real check is one subject in batch mode, run as jobs:
1. pass 1, which packs the batch;
2. pass 2, which unpacks it, resumes the session and shows 0 tasks computed again;
3. pass 2 packed again.
