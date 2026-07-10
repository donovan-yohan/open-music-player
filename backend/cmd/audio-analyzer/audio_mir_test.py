import unittest

import numpy as np

import audio_mir


class AudioMIRTest(unittest.TestCase):
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
