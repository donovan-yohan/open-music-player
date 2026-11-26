"""Exercise fixture custody without talking to a shared Docker daemon."""

import contextlib
import io
import os
import re
import secrets
import subprocess
import sys
import traceback
import unittest
from unittest.mock import patch

import ci_backend
from ci_backend_fixtures import fixtures


class DockerBoundary:
    original = "unix:///fixture-original.sock"
    replacement = "unix:///fixture-replacement.sock"

    def __init__(self):
        self.context = self.original
        self.containers = {self.original: {}, self.replacement: {}}
        self.calls = []
        self.databases = {}
        self.final_attestations = 0
        self.fail_cleanup_transport = False
        self.change_label_on_retirement = False
        self.add_name_neighbor = False
        self.provision_error = None
        self.provision_password = None
        self.captured_output = secrets.token_hex(24)

    def __call__(self, argv, *, env, **kwargs):
        executable, *args = argv
        if executable != "docker" or {"DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG"} & env.keys():
            raise AssertionError("unexpected executable or ambient Docker override")
        explicit_host = args[:1] == ["--host"]
        host = args[1] if explicit_host else self.context
        if explicit_host:
            args = args[2:]
        operation, *rest = args
        self.calls.append((operation, host, explicit_host))
        containers = self.containers[host]
        output = ""
        if operation == "context":
            output = self.context
        elif operation == "run":
            name = rest[rest.index("--name") + 1]
            label = rest[rest.index("--label") + 1]
            if label != f"soundq.ci.fixture={name}":
                raise AssertionError("create was missing the exact ownership label")
            output = f"{len(containers) + 1:064x}"
            containers[output] = (name, name)
            if self.add_name_neighbor and name.endswith("-pg"):
                containers["neighbor"] = (name + "-neighbor", "foreign")
        elif operation == "inspect":
            target = rest[-1]
            name, label = containers[target]
            template = rest[rest.index("-f") + 1]
            output = "fixture-image" if template == "{{.Image}}" else label
            if "{{.Name}}" in template:
                output = f"/{name} {label}"
        elif operation == "port":
            output = "127.0.0.1:" + {"5432/tcp": "25432", "6379/tcp": "26379"}[rest[-1]]
        elif operation == "exec":
            if "pg_isready" in rest:
                output = "ready"
            elif "redis-cli" in rest:
                output = "OK" if "SET" in rest else "1"
            elif "psql" in rest:
                if self.provision_error:
                    self.provision_password = rest[2].split("=", 1)[1]
                    if self.provision_error == "timeout":
                        raise subprocess.TimeoutExpired(argv, kwargs["timeout"], stderr=self.captured_output)
                    raise subprocess.CalledProcessError(9, argv, stderr=self.captured_output)
                query = kwargs["input"].strip()
                if query.startswith("CREATE DATABASE"):
                    match = re.fullmatch(
                        r"CREATE DATABASE (\w+) OWNER (\w+); COMMENT ON DATABASE \w+ IS '([^']+)';",
                        query,
                    )
                    if match is None:
                        raise AssertionError("unexpected database provisioning query")
                    name, role, comment = match.groups()
                    nonce = containers[rest[3]][0].split("-")[2]
                    self.databases[name] = f"{name}|{role}|{comment}|ci-{nonce}|f"
                elif query.startswith("SELECT current_database()"):
                    database = rest[rest.index("-d") + 1]
                    output = self.databases[database]
                    if database.startswith("pif_"):
                        self.final_attestations += 1
                        if self.final_attestations == 2:
                            self.context = self.replacement
                            if self.change_label_on_retirement:
                                for key, (name, _) in list(containers.items()):
                                    if name.endswith("-redis"):
                                        containers[key] = (name, "foreign")
            else:
                raise AssertionError("unexpected Docker exec")
        elif operation == "ps":
            if host == self.original and self.context == self.replacement and self.fail_cleanup_transport:
                raise subprocess.CalledProcessError(1, argv, stderr="fixture transport disconnected: No such container")
            selector = rest[rest.index("--filter") + 1]
            if selector.startswith("label=soundq.ci.fixture="):
                ids = [key for key, (_, label) in containers.items() if label == selector.split("=", 2)[2]]
            elif selector.startswith("name="):
                ids = [key for key, (name, _) in containers.items() if re.search(selector[5:], f"/{name}")]
            else:
                raise AssertionError("unexpected fixture ownership selector")
            output = "\n".join(ids)
        elif operation == "rm":
            containers.pop(rest[-1])
        else:
            raise AssertionError("unexpected Docker operation")
        return subprocess.CompletedProcess(argv, 0, output, "")


class FixtureCustodyTests(unittest.TestCase):
    def isolate(self, daemon):
        for boundary in (patch.dict(os.environ, {}, clear=True),
                         patch("ci_backend_fixtures.subprocess.run", side_effect=daemon),
                         patch("ci_backend_fixtures.redis_probe", return_value=True)):
            boundary.start()
            self.addCleanup(boundary.stop)

    def test_late_context_change_cannot_strand_fixtures(self):
        daemon = DockerBoundary()
        self.isolate(daemon)
        receipt = {}
        with fixtures(receipt):
            self.assertEqual(len(daemon.containers[daemon.original]), 2)
        self.assertEqual(daemon.context, daemon.replacement)
        self.assertFalse(bool(daemon.containers[daemon.original]), "original fixtures leaked after default context changed")
        self.assertTrue(receipt.get("retired"))
        self.assertTrue(all(host == daemon.original and pinned for op, host, pinned in daemon.calls if op != "context"))

    def test_cleanup_transport_failure_cannot_report_retirement(self):
        daemon = DockerBoundary()
        daemon.fail_cleanup_transport = True
        self.isolate(daemon)
        receipt = {}
        with self.assertRaises(subprocess.CalledProcessError), fixtures(receipt):
            pass
        self.assertFalse(receipt.get("retired"))
        self.assertTrue(all(host == daemon.original for op, host, _ in daemon.calls if op != "context"))
        self.assertFalse(any(op == "rm" for op, *_ in daemon.calls))

    def test_exact_name_without_exact_label_is_not_absence(self):
        daemon = DockerBoundary()
        daemon.change_label_on_retirement = True
        self.isolate(daemon)
        receipt = {}
        with self.assertRaisesRegex(ValueError, "fixture owner"), fixtures(receipt):
            pass
        self.assertFalse(receipt.get("retired"))
        self.assertEqual([label for _, label in daemon.containers[daemon.original].values()], ["foreign"])

    def test_ordinary_test_failure_still_cleans_up_except_similarly_named_neighbor(self):
        daemon = DockerBoundary()
        daemon.add_name_neighbor = True
        self.isolate(daemon)
        receipt = {}
        with self.assertRaisesRegex(RuntimeError, "ordinary test failure"), fixtures(receipt):
            raise RuntimeError("ordinary test failure")
        self.assertEqual(set(daemon.containers[daemon.original]), {"neighbor"})
        self.assertFalse(daemon.containers[daemon.replacement])

    def cli_provision_failure(self, kind, expected):
        daemon = DockerBoundary()
        daemon.provision_error = kind
        self.isolate(daemon)

        def run(shard, directory):
            with fixtures({}):
                self.fail("provision failure reached test execution")

        output = io.StringIO()
        with (patch.object(ci_backend, "run", run),
              patch.object(sys, "argv", ["ci_backend.py", "run", "api", "unused-output"]),
              contextlib.redirect_stdout(output), contextlib.redirect_stderr(output)):
            try:
                ci_backend.main()
            except SystemExit as error:
                print(error.code, file=sys.stderr)
            except Exception:
                traceback.print_exc()
        text = output.getvalue()
        self.assertTrue(bool(daemon.provision_password), "provision did not reach a credential-bearing subprocess")
        self.assertFalse(bool(daemon.provision_password and daemon.provision_password in text),
                         "CLI output exposed credential-bearing subprocess argv")
        self.assertFalse(daemon.captured_output in text, "CLI output exposed captured subprocess stderr")
        self.assertFalse("Traceback" in text, "CLI emitted a traceback")
        self.assertTrue(text == expected + "\n", "CLI did not emit only the expected diagnostic")
        self.assertFalse(daemon.containers[daemon.original])

    def test_timeout_redacts_argv_traceback_and_subprocess_output(self):
        self.cli_provision_failure("timeout", "backend CI command docker timed out after 20s")

    def test_nonzero_exit_remains_redacted(self):
        self.cli_provision_failure("nonzero", "backend CI command docker exited 9")


if __name__ == "__main__":
    unittest.main()
