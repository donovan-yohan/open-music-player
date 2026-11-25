"""Private loopback PostgreSQL and Redis for one serial Go test shard."""

import contextlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import time


def docker(*args, **kwargs):
    return subprocess.run(
        ["docker", *args], check=True, text=True, capture_output=True,
        timeout=kwargs.pop("timeout", 20), env=test_environment(), **kwargs,
    ).stdout.strip()


def test_environment():
    # Do not forward ambient application, provider, libpq or override settings.
    keys = "PATH HOME TMPDIR RUNNER_TEMP GOCACHE GOMODCACHE GOPATH".split()
    env = {key: os.environ[key] for key in keys if key in os.environ}
    return env | {"GOENV": "off", "GOWORK": "off", "GOTOOLCHAIN": "local"}


def ready(probe):
    for _ in range(50):
        try:
            if probe():
                return
        except (subprocess.CalledProcessError, OSError):
            pass
        time.sleep(0.2)
    raise ValueError("private fixture did not become ready")


def host_port(container, internal):
    binding = docker("port", container, f"{internal}/tcp").split(":")
    if len(binding) != 2 or binding[0] != "127.0.0.1" or not binding[1].isdigit():
        raise ValueError("fixture has no unique loopback binding")
    return int(binding[1])


@contextlib.contextmanager
def owned_container(nonce, service, port, *args):
    owner = f"soundq-ci-{nonce}-{service}"
    # Arm cleanup before launch: an interrupted docker client may have created it.
    try:
        container = docker(
            "run", "-d", "--name", owner, "--label", f"soundq.ci.fixture={owner}",
            "-p", f"127.0.0.1::{port}", *args, timeout=120,
        )
        if docker("inspect", "-f", '{{index .Config.Labels "soundq.ci.fixture"}}', container) != owner:
            raise ValueError(f"unexpected fixture owner: {service}")
        yield container
    finally:
        found = docker("ps", "-aq", "--no-trunc", "--filter", f"label=soundq.ci.fixture={owner}").splitlines()
        if found:
            if len(found) != 1:
                raise ValueError(f"ambiguous fixture owner: {service}")
            docker("rm", "-f", "-v", found[0])
        if docker("ps", "-aq", "--filter", f"label=soundq.ci.fixture={owner}"):
            raise ValueError(f"fixture still present: {service}")


def redis_probe(port, command, response):
    with socket.create_connection(("127.0.0.1", port), timeout=2) as conn:
        conn.sendall(command)
        with conn.makefile("rb") as stream:
            return all(stream.readline() == line for line in response.splitlines(keepends=True))


@contextlib.contextmanager
def fixtures(receipt):
    if os.environ.get("OMP_ALLOW_PROTECTED_DB_TESTS") or any(
        os.environ.get(key) for key in ("DOCKER_HOST", "DOCKER_CONTEXT")
    ):
        raise ValueError("ambient protection override or Docker endpoint is not supported")
    docker_host = docker("context", "inspect", "--format", "{{.Endpoints.docker.Host}}")
    if not docker_host.startswith("unix://"):
        raise ValueError("fixtures require a local Docker socket")

    nonce = secrets.token_hex(12)
    marker = secrets.token_hex(32)
    admin_password = secrets.token_hex(24)
    root = f"omp_ci_{nonce}_test"
    with (
        owned_container(nonce, "pg", 5432, "-e", "POSTGRES_USER=ci_admin",
                        "-e", f"POSTGRES_PASSWORD={admin_password}", "postgres:15-alpine") as pg,
        owned_container(nonce, "redis", 6379, "redis:7-alpine", "redis-server",
                        "--save", "", "--appendonly", "no") as redis,
    ):
        pg_port, redis_port = host_port(pg, 5432), host_port(redis, 6379)
        protected = {"5434", *(p.strip() for p in os.environ.get("OMP_PROTECTED_DB_PORTS", "").split(","))}
        if str(pg_port) in protected:
            raise ValueError("refusing protected PostgreSQL fixture port")
        ready(lambda: docker("exec", pg, "pg_isready", "-h", "127.0.0.1", "-U", "ci_admin", "-d", "postgres"))
        ready(lambda: redis_probe(redis_port, b"PING\r\n", b"+PONG\r\n"))
        if not redis_probe(redis_port, b"DBSIZE\r\n", b":0\r\n"):
            raise ValueError("Redis fixture is not fresh")
        # Write only through its owned container; a loopback read attests the
        # endpoint the tests will actually use, not merely an internal PING.
        witness = "soundq-ci-owner:" + nonce
        if docker("exec", redis, "redis-cli", "SET", witness, nonce) != "OK":
            raise ValueError("could not seed the Redis ownership witness")
        if not redis_probe(redis_port, f"GET {witness}\r\n".encode(), f"${len(nonce)}\r\n".encode() + nonce.encode() + b"\r\n"):
            raise ValueError("Redis loopback ownership mismatch")
        if docker("exec", redis, "redis-cli", "DEL", witness) != "1":
            raise ValueError("could not retire the Redis ownership witness")

        def sql(database, role, password, query):
            return docker(
                "exec", "-i", "-e", f"PGPASSWORD={password}", pg, "psql", "-XqAt",
                "-v", "ON_ERROR_STOP=1", "-h", "127.0.0.1", "-U", role, "-d", database,
                input=query,
            )

        def provision(name, role, password, comment):
            if role != "ci_admin":
                sql("postgres", "ci_admin", admin_password,
                    f"CREATE ROLE {role} LOGIN CREATEDB PASSWORD '{password}';")
            sql("postgres", "ci_admin", admin_password,
                f"CREATE DATABASE {name} OWNER {role}; COMMENT ON DATABASE {name} IS '{comment}';")
            # Match the canonical marker shape without changing migration defaults.
            sql(name, role, password, f"""
                CREATE TABLE omp_environment (
                    id SMALLINT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
                    name TEXT NOT NULL DEFAULT 'unnamed',
                    protected BOOLEAN NOT NULL DEFAULT FALSE,
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                );
                INSERT INTO omp_environment (name) VALUES ('ci-{nonce}');
            """)
            attest(name, role, password, comment)
            return name, role, password, comment

        def attest(name, role, password, comment):
            witness = sql(name, role, password, """
                SELECT current_database(), current_user, shobj_description(oid, 'pg_database'),
                       (SELECT name FROM omp_environment WHERE id=1),
                       (SELECT protected FROM omp_environment WHERE id=1)
                FROM pg_database WHERE datname = current_database();
            """)
            if witness != f"{name}|{role}|{comment}|ci-{nonce}|f":
                raise ValueError(f"database custody marker mismatch: {name}")

        records = []

        def dsn(name, role="ci_admin", password=admin_password, *, private=False):
            comment = f"private-fence-fixture:{marker}" if private else f"ci-fixture:{nonce}"
            records.append(provision(name, role, password, comment))
            suffix = "&connect_timeout=3" if private else ""
            return f"postgres://{role}:{password}@127.0.0.1:{pg_port}/{name}?sslmode=disable{suffix}"

        shared = dsn(root)
        redis_addr = f"127.0.0.1:{redis_port}"
        redis_url = f"redis://{redis_addr}"
        private = f"pif_{nonce}"
        env = test_environment() | {
            "DATABASE_URL": shared, "OMP_POSTGRES_TEST_DSN": shared,
            "REDIS_URL": redis_url, "OMP_REDIS_TEST_URL": f"{redis_url}/14",
            "OMP_MANUAL_SYNC_REDIS_URL": f"{redis_url}/15",
            "OMP_CONNECT_POSTGRES_DSN": dsn(f"connect_{root}"), "OMP_CONNECT_REDIS_ADDR": redis_addr,
            "JAM_TEST_DSN": dsn(f"jam_{root}"), "JAM_TEST_REDIS": redis_addr,
            "SOUNDQ_WEEKLY_TEST_DSN": dsn("weekly_fixture", "weekly_fixture", secrets.token_hex(24)),
            "SOUNDQ_RADAR_POSTGRES_DSN": dsn("radar_daily_fixture", "radar_daily_fixture", secrets.token_hex(24)),
            "SOUNDQ_RADAR_REDIS_ADDR": redis_addr,
            "OMP_PRIVATE_FENCE_TEST_DSN": dsn(private, private, secrets.token_hex(32), private=True),
            "OMP_PRIVATE_FENCE_TEST_MARKER": marker,
        }
        receipt.update(owner=nonce, containers=[pg, redis], ports=[pg_port, redis_port],
                       images=[docker("inspect", "-f", "{{.Image}}", item) for item in (pg, redis)],
                       databases=[name for name, *_ in records])
        try:
            yield env
        finally:
            for record in records:
                attest(*record)
    receipt["retired"] = True
