#!/usr/bin/env python3
"""Regression tests for backend CI inventory, terminal and coverage admission."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import ci_backend as ci
from ci_backend_fixtures import fixtures, test_environment


MODULE = "example.test/backend"
API = MODULE + "/internal/api"
SOURCE = "a" * 40


def events(pkg, tests, result="pass"):
    def event(action, case=None, **fields):
        item = {"Action": action, "Package": pkg}
        if case is not None:
            item["Test"] = case
        return json.dumps(item | fields) + "\n"

    summary = (f"?   \t{pkg}\t[no test files]\n" if result == "skip" else
               f"ok  \t{pkg}\t1.000s\tcoverage: 100.0% of statements\n")
    return [event("start"), *(line for name, terminal in tests for line in (event("run", name), event(terminal, name))),
            event("output", Output=summary), event(result)]


def row(pkg, count=1, *, statements=2, end=4):
    return f"{pkg}/production.go:2.1,3.{end} {statements} {count}\n"


class ContractTests(unittest.TestCase):
    def setUp(self):
        stub = {"internal/api": {ci.CEILING_TEST, "TestFuture/marker"}}
        self.addCleanup(patch.stopall)
        patch.object(ci, "REQUIRED", stub).start()
        self.packages = {f"{MODULE}/{pkg}": "test" for group in ci.SHARDS.values() for pkg in group}
        self.packages[f"{MODULE}/internal/new"] = "test"
        self.packages[f"{MODULE}/internal/empty"] = "empty"
        self.inventory = {"module": MODULE, "packages": self.packages, "source": SOURCE, "go": ci.GO_VERSION}
        self.names = sorted([ci.CEILING_TEST, "TestFuture", "TestWeeklyFuture", "TestPlaylistFuture",
                             "ExampleFuture", "FuzzFuture"])

    def test_new_package_and_api_tests_route_once(self):
        groups = ci.partition(self.inventory)
        self.assertEqual(set(groups["remaining"]), {f"{MODULE}/internal/empty", f"{MODULE}/internal/new"})
        package_owners = [pkg for group in groups.values() for pkg in group]
        self.assertEqual(sorted(package_owners), sorted(self.packages))
        groups = ci.api_partition(self.names)
        self.assertEqual(groups["api"], ["ExampleFuture", "FuzzFuture", "TestFuture"])
        self.assertEqual(groups["api-playlists"], ["TestPlaylistFuture"])
        self.assertEqual(groups["api-weekly"], ["TestWeeklyFuture"])
        self.assertEqual(groups["api-weekly-ceiling"], [ci.CEILING_TEST])
        self.assertEqual(sorted(test for group in groups.values() for test in group), self.names)

    def test_bad_inventories_fail(self):
        for bad in [[], self.names + self.names[:1], [name for name in self.names if name != "TestFuture"],
                    [name for name in self.names if not name.startswith("TestWeeklyFuture")]]:
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                ci.api_partition(bad)
        with self.assertRaisesRegex(ValueError, "empty or no-test-only"):
            ci.partition(self.inventory | {"packages": self.packages | {f"{MODULE}/internal/new": "empty"}})

    def test_terminals_cannot_skip_required_marker_or_disappear(self):
        passed = [("TestFuture", "pass"), ("TestFuture/marker", "pass")]
        positive = events(API, passed)
        self.assertEqual(len(ci.read_tests(positive, {API: "test"}, MODULE, ["TestFuture"])[0]), 2)
        for bad, message in [
            (positive[:-1], "incomplete"),
            ([*positive[:-2], positive[-1]], "missing Go package summary"),
            (events(API, passed + passed), "duplicate"),
            (events(API, passed[:-1]), "fixture test did not pass"),
            (events(API, [passed[0], ("TestFuture/marker", "skip")]), "fixture test did not pass"),
            (events(API, passed + [("TestOtherShard", "pass")]), "complete shard selection"),
            (events(API, []), "complete shard selection"),
            (events(API, passed, result="fail"), "package did not pass"),
        ]:
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                ci.read_tests(bad, {API: "test"}, MODULE, ["TestFuture"])

    def test_coverage_rejects_bad_mode_empty_zero_foreign_or_duplicate(self):
        for lines, message in [
            (["mode: count\n", row(API)], "atomic"),
            (["mode: atomic\n"], "empty or zero"),
            (["mode: atomic\n", row(API, 0)], "empty or zero"),
            (["mode: atomic\n", row(MODULE + "/other")], "foreign"),
            (["mode: atomic\n", row(API), row(API)], "duplicate"),
            (["mode: atomic\n", row(API, 2**32)], "range or counter"),
        ]:
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                ci.read_cover(iter(lines), {API: "test"})

    def test_split_api_counters_sum_only_on_exact_statement_geometry(self):
        def cover(data):
            return ci.read_cover(iter(["mode: atomic\n", data]), {API: "test"})
        self.assertEqual(list(ci.merge_api_coverage(cover(row(API, 3)), cover(row(API, 5))).values()), [(2, 8)])
        with self.assertRaisesRegex(ValueError, "range inventory"):
            ci.merge_api_coverage(cover(row(API)), cover(row(API, end=5)))
        with self.assertRaisesRegex(ValueError, "statement geometry"):
            ci.merge_api_coverage(cover(row(API)), cover(row(API, statements=3)))

    def test_join_rejects_missing_or_misbound_artifacts(self):
        groups = ci.partition(self.inventory)
        api_groups = ci.api_partition(self.names)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inputs = root / "inputs"
            inputs.mkdir()
            for index, shard in enumerate((*ci.API_SHARDS, *(s for s in groups if s != "api"))):
                out = inputs / f"backend-go-{shard}"
                out.mkdir()
                assigned = groups["api" if shard in ci.API_SHARDS else shard]
                tests, coverage = [], ["mode: atomic\n"]
                for pkg, kind in assigned.items():
                    names = api_groups[shard] if shard in api_groups else ["TestAny"] if kind == "test" else []
                    if "TestFuture" in names:
                        names = [*names, "TestFuture/marker"]
                    tests.extend(events(pkg, [(name, "pass") for name in names], "pass" if names else "skip"))
                    if names:
                        coverage.append(row(pkg, index + 1))
                (out / "tests.jsonl").write_text("".join(tests))
                (out / "coverage.out").write_text("".join(coverage))
                record = {
                    "shard": shard, "go_exit": 0, "inventory": self.inventory, "api_tests": self.names,
                    "fixture": {"retired": True, "owner": shard, "containers": [shard + "pg", shard + "redis"]},
                    "sha256": ci.artifact_hashes(out),
                }
                (out / "receipt.json").write_text(json.dumps(record))
            with contextlib.redirect_stdout(io.StringIO()):
                ci.merge(inputs, root / "combined.out", SOURCE)
                self.assertIn(row(API, 10), (root / "combined.out").read_text())
                with self.assertRaisesRegex(ValueError, "source or Go package inventory mismatch"):
                    ci.merge(inputs, root / "stale.out", "b" * 40)
                target = inputs / "backend-go-api"
                coverage = target / "coverage.out"
                original = coverage.read_text()
                coverage.write_text("mode: atomic\n")
                with self.assertRaisesRegex(ValueError, "digest mismatch"):
                    ci.merge(inputs, root / "truncated.out", SOURCE)
                coverage.write_text(original)
                target.rename(root / target.name)
                with self.assertRaisesRegex(ValueError, "artifact inventory"):
                    ci.merge(inputs, root / "missing.out", SOURCE)

    def test_ambient_endpoint_and_protection_override_are_not_admitted(self):
        with patch.dict(os.environ, {"DATABASE_URL": "not-a-test-endpoint", "OMP_CONNECT_POSTGRES_DSN": "ambient",
                                     "REDIS_URL": "ambient", "PGHOST": "ambient", "GOFLAGS": "-run=foo",
                                     "OMP_ALLOW_PROTECTED_DB_TESTS": "1"}):
            self.assertFalse(set(test_environment()) & {"DATABASE_URL", "REDIS_URL", "PGHOST", "GOFLAGS",
                                                        "OMP_ALLOW_PROTECTED_DB_TESTS", "OMP_CONNECT_POSTGRES_DSN"})
            with patch("ci_backend_fixtures.docker") as docker_mock:
                with self.assertRaisesRegex(ValueError, "protection override"), fixtures({}):
                    self.fail("override reached provisioning")
                docker_mock.assert_not_called()


class GoEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        cls.root = Path(temporary.name)
        backend = cls.root / "backend"
        sources = {
            "go.mod": f"module {MODULE}\n\ngo {ci.GO_VERSION.removeprefix('go')}\n",
            "tested/p.go": "package tested\nfunc Value() int { return 1 }\nfunc Empty() {}\n",
            "tested/p_test.go": 'package tested\nimport "testing"\nfunc TestValue(t *testing.T) { Value() }\n',
            "bench/p.go": "package bench\nfunc Value() int { return 1 }\n",
            "bench/p_test.go": 'package bench_test\nimport "testing"\nfunc BenchmarkValue(b *testing.B) {}\n',
            "empty/p.go": "package empty\nconst Value = 1\n",
            "emptytest/p.go": "package emptytest\nconst Value = 1\n",
            "emptytest/p_test.go": 'package emptytest\nimport "testing"\nfunc TestValue(t *testing.T) {}\n',
            "untested/p.go": "package untested\nfunc Value() int { return 1 }\n",
            "raceonly/p.go": "//go:build race\n\npackage raceonly\nfunc Value() int { return 1 }\n",
            "raceonly/p_test.go": ('//go:build race\n\npackage raceonly\nimport "testing"\n'
                                   'func TestRace(t *testing.T) { Value() }\n'),
            "norace/p.go": "//go:build !race\n\npackage norace\nconst Value = 1\n",
            "skipped/p.go": "package skipped\nconst Value = 1\n",
            "skipped/p_test.go": ('package skipped\nimport "testing"\n'
                                  'func TestSkipped(t *testing.T) { t.Skip("control") }\n'),
        }
        for name, text in sources.items():
            target = backend / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(text)
        cls.group = {f"{MODULE}/{name}": kind for name, kind in (
            ("tested", "test"), ("bench", "test"), ("empty", "empty"), ("emptytest", "test"),
            ("untested", "empty"), ("raceonly", "test"),
        )}
        with (cls.root / "tests.jsonl").open("w") as output:
            subprocess.run(["go", "test", "-race", "-json", "-v", "-count=1",
                            f"-coverprofile={cls.root / 'coverage.out'}", *cls.group, f"{MODULE}/skipped"],
                           cwd=backend, env=test_environment(), stdout=output, check=True)
        cls.events = {}
        for line in (cls.root / "tests.jsonl").read_text().splitlines():
            pkg = json.loads(line).get("Package")
            if pkg is not None:
                cls.events.setdefault(pkg, []).append(line + "\n")
        cls.profile = (cls.root / "coverage.out").read_text().splitlines(keepends=True)

    def test_inventory_uses_race_build_constraints(self):
        check_output = subprocess.check_output

        def resolve(command, **kwargs):
            return SOURCE if command == ["git", "rev-parse", "HEAD"] else check_output(command, **kwargs)

        with patch.object(ci, "ROOT", self.root), patch.object(ci.subprocess, "check_output", side_effect=resolve):
            self.assertEqual(ci.go_inventory()["packages"], self.group | {f"{MODULE}/skipped": "test"})

    def test_benchmark_only_is_not_an_all_skipped_or_missing_test_package(self):
        bench, skipped, tested = (f"{MODULE}/{name}" for name in ("bench", "skipped", "tested"))
        ci.read_tests(self.events[bench], {bench: "test"}, MODULE)
        partial = [line for line in self.events[tested] if "Test" not in json.loads(line)]
        for pkg, lines in [(skipped, self.events[skipped]), (tested, partial)]:
            with self.subTest(pkg=pkg), self.assertRaisesRegex(ValueError, "no passing tests"):
                ci.read_tests(lines, {pkg: "test"}, MODULE)
        with patch.object(ci, "REQUIRED", {"bench": {"TestRequired"}}):
            with self.assertRaisesRegex(ValueError, "fixture test did not pass"):
                ci.read_tests(self.events[bench], {bench: "test"}, MODULE)

    def test_coverage_requires_coverable_packages_even_without_test_files(self):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            (out / "tests.jsonl").write_text("".join(line for pkg in self.group for line in self.events[pkg]))
            cover = out / "coverage.out"
            # No rows for declarations-only packages with or without tests.
            # Real no-test and benchmark-only packages do contribute zero-hit rows.
            self.assertEqual({line.split(":")[0].rsplit("/", 1)[0] for line in self.profile[1:]},
                             {f"{MODULE}/{name}" for name in ("tested", "untested", "bench", "raceonly")})
            cover.write_text("".join(self.profile))
            _, blocks = ci.validate(out, self.group, MODULE)
            self.assertIn((0, 0), blocks.values())
            self.assertEqual({key[0].rsplit("/", 1)[0] for key, (statements, count) in blocks.items()
                              if statements and count == 0}, {f"{MODULE}/bench", f"{MODULE}/untested"})
            for omitted in ("untested", "bench", "raceonly"):
                cover.write_text("".join(line for line in self.profile if not line.startswith(f"{MODULE}/{omitted}/")))
                with self.subTest(omitted=omitted), self.assertRaisesRegex(ValueError, rf"missing Go coverage.*{MODULE}/{omitted}"):
                    ci.validate(out, self.group, MODULE)


if __name__ == "__main__":
    unittest.main()
