import importlib.util
import os
import sys
import tempfile
import types
import unittest
import wave
from pathlib import Path
from unittest import mock

import numpy as np

import audio_mir


BEAT_THIS_RUNTIME_AVAILABLE = importlib.util.find_spec("beat_this") is not None
BEAT_THIS_MODEL_PATH = Path(
    os.environ.get("ANALYZER_BEAT_MODEL", "/app/models/beat_this-final0.ckpt")
)

# Exact first 120 stored Beat This markers from live Postgres track 43,
# "in my cup (luv being toxic)", captured before beat-grid regularization.
TRACK_43_PRODUCTION_DERIVED_BEATS_MS = np.asarray(
    [
        0, 380, 800, 1220, 1640, 2020, 2440, 2840, 3300, 3680,
        4120, 4520, 4960, 5340, 5780, 6220, 6620, 7040, 7440, 7860,
        8280, 8700, 9120, 9560, 9980, 10380, 10800, 11220, 11640, 12040,
        12460, 12880, 13300, 13700, 14120, 14540, 14960, 15380, 15800, 16200,
        16620, 17020, 17440, 17840, 18260, 18680, 19100, 19500, 19920, 20340,
        20760, 21160, 21580, 21900, 22000, 22400, 22720, 22820, 23240, 23660,
        24060, 24380, 24460, 24880, 25300, 25720, 26120, 26520, 26920, 27340,
        27720, 28160, 28540, 28960, 29360, 29760, 30160, 30560, 31000, 31400,
        31820, 32220, 32640, 33060, 33480, 33880, 34000, 34300, 34720, 34820,
        35140, 35260, 35560, 35660, 35980, 36080, 36480, 36800, 36900, 37200,
        37320, 37620, 37720, 38040, 38140, 38460, 38560, 38960, 39280, 39380,
        39800, 40220, 40620, 41040, 41460, 41880, 42280, 42700, 43120, 43540,
    ],
    dtype=np.float64,
)
TRACK_43_PRODUCTION_DERIVED_GAP_BEATS_MS = np.asarray(
    [
        54240, 54620, 55080, 55440, 55860, 56240, 56760, 57080, 57180,
        57480, 57600, 57900, 58020, 58420, 58880, 59560, 59960, 60380,
        60800, 61220, 61620, 62040, 62440, 62520, 62900, 63320, 63760,
        64100, 64200, 64600, 65020, 65340, 65460, 65740, 65860, 66180,
        66280, 66660, 67080, 67500, 68260, 68660, 69080, 69580, 69940,
        70420, 70720, 71160, 71560, 71660, 71960,
    ],
    dtype=np.float64,
)
TRACK_43_PRODUCTION_DERIVED_GAP_DOWNBEATS_MS = np.asarray(
    [
        54620, 56240, 57900, 58020, 59560, 61220, 62900,
        64600, 66180, 66280, 68260, 69580, 71160,
    ],
    dtype=np.float64,
)


def write_pcm16_wav(path, sample_count, sample_rate=audio_mir.BEAT_THIS_SAMPLE_RATE):
    samples = np.zeros(sample_count, dtype="<i2")
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(samples.tobytes())


class AudioMIRTest(unittest.TestCase):
    def test_analyze_skips_beat_this_for_short_decoded_audio(self):
        decoded_audio = np.zeros(176, dtype=np.float32)
        inference = types.ModuleType("beat_this.inference")
        inference.load_audio = mock.Mock(
            return_value=(decoded_audio, audio_mir.BEAT_THIS_SAMPLE_RATE)
        )
        inference.Audio2Beats = mock.Mock(
            side_effect=AssertionError("Beat This must not run for short audio")
        )
        beat_this = types.ModuleType("beat_this")
        beat_this.inference = inference

        with tempfile.TemporaryDirectory() as temp_dir:
            audio_path = Path(temp_dir) / "short.wav"
            model_path = Path(temp_dir) / "beat-this.ckpt"
            audio_path.touch()
            model_path.touch()
            with mock.patch.dict(
                sys.modules,
                {
                    "beat_this": beat_this,
                    "beat_this.inference": inference,
                },
            ):
                result = audio_mir.analyze(audio_path, model_path)

        self.assertEqual(result, audio_mir.empty_mir_result())
        inference.load_audio.assert_called_once_with(str(audio_path))
        inference.Audio2Beats.assert_not_called()

    def test_analyze_does_not_treat_decoder_errors_as_short_audio(self):
        inference = types.ModuleType("beat_this.inference")
        inference.load_audio = mock.Mock(side_effect=RuntimeError("decoder failed"))
        inference.Audio2Beats = mock.Mock()
        beat_this = types.ModuleType("beat_this")
        beat_this.inference = inference

        with tempfile.TemporaryDirectory() as temp_dir:
            audio_path = Path(temp_dir) / "unreadable.audio"
            model_path = Path(temp_dir) / "beat-this.ckpt"
            audio_path.touch()
            model_path.touch()
            with mock.patch.dict(
                sys.modules,
                {"beat_this": beat_this, "beat_this.inference": inference},
            ):
                with self.assertRaisesRegex(RuntimeError, "decoder failed"):
                    audio_mir.analyze(audio_path, model_path)

        inference.Audio2Beats.assert_not_called()

    def test_load_beat_this_signal_rejects_more_than_two_dimensions(self):
        inference = types.ModuleType("beat_this.inference")
        inference.load_audio = mock.Mock(
            return_value=(
                np.zeros((1, 1, 1), dtype=np.float32),
                audio_mir.BEAT_THIS_SAMPLE_RATE,
            )
        )
        beat_this = types.ModuleType("beat_this")
        beat_this.inference = inference

        with mock.patch.dict(
            sys.modules,
            {"beat_this": beat_this, "beat_this.inference": inference},
        ):
            with self.assertRaisesRegex(ValueError, "Expected 1D or 2D signal"):
                audio_mir.load_beat_this_signal(Path("invalid-shape.wav"))

    @unittest.skipUnless(
        BEAT_THIS_RUNTIME_AVAILABLE,
        "requires the pinned Beat This runtime",
    )
    def test_real_decoder_normalizes_one_frame_and_skips_beat_this(self):
        from beat_this import inference

        with tempfile.TemporaryDirectory() as temp_dir:
            audio_path = Path(temp_dir) / "one-frame.wav"
            model_path = Path(temp_dir) / "beat-this.ckpt"
            write_pcm16_wav(audio_path, 1)
            model_path.touch()

            signal = audio_mir.load_beat_this_signal(audio_path)
            self.assertEqual(signal.ndim, 1)
            self.assertEqual(signal.size, 1)

            with mock.patch.object(
                inference,
                "Audio2Beats",
                side_effect=AssertionError(
                    "Beat This must not run for one-frame audio"
                ),
            ) as tracker_factory:
                result = audio_mir.analyze(audio_path, model_path)

        self.assertEqual(result, audio_mir.empty_mir_result())
        tracker_factory.assert_not_called()

    @unittest.skipUnless(
        BEAT_THIS_RUNTIME_AVAILABLE,
        "requires the pinned Beat This runtime",
    )
    def test_beat_this_runtime_stft_boundary_is_512_513(self):
        import torch
        from beat_this.preprocessing import LogMelSpect

        with tempfile.TemporaryDirectory() as temp_dir:
            signals = {}
            for sample_count in (512, 513):
                audio_path = Path(temp_dir) / f"{sample_count}.wav"
                write_pcm16_wav(audio_path, sample_count)
                signals[sample_count] = audio_mir.load_beat_this_signal(audio_path)
                self.assertEqual(signals[sample_count].size, sample_count)

        preprocessor = LogMelSpect()
        self.assertEqual(preprocessor.spect_class.n_fft, audio_mir.BEAT_THIS_N_FFT)
        with self.assertRaisesRegex(RuntimeError, "Padding size should be less"):
            preprocessor(torch.as_tensor(signals[512], dtype=torch.float32))
        spectrogram = preprocessor(
            torch.as_tensor(signals[513], dtype=torch.float32)
        )
        self.assertEqual(tuple(spectrogram.shape), (2, 128))

    @unittest.skipUnless(
        BEAT_THIS_RUNTIME_AVAILABLE,
        "requires the pinned Beat This runtime",
    )
    def test_analyze_real_decoder_bypasses_512_and_allows_513(self):
        from beat_this import inference

        with tempfile.TemporaryDirectory() as temp_dir:
            model_path = Path(temp_dir) / "beat-this.ckpt"
            model_path.touch()
            audio_512 = Path(temp_dir) / "512.wav"
            audio_513 = Path(temp_dir) / "513.wav"
            write_pcm16_wav(audio_512, 512)
            write_pcm16_wav(audio_513, 513)

            class FakeLogits:
                def detach(self):
                    return self

                def float(self):
                    return self

                def cpu(self):
                    return self

                def numpy(self):
                    return np.asarray([], dtype=np.float64)

            tracker = mock.Mock(return_value=(FakeLogits(), FakeLogits()))
            postprocessor = mock.Mock(return_value=(np.asarray([]), np.asarray([])))
            with (
                mock.patch.object(
                    inference,
                    "Audio2Frames",
                    return_value=tracker,
                ) as tracker_factory,
                mock.patch(
                    "beat_this.model.postprocessor.Postprocessor",
                    return_value=postprocessor,
                ),
            ):
                result_512 = audio_mir.analyze(audio_512, model_path)
                tracker_factory.assert_not_called()

                result_513 = audio_mir.analyze(audio_513, model_path)

        self.assertEqual(result_512, audio_mir.empty_mir_result())
        self.assertEqual(result_513, audio_mir.empty_mir_result())
        tracker_factory.assert_called_once_with(
            checkpoint_path=str(model_path), device="cpu"
        )
        signal, sample_rate = tracker.call_args.args
        self.assertEqual(signal.size, 513)
        self.assertEqual(sample_rate, audio_mir.BEAT_THIS_SAMPLE_RATE)

    @unittest.skipUnless(
        BEAT_THIS_RUNTIME_AVAILABLE and BEAT_THIS_MODEL_PATH.is_file(),
        "requires the pinned Beat This runtime and model",
    )
    def test_actual_beat_this_model_accepts_513_samples(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            audio_path = Path(temp_dir) / "513.wav"
            write_pcm16_wav(audio_path, 513)

            result = audio_mir.analyze(audio_path, BEAT_THIS_MODEL_PATH)

        self.assertEqual(result, audio_mir.empty_mir_result())

    def test_estimate_tempo_rejects_outliers_and_preserves_fractional_bpm(self):
        beats = [index * 0.5 for index in range(64)]
        beats[31] += 0.12

        bpm, confidence = audio_mir.estimate_tempo(beats)

        self.assertAlmostEqual(bpm, 120, delta=0.2)
        self.assertGreaterEqual(confidence, 0.8)

    def test_estimate_tempo_keeps_sparse_grid_below_automation_threshold(self):
        bpm, confidence = audio_mir.estimate_tempo([0.0, 0.5, 1.0, 1.5])

        self.assertEqual(bpm, 120)
        self.assertLess(confidence, 0.55)

    def test_strong_base_evidence_clears_threshold_without_promotion(self):
        period = 60 / 90
        candidates = np.arange(64, dtype=np.float64) * period
        estimated_bpm, estimated_confidence = audio_mir.estimate_tempo(candidates)
        bpm, confidence, octave_factor = audio_mir.resolve_tempo_octave(
            estimated_bpm,
            estimated_confidence,
            candidates,
            np.full(candidates.size, 0.90),
            np.full(candidates.size - 1, 0.08),
        )

        self.assertEqual(estimated_bpm, 90)
        self.assertEqual(bpm, 90)
        self.assertEqual(octave_factor, 1)
        self.assertGreater(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)
        self.assertNotEqual(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_strong_posterior_preserves_181_90_and_180(self):
        for expected_bpm in (181, 90, 180):
            with self.subTest(bpm=expected_bpm):
                candidates = np.arange(96, dtype=np.float64) * (60 / expected_bpm)
                estimated_bpm, estimated_confidence = audio_mir.estimate_tempo(
                    candidates
                )
                bpm, confidence, octave_factor = audio_mir.resolve_tempo_octave(
                    estimated_bpm,
                    estimated_confidence,
                    candidates,
                    np.full(candidates.size, 0.90),
                    np.full(candidates.size - 1, 0.08),
                )

                self.assertAlmostEqual(bpm, expected_bpm, delta=0.02)
                self.assertEqual(octave_factor, 1)
                self.assertGreater(
                    confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD
                )

    def test_weak_base_evidence_is_not_clamped_up_to_threshold(self):
        candidates = np.arange(64, dtype=np.float64) * (60 / 90)
        bpm, confidence, octave_factor = audio_mir.resolve_tempo_octave(
            90,
            0.95,
            candidates,
            np.full(candidates.size, 0.60),
            np.full(candidates.size - 1, 0.08),
        )

        self.assertEqual(bpm, 90)
        self.assertEqual(octave_factor, 1)
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)
        self.assertNotEqual(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_weak_double_time_evidence_remains_ambiguous(self):
        candidates = np.arange(64, dtype=np.float64) * (60 / 90)
        bpm, confidence, octave_factor = audio_mir.resolve_tempo_octave(
            90,
            0.95,
            candidates,
            np.full(candidates.size, 0.90),
            np.full(candidates.size - 1, 0.48),
        )

        self.assertEqual(bpm, 90)
        self.assertEqual(octave_factor, 1)
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_weak_half_time_evidence_preserves_180_and_stays_ineligible(self):
        candidates = np.arange(128, dtype=np.float64) * (60 / 180)
        bpm, confidence, octave_factor = audio_mir.resolve_tempo_octave(
            180,
            0.95,
            candidates,
            np.full(candidates.size, 0.60),
            np.full(candidates.size - 1, 0.10),
        )

        self.assertEqual(bpm, 180)
        self.assertEqual(octave_factor, 1)
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_alternating_downbeats_do_not_half_legitimate_2_4_at_180(self):
        candidates = np.arange(96, dtype=np.float64) * (60 / 180)
        estimated_bpm, estimated_confidence = audio_mir.estimate_tempo(candidates)
        bpm, confidence, octave_factor = audio_mir.resolve_tempo_octave(
            estimated_bpm,
            estimated_confidence,
            candidates,
            np.full(candidates.size, 0.90),
            np.full(candidates.size - 1, 0.10),
        )
        downbeat_candidates = candidates[::2]
        downbeats, downbeat_confidence = audio_mir.regularize_downbeats(
            candidates,
            np.arange(candidates.size),
            downbeat_candidates,
        )

        self.assertEqual(bpm, 180)
        self.assertEqual(octave_factor, 1)
        self.assertGreater(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)
        np.testing.assert_allclose(downbeats, downbeat_candidates)
        self.assertGreater(
            downbeat_confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD
        )

    def test_systematic_missing_downbeats_do_not_flip_181_or_genuine_90(self):
        for expected_bpm in (181, 90):
            with self.subTest(bpm=expected_bpm):
                candidates = np.arange(96, dtype=np.float64) * (60 / expected_bpm)
                estimated_bpm, estimated_confidence = audio_mir.estimate_tempo(
                    candidates
                )
                bpm, confidence, octave_factor = audio_mir.resolve_tempo_octave(
                    estimated_bpm,
                    estimated_confidence,
                    candidates,
                    np.full(candidates.size, 0.90),
                    np.full(candidates.size - 1, 0.08),
                )
                emitted_downbeats = candidates[::8]
                downbeats, _ = audio_mir.regularize_downbeats(
                    candidates,
                    np.arange(candidates.size),
                    emitted_downbeats,
                )

                self.assertAlmostEqual(bpm, expected_bpm, delta=0.02)
                self.assertEqual(octave_factor, 1)
                self.assertGreater(
                    confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD
                )
                np.testing.assert_allclose(downbeats, emitted_downbeats)

    def test_sparse_or_mixed_meter_posterior_stays_ineligible(self):
        candidates = np.arange(12, dtype=np.float64) * 0.5
        bpm, confidence, octave_factor = audio_mir.resolve_tempo_octave(
            120,
            0.90,
            candidates,
            np.full(candidates.size, 0.55),
            np.full(candidates.size - 1, 0.52),
        )

        self.assertEqual(bpm, 120)
        self.assertEqual(octave_factor, 1)
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    @unittest.skipUnless(
        BEAT_THIS_RUNTIME_AVAILABLE,
        "requires the pinned Beat This runtime",
    )
    def test_real_postprocessor_emits_strong_midpoints_instead_of_hiding_double_time(self):
        import torch
        from beat_this.model.postprocessor import Postprocessor

        logits = torch.full((2200,), -8.0)
        accepted_frames = np.arange(32, dtype=np.int64) * 66
        midpoint_frames = accepted_frames[:-1] + 33
        logits[accepted_frames] = 4.0
        logits[midpoint_frames] = 3.0
        beats, _ = Postprocessor(type="minimal", fps=50)(logits, torch.full_like(logits, -8.0))

        self.assertEqual(len(beats), len(accepted_frames) + len(midpoint_frames))
        np.testing.assert_allclose(beats[1::2] * 50, midpoint_frames)

    @unittest.skipUnless(
        BEAT_THIS_RUNTIME_AVAILABLE,
        "requires the pinned Beat This runtime",
    )
    def test_real_postprocessor_below_threshold_midpoints_do_not_claim_90_to_180(self):
        import torch
        from beat_this.model.postprocessor import Postprocessor

        logits = torch.full((2200,), -8.0)
        accepted_frames = np.arange(64, dtype=np.int64) * 33
        midpoint_frames = accepted_frames[:-1] + 16
        logits[accepted_frames] = 4.0
        logits[midpoint_frames] = -0.08
        logits[midpoint_frames + 1] = -0.08
        beats, _ = Postprocessor(type="minimal", fps=50)(logits, torch.full_like(logits, -8.0))
        posterior = audio_mir._logits_to_posterior(logits)
        bpm, tempo_confidence = audio_mir.estimate_tempo(beats)
        resolved_bpm, confidence, octave_factor = audio_mir.resolve_tempo_octave(
            bpm,
            tempo_confidence,
            beats,
            audio_mir._posterior_at_seconds(posterior, beats, 50),
            audio_mir._posterior_at_seconds(
                posterior,
                (np.asarray(beats[:-1]) + np.asarray(beats[1:])) / 2,
                50,
            ),
        )

        self.assertEqual(len(beats), len(accepted_frames))
        self.assertAlmostEqual(resolved_bpm, bpm)
        self.assertEqual(octave_factor, 1)
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_sparse_four_downbeats_cannot_auto_lock(self):
        beats = np.arange(32, dtype=np.float64) * 0.5
        downbeats, confidence = audio_mir.regularize_downbeats(
            beats, np.arange(beats.size), beats[::8]
        )

        np.testing.assert_allclose(downbeats, beats[::8])
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_regularize_beat_grid_removes_nearby_duplicates_at_145_bpm(self):
        period = 60 / 145
        expected = np.arange(24, dtype=np.float64) * period
        duplicates = expected[2:22:3] + np.asarray(
            [0.102, 0.138, 0.114, 0.132, 0.107, 0.141, 0.119],
            dtype=np.float64,
        )
        candidates = np.sort(np.concatenate((expected, duplicates)))

        grid, cells, confidence = audio_mir.regularize_beat_grid(
            candidates, 145, 0.91
        )

        self.assertEqual(grid.size, expected.size)
        np.testing.assert_array_equal(cells, np.arange(expected.size))
        np.testing.assert_allclose(np.diff(grid), period, atol=0.001)
        self.assertTrue(np.all(np.diff(grid) >= 0.18))
        self.assertGreaterEqual(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_regularize_beat_grid_preserves_clean_steady_grid(self):
        period = 0.5
        candidates = np.arange(64, dtype=np.float64) * period

        grid, cells, confidence = audio_mir.regularize_beat_grid(
            candidates, 120, 0.95
        )

        np.testing.assert_allclose(grid, candidates, atol=0.001)
        np.testing.assert_array_equal(cells, np.arange(candidates.size))
        self.assertGreaterEqual(confidence, 0.9)

    def test_760_over_420_contract_caps_confidence_when_client_rejects_grid(self):
        candidates = np.asarray([0.0, 0.42, 0.84, 1.26, 2.02, 2.44, 2.86])

        grid, _, confidence = audio_mir.regularize_beat_grid(
            candidates, 60 / 0.42, 0.584
        )
        serialized = audio_mir.marker_ms(grid)
        intervals = np.diff(serialized)
        median = int(np.sort(intervals)[intervals.size // 2])

        self.assertEqual(max(intervals), 760)
        self.assertEqual(median, 420)
        self.assertGreater(max(intervals) / median, 1.8)
        self.assertFalse(audio_mir.has_client_eligible_beat_intervals(grid))
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_760_gap_interpolates_only_with_midpoint_posterior_and_becomes_eligible(self):
        candidates = np.asarray([0.0, 0.42, 0.84, 1.26, 2.02, 2.44, 2.86])
        posterior = np.zeros(200, dtype=np.float64)
        posterior[round(1.64 * audio_mir.BEAT_POSTERIOR_FPS)] = 0.91

        grid, cells, confidence = audio_mir.regularize_beat_grid(
            candidates,
            60 / 0.42,
            0.9,
            beat_posterior=posterior,
        )

        self.assertIn(1640, audio_mir.marker_ms(grid))
        np.testing.assert_array_equal(cells, np.arange(cells.size))
        self.assertTrue(audio_mir.has_client_eligible_beat_intervals(grid))
        self.assertGreater(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_regularize_beat_grid_marks_variable_tempo_candidates_ineligible(self):
        period = 60 / 145
        phase_errors = np.asarray(
            [0.0, 0.08, 0.16, 0.24, 0.32, 0.04, 0.12, 0.20, 0.28]
        )
        candidates = np.arange(phase_errors.size) * period + phase_errors

        grid, cells, confidence = audio_mir.regularize_beat_grid(
            candidates, 145, 0.91
        )

        np.testing.assert_allclose(grid, candidates[:5])
        np.testing.assert_array_equal(cells, [0, 1, 2, 3, 4])
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_regularize_beat_grid_requires_four_supported_beats(self):
        grid, cells, confidence = audio_mir.regularize_beat_grid(
            [0.0, 0.5, 1.0], 120, 0.95
        )

        self.assertEqual(grid.size, 0)
        self.assertEqual(cells.size, 0)
        self.assertEqual(confidence, 0)

    def test_regularize_beat_grid_keeps_onset_cell_after_phase_wrap(self):
        candidates = [0.0, 0.49, 0.99, 1.49]

        grid, cells, confidence = audio_mir.regularize_beat_grid(
            candidates, 120, 0.9
        )

        np.testing.assert_allclose(grid, candidates, atol=0.001)
        np.testing.assert_array_equal(cells, [0, 1, 2, 3])
        self.assertEqual(audio_mir.marker_ms(grid), [0, 490, 990, 1490])
        self.assertGreaterEqual(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_regularize_beat_grid_preserves_39ms_onset_at_30_bpm(self):
        candidates = 0.039 + np.arange(16, dtype=np.float64) * 2.0

        grid, cells, _ = audio_mir.regularize_beat_grid(candidates, 30, 0.9)

        self.assertEqual(audio_mir.marker_ms(grid[:1]), [39])
        np.testing.assert_array_equal(cells, np.arange(candidates.size))

    def test_production_derived_track_43_segment_preserves_local_beat_path(self):
        candidates = TRACK_43_PRODUCTION_DERIVED_BEATS_MS / 1000

        grid, cells, confidence = audio_mir.regularize_beat_grid(
            candidates, 145.14, 0.589
        )

        self.assertEqual(candidates.size, 120)
        self.assertEqual(grid.size, 106)
        self.assertEqual(
            audio_mir.marker_ms(grid[:8]),
            [0, 380, 800, 1220, 1640, 2020, 2440, 2840],
        )
        self.assertEqual(audio_mir.marker_ms(grid[-1:]), [43540])
        self.assertTrue(np.all(np.diff(grid) >= 0.18))
        np.testing.assert_array_equal(cells, np.arange(106))
        self.assertGreaterEqual(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_production_derived_track_43_gaps_preserve_observed_marker_times(self):
        candidates = TRACK_43_PRODUCTION_DERIVED_GAP_BEATS_MS / 1000
        downbeat_candidates = (
            TRACK_43_PRODUCTION_DERIVED_GAP_DOWNBEATS_MS / 1000
        )

        grid, cells, grid_confidence = audio_mir.regularize_beat_grid(
            candidates,
            145.14,
            0.589,
        )
        downbeats, downbeat_confidence = audio_mir.regularize_downbeats(
            grid, cells, downbeat_candidates
        )
        serialized = np.asarray(audio_mir.marker_ms(grid), dtype=np.int64)
        intervals = np.diff(serialized)

        self.assertTrue(
            set(serialized).issubset(set(np.rint(candidates * 1000).astype(np.int64)))
        )
        self.assertTrue(np.all(intervals >= 180))
        median = int(np.sort(intervals)[intervals.size // 2])
        self.assertGreater(float(np.max(intervals)) / median, 1.8)
        self.assertFalse(audio_mir.has_client_eligible_beat_intervals(grid))
        self.assertLess(
            grid_confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD
        )
        self.assertTrue(set(audio_mir.marker_ms(downbeats)).issubset(set(serialized)))
        self.assertLess(downbeat_confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_analyze_emits_cleaned_grid_not_synthetic_duplicate_burst(self):
        period = 60 / 145
        expected = np.arange(16, dtype=np.float64) * period
        candidates = np.sort(
            np.concatenate(
                (
                    expected,
                    expected[1:15:2]
                    + np.asarray(
                        [0.102, 0.138, 0.114, 0.132, 0.107, 0.141, 0.119]
                    ),
                )
            )
        )
        class FakeLogits:
            def detach(self):
                return self

            def float(self):
                return self

            def cpu(self):
                return self

            def numpy(self):
                return np.zeros(1024, dtype=np.float64)

        inference = types.ModuleType("beat_this.inference")
        inference.Audio2Frames = mock.Mock(
            return_value=mock.Mock(return_value=(FakeLogits(), FakeLogits()))
        )
        postprocessor = types.ModuleType("beat_this.model.postprocessor")
        postprocessor.Postprocessor = mock.Mock(
            return_value=mock.Mock(return_value=(candidates, expected[::4]))
        )
        model = types.ModuleType("beat_this.model")
        model.postprocessor = postprocessor
        beat_this = types.ModuleType("beat_this")
        beat_this.inference = inference
        beat_this.model = model
        librosa = types.ModuleType("librosa")
        librosa.load = mock.Mock(return_value=(np.zeros(1, dtype=np.float32), 22050))

        with tempfile.TemporaryDirectory() as temp_dir:
            audio_path = Path(temp_dir) / "synthetic-duplicate-burst.wav"
            model_path = Path(temp_dir) / "beat-this.ckpt"
            audio_path.touch()
            model_path.touch()
            with (
                mock.patch.dict(
                    sys.modules,
                    {
                        "beat_this": beat_this,
                        "beat_this.inference": inference,
                        "beat_this.model": model,
                        "beat_this.model.postprocessor": postprocessor,
                        "librosa": librosa,
                    },
                ),
                mock.patch.object(
                    audio_mir,
                    "load_beat_this_signal",
                    return_value=np.zeros(audio_mir.MIN_BEAT_THIS_SAMPLES),
                ),
                mock.patch.object(audio_mir, "estimate_tempo", return_value=(145, 0.91)),
            ):
                result = audio_mir.analyze(audio_path, model_path)

        self.assertEqual(set(result), set(audio_mir.empty_mir_result()))
        beats = np.asarray(result["beats_ms"], dtype=np.float64) / 1000
        self.assertEqual(beats.size, expected.size)
        np.testing.assert_allclose(np.diff(beats), period, atol=0.002)
        self.assertTrue(np.all(np.diff(beats) >= 0.18))
        self.assertLess(
            result["tempo_confidence"], audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD
        )
        np.testing.assert_allclose(result["downbeats_ms"], expected[::4] * 1000, atol=1)

    def test_downbeats_follow_cleaned_grid_instead_of_raw_ordinals(self):
        period = 60 / 145
        expected = np.arange(16, dtype=np.float64) * period
        candidates = np.sort(
            np.concatenate((expected, expected[1:15:2] + 0.118))
        )
        grid, cells, _ = audio_mir.regularize_beat_grid(candidates, 145, 0.91)

        downbeats, confidence = audio_mir.regularize_downbeats(
            grid,
            cells,
            [expected[0], expected[4], expected[8], expected[12]],
        )

        np.testing.assert_allclose(downbeats, expected[::4], atol=0.001)
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_bracketed_missing_cell_is_interpolated_without_phase_shift(self):
        expected_cells = np.asarray([0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        candidates = expected_cells.astype(np.float64) * 0.5
        downbeat_candidates = np.asarray([0.0, 2.0, 4.0, 6.0])

        posterior = np.zeros(400, dtype=np.float64)
        posterior[int(1.5 * audio_mir.BEAT_POSTERIOR_FPS)] = 0.9
        grid, cells, _ = audio_mir.regularize_beat_grid(
            candidates, 120, 0.9, beat_posterior=posterior
        )
        downbeats, confidence = audio_mir.regularize_downbeats(
            grid, cells, downbeat_candidates
        )

        np.testing.assert_allclose(grid, np.arange(13) * 0.5)
        np.testing.assert_array_equal(cells, np.arange(13))
        np.testing.assert_allclose(downbeats, downbeat_candidates)
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_unbracketed_missing_cell_is_not_interpolated_or_trusted(self):
        expected_cells = np.asarray([0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        candidates = expected_cells.astype(np.float64) * 0.5
        downbeat_candidates = np.asarray([0.0, 2.0, 4.0, 6.0])

        grid, cells, _ = audio_mir.regularize_beat_grid(candidates, 120, 0.9)
        downbeats, confidence = audio_mir.regularize_downbeats(
            grid, cells, downbeat_candidates
        )

        np.testing.assert_array_equal(cells, expected_cells)
        self.assertNotIn(0.5, grid)
        np.testing.assert_allclose(downbeats, downbeat_candidates)
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_estimate_key_matches_shifted_krumhansl_profile(self):
        chroma = np.repeat(np.roll(audio_mir.MINOR_PROFILE, 9)[:, None], 16, axis=1)

        key_index, mode, confidence = audio_mir.estimate_key(chroma)

        self.assertEqual(key_index, 9)
        self.assertEqual(mode, "minor")
        self.assertGreater(confidence, 0.7)

    def test_estimate_key_rejects_uniform_chroma(self):
        key_index, mode, confidence = audio_mir.estimate_key(np.ones((12, 16)))

        self.assertIsNone(key_index)
        self.assertIsNone(mode)
        self.assertEqual(confidence, 0)

    def test_marker_ms_sorts_deduplicates_and_drops_negative_values(self):
        self.assertEqual(audio_mir.marker_ms([0.5, -1, 0.0, 0.5001]), [0, 500])

    def test_regularize_downbeats_keeps_sparse_candidates_ineligible(self):
        beats = [index * 0.5 for index in range(16)]
        cells = list(range(16))
        candidates = [0.5, 2.5, 4.5, 6.5, 1.5]

        downbeats, confidence = audio_mir.regularize_downbeats(
            beats, cells, candidates
        )

        np.testing.assert_allclose(downbeats, sorted(candidates))
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_regularize_downbeats_does_not_expand_one_candidate(self):
        beats = [index * 0.5 for index in range(32)]
        cells = list(range(32))

        downbeats, confidence = audio_mir.regularize_downbeats(
            beats, cells, [0.5]
        )

        np.testing.assert_allclose(downbeats, [0.5])
        self.assertLess(confidence, 0.55)

    def test_regularize_downbeats_keeps_noisy_candidates_low_confidence(self):
        beats = [index * 0.5 for index in range(16)]
        cells = list(range(16))
        candidates = [0.0, 0.5, 1.0, 1.5]

        downbeats, confidence = audio_mir.regularize_downbeats(
            beats, cells, candidates
        )

        np.testing.assert_allclose(downbeats, candidates)
        self.assertLess(confidence, 0.55)

    def test_regularize_downbeats_preserves_supported_candidate_timing(self):
        beats = np.arange(64, dtype=np.float64) * 0.5
        emitted = beats[::4] + 0.03

        downbeats, confidence = audio_mir.regularize_downbeats(
            beats,
            np.arange(beats.size),
            emitted,
        )

        np.testing.assert_allclose(downbeats, emitted)
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)

    def test_regularize_downbeats_preserves_4_4_to_3_4_tail_without_expansion(self):
        beats = np.arange(48, dtype=np.float64) * 0.5
        downbeat_cells = np.asarray([0, 4, 8, 12, 16, 20, 24, 28, 32, 35, 38, 41])
        emitted = beats[downbeat_cells]

        downbeats, confidence = audio_mir.regularize_downbeats(
            beats,
            np.arange(beats.size),
            emitted,
        )

        np.testing.assert_allclose(downbeats, emitted)
        self.assertLess(confidence, audio_mir.AUTO_LOCK_CONFIDENCE_THRESHOLD)


if __name__ == "__main__":
    unittest.main()
