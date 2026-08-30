#!/usr/bin/env python3
"""Stem separation DSP helper for the ``stemsep-worker`` service.

The Go service in ``main.go`` owns HTTP, bearer auth, MinIO transfer, and the
durable Postgres row. This module owns everything that is pure signal
processing plus the artifact manifest shape, and it is deliberately importable
without ``torch``/``audio-separator`` so the DSP contract can be unit tested in a tiny
image (see the ``stems-test`` stage in ``backend/Dockerfile``).

Contract notes that are load-bearing (see docs/adr/0006-stem-edit-events-and-playback-ladder.md
and its stems5-hybrid-v1 addendum):

* ``stems5-hybrid-v1`` kick/perc are DERIVED by a deterministic crossover, not
  by a learned model: ``kick = zero-phase LR4 low-pass(drums, 180 Hz)`` and
  ``perc = drums - kick`` computed sample-exact, so ``kick + perc == drums`` to
  numerical precision. That is what makes the pair audio-addressable without
  reopening the "no learned hi-hat stem" verdict.
* Every stem of a set is encoded by ONE libopus configuration in ONE worker
  run. Mixed encoders have different priming delays, which would show up as a
  fixed inter-stem offset under any mixer. ``opus_encode_argv`` is the single
  place that configuration exists, and the build-time smoke asserts uniformity.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Mapping, Sequence, Tuple

import numpy as np
from scipy.signal import butter, filtfilt

SCHEMA_VERSION = 1

WORKER_NAME = "stemsep-worker"
WORKER_VERSION = "2026-08-30-1"

# audio-separator is the inference provider. htdemucs_ft remains a coherent
# Demucs-family four-stem model; this changes the runtime and artifact identity,
# not the user-facing channel vocabulary.
INFERENCE_PROVIDER = "audio-separator"
AUDIO_SEPARATOR_VERSION = "0.47.0"
AUDIO_SEPARATOR_WHEEL_SHA256 = "756f3b620d78e581a117c6b6d96fe4f0eafc3432ab2824cb11532b4868bfd9a8"
MODEL_DIR = Path(os.environ.get("STEMS_MODEL_DIR", "/app/models"))
MODEL_CONFIG_FILE = "htdemucs_ft.yaml"
MODEL_CONFIG_SHA256 = "69470b8c1bbd674437b51bc9fb491327a10ab0396b702c93389b9cf750016346"
DOWNLOAD_CHECKS_FILE = "download_checks.json"
DOWNLOAD_CHECKS_SHA256 = "d3622e1fa19c161d3cf704927711b453d593a3f1eb0f2e0838c3136907935151"
MODEL_WEIGHTS: Dict[str, str] = {
    "f7e0c4bc-ba3fe64a.th": "ba3fe64ae8ef66ac9a4857222ce48efbdc5eb3ad375cb79dd13debee5aaa4066",
    "d12395a8-e57c48e6.th": "e57c48e6b0e38af4f7118d7bd08c49f0a0c0edf7d09143bdd902ea0d237303e6",
    "92cfc3b6-ef3bcb9c.th": "ef3bcb9c8b40d14ae5d51b6db2587339cc12c6b77c0be151ce6d69002e087bf2",
    "04573f0d-f3cf25b2.th": "f3cf25b222c4eed7cd49dd8b2c9597d50c18bd154090f7b919cfa5f93cf22c49",
}

# Canonical wire names. ``hihat`` is retired; ``perc`` is the only name for the
# non-kick percussion channel, and ``melody`` is the only alias of the model's
# ``other``. Declaring the alias map exactly once is what stops edit events,
# energy channels, and the client colour registry from drifting apart.
BASE_CHANNELS: Tuple[str, ...] = ("vocals", "drums", "bass", "other")
CHANNEL_SETS: Dict[str, Tuple[str, ...]] = {
    "stems4-demucs-v1": ("vocals", "drums", "bass", "other"),
    "stems5-hybrid-v1": ("vocals", "melody", "bass", "kick", "perc"),
}
CHANNEL_ALIASES: Dict[str, str] = {"melody": "other"}

BASE_MODEL_VERSION = "audio-separator-htdemucs-ft-4s-v1"
CROSSOVER_TAG = "lr4-180"
STEM_MODEL_VERSIONS: Dict[str, str] = {
    "stems4-demucs-v1": BASE_MODEL_VERSION,
    "stems5-hybrid-v1": f"{BASE_MODEL_VERSION}+{CROSSOVER_TAG}",
}

BASE_PREFIX = BASE_MODEL_VERSION
DERIVATION_SEPARATOR = "separator"
DERIVATION_CROSSOVER = "dsp-crossover-lr4-180"

CROSSOVER_HZ = 180.0
# A 2nd-order Butterworth applied zero-phase (filtfilt) has 4th-order magnitude:
# that is the Linkwitz-Riley 4 low-pass the spec asks for, with no phase shift
# to break the sample-exact ``perc = drums - kick`` identity.
CROSSOVER_ORDER = 2
NULL_SUM_THRESHOLD_DB = -80.0
SILENCE_FLOOR_DB = -200.0

ENERGY_FRAME_HZ = 80
ENERGY_ENCODING = "uint8-linear"

MODEL_SAMPLE_RATE = 44100

OPUS_CODEC = {
    "name": "libopus",
    "bitrate_kbps": 128,
    "vbr": True,
    "sample_rate_hz": 48000,
    "channels": 2,
    "application": "audio",
    "frame_duration_ms": 20,
    "compression_level": 10,
}


class StemsError(RuntimeError):
    """Raised for unrecoverable helper failures; the Go side maps it to 422/500."""


# --------------------------------------------------------------------------- #
# Channel-set vocabulary
# --------------------------------------------------------------------------- #


def channels_for(channel_set: str) -> Tuple[str, ...]:
    try:
        return CHANNEL_SETS[channel_set]
    except KeyError as exc:  # pragma: no cover - argparse guards the CLI path
        raise StemsError(f"unknown channel set: {channel_set!r}") from exc


def stem_model_version(channel_set: str) -> str:
    try:
        return STEM_MODEL_VERSIONS[channel_set]
    except KeyError as exc:  # pragma: no cover - argparse guards the CLI path
        raise StemsError(f"unknown channel set: {channel_set!r}") from exc


def base_channel_for(channel: str) -> str:
    """Resolve a wire channel name onto the coherent four-stem output."""
    return CHANNEL_ALIASES.get(channel, channel)


def object_key(track_id: int, channel_set: str, channel: str) -> str:
    """MinIO key for one channel of one set.

    Every persisted channel is namespaced by the complete immutable model
    version for its channel set. In particular, the stems5-derived drums,
    melody, kick, and perc cannot overwrite pre-migration keys that happened
    to share a channel-set name. ``drums`` is retained with the five-channel
    result so the pair can be null-verified without another separator run.
    """
    return f"stems/{track_id}/{stem_model_version(channel_set)}/{base_channel_for(channel)}.opus"


def derivation_for(channel: str) -> str:
    return DERIVATION_CROSSOVER if channel in ("kick", "perc") else DERIVATION_SEPARATOR


# --------------------------------------------------------------------------- #
# Crossover / null-sum
# --------------------------------------------------------------------------- #


def design_lowpass(
    sample_rate: int,
    cutoff_hz: float = CROSSOVER_HZ,
    order: int = CROSSOVER_ORDER,
) -> Tuple[np.ndarray, np.ndarray]:
    if sample_rate <= 0:
        raise StemsError("sample rate must be positive")
    nyquist = sample_rate / 2.0
    if not 0.0 < cutoff_hz < nyquist:
        raise StemsError(f"cutoff {cutoff_hz} Hz outside (0, {nyquist}) Hz")
    return butter(order, cutoff_hz / nyquist, btype="low")


def split_kick_perc(
    drums: np.ndarray,
    sample_rate: int,
    cutoff_hz: float = CROSSOVER_HZ,
    order: int = CROSSOVER_ORDER,
) -> Tuple[np.ndarray, np.ndarray]:
    """Split a drums stem into (kick, perc) with an exact null-sum guarantee.

    ``perc`` is computed by subtraction rather than by a complementary
    high-pass, which is what makes ``kick + perc == drums`` hold to float
    precision instead of merely approximately.
    """
    audio = np.asarray(drums, dtype=np.float64)
    if audio.ndim == 1:
        audio = audio[np.newaxis, :]
    if audio.ndim != 2:
        raise StemsError("drums stem must be 1-D or 2-D (channels, samples)")
    b, a = design_lowpass(sample_rate, cutoff_hz=cutoff_hz, order=order)
    padlen = 3 * max(len(a), len(b))
    if audio.shape[-1] <= padlen:
        raise StemsError(
            f"drums stem too short for zero-phase filtering ({audio.shape[-1]} samples)"
        )
    kick = filtfilt(b, a, audio, axis=-1)
    perc = audio - kick
    return kick.astype(np.float32), perc.astype(np.float32)


def rms(signal: np.ndarray) -> float:
    values = np.asarray(signal, dtype=np.float64).reshape(-1)
    if values.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(values))))


def null_sum_residual_db(
    kick: np.ndarray, perc: np.ndarray, drums: np.ndarray
) -> float:
    """Residual of ``(kick + perc) - drums`` relative to ``drums``, in dB."""
    reference = rms(drums)
    residual = rms(np.asarray(kick, dtype=np.float64) + np.asarray(perc, dtype=np.float64)
                   - np.asarray(drums, dtype=np.float64))
    if reference <= 0.0:
        return SILENCE_FLOOR_DB
    if residual <= 0.0:
        return SILENCE_FLOOR_DB
    return max(SILENCE_FLOOR_DB, 20.0 * math.log10(residual / reference))


# --------------------------------------------------------------------------- #
# Energy curves (80 Hz frame grid, shared with the analyzer's waveform grid)
# --------------------------------------------------------------------------- #


def energy_curve(
    signal: np.ndarray,
    sample_rate: int,
    frame_hz: int = ENERGY_FRAME_HZ,
) -> np.ndarray:
    """Per-frame RMS on the shared 80 Hz grid, as float64 (unnormalized)."""
    audio = np.asarray(signal, dtype=np.float64)
    if audio.ndim == 2:
        audio = audio.mean(axis=0)
    if audio.ndim != 1:
        raise StemsError("energy input must be 1-D or 2-D (channels, samples)")
    if frame_hz <= 0:
        raise StemsError("frame_hz must be positive")
    # Frame boundaries are computed from the exact sample position rather than a
    # rounded integer hop, so an 80 Hz grid over N seconds is exactly 80*N
    # frames with no cumulative drift against the analyzer's waveform grid.
    frames = int(round(audio.size / sample_rate * frame_hz)) if audio.size else 0
    out = np.zeros(frames, dtype=np.float64)
    for index in range(frames):
        start = int(round(index * sample_rate / frame_hz))
        end = min(audio.size, int(round((index + 1) * sample_rate / frame_hz)))
        if end > start:
            out[index] = math.sqrt(float(np.mean(np.square(audio[start:end]))))
    return out


def quantize_energy(curves: Mapping[str, np.ndarray]) -> Dict[str, object]:
    """Quantize a channel->curve map to the wire ``uint8-linear`` encoding.

    All channels share ONE normalization reference so the client can compare
    lanes against each other; per-channel autoscaling would make a silent stem
    look as loud as a busy one.
    """
    ordered = list(curves.items())
    frame_count = max((curve.size for _, curve in ordered), default=0)
    reference = max((float(curve.max()) for _, curve in ordered if curve.size), default=0.0)
    encoded: Dict[str, str] = {}
    for name, curve in ordered:
        padded = np.zeros(frame_count, dtype=np.float64)
        padded[: curve.size] = curve
        if reference > 0.0:
            scaled = np.clip(np.rint(padded / reference * 255.0), 0.0, 255.0)
        else:
            scaled = padded
        encoded[name] = base64.b64encode(scaled.astype(np.uint8).tobytes()).decode("ascii")
    return {
        "frame_hz": ENERGY_FRAME_HZ,
        "frame_count": frame_count,
        "encoding": ENERGY_ENCODING,
        "reference_rms": reference,
        "channels": encoded,
    }


# --------------------------------------------------------------------------- #
# ffmpeg transport
# --------------------------------------------------------------------------- #


def _ffmpeg_binary() -> str:
    return os.environ.get("STEMS_FFMPEG", "ffmpeg")


def decode_pcm(path: str | Path, sample_rate: int = MODEL_SAMPLE_RATE) -> np.ndarray:
    """Decode any container to float32 stereo PCM shaped (2, samples)."""
    argv = [
        _ffmpeg_binary(),
        "-hide_banner",
        "-v",
        "error",
        "-i",
        str(path),
        "-f",
        "f32le",
        "-acodec",
        "pcm_f32le",
        "-ac",
        "2",
        "-ar",
        str(sample_rate),
        "-",
    ]
    completed = subprocess.run(argv, capture_output=True, check=False)
    if completed.returncode != 0:
        raise StemsError(
            f"decode failed: {completed.stderr.decode('utf-8', 'replace').strip()}"
        )
    flat = np.frombuffer(completed.stdout, dtype="<f4")
    if flat.size == 0:
        raise StemsError("decode produced no samples")
    return np.ascontiguousarray(flat.reshape(-1, 2).T)


def opus_encode_argv(dest_path: str | Path, sample_rate: int) -> List[str]:
    """The ONE libopus configuration used for every stem in a set.

    Only ``dest_path`` and the input sample rate vary between calls; the
    build-time smoke asserts the encoder-flag suffix is byte-identical across
    all six files so their priming delays match.
    """
    codec = OPUS_CODEC
    return [
        _ffmpeg_binary(),
        "-hide_banner",
        "-v",
        "error",
        "-y",
        "-f",
        "f32le",
        "-ar",
        str(sample_rate),
        "-ac",
        "2",
        "-i",
        "-",
        "-c:a",
        codec["name"],
        "-b:a",
        f"{codec['bitrate_kbps']}k",
        "-vbr",
        "on" if codec["vbr"] else "off",
        "-compression_level",
        str(codec["compression_level"]),
        "-application",
        codec["application"],
        "-frame_duration",
        str(codec["frame_duration_ms"]),
        "-ar",
        str(codec["sample_rate_hz"]),
        "-ac",
        str(codec["channels"]),
        str(dest_path),
    ]


def encoder_flag_signature(argv: Sequence[str]) -> Tuple[str, ...]:
    """Encoder-only slice of an encode argv, for uniformity assertions."""
    marker = argv.index("-c:a")
    return tuple(argv[marker:-1])


def encode_opus(signal: np.ndarray, dest_path: str | Path, sample_rate: int) -> int:
    audio = np.asarray(signal, dtype=np.float32)
    if audio.ndim == 1:
        audio = np.stack([audio, audio])
    interleaved = np.ascontiguousarray(audio.T, dtype="<f4").tobytes()
    argv = opus_encode_argv(dest_path, sample_rate)
    completed = subprocess.run(argv, input=interleaved, capture_output=True, check=False)
    if completed.returncode != 0:
        raise StemsError(
            f"opus encode failed: {completed.stderr.decode('utf-8', 'replace').strip()}"
        )
    return int(Path(dest_path).stat().st_size)


# --------------------------------------------------------------------------- #
# Separators
# --------------------------------------------------------------------------- #

Separator = Callable[[str, int], Dict[str, np.ndarray]]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_model_bundle(model_dir: Path = MODEL_DIR) -> None:
    """Fail closed unless every mutable provider input is the pinned artifact."""
    expected = {
        MODEL_CONFIG_FILE: MODEL_CONFIG_SHA256,
        DOWNLOAD_CHECKS_FILE: DOWNLOAD_CHECKS_SHA256,
        **MODEL_WEIGHTS,
    }
    for filename, expected_hash in expected.items():
        path = model_dir / filename
        if not path.is_file():
            raise StemsError(f"pinned model artifact is missing: {path}")
        actual_hash = _sha256(path)
        if actual_hash != expected_hash:
            raise StemsError(
                f"pinned model artifact hash mismatch for {filename}: "
                f"got {actual_hash}, expected {expected_hash}"
            )


def _read_separator_outputs(
    paths: Iterable[str | Path], sample_rate: int, output_dir: str | Path | None = None
) -> Dict[str, np.ndarray]:
    """Read exactly one WAV boundary per expected audio-separator output.

    audio-separator's public API publishes files rather than source arrays. The
    WAV handoff is therefore unavoidable: it is PCM quantized at the source
    subtype and it may normalize only an over-unity stem. We configure the
    least-mutating allowed thresholds (1.0 / 0.0), then immediately own all
    subsequent DSP and the single uniform Opus boundary ourselves.
    """
    import soundfile as sf  # noqa: PLC0415 - lazy runtime dependency

    expected = {f"omp-{name}.wav": name for name in BASE_CHANNELS}
    outputs: Dict[str, np.ndarray] = {}
    for output in paths:
        path = Path(output)
        # The provider API returns basenames for some architectures and full
        # paths for others. Both forms refer only to our private temp output
        # directory; never fall back to the process working directory.
        if output_dir is not None and not path.is_absolute():
            path = Path(output_dir) / path
        channel = expected.get(path.name)
        if channel is None:
            raise StemsError(f"separator emitted unexpected output: {path.name}")
        if channel in outputs:
            raise StemsError(f"separator emitted duplicate output for {channel}")
        signal, actual_rate = sf.read(path, dtype="float32", always_2d=True)
        if actual_rate != sample_rate:
            raise StemsError(
                f"separator output {path.name} has sample rate {actual_rate}, expected {sample_rate}"
            )
        if signal.size == 0:
            raise StemsError(f"separator output {path.name} is empty")
        outputs[channel] = np.ascontiguousarray(signal.T)
    missing = [name for name in BASE_CHANNELS if name not in outputs]
    if missing:
        raise StemsError(f"separator did not emit required channels: {missing}")
    return outputs


def audio_separator_htdemucs_ft_separator(audio_path: str, sample_rate: int) -> Dict[str, np.ndarray]:
    """Run the pinned htdemucs_ft model through audio-separator's public API.

    ``Separator.load_model`` normally refreshes UVR's mutable model registry.
    The narrow subclass below permits only this baked local bundle, so an
    absent/corrupt artifact fails instead of becoming an implicit download.
    """
    import logging  # noqa: PLC0415
    from audio_separator.separator import Separator as AudioSeparator  # noqa: PLC0415

    validate_model_bundle()

    class OfflineHTDemucsFT(AudioSeparator):
        def setup_accelerated_inferencing_device(self) -> None:
            # This worker has a CPU-only artifact/runtime contract. Pinning the
            # provider's auto-detection prevents an opportunistic CUDA/MPS
            # choice from making the advertised device identity untrue.
            import torch  # noqa: PLC0415

            self.torch_device_cpu = torch.device("cpu")
            self.torch_device = self.torch_device_cpu
            self.requested_torch_device = self.torch_device_cpu
            self.onnx_execution_provider = ["CPUExecutionProvider"]

        def download_model_files(self, model_filename: str):  # type: ignore[no-untyped-def]
            if model_filename != MODEL_CONFIG_FILE:
                raise StemsError(f"unexpected audio-separator model request: {model_filename}")
            # Deliberately bypasses list_supported_model_files(), whose stock
            # implementation refreshes download_checks.json from the network.
            return (
                MODEL_CONFIG_FILE,
                "Demucs",
                "HTDemucs FT (OMP pinned)",
                str(MODEL_DIR / MODEL_CONFIG_FILE),
                str(MODEL_DIR / MODEL_CONFIG_FILE),
            )

        def download_file_if_not_exists(self, url: str, output_path: str) -> None:
            # A future provider code path must fail closed rather than acquiring
            # an unreviewed model/registry at runtime.
            if not Path(output_path).is_file():
                raise StemsError(f"runtime model download blocked for {Path(output_path).name}")

    with tempfile.TemporaryDirectory(prefix="omp-audio-separator-") as provider_output:
        separator = OfflineHTDemucsFT(
            log_level=logging.ERROR,
            model_file_dir=str(MODEL_DIR),
            output_dir=provider_output,
            output_format="WAV",
            sample_rate=sample_rate,
            use_soundfile=True,
            normalization_threshold=1.0,
            amplification_threshold=0.0,
            demucs_params={
                "segment_size": float(os.environ.get("STEMS_SEGMENT_SECONDS", "7")),
                "shifts": 0,
                "overlap": 0.25,
                "segments_enabled": True,
            },
        )
        separator.load_model(MODEL_CONFIG_FILE)
        output_paths = separator.separate(
            audio_path,
            custom_output_names={name: f"omp-{name}" for name in BASE_CHANNELS},
        )
        return _read_separator_outputs(output_paths, sample_rate, provider_output)


def _audio_separator_version() -> str:
    try:
        from importlib.metadata import version  # noqa: PLC0415

        return version("audio-separator")
    except Exception:  # pragma: no cover - torch-free test path
        return "unknown"


def _torch_version() -> str:
    try:
        import torch  # noqa: PLC0415

        return str(torch.__version__)
    except Exception:  # pragma: no cover - torch-free test path
        return "unknown"


# --------------------------------------------------------------------------- #
# Manifest
# --------------------------------------------------------------------------- #


def build_manifest(
    *,
    track_id: int,
    channel_set: str,
    sample_rate: int,
    duration_ms: int,
    objects: Iterable[Mapping[str, object]],
    null_sum_db: float | None,
    energy: Mapping[str, object],
    provenance_extra: Mapping[str, object] | None = None,
) -> Dict[str, object]:
    artifacts: Dict[str, object] = {
        "objects": list(objects),
        "codec": dict(OPUS_CODEC),
        "energy": dict(energy),
    }
    if null_sum_db is not None:
        artifacts["null_sum"] = {
            "pair": ["kick", "perc"],
            "against": "drums",
            "residual_db": round(null_sum_db, 3),
            "threshold_db": NULL_SUM_THRESHOLD_DB,
            "passed": null_sum_db <= NULL_SUM_THRESHOLD_DB,
        }
    provenance: Dict[str, object] = {
        "worker": WORKER_NAME,
        "worker_version": WORKER_VERSION,
        "inference_provider": {
            "name": INFERENCE_PROVIDER,
            "version": _audio_separator_version(),
            "wheel_sha256": AUDIO_SEPARATOR_WHEEL_SHA256,
        },
        "torch_version": _torch_version(),
        "model": {
            "family": "demucs",
            "name": "htdemucs_ft",
            "config": {"file": MODEL_CONFIG_FILE, "sha256": MODEL_CONFIG_SHA256},
            "weights": dict(MODEL_WEIGHTS),
            "download_checks": {"file": DOWNLOAD_CHECKS_FILE, "sha256": DOWNLOAD_CHECKS_SHA256},
        },
        "crossover": {
            "type": "lr4",
            "cutoff_hz": CROSSOVER_HZ,
            "order": CROSSOVER_ORDER,
            "zero_phase": True,
            "design": "butterworth-filtfilt",
        },
        "separator": {
            "model": "htdemucs_ft",
            "sample_rate_hz": sample_rate,
            "shifts": 0,
            "overlap": 0.25,
            "output_mapping": {name: f"omp-{name}.wav" for name in BASE_CHANNELS},
            "output_boundary": {
                "format": "wav",
                "normalization_threshold": 1.0,
                "amplification_threshold": 0.0,
                "note": "audio-separator public API returns normalized PCM files; OMP re-encodes every final artifact uniformly",
            },
        },
    }
    if provenance_extra:
        provenance.update(dict(provenance_extra))
    return {
        "schema_version": SCHEMA_VERSION,
        "track_id": track_id,
        "channel_set": channel_set,
        "stem_model_version": stem_model_version(channel_set),
        "duration_ms": duration_ms,
        "sample_rate_hz": sample_rate,
        "artifacts": artifacts,
        "provenance": provenance,
    }


# --------------------------------------------------------------------------- #
# Pipeline
# --------------------------------------------------------------------------- #


def run_separation(
    *,
    audio_path: str,
    out_dir: str,
    track_id: int,
    channel_set: str = "stems5-hybrid-v1",
    separator: Separator | None = None,
    sample_rate: int = MODEL_SAMPLE_RATE,
    encode: bool = True,
) -> Dict[str, object]:
    """Separate, derive kick/perc, encode, and return the artifact manifest.

    ``separator`` is injected so the whole pipeline (including the null-sum and
    manifest gates) is exercisable without torch.
    """
    channels = channels_for(channel_set)
    separate = separator or audio_separator_htdemucs_ft_separator
    stems = separate(audio_path, sample_rate)

    missing = [name for name in BASE_CHANNELS if name not in stems]
    if missing:
        raise StemsError(f"separator did not emit required channels: {missing}")

    emitted: Dict[str, np.ndarray] = {name: np.asarray(stems[name], dtype=np.float32)
                                      for name in BASE_CHANNELS}
    null_sum_db: float | None = None
    if channel_set == "stems5-hybrid-v1":
        kick, perc = split_kick_perc(emitted["drums"], sample_rate)
        null_sum_db = null_sum_residual_db(kick, perc, emitted["drums"])
        if null_sum_db > NULL_SUM_THRESHOLD_DB:
            raise StemsError(
                f"kick/perc null-sum residual {null_sum_db:.2f} dB exceeds "
                f"{NULL_SUM_THRESHOLD_DB:.2f} dB"
            )
        emitted["kick"] = kick
        emitted["perc"] = perc

    def signal_for(channel: str) -> np.ndarray:
        return emitted[channel] if channel in emitted else emitted[base_channel_for(channel)]

    # ``drums`` is always retained even when the active set is stems5, so the
    # pair can be null-verified or re-derived without another separator run.
    persist_order = list(channels)
    if "drums" not in persist_order:
        persist_order.append("drums")

    duration_ms = int(round(emitted["drums"].shape[-1] / sample_rate * 1000.0))
    out_root = Path(out_dir)
    out_root.mkdir(parents=True, exist_ok=True)

    objects: List[Dict[str, object]] = []
    signatures = set()
    for channel in persist_order:
        source = signal_for(channel)
        key = object_key(track_id, channel_set, channel)
        local = out_root / key.replace("/", "__")
        size = 0
        if encode:
            size = encode_opus(source, local, sample_rate)
            signatures.add(encoder_flag_signature(opus_encode_argv(local, sample_rate)))
        objects.append(
            {
                "channel": channel,
                "key": key,
                "path": str(local),
                "bytes": size,
                "duration_ms": duration_ms,
                "derivation": derivation_for(channel),
            }
        )
    if encode and len(signatures) > 1:
        raise StemsError("opus encoder settings were not uniform across stems")

    curves = {channel: energy_curve(signal_for(channel), sample_rate) for channel in persist_order}
    return build_manifest(
        track_id=track_id,
        channel_set=channel_set,
        sample_rate=sample_rate,
        duration_ms=duration_ms,
        objects=objects,
        null_sum_db=null_sum_db,
        energy=quantize_energy(curves),
    )


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


def _identity_payload() -> Dict[str, object]:
    return {
        "worker": WORKER_NAME,
        "worker_version": WORKER_VERSION,
        "channel_sets": sorted(CHANNEL_SETS),
        "stem_model_versions": dict(STEM_MODEL_VERSIONS),
        "inference_provider": INFERENCE_PROVIDER,
        "inference_provider_version": _audio_separator_version(),
        "inference_provider_wheel_sha256": AUDIO_SEPARATOR_WHEEL_SHA256,
        "torch_version": _torch_version(),
        "model_family": "demucs",
        "model_name": "htdemucs_ft",
        "model_config_sha256": MODEL_CONFIG_SHA256,
        "model_weight_sha256": dict(MODEL_WEIGHTS),
        "download_checks_sha256": DOWNLOAD_CHECKS_SHA256,
        "output_mapping": {name: f"omp-{name}.wav" for name in BASE_CHANNELS},
        "device": "cpu",
        "ffmpeg": bool(shutil.which(_ffmpeg_binary())),
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="stemsep-worker DSP helper")
    parser.add_argument("audio", nargs="?", help="path to the source audio file")
    parser.add_argument("--out-dir", help="directory to write encoded stems into")
    parser.add_argument("--track-id", type=int, default=0)
    parser.add_argument("--channel-set", default="stems5-hybrid-v1", choices=sorted(CHANNEL_SETS))
    parser.add_argument(
        "--check",
        action="store_true",
        help="print the worker identity and exit (readiness probe)",
    )
    args = parser.parse_args(list(argv) if argv is not None else None)

    if args.check:
        # Health must prove that the worker can use its immutable local model
        # bundle before Go starts queue consumers or exposes stem handlers.
        validate_model_bundle()
        json.dump(_identity_payload(), sys.stdout)
        sys.stdout.write("\n")
        return 0

    if not args.audio:
        parser.error("audio path is required unless --check is given")

    out_dir = args.out_dir or tempfile.mkdtemp(prefix="omp-stems-")
    try:
        manifest = run_separation(
            audio_path=args.audio,
            out_dir=out_dir,
            track_id=args.track_id,
            channel_set=args.channel_set,
        )
    except StemsError as exc:
        json.dump({"error": str(exc)}, sys.stderr)
        sys.stderr.write("\n")
        return 2
    json.dump(manifest, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
