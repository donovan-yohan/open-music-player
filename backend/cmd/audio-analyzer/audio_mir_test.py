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

            tracker = mock.Mock(return_value=(np.asarray([]), np.asarray([])))
            with mock.patch.object(
                inference,
                "Audio2Beats",
                return_value=tracker,
            ) as tracker_factory:
                result_512 = audio_mir.analyze(audio_512, model_path)
                tracker_factory.assert_not_called()

                result_513 = audio_mir.analyze(audio_513, model_path)

        self.assertEqual(result_512, audio_mir.empty_mir_result())
        self.assertEqual(result_513, audio_mir.empty_mir_result())
        tracker_factory.assert_called_once_with(
            checkpoint_path=str(model_path), device="cpu", dbn=False
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

    def test_regularize_downbeats_uses_dominant_four_beat_phase(self):
        beats = [index * 0.5 for index in range(16)]
        candidates = [0.5, 2.5, 4.5, 6.5, 1.5]

        downbeats, confidence = audio_mir.regularize_downbeats(beats, candidates)

        np.testing.assert_allclose(downbeats, [0.5, 2.5, 4.5, 6.5])
        self.assertGreater(confidence, 0.7)

    def test_regularize_downbeats_does_not_expand_one_candidate(self):
        beats = [index * 0.5 for index in range(32)]

        downbeats, confidence = audio_mir.regularize_downbeats(beats, [0.5])

        np.testing.assert_allclose(downbeats, [0.5])
        self.assertLess(confidence, 0.55)

    def test_regularize_downbeats_keeps_noisy_candidates_low_confidence(self):
        beats = [index * 0.5 for index in range(16)]
        candidates = [0.0, 0.5, 1.0, 1.5]

        downbeats, confidence = audio_mir.regularize_downbeats(beats, candidates)

        np.testing.assert_allclose(downbeats, candidates)
        self.assertLess(confidence, 0.55)


if __name__ == "__main__":
    unittest.main()
