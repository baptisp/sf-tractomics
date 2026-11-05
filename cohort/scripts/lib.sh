# Functions shared by run.sh and the job scripts, sourced from the root folder after scripts/env.sh.
#
# A launch folder is where one Nextflow history lives: the root folder without batches, each
# batches/bNNNN/ with them. run_pass runs one pass in one launch folder, the same way in both modes,
# so a session gives the same tasks whether it ran alone on vitalTour or in a batch on a cluster.
# A launch folder keeps in meta/:
#   inputs.sha256      checksums of data_bids/ (participants.tsv included), refused if they change:
#                      the covariates are in every task's metadata, so any change recomputes all
#   pipeline_commit    the pipeline version of its first pass; another is refused (ALLOW_COMMIT_CHANGE=1
#                      to override): changed modules recompute, and the cohort would mix versions
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
    local dir=$1 pass=$2 head p session name id rc publish=()
    cd "$dir"
    mkdir -p meta logs
    head=$(pipeline_version)
    if [ -s meta/pipeline_commit ]; then
        [ "$(cat meta/pipeline_commit)" = "$head" ] || [ "${ALLOW_COMMIT_CHANGE:-0}" = 1 ] \
            || die "$dir ran with pipeline commit $(cat meta/pipeline_commit), now $head (ALLOW_COMMIT_CHANGE=1 to override)"
    else
        echo "$head" > meta/pipeline_commit
    fi
    [ -s meta/inputs.sha256 ] || die "$dir has no input checksums"
    sha256sum --quiet -c meta/inputs.sha256 || die "$dir/data_bids changed since it was prepared"
    for p in $(passes_before "$pass"); do
        grep -qx "$p" meta/passes_done 2>/dev/null || die "$dir: pass $p has not run (passes run in order)"
    done
    # Batch results are hard links into work/: no inode of their own, and they stay valid after
    # work/ is packed and deleted. Without batches, the pipeline's default (copy), as on vitalTour.
    [ "$BATCH" = true ] && publish=(--set publish_dir_mode=link)
    python3 "$SFT_ROOT/scripts/passes.py" resolve "$pass" "meta/params_${pass}.yaml" \
        --set "participants_tsv=$dir/data_bids/participants.tsv" --set "freesurfer_license=$FS_LICENSE" \
        "${publish[@]}" || die "parameters of pass $pass refused"

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
    local sub rc
    ( run_pass "$1" "$2" ) &
    sub=$!
    while true; do
        wait "$sub" && rc=0 || rc=$?
        if [ "$rc" -gt 128 ] && kill -0 "$sub" 2>/dev/null; then
            continue
        fi
        break
    done
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

# stop_nextflow DIR: ask the running Nextflow of DIR to stop (it cancels its task jobs and keeps its
# cache); used on the walltime warning
stop_nextflow() {
    local pid
    pid=$(cat "$1/meta/nextflow.pid" 2>/dev/null || true)
    [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null && log "$1: stopping Nextflow (pid $pid) before the walltime"
    return 0
}
