from __future__ import annotations

import hashlib
import json
import wave
from pathlib import Path

import pytest

from audio_mir_eval.cli import main as cli_main
from audio_mir_eval.io import load_predictions, sha256_file
from audio_mir_eval.vdj_export import main, parse_bpm, parse_key, remap_audio_path


def _write_wav(path: Path, *, seconds: float = 4.0, sample: bytes = b"\0\0") -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(8000)
        output.writeframes(sample * round(seconds * 8000))


def _write_manifest(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(row) + "\n" for row in rows), encoding="utf-8")


def _manifest_row(track_id: str, audio_path: Path) -> dict:
    return {
        "id": track_id,
        "audio_path": str(audio_path),
        "audio_sha256": sha256_file(audio_path),
        "label_kind": "ground_truth",
        "provenance": {"dataset": "fixture"},
        "reference": {
            "bpm": 120.0,
            "key": "A minor",
            "beats_seconds": [1, 1.5, 2, 2.5],
        },
    }


@pytest.mark.parametrize(
    ("value", "encoding", "expected"),
    [
        ("0.461538", "auto", (130.00013, "period")),
        ("130", "auto", (130.0, "bpm")),
        ("0.5", "period", (120.0, "period")),
        ("120", "bpm", (120.0, "bpm")),
    ],
)
def test_parse_bpm_supports_auto_and_forced_encodings(value, encoding, expected):
    parsed = parse_bpm(value, encoding)

    assert parsed is not None
    assert parsed[0] == pytest.approx(expected[0])
    assert parsed[1] == expected[1]


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("Am", (9, "minor")),
        ("G#m", (8, "minor")),
        ("F#", (6, "major")),
        ("Db", (1, "major")),
        ("8A", (9, "minor")),
        ("12B", (4, "major")),
        ("not-a-key", None),
    ],
)
def test_parse_key_accepts_musical_and_camelot_notation(value, expected):
    assert parse_key(value) == expected


def test_windows_root_remap_requires_a_path_boundary():
    mappings = [(r"C:\Users\you\Music", "/local-audio")]

    assert remap_audio_path(r"C:\Users\you\Music\folder\track.wav", mappings) == Path(
        "/local-audio/folder/track.wav"
    )
    assert remap_audio_path(r"C:\Users\you\Musical\track.wav", mappings) == Path(
        r"C:\Users\you\Musical\track.wav"
    )


def test_windows_root_remap_ignores_prefix_case_and_preserves_path_remainder():
    mappings = [(r"C:\Users\you\Music", "/local-audio")]

    assert remap_audio_path(r"c:\users\You\music\Folder\Track.wav", mappings) == Path(
        "/local-audio/Folder/Track.wav"
    )


def test_posix_root_remap_remains_case_sensitive():
    mappings = [("/Users/you/Music", "/local-audio")]

    assert remap_audio_path("/users/you/Music/track.wav", mappings) == Path(
        "/users/you/Music/track.wav"
    )


def test_export_joins_remapped_audio_and_marks_missing_manifest_tracks(
    tmp_path: Path, capsys, monkeypatch
):
    audio_root = tmp_path / "local-audio"
    audio_root.mkdir()
    period = audio_root / "period.wav"
    bpm = audio_root / "bpm.wav"
    missing = audio_root / "missing.wav"
    _write_wav(period)
    _write_wav(bpm, sample=b"\1\0")
    _write_wav(missing, sample=b"\2\0")
    manifest = tmp_path / "manifest.jsonl"
    _write_manifest(
        manifest,
        [
            _manifest_row("period", period),
            _manifest_row("bpm", bpm),
            _manifest_row("missing", missing),
        ],
    )
    database = tmp_path / "database.xml"
    fixture = (Path(__file__).parent / "fixtures/vdj_database_sample.xml").read_text(
        encoding="utf-8"
    )
    database.write_text(fixture, encoding="utf-8")
    output = tmp_path / "predictions.jsonl"

    def audio_probe_must_not_run(_path: Path) -> float:
        pytest.fail("Infos SongLength should avoid an audio duration probe")

    monkeypatch.setattr(
        "audio_mir_eval.vdj_export._duration_from_audio", audio_probe_must_not_run
    )

    assert (
        main(
            [
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--audio-root-map",
                f"OLD_ROOT={audio_root}",
                "--output",
                str(output),
                "--assume-44-bars",
            ]
        )
        == 0
    )

    run, predictions = load_predictions(output)
    assert run["analyzer"]["analyzer"] == "virtualdj"
    assert (
        run["analyzer"]["database_sha256"]
        == hashlib.sha256(database.read_bytes()).hexdigest()
    )
    assert run["analyzer"]["bpm_interpretations"] == {
        "bpm": "bpm",
        "period": "period",
    }
    assert predictions["period"]["bpm"] == 120.0
    assert predictions["period"]["provenance"]["bpm_encoding"] == "period"
    assert predictions["period"]["beats_ms"] == [
        1000,
        1500,
        2000,
        2500,
        3000,
        3500,
        4000,
    ]
    assert predictions["period"]["downbeats_ms"] == [1000, 3000]
    assert predictions["period"]["key_index"] == 9
    assert predictions["bpm"]["bpm"] == 128.0
    assert predictions["bpm"]["mode"] == "major"
    assert predictions["missing"]["error"]["type"] == "MissingVirtualDJPrediction"
    captured = capsys.readouterr()
    assert "matched=2 xml_only=1 manifest_only=1" in captured.out
    assert f"audio_root_map_applied=OLD_ROOT={audio_root}:3" in captured.out


def test_export_reports_distinct_root_map_counts_and_warns_only_for_zero_matches(
    tmp_path: Path, capsys
):
    audio = tmp_path / "track.wav"
    _write_wav(audio)
    manifest = tmp_path / "manifest.jsonl"
    _write_manifest(manifest, [_manifest_row("track", audio)])
    database = tmp_path / "database.xml"
    database.write_text(
        '<VirtualDJ><Song FilePath="OLD_ROOT/nested/track.wav" /></VirtualDJ>',
        encoding="utf-8",
    )
    output = tmp_path / "predictions.jsonl"
    zero_match_map = f"OLD_ROOT={tmp_path / 'unused'}"
    applied_map = f"OLD_ROOT/nested={tmp_path}"

    assert (
        main(
            [
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--audio-root-map",
                zero_match_map,
                "--audio-root-map",
                applied_map,
                "--output",
                str(output),
            ]
        )
        == 0
    )

    captured = capsys.readouterr()
    assert (
        "audio_root_map_applied="
        f"OLD_ROOT/nested={tmp_path}:1,OLD_ROOT={tmp_path / 'unused'}:0" in captured.out
    )
    assert (
        f"WARNING: --audio-root-map {zero_match_map} matched zero songs" in captured.err
    )
    assert (
        f"WARNING: --audio-root-map {applied_map} matched zero songs"
        not in captured.err
    )


def test_exported_artifact_scores_with_existing_cli(tmp_path: Path):
    audio = tmp_path / "track.wav"
    _write_wav(audio, seconds=8)
    manifest = tmp_path / "manifest.jsonl"
    _write_manifest(
        manifest,
        [
            {
                **_manifest_row("track", audio),
                "reference": {
                    "bpm": 120.0,
                    "key": "A minor",
                    "beats_seconds": [5, 5.5, 6, 6.5],
                },
            }
        ],
    )
    database = tmp_path / "database.xml"
    database.write_text(
        '<VirtualDJ><Song FilePath="OLD_ROOT/track.wav" Duration="8">'
        '<Scan Version="8" Bpm="0.5" Key="8A" FirstBeat="0" />'
        "</Song></VirtualDJ>",
        encoding="utf-8",
    )
    predictions = tmp_path / "predictions.jsonl"
    report = tmp_path / "report.json"

    assert (
        main(
            [
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--audio-root-map",
                f"OLD_ROOT={tmp_path}",
                "--output",
                str(predictions),
            ]
        )
        == 0
    )
    assert (
        cli_main(
            [
                "--repo-root",
                str(Path(__file__).resolve().parents[3]),
                "score",
                "--manifest",
                str(manifest),
                "--predictions",
                str(predictions),
                "--output",
                str(report),
            ]
        )
        == 0
    )
    result = json.loads(report.read_text(encoding="utf-8"))
    assert result["run"]["analyzer"]["bpm_interpretations"] == {"track": "period"}
    assert result["counts"]["completed"] == 1
    assert result["groups"]["ground_truth"]["tempo"]["acc1"] == 1.0


def test_scan_phase_anchor_synthesizes_grid_from_vdj_2026_schema(tmp_path: Path):
    audio = tmp_path / "track.wav"
    _write_wav(audio, seconds=4)
    manifest = tmp_path / "manifest.jsonl"
    _write_manifest(manifest, [_manifest_row("track", audio)])
    database = tmp_path / "database.xml"
    database.write_text(
        '<VirtualDJ_Database Version="2026">'
        f'<Song FilePath="{audio}" FileSize="1">'
        '<Infos SongLength="4.0" />'
        '<Scan Version="801" Bpm="0.5" Phase="0.099" AltBpm="0.6" Key="E" />'
        "</Song></VirtualDJ_Database>",
        encoding="utf-8",
    )
    output = tmp_path / "predictions.jsonl"

    assert (
        main(
            [
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--output",
                str(output),
            ]
        )
        == 0
    )

    _, predictions = load_predictions(output)
    row = predictions["track"]
    assert row["bpm"] == 120.0
    assert row["provenance"]["beat_anchor"] == "scan_phase"
    assert row["beats_ms"][:3] == [99, 599, 1099]
    assert "downbeats_ms" not in row


def test_first_beat_takes_precedence_over_scan_phase(tmp_path: Path):
    audio = tmp_path / "track.wav"
    _write_wav(audio, seconds=4)
    manifest = tmp_path / "manifest.jsonl"
    _write_manifest(manifest, [_manifest_row("track", audio)])
    database = tmp_path / "database.xml"
    database.write_text(
        f'<VirtualDJ><Song FilePath="{audio}" Duration="4">'
        '<Scan Version="801" Bpm="0.5" Phase="0.099" FirstBeat="0.25" Key="E" />'
        "</Song></VirtualDJ>",
        encoding="utf-8",
    )
    output = tmp_path / "predictions.jsonl"

    assert (
        main(
            [
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--output",
                str(output),
            ]
        )
        == 0
    )

    _, predictions = load_predictions(output)
    row = predictions["track"]
    assert row["provenance"]["beat_anchor"] == "FirstBeat"
    assert row["beats_ms"][:2] == [250, 750]


def test_scan_phase_beyond_one_period_is_normalized(tmp_path: Path):
    audio = tmp_path / "track.wav"
    _write_wav(audio, seconds=4)
    manifest = tmp_path / "manifest.jsonl"
    _write_manifest(manifest, [_manifest_row("track", audio)])
    database = tmp_path / "database.xml"
    database.write_text(
        f'<VirtualDJ><Song FilePath="{audio}" Duration="4">'
        '<Scan Version="801" Bpm="0.5" Phase="0.7" Key="E" />'
        "</Song></VirtualDJ>",
        encoding="utf-8",
    )
    output = tmp_path / "predictions.jsonl"

    assert (
        main(
            [
                "--database",
                str(database),
                "--manifest",
                str(manifest),
                "--output",
                str(output),
            ]
        )
        == 0
    )

    _, predictions = load_predictions(output)
    row = predictions["track"]
    assert row["provenance"]["beat_anchor"] == "scan_phase"
    assert row["beats_ms"][:3] == [200, 700, 1200]
