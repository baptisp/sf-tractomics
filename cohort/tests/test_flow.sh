#!/bin/bash
# End-to-end test of a batch job (scripts/batch_job.sbatch) without a cluster or the pipeline: a fake
# nextflow records how it was called and writes a history line and a trace like the real one; a
# fake pipeline repository gives the commit. Checks the whole flow of two passes over a pack, and
# the refusals. Run: bash tests/test_flow.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PATH=$(echo "$PATH" | tr ':' '\n' | grep -v slurm | paste -sd:)
unset CC_CLUSTER

failures=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { local what=$1; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }

# A fake pipeline checkout with this folder inside it (cohort/), as in the fork; a fake Nextflow
P=$T/pipe
R=$P/cohort
mkdir -p "$R"
cp -r "$REPO"/{scripts,params,configs} "$R/"
cp "$REPO/config.env" "$R/"
mkdir -p "$R/inputs" "$R/logs" "$R/meta" "$R/bin" "$R/work/atlas_iit" "$R/.atlas_cache/freesurfer"
printf 'participant_id\tsession\trun\tage\nsub-A\t1\t1\t70\nsub-A\t2\t1\t71\n' > "$R/inputs/participants.tsv"
B=$T/bids
mkdir -p "$B/sub-A/ses-1/anat" "$B/sub-A/ses-2/anat"
echo '{}' > "$B/dataset_description.json"
echo t1 > "$B/sub-A/ses-1/anat/T1w.nii.gz"; echo t1b > "$B/sub-A/ses-2/anat/T1w.nii.gz"
sed -i "s|^    vitaltour) INPUT_BIDS=.*|    vitaltour) INPUT_BIDS=\"$B\" ;;|" "$R/config.env"
echo b0 > "$R/work/atlas_iit/IITmean_b0.nii.gz"; echo b0 > "$R/.atlas_cache/freesurfer/IITmean_b0.nii.gz"
echo licence > "$R/license_freesurfer.txt"
gitc() { git -C "$P" -c user.name=t -c user.email=t@t "$@"; }
git init -q "$P" && echo "workflow v1" > "$P/main.nf" && gitc add main.nf && gitc commit -qm one
cat > "$R/bin/nextflow" <<'EOF'
#!/bin/bash
# fake nextflow: records its arguments; history line (run name, session); trace; one task output
echo "$*" >> "$FAKE_CALLS"
name= session= trace= params=
while [ $# -gt 0 ]; do
    case "$1" in
        -name) name=$2; shift ;;
        -resume) session=$2; shift ;;
        -with-trace) trace=$2; shift ;;
        -params-file) params=$2; shift ;;
    esac
    shift
done
[ -n "$session" ] || session=$(cat /proc/sys/kernel/random/uuid)
mkdir -p .nextflow work/aa out
printf '2026-11-05\t1s\t%s\tOK\tabc\t%s\tnextflow run\n' "$name" "$session" >> .nextflow/history
printf 'task_id\thash\tname\tstatus\texit\n' > "$trace"
if grep -q run_roi_metrics "$params"; then
    printf '1\taa\tVOLUMES (sub-A)\t%s\n2\tbb\tMETRICS (sub-A)\tCOMPLETED\n' "${FAKE_VOLUMES_STATUS:-CACHED}" >> "$trace"
else
    printf '1\taa\tVOLUMES (sub-A)\tCOMPLETED\n' >> "$trace"
fi
# FAKE_FAIL=n: the brain extraction of sessions 1..n fails for good (errorStrategy 'ignore')
for s in $(seq 1 "${FAKE_FAIL:-0}"); do
    mkdir -p "work/f$s/0123456789"
    echo "bet sub-A_ses-${s}__image_n4.nii.gz" > "work/f$s/0123456789/.command.sh"
    printf 'antsAI\nSegmentation fault (core dumped)\n' > "work/f$s/0123456789/.command.err"
    printf '%s\tf%s/012345\tPREPROC_T1:BETCROP_ANTSBET (sub-A)\tFAILED\t1\n' "$((10 + s))" "$s" >> "$trace"
done
echo "$name" > work/aa/out.txt
mkdir -p out/metrics && ln -f work/aa/out.txt out/metrics/volumes.tsv
exit "${FAKE_RC:-0}"
EOF
chmod +x "$R/bin/nextflow"
export FAKE_CALLS=$T/calls
printf 'b0001\tsub-A\n' > /dev/null
(cd "$R" && python3 scripts/make_batches.py 10 >/dev/null)

job() {   # job PASS JOBID: one batch task, as Slurm would start it
    ( cd "$R" && SLURM_SUBMIT_DIR=$R SLURM_ARRAY_TASK_ID=1 SLURM_JOB_ID=$2 SFT_PASS=$1 \
        SFT_LIST=$T/list BATCH=true bash scripts/batch_job.sbatch ) > "$T/job_$2.log" 2>&1
}
echo b0001 > "$T/list"
D=$R/batches/b0001

# Pass 2 before pass 1: refused, but the batch is still prepared and packed
job 2_metrics 101; rc=$?
check "pass 2 before pass 1 is refused" [ "$rc" != 0 ]
check "refused pass: nextflow never called" [ ! -e "$FAKE_CALLS" ]
check "refused pass: the batch is packed anyway" [ "$(cat "$D/meta/state")" = packed ]

# Pass 1: prepared (inputs, atlases), run, recorded, packed
job 1_volumes 102; rc=$?
check "pass 1 succeeds" [ "$rc" = 0 ]
check "pass 1: a new session (no -resume)" bash -c "! grep -q -- '-resume' '$FAKE_CALLS'"
check "pass 1: recorded as done" grep -qx 1_volumes "$D/meta/passes_done"
check "pass 1: session recorded" [ -s "$D/meta/session_id" ]
check "pass 1: packed" bash -c "[ \"\$(cat '$D/meta/state')\" = packed ] && [ ! -e '$D/work' ] && [ -s '$R/archives/b0001.tar' ]"
check "pass 1: results packed (out/ in the archive, tables in extracted_results.tar.gz)" \
    bash -c "[ ! -e '$D/out' ] && tar -tf '$R/archives/b0001.tar' | grep -qx out/metrics/volumes.tsv && tar -tzf '$D/extracted_results.tar.gz' | grep -qx metrics/volumes.tsv"
check "pass 1: inputs checksummed" grep -q "data_bids/sub-A/ses-2/anat/T1w.nii.gz" "$D/meta/inputs.sha256"
check "pass 1: publish as hard links in batch mode" grep -qx "publish_dir_mode: link" "$D/meta/params_1_volumes.yaml"
session=$(cat "$D/meta/session_id")

# Pass 2: unpacked, resumes pass 1's session, every task of pass 1 reused, packed again
job 2_metrics 103; rc=$?
check "pass 2 succeeds" [ "$rc" = 0 ]
check "pass 2 resumes the session of pass 1" grep -q -- "-resume $session" "$FAKE_CALLS"
check "pass 2: its parameters include pass 1's" bash -c "grep -q run_gm_volumes '$D/meta/params_2_metrics.yaml' && grep -q run_roi_metrics '$D/meta/params_2_metrics.yaml'"
check "pass 2: reuse report says nothing of pass 1 was computed again" grep -q "1 tasks of run 1 reused, 0 computed again" "$D"/logs/reuse_2_metrics_103.txt
check "pass 2: packed again" [ "$(cat "$D/meta/state")" = packed ]
check "pass 2: the work of pass 1 is still in the archive" bash -c "tar -tf '$R/archives/b0001.tar' | grep -q work/aa/out.txt"

# A pass that recomputes a task of pass 1 is reported
FAKE_VOLUMES_STATUS=COMPLETED job 2_metrics 104
check "a task of pass 1 computed again is reported" grep -q "computed again: VOLUMES (sub-A)" "$D"/logs/reuse_2_metrics_104.txt

# A commit that changes only cohort/ is not another pipeline: accepted
echo "# note" >> "$R/README.md" && gitc add cohort/README.md && gitc commit -qm "wrapper only"
job 2_metrics 108; rc=$?
check "a commit of cohort/ only is not another pipeline version" [ "$rc" = 0 ]

# An uncommitted change of a pipeline file: refused
echo "edited" >> "$P/main.nf"
job 2_metrics 109; rc=$?
check "an uncommitted pipeline change is refused" bash -c "[ $rc != 0 ] && grep -q 'uncommitted changes' '$T/job_109.log'"
git -C "$P" checkout -q main.nf

# Another pipeline commit: refused (ALLOW_COMMIT_CHANGE=1 to override)
echo "workflow v2" > "$P/main.nf" && gitc commit -qam two
job 2_metrics 105; rc=$?
check "another pipeline commit is refused" bash -c "[ $rc != 0 ] && grep -q 'ran with pipeline commit' '$T/job_105.log'"
check "refused commit: packed anyway" [ "$(cat "$D/meta/state")" = packed ]
# Accepted with ALLOW_COMMIT_CHANGE=1: the new commit becomes the pin, the old one in the history
old_pin=$(cat "$D/meta/pipeline_commit")
ALLOW_COMMIT_CHANGE=1 job 2_metrics 110; rc=$?
check "an accepted commit change runs" [ "$rc" = 0 ]
check "an accepted commit change becomes the pin" [ "$(cat "$D/meta/pipeline_commit")" = "$(git -C "$P" log -1 --format=%H)" ]
check "an accepted commit change is kept in the history" grep -q "$old_pin -> " "$D/meta/pipeline_commit_history"
job 2_metrics 111; rc=$?
check "after an accepted change, the next run needs no override" [ "$rc" = 0 ]
gitc reset -q --hard HEAD~1
echo "$old_pin" > "$D/meta/pipeline_commit"

# Inputs changed after preparation: refused
tar -xf "$R/archives/b0001.tar" -C "$T" data_bids/participants.tsv
job_inputs_changed() {
    ( cd "$D" && tar -xf "$R/archives/b0001.tar" && echo changed >> data_bids/participants.tsv \
      && tar -cf "$R/archives/b0001.tar" .nextflow work .atlas_cache data_bids && rm -rf .nextflow work .atlas_cache data_bids )
    job 2_metrics 106
}
job_inputs_changed; rc=$?
check "changed inputs are refused" bash -c "[ $rc != 0 ] && grep -q 'changed since it was prepared' '$T/job_106.log'"

# A failed run is packed too, and not recorded as done
( cd "$D" && tar -xf "$R/archives/b0001.tar" && cp "$T/data_bids/participants.tsv" data_bids/participants.tsv \
  && tar -cf "$R/archives/b0001.tar" .nextflow work .atlas_cache data_bids && rm -rf .nextflow work .atlas_cache data_bids )
sed -i '/^2_metrics$/d' "$D/meta/passes_done"
FAKE_RC=1 job 2_metrics 107; rc=$?
check "a failed run returns its status" [ "$rc" != 0 ]
check "a failed run is packed" [ "$(cat "$D/meta/state")" = packed ]
check "a failed run is not recorded as done" bash -c "! grep -qx 2_metrics '$D/meta/passes_done'"
check "the lock is released after every job" [ ! -e "$D/meta/lock" ]

# A failed session no longer fails the pass: listed in out/metrics/failed_tasks.tsv, the pass done.
# Every run failed (more than MAX_FAILED_FRACTION): a bug, the pass not done.
FAKE_FAIL=2 job 2_metrics 120; rc=$?
check "failures: every run failed fails the pass" bash -c "[ $rc != 0 ] && ! grep -qx 2_metrics '$D/meta/passes_done' && grep -q 'not marked done' '$T/job_120.log'"
FAKE_FAIL=1 job 2_metrics 121; rc=$?
check "failures: one failed run of two, the pass is done" bash -c "[ $rc = 0 ] && grep -qx 2_metrics '$D/meta/passes_done' && grep -q '1 task(s) failed, 1 of 2 run(s), 1 session(s)' '$T/job_121.log'"
tar -xzf "$D/extracted_results.tar.gz" -C "$T" metrics/failed_tasks.tsv 2>/dev/null
check "failures: the table lists the session and its error, in the extracted results" \
    bash -c "[ \$(wc -l < '$T/metrics/failed_tasks.tsv') = 2 ] && grep -qP '^b0001\t2_metrics\tsft-2-metrics-121\tsub-A\t1\t\tBETCROP_ANTSBET\t1\t1\tSegmentation fault \\(core dumped\\)\twork/f1/0123456789$' '$T/metrics/failed_tasks.tsv'"
check "failures: a copy of the table in logs/" [ -s "$D/logs/failed_tasks_2_metrics_121.tsv" ]
check "failures: the table is in the archive" bash -c "tar -tf '$R/archives/b0001.tar' | grep -qx out/metrics/failed_tasks.tsv"

# Every pass done: the archive leaves scratch for ARCHIVE_STORE, with its extracted results and
# meta/; a later run unpacks from the store and stores the new archive over the old one
S=$T/store
ARCHIVE_STORE=$S job 2_metrics 112; rc=$?
check "store: the run that finishes every pass succeeds" [ "$rc" = 0 ]
check "store: archive, extracted results and meta/ in the store" \
    bash -c "[ -s '$S/b0001.tar' ] && [ -s '$S/b0001_extracted_results.tar.gz' ] && tar -tf '$S/b0001_meta.tar' | grep -qx meta/passes_done"
check "store: the scratch archive is gone, no .part left" bash -c "[ ! -e '$R/archives/b0001.tar' ] && ! ls '$S'/*.part >/dev/null 2>&1"
cp "$S/b0001.tar" "$T/stored_before.tar"
FORCE=1 ARCHIVE_STORE=$S job 2_metrics 113; rc=$?
check "store: a later run unpacks from the store" bash -c "[ $rc = 0 ] && grep -q 'unpacked from $S/b0001.tar' '$T/job_113.log'"
check "store: the new archive replaces the stored one" bash -c "! cmp -s '$S/b0001.tar' '$T/stored_before.tar' && tar -tf '$S/b0001.tar' | grep -q work/aa/out.txt && [ ! -e '$R/archives/b0001.tar' ]"
X=$T/x; ( cd "$R" && ARCHIVE_STORE=$S scripts/extract_results.sh b0001 "$X" 'out/metrics/*' ) >/dev/null 2>&1
check "store: extract_results.sh reads a stored archive" [ -s "$X/out/metrics/volumes.tsv" ]
mkdir -p "$T/nostore"; chmod 500 "$T/nostore"
ARCHIVE_STORE=$T/nostore/sub job 2_metrics 114; rc=$?
check "store: an unwritable store keeps the scratch archive" bash -c "[ $rc = 0 ] && [ -s '$R/archives/b0001.tar' ] && grep -q 'cannot be created\|copy of' '$T/job_114.log'"
chmod 700 "$T/nostore"

echo
[ "$failures" = 0 ] && echo "all flow tests passed" || { echo "$failures failure(s)"; for f in "$T"/job_*.log; do echo "== $f"; tail -5 "$f"; done; exit 1; }
