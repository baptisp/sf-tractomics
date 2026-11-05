#!/bin/bash
# Setup job, submitted by ./run.sh setup on a cluster: every download and copy runs here rather
# than on the login node (scripts/setup_steps.sh). Needs internet from the compute node, and stops at
# once with a clear message when there is none.
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=04:00:00
#SBATCH --tmp=100G
set -euo pipefail
cd "${SLURM_SUBMIT_DIR:?}"
exec scripts/setup_steps.sh
