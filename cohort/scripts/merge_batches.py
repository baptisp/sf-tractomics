"""merged/: every metrics table of the batches (batches/bNNNN/out/metrics/...), one file per table.

Usage: python3 scripts/merge_batches.py

Each batch writes its own copy of every cohort-level table (metrics/*.csv, *.tsv, and those in
subfolders), over its own subjects. A merged table is the batches' rows under one header, in batch
order. A table whose header differs between batches is not merged (listed, exit status 1): its
columns would not line up. merged/ is rebuilt from scratch each time, into merged.tmp/ then
renamed, so it never mixes two merges. Reports which batches lack a table that others have.
"""

import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def main():
    batches = sorted(p for p in (ROOT / "batches").glob("b[0-9][0-9][0-9][0-9]") if p.is_dir())
    tables = {}
    for b in batches:
        metrics = b / "out" / "metrics"
        for f in sorted(metrics.rglob("*")) if metrics.is_dir() else []:
            if f.is_file() and f.suffix in (".csv", ".tsv"):
                tables.setdefault(f.relative_to(metrics), []).append((b.name, f))
    if not tables:
        sys.exit("ERROR: no batch has metrics tables yet")

    tmp, out = ROOT / "merged.tmp", ROOT / "merged"
    shutil.rmtree(tmp, ignore_errors=True)
    refused = []
    for rel, files in sorted(tables.items()):
        headers = {f.open().readline() for _, f in files}
        if len(headers) != 1:
            refused.append(str(rel))
            continue
        target = tmp / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        with open(target, "w") as w:
            w.write(headers.pop())
            for _, f in files:
                with open(f) as r:
                    next(r, None)
                    shutil.copyfileobj(r, w)
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
