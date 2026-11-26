"""Classify the tested PR merge; uncertainty always selects the full CI suite."""

import os
from pathlib import Path
import re
import subprocess


# Deliberately not docs/** or *.md: e.g. the Go suite reads the AcousticBrainz
# runbook as test data. Expand only after auditing CI consumers of exact paths.
DELIVERY_FILES = {
    b".github/ISSUE_TEMPLATE/agentic-work-packet.md": b"100644",
    b".github/pull_request_template.md": b"100644",
    b"AGENTS.md": b"100644",
    b"CLAUDE.md": b"100644",
    b"README.md": b"100644",
    b"docs/agentic-delivery.md": b"100644",
    b"docs/context-map.md": b"100644",
    b"docs/adr/0002-agentic-delivery-harness.md": b"100644",
    b"scripts/release-audit": b"100755",
}
SHA = re.compile(r"[0-9a-f]{40}")
MODIFIED = re.compile(rb":([0-7]{6}) ([0-7]{6}) [0-9a-f]{40} [0-9a-f]{40} M")


def git(*args):
    return subprocess.check_output(["git", "--no-replace-objects", *args], stderr=subprocess.PIPE)


def classify(event, merge, head):
    if event != "pull_request" or not SHA.fullmatch(merge) or not SHA.fullmatch(head):
        return "full", "not an identified pull request merge"
    try:
        if git("rev-parse", "--verify", "HEAD").strip() != merge.encode():
            return "full", "checkout does not match the tested SHA"
        # Read the actual commit's headers, not a merge-base or today's main.
        commit = git("cat-file", "commit", merge).split(b"\n\n", 1)[0]
        parents = [line[7:] for line in commit.split(b"\n") if line.startswith(b"parent ")]
        if len(parents) != 2 or parents[0] == parents[1] or parents[1] != head.encode():
            return "full", "checkout does not have the expected PR head as second parent"
        base = parents[0].decode("ascii")
        if not SHA.fullmatch(base) or git("cat-file", "-t", head).strip() != b"commit":
            return "full", "missing or invalid parent"
        # Raw records include modes and both sides of a rename (delete/add).
        # Use a local NUL-delimited diff, not the service's capped path list.
        changes = git("diff", "--raw", "-z", "--no-abbrev", "--no-renames",
                      "--ignore-submodules=none", "--no-ext-diff", "--no-textconv",
                      base, merge, "--")
    except (subprocess.CalledProcessError, OSError, UnicodeDecodeError):
        return "full", "unable to compare the tested merge with its first parent"

    records = changes.split(b"\0")
    if records[-1] != b"" or len(records) < 3 or len(records) % 2 != 1:
        return "full", "empty or invalid Git change list"
    for metadata, path in zip(records[:-1:2], records[1:-1:2]):
        modified = MODIFIED.fullmatch(metadata)
        mode = DELIVERY_FILES.get(path)
        if mode is None or modified is None or modified.groups() != (mode, mode):
            return "full", "change is not a content edit to an allowlisted delivery file"
    return "delivery-only", "all changes are allowlisted delivery-file edits"


def main():
    scope, reason = classify(os.getenv("GITHUB_EVENT_NAME", ""), os.getenv("GITHUB_SHA", ""),
                             os.getenv("PR_HEAD_SHA", ""))
    print(f"PR CI scope: {scope} ({reason})", flush=True)
    with Path(os.environ["GITHUB_OUTPUT"]).open("a", encoding="utf-8") as output:
        output.write(f"scope={scope}\n")


if __name__ == "__main__":
    main()
