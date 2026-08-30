#!/usr/bin/env python3
"""Torch-free contract tests for the stemsep-worker DSP helper.

Everything here runs with numpy + scipy + ffmpeg only. The separator is
dependency-injected, so the crossover math, the null-sum gate, the encoder
uniformity rule, and the manifest shape are all provable in the tiny
``stems-test`` Docker stage without pulling torch or the checkpoint.
"""

from __future__ import annotations

import base64
import io
import json
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock
from pathlib import Path
from contextlib import redirect_stdout

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import stems_dsp  # noqa: E402


HAVE_FFMPEG = shutil.which(stems_dsp._ffmpeg_binary()) is not None
SR = 44100


def synth_drums(seconds: float = 3.0, sample_rate: int = SR) -> np.ndarray:
    """Kick-ish low sine bursts plus hat-ish high noise bursts, stereo."""
    n = int(seconds * sample_rate)
    t = np.arange(n) / sample_rate
    kick = 0.8 * np.sin(2 * np.pi * 55.0 * t) * np.exp(-14.0 * (t % 0.5))
    rng = np.random.default_rng(1234)
    noise = rng.standard_normal(n)
    # Crude high-pass so the "hats" sit well above the crossover.
    hats = 0.25 * np.diff(noise, prepend=0.0) * np.exp(-40.0 * ((t + 0.25) % 0.5))
    mono = (kick + hats).astype(np.float32)
    return np.stack([mono, mono * 0.97])


def synth_tone(freq: float, seconds: float = 3.0, sample_rate: int = SR) -> np.ndarray:
    t = np.arange(int(seconds * sample_rate)) / sample_rate
    mono = (0.3 * np.sin(2 * np.pi * freq * t)).astype(np.float32)
    return np.stack([mono, mono])


def fake_separator(_audio_path: str, sample_rate: int):
    return {
        "vocals": synth_tone(440.0, sample_rate=sample_rate),
        "drums": synth_drums(sample_rate=sample_rate),
        "bass": synth_tone(80.0, sample_rate=sample_rate),
        "other": synth_tone(1200.0, sample_rate=sample_rate),
    }


class ChannelVocabularyTest(unittest.TestCase):
    def test_canonical_channel_sets(self):
        self.assertEqual(
            stems_dsp.channels_for("stems4-demucs-v1"),
            ("vocals", "drums", "bass", "other"),
        )
        self.assertEqual(
            stems_dsp.channels_for("stems5-hybrid-v1"),
            ("vocals", "melody", "bass", "kick", "perc"),
        )

    def test_hihat_name_is_retired(self):
        for names in stems_dsp.CHANNEL_SETS.values():
            self.assertNotIn("hihat", names)

    def test_melody_is_the_only_alias(self):
        self.assertEqual(stems_dsp.CHANNEL_ALIASES, {"melody": "other"})
        self.assertEqual(stems_dsp.base_channel_for("melody"), "other")
        self.assertEqual(stems_dsp.base_channel_for("kick"), "kick")

    def test_stem_model_versions(self):
        self.assertEqual(
            stems_dsp.stem_model_version("stems4-demucs-v1"),
            "audio-separator-htdemucs-ft-4s-v1",
        )
        self.assertEqual(
            stems_dsp.stem_model_version("stems5-hybrid-v1"),
            "audio-separator-htdemucs-ft-4s-v1+lr4-180",
        )

    def test_object_layout_uses_full_immutable_model_identity(self):
        self.assertEqual(
            stems_dsp.object_key(42, "stems5-hybrid-v1", "melody"),
            "stems/42/audio-separator-htdemucs-ft-4s-v1+lr4-180/other.opus",
        )
        self.assertEqual(
            stems_dsp.object_key(42, "stems5-hybrid-v1", "vocals"),
            "stems/42/audio-separator-htdemucs-ft-4s-v1+lr4-180/vocals.opus",
        )
        self.assertEqual(
            stems_dsp.object_key(42, "stems5-hybrid-v1", "kick"),
            "stems/42/audio-separator-htdemucs-ft-4s-v1+lr4-180/kick.opus",
        )
        self.assertEqual(
            stems_dsp.object_key(42, "stems5-hybrid-v1", "perc"),
            "stems/42/audio-separator-htdemucs-ft-4s-v1+lr4-180/perc.opus",
        )

    def test_new_six_artifact_keys_are_disjoint_from_legacy_layout(self):
        new_keys = {
            stems_dsp.object_key(42, "stems5-hybrid-v1", channel)
            for channel in ("vocals", "melody", "bass", "kick", "perc", "drums")
        }
        legacy_keys = {
            f"stems/42/htdemucs-4s-v1/{channel}.opus"
            for channel in ("vocals", "other", "bass", "drums")
        } | {
            f"stems/42/stems5-hybrid-v1/{channel}.opus" for channel in ("kick", "perc")
        }
        self.assertTrue(new_keys.isdisjoint(legacy_keys), (new_keys, legacy_keys))

    def test_derivation_tags(self):
        self.assertEqual(stems_dsp.derivation_for("kick"), "dsp-crossover-lr4-180")
        self.assertEqual(stems_dsp.derivation_for("perc"), "dsp-crossover-lr4-180")
        self.assertEqual(stems_dsp.derivation_for("vocals"), "separator")

    def test_unknown_channel_set_rejected(self):
        with self.assertRaises(stems_dsp.StemsError):
            stems_dsp.channels_for("stems5-learned-hihat-v1")


class AudioSeparatorAdapterContractTest(unittest.TestCase):
    def _soundfile_module(self):
        module = types.ModuleType("soundfile")

        def read(path, dtype, always_2d):
            self.assertEqual(dtype, "float32")
            self.assertTrue(always_2d)
            return np.ones((4, 2), dtype=np.float32), SR

        module.read = read
        return module

    def test_output_mapping_requires_exact_unique_four_stems(self):
        outputs = [Path(f"/tmp/omp-{name}.wav") for name in stems_dsp.BASE_CHANNELS]
        with mock.patch.dict(sys.modules, {"soundfile": self._soundfile_module()}):
            result = stems_dsp._read_separator_outputs(outputs, SR)
        self.assertEqual(set(result), set(stems_dsp.BASE_CHANNELS))
        self.assertEqual(result["vocals"].shape, (2, 4))

    def test_output_mapping_rejects_duplicate_missing_and_unexpected_stems(self):
        with mock.patch.dict(sys.modules, {"soundfile": self._soundfile_module()}):
            with self.assertRaisesRegex(stems_dsp.StemsError, "duplicate"):
                stems_dsp._read_separator_outputs(
                    ["/tmp/omp-vocals.wav", "/tmp/omp-vocals.wav"], SR
                )
            with self.assertRaisesRegex(stems_dsp.StemsError, "unexpected"):
                stems_dsp._read_separator_outputs(["/tmp/not-omp.wav"], SR)

    def test_bundle_validation_rejects_missing_or_wrong_hash_artifacts(self):
        with tempfile.TemporaryDirectory() as tmp:
            model_dir = Path(tmp)
            with self.assertRaisesRegex(stems_dsp.StemsError, "missing"):
                stems_dsp.validate_model_bundle(model_dir)
            expected = {
                stems_dsp.MODEL_CONFIG_FILE: stems_dsp.MODEL_CONFIG_SHA256,
                stems_dsp.DOWNLOAD_CHECKS_FILE: stems_dsp.DOWNLOAD_CHECKS_SHA256,
                **stems_dsp.MODEL_WEIGHTS,
            }
            for filename in expected:
                (model_dir / filename).write_bytes(b"wrong")
            with self.assertRaisesRegex(stems_dsp.StemsError, "hash mismatch"):
                stems_dsp.validate_model_bundle(model_dir)


class CrossoverTest(unittest.TestCase):
    def test_kick_plus_perc_nulls_to_drums(self):
        drums = synth_drums()
        kick, perc = stems_dsp.split_kick_perc(drums, SR)
        residual = stems_dsp.null_sum_residual_db(kick, perc, drums)
        self.assertLessEqual(residual, stems_dsp.NULL_SUM_THRESHOLD_DB)
        self.assertLessEqual(residual, -100.0, f"residual {residual} dB is not numerically exact")

    def test_shapes_and_dtypes_preserved(self):
        drums = synth_drums()
        kick, perc = stems_dsp.split_kick_perc(drums, SR)
        self.assertEqual(kick.shape, drums.shape)
        self.assertEqual(perc.shape, drums.shape)
        self.assertEqual(kick.dtype, np.float32)
        self.assertEqual(perc.dtype, np.float32)

    def test_mono_input_is_promoted(self):
        mono = synth_drums()[0]
        kick, perc = stems_dsp.split_kick_perc(mono, SR)
        self.assertEqual(kick.shape, (1, mono.size))
        self.assertLessEqual(stems_dsp.null_sum_residual_db(kick, perc, mono[np.newaxis, :]), -100.0)

    def test_low_energy_lands_in_kick_high_energy_in_perc(self):
        low = synth_tone(50.0)
        kick_low, perc_low = stems_dsp.split_kick_perc(low, SR)
        self.assertGreater(stems_dsp.rms(kick_low), 8 * stems_dsp.rms(perc_low))

        high = synth_tone(6000.0)
        kick_high, perc_high = stems_dsp.split_kick_perc(high, SR)
        self.assertGreater(stems_dsp.rms(perc_high), 8 * stems_dsp.rms(kick_high))

    def test_crossover_is_lr4_at_the_corner(self):
        # A zero-phase 2nd-order Butterworth has 4th-order magnitude, i.e. the
        # LR4 the spec asks for: -6 dB at the corner, ~-24 dB/octave beyond it.
        corner = stems_dsp.CROSSOVER_HZ
        at_corner = synth_tone(corner)
        kick, _ = stems_dsp.split_kick_perc(at_corner, SR)
        # Ignore filtfilt edge transients when measuring the steady state.
        gain_db = 20 * np.log10(
            stems_dsp.rms(kick[:, SR // 2 : -SR // 2])
            / stems_dsp.rms(at_corner[:, SR // 2 : -SR // 2])
        )
        self.assertAlmostEqual(gain_db, -6.0, delta=1.0)

        octave_up = synth_tone(corner * 2)
        kick_up, _ = stems_dsp.split_kick_perc(octave_up, SR)
        gain_up_db = 20 * np.log10(
            stems_dsp.rms(kick_up[:, SR // 2 : -SR // 2])
            / stems_dsp.rms(octave_up[:, SR // 2 : -SR // 2])
        )
        self.assertLess(gain_up_db, -22.0)
        self.assertGreater(gain_up_db, -32.0)

    def test_cutoff_above_nyquist_rejected(self):
        with self.assertRaises(stems_dsp.StemsError):
            stems_dsp.design_lowpass(8000, cutoff_hz=9000.0)

    def test_too_short_signal_rejected(self):
        with self.assertRaises(stems_dsp.StemsError):
            stems_dsp.split_kick_perc(np.zeros((2, 4), dtype=np.float32), SR)

    def test_silent_drums_report_floor_not_nan(self):
        silent = np.zeros((2, SR), dtype=np.float32)
        self.assertEqual(
            stems_dsp.null_sum_residual_db(silent, silent, silent), stems_dsp.SILENCE_FLOOR_DB
        )


class EnergyCurveTest(unittest.TestCase):
    def test_frame_grid_is_80hz(self):
        curve = stems_dsp.energy_curve(synth_tone(440.0, seconds=2.0), SR)
        self.assertEqual(curve.size, 160)

    def test_quantized_payload_shape(self):
        curves = {
            "vocals": stems_dsp.energy_curve(synth_tone(440.0, seconds=1.0), SR),
            "bass": stems_dsp.energy_curve(synth_tone(80.0, seconds=1.0), SR),
        }
        payload = stems_dsp.quantize_energy(curves)
        self.assertEqual(payload["frame_hz"], 80)
        self.assertEqual(payload["frame_count"], 80)
        self.assertEqual(payload["encoding"], "uint8-linear")
        for name in ("vocals", "bass"):
            decoded = np.frombuffer(base64.b64decode(payload["channels"][name]), dtype=np.uint8)
            self.assertEqual(decoded.size, 80)

    def test_channels_share_one_normalization_reference(self):
        loud = stems_dsp.energy_curve(synth_tone(440.0, seconds=1.0) * 4.0, SR)
        quiet = stems_dsp.energy_curve(synth_tone(440.0, seconds=1.0) * 0.25, SR)
        payload = stems_dsp.quantize_energy({"loud": loud, "quiet": quiet})
        loud_peak = np.frombuffer(base64.b64decode(payload["channels"]["loud"]), np.uint8).max()
        quiet_peak = np.frombuffer(base64.b64decode(payload["channels"]["quiet"]), np.uint8).max()
        self.assertEqual(int(loud_peak), 255)
        self.assertLess(int(quiet_peak), 40)

    def test_silent_channels_do_not_divide_by_zero(self):
        payload = stems_dsp.quantize_energy({"a": np.zeros(10), "b": np.zeros(10)})
        self.assertEqual(payload["reference_rms"], 0.0)
        decoded = np.frombuffer(base64.b64decode(payload["channels"]["a"]), dtype=np.uint8)
        self.assertTrue(np.all(decoded == 0))


class OpusUniformityTest(unittest.TestCase):
    def test_encoder_flags_identical_across_stems(self):
        signatures = {
            stems_dsp.encoder_flag_signature(stems_dsp.opus_encode_argv(f"/tmp/{name}.opus", SR))
            for name in ("vocals", "drums", "bass", "other", "kick", "perc")
        }
        self.assertEqual(len(signatures), 1, signatures)

    def test_encoder_flags_carry_the_declared_settings(self):
        argv = stems_dsp.opus_encode_argv("/tmp/x.opus", SR)
        self.assertIn("libopus", argv)
        self.assertIn("128k", argv)
        self.assertEqual(argv[argv.index("-vbr") + 1], "on")
        self.assertEqual(argv[-2], "2")
        self.assertEqual(argv[argv.index("-application") + 1], "audio")
        # The LAST -ar wins in ffmpeg output options; it must be 48 kHz.
        last_ar = len(argv) - 1 - argv[::-1].index("-ar")
        self.assertEqual(argv[last_ar + 1], "48000")

    def test_declared_codec_matches_argv(self):
        self.assertEqual(stems_dsp.OPUS_CODEC["sample_rate_hz"], 48000)
        self.assertEqual(stems_dsp.OPUS_CODEC["bitrate_kbps"], 128)
        self.assertTrue(stems_dsp.OPUS_CODEC["vbr"])


class ManifestTest(unittest.TestCase):
    def _manifest(self, channel_set="stems5-hybrid-v1", encode=False):
        with tempfile.TemporaryDirectory() as out_dir:
            return stems_dsp.run_separation(
                audio_path="unused.wav",
                out_dir=out_dir,
                track_id=7,
                channel_set=channel_set,
                separator=fake_separator,
                encode=encode,
            )

    def test_manifest_is_json_serializable_and_versioned(self):
        manifest = self._manifest()
        json.dumps(manifest)
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["track_id"], 7)
        self.assertEqual(manifest["channel_set"], "stems5-hybrid-v1")
        self.assertEqual(manifest["stem_model_version"], "audio-separator-htdemucs-ft-4s-v1+lr4-180")

    def test_manifest_emits_six_objects_with_drums_retained(self):
        objects = self._manifest()["artifacts"]["objects"]
        self.assertEqual(len(objects), 6)
        channels = [obj["channel"] for obj in objects]
        self.assertEqual(channels, ["vocals", "melody", "bass", "kick", "perc", "drums"])
        self.assertEqual(len({obj["key"] for obj in objects}), 6)

    def test_manifest_records_null_sum_and_threshold(self):
        null_sum = self._manifest()["artifacts"]["null_sum"]
        self.assertEqual(null_sum["pair"], ["kick", "perc"])
        self.assertEqual(null_sum["against"], "drums")
        self.assertEqual(null_sum["threshold_db"], -80.0)
        self.assertTrue(null_sum["passed"])
        self.assertLessEqual(null_sum["residual_db"], -80.0)

    def test_manifest_records_provenance_identity(self):
        provenance = self._manifest()["provenance"]
        self.assertEqual(provenance["worker"], "stemsep-worker")
        self.assertEqual(provenance["worker_version"], stems_dsp.WORKER_VERSION)
        self.assertEqual(provenance["inference_provider"]["name"], "audio-separator")
        self.assertEqual(provenance["model"]["name"], "htdemucs_ft")
        self.assertEqual(provenance["model"]["config"]["sha256"], stems_dsp.MODEL_CONFIG_SHA256)
        self.assertEqual(
            provenance["separator"]["output_boundary"]["normalization_threshold"], 1.0
        )
        self.assertEqual(provenance["crossover"]["cutoff_hz"], 180.0)
        self.assertTrue(provenance["crossover"]["zero_phase"])

    def test_manifest_carries_energy_for_every_persisted_channel(self):
        energy = self._manifest()["artifacts"]["energy"]
        self.assertEqual(
            sorted(energy["channels"]),
            sorted(["vocals", "melody", "bass", "kick", "perc", "drums"]),
        )
        self.assertEqual(energy["frame_hz"], 80)

    def test_stems4_set_has_no_derived_pair(self):
        manifest = self._manifest(channel_set="stems4-demucs-v1")
        channels = [obj["channel"] for obj in manifest["artifacts"]["objects"]]
        self.assertEqual(channels, ["vocals", "drums", "bass", "other"])
        self.assertNotIn("null_sum", manifest["artifacts"])
        self.assertEqual(manifest["stem_model_version"], "audio-separator-htdemucs-ft-4s-v1")

    def test_incomplete_separator_output_is_rejected(self):
        def broken(_path, sample_rate):
            stems = fake_separator(_path, sample_rate)
            del stems["bass"]
            return stems

        with tempfile.TemporaryDirectory() as out_dir:
            with self.assertRaises(stems_dsp.StemsError):
                stems_dsp.run_separation(
                    audio_path="unused.wav",
                    out_dir=out_dir,
                    track_id=1,
                    separator=broken,
                    encode=False,
                )


@unittest.skipUnless(HAVE_FFMPEG, "ffmpeg with libopus is required")
class FfmpegRoundTripTest(unittest.TestCase):
    def test_encode_then_decode_preserves_the_signal(self):
        tone = synth_tone(440.0, seconds=1.0)
        with tempfile.TemporaryDirectory() as tmp:
            dest = Path(tmp) / "tone.opus"
            size = stems_dsp.encode_opus(tone, dest, SR)
            self.assertGreater(size, 0)
            decoded = stems_dsp.decode_pcm(dest, 48000)
            self.assertEqual(decoded.shape[0], 2)
            self.assertGreater(stems_dsp.rms(decoded), 0.05)

    def test_full_pipeline_with_encoding(self):
        with tempfile.TemporaryDirectory() as out_dir:
            manifest = stems_dsp.run_separation(
                audio_path="unused.wav",
                out_dir=out_dir,
                track_id=9,
                separator=fake_separator,
                encode=True,
            )
        for obj in manifest["artifacts"]["objects"]:
            self.assertGreater(obj["bytes"], 0, obj["channel"])
            self.assertGreater(obj["duration_ms"], 2500)

    def test_cli_check_reports_identity(self):
        stdout = io.StringIO()
        with mock.patch.object(stems_dsp, "validate_model_bundle"), redirect_stdout(stdout):
            self.assertEqual(stems_dsp.main(["--check"]), 0)
        payload = json.loads(stdout.getvalue())
        self.assertEqual(payload["worker"], "stemsep-worker")
        self.assertEqual(payload["worker_version"], stems_dsp.WORKER_VERSION)
        self.assertIn("stems5-hybrid-v1", payload["channel_sets"])
        self.assertTrue(payload["ffmpeg"])


if __name__ == "__main__":
    unittest.main()
