#!/bin/bash
# Usage (in a Slurm job, not on a login node): scripts/extract_results.sh BATCH DEST PATTERN...
# Extracts the files of a packed batch matching PATTERN (globs on paths inside the archive, e.g.
# "out/sub-*/ses-*/anat/*_desc-thickness.csv") into DEST. A matching file stored as a hard link
# (archives packed with work/ before out/) brings its link target along, so it always extracts.
set -euo pipefail
export LC_ALL=C   # tar prints "link to" in English only
batch=${1:?usage: extract_results.sh BATCH DEST PATTERN...}; dest=$(realpath -m "${2:?}"); shift 2
[ $# -gt 0 ] || { echo "no PATTERN given" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
cd "${SFT_ROOT:-$here/..}"
export SFT_ROOT=$PWD
[ -e config.env ] && source config.env   # ARCHIVE_STORE
source "$here/lib.sh"
source "$here/batch.sh"
archive=$(archive_of "$batch")
[ -s "$archive" ] || { echo "$archive not found" >&2; exit 1; }
mkdir -p "$dest"
list=$(mktemp); trap 'rm -f "$list"' EXIT
tar -tvf "$archive" --wildcards "$@" | awk '{
    name = ""; for (i = 6; i <= NF; i++) name = name (i > 6 ? " " : "") $i
    if ($1 ~ /^h/) { split(name, p, " link to "); print p[1]; print p[2] } else print name }' | sort -u > "$list"
[ -s "$list" ] || { echo "nothing in $archive matches: $*" >&2; exit 1; }
tar -xf "$archive" -C "$dest" -T "$list"
echo "$(grep -c . "$list") entries of $archive in $dest"
