"""merged/: every metrics table of the batches, one file per table.

Usage: python3 scripts/merge_batches.py

Each batch writes its own copy of every cohort-level table (metrics/*.csv, *.tsv, and those in
subfolders), over its own subjects. They are read from batches/bNNNN/extracted_results.tar.gz
(written at every pack), or from batches/bNNNN/out/metrics/ for a batch packed before out/ was
archived. A merged table is the batches' rows under one header, in batch
order. A table whose header differs between batches is not merged (listed, exit status 1): its
columns would not line up. merged/ is rebuilt from scratch each time, into merged.tmp/ then
renamed, so it never mixes two merges. Reports which batches lack a table that others have.
"""

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
        if len(headers) != 1:
            refused.append(str(rel))
            continue
        target = tmp / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "w") as w:
            w.write(headers.pop() + "\n")
            for _, text in files:
                body = text.partition("\n")[2]
                w.write(body if not body or body.endswith("\n") else body + "\n")
        missing = sorted(set(b.name for b in batches) - {name for name, _ in files})
        note = f" (missing in {len(missing)} batch(es): {', '.join(missing[:5])})" if missing else ""
        print(f"{rel}: {len(files)} batch(es){note}")
    shutil.rmtree(out, ignore_errors=True)
    tmp.rename(out)
    if refused:
        print(f"not merged, headers differ between batches: {', '.join(refused)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
