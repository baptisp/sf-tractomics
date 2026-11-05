"""Which tasks of run 1 were computed again in run 2 (they should all be reused).

Usage: python3 scripts/reuse_report.py RUN2_TRACE RUN1_TRACE [RUN1_TRACE ...]

Reads the Nextflow trace files (tab-separated, columns name and status). A task is identified by
its name (process and tag). In run 2, a task named like one that completed in run 1 should be
CACHED; one that ran again (COMPLETED, FAILED, ...) means a parameter or input of that task changed
between the runs, so its volumes were computed twice. Tasks new in run 2 (the metrics) are counted
apart. MultiQC reports are left out: they read every report of the run, so run 2 rebuilds them.
Exit status 1 when a task of run 1 ran again.
"""

import csv
import sys
from collections import Counter


def read_trace(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def main(run2_path, run1_paths):
    done_in_run1 = {
        row["name"]
        for path in run1_paths
        for row in read_trace(path)
        if row["status"] in ("COMPLETED", "CACHED") and "MULTIQC" not in row["name"]
    }
    run2 = [row for row in read_trace(run2_path) if "MULTIQC" not in row["name"]]
    reused = [row for row in run2 if row["name"] in done_in_run1 and row["status"] == "CACHED"]
    again = [row for row in run2 if row["name"] in done_in_run1 and row["status"] != "CACHED"]
    new = [row for row in run2 if row["name"] not in done_in_run1]

    print(f"run 2 ({run2_path}): {len(reused)} tasks of run 1 reused, {len(again)} computed again, "
          f"{len(new)} new ({', '.join(f'{s} {n}' for s, n in Counter(r['status'] for r in new).items()) or 'none'})")
    for row in again:
        print(f"  computed again: {row['name']} ({row['status']})")
    return 1 if again else 0


if __name__ == "__main__":
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    sys.exit(main(sys.argv[1], sys.argv[2:]))
