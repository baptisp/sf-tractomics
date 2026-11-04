// TractoFlow's fODF (scilpy, `basis` = descoteaux07 by default) rewritten for MRtrix: RAS voxel
// order and the tournier07 basis, so that MRtrix reads the same orientations.
//
// scilpy fits the spherical harmonics in the voxel frame of the image (the b-vectors are used as
// stored, in image axes). MRtrix reads spherical harmonics in its scanner frame, where the image
// axes are flipped or permuted to the nearest RAS order. For an image stored LAS (the TractoFlow
// outputs of OASIS-3 and ADNI), a lobe along voxel axis i, which points left, would be read by
// MRtrix as pointing right: oblique fibres would come out mirrored. So the image is reordered to RAS
// and each voxel's function is moved with it: c' = c M, where M samples the input basis on the
// reflected/permuted directions and fits the output basis on the original ones (exact for these
// band-limited functions). The step is checked against the DWI itself in FC_REGISTER
// (orientation_agreement: fODF peak vs. tensor main eigenvector).
//
// Output: <prefix>__fod_mrtrix.nii.gz, same spherical harmonic order, RAS, tournier07.
process RECONST_FODTOMRTRIX {
    tag "$meta.id"
    label 'process_single'

    container "scilus/scilus:2.2.2"

    input:
    tuple val(meta), path(fodf)

    output:
    tuple val(meta), path("*__fod_mrtrix.nii.gz"), emit: fod
    path "versions.yml",                           emit: versions

    when:
    task.ext.when == null || task.ext.when

    script:
    def prefix   = task.ext.prefix ?: "${meta.id}"
    def in_basis = task.ext.in_basis ?: "descoteaux07"
    """
    python3 << 'PYEOF'
import inspect

import nibabel as nib
import numpy as np
from dipy.core.sphere import Sphere
from dipy.data import get_sphere
from dipy.reconst.shm import order_from_ncoef, sh_to_sf_matrix

in_basis = "${in_basis}"
img = nib.load("${fodf}")
data = np.asarray(img.dataobj, dtype=np.float32)
lmax = int(order_from_ncoef(data.shape[-1]))

# Signed permutation R: new (RAS) voxel axis j = sign * old voxel axis i
transform = nib.orientations.ornt_transform(nib.io_orientation(img.affine),
                                            nib.orientations.axcodes2ornt(("R", "A", "S")))
R = np.zeros((3, 3))
for i, (j, s) in enumerate(transform):
    R[int(j), i] = s

def basis(dirs, name):
    legacy = name.endswith("_legacy")
    kind = name.replace("_legacy", "")
    order = "sh_order_max" if "sh_order_max" in inspect.signature(sh_to_sf_matrix).parameters else "sh_order"
    B = sh_to_sf_matrix(Sphere(xyz=dirs), **{order: lmax}, basis_type=kind, legacy=legacy, return_inv=False)
    return B[0] if isinstance(B, tuple) else B   # (n_coefficients, n_directions): amplitudes = c @ B

try:
    sphere = get_sphere(name="repulsion724")
except TypeError:
    sphere = get_sphere("repulsion724")
U = sphere.vertices                 # directions in the new (RAS) voxel frame
V = U @ R                           # the same directions in the old voxel frame (R^T u)
M = basis(V, in_basis) @ np.linalg.pinv(basis(U, "tournier07"))

out = img.as_reoriented(transform)
coefs = np.asarray(out.dataobj, dtype=np.float32)
coefs = (coefs.reshape(-1, coefs.shape[-1]) @ M.astype(np.float32)).reshape(coefs.shape)
nib.save(nib.Nifti1Image(coefs.astype(np.float32), out.affine), "${prefix}__fod_mrtrix.nii.gz")
print(f"lmax {lmax}, axes {''.join(nib.aff2axcodes(img.affine))} -> RAS, {in_basis} -> tournier07")
PYEOF

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        dipy: \$(python3 -c "import dipy; print(dipy.__version__)")
        nibabel: \$(python3 -c "import nibabel; print(nibabel.__version__)")
    END_VERSIONS
    """

    stub:
    def prefix = task.ext.prefix ?: "${meta.id}"
    """
    touch ${prefix}__fod_mrtrix.nii.gz

    cat <<-END_VERSIONS > versions.yml
    "${task.process}":
        dipy: stub
        nibabel: stub
    END_VERSIONS
    """
}
