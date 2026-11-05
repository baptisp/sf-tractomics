#!/bin/bash
# Tests of scripts/batch.sh: pack and unpack give back exactly the folder, and a job killed at any
# step leaves a state the next job completes without losing anything. Locks refuse a second job.
# Runs anywhere (no Slurm: a lock holder is a process id). Run: bash tests/test_batch.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SFT_ROOT=$T
mkdir -p "$T/logs"
source "$REPO/scripts/lib.sh"
source "$REPO/scripts/batch.sh"
unset -f squeue 2>/dev/null
PATH=$(echo "$PATH" | tr ':' '\n' | grep -v slurm | paste -sd:)   # no Slurm commands here

failures=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { local what=$1; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }

# A batch folder like a real one: cache, task folders with a hard link, a symlink to another task's
# output, an empty folder, inputs, atlases; and out/ holding a hard link to a work file
make_batch() {
    local d=$1
    mkdir -p "$d"/{.nextflow/cache,work/ab/123,work/cd/456,work/empty,data_bids/sub-1,.atlas_cache/fs,out/sub-1,meta}
    echo history > "$d/.nextflow/history"
    echo cache > "$d/.nextflow/cache/db"
    echo result > "$d/work/ab/123/vol.csv"
    head -c 100000 /dev/urandom > "$d/work/ab/123/image.nii.gz"
    ln "$d/work/ab/123/vol.csv" "$d/work/ab/123/vol_link.csv"
    ln -s "$d/work/ab/123/image.nii.gz" "$d/work/cd/456/image.nii.gz"
    echo t1 > "$d/data_bids/sub-1/T1w.nii.gz"
    echo b0 > "$d/.atlas_cache/fs/IIT.nii.gz"
    ln "$d/work/ab/123/vol.csv" "$d/out/sub-1/vol.csv"
    echo "nextflow log" > "$d/.nextflow.log"
    state_set "$d" unpacked
}

# Everything of the packed items: path, type, size, content checksum, link target
manifest() {
    (cd "$1" && find .nextflow work .atlas_cache data_bids -printf '%p %y %s %l\n' | sort
     cd "$1" && find .nextflow work .atlas_cache data_bids -type f -print0 | sort -z | xargs -0 sha256sum)
}

D=$T/batches/b0001
A=$T/archives/b0001.tar

# 1. pack, then unpack: the same folder
make_batch "$D"
before=$(manifest "$D")
( batch_pack "$D" "$A" tag ) >/dev/null 2>&1
check "pack: state packed" [ "$(state_get "$D")" = packed ]
check "pack: archive written, no .part left" bash -c "[ -s '$A' ] && [ ! -e '$A.part' ]"
check "pack: the packed items are gone" bash -c "[ -z \"\$(cd '$D' && ls -A | grep -vE '^(meta|logs|out)$')\" ]"
check "pack: out/ still reads its result (hard link)" [ "$(cat "$D/out/sub-1/vol.csv")" = result ]
check "pack: the Nextflow log is kept in logs/" bash -c "ls '$D'/logs/.nextflow.log.* >/dev/null"
( batch_unpack "$D" "$A" ) >/dev/null 2>&1
check "unpack: state unpacked" [ "$(state_get "$D")" = unpacked ]
check "unpack: identical to the folder before packing (paths, types, sizes, links, contents)" \
    [ "$(manifest "$D")" = "$before" ]
check "unpack: the archive is kept" [ -s "$A" ]

# 2. unpack of an unpacked folder does nothing; pack of a packed folder does nothing
echo extra > "$D/work/ab/123/new.txt"
( batch_unpack "$D" "$A" ) >/dev/null 2>&1
check "unpack of an unpacked folder keeps its newer files" [ -e "$D/work/ab/123/new.txt" ]
rm "$D/work/ab/123/new.txt"
( batch_pack "$D" "$A" tag ) >/dev/null 2>&1
cp "$A" "$T/archive_ref.tar"
( batch_pack "$D" "$A" tag ) >/dev/null 2>&1
check "pack of a packed folder leaves the archive alone" cmp -s "$A" "$T/archive_ref.tar"

# 3. killed while writing the archive: .part left, state still unpacked. The folder is the truth.
( batch_unpack "$D" "$A" ) >/dev/null 2>&1
echo newer > "$D/work/ab/123/newer.txt"
before=$(manifest "$D")
echo garbage > "$A.part"
( batch_pack "$D" "$A" tag ) >/dev/null 2>&1
( batch_unpack "$D" "$A" ) >/dev/null 2>&1
check "killed while writing: the next pack replaces the .part, nothing lost" [ "$(manifest "$D")" = "$before" ]

# 4. killed while deleting the items (state packing, some items left): the next unpack finishes the
#    deletion and extracts the verified archive
( batch_pack "$D" "$A" tag ) >/dev/null 2>&1
mkdir -p "$D/work/ab"; echo leftover > "$D/work/ab/half_deleted"
state_set "$D" packing
( batch_unpack "$D" "$A" ) >/dev/null 2>&1
check "killed while deleting: unpack gives the archived folder back, no leftover" \
    bash -c "[ \"\$(state_get '$D' 2>/dev/null; cat '$D/meta/state')\" ] && [ ! -e '$D/work/ab/half_deleted' ]"
check "killed while deleting: contents identical" [ "$(manifest "$D")" = "$before" ]

# 5. killed while extracting (state packed, partial items): extracted again from scratch
( batch_pack "$D" "$A" tag ) >/dev/null 2>&1
mkdir -p "$D/work/zz"; echo partial > "$D/work/zz/partial"
( batch_unpack "$D" "$A" ) >/dev/null 2>&1
check "killed while extracting: partial files discarded, contents identical" \
    bash -c "[ ! -e '$D/work/zz/partial' ]"
check "killed while extracting: contents identical" [ "$(manifest "$D")" = "$before" ]

# 6. packed but the archive is missing: refused, nothing deleted
( batch_pack "$D" "$A" tag ) >/dev/null 2>&1
mv "$A" "$A.away"
( batch_unpack "$D" "$A" ) >/dev/null 2>&1 && fail "unpack without archive refused" || ok "unpack without archive refused"
mv "$A.away" "$A"

# 7. an unknown state is refused
state_set "$D" weird
( batch_unpack "$D" "$A" ) >/dev/null 2>&1 && fail "unknown state refused" || ok "unknown state refused"
state_set "$D" packed

# 8. locks: a second job is refused while the first holds the lock; a dead holder's lock is taken
sleep 30 & holder=$!
mkdir -p "$D/meta/lock"; echo "$holder" > "$D/meta/lock/job"
( SLURM_JOB_ID=999999 batch_lock "$D" ) >/dev/null 2>&1 && fail "a live lock refuses a second job" || ok "a live lock refuses a second job"
check "the refused job leaves the holder's lock" [ "$(cat "$D/meta/lock/job")" = "$holder" ]
kill "$holder"; wait "$holder" 2>/dev/null
( SLURM_JOB_ID=$$ batch_lock "$D" ) >/dev/null 2>&1 && ok "a dead holder's lock is taken over" || fail "a dead holder's lock is taken over"
check "the new holder is recorded" [ "$(cat "$D/meta/lock/job")" = "$$" ]
( SLURM_JOB_ID=$$ batch_unlock "$D" )
check "unlock removes only its own lock" [ ! -e "$D/meta/lock" ]
mkdir -p "$D/meta/lock"; echo 12345 > "$D/meta/lock/job"
( SLURM_JOB_ID=$$ batch_unlock "$D" )
check "unlock leaves another job's lock" [ -e "$D/meta/lock" ]
rm -rf "$D/meta/lock"

# 9. two jobs racing for the lock: exactly one gets it
results=$T/race; mkdir -p "$results"
for i in 1 2 3 4 5 6; do
    ( sleep 0.$((RANDOM % 3)); SLURM_JOB_ID=$BASHPID
      if batch_lock "$D" >/dev/null 2>&1; then echo got > "$results/$i"; sleep 2; fi ) &
done
wait
check "racing jobs: exactly one holds the lock" [ "$(ls "$results" | wc -l)" = 1 ]
rm -rf "$D/meta/lock"

# 10. racing jobs taking over the same stale lock (dead holder): still exactly one holds it
results=$T/race_stale; mkdir -p "$results"
mkdir -p "$D/meta/lock"; echo 2147483000 > "$D/meta/lock/job"   # a process id that does not exist
for i in 1 2 3 4 5 6; do
    ( SLURM_JOB_ID=$BASHPID
      if batch_lock "$D" >/dev/null 2>&1; then echo got > "$results/$i"; sleep 6; fi ) &
done
wait
check "racing take-over of a stale lock: exactly one holds it" [ "$(ls "$results" | wc -l)" = 1 ]

echo
[ "$failures" = 0 ] && echo "all batch tests passed" || { echo "$failures failure(s)"; exit 1; }
