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

import getpass
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

# Wall-clock ceiling for a single scorer invocation. The Go binary is hermetic
# and finishes in milliseconds; a hang means something is wrong, so bound it
# rather than block the eval run indefinitely.
_GO_RANK_TIMEOUT_S = 60


class GoRankerError(RuntimeError):
    """Raised when the Go scorer cannot be built or invoked."""


def _backend_dir() -> Path:
    override = os.environ.get("AGENT_SEARCH_BACKEND_DIR")
    if override:
        return Path(override)
    return _REPO_ROOT / "backend"


def _build_cache_dir() -> Path:
    """A per-user, private (0o700) build-cache directory under the temp dir.

    A fixed shared name (``omp-sourcequality-rank``) in a world-writable temp dir
    is a hijack vector: another user can pre-create it (or symlink it) and race
    the build output. Scoping the name to the current user and refusing a
    directory we do not own closes that while still reusing the built binary
    across runs for the same user.
    """

    getuid = getattr(os, "getuid", None)
    if getuid is not None:
        suffix = str(getuid())
    else:  # pragma: no cover - non-POSIX fallback
        suffix = getpass.getuser()
    out_dir = Path(tempfile.gettempdir()) / f"omp-sourcequality-rank-{suffix}"
    try:
        out_dir.mkdir(mode=0o700, exist_ok=True)
    except OSError as exc:
        raise GoRankerError(f"could not create build cache dir {out_dir}: {exc}") from exc
    if getuid is not None:
        # ``mkdir(exist_ok=True)`` does not touch an already-existing dir's owner
        # or mode, so verify we actually own it before trusting the build output.
        try:
            owner = out_dir.stat().st_uid
        except OSError as exc:  # pragma: no cover - unexpected stat failure
            raise GoRankerError(f"could not stat build cache dir {out_dir}: {exc}") from exc
        if owner != getuid():
            raise GoRankerError(
                f"build cache dir {out_dir} is not owned by the current user "
                f"(uid {getuid()}); refusing to use it"
            )
    return out_dir


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
    out_dir = _build_cache_dir()
    binary = out_dir / "sourcequality-rank"
    build_env = os.environ.copy()
    # The scorer's JSON contract does not consume Go VCS build metadata. Disable
    # stamping so fixture replay remains hermetic in detached/parallel worktrees
    # where `go build` cannot query the enclosing repository status.
    if "-buildvcs=false" not in build_env.get("GOFLAGS", ""):
        build_env["GOFLAGS"] = (build_env.get("GOFLAGS", "") + " -buildvcs=false").strip()
    try:
        subprocess.run(
            [go, "build", "-o", str(binary), "./cmd/sourcequality-rank"],
            cwd=str(backend),
            check=True,
            capture_output=True,
            text=True,
            env=build_env,
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
            timeout=_GO_RANK_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired as exc:
        raise GoRankerError(
            f"sourcequality-rank timed out after {_GO_RANK_TIMEOUT_S}s"
        ) from exc
    except subprocess.CalledProcessError as exc:  # pragma: no cover - env failure
        raise GoRankerError(f"sourcequality-rank failed: {exc.stderr.strip()}") from exc
    try:
        decoded = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise GoRankerError(f"sourcequality-rank returned invalid JSON: {exc}") from exc
    return decoded.get("ranked", [])
