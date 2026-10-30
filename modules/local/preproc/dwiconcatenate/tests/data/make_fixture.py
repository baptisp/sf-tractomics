"""Builds the DWI parts of the concatenation tests. Run in the scilus container: python3 make_fixture.py

Three parts of one 4x4x4 acquisition (2 mm), as a Siemens split series: b0 = 100 in the central
2x2x2 voxels and 10 elsewhere, times a per-series intensity scale (part 1: 1, part 2: 2, part 3:
0.5), diffusion volumes b0 x exp(-b x 1e-3):
  part1: b 0, 1000, 1000     part2: b 0, 500, 500     part3: b 0, 2000, 2000
After concatenation every part is on the scale of part 1: b0 = 100 in the centre, and the
diffusion volumes 100 exp(-1), 100 exp(-0.5), 100 exp(-2). shifted.nii.gz is part 2 moved by
one voxel (another grid).
"""
import nibabel as nib
import numpy as np

affine = np.diag([2.0, 2.0, 2.0, 1.0])
b0 = np.full((4, 4, 4), 10.0)
b0[1:3, 1:3, 1:3] = 100.0
dirs = np.array([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0]]).T
for name, scale, b in (("part1", 1.0, 1000.0), ("part2", 2.0, 500.0), ("part3", 0.5, 2000.0)):
    vols = [b0 * scale] + [b0 * scale * np.exp(-b * 1e-3)] * 2
    nib.save(nib.Nifti1Image(np.stack(vols, axis=3).astype(np.float32), affine), f"{name}.nii.gz")
    np.savetxt(f"{name}.bval", np.array([[0, b, b]]), fmt="%g")
    np.savetxt(f"{name}.bvec", np.concatenate([[[0.0], [0.0], [0.0]], dirs], axis=1), fmt="%g")
shifted = affine.copy()
shifted[0, 3] = 2.0
nib.save(nib.Nifti1Image(np.asarray(nib.load("part2.nii.gz").dataobj), shifted), "shifted.nii.gz")
