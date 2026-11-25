"""Regression tests for the Flutter CI planner and required-check evidence."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from textwrap import dedent
import unittest
from unittest.mock import patch

import ci_flutter as ci


class FlutterCITest(unittest.TestCase):
    def setUp(self):
        # Test Git writes must stay in the disposable fixture even if the
        # caller is reviewing the candidate with a throwaway index/object dir.
        routing = subprocess.check_output(["git", "rev-parse", "--local-env-vars"], text=True).splitlines()
        isolated = patch.dict(os.environ)
        isolated.start()
        self.addCleanup(isolated.stop)
        for variable in routing:
            os.environ.pop(variable, None)
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name).resolve()
        self.client = self.root / "client"
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.run_git("init", "-q")
        self.assertEqual(self.run_git("rev-parse", "--show-toplevel").stdout.decode().strip(), str(self.root))
        self.vm = [f"test/{name}_test.dart" for name in ("a", "b", "c", "d", "e")]
        for path in self.vm:
            self.write_test(path)
        for path in ci.BROWSER_ONLY:
            self.write_test(path, "@TestOn('browser')\nlibrary;\n")
        self.run_git("add", "client")

    def run_git(self, *args):
        return subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def write_test(self, path, text="void main() {}\n"):
        file = self.client / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)

    def test_plan_is_complete_and_admits_future_nested_vm_file(self):
        future = "test/new dir/nested/new_test.dart"
        self.write_test(future)
        self.write_test("test/untracked_test.dart")
        self.write_test("test/helper.dart")
        self.run_git("add", f"client/{future}", "client/test/helper.dart")
        plan = ci.plan(self.client)
        self.assertEqual(ci.plan(self.client), plan)
        self.assertEqual(len(plan), ci.SHARD_COUNT)
        self.assertCountEqual([path for shard in plan for path in shard], self.vm + [future])
        self.assertTrue(all(plan))

    def test_browser_exception_does_not_hide_a_vm_test_or_stale_path(self):
        path = next(iter(ci.BROWSER_ONLY))
        self.write_test(path)
        with self.assertRaisesRegex(ValueError, "browser-only"):
            ci.plan(self.client)
        self.run_git("rm", "-f", f"client/{path}")
        with self.assertRaisesRegex(ValueError, "browser-only"):
            ci.plan(self.client)

    def report(self, files):
        events = [{"type": "start", "protocolVersion": "0.1.1"},
                  {"type": "allSuites", "count": len(files)}]
        for index, path in enumerate(files):
            events.extend([
                {"type": "suite", "suite": {"id": index, "path": str(self.client / path), "platform": "vm"}},
                {"type": "testStart", "test": {"id": index, "suiteID": index, "name": "a case"}},
                {"type": "testDone", "testID": index, "result": "success", "hidden": False, "skipped": False},
            ])
        events.append({"type": "done", "success": True})
        return events

    def write_artifacts(self):
        for index, files in enumerate(ci.plan(self.client)):
            at = self.artifacts / f"client-vm-shard-{index}"
            at.mkdir()
            self.write_report(at, self.report(files))
            covered = {1: index, index + 2: 1, 20: 0}
            (at / "lcov.info").write_text("SF:lib/demo.dart\n" + "".join(
                f"DA:{line},{hits}\n" for line, hits in covered.items()
            ) + f"LF:3\nLH:{sum(hits > 0 for hits in covered.values())}\nend_of_record\n")
            self.seal(at, index)

    @staticmethod
    def write_report(at, events):
        (at / "machine.jsonl").write_text("one non-event diagnostic\n" + "".join(json.dumps(e) + "\n" for e in events))

    def seal(self, at, index):
        receipt = {"sha": "a" * 40, "run_id": "7", "shard": index, "client_root": str(self.client),
                   "sha256": {name: hashlib.sha256((at / name).read_bytes()).hexdigest()
                              for name in ("machine.jsonl", "lcov.info")}}
        (at / "receipt.json").write_text(json.dumps(receipt) + "\n")

    def join(self):
        return ci.collect(self.client, self.artifacts, "a" * 40, "7")

    def test_joins_actual_lcov_keys_and_sums_hits(self):
        self.write_artifacts()
        coverage, passed, skipped = self.join()
        self.assertEqual(coverage, {"lib/demo.dart": {1: 6, 2: 1, 3: 1, 4: 1, 5: 1, 20: 0}})
        self.assertEqual((passed, skipped), (len(self.vm), 0))
        output = self.root / "merged.info"
        ci.write_lcov(output, coverage)
        self.assertEqual(ci.read_lcov(output), coverage)
        self.assertIn("LF:6\nLH:5\nend_of_record\n", output.read_text())

    def test_missing_or_unexpected_shard_is_not_a_success(self):
        self.write_artifacts()
        (self.artifacts / "client-vm-shard-1").rename(self.artifacts / "client-vm-shard-4")
        with self.assertRaisesRegex(ValueError, "artifact names"):
            self.join()

    def test_changed_digest_and_wrong_run_fail(self):
        self.write_artifacts()
        at = self.artifacts / "client-vm-shard-0"
        (at / "machine.jsonl").write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "digest"):
            self.join()
        self.seal(at, 1)
        with self.assertRaisesRegex(ValueError, "identity"):
            self.join()
        self.seal(at, 0)
        receipt = json.loads((at / "receipt.json").read_text())
        receipt["run_id"] = "8"
        (at / "receipt.json").write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, "identity"):
            self.join()

    def test_truncated_or_failing_machine_is_refused_even_if_resealed(self):
        self.write_artifacts()
        at = self.artifacts / "client-vm-shard-0"
        files = ci.plan(self.client)[0]
        events = self.report(files)
        for wrong in (events[:-1], events[: -2] + events[-1:],
                      events[:-1] + [{"type": "done", "success": False}],
                      self.report(ci.plan(self.client)[1]),
                      events + [{"type": "print"}]):
            with self.subTest(events=wrong):
                self.write_report(at, wrong)
                self.seal(at, 0)
                with self.assertRaisesRegex(ValueError, "machine"):
                    self.join()

    def test_truncated_lcov_record_and_incorrect_line_totals_are_refused(self):
        self.write_artifacts()
        at = self.artifacts / "client-vm-shard-0"
        path = at / "lcov.info"
        lcov = path.read_text()
        for wrong in (lcov.removesuffix("end_of_record\n"), lcov.replace("LF:3", "LF:4"),
                      lcov.replace("DA:1,0", "DA:1,0\nDA:1,2"), lcov + lcov,
                      lcov.replace("lib/demo.dart", "../lib/demo.dart")):
            with self.subTest(lcov=wrong):
                path.write_text(wrong)
                self.seal(at, 0)
                with self.assertRaisesRegex(ValueError, "LCOV"):
                    self.join()

    def test_required_status_admits_only_success(self):
        for result in ("failure", "cancelled", "skipped", "", "SUCCESS"):
            for index in range(3):
                with self.subTest(result=result, lane=index):
                    lanes = ["success"] * 3
                    lanes[index] = result
                    with self.assertRaisesRegex(ValueError, "Flutter prerequisite"):
                        ci.require(*lanes)
        ci.require("success", "success", "success")

    def test_nonzero_flutter_process_cannot_seal_a_successful_report(self):
        expected = ci.plan(self.client)[0]
        self.write_report(self.root, self.report(expected))
        shim = self.root / "flutter"
        shim.write_text(f'#!/bin/sh\ncat "{self.root / "machine.jsonl"}"\nexit 1\n')
        shim.chmod(0o755)
        output = self.artifacts / "new"
        with patch.dict(os.environ, PATH=f"{self.root}{os.pathsep}{os.environ['PATH']}"), \
                patch("sys.stdout"), patch("sys.stderr"):
            with self.assertRaisesRegex(ValueError, "exited 1"):
                ci.run_shard(self.client, 0, output, "a" * 40, "7")
        self.assertEqual(ci.read_machine(output / "machine.jsonl", self.client, expected),
                         [(file, "a case", False) for file in expected])
        self.assertFalse((output / "receipt.json").exists())


class FlutterJoinWorkflowTest(unittest.TestCase):
    def test_join_requires_web_success_from_the_event_owned_producer(self):
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ci.yml").read_text()
        join = workflow.split("\n  client:\n", 1)[1]
        gate = join.split("      - name: Require all Flutter lanes\n", 1)[1].split("      - name:", 1)[0]
        command = gate.split("        run: ", 1)[1]
        if command.startswith("|\n"):
            command = dedent(command[2:])
        results = ("success", "failure", "skipped", "cancelled", "", "SUCCESS")
        for event, standalone, folded in [("pull_request", "skipped", result) for result in results] + [
            ("pull_request", result, "success") for result in results if result != "skipped"
        ] + [("push", result, "success") for result in results] + [("push", "success", "")]:
            expected = (standalone, folded) == ("skipped", "success") if event == "pull_request" else standalone == "success"
            with self.subTest(event=event, standalone=standalone, folded=folded):
                proc = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", command], cwd=root,
                                      env=dict(os.environ, CI_EVENT=event, VM_RESULT="success", CONTRACTS_RESULT="success",
                                               WEB_RESULT=standalone, FOLDED_WEB_OUTCOME=folded), capture_output=True, text=True)
                self.assertEqual(proc.returncode, 0 if expected else 1, proc.stderr)


if __name__ == "__main__":
    unittest.main()
