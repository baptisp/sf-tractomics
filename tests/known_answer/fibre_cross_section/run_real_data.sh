#!/bin/bash
# Fibre cross-section on real sessions with a known effect (see real_data.nf).
# Usage: run_real_data.sh SESSIONS_TSV OUTDIR SCALED_LABELS   (e.g. "sub-OAS30001,sub-OAS30098")
# SESSIONS_TSV columns: label, fodf, mask, b0, dwi, bval, bvec (TractoFlow outputs of the pipeline).
# Then: python3 check_real_data.py OUTDIR/fc_stats.csv 1.05,0.95
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
sessions=$(realpath "$1"); outdir=$(realpath -m "$2"); scaled=$3
mkdir -p "$outdir"
cd "$outdir"
NXF_VER=${NXF_VER:-26.04.4} nextflow run "$here/real_data.nf" -profile docker \
    -c "$repo/nextflow.config" -c "$here/real_data.config" \
    --sessions "$sessions" --outdir "$outdir" --scaled_sessions "$scaled" -resume
