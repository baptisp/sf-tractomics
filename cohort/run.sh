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
#   status       jobs in the queue, then per launch folder: passes done, state, owner, last log
#   merge        batches only: the batches' metrics tables, concatenated into merged/
#   handoff MACHINE BATCH...  batches only: give packed (or never prepared) batches to another
#                cluster. They stop running here, and transfers/ gets the list of files to copy
#                (a Globus batch file, same paths on both sides) and a manifest for adopt.
#   adopt MANIFEST  batches only, on the receiving cluster once the copy is done: checks the
#                copy and that both clusters run the same cohort, then the batches run here.
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
source scripts/batch.sh

# Head and batch jobs: recon-all (~7 h per T1) and eddy on CPU dominate. JOB_TIME=... ./run.sh submit
# sets another walltime (tests of the walltime warning; above 30 min, when the warning comes).
# A batch took 5 to 9 h on Rorqual (ADNI, 2026-11-06): 24 h lets its job use the <= 24 h partitions
# (more nodes than <= 72 h). One that runs over is stopped 30 min before, packed with its cache, and
# resumes when submitted again. A whole cohort without batches keeps 2 days.
if [ "$BATCH" = true ]; then
    JOB_TIME="${JOB_TIME:-1-00:00:00}"
else
    JOB_TIME="${JOB_TIME:-2-00:00:00}"
fi
JOB_NAME="sft-$COHORT_NAME"

on_cluster() { [ "$MACHINE" != vitaltour ]; }

# cohort_files: what two machines running one cohort must have identical (handoff, adopt): the
# sessions and batches, every input table, the parameters of the passes, the task settings
cohort_files() {
    { echo batches/list.tsv; ls inputs/*.tsv | grep -v '\.example\.tsv$'; find params -type f; echo configs/alliance.config; } | sort
}

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
        # only the batches this machine owns (handoff, adopt); the others are counted
        not_here=0
        for b in $all; do
            [ -z "${BATCHES:-}" ] || echo " $BATCHES " | grep -q " $b " || continue
            if [ "$(owner_get "batches/$b")" != "$MACHINE" ]; then
                not_here=$((not_here + 1))
                continue
            fi
            if [ "${FORCE:-0}" = 1 ] || ! grep -qx "$pass" "batches/$b/meta/passes_done" 2>/dev/null; then
                echo "$b"
            fi
        done > "$list"
        [ "$not_here" = 0 ] || log "$not_here batch(es) left out: owned by another machine (./run.sh status)"
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
        printf '%-14s %-9s %-16s passes: %-28s %s\n' "$(basename "$d")" "$(cat "$d/meta/state" 2>/dev/null || echo -)" \
            "$( [ "$BATCH" = true ] && owner_get "$d" || echo -)" \
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
    rc=0
    python3 scripts/merge_batches.py || rc=$?
    python3 scripts/volume_qc.py
    exit "$rc"
    ;;
handoff)
    # Packed (or never prepared) batches go to another machine. Each is locked, checked and marked
    # "transit:DEST": it then runs nowhere (a batch job refuses a batch it does not own, queued ones
    # included). Everything to copy is staged in one folder, transfers/<date>_<here>_to_<DEST>/,
    # laid out like this folder: the batch folders (copied), their archives and input tars (hard
    # links: no space, no inode), and manifest.tsv for adopt. Copy that one folder to the same path
    # on DEST (Nextflow's cache holds absolute paths, so the cohort folder has the same path on
    # both), then ./run.sh adopt there. Nothing of this machine's copies is deleted.
    [ "$BATCH" = true ] || die "handoff is for batches"
    dest=${2:?usage: ./run.sh handoff MACHINE BATCH...}
    shift 2
    [ "$dest" != "$MACHINE" ] || die "$dest is this machine"
    [ $# -gt 0 ] || die "usage: ./run.sh handoff MACHINE BATCH..."
    all=$(cut -f1 batches/list.tsv | uniq)
    for b in "$@"; do   # every batch checked before any is changed
        echo "$all" | grep -qx "$b" || die "$b is not in batches/list.tsv"
        [ "$(owner_get "batches/$b")" = "$MACHINE" ] || die "$b belongs to $(owner_get "batches/$b"), not $MACHINE"
        case "$(state_get "batches/$b")" in
            packed) [ -s "$(archive_of "$b")" ] || die "$b is packed but its archive $(archive_of "$b") is missing" ;;
            "") ;;
            *) die "$b is $(state_get "batches/$b"): only a packed or never prepared batch can move" ;;
        esac
        [ ! -e "batches/$b/meta/lock" ] || die "$b is locked (a job is using it, or a stale lock: check squeue)"
    done
    stage="transfers/$(date +%Y%m%d%H%M%S)_${MACHINE}_to_${dest}"
    mkdir -p "$stage/batches" "$stage/archives" "$stage/inputs/batch_tars"
    {
        printf '# handoff\t%s\t%s\t%s\n' "$MACHINE" "$dest" "$(date '+%F %H:%M:%S')"
        printf '# pipeline\t%s\n' "$(pipeline_version)"
        printf '# nextflow\t%s\n' "$NXF_VER"
        cohort_files | while read -r f; do printf '# file\t%s\t%s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"; done
        printf 'batch\tstate\tarchive_bytes\tinput_tar_bytes\n'
    } > "$stage/manifest.tsv.part"
    for b in "$@"; do
        d="batches/$b"
        batch_lock "$d"
        state=$(state_get "$d")
        case "$state" in packed|"") ;; *) batch_unlock "$d"; die "$b became $state while handing off" ;; esac
        owner_set "$d" "transit:$dest"
        batch_unlock "$d"
        abytes=- tbytes=-
        if [ "$state" = packed ]; then
            a=$(archive_of "$b")
            ln "$a" "$stage/archives/$b.tar" \
                || die "$a cannot be linked into $stage (another file system): copy it to archives/ first, then hand $b off again"
            abytes=$(stat -c %s "$a")
        fi
        if [ -s "inputs/batch_tars/$b.tar" ]; then
            ln "inputs/batch_tars/$b.tar" "$stage/inputs/batch_tars/$b.tar"
            tbytes=$(stat -c %s "inputs/batch_tars/$b.tar")
        fi
        cp -a "$d" "$stage/batches/"
        printf '%s\t%s\t%s\t%s\n' "$b" "${state:-new}" "$abytes" "$tbytes" >> "$stage/manifest.tsv.part"
    done
    mv -f "$stage/manifest.tsv.part" "$stage/manifest.tsv"
    log "handoff to $dest: $# batch(es), now transit:$dest. Copy the folder $SFT_ROOT/$stage to the same path on $dest, then there: ./run.sh adopt $stage"
    if on_cluster && command -v squeue >/dev/null 2>&1; then
        n=$(squeue -h -r -u "$USER" -n "$JOB_NAME" -t PD | wc -l)
        [ "$n" = 0 ] || log "note: $n task(s) of $JOB_NAME are queued here; one that reaches a handed-off batch stops at once (owner check). Cancel them to keep the queue clean."
    fi
    ;;
adopt)
    # The receiving side of handoff, once its folder is copied here: the same cohort (inputs, batch
    # list, parameters, task settings, pipeline commit, Nextflow version), every archive and input
    # tar complete, every batch in transit to this machine, and no batch this machine runs is
    # overwritten. Checked for every batch before anything moves. Then each batch's folder, archive
    # and input tar move into place; what they replace (this machine's copies from before it gave
    # the batch away) goes to the transfer folder's replaced/, to delete once satisfied.
    [ "$BATCH" = true ] || die "adopt is for batches"
    stage=${2:?usage: ./run.sh adopt transfers/<folder>}
    stage=${stage%/}
    manifest="$stage/manifest.tsv"
    [ -s "$manifest" ] || die "$manifest not found (is the copy finished?)"
    dest=$(awk -F'\t' '$1 == "# handoff" { print $3 }' "$manifest")
    [ "$dest" = "$MACHINE" ] || die "$manifest hands off to ${dest:-?}, not to $MACHINE"
    pin=$(awk -F'\t' '$1 == "# pipeline" { print $2 }' "$manifest")
    [ "$pin" = "$(pipeline_version)" ] || die "the pipeline commit differs: $pin there, $(pipeline_version) here"
    [ "$(awk -F'\t' '$1 == "# nextflow" { print $2 }' "$manifest")" = "$NXF_VER" ] || die "the Nextflow version differs"
    there=$(awk -F'\t' '$1 == "# file" { print $2 "\t" $3 }' "$manifest" | sort)
    here=$(cohort_files | while read -r f; do printf '%s\t%s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"; done | sort)
    [ "$there" = "$here" ] || die "the cohort files differ (batches/list.tsv, inputs/, params/, configs/):
$(diff <(echo "$there") <(echo "$here") || true)"
    rows=$(awk -F'\t' '!/^#/ && $1 != "batch"' "$manifest")
    [ -n "$rows" ] || die "$manifest lists no batch"
    while IFS=$'\t' read -r b state abytes tbytes; do
        s="$stage/batches/$b"
        [ "$(owner_get "$s")" = "transit:$MACHINE" ] || die "$s is $(owner_get "$s"), not in transit to $MACHINE"
        [ "$(state_get "$s")" = "${state/new/}" ] || die "$s is '$(state_get "$s")', '$state' in the manifest"
        if [ "$state" = packed ]; then
            [ "$(stat -c %s "$stage/archives/$b.tar" 2>/dev/null)" = "$abytes" ] \
                || die "$stage/archives/$b.tar is missing or incomplete ($abytes bytes expected)"
        fi
        if [ "$tbytes" != - ]; then
            [ "$(stat -c %s "$stage/inputs/batch_tars/$b.tar" 2>/dev/null)" = "$tbytes" ] \
                || die "$stage/inputs/batch_tars/$b.tar is missing or incomplete"
        elif [ "$state" = new ]; then
            [ -d "$INPUT_BIDS" ] || die "$b was never prepared and has no input tar: $INPUT_BIDS is needed here"
        fi
        if [ -e "batches/$b" ] && [ "$(owner_get "batches/$b")" = "$MACHINE" ]; then
            die "batches/$b is this machine's and would be overwritten"
        fi
        [ ! -e "batches/$b/meta/lock" ] || die "batches/$b is locked here"
    done <<< "$rows"
    mkdir -p "$stage/replaced/batches" "$stage/replaced/archives" "$stage/replaced/inputs/batch_tars"
    while IFS=$'\t' read -r b state abytes tbytes; do
        for f in "batches/$b" "archives/$b.tar" "inputs/batch_tars/$b.tar"; do
            if [ -e "$f" ] && { [ -e "$stage/$f" ] || [ "$f" = "batches/$b" ]; }; then
                mv "$f" "$stage/replaced/$f"
            fi
            if [ -e "$stage/$f" ]; then
                mkdir -p "$(dirname "$f")"
                mv "$stage/$f" "$f"
            fi
        done
        d="batches/$b"
        # where the other machine had stored the archive does not exist here: archives/ is used
        if [ -s "$d/meta/archive_location" ] && [ ! -s "$(cat "$d/meta/archive_location")" ]; then
            mv -f "$d/meta/archive_location" "$d/meta/archive_location.before_adopt"
        fi
        owner_set "$d" "$MACHINE"
    done <<< "$rows"
    log "adopted $(echo "$rows" | wc -l) batch(es) from $stage; they run here now (./run.sh submit PASS). Earlier copies replaced: $stage/replaced/ (delete once satisfied)"
    ;;
*)
    sed -n '2,21p' "$0" >&2
    exit 1
    ;;
esac
