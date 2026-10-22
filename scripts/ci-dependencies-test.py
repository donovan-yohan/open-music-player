#!/usr/bin/env python3
"""Offline regressions for the CI dependency source and identity contract."""
import json
import os
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
MODEL_SHA256 = "8c328b45f59d8dd3dff219253ff6a8d6482be57d0133a29140e2febbf8eb8331"
MODEL_URL = (
    "https://huggingface.co/AEmotionStudio/muscriptor-models/resolve/"
    "57db6b00a7c50052b15b0487545b04f22ce2e699/shared/beat_this_final0.ckpt"
)


class DependencySourcesTest(unittest.TestCase):
    def test_checkpoint_transport_changes_without_changing_model_identity(self):
        dockerfile = (ROOT / "backend/Dockerfile").read_text()
        self.assertIn(f'ARG BEAT_THIS_MODEL_URL="{MODEL_URL}"', dockerfile)
        self.assertIn(f'ARG BEAT_THIS_MODEL_SHA256="{MODEL_SHA256}"', dockerfile)
        self.assertIn('"beat-this==1.1.0"', dockerfile)
        self.assertIn(
            'echo "$BEAT_THIS_MODEL_SHA256  /app/models/beat_this-final0.ckpt" | sha256sum -c -',
            dockerfile,
        )
        self.assertIn(
            "RUN python /app/audio_mir.py --check --model /app/models/beat_this-final0.ckpt",
            dockerfile,
        )

    def test_compose_builds_official_pinned_storage_sources(self):
        dockerfile = (ROOT / "backend/Dockerfile").read_text()
        for filename in ("docker-compose.yml", "docker-compose.local-low-memory.yml"):
            with self.subTest(compose=filename):
                env = {key: value for key, value in os.environ.items()
                       if not key.startswith(("COMPOSE_", "MINIO_"))}
                config = json.loads(subprocess.check_output([
                    "docker", "compose", "--env-file", "/dev/null", "--profile", "smoke", "-f",
                    str(ROOT / filename), "config", "--format", "json",
                ], env=env))
                targets = [("minio", "minio-runtime"), ("minio-init", "minio-client")]
                if filename == "docker-compose.local-low-memory.yml":
                    targets.append(("minio-smoke", "minio-client"))
                for name, target in targets:
                    service = config["services"][name]
                    self.assertFalse("image" in service, f"{name} must build the verified source")
                    self.assertEqual(service["build"]["target"], target)
                    self.assertEqual(Path(service["build"]["context"]), ROOT / "backend")
                self.assertEqual(config["services"]["minio"]["healthcheck"]["test"],
                                 ["CMD", "mc", "ready", "local"])
        for source, digest in (
            ("https://codeload.github.com/minio/minio/tar.gz/9e49d5e7a648f00e26f2246f4dc28e6b07f8c84a",
             "45521908307306e925c98d629e1c17d78c8b72b6ee242b1bfb1409f7d8ee5841"),
            ("https://codeload.github.com/minio/mc/tar.gz/7394ce0dd2a80935aded936b09fa12cbb3cb8096",
             "95cd293c7119f16921a6dc515a1fb74a2227f19fd994b9c8b770a154e802ac44"),
        ):
            self.assertIn(source, dockerfile)
            self.assertIn(digest, dockerfile)
        self.assertIn("RELEASE.2025-10-15T17-29-55Z", dockerfile)
        self.assertIn("RELEASE.2025-08-13T08-35-41Z", dockerfile)
        self.assertNotRegex(dockerfile, r"FROM (?:quay.io/)?minio/")
        self.assertRegex(dockerfile, r"FROM alpine:3\.24@sha256:[a-f0-9]{64} AS minio-client")
        self.assertIn("go mod verify", dockerfile)
        self.assertIn("-mod=readonly", dockerfile)
        self.assertEqual(re.findall(r"^FROM .+ AS (\S+)", dockerfile, re.M)[-1], "server-runtime")


if __name__ == "__main__":
    unittest.main()
