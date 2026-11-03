#!/usr/bin/env python3
"""Authenticated OpenObserve API and OTLP fixture smoke. Stdlib only, no secrets printed."""
import argparse
import json
from pathlib import Path
import re
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def load_env(path):
    return dict(line.split("=", 1) for line in Path(path).read_text().splitlines()
                if line and not line.startswith("#"))


class API:
    def __init__(self, env):
        self.env = env
        self.base = "http://127.0.0.1:" + env.get("OBS_UI_PORT", "15080")
        self.otlp = "http://127.0.0.1:" + env.get("OBS_OTLP_PORT", "14318")

    def request(self, path, data=None, authenticated=True, base=None):
        headers = {"Content-Type": "application/json"}
        if authenticated:
            headers["Authorization"] = "Basic " + self.env["OPENOBSERVE_AUTH"]
        req = urllib.request.Request((base or self.base) + path,
                                     data=None if data is None else json.dumps(data).encode(),
                                     headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                body = response.read()
                if "json" in response.headers.get("Content-Type", ""):
                    return json.loads(body)
                return body.decode()
        except urllib.error.HTTPError as exc:
            # Do not let a server error echo an auth value into task output.
            body = exc.read().decode(errors="replace")
            for key in ("OPENOBSERVE_AUTH", "ZO_ROOT_USER_PASSWORD"):
                if self.env.get(key):
                    body = body.replace(self.env[key], "[REDACTED]")
            body = body[:1500]
            raise RuntimeError("HTTP %s for %s: %s" % (exc.code, path, body)) from None

    def query(self, sql, kind="logs", minutes=30, size=100):
        now = time.time_ns() // 1000
        return self.request("/api/default/_search?type=" + kind,
                            {"query": {"sql": sql, "start_time": now - minutes * 60 * 1000000,
                                       "end_time": now, "from": 0, "size": size}})

    def streams(self, kind):
        return self.request("/api/default/streams?type=" + kind)


def attributes(values):
    return [{"key": key, "value": {"stringValue": str(value)}}
            for key, value in values.items()]


def emit(api, run):
    ids = {}
    now = time.time_ns()
    for environment in ("development", "production"):
        trace, span = secrets.token_hex(16), secrets.token_hex(8)
        instance = "synthetic-stack-smoke-%s-%s" % (environment, run)
        ids[environment] = {"trace_id": trace, "span_id": span, "instance": instance}
        resource = {"attributes": attributes({
            "service.name": "soundq-backend", "service.version": "synthetic-stack-smoke",
            "service.instance.id": instance, "deployment.environment.name": environment,
            "telemetry.fixture": "synthetic", "telemetry.smoke.run": run})}
        scope = {"name": "soundq.observability.stack-smoke"}
        common = attributes({"http.request.method": "GET", "http.route": "/health",
                             "request_id": "fixture-" + run})
        log = {"timeUnixNano": str(now), "observedTimeUnixNano": str(now),
               "severityNumber": 9, "severityText": "INFO", "traceId": trace, "spanId": span,
               "body": {"stringValue": "synthetic stack smoke"}, "attributes": common}
        data = {"resourceLogs": [{"resource": resource, "scopeLogs": [
            {"scope": scope, "logRecords": [log]}]}]}
        api.request("/v1/logs", data, authenticated=False, base=api.otlp)
        data = {"resourceSpans": [{"resource": resource, "scopeSpans": [
            {"scope": scope, "spans": [{"traceId": trace, "spanId": span,
                "name": "GET /health synthetic stack smoke", "kind": 2,
                "startTimeUnixNano": str(now - 1000000), "endTimeUnixNano": str(now),
                "attributes": common, "status": {"code": 1}}]}]}]}
        api.request("/v1/traces", data, authenticated=False, base=api.otlp)
        data = {"resourceMetrics": [{"resource": resource, "scopeMetrics": [
            {"scope": scope, "metrics": [{"name": "soundq_observability_smoke_total",
                "description": "Synthetic fixture, not actual backend activity", "unit": "1",
                "sum": {"aggregationTemporality": 2, "isMonotonic": True, "dataPoints": [
                    {"attributes": common, "startTimeUnixNano": str(now - 1000000),
                     "timeUnixNano": str(now), "asInt": "1"}]}}]}]}]}
        api.request("/v1/metrics", data, authenticated=False, base=api.otlp)
    return ids


def check_health(api):
    assert "html" in api.request("/web/", authenticated=False).lower(), "UI HTML unavailable"
    api.request("/healthz", authenticated=False)
    health = "http://127.0.0.1:" + api.env.get("OBS_HEALTH_PORT", "14333")
    api.request("/", authenticated=False, base=health)
    try:
        api.request("/api/default/streams", authenticated=False)
    except RuntimeError as exc:
        assert "HTTP 401" in str(exc) or "HTTP 403" in str(exc), str(exc)
    else:
        raise AssertionError("store API allowed unauthenticated access")
    api.streams("logs")


def identity_columns(kind):
    if kind == "traces":
        return ("service_deployment_environment_name", "service_service_instance_id",
                "service_service_version", "service_telemetry_smoke_run")
    return ("deployment_environment_name", "service_instance_id", "service_version",
            "telemetry_smoke_run")


def sql_string(value):
    return "'" + value.replace("'", "''") + "'"


def sql_identifier(value):
    return '"' + value.replace('"', '""') + '"'


def verify_fixtures(api, result):
    found = {}
    for kind, stream in (("logs", "soundq_backend"), ("traces", "soundq_backend"),
                         ("metrics", "soundq_observability_smoke_total")):
        env_col, instance_col, version_col, run_col = identity_columns(kind)
        rows = api.query("SELECT * FROM %s WHERE %s = %s" % (
            sql_identifier(stream), run_col, sql_string(result["run"])), kind)["hits"]
        assert len(rows) == 2, "%s expected exactly two fixture rows" % kind
        for environment, expected in result["ids"].items():
            matching = [row for row in rows if row.get(env_col) == environment]
            assert len(matching) == 1, "%s %s identity missing" % (kind, environment)
            row = matching[0]
            assert row["service_name"] == "soundq-backend"
            assert row[instance_col] == expected["instance"]
            assert row[version_col] == "synthetic-stack-smoke"
            if kind in ("logs", "traces"):
                assert row["trace_id"] == expected["trace_id"]
                assert row["span_id"] == expected["span_id"]
            else:
                assert row["value"] == 1
        found[kind] = rows
    return found


def verify_received(api, args):
    received = {}
    for kind, streams in (("logs", ["soundq_backend"]), ("traces", ["soundq_backend"]),
                          ("metrics", args.metric_stream)):
        env_col, instance_col, version_col, _ = identity_columns(kind)
        predicate = "%s = %s AND %s = %s AND service_name = 'soundq-backend'" % (
            env_col, sql_string(args.environment), instance_col, sql_string(args.instance))
        for stream in streams:
            rows = api.query("SELECT * FROM %s WHERE %s" % (sql_identifier(stream), predicate),
                             kind, args.minutes)["hits"]
            assert rows, "%s/%s has no received rows for this producer" % (kind, stream)
            assert all(row.get(version_col) for row in rows), "service.version missing"
            fixture_col = "service_telemetry_fixture" if kind == "traces" else "telemetry_fixture"
            assert not any(row.get(fixture_col) == "synthetic" for row in rows), "synthetic is not real backend evidence"
            received[kind + "/" + stream] = rows
    logs, traces = received["logs/soundq_backend"], received["traces/soundq_backend"]
    def pairs(rows):
        return {(row["trace_id"], row["span_id"]) for row in rows
                if re.fullmatch(r"[0-9a-f]{32}", row.get("trace_id", ""))
                and re.fullmatch(r"[0-9a-f]{16}", row.get("span_id", ""))
                and int(row["trace_id"], 16) and int(row["span_id"], 16)}
    assert pairs(logs) & pairs(traces), "no valid correlated received log/span pair"
    return {"status": "passed", "environment": args.environment, "instance": args.instance,
            "synthetic": False, "received": received}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", required=True)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("health")
    sub.add_parser("fixtures")
    received = sub.add_parser("received", help="read-only check of actual backend producer data")
    received.add_argument("--environment", required=True)
    received.add_argument("--instance", required=True)
    received.add_argument("--metric-stream", action="append", required=True)
    received.add_argument("--minutes", type=int, default=30)
    streams = sub.add_parser("streams")
    streams.add_argument("--type", choices=("logs", "traces", "metrics"), default="logs")
    query = sub.add_parser("query")
    query.add_argument("--type", choices=("logs", "traces", "metrics"), default="logs")
    query.add_argument("--sql", required=True)
    query.add_argument("--minutes", type=int, default=30)
    args = parser.parse_args()
    api = API(load_env(args.env_file))
    if args.action == "health":
        check_health(api)
        result = {"health": "passed", "ui": api.base, "otlp": api.otlp,
                  "unauthenticated_store_api": "rejected"}
    elif args.action == "streams":
        result = api.streams(args.type)
    elif args.action == "received":
        result = verify_received(api, args)
    elif args.action == "query":
        result = api.query(args.sql, args.type, args.minutes)
    else:
        check_health(api)
        run = secrets.token_hex(8)
        result = {"run": run, "synthetic": True, "ids": emit(api, run)}
        # Read the actual search API. Transport acceptance alone is not ingestion proof.
        deadline = time.monotonic() + 90
        last = None
        while time.monotonic() < deadline:
            try:
                result["received"] = verify_fixtures(api, result)
                result["status"] = "passed"
                break
            except (RuntimeError, AssertionError, KeyError) as exc:
                last = str(exc)
                time.sleep(2)
        else:
            raise RuntimeError("fixtures not searchable within 90s: " + str(last))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, AssertionError, OSError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
