// Concatenation of the parts of one diffusion acquisition stored as several series (Siemens
// "<name>_1_of_3", "_2_of_3", ...: each part holds some of the shells, and only all of them
// together are the protocol; on OASIS-3 Vida, 66 volumes from b = 100 to 2000 in 3 parts).
//
// The parts must be on the same grid (shape and affine; the run stops otherwise). Each series
// has its own intensity scaling, so every part is scaled to the first one by the ratio of their
// mean b0 inside a rough brain mask of the first part's b0 (voxels above its mean); a part
// without a b0 is left unscaled and flagged. Head motion between parts is left to eddy, which
// registers all the volumes together.
//
// Inputs, in part order: dwis, bvals, bvecs (lists of the same length).
// Outputs:
//   <prefix>__dwi_concatenated.{nii.gz,bval,bvec}   float32 DWI, FSL b-values and b-vectors
//   <prefix>__dwi_concatenated_parts.csv            part, file, volumes, b0_volumes, scale, note
process PREPROC_DWICONCATENATE {
    tag "$meta.id"
    label 'process_single'

    container "scilus/scilus:2.2.2"

    input:
    tuple val(meta), path(dwis, stageAs: "part??/*"), path(bvals, stageAs: "part??/*"), path(bvecs, stageAs: "part??/*")

    output:
    tuple val(meta), path("*__dwi_concatenated.nii.gz"), path("*__dwi_concatenated.bval"), path("*__dwi_concatenated.bvec"), emit: dwi_bval_bvec
    tuple val(meta), path("*__dwi_concatenated_parts.csv"), emit: parts
    path "versions.yml", emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix   = task.ext.prefix ?: "${meta.id}"
    def b0_thr   = task.ext.b0_thr_extract_b0 != null ? task.ext.b0_thr_extract_b0 : 10
    def dwi_list  = dwis instanceof List ? dwis : [dwis]
    def bval_list = bvals instanceof List ? bvals : [bvals]
    def bvec_list = bvecs instanceof List ? bvecs : [bvecs]
    """
    python3 << 'PYEOF'
import nibabel as nib
import numpy as np

dwis = "${dwi_list.join(' ')}".split()
bvals = "${bval_list.join(' ')}".split()
bvecs = "${bvec_list.join(' ')}".split()
if not (len(dwis) == len(bvals) == len(bvecs)) or len(dwis) < 2:
    raise SystemExit(f"ERROR: expected matching lists of at least 2 parts, got {len(dwis)} DWIs, {len(bvals)} bvals, {len(bvecs)} bvecs")

ref = nib.load(dwis[0])
parts, all_b, all_v, rows = [], [], [], []
mask = None
ref_b0 = None
for i, (d, bl, bv) in enumerate(zip(dwis, bvals, bvecs), start=1):
    img = nib.load(d)
    if img.shape[:3] != ref.shape[:3] or not np.allclose(img.affine, ref.affine, atol=1e-3):
        raise SystemExit(f"ERROR: part {i} ({d}) is not on the grid of part 1 ({dwis[0]}): "
                         f"shape {img.shape[:3]} vs {ref.shape[:3]}")
    data = np.asarray(img.dataobj, dtype=np.float32)
    if data.ndim == 3:
        data = data[..., None]
    b = np.loadtxt(bl, ndmin=1)
    v = np.loadtxt(bv, ndmin=2)
    if v.shape[0] != 3 and v.shape[1] == 3:
        v = v.T
    if not (data.shape[3] == len(b) == v.shape[1]):
        raise SystemExit(f"ERROR: part {i} has {data.shape[3]} volumes, {len(b)} b-values and {v.shape[1]} b-vectors")
    b0 = b <= ${b0_thr}
    note = ""
    if b0.any():
        mean_b0 = data[..., b0].mean(axis=3)
        if mask is None:
            mask = mean_b0 > mean_b0.mean()
            ref_b0 = float(mean_b0[mask].mean())
        scale = ref_b0 / float(mean_b0[mask].mean())
    else:
        scale = 1.0
        note = "no b0: not scaled"
        if mask is None:
            raise SystemExit("ERROR: part 1 has no b0, the parts cannot be put on one intensity scale")
    parts.append(data * np.float32(scale))
    all_b.append(b)
    all_v.append(v)
    rows.append(f"{i},{d.split('/')[-1]},{len(b)},{int(b0.sum())},{scale:.6f},{note}")

out = np.concatenate(parts, axis=3)
header = ref.header.copy()
header.set_data_dtype(np.float32)
header.set_slope_inter(1, 0)
nib.save(nib.Nifti1Image(out, ref.affine, header), "${prefix}__dwi_concatenated.nii.gz")
np.savetxt("${prefix}__dwi_concatenated.bval", np.concatenate(all_b)[None, :], fmt="%g")
np.savetxt("${prefix}__dwi_concatenated.bvec", np.concatenate(all_v, axis=1), fmt="%.8f")
with open("${prefix}__dwi_concatenated_parts.csv", "w") as f:
    f.write("part,file,volumes,b0_volumes,scale,note\\n")
    f.write("\\n".join(rows) + "\\n")

with open("versions.yml", "w") as v:
    v.write('"${task.process}":\\n')
    v.write(f"    nibabel: {nib.__version__}\\n")
    v.write(f"    numpy: {np.__version__}\\n")
PYEOF
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}__dwi_concatenated.nii.gz ${prefix}__dwi_concatenated.bval ${prefix}__dwi_concatenated.bvec
    echo "part,file,volumes,b0_volumes,scale,note" > ${prefix}__dwi_concatenated_parts.csv

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        nibabel: stub
        numpy: stub
    END_VERSIONS
    """
}
