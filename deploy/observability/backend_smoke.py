#!/usr/bin/env python3
"""Exercise the real Go router and read its OTLP records from OpenObserve.

Both traffic cohorts are synthetic local requests. A production label is not
production-VM evidence. Credentials are read privately by the existing helper.
"""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import time

from check import API, load_env, sql_identifier, sql_string

CANARY = "SOUNDQ_SYNTHETIC_PRIVACY_CANARY"


def run(api, root, output):
    output.mkdir(parents=True, exist_ok=False)
    run_id = secrets.token_hex(8)
    cohorts = {}
    for environment in ("development", "production"):
        instance = "synthetic-router-" + environment + "-" + run_id
        version = "synthetic-router-e2e-" + run_id
        env = {k: v for k, v in os.environ.items() if not k.startswith("OTEL_")}
        env.update({
            "TMPDIR": os.environ.get("TMPDIR", str(output.parent)),
            "OTEL_SERVICE_NAME": "soundq-backend",
            "OTEL_RESOURCE_ATTRIBUTES": "deployment.environment.name=" + environment
                + ",service.version=" + version + ",service.instance.id=" + instance,
            "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
            "OTEL_EXPORTER_OTLP_ENDPOINT": api.otlp,
            "OTEL_TRACES_EXPORTER": "otlp", "OTEL_LOGS_EXPORTER": "otlp",
            "OTEL_METRICS_EXPORTER": "otlp", "OTEL_TRACES_SAMPLER": "always_on",
        })
        child = subprocess.run(["go", "run", "./cmd/telemetry-smoke"], cwd=root / "backend",
                               env=env, capture_output=True, text=True, timeout=90)
        (output / (environment + "-stdout.jsonl")).write_text(child.stdout)
        (output / (environment + "-stderr.log")).write_text(child.stderr)
        assert child.returncode == 0, "router smoke failed; inspect retained log"
        assert CANARY not in child.stdout and CANARY not in child.stderr
        stdout = [json.loads(line) for line in child.stdout.splitlines()]
        summary = stdout[-1]
        assert summary["synthetic"] is True and summary["telemetry_drained"] is True
        assert summary["instance"] == instance and summary["environment"] == environment
        assert sorted(r["status"] for r in summary["requests"]) == [200, 401, 404]
        cohorts[environment] = {"instance": instance, "version": version,
                                "summary": summary, "stdout": stdout[:-1]}

    def read(cohort):
        received = {}
        for kind, streams, column in (
            ("logs", ["soundq_backend"], "service_instance_id"),
            ("traces", ["soundq_backend"], "service_service_instance_id"),
            ("metrics", ["http_server_request_count", "http_server_request_duration_count",
                         "http_server_request_duration_sum", "http_server_request_duration_bucket"],
             "service_instance_id"),
        ):
            for stream in streams:
                result = api.query("SELECT * FROM " + sql_identifier(stream) + " WHERE "
                                   + column + " = " + sql_string(cohort["instance"]), kind, size=100)
                assert not result.get("is_partial", False), "partial search cannot establish complete cohort"
                rows = result["hits"]
                assert rows and len(rows) < 100, "missing or truncated signal"
                assert CANARY not in json.dumps(rows), "privacy canary reached store"
                received[kind + "/" + stream] = rows
        return received

    deadline = time.monotonic() + 90
    while True:
        try:
            received = {name: read(cohort) for name, cohort in cohorts.items()}
            break
        except (RuntimeError, AssertionError, KeyError):
            if time.monotonic() >= deadline:
                raise
            time.sleep(1)

    for environment, signals in received.items():
        cohort = cohorts[environment]
        expected_ids = {row["request_id"] for row in cohort["summary"]["requests"]}
        logs, spans = signals["logs/soundq_backend"], signals["traces/soundq_backend"]
        assert len(logs) == len(spans) == 3
        assert {row["request_id"] for row in logs} == expected_ids
        assert {row["request_id"] for row in spans} == expected_ids
        expected_routes = {"/health", "/api/v1/tracks/{track_id}/metadata-override", "unknown"}
        for kind, rows in signals.items():
            prefix = "service_" if kind.startswith("traces/") else ""
            assert all(row["service_name"] == "soundq-backend" for row in rows)
            assert all(row[prefix + "deployment_environment_name"] == environment for row in rows)
            assert all(row[prefix + "service_instance_id"] == cohort["instance"] for row in rows)
            assert all(row[prefix + "service_version"] == cohort["version"] for row in rows)
            assert {row["http_route"] for row in rows} == expected_routes
        pairs = lambda rows: {(r["trace_id"], r["span_id"], r["request_id"]) for r in rows}
        assert pairs(logs) == pairs(spans)
        assert pairs(cohort["stdout"]) == pairs(logs)
        assert all(re.fullmatch(r"[0-9a-f]{32}", r["trace_id"]) and
                   re.fullmatch(r"[0-9a-f]{16}", r["span_id"]) for r in logs)
        counts = signals["metrics/http_server_request_count"]
        assert len(counts) == 3 and sum(r["value"] for r in counts) == 3
        durations = signals["metrics/http_server_request_duration_count"]
        assert len(durations) == 3 and sum(r["value"] for r in durations) == 3
        assert all(r["value"] >= 0 for r in signals["metrics/http_server_request_duration_sum"])
        assert all(r["value"] == 1 for r in signals["metrics/http_server_request_duration_bucket"]
                   if str(r.get("le")) == "+Inf")
    dev = {r["request_id"] for r in received["development"]["logs/soundq_backend"]}
    prod = {r["request_id"] for r in received["production"]["logs/soundq_backend"]}
    assert not dev & prod
    receipt = {"passed": True, "syntheticTraffic": True, "actualGoRouterExecuted": True,
               "productionVMInstrumented": False, "run": run_id,
               "cohorts": {name: {"instance": c["instance"], "version": c["version"]}
                           for name, c in cohorts.items()},
               "requestsPerEnvironment": 3, "allSignalsSearchable": True,
               "stdoutLogSpanCorrelationExact": True, "privacyCanaryAbsent": True,
               "receiver": api.otlp, "store": api.base}
    (output / "received.json").write_text(json.dumps(received, indent=2) + "\n")
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    run(API(load_env(args.env_file)), root, args.output.resolve())


if __name__ == "__main__":
    main()
