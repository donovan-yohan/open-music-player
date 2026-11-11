#!/usr/bin/env python3
"""Generate throwaway local bootstrap credentials without printing them."""
import argparse
import base64
import os
from pathlib import Path
import secrets
import socket


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--ui-port", type=int, default=15080)
    parser.add_argument("--otlp-port", type=int, default=14318)
    parser.add_argument("--health-port", type=int, default=14333)
    args = parser.parse_args()
    target = args.env_file.expanduser().resolve()
    repo = Path(__file__).resolve().parents[2]
    if target == repo or repo in target.parents:
        parser.error("credential file must be outside the repository")
    ports = (args.ui_port, args.otlp_port, args.health_port)
    if len(set(ports)) != 3 or not all(1024 <= port <= 65535 for port in ports):
        parser.error("choose three distinct unprivileged TCP ports")
    for port in ports:
        with socket.socket() as sock:
            try:
                sock.bind(("127.0.0.1", port))
            except OSError:
                parser.error("port %s unavailable; select another --*-port" % port)
    email = "soundq-preview@example.invalid"
    password = "Aa1!" + secrets.token_urlsafe(36)
    auth = base64.b64encode((email + ":" + password).encode()).decode()
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as out:
        out.write("ZO_ROOT_USER_EMAIL=%s\nZO_ROOT_USER_PASSWORD=%s\nOPENOBSERVE_AUTH=%s\n"
                  "OBS_UI_PORT=%s\nOBS_OTLP_PORT=%s\nOBS_HEALTH_PORT=%s\n"
                  "OBS_RETENTION_DAYS=7\n" % (email, password, auth, *ports))
    print(target)


if __name__ == "__main__":
    main()
