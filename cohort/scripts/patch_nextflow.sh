#!/bin/bash
# patch_nextflow.sh: the Nextflow jar of NXF_HOME at NXF_VER, with nextflow_patch/HashBuilder.java
# compiled into it in place of Nextflow's own (README: "Moving batches between clusters").
#
# Why: with cache = 'lenient' a task's hash holds each input's path and size, and a directory's size
# is what the filesystem reports for the directory itself, not its content: Rorqual's Lustre reports
# 25600 for any folder, Fir's 4096. The first task takes data_bids/ (a folder) as input, so on Fir
# every hash differed and a batch from Rorqual was computed again from scratch. The patched class
# hashes a directory's size as 25600 on every machine: on Rorqual, where every folder reports that,
# the hashes are the ones the stock jar gave, so its caches stay valid, and Fir gives the same.
#
# Safe to repeat: a patched jar is left alone. The stock jar is kept next to it (.orig). Refused for
# any jar but the stock 26.04.4 one this source was taken from (sha256 below).
# Sourced by scripts/lib.sh; setup_steps.sh calls patch_nextflow, run_pass checks the jar.

NXF_PATCH_SOURCE_VER="26.04.4"
NXF_STOCK_JAR_SHA256="7bc999bc0c5a8f5fdcd3221113a3715cacebaf8f140c735562c5c9ad1b164e12"
NXF_PATCH_MARKER="DIR_HASH_SIZE"   # a field only the patched class has

nextflow_jar() { echo "$NXF_HOME/framework/$NXF_VER/nextflow-$NXF_VER-one.jar"; }

# nextflow_is_patched: 0 when the jar holds the patched HashBuilder
nextflow_is_patched() {
    unzip -p "$(nextflow_jar)" nextflow/util/HashBuilder.class 2>/dev/null | grep -qa "$NXF_PATCH_MARKER"
}

patch_nextflow() {
    local jar tmp
    jar=$(nextflow_jar)
    [ -s "$jar" ] || die "no Nextflow jar at $jar"
    if nextflow_is_patched; then
        log "Nextflow jar already patched (directory size in task hashes)"
        return 0
    fi
    [ "$NXF_VER" = "$NXF_PATCH_SOURCE_VER" ] \
        || die "nextflow_patch/HashBuilder.java is Nextflow $NXF_PATCH_SOURCE_VER's, NXF_VER is $NXF_VER: port the change first"
    [ "$(sha256sum "$jar" | cut -d' ' -f1)" = "$NXF_STOCK_JAR_SHA256" ] \
        || die "$jar is not the stock $NXF_VER jar the patch was made for"
    command -v javac > /dev/null || module load java/17 > /dev/null 2>&1 || true
    command -v javac > /dev/null || die "no javac to compile the Nextflow patch (module load java/17)"
    tmp=$(mktemp -d)
    javac -nowarn --release 17 -cp "$jar" -d "$tmp/classes" "$(dirname "${BASH_SOURCE[0]}")/../nextflow_patch/HashBuilder.java" 2>&1 \
        | grep -v '^Note:' >&2 || true
    [ -s "$tmp/classes/nextflow/util/HashBuilder.class" ] || die "the Nextflow patch did not compile"
    # jar uf refuses this jar (it has duplicate entries): copy every entry, the three classes replaced
    python3 - "$jar" "$tmp/patched.jar" "$tmp/classes" <<'PY' || die "the patched jar could not be written"
import sys, warnings, zipfile
warnings.simplefilter("ignore")
src, dst, classes = sys.argv[1:]
names = ["HashBuilder", "HashBuilder$1", "HashBuilder$2"]
new = {f"nextflow/util/{n}.class": open(f"{classes}/nextflow/util/{n}.class", "rb").read() for n in names}
seen = set()
with zipfile.ZipFile(src) as zi, zipfile.ZipFile(dst, "w") as zo:
    for info in zi.infolist():
        if info.filename in new:
            seen.add(info.filename)
            zo.writestr(info, new[info.filename])
        else:
            zo.writestr(info, zi.read(info))
assert seen == set(new), f"classes not found in the jar: {set(new) - seen}"
PY
    cp -p "$jar" "$jar.orig"
    chmod --reference="$jar" "$tmp/patched.jar"
    mv "$tmp/patched.jar" "$jar"
    rm -rf "$tmp"
    nextflow_is_patched || die "the jar is still not patched"
    log "Nextflow jar patched: a directory's size is hashed as 25600 (stock jar kept: $jar.orig)"
}
