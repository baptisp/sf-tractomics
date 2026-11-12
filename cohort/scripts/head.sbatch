#!/bin/bash
# One pass of the root folder (no batches) on an Alliance cluster: the Nextflow head job, which
# submits every task as its own CPU job. Submitted by ./run.sh submit PASS; never run it by hand.
# --signal: 60 min before the walltime Nextflow is asked to stop cleanly (cache kept); submitting
# the pass again resumes it.
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --signal=B:USR1@3600
set -euo pipefail

cd "${SLURM_SUBMIT_DIR:?}"
source scripts/env.sh
source scripts/lib.sh
: "${SFT_PASS:?}"
export SFT_TAG="sft-$COHORT_NAME"

trap 'stop_nextflow "$SFT_ROOT"' USR1
wait_task_jobs "$SFT_TAG"   # task jobs left by a head job cancelled or lost with its node
run_pass_guarded "$SFT_ROOT" "$SFT_PASS" && rc=0 || rc=$?
exit "$rc"
