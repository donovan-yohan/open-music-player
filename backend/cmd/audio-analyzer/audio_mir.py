#!/usr/bin/env python3
"""Extract beat/downbeat and tonal metadata for the Go analyzer service."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Iterable

import numpy as np


MAJOR_PROFILE = np.asarray(
    [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88],
    dtype=np.float64,
)
MINOR_PROFILE = np.asarray(
    [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17],
    dtype=np.float64,
)

# Beat This resamples to 22050 Hz and uses a centered 1024-sample STFT. Its
# reflection padding is 512 samples on each side, so inputs must exceed it.
BEAT_THIS_SAMPLE_RATE = 22050
BEAT_THIS_N_FFT = 1024
MIN_BEAT_THIS_SAMPLES = BEAT_THIS_N_FFT // 2 + 1


def _clamp(value: float, minimum: float, maximum: float) -> float:
    return max(minimum, min(maximum, value))


def estimate_tempo(beats_seconds: Iterable[float]) -> tuple[float, float]:
    beats = np.unique(np.asarray(list(beats_seconds), dtype=np.float64))
    if beats.size < 4 or not np.all(np.isfinite(beats)):
        raise ValueError("beat tracker returned fewer than four valid beats")

    intervals = np.diff(beats)
    intervals = intervals[(intervals >= 0.18) & (intervals <= 2.05)]
    if intervals.size < 3:
        raise ValueError("beat tracker returned too few usable intervals")

    median = float(np.median(intervals))
    deviation = np.abs(intervals - median)
    mad = float(np.median(deviation))
    tolerance = max(0.03, mad * 3.5)
    stable = intervals[deviation <= tolerance]
    if stable.size < 3:
        stable = intervals

    if stable.size >= 20:
        trim = max(1, int(stable.size * 0.05))
        stable = np.sort(stable)[trim:-trim]
    mean_interval = float(np.mean(stable))
    bpm = 60.0 / mean_interval
    if not math.isfinite(bpm) or bpm < 30 or bpm > 300:
        raise ValueError(f"derived BPM is outside the supported range: {bpm}")

    coefficient_of_variation = float(np.std(stable) / mean_interval)
    regularity = _clamp(1.0 - coefficient_of_variation * 8.0, 0.0, 1.0)
    coverage = math.sqrt(_clamp(stable.size / 48.0, 0.0, 1.0))
    inlier_ratio = _clamp(stable.size / intervals.size, 0.0, 1.0)
    confidence = 0.1 + 0.85 * regularity * coverage * inlier_ratio
    return round(bpm, 2), round(_clamp(confidence, 0.1, 0.95), 3)


def _correlation(chroma: np.ndarray, profile: np.ndarray) -> float:
    chroma_centered = chroma - float(np.mean(chroma))
    profile_centered = profile - float(np.mean(profile))
    denominator = float(
        np.linalg.norm(chroma_centered) * np.linalg.norm(profile_centered)
    )
    if denominator <= 0:
        return -1.0
    return float(np.dot(chroma_centered, profile_centered) / denominator)


def estimate_key(chroma_frames: np.ndarray) -> tuple[int | None, str | None, float]:
    chroma = np.asarray(chroma_frames, dtype=np.float64)
    if chroma.ndim != 2 or chroma.shape[0] != 12 or chroma.shape[1] == 0:
        raise ValueError("constant-Q chroma must contain 12 non-empty pitch classes")
    aggregate = np.mean(np.maximum(chroma, 0), axis=1)
    if not np.any(aggregate > 0):
        return None, None, 0.0
    tonal_variation = float(np.std(aggregate) / max(float(np.mean(aggregate)), 1e-9))
    if tonal_variation < 0.03:
        return None, None, 0.0

    candidates: list[tuple[float, int, str]] = []
    for key_index in range(12):
        candidates.append(
            (
                _correlation(aggregate, np.roll(MAJOR_PROFILE, key_index)),
                key_index,
                "major",
            )
        )
        candidates.append(
            (
                _correlation(aggregate, np.roll(MINOR_PROFILE, key_index)),
                key_index,
                "minor",
            )
        )
    candidates.sort(reverse=True)
    best_score, key_index, mode = candidates[0]
    second_score = candidates[1][0]
    winner_gap = max(0.0, best_score - second_score)
    if best_score <= 0 or winner_gap < 0.005:
        return None, None, 0.0
    confidence = max(0.0, best_score) * 0.72 + min(0.23, winner_gap * 2.3)
    return key_index, mode, round(_clamp(confidence, 0.0, 0.95), 3)


def marker_ms(values: Iterable[float]) -> list[int]:
    markers = {
        int(round(float(value) * 1000))
        for value in values
        if math.isfinite(float(value)) and float(value) >= 0
    }
    return sorted(markers)


def regularize_downbeats(
    beats_seconds: Iterable[float], downbeats_seconds: Iterable[float]
) -> tuple[np.ndarray, float]:
    beats = np.unique(np.asarray(list(beats_seconds), dtype=np.float64))
    candidates = np.unique(np.asarray(list(downbeats_seconds), dtype=np.float64))
    if beats.size < 4 or candidates.size == 0:
        return np.asarray([], dtype=np.float64), 0.0

    median_interval = float(np.median(np.diff(beats)))
    tolerance = max(0.08, median_interval * 0.35)
    matched_indices: list[int] = []
    for candidate in candidates:
        insertion = int(np.searchsorted(beats, candidate))
        nearby = [index for index in (insertion - 1, insertion) if 0 <= index < beats.size]
        if not nearby:
            continue
        nearest = min(nearby, key=lambda index: abs(float(beats[index] - candidate)))
        if abs(float(beats[nearest] - candidate)) <= tolerance:
            matched_indices.append(nearest)
    if not matched_indices:
        return np.asarray([], dtype=np.float64), 0.0

    unique_indices = np.unique(np.asarray(matched_indices, dtype=np.int64))
    phase_counts = np.bincount(unique_indices % 4, minlength=4)
    phase = int(np.argmax(phase_counts))
    agreement = float(phase_counts[phase] / unique_indices.size)
    expected = max(1, int(math.ceil(beats.size / 4)))
    coverage = _clamp(unique_indices.size / expected, 0.0, 1.0)
    confidence = _clamp(0.95 * agreement * math.sqrt(coverage), 0.0, 0.95)
    if unique_indices.size < 4 or agreement < 0.6:
        return beats[unique_indices], round(confidence, 3)
    return beats[phase::4], round(confidence, 3)


def empty_mir_result() -> dict[str, object]:
    """Return the established helper schema without optional DJ metadata."""
    return {
        "bpm": None,
        "tempo_confidence": 0.0,
        "beats_ms": [],
        "downbeats_ms": [],
        "downbeat_confidence": 0.0,
        "key_index": None,
        "mode": None,
        "key_confidence": 0.0,
    }


def load_beat_this_signal(audio_path: Path) -> np.ndarray:
    """Decode and resample exactly as Beat This 1.1.0 does before its STFT."""
    from beat_this.inference import load_audio

    signal, sample_rate = load_audio(str(audio_path))
    signal = np.asanyarray(signal)
    if signal.ndim == 0:
        signal = signal.reshape(1)
    elif signal.ndim == 2:
        signal = signal.mean(1)
    elif signal.ndim != 1:
        raise ValueError(f"Expected 1D or 2D signal, got shape {signal.shape}")
    if sample_rate != BEAT_THIS_SAMPLE_RATE:
        import soxr

        signal = soxr.resample(
            signal,
            in_rate=sample_rate,
            out_rate=BEAT_THIS_SAMPLE_RATE,
        )
    return np.asanyarray(signal)


def analyze(audio_path: Path, model_path: Path) -> dict[str, object]:
    if not audio_path.is_file():
        raise ValueError(f"audio file does not exist: {audio_path}")
    if not model_path.is_file():
        raise ValueError(f"beat model does not exist: {model_path}")

    signal = load_beat_this_signal(audio_path)
    if signal.size < MIN_BEAT_THIS_SAMPLES:
        return empty_mir_result()

    from beat_this.inference import Audio2Beats

    tracker = Audio2Beats(checkpoint_path=str(model_path), device="cpu", dbn=False)
    beats, downbeats = tracker(signal, BEAT_THIS_SAMPLE_RATE)
    try:
        bpm, tempo_confidence = estimate_tempo(beats)
    except ValueError:
        bpm, tempo_confidence = None, 0.0
    regular_downbeats, downbeat_confidence = regularize_downbeats(beats, downbeats)

    import librosa

    audio, sample_rate = librosa.load(
        audio_path, sr=BEAT_THIS_SAMPLE_RATE, mono=True
    )
    if audio.size < sample_rate:
        key_index, mode, key_confidence = None, None, 0.0
    else:
        harmonic = librosa.effects.harmonic(audio)
        chroma = librosa.feature.chroma_cqt(
            y=harmonic,
            sr=sample_rate,
            hop_length=4096,
            bins_per_octave=36,
        )
        key_index, mode, key_confidence = estimate_key(chroma)

    return {
        "bpm": bpm,
        "tempo_confidence": tempo_confidence,
        "beats_ms": marker_ms(beats),
        "downbeats_ms": marker_ms(regular_downbeats),
        "downbeat_confidence": downbeat_confidence,
        "key_index": key_index,
        "mode": mode,
        "key_confidence": key_confidence,
    }


def check_runtime(model_path: Path) -> dict[str, str]:
    if not model_path.is_file():
        raise ValueError(f"beat model does not exist: {model_path}")

    import librosa
    from beat_this.inference import File2Beats

    File2Beats(checkpoint_path=str(model_path), device="cpu", dbn=False)
    return {
        "status": "ready",
        "tempo_model": "beat-this-final0-v1.1.0",
        "key_model": f"librosa-{librosa.__version__}-cqt-krumhansl-v1",
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", nargs="?", type=Path)
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        result = check_runtime(args.model)
    else:
        if args.audio is None:
            parser.error("audio is required unless --check is used")
        result = analyze(args.audio, args.model)
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
