"""Tests of scripts/passes.py, scripts/make_batches.py and scripts/merge_batches.py, each run on a copy of the repository's
layout in a temporary folder (the scripts find their files from their own location).

Run: python3 tests/test_python.py      (no cluster, no pipeline needed)
"""

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def make_root(tmp, shared, passes, participants=None):
    root = Path(tmp)
    (root / "scripts").mkdir()
    for script in ("passes.py", "make_batches.py", "merge_batches.py"):
        shutil.copy(REPO / "scripts" / script, root / "scripts" / script)
    (root / "params" / "passes").mkdir(parents=True)
    (root / "params" / "shared.yaml").write_text(shared)
    for name, text in passes.items():
        (root / "params" / "passes" / f"{name}.yaml").write_text(text)
    if participants is not None:
        (root / "inputs").mkdir()
        (root / "inputs" / "participants.tsv").write_text(participants)
    return root


def run(root, *args):
    return subprocess.run([sys.executable, str(root / "scripts" / args[0]), *args[1:]],
                          capture_output=True, text=True)


SHARED = "sh_order: 6\nfodf_shells: \"1000\"   # comment\n"


class TestPasses(unittest.TestCase):
    def test_the_real_parameter_files_follow_the_rules(self):
        r = subprocess.run([sys.executable, str(REPO / "scripts" / "passes.py"), "check"],
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_a_pass_runs_with_every_earlier_pass_and_the_shared_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, SHARED, {"1_vol": "run_gm_volumes: true\nrun_noddi: false\n",
                                           "2_met": "run_noddi: true\nrun_roi_metrics: true\n"})
            out = root / "p.yaml"
            r = run(root, "passes.py", "resolve", "2_met", str(out), "--set", "participants_tsv=/x/p.tsv")
            self.assertEqual(r.returncode, 0, r.stderr)
            lines = [l for l in out.read_text().splitlines() if not l.startswith("#")]
            self.assertEqual(lines, ["participants_tsv: /x/p.tsv", "sh_order: 6", 'fodf_shells: "1000"',
                                     "run_gm_volumes: true", "run_noddi: true", "run_roi_metrics: true"])
            r = run(root, "passes.py", "resolve", "1_vol", str(out))
            self.assertNotIn("run_roi_metrics", out.read_text())
            self.assertIn("run_noddi: false", out.read_text())

    def test_the_passes_are_listed_in_numeric_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, SHARED, {"10_late": "a: 1\n", "2_early": "b: 1\n", "1_first": "c: 1\n"})
            self.assertEqual(run(root, "passes.py", "list").stdout.split(), ["1_first", "2_early", "10_late"])

    def refused(self, passes, shared=SHARED, extra=()):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, shared, passes)
            first = sorted(n for n in passes if n[0].isdigit())[0]
            r = run(root, "passes.py", "resolve", first, str(root / "p.yaml"), *extra)
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse((root / "p.yaml").exists())
            return r.stderr

    def test_a_pass_may_not_set_a_shared_parameter(self):
        self.assertIn("params/shared.yaml", self.refused({"1_a": "x: 1\n", "2_b": "sh_order: 8\n"}))

    def test_a_later_pass_may_not_change_a_value(self):
        self.assertIn("may only add", self.refused({"1_a": "subject_roi_min_fraction: 0\n",
                                                    "2_b": "subject_roi_min_fraction: 0.75\n"}))

    def test_a_later_pass_may_not_turn_a_metric_off(self):
        self.assertIn("may only add", self.refused({"1_a": "run_noddi: true\n", "2_b": "run_noddi: false\n"}))

    def test_a_later_pass_may_turn_a_metric_on_or_repeat_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, SHARED, {"1_a": "run_noddi: false\nrun_hoc: true\n",
                                           "2_b": "run_noddi: true\nrun_hoc: true\n"})
            self.assertEqual(run(root, "passes.py", "check").returncode, 0)

    def test_nested_yaml_and_unparsable_lines_are_refused(self):
        self.assertIn("nested", self.refused({"1_a": "a:\n  b: 1\n"}))
        self.assertIn("nested", self.refused({"1_a": "a:\n- 1\n"}))
        self.assertIn("no value", self.refused({"1_a": "a:\n"}))
        self.assertIn("set twice", self.refused({"1_a": "a: 1\na: 2\n"}))

    def test_a_badly_named_or_duplicated_pass_number_is_refused(self):
        self.assertIn("name must be", self.refused({"1_a": "a: 1\n", "x": "b: 1\n"}))
        self.assertIn("share a number", self.refused({"1_a": "a: 1\n", "1_b": "b: 1\n"}))

    def test_run_values_may_not_shadow_a_parameter_file(self):
        self.assertIn("set by run.sh", self.refused({"1_a": "participants_tsv: /y\n"},
                                                    extra=("--set", "participants_tsv=/x")))

    def test_a_quoted_hash_is_not_a_comment(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, SHARED, {"1_a": 'eddy_extra_args: "--x=#1"  # real comment\n'})
            run(root, "passes.py", "resolve", "1_a", str(root / "p.yaml"))
            self.assertIn('eddy_extra_args: "--x=#1"\n', (root / "p.yaml").read_text())


HEADER = "participant_id\tsession\trun\tage\n"


def participants(*subject_sessions):
    return HEADER + "".join(f"{s}\t{ses}\t1\t70\n" for s, n in subject_sessions for ses in range(n))


class TestBatches(unittest.TestCase):
    def batches(self, root):
        return [l.split("\t") for l in (root / "batches" / "list.tsv").read_text().splitlines()]

    def test_subjects_are_never_split_and_batches_fill_to_the_size(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, SHARED, {"1_a": "a: 1\n"},
                             participants(("sub-A", 2), ("sub-B", 1), ("sub-C", 3), ("sub-D", 1)))
            self.assertEqual(run(root, "make_batches.py", "3").returncode, 0)
            self.assertEqual(self.batches(root), [["b0001", "sub-A"], ["b0001", "sub-B"],
                                                  ["b0002", "sub-C"], ["b0003", "sub-D"]])

    def test_the_list_is_frozen_and_new_subjects_go_to_new_batches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, SHARED, {"1_a": "a: 1\n"}, participants(("sub-A", 1)))
            run(root, "make_batches.py", "3")
            (root / "inputs" / "participants.tsv").write_text(participants(("sub-Z", 1), ("sub-A", 1), ("sub-B", 1)))
            self.assertEqual(run(root, "make_batches.py", "3").returncode, 0)
            self.assertEqual(self.batches(root), [["b0001", "sub-A"], ["b0002", "sub-Z"], ["b0002", "sub-B"]])
            before = (root / "batches" / "list.tsv").read_text()
            run(root, "make_batches.py", "1")
            self.assertEqual((root / "batches" / "list.tsv").read_text(), before)

    def test_a_subject_removed_from_the_inputs_is_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, SHARED, {"1_a": "a: 1\n"}, participants(("sub-A", 1), ("sub-B", 1)))
            run(root, "make_batches.py", "5")
            (root / "inputs" / "participants.tsv").write_text(participants(("sub-A", 1)))
            r = run(root, "make_batches.py", "5")
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("sub-B", r.stderr)


class TestMerge(unittest.TestCase):
    """merge_batches.py reads each batch's extracted_results.tar.gz, or out/metrics/ for a batch
    packed before out/ was archived"""

    def batch_with_extracted(self, root, name, tables):
        import io
        import tarfile
        b = root / "batches" / name
        b.mkdir(parents=True)
        with tarfile.open(b / "extracted_results.tar.gz", "w:gz") as tar:
            for rel, text in tables.items():
                data = text.encode()
                info = tarfile.TarInfo(rel)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))

    def test_extracted_and_legacy_batches_are_merged_in_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, SHARED, {})
            self.batch_with_extracted(root, "b0001", {
                "metrics/vol.tsv": "sid\tv\nA\t1\n", "metrics/comparison/c.csv": "sid,c\nA,9\n",
                "multiqc/report.html": "<html>"})
            legacy = root / "batches" / "b0002" / "out" / "metrics"
            legacy.mkdir(parents=True)
            (legacy / "vol.tsv").write_text("sid\tv\nB\t2")   # no final newline
            r = run(root, "merge_batches.py")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual((root / "merged" / "vol.tsv").read_text(), "sid\tv\nA\t1\nB\t2\n")
            self.assertEqual((root / "merged" / "comparison" / "c.csv").read_text(), "sid,c\nA,9\n")
            self.assertIn("missing in 1 batch(es): b0002", r.stdout)
            self.assertFalse((root / "merged" / "report.html").exists())

    def test_a_table_whose_header_differs_is_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = make_root(tmp, SHARED, {})
            self.batch_with_extracted(root, "b0001", {"metrics/vol.tsv": "sid\tv\nA\t1\n"})
            self.batch_with_extracted(root, "b0002", {"metrics/vol.tsv": "sid\tw\nB\t2\n"})
            r = run(root, "merge_batches.py")
            self.assertEqual(r.returncode, 1)
            self.assertIn("headers differ between batches: vol.tsv", r.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
