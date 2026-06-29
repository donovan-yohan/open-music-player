#!/usr/bin/env python3
"""Run the local discovery -> queue -> download -> MinIO -> playback smoke.

This is intentionally stdlib-only so the smoke can run on a plain devbox. The
`scripts/local-low-memory.sh e2e-smoke` wrapper starts the low-memory downloads
profile before invoking this script; direct callers should start it first with
`scripts/local-low-memory.sh start-downloads`.
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DOTENV = ROOT / ".env"
COMPOSE_FILE = ROOT / "docker-compose.local-low-memory.yml"


class SmokeError(RuntimeError):
    pass


def load_dotenv(path: Path) -> None:
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        os.environ.setdefault(key, value)


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


def env_int(name: str, default: int) -> int:
    value = os.environ.get(name)
    if not value:
        return default
    try:
        return int(value)
    except ValueError as exc:
        raise SmokeError(f"{name} must be an integer, got {value!r}") from exc


def request_json(
    method: str,
    url: str,
    *,
    token: str | None = None,
    payload: Any | None = None,
    expected: tuple[int, ...] = (200,),
    timeout: int = 20,
) -> tuple[int, Any]:
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - local smoke target/user source
            data = resp.read(1 << 22)
            status = resp.status
    except urllib.error.HTTPError as exc:
        data = exc.read(1 << 20)
        status = exc.code
    if status not in expected:
        trimmed = data.decode("utf-8", errors="replace").strip()
        raise SmokeError(f"{method} {url} returned {status}: {trimmed}")
    if not data:
        return status, None
    try:
        return status, json.loads(data)
    except json.JSONDecodeError as exc:
        raise SmokeError(f"{method} {url} returned non-JSON body: {data[:200]!r}") from exc


def get_signed_range(url: str, timeout: int) -> tuple[int, int, str]:
    req = urllib.request.Request(url, headers={"Range": "bytes=0-15"}, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - signed local MinIO URL
            data = resp.read(16)
            return resp.status, len(data), resp.headers.get("Content-Range", "")
    except urllib.error.HTTPError as exc:
        data = exc.read(16)
        return exc.code, len(data), exc.headers.get("Content-Range", "")


def run_cmd(args: list[str], *, check: bool = True, capture: bool = True, env_overrides: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    merged_env = os.environ.copy()
    if env_overrides:
        merged_env.update(env_overrides)
    try:
        return subprocess.run(
            args,
            cwd=ROOT,
            env=merged_env,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            check=check,
        )
    except subprocess.CalledProcessError as exc:
        stdout = (exc.stdout or "").strip()
        stderr = (exc.stderr or "").strip()
        detail = "\n".join(part for part in (stdout, stderr) if part)
        if len(detail) > 1200:
            detail = detail[-1200:]
        command = " ".join(shlex.quote(part) for part in args)
        suffix = f": {detail}" if detail else ""
        raise SmokeError(f"command failed with exit {exc.returncode}: {command}{suffix}") from exc


def compose_args(*args: str) -> list[str]:
    return ["docker", "compose", "-f", str(COMPOSE_FILE), *args]


def wait_for_backend(backend: str, timeout_seconds: int) -> None:
    deadline = time.time() + timeout_seconds
    last_err: Exception | None = None
    while time.time() < deadline:
        try:
            request_json("GET", f"{backend}/health", expected=(200,), timeout=5)
            print(f"backend health: ok ({backend}/health)")
            return
        except Exception as exc:  # noqa: BLE001 - compact retry loop
            last_err = exc
            time.sleep(1)
    raise SmokeError(f"backend did not become healthy at {backend}/health: {last_err}")


def assert_worker_count_one() -> None:
    proc = run_cmd(compose_args("exec", "-T", "backend", "/bin/sh", "-lc", "printf %s \"$WORKER_COUNT\""))
    value = proc.stdout.strip()
    if value != "1":
        raise SmokeError(f"backend WORKER_COUNT={value!r}; e2e smoke requires exactly 1 worker")
    print("download worker concurrency: ok (WORKER_COUNT=1)")


def auth_token(api: str, email: str, password: str, username: str) -> str:
    register_payload = {"email": email, "password": password, "username": username}
    status, body = request_json(
        "POST",
        f"{api}/auth/register",
        payload=register_payload,
        expected=(201, 400, 409),
    )
    if status == 201:
        token = body.get("accessToken", "")
        if not token:
            raise SmokeError("register response missing accessToken")
        print(f"auth: registered smoke user ({email})")
        return token

    # Existing smoke user: login instead. This keeps repeated local runs boring.
    _, body = request_json(
        "POST",
        f"{api}/auth/login",
        payload={"email": email, "password": password},
        expected=(200,),
    )
    token = body.get("accessToken", "")
    if not token:
        raise SmokeError("login response missing accessToken")
    print(f"auth: logged in smoke user ({email})")
    return token


def choose_candidate(search_body: dict[str, Any]) -> dict[str, Any]:
    candidates: list[dict[str, Any]] = []
    for item in search_body.get("results") or []:
        if isinstance(item, dict):
            candidates.append(item)
    for section in search_body.get("sections") or []:
        if not isinstance(section, dict):
            continue
        for item in section.get("items") or []:
            if isinstance(item, dict) and isinstance(item.get("candidate"), dict):
                candidates.append(item["candidate"])
    for candidate in candidates:
        if candidate.get("downloadable") and candidate.get("sourceUrl") and candidate.get("title"):
            return candidate
    raise SmokeError("discovery search returned no downloadable source candidates")


def resolve_candidate(api: str, token: str, args: argparse.Namespace) -> dict[str, Any]:
    if args.source_url:
        _, body = request_json(
            "POST",
            f"{api}/discovery/resolve-url",
            token=token,
            payload={"url": args.source_url},
            expected=(200,),
        )
        candidate = body.get("candidate")
        if not isinstance(candidate, dict):
            raise SmokeError("resolve-url response missing candidate")
        print(f"discovery resolve-url: ok provider={candidate.get('provider')} title={candidate.get('title')!r}")
        return candidate

    params = urllib.parse.urlencode({"q": args.query, "providers": args.provider, "limit": str(args.limit)})
    _, body = request_json("GET", f"{api}/discovery/search?{params}", token=token, expected=(200,), timeout=args.http_timeout)
    candidate = choose_candidate(body)
    providers = ",".join(
        f"{p.get('provider')}:{p.get('status')}:{p.get('resultCount')}"
        for p in (body.get("providers") or [])
        if isinstance(p, dict)
    )
    print(
        "discovery search: ok "
        f"query={args.query!r} providers=[{providers}] "
        f"selected={candidate.get('provider')} title={candidate.get('title')!r}"
    )
    return candidate


def queue_source_candidate(api: str, token: str, candidate: dict[str, Any]) -> str:
    _, body = request_json(
        "POST",
        f"{api}/queue/items",
        token=token,
        payload={"position": "last", "sourceCandidate": candidate},
        expected=(202,),
    )
    job_id = body.get("downloadJobId")
    if not job_id:
        raise SmokeError("queue source response missing downloadJobId")
    print(f"queue insertion: ok downloadJobId={job_id}")
    return str(job_id)


def poll_download(api: str, token: str, job_id: str, timeout_seconds: int) -> int:
    deadline = time.time() + timeout_seconds
    last_status = ""
    last_progress: Any = None
    while time.time() < deadline:
        _, body = request_json("GET", f"{api}/downloads/{job_id}", token=token, expected=(200,), timeout=15)
        status = str(body.get("status", ""))
        progress = body.get("progress")
        if status != last_status or progress != last_progress:
            print(f"download job: status={status} progress={progress}")
            last_status = status
            last_progress = progress
        if status == "complete":
            track_id = body.get("track_id") or body.get("trackId")
            if not isinstance(track_id, int):
                raise SmokeError(f"completed job missing track id: {body}")
            return track_id
        if status == "failed":
            raise SmokeError(f"download failed: {body.get('error', 'no error message')}")
        time.sleep(2)
    raise SmokeError(f"download job {job_id} did not complete within {timeout_seconds}s")


def queue_items(api: str, token: str) -> list[dict[str, Any]]:
    _, body = request_json("GET", f"{api}/queue", token=token, expected=(200,), timeout=15)
    items = body.get("items")
    if not isinstance(items, list):
        raise SmokeError("queue response missing items")
    return [item for item in items if isinstance(item, dict)]


def wait_queue_playable(api: str, token: str, job_id: str, track_id: int, timeout_seconds: int) -> str:
    deadline = time.time() + timeout_seconds
    while time.time() < deadline:
        items = queue_items(api, token)
        for item in items:
            if item.get("downloadJobId") == job_id and item.get("trackId") == track_id:
                if item.get("playbackState") == "playable" and item.get("canPlay") is True:
                    queue_item_id = item.get("queueItemId") or item.get("id")
                    if not queue_item_id:
                        raise SmokeError("playable queue item missing queueItemId")
                    print(f"queue projection: ok queueItemId={queue_item_id} playbackState=playable trackId={track_id}")
                    return str(queue_item_id)
        time.sleep(1)
    raise SmokeError("queue item never projected completed download as playable")


def verify_playback(api: str, token: str, track_id: int, http_timeout: int) -> tuple[str, int, str]:
    _, body = request_json(
        "POST",
        f"{api}/playback/urls",
        token=token,
        payload={"trackIds": [track_id], "ttlSeconds": 600},
        expected=(200,),
    )
    urls = body.get("urls") or []
    if len(urls) != 1:
        raise SmokeError(f"playback URL response did not return exactly one URL: {body}")
    item = urls[0]
    signed_url = item.get("url")
    if not signed_url:
        raise SmokeError("playback URL item missing url")
    status, byte_count, content_range = get_signed_range(str(signed_url), http_timeout)
    if status not in (200, 206) or byte_count <= 0:
        raise SmokeError(f"signed URL range read failed: status={status} bytes={byte_count}")
    print(
        "signed playback URL: ok "
        f"status={status} bytes={byte_count} contentType={item.get('contentType')} sizeBytes={item.get('sizeBytes')}"
    )
    return str(signed_url), int(item.get("sizeBytes") or 0), content_range


def storage_key_for_track(track_id: int) -> str:
    user = env("POSTGRES_USER", "omp")
    db_name = env("POSTGRES_DB", "openmusicplayer")
    sql = f"SELECT storage_key FROM tracks WHERE id = {int(track_id)}"
    proc = run_cmd(compose_args("exec", "-T", "postgres", "psql", "-U", user, "-d", db_name, "-At", "-c", sql))
    storage_key = proc.stdout.strip()
    if not storage_key:
        raise SmokeError(f"track {track_id} has no storage_key in PostgreSQL")
    return storage_key


def verify_minio_object(storage_key: str) -> None:
    bucket = env("MINIO_BUCKET", "audio-files")
    root_user = env("MINIO_ROOT_USER", env("MINIO_ACCESS_KEY", "minioadmin"))
    root_password = env("MINIO_ROOT_PASSWORD", env("MINIO_SECRET_KEY", "minioadmin"))
    script = (
        "mc alias set local http://minio:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" >/dev/null; "
        "mc stat " + shlex.quote(f"local/{bucket}/{storage_key}") + " >/dev/null"
    )
    run_cmd(
        compose_args("--profile", "smoke", "run", "--rm", "--entrypoint", "/bin/sh", "minio-smoke", "-lc", script),
        env_overrides={"MINIO_ROOT_USER": root_user, "MINIO_ROOT_PASSWORD": root_password, "MINIO_BUCKET": bucket},
    )
    print(f"MinIO object: ok bucket={bucket} key={storage_key}")


def verify_queue_reorder(api: str, token: str, track_id: int) -> None:
    _, body = request_json(
        "POST",
        f"{api}/queue/items",
        token=token,
        payload={"position": "last", "trackId": track_id},
        expected=(200,),
    )
    items = body.get("items") or []
    if len(items) < 2:
        raise SmokeError("expected at least two queue items after adding duplicate playable track")
    last = items[-1]
    queue_item_id = last.get("queueItemId") or last.get("id")
    if not queue_item_id:
        raise SmokeError("new playable queue item missing queueItemId")
    _, reordered = request_json(
        "PUT",
        f"{api}/queue/reorder",
        token=token,
        payload={"queueItemId": queue_item_id, "toPosition": 0},
        expected=(200,),
    )
    reordered_items = reordered.get("items") or []
    if not reordered_items or (reordered_items[0].get("queueItemId") or reordered_items[0].get("id")) != queue_item_id:
        raise SmokeError("queue reorder did not move playable duplicate to position 0")
    print(f"queue reorder while playback URL is live: ok moved queueItemId={queue_item_id} toPosition=0")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run local OMP discovery-to-playback e2e smoke")
    parser.add_argument("--backend-url", default=env("OMP_BACKEND_BASE_URL", f"http://localhost:{env('SERVER_PORT', '8080')}"))
    parser.add_argument("--query", default=env("OMP_E2E_QUERY", "lofi short audio"))
    parser.add_argument("--provider", default=env("OMP_E2E_PROVIDER", "youtube"))
    parser.add_argument("--limit", type=int, default=env_int("OMP_E2E_LIMIT", 3))
    parser.add_argument("--source-url", default=env("OMP_E2E_SOURCE_URL", ""), help="optional direct URL fallback; when omitted, discovery/search is used")
    parser.add_argument("--email", default=env("OMP_E2E_USER_EMAIL", "local-e2e-smoke@openmusicplayer.local"))
    parser.add_argument("--password", default=env("OMP_E2E_USER_PASSWORD", "local-e2e-smoke-password"))
    parser.add_argument("--username", default=env("OMP_E2E_USERNAME", "local-e2e-smoke"))
    parser.add_argument("--timeout-seconds", type=int, default=env_int("OMP_E2E_TIMEOUT_SECONDS", 240))
    parser.add_argument("--http-timeout", type=int, default=env_int("OMP_E2E_HTTP_TIMEOUT_SECONDS", 30))
    return parser.parse_args()


def main() -> int:
    load_dotenv(DOTENV)
    args = parse_args()
    backend = args.backend_url.rstrip("/")
    api = f"{backend}/api/v1"

    wait_for_backend(backend, min(args.timeout_seconds, 60))
    assert_worker_count_one()
    token = auth_token(api, args.email, args.password, args.username)

    # Make repeated smoke runs deterministic for this user.
    request_json("DELETE", f"{api}/queue", token=token, expected=(200,))
    print("queue reset: ok")

    candidate = resolve_candidate(api, token, args)
    job_id = queue_source_candidate(api, token, candidate)
    track_id = poll_download(api, token, job_id, args.timeout_seconds)
    wait_queue_playable(api, token, job_id, track_id, min(args.timeout_seconds, 60))
    verify_playback(api, token, track_id, args.http_timeout)
    storage_key = storage_key_for_track(track_id)
    verify_minio_object(storage_key)
    verify_queue_reorder(api, token, track_id)

    print("local e2e smoke: ok")
    print(f"evidence: track_id={track_id} download_job_id={job_id} storage_key={storage_key}")
    print(f"mobile web: run scripts/local-low-memory.sh flutter-web-command and verify track {track_id} plays/reorders in a mobile viewport")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SmokeError as exc:
        print(f"local e2e smoke: FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
