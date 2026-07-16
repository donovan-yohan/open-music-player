"""Bridge to the real Go source-quality scorer via the ``sourcequality-rank`` CLI.

The deterministic baseline arm must use the production scorer, not a Python
re-implementation, so it shells out to ``backend/cmd/sourcequality-rank``. The Go
binary is built once per process into a temp location and cached; each call feeds
one ``{"query", "candidates"}`` request on stdin and reads the ranked candidates
(with attached ``sourceQuality`` metadata) back on stdout. Hermetic and
network-free: no model, no HTTP, just the local Go toolchain and the fixture
pool.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Optional

_PACKAGE_ROOT = Path(__file__).resolve()
# .../agents/candidate_assembly/src/candidate_assembly/go_ranker.py -> repo root.
_REPO_ROOT = _PACKAGE_ROOT.parents[4]

_cached_binary: Optional[str] = None


class GoRankerError(RuntimeError):
    """Raised when the Go scorer cannot be built or invoked."""


def _backend_dir() -> Path:
    override = os.environ.get("AGENT_SEARCH_BACKEND_DIR")
    if override:
        return Path(override)
    return _REPO_ROOT / "backend"


def _resolve_binary() -> str:
    global _cached_binary
    prebuilt = os.environ.get("AGENT_SEARCH_SOURCEQUALITY_BIN")
    if prebuilt:
        if not Path(prebuilt).exists():
            raise GoRankerError(f"AGENT_SEARCH_SOURCEQUALITY_BIN does not exist: {prebuilt}")
        return prebuilt
    if _cached_binary and Path(_cached_binary).exists():
        return _cached_binary
    go = shutil.which("go")
    if not go:
        raise GoRankerError("the Go toolchain is required to run the deterministic arm but 'go' was not found on PATH")
    backend = _backend_dir()
    if not backend.exists():
        raise GoRankerError(f"backend directory not found at {backend}")
    out_dir = Path(tempfile.gettempdir()) / "omp-sourcequality-rank"
    out_dir.mkdir(parents=True, exist_ok=True)
    binary = out_dir / "sourcequality-rank"
    try:
        subprocess.run(
            [go, "build", "-o", str(binary), "./cmd/sourcequality-rank"],
            cwd=str(backend),
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:  # pragma: no cover - env failure
        raise GoRankerError(f"failed to build sourcequality-rank: {exc.stderr.strip()}") from exc
    _cached_binary = str(binary)
    return _cached_binary


def rank(query: str, candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Return the candidates ranked by the Go scorer with sourceQuality attached."""

    binary = _resolve_binary()
    payload = json.dumps({"query": query, "candidates": candidates})
    try:
        completed = subprocess.run(
            [binary],
            input=payload,
            check=True,
            capture_output=True,
            text=True,
        )
    except subprocess.CalledProcessError as exc:  # pragma: no cover - env failure
        raise GoRankerError(f"sourcequality-rank failed: {exc.stderr.strip()}") from exc
    try:
        decoded = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise GoRankerError(f"sourcequality-rank returned invalid JSON: {exc}") from exc
    return decoded.get("ranked", [])
