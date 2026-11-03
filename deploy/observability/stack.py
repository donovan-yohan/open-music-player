#!/usr/bin/env python3
"""Operate only the owned SoundQ observability Compose project. Never prints env values."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time

from check import API, check_health, load_env


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", required=True, type=Path)
    parser.add_argument("action", choices=("up", "down", "stop", "status", "validate"))
    args = parser.parse_args()
    config = load_env(args.env_file)
    retention = int(config.get("OBS_RETENTION_DAYS", "7"))
    if retention < 3:
        parser.error("OBS_RETENTION_DAYS must be at least 3; zero disables retention")
    env = dict(os.environ)
    env.update(config)
    base = ["docker", "compose", "--env-file", os.devnull,
            "--project-name", "soundq-observability-preview",
            "--file", str(Path(__file__).resolve().with_name("compose.yaml"))]
    commands = {
        "up": ["up", "--detach"], "down": ["down"], "stop": ["stop"],
        "status": ["ps"],
        "validate": ["run", "--rm", "--no-deps", "collector", "validate",
                     "--config=/etc/otelcol-contrib/config.yaml"],
    }
    subprocess.run(base + ["config", "--quiet"], env=env, check=True)
    subprocess.run(base + commands[args.action], env=env, check=True)
    if args.action == "up":
        api = API(config)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                check_health(api)
                print("UI, authenticated API, and Collector health passed")
                return
            except (RuntimeError, OSError, AssertionError):
                time.sleep(2)
        raise RuntimeError("services failed health checks within 90s")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
