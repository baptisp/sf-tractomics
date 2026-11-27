"""merged/: every metrics table of the batches, one file per table.

Usage: python3 scripts/merge_batches.py

Each batch writes its own copy of every cohort-level table (metrics/*.csv, *.tsv, and those in
subfolders), over its own subjects. They are read from batches/bNNNN/extracted_results.tar.gz
(written at every pack), or from batches/bNNNN/out/metrics/ for a batch packed before out/ was
archived. A merged table is the batches' rows under one header, in batch
order. Batches can differ in columns (a batch without multi-shell runs has no NODDI columns, one
without a b = 1000 shell no AFD ones): then the rows are aligned by column name under the union of
the headers (the widest header's order, then the others' new columns), a missing column is left
empty, and the columns missing in some batches are reported. A table with a header that names a
column twice, or that cannot be read as CSV/TSV, is not merged (listed, exit status 1). merged/ is rebuilt from scratch each time, into merged.tmp/ then
renamed, so it never mixes two merges. Reports which batches lack a table that others have.
"""

import csv
import io
import shutil
import sys
import tarfile
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent


def batch_tables(batch):
    """(path relative to metrics/, text) of every table of one batch"""
    extracted = batch / "extracted_results.tar.gz"
    if extracted.exists():
        with tarfile.open(extracted) as tar:
            for m in sorted(tar.getmembers(), key=lambda m: m.name):
                rel = PurePosixPath(m.name)
                if m.isfile() and rel.parts[0] == "metrics" and rel.suffix in (".csv", ".tsv"):
                    yield str(rel.relative_to("metrics")), tar.extractfile(m).read().decode()
        return
    metrics = batch / "out" / "metrics"
    for f in sorted(metrics.rglob("*")) if metrics.is_dir() else []:
        if f.is_file() and f.suffix in (".csv", ".tsv"):
            yield str(f.relative_to(metrics)), f.read_text()


def merge_by_name(target, files):
    """Write the batches' rows aligned by column name under the union of their headers. Returns a
    note naming the columns some batches lack, or None when a header repeats a column name."""
    sep = "\t" if target.suffix == ".tsv" else ","
    parsed = []
    for name, text in files:
        rows = list(csv.reader(io.StringIO(text), delimiter=sep))
        if not rows or len(set(rows[0])) != len(rows[0]):
            return None
        parsed.append((name, rows[0], rows[1:]))
    columns = list(max((h for _, h, _ in parsed), key=len))
    for _, header, _ in parsed:
        columns += [c for c in header if c not in columns]
    lacking = {}
    with open(target, "w", newline="") as w:
        out = csv.writer(w, delimiter=sep, lineterminator="\n")
        out.writerow(columns)
        for name, header, rows in parsed:
            for c in columns:
                if c not in header:
                    lacking.setdefault(c, []).append(name)
            index = {c: i for i, c in enumerate(header)}
            for row in rows:
                out.writerow([row[index[c]] if c in index and index[c] < len(row) else "" for c in columns])
    if not lacking:
        return ""
    parts = [f"{c} in {len(b)}" for c, b in lacking.items()]
    return f"; aligned by column name, columns absent (left empty) in some batches: {', '.join(parts)}"


def main():
    batches = sorted(p for p in (ROOT / "batches").glob("b[0-9][0-9][0-9][0-9]") if p.is_dir())
    tables = {}
    for b in batches:
        for rel, text in batch_tables(b):
            tables.setdefault(rel, []).append((b.name, text))
    if not tables:
        sys.exit("ERROR: no batch has metrics tables yet")

    tmp, out = ROOT / "merged.tmp", ROOT / "merged"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir()   # exists even when every table is refused
    refused = []
    for rel, files in sorted(tables.items()):
        headers = {text.partition("\n")[0] for _, text in files}
        target = tmp / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        if len(headers) == 1:
            with open(target, "w") as w:
                w.write(headers.pop() + "\n")
                for _, text in files:
                    body = text.partition("\n")[2]
                    w.write(body if not body or body.endswith("\n") else body + "\n")
            absent = ""
        else:
            absent = merge_by_name(target, files)
            if absent is None:
                target.unlink(missing_ok=True)
                refused.append(str(rel))
                continue
        missing = sorted(set(b.name for b in batches) - {name for name, _ in files})
        note = f" (missing in {len(missing)} batch(es): {', '.join(missing[:5])})" if missing else ""
        print(f"{rel}: {len(files)} batch(es){note}{absent}")
    shutil.rmtree(out, ignore_errors=True)
    tmp.rename(out)
    if refused:
        print(f"not merged (a column named twice, or unreadable): {', '.join(refused)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
