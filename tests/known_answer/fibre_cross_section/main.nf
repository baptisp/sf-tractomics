// Test harness: fibre cross-section on synthetic data with known answers.
//   Template: 16 x 8 x 4 voxels of 1.25 mm, RAS, one fibre per voxel: along x in the left half
//   (bundle "X"), along y in the right half (bundle "Y"). The subject is the template itself (its
//   brain mask larger, so every template fixel stays covered under the scaling), and
//   the subject-to-template warp is set by hand (no registration):
//     iso   positions scaled by s in every direction: cross-section x s^2, log FC = 2 ln s everywhere
//     xonly positions scaled by s along x only: fibres along x keep their cross-section (log FC = 0),
//           fibres along y have theirs scaled by s (log FC = ln s)
//   Orientation: a descoteaux07 fODF stored LAS with one lobe along voxel axes (1, 1, 0) / sqrt 2;
//   voxel axis i points left, so MRtrix must read the lobe along (-1, 1, 0) / sqrt 2 after
//   RECONST_FODTOMRTRIX.
include { RECONST_FODTOMRTRIX         } from '../../../modules/local/reconst/fodmrtrix/main'
include { TEMPLATE_FCBUNDLEFIXELS     } from '../../../modules/local/template/fcbundlefixels/main'
include { STATS_FIBRECROSSSECTION     } from '../../../modules/local/stats/fibrecrosssection/main'

process MAKE_FC_DATA {
    container "scilus/scilus:2.2.2"

    output:
    tuple path("template_fod.nii.gz"), path("template_mask.nii.gz"), path("bundles"), emit: template
    path "subject_mask.nii.gz", emit: subject_mask
    path "las_fod.nii.gz", emit: las_fod

    script:
    """
    python3 << 'PYEOF'
import inspect, os
import nibabel as nib
import numpy as np
from dipy.core.sphere import Sphere
from dipy.data import get_sphere
from dipy.reconst.shm import sh_to_sf_matrix

try:
    sphere = get_sphere(name="repulsion724")
except TypeError:
    sphere = get_sphere("repulsion724")
U = sphere.vertices
def fit(direction, basis, legacy=False, lmax=6):
    order = "sh_order_max" if "sh_order_max" in inspect.signature(sh_to_sf_matrix).parameters else "sh_order"
    B = sh_to_sf_matrix(Sphere(xyz=U), **{order: lmax}, basis_type=basis, legacy=legacy, return_inv=False)
    B = B[0] if isinstance(B, tuple) else B
    d = np.asarray(direction, float) / np.linalg.norm(direction)
    amplitudes = np.exp(-20 * (1 - (U @ d) ** 2))
    return amplitudes @ np.linalg.pinv(B)

shape = (16, 8, 4)
affine = np.diag([1.25, 1.25, 1.25, 1.0]); affine[:3, 3] = -np.array(shape) * 1.25 / 2
fod = np.zeros(shape + (28,), np.float32)
fod[:8] = fit([1, 0, 0], "tournier07")
fod[8:] = fit([0, 1, 0], "tournier07")
nib.save(nib.Nifti1Image(fod, affine), "template_fod.nii.gz")
nib.save(nib.Nifti1Image(np.ones(shape, np.uint8), affine), "template_mask.nii.gz")
# The subject's brain mask covers the template even after scaling by 1.2: every fixel is covered
big = tuple(2 * n for n in shape)
big_affine = affine.copy(); big_affine[:3, 3] = -np.array(big) * 1.25 / 2
nib.save(nib.Nifti1Image(np.ones(big, np.uint8), big_affine), "subject_mask.nii.gz")
os.makedirs("bundles")
# Named like the IIT mask files (<bundle>_mask): the bundle names drop the suffix
for name, sl in (("X_mask", slice(0, 8)), ("Y_mask", slice(8, 16))):
    m = np.zeros(shape, np.uint8); m[sl] = 1
    nib.save(nib.Nifti1Image(m, affine), f"bundles/{name}.nii.gz")

las = np.diag([-2.0, 2.0, 2.0, 1.0]); las[:3, 3] = [3, -3, -3]
nib.save(nib.Nifti1Image(np.tile(fit([1, 1, 0], "descoteaux07").astype(np.float32), (4, 4, 4, 1)), las), "las_fod.nii.gz")
PYEOF
    """
}

process MAKE_FC_TEMPLATE_INPUTS {
    container "mrtrix3/mrtrix3:3.0.5"

    input:
    tuple path(fod), path(mask), path(bundles)

    output:
    tuple path("fod_template.mif"), path("template_mask.mif"), path("template_b0.nii.gz"), path("fixels"), path("sessions.tsv"), path(bundles), path("iit_b0.nii.gz"), emit: inputs
    path "warps", emit: warps

    script:
    """
    mrconvert -quiet ${fod} fod_template.mif
    mrconvert -quiet ${mask} template_mask.mif
    cp -L ${mask} template_b0.nii.gz
    cp -L ${mask} iit_b0.nii.gz
    printf "label\\nsynthetic\\n" > sessions.tsv
    fod2fixel -quiet -mask template_mask.mif fod_template.mif fixels -afd fd.mif
    mkdir warps
    warpinit -quiet template_mask.mif identity.mif
    mrcalc -quiet identity.mif 1.2 -mult warps/iso.mif
    mrconvert -quiet -coord 3 0 identity.mif wx.mif
    mrconvert -quiet -coord 3 1:2 identity.mif wyz.mif
    mrcalc -quiet wx.mif 1.2 -mult wx_scaled.mif
    mrcat -quiet wx_scaled.mif wyz.mif -axis 3 warps/xonly.mif
    """
}

process READ_PEAK {
    container "mrtrix3/mrtrix3:3.0.5"

    input:
    tuple val(meta), path(fod)

    output:
    path "peak.txt"

    script:
    """
    sh2peaks -quiet ${fod} -num 1 peak.mif
    mrconvert -quiet peak.mif -coord 0 1 -coord 1 1 -coord 2 1 - | mrdump -quiet - > peak.txt
    """
}

workflow FC_KNOWN_ANSWER {
    main:
    MAKE_FC_DATA()
    MAKE_FC_TEMPLATE_INPUTS(MAKE_FC_DATA.out.template)
    TEMPLATE_FCBUNDLEFIXELS(MAKE_FC_TEMPLATE_INPUTS.out.inputs)

    ch_subject = MAKE_FC_DATA.out.template.map { fod, _mask, _bundles -> fod }.combine(MAKE_FC_DATA.out.subject_mask)
    ch_qc = channel.of("orientation_agreement 1").collectFile(name: "fc_registration.txt")
    ch_cases = MAKE_FC_TEMPLATE_INPUTS.out.warps
        .flatMap { dir -> ["iso", "xonly"].collect { c -> [[id: c, session: "", run: ""], file("${dir}/${c}.mif")] } }
    STATS_FIBRECROSSSECTION(
        ch_cases
            .combine(ch_subject)
            .combine(ch_qc)
            .combine(TEMPLATE_FCBUNDLEFIXELS.out.template)
            .map { meta, warp, fod, mask, qc, tpl -> [meta, fod, mask, warp, qc, 0, tpl] }
    )

    RECONST_FODTOMRTRIX(MAKE_FC_DATA.out.las_fod.map { f -> [[id: "las"], f] })
    READ_PEAK(RECONST_FODTOMRTRIX.out.fod)

    emit:
    stats    = STATS_FIBRECROSSSECTION.out.stats
    template = TEMPLATE_FCBUNDLEFIXELS.out.template
    peak     = READ_PEAK.out
    // The pipeline parses every versions.yml as YAML at the end of a run
    versions = RECONST_FODTOMRTRIX.out.versions.mix(TEMPLATE_FCBUNDLEFIXELS.out.versions, STATS_FIBRECROSSSECTION.out.versions)
}
