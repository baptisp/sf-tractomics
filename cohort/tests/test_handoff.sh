#!/bin/bash
# Tests of moving batches between machines (./run.sh handoff, adopt, and the owner check of the batch
# job), without a cluster or the pipeline: two cohort folders A and B in one fake pipeline checkout
# stand for the same cohort on two clusters (MACHINE mA and mB), with the fake Nextflow of
# test_flow.sh. A batch runs pass 1 on A, moves to B and resumes there, comes back to A, and a never
# prepared batch moves with its input tar. Every refusal leaves both sides unchanged.
# Run: bash tests/test_handoff.sh
set -uo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PATH=$(echo "$PATH" | tr ':' '\n' | grep -v slurm | paste -sd:)
unset CC_CLUSTER
# env.sh loads modules on a cluster machine: a stub, and no BASH_ENV (on Alliance it re-initialises
# Lmod in every shell, replacing the stub)
unset BASH_ENV ENV
module() { :; }
export -f module

failures=0
ok()   { echo "ok    $*"; }
fail() { echo "FAIL  $*"; failures=$((failures + 1)); }
check() { local what=$1; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }

P=$T/pipe
B=$T/bids
mkdir -p "$B/sub-A/ses-1/anat" "$B/sub-A/ses-2/anat" "$B/sub-B/ses-1/anat"
echo '{}' > "$B/dataset_description.json"
echo t1 > "$B/sub-A/ses-1/anat/T1w.nii.gz"; echo t1b > "$B/sub-A/ses-2/anat/T1w.nii.gz"
echo t1c > "$B/sub-B/ses-1/anat/T1w.nii.gz"
gitc() { git -C "$P" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$P"
git init -q "$P" && echo "workflow v1" > "$P/main.nf" && gitc add main.nf && gitc commit -qm one

# make_root DIR MACHINE: a cohort folder (untracked, so both give the same pipeline commit)
make_root() {
    local R=$1 m=$2
    mkdir -p "$R"
    cp -r "$REPO"/{scripts,params,configs,run.sh} "$R/"
    cp "$REPO/config.env" "$R/"
    sed -i -e "s|^MACHINE=.*|MACHINE=\"$m\"|" -e 's|^HOME_CLUSTER=.*|HOME_CLUSTER="mA"|' "$R/config.env"
    mkdir -p "$R/inputs" "$R/logs" "$R/meta" "$R/bin" "$R/work/atlas_iit" "$R/.atlas_cache/freesurfer"
    printf 'participant_id\tsession\trun\tage\nsub-A\t1\t1\t70\nsub-A\t2\t1\t71\nsub-B\t1\t1\t60\n' > "$R/inputs/participants.tsv"
    echo b0 > "$R/work/atlas_iit/IITmean_b0.nii.gz"; echo b0 > "$R/.atlas_cache/freesurfer/IITmean_b0.nii.gz"
    echo licence > "$R/license_freesurfer.txt"
    cat > "$R/bin/nextflow" <<'EOF'
#!/bin/bash
# fake nextflow: records its arguments; a history line (run name, session); a trace; one output
echo "$PWD $*" >> "$FAKE_CALLS"
name= session= trace=
while [ $# -gt 0 ]; do
    case "$1" in
        -name) name=$2; shift ;;
        -resume) session=$2; shift ;;
        -with-trace) trace=$2; shift ;;
    esac
    shift
done
[ -n "$session" ] || session=$(cat /proc/sys/kernel/random/uuid)
mkdir -p .nextflow work/aa out
printf '2026-11-05\t1s\t%s\tOK\tabc\t%s\tnextflow run\n' "$name" "$session" >> .nextflow/history
printf 'task_id\thash\tname\tstatus\texit\n1\taa\tVOLUMES (sub-A)\tCOMPLETED\n' > "$trace"
echo "$name" >> work/aa/out.txt
mkdir -p out/metrics && ln -f work/aa/out.txt out/metrics/volumes.tsv
EOF
    chmod +x "$R/bin/nextflow"
    (cd "$R" && python3 scripts/make_batches.py 2 >/dev/null)
}
A=$P/cohort
Bm=$P/cohort_b
make_root "$A" mA
make_root "$Bm" mB
mkdir -p "$A/inputs_transfer" && ln -s "$B" "$A/inputs_transfer/ADNI_BIDS"   # mA reads the BIDS folder
export FAKE_CALLS=$T/calls

job() {   # job ROOT PASS JOBID BATCH: one batch task, as Slurm would start it
    echo "$4" > "$T/list_$3"
    ( cd "$1" && SLURM_SUBMIT_DIR=$1 SLURM_ARRAY_TASK_ID=1 SLURM_JOB_ID=$3 SFT_PASS=$2 \
        SFT_LIST=$T/list_$3 BATCH=true bash scripts/batch_job.sbatch ) > "$T/job_$3.log" 2>&1
}
run() {   # run ROOT ARGS...: ./run.sh in that folder
    ( cd "$1" && shift && ./run.sh --batch "$@" ) > "$T/run.log" 2>&1
}
owner() { cat "$1/meta/owner" 2>/dev/null || echo "(none)"; }

check "two batches" [ "$(cut -f1 "$A/batches/list.tsv" | uniq | tr '\n' ' ')" = "b0001 b0002 " ]

# A runs pass 1 of b0001: no owner recorded, so HOME_CLUSTER (mA)
job "$A" 1_volumes 101 b0001; rc=$?
check "home machine runs a batch with no owner recorded" [ "$rc" = 0 ]
session=$(cat "$A/batches/b0001/meta/session_id")

# The other machine does not run it
job "$Bm" 1_volumes 102 b0001; rc=$?
check "another machine refuses a batch it does not own" bash -c "[ $rc != 0 ] && grep -q 'belongs to mA, not mB' '$T/job_102.log'"
check "the refused job left nothing there" [ ! -e "$Bm/batches/b0001" ]

# Handoff refusals: unpacked, unknown, locked, someone else's
mkdir -p "$A/batches/b0001/meta/lock"
run "$A" handoff mB b0001; rc=$?
check "handoff refuses a locked batch" bash -c "[ $rc != 0 ] && grep -q 'locked' '$T/run.log'"
rmdir "$A/batches/b0001/meta/lock"
run "$A" handoff mB b0099; rc=$?
check "handoff refuses a batch not in the list" [ "$rc" != 0 ]
run "$A" handoff mA b0001; rc=$?
check "handoff refuses this machine as destination" [ "$rc" != 0 ]
check "refused handoffs changed nothing" bash -c "[ \"\$(cat '$A/batches/b0001/meta/owner' 2>/dev/null)\" = '' ] && [ ! -d '$A/transfers' ]"

# Handoff of b0001 (packed) and b0002 (never prepared, with an input tar)
mkdir -p "$A/inputs/batch_tars" "$T/b2" && cp -r "$B/sub-B" "$B/dataset_description.json" "$T/b2/"
tar -cf "$A/inputs/batch_tars/b0002.tar" -C "$T/b2" .
run "$A" handoff mB b0001 b0002; rc=$?
S=$(ls -d "$A"/transfers/*_mA_to_mB 2>/dev/null | head -1)
check "handoff succeeds" bash -c "[ $rc = 0 ] && [ -n '$S' ]"
check "handoff: both batches in transit" bash -c "[ \"\$(cat '$A/batches/b0001/meta/owner')\" = transit:mB ] && [ \"\$(cat '$A/batches/b0002/meta/owner')\" = transit:mB ]"
check "handoff: the archive is staged as a hard link (no copy)" \
    [ "$(stat -c %i "$S/archives/b0001.tar")" = "$(stat -c %i "$A/archives/b0001.tar")" ]
check "handoff: the input tar is staged" [ "$(stat -c %i "$S/inputs/batch_tars/b0002.tar")" = "$(stat -c %i "$A/inputs/batch_tars/b0002.tar")" ]
check "handoff: the batch folders are staged" bash -c "[ -s '$S/batches/b0001/meta/session_id' ] && [ \"\$(cat '$S/batches/b0002/meta/owner')\" = transit:mB ]"
check "handoff: the manifest lists both" bash -c "grep -qP '^b0001\tpacked\t[0-9]+\t-$' '$S/manifest.tsv' && grep -qP '^b0002\tnew\t-\t[0-9]+$' '$S/manifest.tsv'"
job "$A" 1_volumes 103 b0001; rc=$?
check "a batch in transit runs nowhere (not on the machine it left)" bash -c "[ $rc != 0 ] && grep -q 'belongs to transit:mB' '$T/job_103.log'"
run "$A" handoff mB b0001; rc=$?
check "a batch in transit cannot be handed off again" [ "$rc" != 0 ]

# Adopt refusals: nothing copied yet, an incomplete archive, a cohort file that differs, the wrong machine
rel=${S#"$A"/}
run "$Bm" adopt "$rel"; rc=$?
check "adopt refuses before the copy" [ "$rc" != 0 ]
mkdir -p "$Bm/transfers" && cp -a "$S" "$Bm/transfers/"
truncate -s 10 "$Bm/$rel/archives/b0001.tar"
run "$Bm" adopt "$rel"; rc=$?
check "adopt refuses an incomplete archive" bash -c "[ $rc != 0 ] && grep -q 'incomplete' '$T/run.log'"
cp "$S/archives/b0001.tar" "$Bm/$rel/archives/b0001.tar"
echo "# other" >> "$Bm/params/passes/1_volumes.yaml" 2>/dev/null || echo x >> "$(find "$Bm/params" -type f | head -1)"
run "$Bm" adopt "$rel"; rc=$?
check "adopt refuses when the cohort files differ" bash -c "[ $rc != 0 ] && grep -q 'cohort files differ' '$T/run.log'"
rm -rf "$Bm/params" && cp -r "$REPO/params" "$Bm/"
run "$A" adopt "$rel"; rc=$?
check "adopt refuses a handoff meant for another machine" [ "$rc" != 0 ]
check "refused adopts changed nothing" bash -c "[ ! -e '$Bm/batches/b0001' ] && [ ! -e '$Bm/archives/b0001.tar' ]"

# Adopt
run "$Bm" adopt "$rel"; rc=$?
check "adopt succeeds" [ "$rc" = 0 ]
check "adopt: the batches are this machine's" bash -c "[ \"\$(cat '$Bm/batches/b0001/meta/owner')\" = mB ] && [ \"\$(cat '$Bm/batches/b0002/meta/owner')\" = mB ]"
check "adopt: archive and input tar in place" bash -c "[ -s '$Bm/archives/b0001.tar' ] && [ -s '$Bm/inputs/batch_tars/b0002.tar' ]"
check "adopt: the history records the moves" bash -c "grep -c . '$Bm/batches/b0001/meta/owner_history' | grep -qx 2"

# The batch resumes on B with its session, and the never prepared one starts from its input tar
job "$Bm" 2_metrics 104 b0001; rc=$?
check "the adopted batch runs its next pass" [ "$rc" = 0 ]
check "the adopted batch resumes the session of pass 1" grep -q -- "-resume $session" "$FAKE_CALLS"
job "$Bm" 1_volumes 105 b0002; rc=$?
check "a never prepared batch starts from its input tar" bash -c "[ $rc = 0 ] && grep -q 'data_bids/sub-B/ses-1/anat/T1w.nii.gz' '$Bm/batches/b0002/meta/inputs.sha256'"

# Back to A: A's old copies are replaced and kept aside; the batch resumes the same session there
run "$Bm" handoff mA b0001; rc=$?
S2=$(ls -d "$Bm"/transfers/*_mB_to_mA | head -1); rel2=${S2#"$Bm"/}
check "handoff back succeeds" [ "$rc" = 0 ]
mkdir -p "$A/transfers" && cp -a "$S2" "$A/transfers/"
old_inode=$(stat -c %i "$A/archives/b0001.tar")
run "$A" adopt "$rel2"; rc=$?
check "adopt back succeeds" [ "$rc" = 0 ]
check "adopt back: the earlier archive is kept in replaced/" [ "$(stat -c %i "$A/$rel2/replaced/archives/b0001.tar")" = "$old_inode" ]
check "adopt back: the new archive holds the pass run on B" bash -c "tar -tf '$A/archives/b0001.tar' | grep -q work/aa/out.txt && grep -qx 2_metrics '$A/batches/b0001/meta/passes_done'"
FORCE=1 job "$A" 2_metrics 106 b0001; rc=$?
check "back on A, the batch resumes the same session" bash -c "[ $rc = 0 ] && [ \$(grep -c -- '-resume $session' '$FAKE_CALLS') = 2 ]"

# Adopt never overwrites a batch the machine runs
run "$Bm" handoff mA b0002; rc=$?
S3=$(ls -d "$Bm"/transfers/*_mB_to_mA | sort | tail -1); rel3=${S3#"$Bm"/}
mkdir -p "$A/transfers" && cp -a "$S3" "$A/transfers/"
echo mA > "$A/batches/b0002/meta/owner" 2>/dev/null || { mkdir -p "$A/batches/b0002/meta"; echo mA > "$A/batches/b0002/meta/owner"; }
run "$A" adopt "$rel3"; rc=$?
check "adopt refuses to overwrite a batch this machine owns" bash -c "[ $rc != 0 ] && grep -q 'would be overwritten' '$T/run.log'"

echo
[ "$failures" = 0 ] && echo "all handoff tests passed" || { echo "$failures failure(s)"; tail -5 "$T/run.log"; for f in "$T"/job_*.log; do echo "== $f"; tail -3 "$f"; done; exit 1; }
