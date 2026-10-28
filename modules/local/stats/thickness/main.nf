// Cortical thickness per Desikan region, read from a FreeSurfer recon-all subject folder
// (stats/lh.aparc.stats and stats/rh.aparc.stats, written by mris_anatomical_stats).
// Region names are prefixed ctx-lh- / ctx-rh-, as in the FreeSurfer LUT and the GM files.
//
// Output CSV:
//   sid,session,run,roi,thickness_mm,thickness_std_mm,surface_area_mm2,gm_volume_mm3,num_vertices,
//   thickness_method,qc_flags
// qc_flags (separated by ';', empty = no reason found): coarse_t1 (an input voxel side above
// ext.max_voxel_mm, 1.2 mm by default: recon-all expects about 1 mm), implausible:<regions>
// (mean thickness outside ext.min_thickness_mm .. ext.max_thickness_mm, 1 to 4.5 mm by default,
// the usual sign of a surface failure). Thickness is not normalised by head size.
process STATS_THICKNESS {
    tag "$meta.id"
    label 'process_single'

    conda "${moduleDir}/../../../nf-neuro/stats/roivolumes/environment.yml"
    container "${ 'community.wave.seqera.io/library/nibabel_numpy:4148b92a8cbc6976' }"

    input:
    tuple val(meta), path(recon_all)

    output:
    tuple val(meta), path("*_thickness.csv"), emit: thickness
    path "versions.yml",                      emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix        = task.ext.prefix ?: "${meta.id}"
    def method        = task.ext.thickness_method ?: "recon-all"
    def max_voxel     = task.ext.max_voxel_mm ?: 1.2
    def min_thickness = task.ext.min_thickness_mm ?: 1.0
    def max_thickness = task.ext.max_thickness_mm ?: 4.5
    def subject_id    = meta.id ?: ""
    def session_id    = meta.session ?: ""
    // Same run convention as the other stats files: bare run number, absent run = 1
    def run_id        = (meta.run ?: "run-1").replaceFirst(/^run-/, "")
    """
    python3 << 'PYEOF'
import glob
import os
import sys

import nibabel as nib

rows = []
for hemi in ("lh", "rh"):
    path = os.path.join("${recon_all}", "stats", f"{hemi}.aparc.stats")
    if not os.path.isfile(path):
        sys.exit(f"ERROR: {path} not found: recon-all did not finish for this sample")
    columns = None
    for line in open(path):
        if line.startswith("# ColHeaders"):
            columns = line.split()[2:]
        elif not line.startswith("#") and line.strip():
            if columns is None:
                sys.exit(f"ERROR: {path} has no '# ColHeaders' line")
            value = dict(zip(columns, line.split()))
            rows.append((f"ctx-{hemi}-{value['StructName']}", value))

# Voxel size of the input T1 as recon-all received it
flags = []
orig = sorted(glob.glob(os.path.join("${recon_all}", "mri", "orig", "0*.mgz")))
if orig and max(float(z) for z in nib.load(orig[0]).header.get_zooms()[:3]) > ${max_voxel}:
    flags.append("coarse_t1")
implausible = [roi for roi, v in rows if not ${min_thickness} <= float(v["ThickAvg"]) <= ${max_thickness}]
if implausible:
    flags.append("implausible:" + "|".join(implausible))
qc_flags = ";".join(flags)

with open("${prefix}_thickness.csv", "w") as out:
    out.write("sid,session,run,roi,thickness_mm,thickness_std_mm,surface_area_mm2,gm_volume_mm3,num_vertices,"
              "thickness_method,qc_flags\\n")
    for roi, v in rows:
        out.write(f"${subject_id},${session_id},${run_id},{roi},{v['ThickAvg']},{v['ThickStd']},{v['SurfArea']},"
                  f"{v['GrayVol']},{v['NumVert']},${method},{qc_flags}\\n")

with open("versions.yml", "w") as v:
    v.write('"${task.process}":\\n')
    v.write(f"    nibabel: {nib.__version__}\\n")
PYEOF
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    echo "sid,session,run,roi,thickness_mm,thickness_std_mm,surface_area_mm2,gm_volume_mm3,num_vertices,thickness_method,qc_flags" > ${prefix}_thickness.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        nibabel: stub
    END_VERSIONS
    """
}
