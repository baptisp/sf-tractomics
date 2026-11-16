#!/usr/bin/env python3
"""Repair listed input images of one launch folder, once, before a pass runs (stdlib only).

Usage: fix_inputs.py LIST DIR

LIST (inputs/input_fixes.tsv): columns `file`, `fix`, `reason`, with that header. `file` is a path
under data_bids/ (sub-X/ses-Y/anat/...nii.gz). A row whose file is not in DIR/data_bids is another
launch folder's and is skipped.

Each fix is applied once per launch folder and recorded in DIR/meta/input_fixes_applied.tsv: a
rewritten file has a new modification time, so applying it again would recompute every task that
reads it. The file must still be the one DIR/meta/inputs.sha256 recorded (an original input): its
checksum line is then replaced by the repaired file's, so the check of run_pass still guarantees
that nothing else changed. Only the listed file's tasks recompute; every other file keeps its cache.

Fixes:
  sform_from_qform   the sform matrix is replaced by the one the qform gives (quaternion, offsets,
                     pixdim and qfac), sform_code kept. For a T1 whose two transforms disagree on
                     the voxel size: ITK reads one, MRtrix the other, and N4 then refuses an image
                     and its mask that "do not occupy the same physical space" (ADNI b0096, sform
                     voxel 1.0000992 mm, qform 1 mm). Only the 348-byte header changes.
"""

import csv
import gzip
import hashlib
import math
import struct
import sys
from datetime import datetime
from pathlib import Path

HEADER = 348


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def endian(raw):
    for e in "<>":
        if struct.unpack_from(e + "i", raw, 0)[0] == HEADER:
            return e
    raise ValueError("not a NIfTI-1 header")


def qform_matrix(raw, e):
    """The 3x4 affine of the qform (NIfTI-1 method 2)."""
    b, c, d, qx, qy, qz = struct.unpack_from(e + "6f", raw, 256)
    pixdim = struct.unpack_from(e + "8f", raw, 76)
    qfac = -1.0 if pixdim[0] < 0 else 1.0
    a = 1.0 - (b * b + c * c + d * d)
    a = math.sqrt(a) if a > 1e-7 else 0.0
    r = [[a * a + b * b - c * c - d * d, 2 * (b * c - a * d), 2 * (b * d + a * c)],
         [2 * (b * c + a * d), a * a + c * c - b * b - d * d, 2 * (c * d - a * b)],
         [2 * (b * d - a * c), 2 * (c * d + a * b), a * a + d * d - c * c - b * b]]
    scale = (pixdim[1], pixdim[2], pixdim[3] * qfac)
    offset = (qx, qy, qz)
    return [[r[i][j] * scale[j] for j in range(3)] + [offset[i]] for i in range(3)]


def sform_from_qform(data):
    raw = bytearray(data[:HEADER])
    e = endian(raw)
    if struct.unpack_from(e + "h", raw, 252)[0] <= 0:
        raise ValueError("no qform (qform_code 0): nothing to take the sform from")
    for i, row in enumerate(qform_matrix(raw, e)):
        struct.pack_into(e + "4f", raw, 280 + 16 * i, *row)
    if struct.unpack_from(e + "h", raw, 254)[0] <= 0:
        struct.pack_into(e + "h", raw, 254, struct.unpack_from(e + "h", raw, 252)[0])
    return bytes(raw) + data[HEADER:]


FIXES = {"sform_from_qform": sform_from_qform}


def apply(path, fix):
    opener = gzip.open if path.name.endswith(".gz") else open
    with opener(path, "rb") as f:
        data = f.read()
    fixed = FIXES[fix](data)
    tmp = path.with_name(path.name + ".fixing")
    with opener(tmp, "wb") as f:
        f.write(fixed)
    tmp.replace(path)


def main(list_path, launch):
    launch = Path(launch)
    sums_path = launch / "meta" / "inputs.sha256"
    applied_path = launch / "meta" / "input_fixes_applied.tsv"
    applied = set()
    if applied_path.exists():
        applied = {line.split("\t")[0] for line in applied_path.read_text().splitlines()[1:] if line}
    with open(list_path, newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    if rows and set(rows[0]) != {"file", "fix", "reason"}:
        sys.exit(f"{list_path}: columns must be file, fix, reason")
    for row in rows:
        if row["fix"] not in FIXES:
            sys.exit(f"{list_path}: unknown fix {row['fix']!r} (known: {', '.join(FIXES)})")
    sums = sums_path.read_text().splitlines() if sums_path.exists() else []
    done = []
    for row in rows:
        rel = "data_bids/" + row["file"].strip().lstrip("/")
        path = launch / rel
        if not path.is_file() or rel in applied:
            continue
        line = next((i for i, s in enumerate(sums) if s.split("  ", 1)[-1] == rel), None)
        if line is None:
            sys.exit(f"{rel} has no checksum in {sums_path}")
        before = sha256(path)
        if sums[line].split("  ", 1)[0] != before:
            sys.exit(f"{rel} is not the input that was prepared (checksum differs): not repaired")
        apply(path, row["fix"])
        after = sha256(path)
        sums[line] = f"{after}  {rel}"
        done.append((rel, row["fix"], before, after))
    if not done:
        return
    tmp = sums_path.with_name(sums_path.name + ".fixing")
    tmp.write_text("\n".join(sums) + "\n")
    tmp.replace(sums_path)
    new = not applied_path.exists()
    with open(applied_path, "a") as f:
        if new:
            f.write("file\tfix\tsha256_before\tsha256_after\tdate\n")
        stamp = datetime.now().strftime("%F %T")
        for rel, fix, before, after in done:
            f.write(f"{rel}\t{fix}\t{before}\t{after}\t{stamp}\n")
            print(f"{launch}: {rel} repaired ({fix})")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
