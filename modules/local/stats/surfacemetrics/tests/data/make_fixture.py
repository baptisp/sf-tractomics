"""Builds the synthetic FreeSurfer subject and diffusion maps of the surface metrics tests.
Run in the scilus container (nibabel, numpy, scipy): python3 make_fixture.py

Subject: one sphere per hemisphere, centred at tkregister (-14, 0, 0) and (14, 0, 0), white
surface radius 8 mm, pial 12 mm, so mid-thickness is at radius 10 mm. orig.mgz (and t1.nii.gz) is a 64^3 1 mm
conformed (LIA) volume whose centre is at scanner (10, 20, -5): surface and scanner coordinates
differ by that offset. t1_cropped.nii.gz keeps the
first 41 slices of t1.nii.gz, cutting through the lh sphere (a T1 cropped too tight). Regions: superiorfrontal above the centre (z > 5 mm), inferiortemporal
below (z < -5 mm), unknown between; precuneus is in the colour table with no vertex.

Diffusion space (2 mm grid) is the T1 space moved 3 mm up: dwi_to_t1.txt maps each T1 point
to the DWI point 3 mm higher, as an ANTs transform does. Maps:
  test__md.nii.gz            2 above the sphere centres, 5 below
  test_desc-fwc__md.nii.gz   distance to the nearest sphere centre (10 at mid-thickness)
  mask.nii.gz                1 within 18 mm of a centre, except below the rh centre (z < -2 mm)
"""
import os

import nibabel as nib
import numpy as np
from scipy.spatial import ConvexHull

C_RAS = np.array([10.0, 20.0, -5.0])
CENTRES = {"lh": np.array([-14.0, 0.0, 0.0]), "rh": np.array([14.0, 0.0, 0.0])}   # tkregister
SHIFT = np.array([0.0, 0.0, 3.0])      # DWI point = T1 point + SHIFT
REGIONS = ["unknown", "superiorfrontal", "inferiortemporal", "precuneus"]

for d in ("mri", "surf", "label"):
    os.makedirs(f"sub__recon_all/{d}", exist_ok=True)
with open("dwi_to_t1.txt", "w") as f:   # ITK (LPS) z is RAS z: +3 mm up
    f.write("#Insight Transform File V1.0\n#Transform 0\nTransform: AffineTransform_double_3_3\n"
            "Parameters: 1 0 0 0 1 0 0 0 1 0 0 3\nFixedParameters: 0 0 0\n")

# orig.mgz: conformed LIA, 1 mm, centre at C_RAS
lia = np.array([[-1, 0, 0], [0, 0, 1], [0, -1, 0]], float)
affine = np.eye(4)
affine[:3, :3] = lia
affine[:3, 3] = C_RAS - lia @ np.array([32.0, 32.0, 32.0])
nib.save(nib.MGHImage(np.zeros((64, 64, 64), np.uint8), affine), "sub__recon_all/mri/orig.mgz")
t1 = nib.Nifti1Image(np.zeros((64, 64, 64), np.float32), affine)
nib.save(t1, "t1.nii.gz")
nib.save(t1.slicer[:41], "t1_cropped.nii.gz")   # cut at x = -8 mm: through the lh sphere

# Spheres (Fibonacci points), regions by height
n = 2000
k = np.arange(n) + 0.5
z = 1 - 2 * k / n
r = np.sqrt(1 - z ** 2)
phi = np.pi * (1 + 5 ** 0.5) * k
unit = np.stack([r * np.cos(phi), r * np.sin(phi), z], axis=1)
faces = ConvexHull(unit).simplices.astype(np.int32)
for hemi, c in CENTRES.items():
    for surf, radius in (("white", 8.0), ("pial", 12.0)):
        nib.freesurfer.write_geometry(f"sub__recon_all/surf/{hemi}.{surf}", c + radius * unit, faces,
                                     create_stamp="created by make_fixture.py")
    height = 10.0 * unit[:, 2]
    labels = np.where(height > 5, 1, np.where(height < -5, 2, 0)).astype(np.int32)
    ctab = np.array([[25, 5, 25, 0, 0], [20, 220, 160, 0, 0], [180, 40, 120, 0, 0], [160, 140, 180, 0, 0]], np.int32)
    ctab[:, 4] = ctab[:, 0] + ctab[:, 1] * 256 + ctab[:, 2] * 65536
    nib.freesurfer.write_annot(f"sub__recon_all/label/{hemi}.aparc.annot", labels, ctab, REGIONS, fill_ctab=False)
    assert [(labels == i).sum() for i in (1, 2)] == [500, 500]

# Diffusion maps on a 2 mm RAS grid covering the head
dwi_affine = np.diag([2.0, 2.0, 2.0, 1.0])
dwi_affine[:3, 3] = C_RAS - 31.0
ijk = np.indices((32, 32, 32)).reshape(3, -1).T
xyz = nib.affines.apply_affine(dwi_affine, ijk)
centres = {h: c + C_RAS + SHIFT for h, c in CENTRES.items()}   # scanner, DWI space
dist = {h: np.linalg.norm(xyz - c, axis=1) for h, c in centres.items()}
nearest = np.minimum(dist["lh"], dist["rh"])
md = np.where(xyz[:, 2] > centres["lh"][2], 2.0, 5.0)
mask = (nearest <= 18) & ~((dist["rh"] < dist["lh"]) & (xyz[:, 2] < centres["rh"][2] - 2))
for name, data in (("test__md", md), ("test_desc-fwc__md", nearest), ("mask", mask.astype(float))):
    nib.save(nib.Nifti1Image(data.reshape(32, 32, 32).astype(np.float32), dwi_affine), f"{name}.nii.gz")
