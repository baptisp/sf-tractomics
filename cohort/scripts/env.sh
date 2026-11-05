# Environment of every call (run.sh and the job scripts), sourced from the root folder: config.env,
# then on Alliance clusters the modules (Java for Nextflow, Apptainer for the tasks), and Nextflow's
# own files kept inside the root folder.
# BATCH given by the caller (a batch job, ./run.sh --batch) wins over config.env
batch_given=${BATCH:-}
set -a
source ./config.env
set +a
[ -n "$batch_given" ] && BATCH=$batch_given
unset batch_given
export SFT_ROOT="$PWD"
SFT_PIPELINE=$(cd .. && pwd)            # the sf-tractomics checkout this folder sits in
export SFT_PIPELINE
export SFT_ACCOUNT="$ACCOUNT"
# config.env's ACCOUNT is the only one: a default account in the login environment (e.g.
# SBATCH_ACCOUNT in ~/.bashrc) would override the --account Nextflow writes into each task script
unset SBATCH_ACCOUNT SALLOC_ACCOUNT SLURM_ACCOUNT
export NXF_HOME="$PWD/.nextflow_home"   # Nextflow jars and the nf-schema plugin (setup)
export NXF_OPTS="-Xms1g -Xmx6g"         # the head job has 8 GB
# No internet (config.env OFFLINE): Nextflow uses the jars and plugin of NXF_HOME, and the nf-core
# institutional configs, otherwise fetched from GitHub at every start, are skipped
if [ "${OFFLINE:-false}" = true ]; then
    export NXF_OFFLINE=true
fi

if [ "$MACHINE" = vitaltour ]; then
    SFT_PROFILE="docker,iit_tractometry"
    SFT_CONFIG="$PWD/configs/vitaltour.config"
else
    module load StdEnv/2023 java/21.0.1 apptainer >/dev/null 2>&1 || {
        echo "ERROR: module load StdEnv/2023 java/21.0.1 apptainer failed" >&2
        return 1
    }
    SFT_PROFILE="apptainer,slurm,iit_tractometry"
    SFT_CONFIG="$PWD/configs/alliance.config"
    export NXF_APPTAINER_CACHEDIR="$PWD/containers"  # images (setup)
    # Apptainer's cache and build space default to $HOME, whose quota a few images fill. In a job
    # they go to the node's local disk: converting one image unpacks it there (the scilus image is
    # over 100K files, which on scratch took most of the inode quota and ran slowly). Outside a job
    # nothing is pulled, but the variables still point away from $HOME.
    if [ -n "${SLURM_TMPDIR:-}" ]; then
        export APPTAINER_CACHEDIR="$SLURM_TMPDIR/apptainer/cache"
        export APPTAINER_TMPDIR="$SLURM_TMPDIR/apptainer/tmp"
    else
        export APPTAINER_CACHEDIR="$PWD/.apptainer/cache"
        export APPTAINER_TMPDIR="$PWD/.apptainer/tmp"
    fi
    mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"
fi
export SFT_PROFILE SFT_CONFIG
