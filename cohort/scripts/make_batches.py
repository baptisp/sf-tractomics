"""batches/list.tsv: which subjects each batch holds (columns batch, subject).

Usage: python3 scripts/make_batches.py BATCH_SIZE

A subject is never split between batches, and a batch takes subjects in the order of
inputs/participants.tsv until it holds at least BATCH_SIZE sessions. The list is frozen once
written: a batch's launch folder, cache and archive belong to its subjects, so they never move to
another batch. Subjects added to inputs/participants.tsv later go to new batches after the last
one; a subject listed in batches/list.tsv but no longer in inputs/participants.tsv is an error.
"""

import csv
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PARTICIPANTS = ROOT / "inputs" / "participants.tsv"
LIST = ROOT / "batches" / "list.tsv"


def sessions_by_subject():
    with open(PARTICIPANTS, newline="") as f:
        rows = list(csv.DictReader(f, delimiter="\t"))
    sessions = {}
    for row in rows:
        sessions.setdefault(row["participant_id"], set()).add(row["session"])
    return sessions   # insertion order = file order


def read_list():
    if not LIST.exists():
        return []
    with open(LIST, newline="") as f:
        return [tuple(row) for row in csv.reader(f, delimiter="\t") if row]


def main(batch_size):
    sessions = sessions_by_subject()
    existing = read_list()
    assigned = {subject for _, subject in existing}
    gone = sorted(assigned - set(sessions))
    if gone:
        sys.exit(f"ERROR: batches/list.tsv holds subjects no longer in inputs/participants.tsv: {gone[:5]}")
    new_subjects = [s for s in sessions if s not in assigned]
    if not new_subjects:
        return
    last = max((int(b[1:]) for b, _ in existing), default=0)
    rows, batch, count = [], last + 1, 0
    for subject in new_subjects:
        if count >= batch_size:
            batch, count = batch + 1, 0
        rows.append((f"b{batch:04d}", subject))
        count += len(sessions[subject])
    LIST.parent.mkdir(exist_ok=True)
    tmp = LIST.with_suffix(".tmp")
    with open(tmp, "w", newline="") as f:
        csv.writer(f, delimiter="\t", lineterminator="\n").writerows(existing + rows)
    tmp.replace(LIST)
    print(f"batches/list.tsv: {len(rows)} new subject(s) in batches b{last + 1:04d}-b{batch:04d}")


if __name__ == "__main__":
    if len(sys.argv) != 2 or not sys.argv[1].isdigit() or int(sys.argv[1]) < 1:
        sys.exit(__doc__)
    main(int(sys.argv[1]))
