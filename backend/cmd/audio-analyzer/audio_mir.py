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
ANALYZER_NAME = "omp-mir-analyzer"
ANALYZER_VERSION = "2026-07-11-3"
BEAT_GRID_ALGORITHM = "dynamic-meter-posterior-v3"
TEMPO_MODEL_VERSION = "beat-this-final0-v1.1.0-audio2frames-postprocessor-dynamic-meter-posterior-v3"
MIN_GRID_BEATS = 4
MIN_GRID_INTERVAL_SECONDS = 0.18
MAX_GRID_CELL_STEP = 8
AUTO_LOCK_CONFIDENCE_THRESHOLD = 0.55
INELIGIBLE_CONFIDENCE_CAP = 0.549
MIN_AUTO_LOCK_DOWNBEATS = 8
BEAT_POSTERIOR_FPS = 50
STRONG_ACCEPTED_BEAT_POSTERIOR = 0.65
STRONG_MIDPOINT_POSTERIOR = 0.70
LOW_MIDPOINT_POSTERIOR = 0.30
MIN_CLIENT_INTERVAL_MEDIAN_RATIO = 0.45
MAX_CLIENT_INTERVAL_MEDIAN_RATIO = 1.8
MIN_OCTAVE_SUPPORT_SECONDS = 20.0


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


def _posterior_summary(values: Iterable[float]) -> tuple[float, float, int]:
    posterior = np.asarray(list(values), dtype=np.float64)
    posterior = posterior[np.isfinite(posterior)]
    if posterior.size == 0:
        return 0.0, 0.0, 0
    posterior = np.clip(posterior, 0.0, 1.0)
    return float(np.mean(posterior)), float(np.std(posterior)), int(posterior.size)


def resolve_tempo_octave(
    bpm: float,
    tempo_confidence: float,
    beats_seconds: Iterable[float],
    accepted_beat_posterior: Iterable[float],
    midpoint_beat_posterior: Iterable[float],
) -> tuple[float, float, float]:
    """Score the emitted tempo without inventing a half/double-time decision.

    With Beat This minimal postprocessing, a coherent positive midpoint peak is
    itself emitted as a beat. A below-threshold midpoint is not enough evidence
    to reinterpret every accepted interval. Downbeat accents likewise cannot
    distinguish legitimate 2/4 at 180 BPM from a half-time interpretation, so
    ambiguous octave evidence keeps the emitted tempo and remains ineligible.
    """
    beats = np.asarray(list(beats_seconds), dtype=np.float64)
    beats = beats[np.isfinite(beats) & (beats >= 0)]
    accepted_mean, accepted_std, accepted_count = _posterior_summary(
        accepted_beat_posterior
    )
    midpoint_mean, _, midpoint_count = _posterior_summary(
        midpoint_beat_posterior
    )
    if beats.size < MIN_GRID_BEATS or accepted_count < MIN_GRID_BEATS:
        return bpm, 0.0, 1.0

    support = math.sqrt(_clamp((beats.size - 1) / 48.0, 0.0, 1.0))
    accepted_strength = _clamp(
        (accepted_mean - 0.5) / (STRONG_ACCEPTED_BEAT_POSTERIOR - 0.5),
        0.0,
        1.0,
    )
    accepted_coherence = _clamp(1.0 - accepted_std / 0.24, 0.0, 1.0)
    midpoint_rejection = _clamp((0.5 - midpoint_mean) / 0.20, 0.0, 1.0)
    confidence = (
        _clamp(tempo_confidence, 0.0, 1.0)
        * support
        * accepted_strength
        * accepted_coherence
        * midpoint_rejection
    )
    decisive_base = (
        accepted_mean >= STRONG_ACCEPTED_BEAT_POSTERIOR
        and midpoint_count >= max(4, beats.size // 4)
        and midpoint_mean <= LOW_MIDPOINT_POSTERIOR
        and float(beats[-1] - beats[0]) >= MIN_OCTAVE_SUPPORT_SECONDS
    )
    if not decisive_base:
        confidence = min(confidence, INELIGIBLE_CONFIDENCE_CAP)
    return bpm, round(_clamp(confidence, 0.0, 0.95), 3), 1.0


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


def has_client_eligible_beat_intervals(values: Iterable[float]) -> bool:
    markers = np.asarray(marker_ms(values), dtype=np.int64)
    if markers.size < 2:
        return False
    intervals = np.diff(markers)
    median = int(np.sort(intervals)[intervals.size // 2])
    if median <= 0:
        return False
    return bool(
        np.all(intervals >= median * MIN_CLIENT_INTERVAL_MEDIAN_RATIO)
        and np.all(intervals <= median * MAX_CLIENT_INTERVAL_MEDIAN_RATIO)
    )


def _posterior_at_seconds(
    posterior: np.ndarray | None, seconds: Iterable[float], fps: int
) -> np.ndarray:
    values = np.asarray(list(seconds), dtype=np.float64)
    if posterior is None or posterior.size == 0 or values.size == 0:
        return np.zeros(values.size, dtype=np.float64)
    indices = np.rint(values * fps).astype(np.int64)
    indices = np.clip(indices, 0, posterior.size - 1)
    return posterior[indices]


def _logits_to_posterior(logits: object) -> np.ndarray:
    """Detach Beat This logits once and retain their sigmoid posterior."""
    values = logits.detach().float().cpu().numpy()
    values = np.asarray(values, dtype=np.float64).reshape(-1)
    return 1.0 / (1.0 + np.exp(-np.clip(values, -60.0, 60.0)))


def _interpolate_supported_one_cell_gaps(
    grid: np.ndarray,
    cells: np.ndarray,
    period: float,
    beat_posterior: np.ndarray | None,
    posterior_fps: int,
) -> tuple[np.ndarray, np.ndarray, float]:
    if grid.size < 2:
        return grid, cells, 1.0

    def period_compatible(interval: float) -> bool:
        return (
            interval >= MIN_GRID_INTERVAL_SECONDS
            and period * 0.65 <= interval <= period * 1.35
        )

    output_grid: list[float] = []
    output_cells: list[int] = []
    interpolation_support: list[float] = []
    for index in range(grid.size - 1):
        output_grid.append(float(grid[index]))
        output_cells.append(int(cells[index]))
        if int(cells[index + 1] - cells[index]) != 2:
            continue

        gap = float(grid[index + 1] - grid[index])
        midpoint_interval = gap / 2
        midpoint = float((grid[index] + grid[index + 1]) / 2)
        midpoint_posterior = float(
            _posterior_at_seconds(beat_posterior, [midpoint], posterior_fps)[0]
        )
        if not period_compatible(midpoint_interval):
            continue
        if midpoint_posterior < STRONG_MIDPOINT_POSTERIOR:
            continue
        output_grid.append(midpoint)
        output_cells.append(int(cells[index] + 1))
        interpolation_support.append(midpoint_posterior)

    output_grid.append(float(grid[-1]))
    output_cells.append(int(cells[-1]))
    interpolation_confidence = 1.0
    if interpolation_support:
        interpolation_confidence = 0.88 + 0.12 * float(np.mean(interpolation_support))
    return (
        np.asarray(output_grid, dtype=np.float64),
        np.asarray(output_cells, dtype=np.int64),
        interpolation_confidence,
    )


def regularize_beat_grid(
    candidates_seconds: Iterable[float],
    bpm: float | None,
    tempo_confidence: float,
    *,
    beat_posterior: np.ndarray | None = None,
    posterior_fps: int = BEAT_POSTERIOR_FPS,
    allow_interpolation: bool = True,
) -> tuple[np.ndarray, np.ndarray, float]:
    """Select a monotonic local beat path instead of exporting raw markers.

    Beat This candidates are useful diagnostics but can contain nearby duplicate
    activations. Dynamic programming selects candidate-to-candidate transitions
    near the accepted period, preserving local timing variation and explicit
    missing-cell steps without inventing unsupported beat positions.
    """
    candidates = np.asarray(list(candidates_seconds), dtype=np.float64)
    candidates = np.unique(candidates[np.isfinite(candidates) & (candidates >= 0)])
    if (
        candidates.size < MIN_GRID_BEATS
        or bpm is None
        or not math.isfinite(bpm)
        or bpm < 30
        or bpm > 300
    ):
        return (
            np.asarray([], dtype=np.float64),
            np.asarray([], dtype=np.int64),
            0.0,
        )

    period = 60.0 / bpm
    candidate_count = candidates.size
    scores = np.full(candidate_count, -np.inf, dtype=np.float64)
    predecessors = np.full(candidate_count, -1, dtype=np.int64)
    cell_steps = np.ones(candidate_count, dtype=np.int64)
    residual_scale = max(0.04, period * 0.25)
    maximum_delta = period * (MAX_GRID_CELL_STEP + 0.5)

    for current in range(candidate_count):
        start_cells = float(candidates[current] / period)
        scores[current] = 1.0 - min(8.0, start_cells) * 0.25
        for previous in range(current - 1, -1, -1):
            delta = float(candidates[current] - candidates[previous])
            if delta > maximum_delta:
                break
            if delta < MIN_GRID_INTERVAL_SECONDS:
                continue
            step = int(round(delta / period))
            if step < 1 or step > MAX_GRID_CELL_STEP:
                continue
            residual = abs(delta - step * period)
            residual_penalty = (residual / residual_scale) ** 2
            missing_penalty = (step - 1) * 0.45
            transition_score = 1.0 - residual_penalty - missing_penalty
            path_score = float(scores[previous] + transition_score)
            if path_score > scores[current]:
                scores[current] = path_score
                predecessors[current] = previous
                cell_steps[current] = step

    path_indices: list[int] = []
    current = int(np.argmax(scores))
    while current >= 0:
        path_indices.append(current)
        current = int(predecessors[current])
    path_indices.reverse()
    if len(path_indices) < MIN_GRID_BEATS:
        return (
            np.asarray([], dtype=np.float64),
            np.asarray([], dtype=np.int64),
            0.0,
        )

    grid = candidates[np.asarray(path_indices, dtype=np.int64)].copy()
    cells = np.zeros(len(path_indices), dtype=np.int64)
    for index in range(1, len(path_indices)):
        cells[index] = cells[index - 1] + cell_steps[path_indices[index]]

    deltas = np.diff(grid)
    steps = np.diff(cells)
    residuals = np.abs(deltas - steps * period)
    residual_median = float(np.median(residuals))
    residual_upper_quartile = float(np.percentile(residuals, 75))
    robust_residual = residual_median * 0.75 + residual_upper_quartile * 0.25
    confidence_residual_scale = max(0.04, period * 0.18)
    residual_consistency = math.exp(
        -0.5 * (robust_residual / confidence_residual_scale) ** 2
    )
    interpolation_confidence = 1.0
    if allow_interpolation:
        grid, cells, interpolation_confidence = _interpolate_supported_one_cell_gaps(
            grid, cells, period, beat_posterior, posterior_fps
        )
    coverage = float(cells.size / max(1, int(cells[-1] - cells[0] + 1)))
    confidence = (
        _clamp(tempo_confidence, 0.0, 1.0)
        * residual_consistency
        * math.sqrt(coverage)
        * interpolation_confidence
    )
    if not has_client_eligible_beat_intervals(grid):
        confidence = min(confidence, INELIGIBLE_CONFIDENCE_CAP)
    return grid, cells, round(_clamp(confidence, 0.0, 0.95), 3)


def regularize_downbeats(
    beats_seconds: Iterable[float],
    beat_cells: Iterable[int],
    downbeats_seconds: Iterable[float],
) -> tuple[np.ndarray, float]:
    beats = np.asarray(list(beats_seconds), dtype=np.float64)
    cells = np.asarray(list(beat_cells), dtype=np.int64)
    candidates = np.unique(np.asarray(list(downbeats_seconds), dtype=np.float64))
    if (
        beats.size < 4
        or beats.size != cells.size
        or candidates.size == 0
        or not np.all(np.isfinite(beats))
        or np.any(np.diff(beats) <= 0)
        or np.any(np.diff(cells) <= 0)
    ):
        return np.asarray([], dtype=np.float64), 0.0

    median_interval = float(np.median(np.diff(beats) / np.diff(cells)))
    tolerance = max(0.08, median_interval * 0.35)
    matched_candidates: dict[int, float] = {}
    for candidate in candidates:
        insertion = int(np.searchsorted(beats, candidate))
        nearby = [index for index in (insertion - 1, insertion) if 0 <= index < beats.size]
        if not nearby:
            continue
        nearest = min(nearby, key=lambda index: abs(float(beats[index] - candidate)))
        if abs(float(beats[nearest] - candidate)) <= tolerance:
            previous = matched_candidates.get(nearest)
            if previous is None or abs(float(beats[nearest] - candidate)) < abs(
                float(beats[nearest] - previous)
            ):
                matched_candidates[nearest] = float(candidate)
    if not matched_candidates:
        return np.asarray([], dtype=np.float64), 0.0

    unique_indices = np.asarray(sorted(matched_candidates), dtype=np.int64)
    regular_downbeats = np.asarray(
        [matched_candidates[int(index)] for index in unique_indices],
        dtype=np.float64,
    )
    matched_cells = cells[unique_indices]
    meter_consistency = 0.0
    if matched_cells.size >= 2:
        meter_steps = np.diff(matched_cells)
        unique_steps, counts = np.unique(meter_steps, return_counts=True)
        dominant = int(unique_steps[int(np.argmax(counts))])
        if dominant > 0:
            meter_consistency = float(np.count_nonzero(meter_steps == dominant) / meter_steps.size)
    support = math.sqrt(_clamp(unique_indices.size / 12.0, 0.0, 1.0))
    confidence = _clamp(0.95 * support * meter_consistency, 0.0, 0.95)
    has_missing_cells = bool(np.any(np.diff(cells) != 1))
    if (
        has_missing_cells
        or unique_indices.size < MIN_AUTO_LOCK_DOWNBEATS
        or meter_consistency < 0.8
        or not set(marker_ms(regular_downbeats)).issubset(set(marker_ms(beats)))
    ):
        confidence = min(confidence, INELIGIBLE_CONFIDENCE_CAP)
    return regular_downbeats, round(confidence, 3)


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

    from beat_this.inference import Audio2Frames
    from beat_this.model.postprocessor import Postprocessor

    tracker = Audio2Frames(checkpoint_path=str(model_path), device="cpu")
    beat_logits, downbeat_logits = tracker(signal, BEAT_THIS_SAMPLE_RATE)
    postprocessor = Postprocessor(type="minimal", fps=BEAT_POSTERIOR_FPS)
    beats, downbeats = postprocessor(beat_logits, downbeat_logits)
    beat_posterior = _logits_to_posterior(beat_logits)
    accepted_posterior = _posterior_at_seconds(
        beat_posterior, beats, BEAT_POSTERIOR_FPS
    )
    midpoint_posterior = _posterior_at_seconds(
        beat_posterior,
        (np.asarray(beats[:-1]) + np.asarray(beats[1:])) / 2,
        BEAT_POSTERIOR_FPS,
    )
    try:
        bpm, tempo_confidence = estimate_tempo(beats)
        bpm, tempo_confidence, _ = resolve_tempo_octave(
            bpm,
            tempo_confidence,
            beats,
            accepted_posterior,
            midpoint_posterior,
        )
    except ValueError:
        bpm, tempo_confidence = None, 0.0
    cleaned_beats, beat_cells, grid_confidence = regularize_beat_grid(
        beats,
        bpm,
        tempo_confidence,
        beat_posterior=beat_posterior,
    )
    if cleaned_beats.size < MIN_GRID_BEATS:
        # The service contract treats BPM and the beat grid as one timing fact.
        # Do not retain a tempo value that cannot safely anchor a beat grid.
        bpm, grid_confidence = None, 0.0
    regular_downbeats, downbeat_confidence = regularize_downbeats(
        cleaned_beats, beat_cells, downbeats
    )

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
        "tempo_confidence": grid_confidence,
        "beats_ms": marker_ms(cleaned_beats),
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
    from beat_this.inference import Audio2Frames
    from beat_this.model.postprocessor import Postprocessor

    Audio2Frames(checkpoint_path=str(model_path), device="cpu")
    Postprocessor(type="minimal", fps=BEAT_POSTERIOR_FPS)
    return {
        "analyzer": ANALYZER_NAME,
        "analyzer_version": ANALYZER_VERSION,
        "status": "ready",
        "tempo_model": TEMPO_MODEL_VERSION,
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
