"""Partition Flutter VM files and verify/merge evidence for the CI required check."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import time


CLIENT = Path(__file__).resolve().parents[1] / "client"
SHARD_COUNT = 4
# This is the VM gate the old unfiltered Flutter command ran, not a Chrome
# gate. An exception must still be present and explicitly browser-only in Dart.
BROWSER_ONLY = frozenset({"test/web_session_token_storage_test.dart"})
# Rounded whole-suite case time above a 2s threshold from a full --machine run.
# This is only a balancing hint, never the inventory. All suites, including new
# and renamed files, receive a floor for loading/compiling the suite.
EXTRA_MS = {
    "test/analysis_calibration_workspace_test.dart": 2500,
    "test/analysis_correction_sheet_test.dart": 2500,
    "test/auth_desktop_presentation_test.dart": 3500,
    "test/desktop_compact_target_regression_test.dart": 2500,
    "test/desktop_hotate_presentation_test.dart": 12500,
    "test/desktop_mix_editor_widget_test.dart": 6500,
    "test/desktop_mix_performance_test.dart": 14000,
    "test/desktop_native_control_regression_test.dart": 4000,
    "test/dj_screen_test.dart": 2000,
    "test/features/dj/dj_deck_tempo_sheet_test.dart": 3000,
    "test/flight_caller_contrast_regression_test.dart": 5500,
    "test/flight_core_independent_review_test.dart": 35000,
    "test/flight_theme_real_font_native_test.dart": 4000,
    "test/harmonic_discovery_sheet_test.dart": 2500,
    "test/home_desktop_capture_test.dart": 2000,
    "test/home_desktop_density_test.dart": 4000,
    "test/hotate_entry_repair_test.dart": 5000,
    "test/hotate_playlist_detail_header_test.dart": 2500,
    "test/hotate_playlists_creation_entry_test.dart": 3500,
    "test/hotate_timeline_route_capture_test.dart": 2000,
    "test/hotate_title_disclosure_test.dart": 2500,
    "test/native_playback_integration_test.dart": 3000,
    "test/playlist_mix_toggle_test.dart": 2500,
    "test/queue_screen_test.dart": 6500,
    "test/stacked_waveform_timeline_test.dart": 6000,
}


def plan(client):
    # Git's checked-out inventory, not a checked-in list of current suites or
    # whatever happens to be left in a local generated directory.
    tracked = subprocess.check_output(["git", "ls-files", "-z", "--", "test/"], cwd=client)
    files = {path for path in tracked.decode().split("\0") if path.endswith("_test.dart")}
    for path in files:
        if not (client / path).is_file() or (client / path).is_symlink():
            raise ValueError(f"invalid tracked Flutter suite: {path}")
    for path in BROWSER_ONLY:
        if path not in files or not re.match(r"\A@TestOn\((['\"])browser\1\)\s+(?:library|import)\b",
                                            (client / path).read_text(encoding="utf-8")):
            raise ValueError(f"browser-only exception no longer declares a browser-only library: {path}")

    shards = [[] for _ in range(SHARD_COUNT)]
    loads = [0] * SHARD_COUNT
    for path in sorted(files - BROWSER_ONLY, key=lambda path: (-EXTRA_MS.get(path, 0), path)):
        index = min(range(SHARD_COUNT), key=lambda index: (loads[index], index))
        shards[index].append(path)
        loads[index] += 1500 + EXTRA_MS.get(path, 0)
    if not all(shards):
        raise ValueError("empty Flutter VM shard")
    return [sorted(shard) for shard in shards]


def read_machine(log, client_root, expected):
    suites, starts, finished, cases = {}, {}, set(), []
    started = done = False
    count = None

    def require(condition, message):
        if not condition:
            raise ValueError(f"Flutter machine evidence {log}: {message}")

    with log.open(encoding="utf-8") as stream:
        for line in stream:
            # Flutter may emit plain-text SDK/build diagnostics before/after the
            # reporter. JSON event lines, unlike those diagnostics, must parse.
            if not line.lstrip().startswith("{"):
                continue
            require(line.endswith("\n") and not done, "incomplete event or event after done")
            event = json.loads(line)
            event_type = event["type"]
            require(started or event_type == "start", "event before start")
            if event_type == "start":
                require(not started and event["protocolVersion"] == "0.1.1", "invalid start")
                started = True
            elif event_type == "allSuites":
                require(count is None and event["count"] == len(expected), "unexpected allSuites count")
                count = event["count"]
            elif event_type == "suite":
                suite = event["suite"]
                relative = Path(suite["path"]).relative_to(client_root).as_posix()
                require(suite["platform"] == "vm" and suite["id"] not in suites and
                        relative in expected and relative not in suites.values(), f"unexpected suite: {relative}")
                suites[suite["id"]] = relative
            elif event_type == "testStart":
                test = event["test"]
                require(test["suiteID"] in suites and test["id"] not in starts, "invalid testStart")
                starts[test["id"]] = (suites[test["suiteID"]], test["name"])
            elif event_type == "testDone":
                test_id = event["testID"]
                require(test_id in starts and test_id not in finished and event["result"] == "success" and
                        type(event["skipped"]) is bool and type(event["hidden"]) is bool, "invalid testDone")
                finished.add(test_id)
                if not event["hidden"]:
                    cases.append((*starts[test_id], event["skipped"]))
            elif event_type == "done":
                require(event["success"] is True, "runner did not report success")
                done = True
            elif event_type == "error":
                require(False, "runner reported an error event")

    require(done and count is not None and starts.keys() == finished, "missing terminal evidence")
    require(set(suites.values()) == set(expected) == {path for path, _, _ in cases}, "missing suites or cases")
    return cases


def read_lcov(path):
    # Pinned Flutter emits line-only LCOV (SF, DA, LF, LH, end_of_record).
    # Fail on format drift instead of silently dropping unsupported metrics.
    records = path.read_text(encoding="utf-8").split("end_of_record\n")
    if len(records) < 2 or records.pop() != "":
        raise ValueError(f"LCOV {path}: empty or truncated report")
    coverage = {}
    for record in records:
        fields = record.splitlines()
        if len(fields) < 4 or not fields[0].startswith("SF:"):
            raise ValueError(f"LCOV {path}: incomplete source record")
        source = fields[0][3:]
        if (not source.startswith("lib/") or not source.endswith(".dart") or "\\" in source or
                PurePosixPath(source).as_posix() != source or ".." in PurePosixPath(source).parts or source in coverage):
            raise ValueError(f"LCOV {path}: invalid or duplicate source {source!r}")
        lines = {}
        for field in fields[1:-2]:
            match = re.fullmatch(r"DA:([1-9][0-9]*),([0-9]+)", field)
            if not match or int(match[1]) in lines:
                raise ValueError(f"LCOV {path}: invalid or duplicate line {field!r}")
            lines[int(match[1])] = int(match[2])
        if fields[-2:] != [f"LF:{len(lines)}", f"LH:{sum(value > 0 for value in lines.values())}"]:
            raise ValueError(f"LCOV {path}: invalid line totals for {source}")
        coverage[source] = lines
    return coverage


def write_lcov(path, coverage):
    with path.open("x", encoding="utf-8") as stream:
        for source, lines in sorted(coverage.items()):
            stream.write(f"SF:{source}\n")
            for line, hits in sorted(lines.items()):
                stream.write(f"DA:{line},{hits}\n")
            stream.write(f"LF:{len(lines)}\nLH:{sum(value > 0 for value in lines.values())}\nend_of_record\n")


def digests(directory):
    return {name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
            for name in ("machine.jsonl", "lcov.info")}


def run_shard(client, index, output, sha, run_id):
    expected = plan(client)[index]
    output = output.resolve()
    output.mkdir(parents=True)
    log = output / "machine.jsonl"
    print(f"Flutter VM shard {index}: {len(expected)} files", flush=True)
    start = time.monotonic()
    with log.open("wb") as stream:
        result = subprocess.run(["flutter", "test", "--machine", "--no-pub", "--concurrency=2", "--coverage",
                                 f"--coverage-path={output / 'lcov.info'}", *expected], cwd=client, stdout=stream)
    if result.returncode:
        print(log.read_text(encoding="utf-8", errors="replace")[-16000:], file=sys.stderr)
        raise ValueError(f"Flutter VM shard {index} exited {result.returncode}")
    cases = read_machine(log, client, expected)
    read_lcov(output / "lcov.info")
    receipt = {"sha": sha, "run_id": run_id, "shard": index, "client_root": str(client), "sha256": digests(output)}
    (output / "receipt.json").write_text(json.dumps(receipt) + "\n", encoding="utf-8")
    print(f"Flutter VM shard {index}: {len(cases)} cases ({sum(skip for _, _, skip in cases)} skipped) "
          f"in {time.monotonic() - start:.1f}s")


def collect(client, artifacts, sha, run_id):
    plan_by_shard = plan(client)
    names = [f"client-vm-shard-{index}" for index in range(SHARD_COUNT)]
    if {p.name for p in artifacts.iterdir()} != set(names):
        raise ValueError(f"Flutter shard artifact names must be exactly {names}")
    merged, cases = {}, []
    for index, name in enumerate(names):
        directory = artifacts / name
        if {p.name for p in directory.iterdir()} != {"receipt.json", "machine.jsonl", "lcov.info"}:
            raise ValueError(f"incomplete Flutter shard artifact {name}")
        receipt = json.loads((directory / "receipt.json").read_text(encoding="utf-8"))
        if (receipt["sha"], receipt["run_id"], receipt["shard"]) != (sha, run_id, index):
            raise ValueError(f"Flutter shard artifact identity mismatch: {name}")
        if receipt["sha256"] != digests(directory):
            raise ValueError(f"Flutter shard artifact digest mismatch: {name}")
        cases.extend(read_machine(directory / "machine.jsonl", Path(receipt["client_root"]), plan_by_shard[index]))
        for source, lines in read_lcov(directory / "lcov.info").items():
            combined = merged.setdefault(source, {})
            for line, hits in lines.items():
                combined[line] = combined.get(line, 0) + hits
    skipped = sum(skip for _, _, skip in cases)
    return merged, len(cases) - skipped, skipped


def require(vm, contracts, web):
    for name, status in (("VM matrix", vm), ("contracts", contracts), ("web build", web)):
        if status != "success":
            raise ValueError(f"Flutter prerequisite {name} did not succeed: {status!r}")


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    commands = cli.add_subparsers(dest="command", required=True)
    commands.add_parser("plan")
    shard = commands.add_parser("shard")
    shard.add_argument("index", type=int, choices=range(SHARD_COUNT))
    shard.add_argument("output", type=Path)
    verify = commands.add_parser("require")
    verify.add_argument("vm")
    verify.add_argument("contracts")
    verify.add_argument("web")
    merge = commands.add_parser("merge")
    merge.add_argument("artifacts", type=Path)
    merge.add_argument("output", type=Path)
    args = cli.parse_args()
    if args.command == "require":
        require(args.vm, args.contracts, args.web)
        return
    if args.command == "plan":
        print(json.dumps({"vm": plan(CLIENT), "browser_only": sorted(BROWSER_ONLY)}, indent=2))
        return
    sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=CLIENT, text=True).strip()
    if sha != os.environ.get("GITHUB_SHA", sha):
        raise ValueError("Flutter checkout does not match GITHUB_SHA")
    run_id = os.environ.get("GITHUB_RUN_ID", "local")
    if args.command == "shard":
        run_shard(CLIENT, args.index, args.output, sha, run_id)
    else:
        coverage, passed, skipped = collect(CLIENT, args.artifacts, sha, run_id)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        write_lcov(args.output, coverage)
        print(f"Flutter VM: {SHARD_COUNT} complete shards; {passed} passed, {skipped} skipped; "
              f"merged coverage for {len(coverage)} sources")


if __name__ == "__main__":
    try:
        main()
    except (KeyError, OSError, TypeError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
