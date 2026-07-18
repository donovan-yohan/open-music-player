from __future__ import annotations

import os

import pytest

from candidate_assembly.evalrunner.cli import (
    _apply_live_endpoint_overrides,
    _build_parser,
    main as cli_main,
)


def test_live_matrix_overrides_base_url_and_model_without_key_flag(monkeypatch):
    monkeypatch.setenv("AGENT_SEARCH_API_KEY", "opaque-existing-key")
    monkeypatch.setenv("AGENT_SEARCH_BASE_URL", "https://old.invalid/v1")
    monkeypatch.setenv("AGENT_SEARCH_MODEL", "old-model")

    _apply_live_endpoint_overrides(" https://models.example/v1/ ", " model-b ")

    assert os.environ["AGENT_SEARCH_BASE_URL"] == "https://models.example/v1/"
    assert os.environ["AGENT_SEARCH_MODEL"] == "model-b"
    assert os.environ["AGENT_SEARCH_API_KEY"] == "opaque-existing-key"

    with pytest.raises(SystemExit):
        _build_parser().parse_args(["--api-key", "must-not-be-supported"])


@pytest.mark.parametrize("flag", ["--base-url", "--model"])
def test_matrix_overrides_are_rejected_outside_live(flag, capsys):
    assert cli_main(["--mode", "replay", flag, "value"]) == 2
    assert "require --mode live" in capsys.readouterr().err


def test_skip_probe_is_rejected_outside_live(capsys):
    assert cli_main(["--mode", "replay", "--skip-probe"]) == 2
    assert "require --mode live" in capsys.readouterr().err


def test_live_initialization_error_is_typed_and_redacted(monkeypatch, capsys):
    from candidate_assembly import model_client

    def fail_from_env():
        raise RuntimeError("https://models.example/v1 key=super-secret-token")

    monkeypatch.setattr(model_client.ModelConfig, "from_env", staticmethod(fail_from_env))

    assert cli_main(["--mode", "live"]) == 1
    rendered = capsys.readouterr().err
    assert rendered == "agent-search eval: FAIL: LiveModelInitializationError\n"
    assert "models.example" not in rendered
    assert "super-secret-token" not in rendered
