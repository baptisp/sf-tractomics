# Functions shared by run.sh and the job scripts, sourced from the root folder after scripts/env.sh.
#
# A launch folder is where one Nextflow history lives: the root folder without batches, each
# batches/bNNNN/ with them. run_pass runs one pass in one launch folder, the same way in both modes,
# so a session gives the same tasks whether it ran alone on vitalTour or in a batch on a cluster.
# A launch folder keeps in meta/:
#   inputs.sha256      checksums of data_bids/ (participants.tsv included), refused if they change:
#                      the covariates are in every task's metadata, so any change recomputes all
#   pipeline_commit    the pipeline version of its runs; another is refused (ALLOW_COMMIT_CHANGE=1 to
#                      accept it: it becomes the pin, the change is kept in pipeline_commit_history):
#                      changed modules recompute, and the cohort would mix versions
#   session_id         the Nextflow session of its first run, resumed by every later run
#   passes_done        the passes that ended with exit 0, in order
#   params_<pass>.yaml the parameters of each pass (scripts/passes.py)

log() { echo "[$(date '+%F %H:%M:%S')] $*" | tee -a "$SFT_ROOT/logs/run_info.txt" >&2; }
die() { log "ERROR: $*"; exit 1; }

pass_list() { python3 "$SFT_ROOT/scripts/passes.py" list; }

# pipeline_version: the last commit that changed the pipeline's files, i.e. anything of the checkout
# but this folder (cohort/), so editing the wrapper never counts as another pipeline. Refused when
# a pipeline file has uncommitted changes: the run would match no commit.
pipeline_version() {
    local here
    here=$(basename "$SFT_ROOT")
    [ -z "$(git -C "$SFT_PIPELINE" status --porcelain --untracked-files=no -- . ":(exclude)$here")" ] \
        || die "the pipeline checkout $SFT_PIPELINE has uncommitted changes outside $here/"
    git -C "$SFT_PIPELINE" log -1 --format=%H -- . ":(exclude)$here"
}

# passes_before PASS: the passes that must have run before PASS
passes_before() {
    local p
    for p in $(pass_list); do
        [ "$p" = "$1" ] && return 0
        echo "$p"
    done
    die "unknown pass $1: $(pass_list | tr '\n' ' ')"
}

# copy_inputs DIR SUBJECTS...: data_bids/ of a launch folder (the subjects' sessions listed in
# inputs/participants.tsv, from INPUT_BIDS or a per-batch input archive), and its checksums
copy_inputs() {
    local dir=$1 tar_in sub ses; shift
    rm -rf "${dir:?}/data_bids"   # a copy interrupted earlier
    mkdir -p "$dir/data_bids" "$dir/meta"
    tar_in="$SFT_ROOT/inputs/batch_tars/$(basename "$dir").tar"
    if [ -s "$tar_in" ]; then
        tar -xf "$tar_in" -C "$dir/data_bids" || die "extraction of $tar_in failed"
    else
        [ -d "$INPUT_BIDS" ] || die "input folder not found: $INPUT_BIDS"
        cp "$INPUT_BIDS/dataset_description.json" "$dir/data_bids/"
        for sub in "$@"; do
            mkdir -p "$dir/data_bids/$sub"
            for ses in $(awk -F'\t' -v s="$sub" '$1 == s { print $2 }' "$SFT_ROOT/inputs/participants.tsv" | sort -u); do
                [ -d "$INPUT_BIDS/$sub/ses-$ses" ] || die "$INPUT_BIDS/$sub/ses-$ses not found"
                cp -rL "$INPUT_BIDS/$sub/ses-$ses" "$dir/data_bids/$sub/"
            done
        done
    fi
    { head -1 "$SFT_ROOT/inputs/participants.tsv"; awk -F'\t' 'NR == FNR { keep[$1]; next } FNR > 1 && $1 in keep' \
        <(printf '%s\n' "$@") "$SFT_ROOT/inputs/participants.tsv"; } > "$dir/data_bids/participants.tsv"
    (cd "$dir" && find data_bids -type f | sort | xargs sha256sum) > "$dir/meta/inputs.sha256"
    log "$dir: inputs of $# subject(s), $(find "$dir/data_bids" -name '*.nii.gz' | wc -l) images"
}

# copy_atlases DIR: the atlases setup downloaded, as hard links (no new inode, no download)
copy_atlases() {
    local dir=$1
    [ -s "$SFT_ROOT/work/atlas_iit/IITmean_b0.nii.gz" ] || die "atlases missing in $SFT_ROOT/work/atlas_iit: run setup"
    mkdir -p "$dir/work"
    cp -al "$SFT_ROOT/work/atlas_iit" "$dir/work/"
    [ -d "$SFT_ROOT/.atlas_cache" ] && cp -al "$SFT_ROOT/.atlas_cache" "$dir/"
    return 0
}

# launch_session DIR: the session of the first run in DIR, if any (Nextflow history: run name in
# column 3, session id in 6; run.sh names every run sft-...)
launch_session() {
    local dir=$1
    if [ ! -s "$dir/meta/session_id" ] && [ -s "$dir/.nextflow/history" ]; then
        awk -F'\t' '$3 ~ /^sft-/ { print $6; exit }' "$dir/.nextflow/history" > "$dir/meta/session_id"
    fi
    cat "$dir/meta/session_id" 2>/dev/null || true
}

# run_pass DIR PASS: one pass in launch folder DIR (inputs already in DIR/data_bids). Nextflow runs
# in the background, its pid in DIR/meta/nextflow.pid, so a job script can stop it cleanly.
run_pass() {
    local dir=$1 pass=$2 head p session name id rc sets=()
    cd "$dir"
    mkdir -p meta logs
    head=$(pipeline_version)
    if [ -s meta/pipeline_commit ] && [ "$(cat meta/pipeline_commit)" != "$head" ]; then
        [ "${ALLOW_COMMIT_CHANGE:-0}" = 1 ] \
            || die "$dir ran with pipeline commit $(cat meta/pipeline_commit), now $head (ALLOW_COMMIT_CHANGE=1 to override)"
        # Accepted: the new commit is the pin from now on, the earlier ones stay in the history
        log "$dir: pipeline commit $(cat meta/pipeline_commit) replaced by $head (ALLOW_COMMIT_CHANGE=1)"
        echo "$(date '+%F %H:%M:%S') $(cat meta/pipeline_commit) -> $head" >> meta/pipeline_commit_history
    fi
    echo "$head" > meta/pipeline_commit
    # An Alliance cluster runs the patched Nextflow jar (scripts/patch_nextflow.sh), or its task
    # hashes would hold this filesystem's directory sizes and no batch could resume on another one
    if [ -n "${CC_CLUSTER:-}" ] && [ "$MACHINE" = "$CC_CLUSTER" ]; then
        nextflow_is_patched || die "the Nextflow jar $(nextflow_jar) is not patched: ./run.sh setup"
    fi
    [ -s meta/inputs.sha256 ] || die "$dir has no input checksums"
    sha256sum --quiet -c meta/inputs.sha256 || die "$dir/data_bids changed since it was prepared"
    for p in $(passes_before "$pass"); do
        grep -qx "$p" meta/passes_done 2>/dev/null || die "$dir: pass $p has not run (passes run in order)"
    done
    # Batch results are hard links into work/: no inode of their own, and they stay valid after
    # work/ is packed and deleted. Without batches, the pipeline's default (copy), as on vitalTour.
    [ "$BATCH" = true ] && sets=(--set publish_dir_mode=link)
    # recon-all again, with extra options, on the T1s of inputs/reconall_rerun.tsv (README: recon-all
    # reruns). The launch keeps a copy, so meta/ records what it was given.
    if [ -s "$SFT_ROOT/inputs/reconall_rerun.tsv" ]; then
        cp "$SFT_ROOT/inputs/reconall_rerun.tsv" "meta/reconall_rerun_${pass}.tsv"
        sets+=(--set "reconall_rerun=$PWD/meta/reconall_rerun_${pass}.tsv")
    fi
    python3 "$SFT_ROOT/scripts/passes.py" resolve "$pass" "meta/params_${pass}.yaml" \
        --set "participants_tsv=$dir/data_bids/participants.tsv" --set "freesurfer_license=$FS_LICENSE" \
        "${sets[@]}" || die "parameters of pass $pass refused"

    session=$(launch_session "$dir")
    id=${SLURM_JOB_ID:-$(date +%Y%m%d%H%M%S)}
    name="sft-${pass//_/-}-$id"
    log "$dir: pass $pass, run $name, session ${session:-new}"
    "$SFT_ROOT/bin/nextflow" run "$SFT_PIPELINE" \
        -name "$name" -profile "$SFT_PROFILE" -c "$SFT_CONFIG" \
        -params-file "meta/params_${pass}.yaml" \
        --input data_bids --outdir out -w work \
        -with-trace "logs/trace_${pass}_${id}.txt" \
        ${session:+-resume "$session"} \
        -ansi-log false > "logs/nextflow_${pass}_${id}.log" 2>&1 &
    local pid=$!
    echo "$pid" > meta/nextflow.pid
    while true; do
        wait "$pid" && rc=0 || rc=$?
        # A trapped signal (walltime warning) interrupts wait with a status > 128 while Nextflow
        # is still stopping: wait again for its real exit status
        if [ "$rc" -gt 128 ] && kill -0 "$pid" 2>/dev/null; then
            continue
        fi
        break
    done
    rm -f meta/nextflow.pid
    launch_session "$dir" > /dev/null

    # Tasks of earlier runs computed again (they should all be reused)
    local earlier
    earlier=$(ls logs/trace_*.txt 2>/dev/null | grep -v "logs/trace_${pass}_${id}.txt" || true)
    if [ -n "$earlier" ] && [ -s "logs/trace_${pass}_${id}.txt" ]; then
        # shellcheck disable=SC2086
        python3 "$SFT_ROOT/scripts/reuse_report.py" "logs/trace_${pass}_${id}.txt" $earlier \
            > "logs/reuse_${pass}_${id}.txt" || log "$dir: tasks of earlier runs computed again: logs/reuse_${pass}_${id}.txt"
    fi
    # Tasks failed for good: a failure no longer stops the run (errorStrategy 'ignore' once the
    # retries are spent), so they are listed in out/metrics/failed_tasks.tsv (packed with the batch,
    # merged with the other batches' tables) for a later fix. When more than MAX_FAILED_FRACTION of
    # the folder's DWI runs (the pipeline's samples, one row of participants.tsv each) failed, the
    # cause is not a run but a bug: the pass is not done.
    if [ -s "logs/trace_${pass}_${id}.txt" ]; then
        local counts n_tasks n_failed_sessions n_failed n_runs
        counts=$(python3 "$SFT_ROOT/scripts/failure_report.py" "logs/trace_${pass}_${id}.txt" work \
            out/metrics/failed_tasks.tsv --batch "$(basename "$dir")" --pass "$pass" --run "$name") \
            || { log "WARNING: $dir: the failure report of $name could not be written"; counts="0 0 0"; }
        read -r n_tasks n_failed_sessions n_failed <<< "$counts"
        [ -s out/metrics/failed_tasks.tsv ] && cp out/metrics/failed_tasks.tsv "logs/failed_tasks_${pass}_${id}.tsv"
        n_runs=$(awk -F'\t' 'NR > 1 && NF' data_bids/participants.tsv | wc -l)
        if [ "$n_tasks" -gt 0 ]; then
            log "$dir: $n_tasks task(s) failed, $n_failed of $n_runs run(s), $n_failed_sessions session(s): out/metrics/failed_tasks.tsv"
            if awk -v f="$n_failed" -v n="$n_runs" -v m="${MAX_FAILED_FRACTION:-0.5}" 'BEGIN { exit !(f > m * n) }'; then
                log "ERROR: $dir: more than ${MAX_FAILED_FRACTION:-0.5} of the runs failed: pass $pass not marked done"
                [ "$rc" = 0 ] && rc=1
            fi
        fi
    fi
    if [ "$rc" = 0 ]; then
        grep -qx "$pass" meta/passes_done 2>/dev/null || echo "$pass" >> meta/passes_done
    fi
    log "$dir: pass $pass ended, exit $rc"
    return "$rc"
}

# run_pass_guarded DIR PASS: run_pass in a background subshell, its exit status returned. In a
# subshell, a refusal (die) or a failed run ends the subshell only, so the caller still packs; in
# the background, so the caller's signal traps (walltime warning) run at once instead of after the
# pass (bash defers traps while a foreground command runs).
run_pass_guarded() {
    local sub rc watcher=""
    ( run_pass "$1" "$2" ) &
    sub=$!
    # In a batch job, task jobs hung at container start are cancelled while the pass runs. Started
    # here rather than in batch_job.sbatch: Slurm keeps the job script of submission time, while
    # this file is read when the job starts, so batches already queued get the watchdog too.
    if [ -n "${SFT_TAG:-}" ]; then
        ( set +e; watch_hung_tasks "$SFT_TAG" "$1" ) &
        watcher=$!
    fi
    while true; do
        wait "$sub" && rc=0 || rc=$?
        if [ "$rc" -gt 128 ] && kill -0 "$sub" 2>/dev/null; then
            continue
        fi
        break
    done
    [ -n "$watcher" ] && { kill "$watcher" 2>/dev/null || true; }
    return "$rc"
}

# wait_task_jobs TAG: no task job of this batch left in the queue. A head job killed at its walltime,
# cancelled or lost with its node can leave task jobs writing into work/; they are cancelled before
# the folder is packed, and before a later job of the batch resumes it.
wait_task_jobs() {
    local tag=$1 ids i
    command -v squeue >/dev/null 2>&1 || return 0
    for i in $(seq 1 60); do
        ids=$(squeue -h -u "$USER" -o "%i %k" | awk -v t="$tag" '$2 == t { print $1 }')
        [ -z "$ids" ] && return 0
        if [ "$i" = 1 ]; then
            log "cancelling task jobs left by $tag: $(echo $ids)"
            scancel $ids || true
        fi
        sleep 10
    done
    die "task jobs of $tag still in the queue after 10 min: not packing"
}

# Hung containers. On Rorqual some task jobs hang at container start (0.2% of the first day's tasks,
# up to 9% in its busiest hour): Apptainer's processes wait on each other and the task's command
# never starts. Such a job holds its batch until its time limit. The watchdog of a batch job
# cancels them; Nextflow then retries the task (exitReadTimeout, 30 min; a job gone without an exit
# code is in the retry list). A task job is hung when, past HANG_MIN_MINUTES, its batch step holds
# only the job script, the tee of .command.out/.err and Apptainer runtime parent, at two checks in
# a row: a container that started has more (appinit, squashfuse, the task's command).
HANG_WRAPPERS='^(/bin/bash .*/slurm_script|slurmstepd: .*|tee [.]command[.](out|err)|Apptainer runtime parent|sleep [0-9]+)$'

# duration_seconds ELAPSED: seconds of a Slurm elapsed time ([D-][HH:]MM:SS)
duration_seconds() {
    awk -F'[-:]' '{ if (NF == 4) s = $1 * 86400 + $2 * 3600 + $3 * 60 + $4
                    else if (NF == 3) s = $1 * 3600 + $2 * 60 + $3
                    else s = $1 * 60 + $2
                    print s }' <<< "$1"
}

# task_processes JOBID: the command line of each process of the job's batch step, one per line, read
# on its node (an srun step inside the job; environment cleared, so the caller's own job does not
# leak into it). Nothing when the job has ended.
task_processes() {
    env -i PATH="$PATH" HOME="$HOME" USER="$USER" timeout 60 srun --jobid="$1" --overlap --ntasks=1 bash -c \
        'for p in $(scontrol listpids "$SLURM_JOB_ID" | awk "\$3 == \"batch\" { print \$1 }"); do ps -o args= -p "$p"; done' \
        < /dev/null 2>/dev/null || true
}

# task_is_hung: stdin is task_processes' output; true when Apptainer is there and nothing else ran
task_is_hung() {
    awk -v re="$HANG_WRAPPERS" 'NF { n++; if ($0 == "Apptainer runtime parent") a = 1; if ($0 !~ re) other = 1 }
        END { exit !(n && a && !other) }'
}

# watch_hung_tasks TAG DIR: every HANG_CHECK_SECONDS, cancel the task jobs of TAG found hung at two
# checks in a row; each one is logged and listed in DIR/logs/hung_tasks.tsv. Runs until killed.
watch_hung_tasks() {
    local tag=$1 dir=$2 interval=${HANG_CHECK_SECONDS:-300} min=$(( ${HANG_MIN_MINUTES:-10} * 60 ))
    local suspects="" seen id elapsed name
    command -v squeue >/dev/null 2>&1 || return 0
    mkdir -p "$dir/logs"
    while sleep "$interval"; do
        seen=""
        while read -r id elapsed name; do
            [ "$(duration_seconds "$elapsed")" -ge "$min" ] || continue
            task_processes "$id" | task_is_hung || continue
            if [[ " $suspects " == *" $id "* ]]; then
                if scancel "$id"; then
                    log "$dir: task job $id ($name) hung at container start for $elapsed, cancelled: Nextflow retries it"
                    printf '%s\t%s\t%s\t%s\n' "$(date '+%F %H:%M:%S')" "$id" "$elapsed" "$name" >> "$dir/logs/hung_tasks.tsv"
                fi
            else
                seen="$seen $id"
            fi
        done < <(squeue -h -u "$USER" -t R -o "%i %k %M %j" | awk -v t="$tag" '$2 == t { print $1, $3, $4 }')
        suspects=$seen
    done
}

# stop_nextflow DIR: ask the running Nextflow of DIR to stop (it cancels its task jobs and keeps its
# cache); used on the walltime warning
stop_nextflow() {
    local pid
    pid=$(cat "$1/meta/nextflow.pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null && log "$1: stopping Nextflow (pid $pid) before the walltime"
    return 0
}

# nextflow_jar, nextflow_is_patched, patch_nextflow
source "$(dirname "${BASH_SOURCE[0]}")/patch_nextflow.sh"
