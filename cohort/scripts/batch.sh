# Batch folders: lock, state, first preparation, unpack and pack. Sourced by scripts/batch_job.sbatch
# (and tests/test_batch.sh), after scripts/lib.sh.
#
# A batch folder batches/bNNNN/ holds, while unpacked, everything Nextflow needs to resume it:
# PACKED_ITEMS below. Packed, they are one archive file (archives/bNNNN.tar) and the folder keeps
# only meta/, logs/ and out/ (results, hard links that cost no inode of their own once work/ is
# gone). The folder never moves: Nextflow's cache and work folders hold absolute paths.
#
# meta/state, always written whole (temporary file, then rename):
#   (absent)  never prepared            unpacked  PACKED_ITEMS are the truth
#   packing   the archive is complete and verified; PACKED_ITEMS are being deleted
#   packed    the archive is the truth; PACKED_ITEMS are absent (or a partial extraction to discard)
# Order of pack: archive written to .part, its entries counted against the folder, renamed over the
# previous archive, state packing, items deleted, state packed. Order of unpack: partial items
# deleted, archive extracted, state unpacked. The archive is never deleted, only replaced by a newer
# verified one, so a job killed at any step leaves a state the next job completes.

PACKED_ITEMS=".nextflow work .atlas_cache data_bids"

state_get() { cat "$1/meta/state" 2>/dev/null || true; }

state_set() {
    mkdir -p "$1/meta"
    echo "$2" > "$1/meta/state.tmp"
    mv -f "$1/meta/state.tmp" "$1/meta/state"
}

# batch_lock DIR: one job at a time in a batch folder (mkdir is atomic). A lock whose job is no
# longer in the queue is stale (job killed) and is taken over. Two jobs taking over the same stale
# lock at once could each delete it and create their own, the second deleting the first's: so a
# job holds the lock only once it still finds its own id in it after a pause longer than that
# window, and otherwise starts again (and then finds the other job alive).
batch_lock() {
    local dir=$1 me=${SLURM_JOB_ID:-$$} holder attempt
    mkdir -p "$dir/meta"
    for attempt in 1 2 3 4 5; do
        while ! mkdir "$dir/meta/lock" 2>/dev/null; do
            holder=$(cat "$dir/meta/lock/job" 2>/dev/null || true)
            if [ -z "$holder" ]; then
                sleep 1   # being created: its job file follows
                holder=$(cat "$dir/meta/lock/job" 2>/dev/null || true)
            fi
            if [ -n "$holder" ] && [ "$holder" != "$me" ] && job_alive "$holder"; then
                die "$dir is in use by job $holder"
            fi
            log "$dir: stale lock of job ${holder:-?}, taken over"
            rm -rf "$dir/meta/lock"
        done
        echo "$me" > "$dir/meta/lock/job"
        sleep 2
        [ "$(cat "$dir/meta/lock/job" 2>/dev/null)" = "$me" ] && return 0
    done
    die "$dir: could not take the lock"
}

batch_unlock() {
    local dir=$1 me=${SLURM_JOB_ID:-$$}
    [ "$(cat "$dir/meta/lock/job" 2>/dev/null)" = "$me" ] && rm -rf "$dir/meta/lock"
    return 0
}

# job_alive JOBID: the job is still queued or running (Slurm); without Slurm (tests), a process id
job_alive() {
    if command -v squeue >/dev/null 2>&1; then
        squeue -h -j "$1" -o %i 2>/dev/null | grep -q .
    else
        kill -0 "$1" 2>/dev/null
    fi
}

present_items() {
    local dir=$1 item
    for item in $PACKED_ITEMS; do
        [ -e "$dir/$item" ] && printf '%s ' "$item"
    done
    return 0
}

remove_items() {
    local dir=$1 item
    for item in $PACKED_ITEMS; do
        rm -rf "${dir:?}/$item"
    done
}

# batch_unpack DIR ARCHIVE: the folder ready to run (prepared batches only)
batch_unpack() {
    local dir=$1 archive=$2 state
    state=$(state_get "$dir")
    case "$state" in
        unpacked) return 0 ;;
        packing)
            log "$dir: the previous pack was interrupted after its archive was verified; finishing it"
            remove_items "$dir"
            state_set "$dir" packed
            ;;
        packed) ;;
        *) die "$dir: unexpected state '$state'" ;;
    esac
    [ -s "$archive" ] || die "$dir is packed but its archive $archive is missing"
    remove_items "$dir"   # what a killed extraction left
    tar -xf "$archive" -C "$dir" || die "extraction of $archive failed"
    state_set "$dir" unpacked
    log "$dir: unpacked from $archive"
}

# wait_task_jobs TAG: no task job of this batch left in the queue. A head job killed at its walltime
# can leave task jobs writing into work/; they are cancelled before the folder is packed.
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

# batch_pack DIR ARCHIVE TAG: everything Nextflow needs in one verified archive, then removed
batch_pack() {
    local dir=$1 archive=$2 tag=$3 items n_files n_entries
    [ "$(state_get "$dir")" = unpacked ] || return 0
    wait_task_jobs "$tag"
    mkdir -p "$dir/logs" "$(dirname "$archive")"
    for f in "$dir"/.nextflow.log*; do
        [ -e "$f" ] && mv -f "$f" "$dir/logs/$(basename "$f").$(date +%Y%m%d%H%M%S)"
    done
    items=$(present_items "$dir")
    [ -n "$items" ] || die "$dir: nothing to pack"
    # shellcheck disable=SC2086
    n_files=$(cd "$dir" && find $items | wc -l)
    # shellcheck disable=SC2086
    tar -cf "$archive.part" -C "$dir" $items || die "writing $archive.part failed"
    n_entries=$(tar -tf "$archive.part" | wc -l)
    if [ "$n_entries" != "$n_files" ]; then
        rm -f "$archive.part"
        die "$archive.part holds $n_entries entries for $n_files files and folders: not packing"
    fi
    sync "$archive.part" 2>/dev/null || sync
    mv -f "$archive.part" "$archive"
    state_set "$dir" packing
    remove_items "$dir"
    state_set "$dir" packed
    log "$dir: packed into $archive ($n_files files and folders)"
}
