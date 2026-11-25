"""Run and verify the backend CI split (Python standard library)."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

from ci_backend_fixtures import fixtures, test_environment

ROOT = Path(__file__).resolve().parents[1]
PINNED_GO = re.search(r"^go (\S+)$", (ROOT / "backend/go.mod").read_text(), re.M)
if PINNED_GO is None:
    raise ValueError("backend/go.mod must pin the Go version")
GO_VERSION = "go" + PINNED_GO[1]
SHARDS = {
    "api": {"internal/api"},
    "database": {"internal/db"},
    "provider": {"internal/musicbrainz"},
    "application": {"cmd/server", "internal/auth", "internal/discovery", "internal/jam",
                    "internal/research", "internal/search"},
    "remaining": set(),
}
API_SHARDS = ("api", "api-playlists", "api-weekly", "api-weekly-ceiling")
CEILING_TEST = "TestWeeklyExportNearStorageCeilingEscapedMetadata"
PLAYLIST_PREFIXES = ("TestPlaylist", "TestMix", "TestManualSync", "TestSmartReorder", "TestAutoBlend",
                     "TestCreateAutoMix", "TestCreateMix")
# Unlike a package PASS, these require real fixture-backed work. Protection
# probes that also pass without a DB must prove the marker subtest explicitly.
REQUIRED = {
    "cmd/server": {
        "TestJamProductionConfiguredCompositionHTTP",
        "TestJamProductionFixtureProtection/root_marker_before_schema",
        "TestPrivateImportNotInGlobalMaintenanceCandidates",
        "TestReleaseRadarNormalConstructorRegisteredDailyAndDeliberateSearchUnchanged",
    },
    "internal/api": {
        "TestConnectRoutesRealInfra", "TestConnectRouterFixtureProtection/root_marker_before_schema",
        "TestJamHTTPRealLocalFlow", "TestJamIntegrationFixtureProtection/root_marker_before_schema",
        "TestPlaylistFixtureProtection/root_marker_before_schema", "TestPlaylistMixIntegrationCreatesOrderedMixPlan",
        "TestLibraryPrivateFence", "TestManualSyncPipeline", "TestManualSyncBootRecovery",
        "TestWeeklyAuthenticatedDurableTracer", "TestReleaseRadarRealAccountProjectionToWire",
        CEILING_TEST,
    },
    "internal/auth": {
        "TestConnectLogoutGenerationAgainstPostgres", "TestConnectAuthFixtureProtection/root_marker_before_schema",
    },
    "internal/connect": {"TestConnectRegisterListAgainstRedis"},
    "internal/db": {
        "TestMigrateCreatesUnprotectedEnvironmentMarker", "TestEnvironmentMarkerProtectionRefusesDestructiveSetup",
        "TestProtectedDatabaseGuardStopsRealTruncatingHelper", "TestNearbyTracksUsesEffectiveAnalysisIndexAtTenThousandTracks",
    },
    "internal/discovery": {"TestRadarDailyStartupSchemaIdempotenceAndAccountDeletion"},
    "internal/download": {"TestQueue_EnqueueDequeue", "TestSourceCompletionAtomicRetirement"},
    "internal/jam": {
        "TestPostgresGuestFlowRetriesAndReceipts", "TestJamRedisLimiterAtomicBoundedFailClosed",
        "TestJamRepositoryFixtureProtection/root_marker_before_schema",
    },
    "internal/playlistimport": {"TestAssociateItemSourceEntriesBatchesBackfillAndRollsBackConflicts"},
    "internal/queue": {"TestRedisQueueAtomicMutations"},
    "internal/research": {"TestPostgresVariantAssignmentPersistsAcrossRetryAndRecovery"},
    "internal/search": {"TestUnifiedSearchReturnsSectionedBody"},
    "internal/stems": {"TestQueueAgainstRedisEnqueuesDedupesAndBackpressures"},
}
COVER_ROW = re.compile(r"(\S+\.go):(\d+)\.(\d+),(\d+)\.(\d+) ([0-9]+) ([0-9]+)")
COVER_SUMMARY = re.compile(r"coverage: (\d+\.\d% of statements|\[no statements\])( \[no tests to run\])?")


def require(ok, message):
    if not ok:
        raise ValueError(message)


def partition(inventory):
    module, packages = inventory["module"], inventory["packages"]
    require(module and packages and all(
        (pkg == module or pkg.startswith(module + "/")) and has_tests in ("test", "empty")
        for pkg, has_tests in packages.items()
    ), "invalid Go package inventory")
    explicit = {f"{module}/{pkg}": shard for shard, group in SHARDS.items() for pkg in group}
    require(len(explicit) == sum(map(len, SHARDS.values())), "explicit package has multiple shards")
    require(set(explicit) | {f"{module}/{p}" for p in REQUIRED} <= packages.keys(),
            "expected Go package missing; review the shard and fixture contracts")
    groups = {shard: {} for shard in SHARDS}
    for pkg in sorted(packages):
        groups[explicit.get(pkg, "remaining")][pkg] = packages[pkg]
    require(all(any(kind == "test" for kind in group.values()) for group in groups.values()),
            "empty or no-test-only Go shard")
    return groups


def go_inventory():
    def go(*args):
        return subprocess.check_output(["go", *args], cwd=ROOT / "backend", env=test_environment(), text=True).strip()

    require(go("env", "GOVERSION") == GO_VERSION, f"backend must use {GO_VERSION}")
    source = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    module = go("list", "-m")
    rows = [line.split() for line in go(
        "list", "-race", "-f", "{{.ImportPath}} {{if or .TestGoFiles .XTestGoFiles}}test{{else}}empty{{end}}", "./...",
    ).splitlines()]
    packages = dict(rows)
    require(len(rows) == len(packages), "duplicate Go package in go list")
    return {"source": source, "go": GO_VERSION, "module": module, "packages": packages}


def api_partition(names):
    require(names == sorted(set(names)) and all(re.fullmatch(r"(?:Test|Example|Fuzz)\w*", name, re.ASCII)
                                                for name in names), "invalid API test inventory")
    require({case.split("/", 1)[0] for case in REQUIRED.get("internal/api", ())} <= set(names),
            "API inventory is missing a required test")
    groups = {shard: [] for shard in API_SHARDS}
    for name in names:
        shard = ("api-weekly-ceiling" if name == CEILING_TEST else
                 "api-weekly" if name.startswith("TestWeekly") else
                 "api-playlists" if name.startswith(PLAYLIST_PREFIXES) else "api")
        groups[shard].append(name)
    require(all(groups.values()), "API test shard has no cases")
    return groups


def list_api_tests(pkg, env):
    result = subprocess.check_output(["go", "test", "-race", "-cover", "-covermode=atomic", "-list", ".", pkg],
                                     cwd=ROOT / "backend", env=env, text=True)
    lines = result.splitlines()
    require(lines and lines[-1].split()[:2] == ["ok", pkg], "API listing lacks package success")
    # Benchmarks are not run by the predecessor's ordinary Go test invocation.
    return sorted(line for line in lines[:-1] if not line.startswith("Benchmark"))


def read_tests(lines, group, module, selected=None):
    starts, ends = set(), {}
    running, terminal = set(), {}
    summaries = {}
    for line in lines:
        event = json.loads(line)
        action, pkg, case = event["Action"], event.get("Package"), event.get("Test")
        require(action != "build-fail", f"Go build failed: {event}")
        if action == "build-output":
            continue
        require(pkg in group and pkg not in ends, f"unexpected or already finished Go package: {pkg}")
        if case is not None:
            key = (pkg, case)
            require(pkg in starts, f"test before package start: {key}")
            if action == "run":
                require(key not in running and key not in terminal, f"duplicate Go test start: {key}")
                running.add(key)
            elif action in ("pass", "skip", "fail"):
                require(key in running, f"Go test terminal without start: {key}")
                running.remove(key)
                terminal[key] = action
        elif action == "start":
            require(pkg not in starts, f"duplicate Go package start: {pkg}")
            starts.add(pkg)
        elif action == "output":
            # Go 1.25.3 reports package coverage separately from the merged
            # profile, including for packages with no test files. Use the
            # package summary, not arbitrary coverage text from individual tests.
            fields = event["Output"].rstrip("\n").split("\t")
            if len(fields) >= 3 and fields[1] == pkg:
                if fields == ["?   ", pkg, "[no test files]"] and group[pkg] == "empty":
                    summary = (False, False)
                elif (len(fields) == 4 and
                      (fields[0] == "ok  " or (fields[0] == fields[2] == "" and group[pkg] == "empty"))):
                    match = COVER_SUMMARY.fullmatch(fields[3])
                    if match is None:
                        raise ValueError(f"invalid Go coverage summary: {pkg}")
                    summary = (match[1] != "[no statements]", bool(match[2]))
                else:
                    continue
                require(pkg not in summaries, f"duplicate Go package summary: {pkg}")
                summaries[pkg] = summary
        elif action in ("pass", "skip", "fail"):
            require(pkg in starts, f"Go package terminal without start: {pkg}")
            ends[pkg] = action
    require(starts == ends.keys() == group.keys() and not running, "incomplete Go package/test events")
    require(all(result == "pass" or (result == "skip" and group[pkg] == "empty") for pkg, result in ends.items()),
            f"Go package did not pass: {ends}")
    require("fail" not in terminal.values(), "Go test failed")
    if selected is not None:
        require(len(group) == 1 and {case for _, case in terminal if "/" not in case} == set(selected),
                "API test terminals do not match the complete shard selection")
    require(summaries.keys() == group.keys(), "missing Go package summary")
    for pkg, kind in group.items():
        if kind == "test":
            results = [result for (owner, _), result in terminal.items() if owner == pkg]
            # Without a selector, Go's explicit no-tests result covers
            # benchmark-only packages. It is not an all-skipped test run.
            no_cases = selected is None and not results and summaries[pkg][1]
            require("pass" in results or no_cases, f"no passing tests in {pkg}")
        for case in REQUIRED.get(pkg.removeprefix(module + "/"), ()):
            if selected is None or case.split("/", 1)[0] in selected:
                require(terminal.get((pkg, case)) == "pass", f"fixture test did not pass: {pkg}/{case}")
    return terminal, {pkg for pkg, (coverable, _) in summaries.items() if coverable}


def read_cover(lines, group):
    require(next(lines, "").strip() == "mode: atomic", "Go coverage must use atomic counters")
    blocks = {}
    for line in lines:
        match = COVER_ROW.fullmatch(line.rstrip("\n"))
        if match is None:
            raise ValueError(f"invalid Go coverage row: {line!r}")
        filename, *numbers = match.groups()
        start_line, start_col, end_line, end_col, statements, counter = map(int, numbers)
        geometry = (filename, start_line, start_col, end_line, end_col)
        require(filename.rsplit("/", 1)[0] in group, f"foreign Go coverage path: {filename}")
        require(0 < min(start_line, start_col, end_line, end_col) and
                (start_line, start_col) <= (end_line, end_col) and 0 <= counter < 2**32,
                f"invalid Go coverage range or counter: {geometry}")
        require(geometry not in blocks, f"duplicate Go coverage block: {geometry}")
        blocks[geometry] = (statements, counter)
    require(any(statements and counter for statements, counter in blocks.values()), "empty or zero Go coverage shard")
    return blocks


def validate(out, group, module, selected=None):
    with (out / "tests.jsonl").open() as lines:
        tests, coverable = read_tests(lines, group, module, selected)
    with (out / "coverage.out").open() as lines:
        coverage = read_cover(lines, group)
    represented = {block[0].rsplit("/", 1)[0] for block, (statements, _) in coverage.items() if statements}
    missing = coverable - represented
    require(not missing, f"missing Go coverage for packages: {sorted(missing)}")
    return tests, coverage


def artifact_hashes(out):
    return {name: hashlib.sha256((out / name).read_bytes()).hexdigest() for name in ("tests.jsonl", "coverage.out")}


def run(shard, out):
    out.mkdir()
    started = time.monotonic()
    inventory = go_inventory()
    group = partition(inventory)["api" if shard in API_SHARDS else shard]
    receipt = {"shard": shard, "inventory": inventory, "fixture": {}}
    try:
        with fixtures(receipt["fixture"]) as env:
            receipt["preflight_seconds"] = time.monotonic() - started
            before_test = time.monotonic()
            selected, selector = None, []
            if shard in API_SHARDS:
                names = list_api_tests(next(iter(group)), env)
                receipt["api_tests"] = names
                selected = api_partition(names)[shard]
                selector = ["-run", "^(" + "|".join(selected) + ")$"]
            with (out / "tests.jsonl").open("w") as stdout, (out / "go.stderr").open("w") as stderr:
                # Only API selectors are partial, and their tested union is exact.
                # A single-package lane lets Go compile dependencies in parallel.
                serial = ["-p", "1"] if len(group) > 1 else []
                result = subprocess.run(["go", "test", *serial, "-json", "-v", "-race", "-count=1",
                                         f"-coverprofile={out / 'coverage.out'}", *selector, *group],
                                        env=env, cwd=ROOT / "backend", stdout=stdout, stderr=stderr)
            receipt.update(go_exit=result.returncode, test_seconds=time.monotonic() - before_test)
            require(result.returncode == 0, f"{shard} go test exited {result.returncode}; see tests.jsonl / go.stderr")
            tests, coverage = validate(out, group, inventory["module"], selected)
        require(receipt["fixture"].get("retired") is True, "fixture teardown not confirmed")
        receipt["sha256"] = artifact_hashes(out)
    finally:
        receipt["wall_seconds"] = time.monotonic() - started
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"{shard}: {len(group)} packages, {len(tests)} test terminals, {len(coverage)} coverage blocks, "
          f"{receipt['wall_seconds']:.1f}s")


def merge_api_coverage(combined, incoming):
    if combined is None:
        return incoming
    require(combined.keys() == incoming.keys(), "API coverage range inventory changed across test shards")
    for block, (statements, counter) in incoming.items():
        prior_statements, prior_counter = combined[block]
        require(statements == prior_statements, f"API statement geometry mismatch: {block}")
        combined[block] = statements, prior_counter + counter
    return combined


def merge(directory, output, source):
    shards = (*API_SHARDS, *(name for name in SHARDS if name != "api"))
    require({path.name for path in directory.iterdir()} == {f"backend-go-{shard}" for shard in shards},
            "Go shard artifact inventory does not match the required matrix")
    inventory = None
    api_tests, api_blocks = None, None
    blocks = {}
    owners = set()
    containers = set()
    for shard in shards:
        out = directory / f"backend-go-{shard}"
        receipt = json.loads((out / "receipt.json").read_text())
        require(receipt["shard"] == shard and receipt.get("go_exit") == 0, f"unsuccessful or misrouted Go shard: {shard}")
        fixture = receipt["fixture"]
        require(fixture.get("retired") is True and fixture["owner"] not in owners and
                len(set(fixture["containers"])) == 2 and not containers.intersection(fixture["containers"]),
                f"missing retirement or reused fixture in Go shard {shard}")
        owners.add(fixture["owner"])
        containers.update(fixture["containers"])
        if inventory is None:
            inventory = receipt["inventory"]
        require(inventory == receipt["inventory"] and inventory["source"] == source and inventory["go"] == GO_VERSION,
                f"source or Go package inventory mismatch in {shard}")
        require(receipt.get("sha256") == artifact_hashes(out), f"Go artifact digest mismatch: {shard}")
        groups = partition(inventory)
        if shard in API_SHARDS:
            names = receipt["api_tests"]
            if api_tests is None:
                api_tests = names
            require(api_tests == names, f"API test inventory mismatch: {shard}")
            selection = api_partition(names)[shard]
            tests, coverage = validate(out, groups["api"], inventory["module"], selection)
            api_blocks = merge_api_coverage(api_blocks, coverage)
        else:
            tests, coverage = validate(out, groups[shard], inventory["module"])
            require(not blocks.keys() & coverage.keys(), "Go coverage blocks belong to multiple packages")
            blocks.update(coverage)
        print(f"Verified {shard}: {len(tests)} test terminals / {len(coverage)} blocks")
    if not api_blocks or blocks.keys() & api_blocks.keys():
        raise ValueError("missing or multiply owned API coverage blocks")
    blocks.update(api_blocks)
    with output.open("x") as merged:
        merged.write("mode: atomic\n")
        for (path, sl, sc, el, ec), (statements, counter) in sorted(blocks.items()):
            merged.write(f"{path}:{sl}.{sc},{el}.{ec} {statements} {counter}\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    runner = commands.add_parser("run")
    runner.add_argument("shard", choices=(*SHARDS, *API_SHARDS[1:]))
    runner.add_argument("directory", type=Path)
    join = commands.add_parser("merge")
    join.add_argument("directory", type=Path)
    join.add_argument("output", type=Path)
    join.add_argument("source")
    args = parser.parse_args()
    try:
        if args.command == "run":
            run(args.shard, args.directory.resolve())
        else:
            merge(args.directory, args.output, args.source)
    except subprocess.TimeoutExpired as error:
        # As with nonzero exits, never print argv or captured subprocess output.
        sys.exit(f"backend CI command {error.cmd[0]} timed out after {error.timeout}s")
    except subprocess.CalledProcessError as error:
        # docker/psql argv can carry ephemeral credentials; don't print it.
        sys.exit(f"backend CI command {error.cmd[0]} exited {error.returncode}")
    except (ValueError, KeyError, FileNotFoundError) as error:
        sys.exit(str(error))


if __name__ == "__main__":
    main()
