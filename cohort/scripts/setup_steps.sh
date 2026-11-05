#!/bin/bash
# Setup steps: inside the setup job on a cluster (scripts/setup.sbatch), directly on vitalTour.
# Safe to repeat: each step is skipped when its result is already there.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
BATCH=$(cat meta/mode)
export BATCH
source scripts/lib.sh
log "setup on $(hostname)${SLURM_JOB_ID:+, job $SLURM_JOB_ID}, BATCH=$BATCH"

for url in https://get.nextflow.io https://registry-1.docker.io/v2/ https://www.nitrc.org; do
    curl -s -o /dev/null -m 30 "$url" || die "no internet from $(hostname) ($url): download elsewhere and copy here"
done

# Pipeline: the checkout this folder sits in, without uncommitted changes
log "pipeline: $SFT_PIPELINE at $(pipeline_version) ($(git -C "$SFT_PIPELINE" rev-parse --abbrev-ref HEAD))"

# Nextflow launcher and its jars at NXF_VER, in this folder
if [ ! -x bin/nextflow ]; then
    mkdir -p bin
    (cd bin && curl -fsSL https://get.nextflow.io | bash) > logs/setup_nextflow.log 2>&1
fi
bin/nextflow -version | grep -q "$NXF_VER" || die "Nextflow $NXF_VER not installed"

# Images (clusters: Apptainer files under the names the tasks look up, e.g. docker.io/scilus/scilus:2.2.2
# -> docker.io-scilus-scilus-2.2.2.img; vitalTour: Docker pulls them itself). One at a time, the
# conversion pinned to the job's cores: mksquashfs starts one thread per CPU it sees.
IMAGES="scilus/scilus:2.2.2 scilus/scilpy:2.2.2_cpu mrtrix3/mrtrix3:3.0.5 freesurfer/freesurfer:7.4.1
        community.wave.seqera.io/library/nibabel_numpy:4148b92a8cbc6976 gagnonanthony/multiqc-neuroimaging:0.1.1"
if [ "$MACHINE" != vitaltour ]; then
    mkdir -p containers
    for image in $IMAGES; do
        [[ "${image%%/*}" == *.* ]] || image="docker.io/$image"
        file="containers/$(echo "$image" | tr '/:' '--').img"
        [ -s "$file" ] && continue
        log "pulling $image"
        rm -f "$file.part"
        taskset -c "$(taskset -cp $$ | awk '{ print $NF }')" \
            apptainer pull --name "$file.part" "docker://$image" >> logs/setup_pull_images.log 2>&1 \
            || die "pull of $image failed: logs/setup_pull_images.log"
        mv "$file.part" "$file"
    done
    log "images: $(ls containers | tr '\n' ' ')"
fi

# Inputs. Without batches: every session, in data_bids/ of this folder (once; checksums kept).
# With batches: each batch copies its own subjects when it first runs; the preview below uses a
# copy of the first subject only, removed afterwards.
mapfile -t subjects < <(awk -F'\t' 'NR > 1 { print $1 }' inputs/participants.tsv | awk '!seen[$0]++')
[ "${#subjects[@]}" -gt 0 ] || die "inputs/participants.tsv lists no subject"
if [ "$BATCH" = true ]; then
    preview_dir="$SFT_ROOT/.preview"
    copy_inputs "$preview_dir" "${subjects[0]}"
else
    preview_dir="$SFT_ROOT"
    if [ -s meta/inputs.sha256 ]; then
        sha256sum --quiet -c meta/inputs.sha256 || die "data_bids/ changed since it was copied"
    else
        copy_inputs "$SFT_ROOT" "${subjects[@]}"
    fi
fi

# Parameters of every pass validated and the workflow built, no task run. Launched here, the
# workflow script downloads the atlases into work/atlas_iit and .atlas_cache/ (where batches take
# their hard links from), and Nextflow fetches its nf-schema plugin.
for pass in $(pass_list); do
    python3 scripts/passes.py resolve "$pass" "meta/params_preview_${pass}.yaml" \
        --set "participants_tsv=$preview_dir/data_bids/participants.tsv" --set "freesurfer_license=$FS_LICENSE"
    bin/nextflow run "$SFT_PIPELINE" -preview -name "preview-${pass//_/-}-$(date +%Y%m%d%H%M%S)" \
        -profile "$SFT_PROFILE" -c "$SFT_CONFIG" -params-file "meta/params_preview_${pass}.yaml" \
        --input "$preview_dir/data_bids" --outdir out -w work -ansi-log false \
        > "logs/setup_preview_${pass}.log" 2>&1 || die "preview of pass $pass failed: logs/setup_preview_${pass}.log"
    grep -hE "WARN|ERROR" "logs/setup_preview_${pass}.log" | grep -vE "Unrecognized config option|is available" || true
done
[ "$BATCH" = true ] && rm -rf "$preview_dir"
[ -s work/atlas_iit/IITmean_b0.nii.gz ] && [ -s .atlas_cache/freesurfer/IITmean_b0.nii.gz ] \
    || die "the atlases were not downloaded (work/atlas_iit, .atlas_cache/freesurfer)"

touch meta/setup_done
log "setup done; scratch: $(diskusage_report 2>/dev/null | grep -i scratch || echo 'diskusage_report unavailable')"
