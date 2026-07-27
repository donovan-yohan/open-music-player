"""Export VirtualDJ ``database.xml`` analysis into audio-MIR prediction JSONL.

VirtualDJ keeps its analysis local to its desktop database.  This module is
deliberately an importer rather than an ingest integration: it hashes the
audio files named by the XML and joins them to an existing evaluation manifest.
"""

from __future__ import annotations

import argparse
import math
import shutil
import subprocess
import sys
import wave
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from .io import EvalInputError, load_manifest, repo_head, sha256_file, write_jsonl

_PITCH_TO_INDEX = {
    "C": 0,
    "B#": 0,
    "C#": 1,
    "DB": 1,
    "D": 2,
    "D#": 3,
    "EB": 3,
    "E": 4,
    "FB": 4,
    "F": 5,
    "E#": 5,
    "F#": 6,
    "GB": 6,
    "G": 7,
    "G#": 8,
    "AB": 8,
    "A": 9,
    "A#": 10,
    "BB": 10,
    "B": 11,
    "CB": 11,
}
_CAMELOT = {
    (1, "A"): (8, "minor"),
    (2, "A"): (3, "minor"),
    (3, "A"): (10, "minor"),
    (4, "A"): (5, "minor"),
    (5, "A"): (0, "minor"),
    (6, "A"): (7, "minor"),
    (7, "A"): (2, "minor"),
    (8, "A"): (9, "minor"),
    (9, "A"): (4, "minor"),
    (10, "A"): (11, "minor"),
    (11, "A"): (6, "minor"),
    (12, "A"): (1, "minor"),
    (1, "B"): (11, "major"),
    (2, "B"): (6, "major"),
    (3, "B"): (1, "major"),
    (4, "B"): (8, "major"),
    (5, "B"): (3, "major"),
    (6, "B"): (10, "major"),
    (7, "B"): (5, "major"),
    (8, "B"): (0, "major"),
    (9, "B"): (7, "major"),
    (10, "B"): (2, "major"),
    (11, "B"): (9, "major"),
    (12, "B"): (4, "major"),
}


@dataclass(frozen=True)
class VDJSong:
    """The resilient subset of one ``Song`` element needed by the exporter."""

    path: str
    scan: dict[str, str]
    infos: dict[str, str]
    pois: tuple[dict[str, str], ...]
    song_attributes: dict[str, str]


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1].lower()


def _attribute(attributes: dict[str, str], *names: str) -> str | None:
    normalized = {key.lower(): value for key, value in attributes.items()}
    for name in names:
        value = normalized.get(name.lower())
        if value is not None:
            return value
    return None


def _number(value: str | None) -> float | None:
    if value is None:
        return None
    try:
        parsed = float(value.strip().replace(",", "."))
    except ValueError:
        return None
    return parsed if math.isfinite(parsed) else None


def parse_bpm(value: str | None, encoding: str = "auto") -> tuple[float, str] | None:
    """Return normalized BPM and the interpretation used for a Scan Bpm value."""

    raw = _number(value)
    if raw is None or raw <= 0:
        return None
    interpretation = encoding
    if encoding == "auto":
        interpretation = "period" if raw < 30 else "bpm"
    bpm = 60.0 / raw if interpretation == "period" else raw
    if not math.isfinite(bpm) or bpm <= 0:
        return None
    return round(bpm, 6), interpretation


def parse_key(value: str | None) -> tuple[int, str] | None:
    """Map VirtualDJ musical or Camelot notation to the scorer key contract."""

    if value is None:
        return None
    compact = "".join(value.strip().replace("♯", "#").replace("♭", "b").split())
    if not compact:
        return None
    if len(compact) in {2, 3} and compact[:-1].isdigit():
        number = int(compact[:-1])
        letter = compact[-1].upper()
        return _CAMELOT.get((number, letter))

    letter = compact[0].upper()
    if letter not in "ABCDEFG":
        return None
    position = 1
    accidental = ""
    if position < len(compact) and compact[position] in "#b":
        accidental = compact[position].upper()
        position += 1
    suffix = compact[position:].lower()
    if suffix in {"", "major", "maj"}:
        mode = "major"
    elif suffix in {"m", "minor", "min"}:
        mode = "minor"
    else:
        return None
    key_index = _PITCH_TO_INDEX.get(letter + accidental)
    return (key_index, mode) if key_index is not None else None


def parse_database(path: Path) -> list[VDJSong]:
    """Read supported VDJ song fields without requiring a schema version."""

    try:
        root = ET.parse(path).getroot()
    except ET.ParseError as exc:
        raise EvalInputError(f"invalid VirtualDJ XML: {path}") from exc
    songs: list[VDJSong] = []
    for element in root.iter():
        if _local_name(element.tag) != "song":
            continue
        song_attributes = dict(element.attrib)
        raw_path = _attribute(song_attributes, "FilePath")
        if not raw_path:
            continue
        scan: dict[str, str] = {}
        infos: dict[str, str] = {}
        pois: list[dict[str, str]] = []
        for child in element.iter():
            if child is element:
                continue
            if _local_name(child.tag) == "scan" and not scan:
                scan = dict(child.attrib)
            elif _local_name(child.tag) == "infos" and not infos:
                infos = dict(child.attrib)
            elif _local_name(child.tag) == "poi":
                pois.append(dict(child.attrib))
        songs.append(
            VDJSong(
                path=raw_path,
                scan=scan,
                infos=infos,
                pois=tuple(pois),
                song_attributes=song_attributes,
            )
        )
    return songs


def _parse_root_maps(values: list[str]) -> list[tuple[str, str]]:
    mappings: list[tuple[str, str]] = []
    for value in values:
        old, separator, new = value.partition("=")
        if not separator or not old or not new:
            raise EvalInputError("--audio-root-map must use OLD=NEW")
        mappings.append((old.rstrip("/\\"), new.rstrip("/\\")))
    return sorted(mappings, key=lambda mapping: len(mapping[0]), reverse=True)


def remap_audio_path(path: str, mappings: list[tuple[str, str]]) -> Path:
    """Apply the first (longest) explicitly requested VDJ path-prefix remap."""

    for old, new in mappings:
        if path == old:
            return Path(new)
        for separator in ("/", "\\"):
            prefix = old + separator
            if path.startswith(prefix):
                remainder = path[len(prefix) :].replace("\\", "/")
                return Path(new) / remainder
    return Path(path)


def _duration_from_xml(song: VDJSong) -> float | None:
    song_length = _number(_attribute(song.infos, "SongLength"))
    if song_length is not None and song_length > 0:
        return song_length
    for attributes in (song.scan, song.song_attributes):
        for name in ("DurationSeconds", "Duration", "Length", "SongLength"):
            duration = _number(_attribute(attributes, name))
            if duration is not None and duration > 0:
                return duration
        for name in ("DurationMs", "LengthMs", "SongLengthMs"):
            duration_ms = _number(_attribute(attributes, name))
            if duration_ms is not None and duration_ms > 0:
                return duration_ms / 1000.0
    return None


def _duration_from_audio(path: Path) -> float | None:
    try:
        with wave.open(str(path), "rb") as audio:
            if audio.getframerate() > 0:
                return audio.getnframes() / audio.getframerate()
    except (OSError, wave.Error):
        pass
    ffprobe = shutil.which("ffprobe")
    if ffprobe is None:
        return None
    try:
        completed = subprocess.run(
            [
                ffprobe,
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
                str(path),
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return _number(completed.stdout) if completed.returncode == 0 else None


def _beat_anchor(song: VDJSong) -> tuple[float, str] | None:
    first_beat = _number(_attribute(song.scan, "FirstBeat"))
    if first_beat is not None and first_beat >= 0:
        return first_beat, "FirstBeat"
    for poi in song.pois:
        poi_type = _attribute(poi, "Type")
        if poi_type is None or poi_type.lower() != "beatgrid":
            continue
        position = _number(_attribute(poi, "Pos", "Position"))
        if position is not None and position >= 0:
            return position, "beatgrid_poi"
    return None


def synthesize_beat_grid(
    bpm: float, anchor_seconds: float, duration_seconds: float
) -> list[int]:
    """Build a bounded constant-tempo grid in the prediction artifact's ms unit."""

    if bpm <= 0 or anchor_seconds < 0 or duration_seconds < anchor_seconds:
        return []
    period = 60.0 / bpm
    count = math.floor((duration_seconds - anchor_seconds) / period) + 1
    return [round((anchor_seconds + beat * period) * 1000) for beat in range(count)]


def _song_prediction(
    song: VDJSong,
    *,
    audio_path: Path,
    audio_sha256: str,
    bpm_encoding: str,
    assume_44_bars: bool,
) -> dict[str, Any]:
    scan_version = _attribute(song.scan, "Version") or "unknown"
    provenance: dict[str, Any] = {
        "source": "virtualdj",
        "scan_version": scan_version,
        "xml_path": song.path,
    }
    prediction: dict[str, Any] = {
        "record_type": "prediction",
        "audio_sha256": audio_sha256,
        "provenance": provenance,
    }
    parsed_bpm = parse_bpm(_attribute(song.scan, "Bpm"), bpm_encoding)
    if parsed_bpm is not None:
        bpm, interpretation = parsed_bpm
        prediction["bpm"] = bpm
        provenance["bpm_encoding"] = interpretation
        anchor = _beat_anchor(song)
        duration = _duration_from_xml(song) or _duration_from_audio(audio_path)
        if anchor is not None and duration is not None:
            beats_ms = synthesize_beat_grid(bpm, anchor[0], duration)
            if beats_ms:
                prediction["beats_ms"] = beats_ms
                provenance["beat_anchor"] = anchor[1]
                provenance["duration_source"] = (
                    "xml" if _duration_from_xml(song) is not None else "audio_probe"
                )
                if assume_44_bars:
                    prediction["downbeats_ms"] = beats_ms[::4]
                    provenance["downbeats_assumption"] = "4/4_from_beat_anchor"
    parsed_key = parse_key(_attribute(song.scan, "Key"))
    if parsed_key is not None:
        prediction["key_index"], prediction["mode"] = parsed_key
    return prediction


def export_predictions(
    *,
    database_path: Path,
    manifest_path: Path,
    output_path: Path,
    audio_root_maps: list[str],
    bpm_encoding: str,
    assume_44_bars: bool,
) -> dict[str, int]:
    """Write one complete, score-compatible prediction set and return its counts."""

    if not database_path.is_file():
        raise EvalInputError(f"database XML does not exist: {database_path}")
    manifest = load_manifest(manifest_path)
    mappings = _parse_root_maps(audio_root_maps)
    by_hash: dict[str, list[dict[str, Any]]] = {}
    for item in manifest:
        digest = item.get("audio_sha256")
        if isinstance(digest, str):
            by_hash.setdefault(digest, []).append(item)
    matched: dict[str, dict[str, Any]] = {}
    xml_only = 0
    unparseable_keys = 0
    scan_versions: set[str] = set()

    for song in parse_database(database_path):
        audio_path = remap_audio_path(song.path, mappings)
        if not audio_path.is_file():
            xml_only += 1
            continue
        try:
            digest = sha256_file(audio_path)
        except OSError:
            xml_only += 1
            continue
        items = [item for item in by_hash.get(digest, []) if item["id"] not in matched]
        if not items:
            xml_only += 1
            continue
        for item in items:
            prediction = _song_prediction(
                song,
                audio_path=audio_path,
                audio_sha256=digest,
                bpm_encoding=bpm_encoding,
                assume_44_bars=assume_44_bars,
            )
            prediction["id"] = item["id"]
            matched[item["id"]] = prediction
            scan_versions.add(str(prediction["provenance"]["scan_version"]))
            if (
                _attribute(song.scan, "Key") is not None
                and "key_index" not in prediction
            ):
                unparseable_keys += 1

    database_sha256 = sha256_file(database_path)
    bpm_interpretations = {
        item["id"]: matched[item["id"]]["provenance"]["bpm_encoding"]
        for item in manifest
        if item["id"] in matched and "bpm_encoding" in matched[item["id"]]["provenance"]
    }
    analyzer_version = next(iter(scan_versions)) if len(scan_versions) == 1 else "mixed"
    run_record: dict[str, Any] = {
        "record_type": "run",
        "schema_version": 2,
        "complete": True,
        "created_at": datetime.now(UTC).isoformat(),
        "repo_head": repo_head(Path(__file__).resolve().parents[4]),
        "manifest_sha256": sha256_file(manifest_path),
        # VirtualDJ does not expose a separable analyzer model artifact.  The
        # database digest is the immutable local analysis input for this run.
        "model_sha256": database_sha256,
        "analyzer_script_sha256": sha256_file(Path(__file__)),
        "analyzer": {
            "analyzer": "virtualdj",
            "analyzer_version": analyzer_version,
            "database_sha256": database_sha256,
            "bpm_interpretations": bpm_interpretations,
            "bpm_encoding_option": bpm_encoding,
            "downbeats_assumption": "4/4_from_beat_anchor"
            if assume_44_bars
            else "none",
        },
    }
    predictions: list[dict[str, Any]] = []
    manifest_only = 0
    for item in manifest:
        prediction = matched.get(item["id"])
        if prediction is None:
            manifest_only += 1
            prediction = {
                "record_type": "prediction",
                "id": item["id"],
                "error": {
                    "type": "MissingVirtualDJPrediction",
                    "message": "no SHA-256-matched VirtualDJ database entry",
                },
            }
        predictions.append(prediction)
    run_record["prediction_count"] = len(predictions)
    write_jsonl(output_path, [run_record, *predictions])
    return {
        "matched": len(matched),
        "xml_only": xml_only,
        "manifest_only": manifest_only,
        "unparseable_keys": unparseable_keys,
    }


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m audio_mir_eval.vdj_export",
        description="Export VirtualDJ database.xml analysis to audio-MIR predictions.",
    )
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument(
        "--audio-root-map", action="append", default=[], metavar="OLD=NEW"
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--bpm-encoding", choices=("auto", "period", "bpm"), default="auto"
    )
    parser.add_argument("--assume-44-bars", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        counts = export_predictions(
            database_path=args.database,
            manifest_path=args.manifest,
            output_path=args.output,
            audio_root_maps=args.audio_root_map,
            bpm_encoding=args.bpm_encoding,
            assume_44_bars=args.assume_44_bars,
        )
    except (EvalInputError, OSError, ValueError) as exc:
        print(f"audio-mir VDJ export: FAIL: {exc}", file=sys.stderr)
        return 1
    print(
        "audio-mir VDJ export: "
        f"matched={counts['matched']} xml_only={counts['xml_only']} "
        f"manifest_only={counts['manifest_only']} "
        f"unparseable_keys={counts['unparseable_keys']} output={args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
