#!/usr/bin/env python3
"""Check the native source publication payload. Never read ignored local config.

Reports only repository-relative paths and categories, never matched values.
This is a bounded privacy/portability guard, not a credential audit certificate.
"""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PREFIXES = ("android/", "client/native/")
SKIP = {"build", ".gradle", ".cxx", "__pycache__", "node_modules"}
PATTERNS = {
    "absolute-home-path": re.compile(r"(?:/Users/|/home/|[A-Za-z]:\\Users\\)[^\s/\\]+"),
    "agent-profile-storage": re.compile(r"\.hermes[/\\](?:profiles|reports|cache|skills)[/\\]"),
    "host-package-manager-path": re.compile(r"/opt/homebrew/"),
}


def violations(text):
    return [category for category, pattern in PATTERNS.items() if pattern.search(text)]


def source_files():
    raw = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT)
    for name in sorted(set(raw.split(b"\0"))):
        if not name:
            continue
        relative = name.decode()
        path = Path(relative)
        if relative.startswith(PREFIXES):
            yield relative, ROOT / path


def prohibited_entry(relative, path):
    # Refuse accidentally tracked local files without opening their contents.
    if path.name == "local.properties" or path.name == ".env" or path.name.startswith(".env."):
        return "local-config-in-payload"
    if path.suffix.lower() in {".jks", ".keystore", ".p12", ".pfx", ".pem", ".key"}:
        return "signing-or-key-material-in-payload"
    if any(part in SKIP for part in Path(relative).parts):
        return "generated-output-in-payload"
    if path.is_symlink():
        return "symlink-in-payload"
    return None


def main():
    findings = []
    scanned = 0
    for relative, path in source_files():
        category = prohibited_entry(relative, path)
        if category:
            findings.append({"path": relative, "category": category})
            continue
        if not path.is_file():
            continue
        try:
            text = path.read_bytes().decode("utf-8")
        except UnicodeDecodeError:
            continue
        if "\0" in text:
            continue
        scanned += 1
        findings.extend({"path": relative, "category": category} for category in violations(text))
    print(json.dumps({"textFilesScanned": scanned, "findings": findings,
                      "publicationSafe": not findings}, indent=2))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
