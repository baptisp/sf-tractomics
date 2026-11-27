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
inputs/reconall_rerun.tsv optional: T1s whose recon-all runs again with extra options (not in git)
inputs/input_fixes.tsv    optional: input images repaired before a pass (not in git)
scripts/                  setup_steps.sh, lib.sh (one pass in one folder), batch.sh (lock, pack,
                          unpack), passes.py, make_batches.py, merge_batches.py, volume_qc.py, reuse_report.py,
                          fix_inputs.py,
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
- **Walltime.** 60 minutes before a job's walltime, Nextflow is asked to stop. It cancels its task
  jobs and keeps its cache, and the batch is still packed. Every task job carries the batch in its
  Slurm comment, so packing also cancels, and waits for, any task job left behind.
- **A stopped batch comes back by itself.** The job that stops at its walltime submits the next job
  of its batch (same account and name) with `--dependency=afterany` on itself, so that
  job starts only once the batch is packed and unlocked. That job gets at least `RESUBMIT_TIME`
  (3 days): stopping cancels the task jobs still running, and a recon-all cannot resume, so with
  24 h each time a batch whose last recon-all started late lost it at every stop (ADNI b0152,
  2026-11-15: 10.5 h of recon-all cancelled at the walltime). At most `MAX_RESUBMITS` (5) times per batch
  and pass (`meta/resubmits_PASS`), so a batch that can never finish stops coming back. A job lost
  with its node gets no warning: batch jobs are submitted with `--requeue` (the clusters default to
  no requeue), and the requeued job takes over its own lock and resumes the batch. Before this
  (ADNI, 2026-11-13), 8 stopped batches waited 5 to 10 h for someone to resubmit them.
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
- each input file's absolute path and size (not its date). For a folder, the size is the one the
  filesystem reports for the folder itself, not its content.

Everything that varies by cluster is kept the same:
- **Folder sizes, by a patched Nextflow.** Rorqual's Lustre reports 25600 bytes for any folder,
  Fir's 4096. The first task takes `data_bids/` as input, so with the stock Nextflow every hash
  differed on Fir and a batch from Rorqual was computed again from scratch (b0084, November 2026:
  none of its tasks reused). `setup` therefore patches the Nextflow jar on every Alliance cluster
  (`scripts/patch_nextflow.sh`): it compiles `nextflow_patch/HashBuilder.java`, Nextflow 26.04.4's
  own file with one change, into the jar, so a folder's size is hashed as 25600 everywhere.
  - On Rorqual, where every folder reports 25600, the patched jar gives exactly the stock jar's
    hashes: the caches computed before the patch stay valid.
  - The stock jar is kept next to it (`.orig`). The patch refuses any jar but the stock 26.04.4
    one; another `NXF_VER` needs the change ported first.
  - `run_pass` refuses to run on a cluster whose jar is not patched.
  - Checked: the unchanged source compiles to the shipped bytecode; a test folder at the same path
    hashes the same on Rorqual (stock or patched) and on Fir (patched); b0084, moved from Rorqual,
    resumed on Fir with 485 tasks reused, only the MultiQC reports run again (they run again at
    every resume, on Rorqual too).
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
- `merged/volume_qc.tsv` (`./run.sh merge`, `scripts/volume_qc.py`): recon-all against SynthSeg
  per run: cortex volume per hemisphere and intracranial volume, as ratios. A ratio more than 6
  robust SD from the cohort's median is flagged (`cortex_mismatch_lh`/`_rh`, `icv_mismatch`). Both
  segment the same T1, so a flag points to a failed recon-all (or SynthSeg) run that the
  pipeline's own flags, which compare a run with itself or its subject, do not see. Review a
  flagged run; drop the failed source's rows if a rerun does not fix it.

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
  modules write the thread count into their script (task hash) and ANTs results depend on it.
  recon-all asks 12 h, not the 2.5x rule: on Rorqual a job over 12 h goes to the long-job partition,
  where its tasks waited 36 h once fairshare fell (median 3.8 h over 1131 runs, longest 14.5 h,
  retried at 24 h). A batch job asks 24 h (it took 5 to 9 h); one that runs over is stopped and packed 60 min before, and
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
- **A node that cannot start a script.** On Fir (2026-11-12, 01:00 to 09:00 MST) a few nodes'
  CVMFS gave `Input/output error`: the task's job could not run `mktemp`, exit 126, and 8 batches
  had tasks left after one attempt. Exit 126 is in the retry list; a retry goes back to Slurm,
  usually to another node.
- **A node whose disk fills up or fails.** On Rorqual (2026-11-13 21:30 to 2026-11-14 02:35) the
  node-local disk of two nodes filled up (`No space left on device`, 13 tasks of 13 batches); on Fir
  (2026-11-14) scratch gave `Input/output error` to a few tasks. Both reach the task as exit 1, so
  exit 1 gets one retry (any task), with the memory of the next attempt.
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
- **Runs to leave out downstream** (`adni_prep/runs_to_drop.tsv`), 6 runs:
  - b0174 ses-20180420 DWI run 1: the DWI slab is over the neck (all its diffusion values wrong,
    e.g. GM AFD ten times the others); run 2 of that session is kept;
  - b0079 ses-20170321 run 1 and b0259 ses-20210514 run 1: the T1 covers half the head;
  - b0297 ses-20210623 run 1 and b0317 ses-20180724 run 1: flagged `misaligned` by the atlas
    registration QC, with no fix found (pass 2 outcome, below); to be written into the file after
    the final merge, as the file says.
  - b0115 ses-20140613 DWI run 1: tensor values implausible already in the raw data (pass 2
    outcome, below); to be written into the file after the final merge.
  Every other run of these batches is kept.

### recon-all reruns

A recon-all run can fail without an error, so its volumes are checked against SynthSeg's
(`merged/volume_qc.tsv`, above). On the first 64 batches (706 runs) that check and the failed
tasks found 7 runs, of 4 kinds, all on 3T scanners:

- **Talairach check failed** (`talairach_afd`, p below threshold), so recon-all stopped: 2 runs,
  no recon-all volume or thickness. The transforms were far from the atlas (large rotations), so
  skipping the check (`-notal-check`) would have kept a wrong eTIV.
- **Wrong Talairach transform that the check let through**: 2 runs, eTIV 2.3 and 3.3 L (twice
  SynthSeg's ICV, and in one run three times the brain volume). The cortex is right, the ICV and
  every ICV fraction are wrong.
- **One white surface lost**: 2 runs. The ribbon has about 30,000 white-matter voxels on that
  hemisphere against about 290,000 on the other, so its white matter is counted as cortex (cortex
  1.3 and 1.5 times SynthSeg's).
- **Cortical ribbon of one hemisphere not filled**: 1 run. Its surfaces and their statistics are
  normal, but `ribbon.mgz`, and so `aparc+aseg.mgz`, which the volume tables count, holds a tenth
  of that hemisphere's cortex.

What `-samseg-reg` does. Early on, recon-all lines the brain up with a standard template brain,
using a simple stretch and rotation, and saves the result (`transforms/talairach.xfm`). Several
later steps rely on that alignment: it tells them roughly where the brain and the white matter
are, which helps with removing the skull and correcting brightness, and the head-size estimate
(eTIV) is computed straight from it. When the alignment is far off, the later steps go wrong too:
skull removal fails, or one hemisphere's white matter is lost. `-samseg-reg` replaces only that
alignment step. Instead of the usual tool it uses the alignment of SAMSEG, another FreeSurfer
method (`run_samseg --reg-only`). Everything after that step runs as normal, in about the same
time. The segmentation of the deep brain structures (aseg) is not affected, because it does its
own alignment.

The usual tool is `talairach_avi` (written by Avi Snyder, Washington University). It aligns the
head to the MNI305 template, an average of 305 brains, by matching the overall image brightness of
the head to the template, after a quick correction for uneven brightness. `-use-mritotal` selects
an older alternative from the MINC tools; on our failing scans it gave the same wrong result.
SAMSEG matches the head to a template that knows which tissue (grey matter, white matter, fluid)
is likely at each location, which makes it more robust on the unusual scans where `talairach_avi`
failed.

Tested on ADNI pass 1 (2026-11-14), full recon-all outside the pipeline, volumes compared with the
run's SynthSeg ones against the other runs of its batch:
- recon-all failed (an absurd transform, then skull stripping and white matter): fixed by
  `-samseg-reg`. `-use-mritotal`, `-3T` and `-no-wsgcaatlas` did not fix it.
- one hemisphere's cortex wrong (1.30 times SynthSeg's in one run, 0.06 in another): fixed by
  `-samseg-reg`, and by `-3T`. On another run `-3T` made it worse (the Talairach check then
  failed), so the reruns use `-samseg-reg`.
- two T1s cover only part of the head (a field of view of 132 mm across, or the head off to one
  side): SynthSeg's ICV is under 900 cm3 and its volumes are wrong too. No option fixes that; they
  are in `adni_prep/runs_to_drop.tsv`.
- a very atrophied brain: neither `-notal-check` nor `-samseg-reg` brings putamen, caudate and
  cerebellum into their usual ratio to SynthSeg. Its recon-all values are kept and flagged as
  outliers (see the rule below).
- eTIV alone wrong (1.7 to 1.9 times SynthSeg's ICV, or 0.83), the volumes in range: no rerun; use
  SynthSeg's ICV for those runs.
- a strong bias field (the white matter much darker at the top of the head): mri_normalize finds
  the white matter at 90 instead of 110 and the volumes are wrong, or the Talairach check fails.
  `n4` brings the white matter back to 110 in every normalization on both runs: one run's volumes
  are then in range; the other passes the Talairach check and finishes, its cerebellum cortex still
  under the batch's range (0.72 times SynthSeg's).
- four runs from one scanner model where recon-all's atlas registration fails: the white matter
  peak falls to about 90 after the atlas-based normalization (`mri_ca_normalize`), and putamen,
  thalamus and cortex are far from SynthSeg's. It is not a bias field (the white matter profile by
  depth is the same as in good runs). Nothing tried fixes it (2026-11-18): `n4`, `crop n4`,
  `-samseg-reg`, alone or together, leave 5 to 10 of 10 volumes out of the batch's range, and
  `crop` moves eTIV on a good control run. `recon-all-clinical.sh` (SynthSeg-based surfaces)
  completes, but on good runs its cortex is about 8% under recon-all's, and on these four it reads
  higher than on any good run, so it is not comparable either. Their recon-all values (with
  `-samseg-reg`) are kept and flagged as outliers.
A rerun's eTIV comes from a different alignment than the rest of the cohort, so use SynthSeg's ICV
for it too. Look at the T1 before choosing an option, and compare a rerun's volumes with SynthSeg's
before keeping it. A recon-all killed for memory (exit 1) needs no option: exit 1 is retried once.

The rule (2026-11-18): every run whose recon-all finishes keeps its recon-all values, even when
they are off; such runs are listed as outliers, and the study decides what to do with them. Only a
run whose recon-all exits with an error that no option fixes has empty recon-all values.

How:
- `inputs/reconall_rerun.tsv`, not in git: columns `subject`, `session`, `options`, `reason`, with
  that header. Each launch copies it to `meta/reconall_rerun_<pass>.tsv` and passes it as the
  pipeline's `reconall_rerun`.
- A listed T1 runs in `RECONALL_THICKNESS_RERUN`, a copy of the recon-all process that takes the
  options as an input. Every other T1 keeps its `RECONALL_THICKNESS` task and its cache.
  - Adding the options to the nf-neuro module instead would have run recon-all again on every T1:
    Nextflow hashes a task's script source, so any edit to it misses the cache, even for a T1 whose
    options are empty. This was tested.
- The word `n4` (no dash) in `options` is a step run on the T1 before recon-all, in
  `RECONALL_T1PREP`: SynthSeg for the brain mask, then N4 bias field correction inside it.
  recon-all's `rawavg.mgz` and `orig.mgz` are then the corrected T1, on the same grid. A listed T1
  without it runs recon-all on the input T1, as before, and keeps its cached task. Cropping the
  field of view was tested too and fixed nothing, so it was not kept.
- The rerun's FreeSurfer folder replaces the published one, and every task that reads it (thickness,
  subfields, the volume tables) runs again for that run only. The options are in `versions.yml`.
- The reruns go with the next pass of their batches, which needs `ALLOW_COMMIT_CHANGE=1` (the
  pipeline commit changes).
- Afterwards `./run.sh merge` checks them again. A run still flagged keeps its recon-all values
  and goes in the outlier list.

### Pass 1 outcome (2026-11-22)

All 321 batches finished pass 1 (188 on Rorqual, 133 on Fir; Fir's results copied to Rorqual and
checked by md5). Merged on Rorqual into `merge_pass1_20261122/merged/`: 3749 runs in
`volume_qc.tsv`, 11 flagged, 4 failed tasks. The list of runs by participant is in
`inputs/reconall_rerun.tsv` (19 runs, not in git); below, runs are named by batch, session and DWI run, without the participant.

Every run outside that list ran the default recon-all, and every listed run ran exactly its listed
options: checked on 2026-11-22 from each run's `recon-all.log` in the archives
(`/scratch/pierrard/volcheck/qc_options.py`). A batch's rerun recomputes only the listed run (its
recon-all and the tasks that read it); the other runs of the batch come from the cache.

**Failed tasks** (`merged/failed_tasks.tsv`):
- b0079 ses-20170321 run 1, b0259 ses-20210514 run 1: recon-all stopped at the Talairach step. Both T1s cover only part of the head
  (SynthSeg ICV under 900 cm3); `-samseg-reg` finishes on b0079 but every volume is wrong (right
  hippocampus 65 times SynthSeg's). In `adni_prep/runs_to_drop.tsv`; no recon-all values.
- b0064 ses-20251020 run 1: recon-all stopped at the Talairach check. `-samseg-reg` finishes with
  volumes in the batch's range except right hippocampus (1.21 times SynthSeg) and cerebellum cortex
  (0.78). Added to the rerun list on 2026-11-22, under the rule above: it is recomputed at the start
  of pass 2. Pass 2 outcome: recon-all finished (GM 506 mL, SynthSeg 690 mL), in line with the
  participant's 4 other sessions (504 to 571 mL); not flagged by the longitudinal sweep.
- b0218 ses-20160902 run 1: FSL eddy failed (the DWI has no b0 volume, see pass 2); that run has T1
  volumes and no diffusion metrics.

**recon-all reruns, what was tried and what came of it**:

| Batches | Failure | Tried | Kept | Result |
| --- | --- | --- | --- | --- |
| b0262 ses-20180213 | Talairach transform absurd, recon-all failed | `-samseg-reg`, `-use-mritotal`, `-3T`, `-no-wsgcaatlas` | `-samseg-reg` | fixed |
| b0035 ses-20210707, b0044 ses-20220728, b0061 ses-20240119 | one white surface lost, or one ribbon not filled | `-samseg-reg`, `-3T` | `-samseg-reg` | fixed |
| b0204 ses-20130927 | one hemisphere's cortex 1.45 times SynthSeg's | `-samseg-reg` | `-samseg-reg` | fixed |
| b0180 ses-20131128 | cortex 1.56 / 0.83 times SynthSeg's | `-samseg-reg`, `n4 -samseg-reg` | `n4 -samseg-reg` | fixed |
| b0152 ses-20170327 | recon-all failed (`mris_sphere`, after a 13 h topology fix) | `-3T` | `-3T` | finishes; right hippocampus 1.25 times SynthSeg's, eTIV 1.74 times its ICV |
| b0250 ses-20150921 (its T1 serves DWI runs 1 and 2) | Talairach check failed (strong bias field) | `-samseg-reg`, `-no-emreg`, `-bigventricles`, SynthMorph registration, `n4` | `n4` | finishes; cerebellum cortex 0.72 times SynthSeg's |
| b0192 ses-20190408 | `mris_fix_topology` hangs on one defect of about 38,000 vertices (killed at every limit, up to 35 h) | `n4` | `n4` | finishes in 1.8 h, in line with the participant's other sessions; right putamen 0.42 times SynthSeg's |
| b0231 ses-20200903 | same hang (a defect of 37,541 vertices) | `n4`, `-no-fix-with-ga` | `-no-fix-with-ga` | finishes in about 12 h, but the left surface stays damaged (below) |
| b0246 ses-20221114 | cortex 0.60 times SynthSeg's, slight motion | `-samseg-reg`, `n4 -samseg-reg` | `n4 -samseg-reg` | cortex in line with the participant's 6 other sessions; eTIV 8% above them |
| b0284 ses-20230623 | left cortex 0.06 times SynthSeg's | `-samseg-reg`, `n4 -samseg-reg` | `n4 -samseg-reg` | cortex in line, left about 5% under the participant's trend; eTIV 5% above; left hippocampus high in both tools (SynthSeg too) |
| b0130 ses-20200709, b0321 ses-20220525, b0251 ses-20171002 (strong motion), b0247 ses-20210505 (moderate) | cortex 0.44 to 0.62 times SynthSeg's | `-samseg-reg`, `-use-mritotal`, `-3T`, `n4`, `n4 -samseg-reg` | `-samseg-reg` | not fixed: still flagged |
| b0145 ses-20171107, b0180 ses-20190611 | cortex about 0.6 times SynthSeg's | `-samseg-reg` | `-samseg-reg` | not fixed: still flagged; no other session of the participant to compare with |

A run with an option was judged against the same participant's other sessions (recon-all and
SynthSeg per session), not against the batch's range: a participant's volumes change little
between sessions, other participants' a lot.

**Why they failed** (conclusions):
- Motion. The four motion runs show ringing and blurring on the T1. recon-all's Talairach
  registration then goes wrong, the surfaces miss whole regions and eTIV jumps. No recon-all
  option corrects motion: `#@# MotionCor` only averages several T1 acquisitions of a session, and
  FSL eddy corrects the DWI, never the T1. The ADNI repeat T1 (run 2), which could replace a moved
  one, is not in the lab's BIDS folder for these runs.
- A giant topology defect (b0192, b0231). The topology fixer's genetic algorithm does not end on a
  defect of about 38,000 vertices. `n4` changes the image enough that the defect is no longer
  there (b0192); on b0231 it is still there, and `-no-fix-with-ga` patches it with the faster
  method. The surface statistics are then normal (`lhCortexVol` 246 mL, the participant's other
  session 241 mL), but the left hemisphere's `aparc+aseg.mgz` labels, which the volume tables
  count, hold 2.4 to 4 times the other session's cortex per region (423 mL in total).
- The Talairach registration (`talairach_avi`) fails on unusual images: large rotations, a strong
  bias field, a truncated field of view. `-samseg-reg` replaces it, except on a truncated head.

**Limitations: runs to read as possible outliers.** By the rule above, each keeps its recon-all
values:
- cortex wrong (flagged `cortex_mismatch` in `volume_qc.tsv`): b0130 ses-20200709, b0321
  ses-20220525, b0251 ses-20171002, b0247 ses-20210505 (motion), b0145 ses-20171107, b0180
  ses-20190611, b0231 ses-20200903 (left hemisphere's regions; left hippocampus 0.53 times
  the other session's);
- eTIV wrong (flagged `icv_mismatch`; use SynthSeg's ICV): b0008 ses-20110831 and ses-20120918
  (1.89 and 1.73 times SynthSeg's ICV), b0152 ses-20170327 (1.74), b0301 ses-20201030 (0.50); and
  every rerun's eTIV, which comes from another registration than the rest of the cohort (b0246
  ses-20221114 +8% and b0284 ses-20230623 +5% over the participant's other sessions);
- one structure out of range: b0192 ses-20190408 (right putamen), b0250 ses-20150921 runs 1 and 2
  (cerebellum cortex), b0152 ses-20170327 (right hippocampus), b0284 ses-20230623 (left
  hippocampus, in SynthSeg too).

**Image and motion QC.** `/scratch/pierrard/volcheck/qc/qc_screen.tsv` has one row per run:
topology defects and the largest one, the Talairach check, the T1's EFC and background SNR
(MRIQC's definitions), and FSL eddy's DWI movement. 187 runs are past the cohort's 99th
percentile on one figure, 9 on two or more figures of the T1. These figures do not single out the
motion runs above (three of the four are under every threshold), so the volume check against a
participant's other sessions stays the criterion; the table is for reading a run already in doubt.

**Pass 2.** The batches carry three pipeline commits from pass 1 (220 batches on `942bddb3`, 92 on
`9009cb6a`, 9 on the current one). Pass 2 is submitted once with `ALLOW_COMMIT_CHANGE=1`
(`ALLOW_COMMIT_CHANGE=1 ./run.sh submit 2_metrics`), which moves every batch to the current commit
and recomputes the T1 branch of the batches that ran before the masked N4 (above). `config.env` no
longer sets it.

### Pass 2 outcome (2026-11-26)

All 321 batches finished pass 2 (183 on Fir, 138 on Rorqual). The batches rerun below are on
pipeline commit `65de5e2` or `6b57592`, the others on `46dcb00` or a later commit that changes only
`cohort/` and docs. The two pipeline commits since `46dcb00` change only the runs listed in their
per-run lists (below), plus one QC step that only writes a table, so every other run's values are
the same whichever commit its batch is on. That QC table (`space-T1w_desc-brainmask_qc.csv`) exists
only in the rerun batches; the mask-volume scan below covered all of them.

Runs are named by batch, session and DWI run (`run 1` for a file without a run entity); a T1 fix
applies to every DWI run of its session. The participant of each is in the lists named, which are
not in git.

**Summary of the decisions**

| Issue | Runs | Decision |
| --- | --- | --- |
| T1 brain mask wrong (ANTs BET), or T1 misplaced in DWI space | 29 | fixed: SynthStrip for those T1s |
| T1 covers half the head | 2 | dropped (and on the SynthStrip list, which does not fix them) |
| DWI slab over the neck | 1 | dropped |
| atlas registration `misaligned`, no cause found | 2 | dropped (after the final merge) |
| DWI tensor values implausible in the raw data (b0115 run 1) | 1 | dropped (after the final merge) |
| atlas registration `brain_mismatch` (DWI mask too large) | 4 | kept, values unaffected |
| free-water fit stops on NaN | 1 | fixed: NaN set to 0 for that run |
| DWI without b0 | 1 | kept without diffusion values; not fixable from our data |
| recon-all rerun decided in pass 1 (b0064) | 1 | recomputed; values in line |
| batch whose atlas files were deleted (b0108) | 12 (1 batch) | repaired, pass 2 rerun |
| batch that would run out of time (b0231) | 1 batch | resubmitted with a longer limit |
| flagged by the longitudinal sweep, not above | 93 | kept; recon-all ones flagged as outliers (lists below) |

**Brain extraction (ANTs BET) failing without an error: 29 runs, fixed with SynthStrip.**
- What was wrong. `BETCROP_ANTSBET` can return a mask of the whole head or image (7 to 17.1 L)
  or of a patch of the face (417 mL) and exit 0. The T1 "brain" then keeps its skull. With a face
  patch, the T1-to-DWI registration places the T1 far from the DWI brain, so the subject regions
  (recon-all labels in DWI space), the surface metrics and the FAST tissue masks are wrong. With a
  whole-head mask, the registration can still land correctly, but the tissue masks and everything
  built on them read non-brain voxels.
- Round 1, found by the share of each run's T1 regions inside the DWI brain mask (`in_mask_fraction`
  of `SUBJECT_ROI_FRACTIONS`; good runs 0.997 or more, with all 84 regions), 12 runs at 0.000 to
  0.555 or with no value:
  - ANTs BET mask of the whole head: b0251 ses-20110908, ses-20111212 and ses-20120322; b0262
    ses-20191204; b0263 ses-20180330; b0281 ses-20180706 and ses-20190625; b0282 ses-20181115 and
    ses-20191114; b0283 ses-20200729 (all run 1);
  - ANTs BET mask of a 417 mL patch of face and neck: b0193 ses-20210303 run 1;
  - ANTs BET mask normal (1262 mL) but the T1-to-DWI registration distorted: b0315 ses-20191104
    run 1. The same registration from the SynthStrip-extracted T1 places it, so it is on the list
    too.
- Round 2, found by the volume of every T1 brain mask in all 321 batches, read from the archives
  (`/scratch/pierrard/volcheck/maskvol_scan.sh`), with the rule of the new QC step (above 2500 mL
  or below 900 mL), 17 runs whose T1 had registered correctly, so that round 1 could not see them:
  - whole image or head: b0012 ses-20120724 (15.9 L); b0031 ses-20120405 (15.9 L); b0036
    ses-20180425 (12.8 L); b0053 ses-20120510, ses-20120814, ses-20130514 and ses-20140610 (15.9 L);
    b0075 ses-20210322 (17.1 L); b0129 ses-20180511 (7.9 L); b0200 ses-20220927 (10.8 L); b0233
    ses-20200226 (10.8 L); b0251 ses-20221004 (14.3 L); b0263 ses-20180205 (17.1 L); b0281
    ses-20200630 and ses-20210618 (12.8 L) (all run 1);
  - too small: b0079 ses-20170321 (349 mL) and b0259 ses-20210514 (668 mL), run 1.
- The fix. `inputs/t1_bet_rerun.tsv` (columns `subject`, `session`, `method`, `reason`; not in git;
  29 rows, sha256 `3fdc370b…`, identical on both clusters) lists the T1s that SynthStrip
  brain-extracts instead (`T1_SYNTHSTRIP`, FreeSurfer's SynthStrip container, sha256
  `03c6ee056707c3cde8ad114f89661c682369241297b0cb52d587eb81a8a9afdf`, the same file on both
  clusters; Rorqual's compute nodes have no internet, so the image is copied there). Every other T1
  keeps `BETCROP_ANTSBET` with the same inputs and its cached task. The list is copied to
  `meta/t1_bet_rerun_<pass>.tsv` and passed as `t1_bet_rerun`, like the recon-all list. A new step,
  `QC_T1BRAINMASK`, writes `metrics/space-T1w_desc-brainmask_qc.csv` for every T1: mask volume,
  flagged `mask_too_large` above 2500 mL and `mask_too_small` below 900 mL.
- Checked after the reruns (pass 2 with `FORCE=1` on the 8 batches of round 1, then the 13 of
  round 2): in each batch only the listed runs' tasks were recomputed (about 13 per run, from brain
  extraction on: crop, T1-to-DWI registration, FAST and what reads them); recon-all was reused.
  Round 1: in-mask fraction 0.999 or more with all 84 regions. SynthStrip masks 1.34 to 1.95 L for
  27 of the 29 runs.
- Every SynthStrip task ran out of memory on its first attempt and finished on the retry (peak 5.7
  to 7.5 GB). The result is the same; only the first request is too small.

**The T1 covers half the head: 2 runs, dropped.** b0079 ses-20170321 run 1 and b0259 ses-20210514
run 1 keep small masks with SynthStrip (812 and 706 mL): b0079's T1 has 110 slices across, 13 cm,
where the participant's other sessions have 176; b0259's covers one side of the head. Their
recon-all fails at the Talairach step (pass 1, above). The lab's BIDS folder has no other T1 for
those sessions; only ADNI's own database could hold a repeat T1 of those visits. Both are in
`adni_prep/runs_to_drop.tsv` since pass 1; every other run of the two batches is kept. On those 2
runs the SynthSeg volumes are present but measured on half a brain (GM 0.49 and 0.53 times the
participant's other sessions) and recon-all's are empty; the atlas diffusion values come from the
DWI and look normal, but are dropped with the run.

**The DWI slab over the neck: 1 run, dropped.** b0174 ses-20180420 DWI run 1 images the temporal
lobes, brainstem, cerebellum and neck (the slab placed about 9 cm too low; run 2 of that session,
27 min later, is correct and kept). Its atlas registration is flagged `misaligned` (correlation
0.13, about 0.8 normally), its atlas values are wrong (WM FA 0.52 times the participant's other
sessions), and its values in recon-all regions and on the surface cover only the part of the brain
inside the slab (46 of 84 regions, 35 of 68). Its T1 values are valid (the session's single T1).
In `adni_prep/runs_to_drop.tsv` since pass 1 (recorded there as a spine-coil acquisition).

**Atlas registration QC** (`space-native_desc-atlasregistration_qc.csv`: `misaligned` when the
correlation of the registered IIT b0 with the run's b0 is under 0.6, `brain_mismatch` when the Dice
of their brain masks is under 0.85). Besides b0174 above, 6 runs of 3,751 are flagged. Each was
registered again 4 ways (the pipeline's call; the b0 masked to the brain; the brain mask given to
ANTs; a start from the image centres) and scored with the same check:
- `brain_mismatch`, 4 runs, kept: b0085 ses-20190312, b0088 ses-20200224, b0315 ses-20220215 and
  b0316 ses-20220525 (run 1). The atlas is aligned (correlation 0.79 to 0.89); the DWI brain mask
  is too large (the face and eyes; for b0085 the neck and most of the image; Dice 0.63 to 0.85).
  The values are not affected: atlas values are averaged inside atlas regions, which lie in the
  brain, and none of the 4 runs stands out from its participant's other sessions or its site.
- `misaligned`, 2 runs, dropped: b0297 ses-20210623 and b0317 ses-20180724 (run 1). The
  registration is anatomically right, but the run's diffusion is abnormal over the whole brain:
  median MD 1.22e-3 and 0.98e-3 (the highest of 47 and 93 runs of the same site and scanner),
  whole-brain FA 0.24 and 0.28 (the lowest of their site; about 0.4 normally), and in that session
  only. Ruled out: b-values (checked raw), the gradient table (MRtrix `dwigradcheck`: the table used
  scores best, as on two control runs), b0 extraction, the registration method, head motion (eddy:
  mean 0.07 and 0.22 mm, under other sessions of the same participants that are not flagged) and
  ventricle size (59 and 21 mL). No fix found; dropped under the rule above (every `misaligned`
  run). To be written into `adni_prep/runs_to_drop.tsv` after the final merge, as that file says.

**Free-water fit failing on NaN: 1 run, fixed.** b0144 ses-20230314 run 1: `RECONST_FREEWATER`
(AMICO, `scil_freewater_maps`) exited 64, twice, with no message. Its preprocessed DWI holds 224
NaN values in 112 voxels, all outside the brain mask, in 2 of 55 volumes; the tensor fit tolerates
them, AMICO does not. Run by hand, the task's command fails on the published data and succeeds with
the NaN set to 0. `inputs/dwi_nan_fix.tsv` (columns `subject`, `session`, `run`, `reason`; not in
git; this one run, sha256 `3bc8f543…`, identical on both clusters) lists the runs whose DWI goes
through `IMAGE_NANTOZERO` (MRtrix, non-finite values set to 0, the count in `*_nan_count.txt` and
in the Nextflow log as `dwi_nan_fix: ...`) before the free-water and NODDI fits. Every other run
passes unchanged and keeps its cache. The rerun (2026-11-26) set 224 values to 0 and recomputed
that run's free-water and corrected-DTI tasks and their statistics only (608 tasks reused, no
failed task); the run now has the free-water fraction and the free-water-corrected FA, MD, AD and
RD in all 42 bundles. It is single-shell, so it has no NODDI (as every single-shell run), and its
free water depends on the fixed diffusivity priors (exploratory, the pipeline's warning).

**No b0 in the DWI: 1 run, kept without diffusion values.** b0218 ses-20160902 run 1: FSL eddy
stops (`The minimal b-value is lesser than 0 or greater than 10.0`): its 32 volumes are all
b = 1000, where the participant's other sessions have 5 or 6 b0s. The lab's BIDS has no other DWI
for it. The run has T1 values and no diffusion values; only ADNI's original download could hold its
b0 series.

**b0064 ses-20251020 run 1, the recon-all rerun decided in pass 1** (`-samseg-reg`): recomputed at
the start of pass 2; recon-all finished, values in line with the participant's other sessions (pass
1 outcome, above).

**b0108 never ran pass 2 on its first submission** (all 12 runs). It stopped at start, trying to
download the IIT atlas: the 2026-11-17 storage-incident repair had deleted damaged files of its
`work/`, its atlas copies among them, and Rorqual's compute nodes have no internet. The atlas files
were put back as hard links, as setup does (the copies still there were identical), and the batch
reran pass 2 normally. A finished pass is read from `meta/passes_done`, not from a log line: the
status line's log name contains `2_metrics` whether or not the pass ran.

**b0231 would have run out of time.** Its recon-all rerun on ses-20200903 (`-no-fix-with-ga`,
above) takes a little over 12 h and runs again in pass 2 (the commit changes). After its first
attempt was killed at 12 h, the retry could not finish before the batch job's own limit. The batch
was sent the early-stop signal its time limit sends (USR1): it packed and resubmitted itself with
`RESUBMIT_TIME` (3 days), and finished. No value differs from a normal run.

**Longitudinal sweep** (`/scratch/pierrard/volcheck/sweep.py`, output `sweep_<machine>.tsv` on each
cluster; 3,752 runs of 1,488 participants). For each run: SynthSeg and recon-all total GM and ICV,
mean cortical thickness, mean FA and MD over the IIT WM bundles, mean MD over the IIT GM regions. A
run is flagged when a value is more than 12 % (volumes, thickness) or 15 % (FA, MD) from the median
of the participant's other runs, or, for a participant with a single run, outside the cohort's
0.5 to 99.5 % range (so about 1 % of single-run participants' values are flagged by construction).
99 runs are flagged:
- 5 are the runs dropped above (b0079, b0259, b0174 run 1, b0297, b0317): the sweep finds them
  on its own.
- 33 are GM MD alone. In participants with several sessions it rises with the years (1.15 to 1.33
  times the median, e.g. b0244, five sessions from 2019 to 2023 at 1.16 to 1.33), as expected with
  ageing and atrophy; the earliest sessions of the same participants read 0.85. Kept, not errors:
  b0001 ses-20170315 and ses-20190501, b0004 ses-20170417 and ses-20190520, b0040 ses-20240909,
  b0054 ses-20180716, b0057 ses-20190717 and ses-20210219, b0100 ses-20121013, b0112 ses-20190321
  and ses-20210709, b0114 ses-20220622, b0115 ses-20241108, b0162 ses-20241204, b0174 ses-20240730
  and ses-20250708, b0176 ses-20241108, b0190 ses-20151019, b0244 ses-20190814, ses-20200923,
  ses-20210714, ses-20220715 and ses-20230719, b0265 ses-20250624, b0270 ses-20111018, b0298
  ses-20250912, b0303 ses-20251117, b0320 ses-20190306; single-run participants at the cohort's
  edge: b0039 ses-20240611, b0080 ses-20191003, b0149 ses-20240501, b0181 ses-20241218, b0188
  ses-20220418 (all run 1).
- 13 are large or small heads, where SynthSeg's ICV and recon-all's eTIV agree within 10 % (single-run
  participants at the cohort's edge): anatomy, kept: b0044 ses-20210713, b0048 ses-20240822, b0059
  ses-20191119, b0065 ses-20240620, b0149 ses-20240717, b0151 ses-20250409, b0171 ses-20241126 and
  ses-20250102, b0195 ses-20240529, b0199 ses-20220317, b0218 ses-20250210, b0233 ses-20250730
  (GM 833 mL, ICV 1.85 L), b0319 ses-20210713 (all run 1).
- 32 are recon-all values only (SynthSeg in line), kept and flagged as recon-all outliers under the
  2026-11-18 rule:
  - already in the pass 1 outlier lists: b0008 ses-20110831 and ses-20120918, b0130 ses-20200709
    (and ses-20190326, flagged only because its participant's median includes the failed session),
    b0145 ses-20171107, b0152 ses-20170327, b0231 ses-20200903 (and ses-20180526, same reason),
    b0247 ses-20210505 (and ses-20190424, same reason), b0251 ses-20171002, b0301 ses-20201030,
    b0321 ses-20220525;
  - new: eTIV off from SynthSeg's ICV or from the participant's other sessions (use SynthSeg's ICV):
    b0013 ses-20191206 and ses-20220120 (1.15 times), b0107 ses-20240930 (1.14), b0121 ses-20190607
    (0.83 times SynthSeg's), b0171 ses-20241223 (0.84), b0193 ses-20180607 (0.83), ses-20200909
    (0.84 times SynthSeg's) and ses-20220728 (1.20), b0260 ses-20170707 (0.81), b0289 ses-20240402
    (0.85 times SynthSeg's);
  - new: recon-all GM 0.85 to 0.87 times the participant's other sessions: b0020 ses-20150720,
    b0026 ses-20230117, b0042 ses-20210113, b0054 ses-20191016, b0186 ses-20250319;
  - new: mean thickness: b0056 ses-20140120 (1.13 times), and single-run participants at the
    cohort's edge, b0065 ses-20170412 (2.09 mm), b0136 ses-20250507 (2.67 mm), b0138 ses-20180606
    (2.63 mm) (all run 1).
- 16 are diffusion values (WM FA or MD, GM MD). Each was placed among the runs of its own site and
  scanner (`/scratch/pierrard/volcheck/site_md.py`, rank of mean WM MD and FA):
  - at the high-FA, low-MD edge of their site, mostly single-run participants at the cohort's edge:
    b0048 ses-20220617 (MD 1st of 40, FA 33rd), b0061 ses-20250515 (2nd and 9th of 9), b0062
    ses-20250513 and ses-20250528 (6th and 7th; 1st and 8th of 9), b0066 ses-20241217 (2nd and
    146th of 161), b0075 ses-20210803 (3rd and 160th of 161), b0111 ses-20211104 (22nd and 215th of
    216), b0202 ses-20221103 (1st and 32nd of 32: FA 0.50), b0211 ses-20250305 (3rd and 17th of 18).
    Kept: inside or at the edge of their site's range;
  - high MD, low FA within their site: b0231 ses-20180703 and b0232 ses-20181116 (MD 18th and 17th
    of 20), inside their site's range; b0044 ses-20190719 (MD 13th of 13, FA 0.34 against 0.39) and
    b0123 ses-20240103 (MD 117th of 117, FA 0.37 against 0.41), the site's maximum but far from the
    two dropped `misaligned` runs (FA 0.24 and 0.28 against 0.38 and 0.40) and not flagged by the
    atlas QC. Kept, to read as possible outliers;
  - b0313 ses-20170609 and ses-20190619: the participant's two sessions use different protocols
    (single-shell, then multi-shell) and are flagged against each other; within their site, FA 72nd
    and 2nd of 93. Kept; the later session at its site's low end;
  - b0115 ses-20140613 DWI run 1, dropped: WM FA 0.56 and MD 0.59e-3 over the IIT bundles (1.34
    and 0.71 times the participant's other sessions; highest FA and lowest MD of 42 runs of its site
    and scanner), while run 2 of the same session (another series of the same visit) reads 0.39
    and 0.84e-3. In the preprocessed DWI, 1 % of the brain voxels have FA 0.97 or more (run 2:
    0.71). The fault is in the acquisition as stored, not in the pipeline: a tensor fitted on the
    raw DWI (MRtrix `dwi2tensor`, before any preprocessing) gives 5.4 % of brain voxels above FA
    0.8, against 0.5 to 1.6 % for the participant's other 8 raw runs. Ruled out: the b-values (the
    labelled b = 0 volumes are the bright ones, the b = 1000 attenuation matches the participant's
    other sessions), the gradient table (`dwigradcheck`: the table used scores best) and the atlas
    registration (correlation 0.77, Dice 0.95, as run 2). It is the participant's first session on
    a new scanner (GE Discovery MR750w, series `Axial DTI(HEAD 24)`, 41 directions); the b-vectors
    stored for it may not be the ones acquired, which only the original DICOM could tell. Its T1
    values are valid (the session's T1 is shared with run 2). Dropped under the same rule as the
    `misaligned` runs; run 2 is kept. To be written into `adni_prep/runs_to_drop.tsv` after the
    final merge.
None of the sweep's other flags is a pipeline failure that a fix could remove; the recon-all ones are recon-all's own variability, for which the rule is to keep and flag.
The flagged runs and their reasons go into the merged QC table at the final merge.

**Limitations.**
- The checks are those listed: in-mask fraction, T1 mask size, atlas registration QC, failed
  tasks, recon-all against SynthSeg, the longitudinal sweep. A failure none of them measures can
  remain, and single-run participants are checked against the cohort range only.
- The sweep's GM MD and cohort-edge flags were read by pattern, not inspected run by run.
- Runs left out downstream (`adni_prep/runs_to_drop.tsv`): 6, the 3 already in the file (b0079
  ses-20170321 run 1, b0259 ses-20210514 run 1, b0174 ses-20180420 run 1) and the 3 to add after the
  final merge (b0297 ses-20210623 run 1, b0317 ses-20180724 run 1, b0115 ses-20140613 run 1). recon-all outliers are
  kept and flagged.
- The 29 SynthStrip runs and b0144 ses-20230314 run 1 differ from the rest of the cohort in one step
  (brain extraction; NaN clean-up). The NaN were outside the brain mask, so b0144's values inside it
  are unchanged; SynthStrip and ANTs BET masks differ at the brain's edge.
- The 4 `brain_mismatch` runs keep a DWI brain mask that includes non-brain tissue; their reported
  values are in line with their participants' other sessions, but values restricted to the DWI mask
  (tractography, whole-mask QC) include those voxels.

### Input fixes

Some input images have a defect a tool refuses, which the source data cannot be changed for (the
lab's BIDS folder is read only). `inputs/input_fixes.tsv`, not in git, lists them: columns `file`
(a path under `data_bids/`, `sub-X/ses-Y/anat/...nii.gz`), `fix`, `reason`, with that header.

- Before each pass, `run_pass` gives the list to `scripts/fix_inputs.py`, which repairs each listed
  file present in the launch folder's `data_bids/`, once. It is recorded in
  `meta/input_fixes_applied.tsv` (checksums before and after): a rewritten file has a new date, so
  repairing it again would recompute its tasks every time.
- The file must still be the input that was prepared (its line in `meta/inputs.sha256`); that line
  is then replaced by the repaired file's, so the checksum check still covers every other file.
- Only the tasks that read the repaired file run again; every other file keeps its cache. Changing
  the pipeline's step instead would change its script, and so recompute it for every run of any
  batch that resumes.
- Fixes:
  - `sform_from_qform`: the sform is replaced by the transform the qform gives; only the header
    changes. For a T1 whose two transforms disagree on the voxel size: ITK reads one, MRtrix the
    other, and N4 then aborts on an image and its mask that "do not occupy the same physical space"
    (ADNI b0096 ses-20200218 T1: sform voxel 1.0000992 mm, qform 1 mm).

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
