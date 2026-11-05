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
  batch that hasn't done PASS (`FORCE=1` to rerun them), at most `MAX_UNPACKED` at once. Set it from
  the free inodes divided by the inodes of one unpacked batch. Each task does:
  1. lock the batch;
  2. the first time, copy its subjects' sessions from `INPUT_BIDS` (or extract
     `inputs/batch_tars/bNNNN.tar`) and hard-link the atlases; later, unpack its archive;
  3. run the pass;
  4. pack, even after a failure;
  5. unlock.
- **What is packed.** `.nextflow/`, `work/`, `.atlas_cache/`, `data_bids/` and `out/` go into
  `archives/bNNNN.tar`; `meta/` and `logs/` stay. Results are published as hard links into `work/`,
  which tar stores once, so `out/` costs the archive almost nothing, and after an unpack its files
  are hard links again. The inputs are packed too: a batch's input data costs inodes only while it
  runs. A packed batch is about 25 files whatever its size.
- **Extracted results.** Each pack also writes `batches/bNNNN/extracted_results.tar.gz`: the files of
  `out/` matching `EXTRACT_PATTERNS` (`config.env`; by default the `metrics/` tables and the global
  MultiQC report; add per-session patterns such as `**/*_desc-thickness.csv`). It is a copy, replaced
  at every pack, so a later pass updates it; the full results stay in the archive
  (`tar -xf archives/bNNNN.tar out/sub-.../file` in a job reads one).
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
- **Fixed paths.** A batch folder never moves, and is resumed only on the cluster where it was
  created: Nextflow's cache and links hold absolute paths.

**Not yet automated:**
- **The scratch purge.** Archives of batches waiting for a later pass must not sit unused past the
  purge window. Move them to project or nearline storage in time.
- **Inputs on a cluster without ADNI (Fir).** Copy them into `INPUT_BIDS`, or as per-batch archives
  in `inputs/batch_tars/`, one file per batch.

## Tests

```bash
python3 tests/test_python.py   # pass rules, batch list
bash tests/test_batch.sh       # pack/unpack identical, every crash point, locks and lock races
bash tests/test_flow.sh        # two passes over a pack with a fake nextflow; the refusals
```

On a cluster, the real check is one subject in batch mode, run as jobs:
1. pass 1, which packs the batch;
2. pass 2, which unpacks it, resumes the session and shows 0 tasks computed again;
3. pass 2 packed again.
