from __future__ import annotations

import os
import subprocess

import pytest

from candidate_assembly import go_ranker


def test_build_cache_dir_is_per_user_and_private(tmp_path, monkeypatch):
    # Scope the shared temp dir to this test so we never touch the real one.
    monkeypatch.setattr(go_ranker.tempfile, "gettempdir", lambda: str(tmp_path))
    out_dir = go_ranker._build_cache_dir()

    # Per-user name (no fixed shared "omp-sourcequality-rank" path) ...
    assert out_dir.name != "omp-sourcequality-rank"
    if hasattr(os, "getuid"):
        assert str(os.getuid()) in out_dir.name
        # ... created private (0o700) so another user cannot race the build output.
        assert (out_dir.stat().st_mode & 0o777) == 0o700
    # Idempotent within a process: the build stays cached at a stable location.
    assert go_ranker._build_cache_dir() == out_dir


@pytest.mark.skipif(not hasattr(os, "getuid"), reason="ownership guard is POSIX-only")
def test_build_cache_dir_rejects_dir_not_owned(tmp_path, monkeypatch):
    monkeypatch.setattr(go_ranker.tempfile, "gettempdir", lambda: str(tmp_path))
    # Pretend the current process is a different uid: the dir it creates is owned
    # by the real uid, so the ownership guard must refuse it (hijack scenario).
    real_uid = os.getuid()
    monkeypatch.setattr(go_ranker.os, "getuid", lambda: real_uid + 1, raising=False)
    with pytest.raises(go_ranker.GoRankerError) as excinfo:
        go_ranker._build_cache_dir()
    assert "not owned" in str(excinfo.value)


def test_rank_maps_timeout_to_go_ranker_error(monkeypatch):
    monkeypatch.setattr(go_ranker, "_resolve_binary", lambda: "/nonexistent/sourcequality-rank")

    captured: dict = {}

    def fake_run(*args, **kwargs):
        captured["timeout"] = kwargs.get("timeout")
        raise subprocess.TimeoutExpired(cmd=args[0], timeout=kwargs.get("timeout"))

    monkeypatch.setattr(go_ranker.subprocess, "run", fake_run)

    with pytest.raises(go_ranker.GoRankerError) as excinfo:
        go_ranker.rank("some query", [])

    # A bounded timeout is passed and its expiry maps to the typed error path.
    assert captured["timeout"] == go_ranker._GO_RANK_TIMEOUT_S
    assert "timed out" in str(excinfo.value)
