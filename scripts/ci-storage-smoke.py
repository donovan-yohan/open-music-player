#!/usr/bin/env python3
"""Exercise the real low-memory storage definitions on disposable tmpfs only."""
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]


def main():
    project = "omp-ci-storage-" + uuid.uuid4().hex[:12]
    env = os.environ.copy()
    # Never consume a checkout's .env, Compose project, credentials or ports.
    env = {k: v for k, v in env.items() if not k.startswith(("COMPOSE_", "MINIO_"))}
    root_user, root_password, bucket = "ci-storage", uuid.uuid4().hex, "ci-storage"
    env.update(MINIO_ROOT_USER=root_user, MINIO_ROOT_PASSWORD=root_password, MINIO_BUCKET=bucket)
    config = json.loads(subprocess.check_output([
        "docker", "compose", "--env-file", "/dev/null", "-f",
        str(ROOT / "docker-compose.local-low-memory.yml"), "config", "--format", "json",
    ], env=env))
    services = {name: config["services"][name] for name in ("minio", "minio-init")}
    for service in services.values():
        service.pop("networks", None)
        service.pop("restart", None)
    services["minio"].update(volumes=[], tmpfs=["/data"], ports=["127.0.0.1::9000"])
    with tempfile.TemporaryDirectory(prefix="omp-ci-storage-") as scratch:
        compose_file = Path(scratch) / "compose.json"
        compose_file.write_text(json.dumps({"services": services}))
        compose = ["docker", "compose", "--env-file", "/dev/null", "-p", project, "-f", str(compose_file)]

        def run(*args, **kwargs):
            return subprocess.check_output(compose + list(args), env=env, **kwargs)

        try:
            run("up", "-d", "--build", "minio", "minio-init")
            init_id = run("ps", "-aq", "minio-init").decode().strip()
            assert subprocess.check_output(["docker", "wait", init_id]).strip() == b"0", "init failed"
            # Read back bucket existence and privacy: exit 0 alone is not proof
            # because the pre-existing init entrypoint ends in unconditional 0.
            run("run", "--rm", "--no-deps", "--entrypoint", "/bin/sh", "minio-init", "-ec",
                'mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null; '
                'mc stat local/"$MINIO_BUCKET" >/dev/null; '
                'mc anonymous get local/"$MINIO_BUCKET" | grep -q private')
            endpoint = "http://" + run("port", "minio", "9000").decode().strip()
            payload = b"SoundQ disposable storage Range fixture\n" * 128
            key = "/" + bucket + "/fixture.bin"

            def request(method, path, data=None, headers=None, signed=True):
                headers = dict(headers or {})
                if signed:
                    now = datetime.now(timezone.utc)
                    stamp, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
                    host = urllib.parse.urlsplit(endpoint).netloc
                    body_hash = hashlib.sha256(data or b"").hexdigest()
                    canonical_headers = f"host:{host}\nx-amz-content-sha256:{body_hash}\nx-amz-date:{stamp}\n"
                    signed_headers = "host;x-amz-content-sha256;x-amz-date"
                    canonical = "\n".join([method, path, "", canonical_headers, signed_headers, body_hash])
                    scope = day + "/us-east-1/s3/aws4_request"
                    message = "AWS4-HMAC-SHA256\n" + stamp + "\n" + scope + "\n" + hashlib.sha256(canonical.encode()).hexdigest()
                    signing_key = ("AWS4" + root_password).encode()
                    for part in (day, "us-east-1", "s3", "aws4_request"):
                        signing_key = hmac.new(signing_key, part.encode(), hashlib.sha256).digest()
                    signature = hmac.new(signing_key, message.encode(), hashlib.sha256).hexdigest()
                    headers.update({"x-amz-content-sha256": body_hash, "x-amz-date": stamp,
                                    "Authorization": f"AWS4-HMAC-SHA256 Credential={root_user}/{scope}, SignedHeaders={signed_headers}, Signature={signature}"})
                req = urllib.request.Request(endpoint + path, data=data, headers=headers, method=method)
                try:
                    with urllib.request.urlopen(req, timeout=15) as response:
                        return response.status, response.headers, response.read()
                except urllib.error.HTTPError as error:
                    return error.code, error.headers, error.read()

            assert request("PUT", key, payload)[0] == 200, "S3 PUT failed"
            status, headers, _ = request("HEAD", key)
            assert status == 200 and int(headers["Content-Length"]) == len(payload), "S3 HEAD failed"
            assert request("GET", key)[2] == payload, "S3 GET body mismatch"
            status, headers, data = request("GET", key, headers={"Range": "bytes=5-22", "Origin": "http://localhost:18080"})
            assert status == 206 and data == payload[5:23], "Range GET failed"
            assert headers["Content-Range"] == f"bytes 5-22/{len(payload)}", "Content-Range mismatch"
            assert headers["Access-Control-Allow-Origin"] == "http://localhost:18080", "CORS GET failed"
            status, headers, _ = request("OPTIONS", key, signed=False, headers={
                "Origin": "http://localhost:18080", "Access-Control-Request-Method": "GET",
                "Access-Control-Request-Headers": "range",
            })
            assert status in (200, 204) and headers["Access-Control-Allow-Origin"] == "http://localhost:18080", "CORS preflight failed"
            assert request("GET", key, signed=False)[0] == 403, "anonymous object access allowed"
            assert request("DELETE", key)[0] == 204, "S3 DELETE failed"
            assert request("HEAD", key)[0] == 404, "deleted object still exists"
            print("PASS: Compose health/init + private bucket + S3 PUT/HEAD/GET/DELETE + Range 206 + CORS/preflight + anonymous 403")
        finally:
            subprocess.run(compose + ["down", "--remove-orphans"], env=env, check=True)
            # tmpfs is gone with these containers; no named data volume is used.
            remaining = subprocess.check_output(["docker", "ps", "-aq", "--filter", f"label=com.docker.compose.project={project}"])
            assert not remaining.strip(), "disposable containers remain"


if __name__ == "__main__":
    main()
