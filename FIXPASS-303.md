# Fix pass: cross-model review findings on feat/303-spectral-slice1

Verdicts: dsp-signal fix-then-approve, contract-invariants fix-then-approve, render-hydration approve. ONE batch; refute with evidence if wrong.

## P1 (both lenses independently confirmed — library-scale failure)
1. `audio_mir.py` aggregate_band_energy_at_pcm_boundaries — raises ValueError whenever Go's ffmpeg PCM count differs from Python's decode count (typical MP3/m4a/opus decoder-delay deltas); numerically replicated failing 70-80% of track lengths (e.g. S=22007,P=22047,F=80 leaves bins 2,4 empty). Rolling re-analysis would 500 most of the library. Fix: make the reduction TOTAL, not asserting exact coverage — after np.maximum.at, fill empty bins from the nearest covered neighbor (nearest-neighbor of real measured energy = reduction, not fabrication); keep ValueError only for zero-valid-centers. Regression: run extract_spectral_bands END-TO-END (not the aggregate helper directly) sweeping pcm-vs-samples deltas {0, ±64, ±1105, ±1152, ±2257} across several durations including the 32768-cap region.
2. Test-coverage gate: no test executes the new band path with REAL librosa, and no fixture asserts band dominance (the mocked-librosa test fabricates linear 'mel' frequencies; boundary tests bypass the hop/scale pipeline; the Docker MIR smoke omits --waveform-frames so the new stage returns empty). Fix: (a) runtime-gated unittest (skipUnless librosa importable) generating tones in-process: 100 Hz segment → low-dominant, 8 kHz segment → high-dominant, shared-scalar invariant; (b) extend the analyzer-image smoke (backend/Dockerfile) to run audio_mir.py WITH --waveform-frames and an independently-derived --pcm-samples on a two-tone MP3 fixture (encoded lossy so decode-length mismatch is exercised) asserting the same dominance.

## P2
3. Rolling re-analysis honesty: the drain re-runs the FULL pipeline (Beat This inference included — analyzer stateless, cannot reuse beat results). Add the one-sentence cost note to docs/AUDIO_ANALYZER_SERVICE.md re-analysis section AND REPORT-303. Optionally note a follow-up idea (beat-result reuse keyed on tempo-model identity) — do not build it.
4. `timeline_waveform_painter.dart` shouldRepaint — O(frames) channel scans run before the cheap color inequality. Reorder so `old.color != color` short-circuits (or precompute a usesLaneColor flag at construction).
5. Golden test discrimination — the signed-minima assertion passes under mirrored -peak rendering too. Use a fixture with |minPeak| > maxPeak and assert asymmetric extents (or the suggested zero-alpha probe) so mirrored-minima regression fails.
6. REPORT-303 claims a 'pending' honesty label the UI never renders (resolutionLabel is write-only in lib/). Reword the report/claim to the shipped truth (flat accent lane + existing song-info status text); surfacing the label in the lane UI is optional — if trivial do it, else leave reworded.

## Nits (do them)
7. Mel mask centers: use `librosa.mel_frequencies(n_mels=SPECTRAL_MEL_BANDS + 2, fmin=..., fmax=sr/2)[1:-1]` (true row centers of a 128-band melspectrogram).
8. fmin=20.0 (both melspectrogram and mel_frequencies, consistent) — the low band must span ~[20,200) Hz, not include DC/subsonic bins.
9. `queue_provider.dart:1505-1513` — analyzed-but-detail-less responses (mid-rolling-upgrade backend) retry forever at the backoff cap; count them against a bounded attempt cap until interest re-establishes.
10. `seratoWaveformColorForChannels` — all-zero channel energies with nonzero amplitude paints pure white (hotter than any real color); return null → lane color fallback instead.
11. `queue_screen_test.dart` viewport oracle hardcodes lane pixel heights; derive from rendered widgets (tester.getSize) or add a pointer comment to the exact queue_screen constants.

## Verification after fixes
- `scripts/lint analyzer` + `scripts/test analyzer` + `scripts/build analyzer` (the image smoke MUST now exercise the spectral stage — record the dominance assertions passing with real librosa).
- Backend suite with isolated infra; `cd client && flutter analyze` (9 known infos) + `flutter test` (>= 1077, 0 fail).
- `git diff --check origin/main...HEAD` exit 0 at final head.
- One conventional fix commit (or two if analyzer/client split is cleaner). Append "## Fix pass (cross-model review)" to REPORT-303.md: finding → action + exact results.
