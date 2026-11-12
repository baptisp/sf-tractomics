#!/bin/bash
# One batch, one pass: lock, unpack (or prepare, the first time), run the pass, pack, unlock.
# Submitted by ./run.sh submit PASS as an array, one task per batch (SFT_LIST: the batch names, one
# per line), at most MAX_UNPACKED at once; never run it by hand.
# --signal: 60 min before the walltime, Nextflow is asked to stop (it cancels its task jobs and
# keeps its cache), so the batch is still packed; the next submission resumes it. 30 min was too
# short: packing a 30 to 66 GB batch on a slow Lustre outlasted it (Rorqual, 2026-11-12: b0060,
# b0096 and b0097 killed while packing, folders intact, archives left as .part).
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --signal=B:USR1@3600
set -euo pipefail

cd "${SLURM_SUBMIT_DIR:?}"
source scripts/env.sh
source scripts/lib.sh
source scripts/batch.sh
: "${SFT_PASS:?}" "${SFT_LIST:?}"

batch=$(sed -n "${SLURM_ARRAY_TASK_ID:?}p" "$SFT_LIST")
[ -n "$batch" ] || die "no batch at line $SLURM_ARRAY_TASK_ID of $SFT_LIST"
dir="$SFT_ROOT/batches/$batch"
archive=$(archive_of "$batch")   # scratch, or the store once the batch was finished
export SFT_TAG="sft-$COHORT_NAME-$batch"   # comment of every task job of this batch

# A batch handed off to another cluster (or on its way) never runs here, even from an array
# submitted before it left: batch_lock refuses a batch this machine does not own
batch_lock "$dir"
trap 'batch_unlock "$dir"' EXIT
trap 'stop_nextflow "$dir"' USR1

# A job of this batch cancelled or killed outright (scancel, node failure: no walltime warning, so no
# pack) can leave its task jobs running, writing into work/: none may run while this job resumes
wait_task_jobs "$SFT_TAG"

if [ -z "$(state_get "$dir")" ]; then
    mapfile -t subjects < <(awk -F'\t' -v b="$batch" '$1 == b { print $2 }' "$SFT_ROOT/batches/list.tsv")
    [ "${#subjects[@]}" -gt 0 ] || die "$batch has no subject in batches/list.tsv"
    copy_inputs "$dir" "${subjects[@]}"
    copy_atlases "$dir"
    state_set "$dir" unpacked
else
    batch_unpack "$dir" "$archive"
fi

run_pass_guarded "$dir" "$SFT_PASS" && rc=0 || rc=$?
# a new archive is always written to scratch, then stored if the batch is done with every pass
archive_new="$SFT_ROOT/archives/$batch.tar"
[ "$(state_get "$dir")" = unpacked ] && archive="$archive_new"
batch_pack "$dir" "$archive" "$SFT_TAG"
store_archive "$dir" "$archive"
log "$batch: pass $SFT_PASS exit $rc, state $(state_get "$dir")"
exit "$rc"
