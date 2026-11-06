"""The tasks of one run that failed for good, one row per task, for a later fix.

Usage: python3 scripts/failure_report.py TRACE WORK OUT [--batch NAME] [--pass PASS] [--run NAME]

A task failure no longer stops its run (configs/*.config: errorStrategy 'ignore' once the retries
are spent), so the other sessions finish; this table is where the failures go instead. TRACE is the
run's Nextflow trace (tab-separated: task_id, hash, name, status, exit), WORK its work folder.

A task is failed for good when its last attempt failed: its rows (one per attempt) share a name and
the sessions of their work folder, and the one with the highest task_id is FAILED. The task's tag
is the subject, so the sessions and runs are read from the file names in the task's .command.sh
(every sub-X_ses-Y[_run-N] it names, comma-separated when several; a T1 task names the T1's run,
a DWI task the DWI's). The error is the last
non-empty line of .command.err (else .command.out).

OUT is always written, with its header even when nothing failed, so every batch has the same
table (scripts/merge_batches.py merges it with the others). Prints
"<failed tasks> <failed sessions>"; exit status 0.
"""

import argparse
import csv
import re
from pathlib import Path

COLUMNS = ["batch", "pass", "run_name", "subject", "session", "run", "process", "exit", "attempts",
           "error", "workdir"]
SAMPLE = re.compile(r"(sub-[A-Za-z0-9]+)_(ses-[A-Za-z0-9]+)(?:_(run-\d+))?")


def task_dir(work, hash_prefix):
    """The work folder of a trace hash (ab/cdef12, the folder name's first 6 characters)."""
    head, _, tail = hash_prefix.partition("/")
    found = sorted((work / head).glob(tail + "*")) if tail and (work / head).is_dir() else []
    return found[0] if len(found) == 1 else None


def samples(folder):
    """(subjects, sessions, runs) named in the task's script, each sorted."""
    text = (folder / ".command.sh").read_text(errors="replace") if folder and (folder / ".command.sh").exists() else ""
    subs, sess, runs = set(), set(), set()
    for m in SAMPLE.finditer(text):
        subs.add(m.group(1))
        sess.add(m.group(2).removeprefix("ses-"))
        if m.group(3):
            runs.add(int(m.group(3).removeprefix("run-")))   # BIDS run-01 and the pipeline's run-1 alike
    return sorted(subs), sorted(sess), [str(r) for r in sorted(runs)]


def last_line(folder):
    for name in (".command.err", ".command.out"):
        f = folder / name if folder else None
        if f and f.exists():
            lines = [line.strip() for line in f.read_text(errors="replace").splitlines() if line.strip()]
            if lines:
                return lines[-1][:300].replace("\t", " ")
    return ""


def main():
    ap = argparse.ArgumentParser(description=__doc__.partition("\n")[0])
    ap.add_argument("trace", type=Path)
    ap.add_argument("work", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--batch", default="")
    ap.add_argument("--pass", dest="pass_name", default="")
    ap.add_argument("--run", default="")
    a = ap.parse_args()

    with open(a.trace, newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    tasks = {}   # (name, sessions) -> attempts, in task_id order
    for row in sorted(rows, key=lambda r: int(r["task_id"])):
        folder = task_dir(a.work, row["hash"])
        subs, sess, runs = samples(folder)
        tasks.setdefault((row["name"], tuple(sess), tuple(runs)), []).append((row, folder, subs))

    failed = []
    for (name, sess, runs), attempts in tasks.items():
        row, folder, subs = attempts[-1]
        if row["status"] != "FAILED":
            continue
        tag = re.search(r"\(([^)]*)\)\s*$", name)
        failed.append({
            "batch": a.batch, "pass": a.pass_name, "run_name": a.run,
            "subject": ",".join(subs) or (tag.group(1) if tag else ""),
            "session": ",".join(sess), "run": ",".join(runs),
            "process": re.sub(r"\s*\([^)]*\)\s*$", "", name).rpartition(":")[2],
            "exit": row.get("exit", ""), "attempts": str(len(attempts)),
            "error": last_line(folder),
            "workdir": str(folder.relative_to(a.work.parent)) if folder else row["hash"],
        })
    failed.sort(key=lambda r: (r["subject"], r["session"], r["run"], r["process"]))

    a.out.parent.mkdir(parents=True, exist_ok=True)
    tmp = a.out.with_name(a.out.name + ".tmp")
    with open(tmp, "w", newline="") as f:
        w = csv.DictWriter(f, COLUMNS, delimiter="\t", lineterminator="\n")
        w.writeheader()
        w.writerows(failed)
    tmp.replace(a.out)
    sessions = {(r["subject"], r["session"]) for r in failed}
    print(len(failed), len(sessions))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
