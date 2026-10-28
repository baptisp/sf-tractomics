// Hippocampal occupancy score (Heister et al. 2011, Neurology):
//   HOC = hippocampus / (hippocampus + inferior lateral ventricle)
// per hemisphere, and bilateral = both hippocampi / (both hippocampi + both inferior lateral
// ventricles). Counted on the subject's own segmentation (SynthSeg, SAMSEG or FreeSurfer
// aparc+aseg, which share the FreeSurfer label numbers 17/53 and 5/44). A ratio of two volumes of
// one segmentation, so it does not depend on the voxel size.
//
// Output CSV:
//   sid,session,run,roi,hoc,hippocampus_mm3,inf_lat_vent_mm3,volume_source
// roi = Left, Right, Bilateral. hoc is empty when both structures are absent.
process STATS_HOC {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/../../../nf-neuro/stats/roivolumes/environment.yml"
    container "${ 'community.wave.seqera.io/library/nibabel_numpy:4148b92a8cbc6976' }"

    input:
    tuple val(meta), path(labelmap)

    output:
    tuple val(meta), path("*_hoc.csv"), emit: hoc
    path "versions.yml",                emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix        = task.ext.prefix ?: "${meta.id}"
    def volume_source = task.ext.volume_source ?: "subject"
    def subject_id    = meta.id ?: ""
    def session_id    = meta.session ?: ""
    // Same run convention as the other stats files: bare run number, absent run = 1
    def run_id        = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    """
    python3 << 'PYEOF'
import nibabel as nib
import numpy as np

img = nib.load("${labelmap}")
data = np.round(np.asarray(img.dataobj)).astype(np.int32)
vox = float(np.prod(img.header.get_zooms()[:3]))

def mm3(label):
    return float(np.count_nonzero(data == label)) * vox

sides = {"Left": (mm3(17), mm3(5)), "Right": (mm3(53), mm3(44))}
sides["Bilateral"] = tuple(sides["Left"][i] + sides["Right"][i] for i in range(2))

with open("${prefix}_hoc.csv", "w") as out:
    out.write("sid,session,run,roi,hoc,hippocampus_mm3,inf_lat_vent_mm3,volume_source\\n")
    for roi in ("Left", "Right", "Bilateral"):
        hippo, ventricle = sides[roi]
        hoc = f"{hippo / (hippo + ventricle):.6f}" if hippo + ventricle > 0 else ""
        out.write(f"${subject_id},${session_id},${run_id},{roi},{hoc},{hippo:.4f},{ventricle:.4f},${volume_source}\\n")

with open("versions.yml", "w") as v:
    v.write('"${task.process}":\\n')
    v.write(f"    nibabel: {nib.__version__}\\n")
    v.write(f"    numpy: {np.__version__}\\n")
PYEOF
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo "sid,session,run,roi,hoc,hippocampus_mm3,inf_lat_vent_mm3,volume_source" > ${prefix}_hoc.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        nibabel: stub
        numpy: stub
    END_VERSIONS
    """
}
