#!/bin/bash
# sf-tractomics on the sessions of inputs/participants.tsv, in passes (params/passes/), on vitalTour
# or an Alliance cluster, with or without batches (config.env). On a cluster nothing heavy runs on
# the login node: every download, copy and pipeline run is a Slurm job.
#
# Usage: ./run.sh [--batch|--no-batch] COMMAND
#   setup        Nextflow, the images and atlases, the parameters of every pass checked with -preview
#                (no task), for the pipeline checkout this folder sits in. A Slurm job on a cluster.
#                Without batches it also copies every session into data_bids/.
#   submit PASS  run PASS (passes run in order; a finished pass is reused). Without batches: one
#                Nextflow head job (cluster) or Nextflow in the foreground (vitalTour, use tmux).
#                With batches: a Slurm array, one task per batch not done with PASS, at most
#                MAX_UNPACKED at once; each task unpacks its batch, runs PASS and packs it again.
#                BATCHES="b0001 b0002" limits it to those batches; FORCE=1 reruns done ones.
#   status       jobs in the queue, then per launch folder: passes done, state, last log
#   merge        batches only: the batches' metrics tables, concatenated into merged/
# Records: logs/run_info.txt (everything run.sh and the jobs do), meta/ of each launch folder.
set -euo pipefail
cd "$(dirname "$0")"

BATCH_OVERRIDE=""
case "${1:-}" in
    --batch) BATCH_OVERRIDE=true; shift ;;
    --no-batch) BATCH_OVERRIDE=false; shift ;;
esac
unset BATCH   # only config.env or --batch/--no-batch decide, never a variable left in the shell
source scripts/env.sh
[ -n "$BATCH_OVERRIDE" ] && BATCH=$BATCH_OVERRIDE
export BATCH
mkdir -p logs
source scripts/lib.sh

# Head and batch jobs: recon-all (~7 h per T1) and eddy on CPU dominate. JOB_TIME=... ./run.sh submit
# sets another walltime (tests of the walltime warning; above 30 min, when the warning comes)
JOB_TIME="${JOB_TIME:-2-00:00:00}"
JOB_NAME="sft-$COHORT_NAME"

on_cluster() { [ "$MACHINE" != vitaltour ]; }

# A launch folder is never used by two runs at once, and a pass waits for the previous one: one
# submission of this root folder in the queue at a time
no_job_queued() {
    on_cluster || return 0
    if squeue -h -u "$USER" -o %j | grep -qxF -e "$JOB_NAME" -e "$JOB_NAME-setup"; then
        die "jobs of $COHORT_NAME are already in the queue (squeue -u $USER): wait for them"
    fi
}

# The batch and its pinned settings: once a launch folder exists, BATCH may not change
check_mode() {
    if [ -s meta/mode ] && [ "$(cat meta/mode)" != "$BATCH" ]; then
        die "this folder was set up with BATCH=$(cat meta/mode); it cannot change (results and caches would split)"
    fi
    mkdir -p meta
    echo "$BATCH" > meta/mode
}

case "${1:-}" in
setup)
    check_mode
    [ -s "$FS_LICENSE" ] || die "FreeSurfer licence not found: $FS_LICENSE"
    [ -s inputs/participants.tsv ] || die "inputs/participants.tsv missing"
    python3 scripts/passes.py check || die "the parameter files break a rule"
    if on_cluster; then
        sacctmgr -nP show assoc user="$USER" format=account | grep -qx "$ACCOUNT" \
            || die "$ACCOUNT is not one of your Slurm accounts"
        no_job_queued
        job=$(sbatch --parsable --account="$ACCOUNT" --job-name="$JOB_NAME-setup" \
            --output="logs/setup_%j.log" scripts/setup.sbatch)
        log "submitted setup: job $job, log logs/setup_${job}.log"
    else
        scripts/setup_steps.sh 2>&1 | tee "logs/setup_$(date +%Y%m%d%H%M%S).log"
    fi
    ;;
submit)
    pass=${2:?usage: ./run.sh submit PASS}
    check_mode
    [ -e meta/setup_done ] || die "setup has not finished (./run.sh status)"
    python3 scripts/passes.py check || die "the parameter files break a rule"
    passes_before "$pass" > /dev/null
    no_job_queued
    if [ "$BATCH" != true ]; then
        export SFT_PASS=$pass
        if on_cluster; then
            job=$(sbatch --parsable --account="$ACCOUNT" --job-name="$JOB_NAME" --time="$JOB_TIME" \
                --output="logs/head_${pass}_%j.log" --export=ALL,SFT_PASS="$pass" scripts/head.sbatch)
            log "submitted pass $pass: head job $job"
        else
            export SFT_TAG="$JOB_NAME"
            run_pass_guarded "$SFT_ROOT" "$pass"
        fi
    else
        on_cluster || die "batch mode needs Slurm (an Alliance cluster)"
        python3 scripts/make_batches.py "$BATCH_SIZE" || die "batches/list.tsv could not be built"
        list="logs/submit_${pass}_$(date +%Y%m%d%H%M%S).list"
        all=$(cut -f1 batches/list.tsv | uniq)
        for b in ${BATCHES:-}; do
            echo "$all" | grep -qx "$b" || die "BATCHES: $b is not in batches/list.tsv"
        done
        for b in $all; do
            [ -z "${BATCHES:-}" ] || echo " $BATCHES " | grep -q " $b " || continue
            if [ "${FORCE:-0}" = 1 ] || ! grep -qx "$pass" "batches/$b/meta/passes_done" 2>/dev/null; then
                echo "$b"
            fi
        done > "$list"
        n=$(wc -l < "$list")
        [ "$n" -gt 0 ] || { log "every batch has done pass $pass (FORCE=1 to run it again)"; rm -f "$list"; exit 0; }
        job=$(sbatch --parsable --account="$ACCOUNT" --job-name="$JOB_NAME" --time="$JOB_TIME" \
            --array="1-$n%$MAX_UNPACKED" --output="logs/batch_${pass}_%A_%a.log" \
            --export=ALL,SFT_PASS="$pass",SFT_LIST="$SFT_ROOT/$list",BATCH=true scripts/batch_job.sbatch)
        log "submitted pass $pass: array $job, $n batch(es) ($list), $MAX_UNPACKED at once"
    fi
    ;;
status)
    if on_cluster; then
        squeue -u "$USER" -o "%.12i %.24j %.8T %.10M %.4C %.6m %R" | awk -v n="$JOB_NAME" 'NR == 1 || index($2, n) == 1'
    fi
    show() {   # show DIR: one line per launch folder
        local d=$1 last
        last=$(ls -t "$d"/logs/nextflow_*.log 2>/dev/null | head -1 || true)
        printf '%-14s %-9s passes: %-28s %s\n' "$(basename "$d")" "$(cat "$d/meta/state" 2>/dev/null || echo -)" \
            "$(tr '\n' ' ' < "$d/meta/passes_done" 2>/dev/null || echo none)" \
            "${last:+last log ${last#"$SFT_ROOT"/}}"
    }
    latest_setup=$(ls -t logs/setup_*.log 2>/dev/null | head -1 || true)
    [ -n "$latest_setup" ] && { echo "== $latest_setup"; tail -n 5 "$latest_setup"; }
    if [ "$BATCH" = true ]; then
        for d in batches/b*/; do [ -d "$d" ] && show "${d%/}"; done
    else
        show "$SFT_ROOT"
        last=$(ls -t logs/nextflow_*.log 2>/dev/null | head -1 || true)
        [ -n "$last" ] && { echo "== $last"; tail -n 8 "$last"; }
    fi
    for r in $(ls -t logs/reuse_*.txt batches/*/logs/reuse_*.txt 2>/dev/null | head -5); do
        echo "== $r"; cat "$r"
    done
    ;;
merge)
    [ "$BATCH" = true ] || die "merge is for batches; without them the tables are already in out/metrics"
    python3 scripts/merge_batches.py
    ;;
*)
    sed -n '2,17p' "$0" >&2
    exit 1
    ;;
esac
