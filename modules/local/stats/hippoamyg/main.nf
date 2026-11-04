// Table of the hippocampal subfield and amygdala nucleus volumes of one sample (DWI run), from
// SEGMENTATION_HIPPOAMYG, with FreeSurfer's eTIV of the same recon-all for head size.
//
// Output CSV, one row per subfield or nucleus and side:
//   sid,session,run,roi,structure,volume_mm3,volume_source,icv_mm3,volume_icv_fraction,t1_shared_with
// roi = Left-/Right-<FreeSurfer name> (e.g. Left-CA1-head, Right-Whole_hippocampus,
// Left-Lateral-nucleus); structure = hippocampus or amygdala; volume_source = reconall.
// The Whole_* rows are sums of the others, not separate structures.
process STATS_HIPPOAMYG {
    tag "$meta.id"
    label 'process_single'

    container "community.wave.seqera.io/library/nibabel_numpy:4148b92a8cbc6976"

    input:
    tuple val(meta), path(subfields), path(recon_all)

    output:
    tuple val(meta), path("*_hippoamyg.csv"), emit: volumes
    path "versions.yml",                      emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix      = task.ext.prefix ?: "${meta.id}"
    def subject_id  = meta.id ?: ""
    def session_id  = meta.session ?: ""
    // Same run convention as the other stats files: bare run number, absent run = 1
    def run_id      = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    def shared_with = (meta.t1_shared_with ?: "").toString().replace(",", " ")
    """
    python3 << 'PYEOF'
import re

etiv = ""
with open("${recon_all}/stats/aseg.stats") as f:
    for line in f:
        m = re.match(r"# Measure EstimatedTotalIntraCranialVol, eTIV, [^,]*, ([0-9.eE+-]+), mm\\^3", line)
        if m:
            etiv = float(m.group(1))

rows = []
for hemi, side in (("lh", "Left"), ("rh", "Right")):
    for kind, structure in (("hippoSfVolumes", "hippocampus"), ("amygNucVolumes", "amygdala")):
        with open(f"${subfields}/{hemi}.{kind}.txt") as f:
            for line in f:
                if not line.strip():
                    continue
                name, volume = line.split()
                rows.append((f"{side}-{name}", structure, float(volume)))

with open("${prefix}_hippoamyg.csv", "w") as out:
    out.write("sid,session,run,roi,structure,volume_mm3,volume_source,icv_mm3,volume_icv_fraction,t1_shared_with\\n")
    for roi, structure, volume in rows:
        fraction = f"{volume / etiv:.8f}" if etiv else ""
        icv = f"{etiv:.4f}" if etiv else ""
        out.write(f"${subject_id},${session_id},${run_id},{roi},{structure},{volume:.4f},reconall,{icv},{fraction},${shared_with}\\n")

with open("versions.yml", "w") as v:
    v.write('"${task.process}":\\n')
    v.write("    python: 3\\n")
PYEOF
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo "sid,session,run,roi,structure,volume_mm3,volume_source,icv_mm3,volume_icv_fraction,t1_shared_with" > ${prefix}_hippoamyg.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        python: stub
    END_VERSIONS
    """
}
