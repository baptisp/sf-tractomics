# Batch folders: lock, state, first preparation, unpack and pack. Sourced by scripts/batch_job.sbatch
# (and tests/test_batch.sh), after scripts/lib.sh.
#
# A batch folder batches/bNNNN/ holds, while unpacked, everything Nextflow needs to resume it:
# PACKED_ITEMS below. Packed, they are one archive file (archives/bNNNN.tar) and the folder keeps
# only meta/, logs/ and extracted_results.tar.gz (the results matching EXTRACT_PATTERNS of
# config.env, rebuilt at every pack). out/ is in the archive: its files are hard links into work/,
# which tar stores once, so it costs the archive almost nothing. The folder never moves: Nextflow's
# cache and work folders hold absolute paths.
#
# meta/state, always written whole (temporary file, then rename):
#   (absent)  never prepared            unpacked  PACKED_ITEMS are the truth
#   packing   the archive is complete and verified; PACKED_ITEMS are being deleted
#   packed    the archive is the truth; PACKED_ITEMS are absent (or a partial extraction to discard)
# Order of pack: archive written to .part, its entries counted against the folder, renamed over the
# previous archive, state packing, items deleted, state packed. Order of unpack: partial items
# deleted, archive extracted, state unpacked. The archive is never deleted, only replaced by a newer
# verified one, so a job killed at any step leaves a state the next job completes.

# out/ first: tar stores a file with several names (out/ is hard links into work/) under the first
# name it meets and the others as links to it, so with out/ holding the data one result can be read
# back alone (scripts/extract_results.sh), without its work/ twin.
PACKED_ITEMS="out .nextflow work .atlas_cache data_bids"
# What archives written before out/ was packed hold (out/ then stayed in the folder): never delete
# a folder the archive does not hold. meta/packed_items records what each pack put in the archive.
LEGACY_PACKED_ITEMS=".nextflow work .atlas_cache data_bids"

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
# Only the batch's owner (check_owner) takes it: checked before anything is created, and again once
# the lock is held. Every job script that touches a batch goes through here, including array tasks
# queued before a change of this file (Slurm keeps their job script, not the files it sources).
batch_lock() {
    local dir=$1 me=${SLURM_JOB_ID:-$$} holder attempt
    check_owner "$dir"
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
        if [ "$(cat "$dir/meta/lock/job" 2>/dev/null)" = "$me" ]; then
            if [ "$(owner_get "$dir")" != "$MACHINE" ]; then
                rm -rf "$dir/meta/lock"
                die "$dir now belongs to $(owner_get "$dir"), not $MACHINE"
            fi
            return 0
        fi
    done
    die "$dir: could not take the lock"
}

batch_unlock() {
    local dir=$1 me=${SLURM_JOB_ID:-$$}
    [ "$(cat "$dir/meta/lock/job" 2>/dev/null)" = "$me" ] && rm -rf "$dir/meta/lock"
    return 0
}

# Owner: the machine a batch runs on, one at a time. A batch moves between clusters only packed (or
# never prepared), as its folder and its archive at the same absolute path, which is what lets
# Nextflow's cache resume it there: ./run.sh handoff on the machine that has it, a copy, ./run.sh
# adopt on the other. meta/owner holds a machine name (MACHINE), or "transit:MACHINE" from handoff
# to adopt, when it runs nowhere. No file: HOME_CLUSTER (config.env). Every change is appended to
# meta/owner_history.
owner_get() {
    local dir=$1
    if [ -s "$dir/meta/owner" ]; then
        cat "$dir/meta/owner"
    else
        echo "${HOME_CLUSTER:?HOME_CLUSTER is not set in config.env}"
    fi
}

owner_set() {
    local dir=$1 owner=$2
    mkdir -p "$dir/meta"
    echo "$owner" > "$dir/meta/owner.tmp"
    mv -f "$dir/meta/owner.tmp" "$dir/meta/owner"
    printf '%s\t%s\t%s\n' "$(date '+%F %H:%M:%S')" "$MACHINE" "$owner" >> "$dir/meta/owner_history"
}

# check_owner DIR: refuse a batch that this machine does not own (moved, or on its way)
check_owner() {
    local owner
    owner=$(owner_get "$1")
    [ "$owner" = "$MACHINE" ] || die "$1 belongs to $owner, not $MACHINE (./run.sh handoff, then adopt there)"
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

# remove_items DIR: delete the items the archive holds (meta/packed_items), nothing else
remove_items() {
    local dir=$1 item items
    items=$(cat "$dir/meta/packed_items" 2>/dev/null || echo "$LEGACY_PACKED_ITEMS")
    for item in $items; do
        rm -rf "${dir:?}/$item"
    done
}

# write_extracted DIR: DIR/extracted_results.tar.gz, the files of DIR/out matching EXTRACT_PATTERNS
# (globs relative to out/, ** for any depth), written to .part, checked and renamed. A copy of
# results the archive also holds, so it is simply replaced each time; a failure is reported, never
# fatal (the archive is the truth).
# The job scripts run under set -euo pipefail: no command here may end with a non-zero status that
# is not an error (a pattern whose last match is a folder once stopped the job mid-pack, silently)
write_extracted() {
    local dir=$1 target=$1/extracted_results.tar.gz list n
    [ -d "$dir/out" ] || return 0
    list=$(cd "$dir/out" && shopt -s globstar nullglob && for p in ${EXTRACT_PATTERNS:-metrics/** multiqc/*.html}; do
        for f in $p; do if [ -f "$f" ]; then echo "$f"; fi; done; done | sort -u)
    if [ -z "$list" ]; then
        log "$dir: no result matches EXTRACT_PATTERNS yet"
        return 0
    fi
    n=$(echo "$list" | wc -l)
    if echo "$list" | tar -czf "$target.part" -C "$dir/out" -T - \
        && [ "$(tar -tzf "$target.part" | wc -l)" = "$n" ]; then
        mv -f "$target.part" "$target"
        log "$dir: $n results in $(basename "$target")"
    else
        rm -f "$target.part"
        log "WARNING: $dir: $(basename "$target") could not be written; the previous one is kept"
    fi
    return 0
}

# archive_of BATCH: the batch archive: on scratch (archives/) if there, else where it was stored
# (meta/archive_location, so a later change of ARCHIVE_STORE does not lose it), else ARCHIVE_STORE
archive_of() {
    local b=$1 stored
    stored=$(cat "$SFT_ROOT/batches/$b/meta/archive_location" 2>/dev/null || true)
    if [ -s "$SFT_ROOT/archives/$b.tar" ]; then
        echo "$SFT_ROOT/archives/$b.tar"
    elif [ -n "$stored" ] && [ -s "$stored" ]; then
        echo "$stored"
    elif [ -n "${ARCHIVE_STORE:-}" ] && [ -s "$ARCHIVE_STORE/$b.tar" ]; then
        echo "$ARCHIVE_STORE/$b.tar"
    else
        echo "$SFT_ROOT/archives/$b.tar"
    fi
}

# store_archive DIR ARCHIVE: a packed batch done with every pass leaves scratch for ARCHIVE_STORE.
# Copied to .part, compared byte for byte, renamed (replacing an older stored copy), and only then
# deleted from scratch. The extracted results and meta/ go along, so the store alone is enough to
# resume the batch if scratch is purged. Any failure keeps the scratch archive.
store_archive() {
    local dir=$1 archive=$2 b dest p
    [ -n "${ARCHIVE_STORE:-}" ] || return 0
    [ "$(state_get "$dir")" = packed ] && [ -s "$archive" ] || return 0
    case "$archive" in "$ARCHIVE_STORE"/*) return 0 ;; esac
    for p in $(pass_list); do
        grep -qx "$p" "$dir/meta/passes_done" 2>/dev/null || return 0
    done
    b=$(basename "$dir"); dest=$ARCHIVE_STORE/$b.tar
    mkdir -p "$ARCHIVE_STORE" || { log "WARNING: $ARCHIVE_STORE cannot be created; $archive stays"; return 0; }
    if cp "$archive" "$dest.part" && cmp -s "$archive" "$dest.part"; then
        mv -f "$dest.part" "$dest"
    else
        rm -f "$dest.part"
        log "WARNING: copy of $archive to $dest failed; it stays on scratch"
        return 0
    fi
    [ -s "$dir/extracted_results.tar.gz" ] && cp "$dir/extracted_results.tar.gz" "$ARCHIVE_STORE/${b}_extracted_results.tar.gz.part" \
        && mv -f "$ARCHIVE_STORE/${b}_extracted_results.tar.gz.part" "$ARCHIVE_STORE/${b}_extracted_results.tar.gz"
    tar -cf "$ARCHIVE_STORE/${b}_meta.tar.part" -C "$dir" meta logs && mv -f "$ARCHIVE_STORE/${b}_meta.tar.part" "$ARCHIVE_STORE/${b}_meta.tar"
    echo "$dest" > "$dir/meta/archive_location"
    rm -f "$archive"
    log "$dir: archive stored in $dest (scratch copy removed)"
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
    write_extracted "$dir"
    echo "$items" > "$dir/meta/packed_items.tmp" && mv -f "$dir/meta/packed_items.tmp" "$dir/meta/packed_items"
    mv -f "$archive.part" "$archive"
    state_set "$dir" packing
    remove_items "$dir"
    state_set "$dir" packed
    log "$dir: packed into $archive ($n_files files and folders)"
}
