# Audio MIR evaluation

## Decision

Benchmark the local analyzer before changing its models or adding a web-research dependency. External catalog values are useful disagreement signals, not ground truth.

This harness evaluates the current out-of-process analyzer without changing its production JSON contract. Audio and dataset downloads stay local and untracked. Every manifest row declares one label class:

- `ground_truth` — human/dataset annotations suitable for accuracy claims;
- `external_reference` — estimates from Tunebat, Spotify, Rekordbox, Mixed In Key, or similar systems;
- `synthetic` — generated invariants and smoke fixtures.

Reports are grouped by label class and never average these classes together.

## Current baseline

At analyzer version `2026-07-24-1`:

- tempo, beats, and downbeats come from Beat This `final0` with minimal peak postprocessing, followed by OMP's dynamic beat-grid and downbeat regularizers;
- global BPM is derived from accepted inter-beat intervals;
- key is harmonic-source CQT chroma averaged over the full track and correlated with Krumhansl major/minor profiles;
- the analyzer has no stem-separation model. Its low/mid/high spectral bands are display energy channels, not stems.

The existing Python suite mostly verifies synthetic invariants and two production-derived marker sequences. It does not contain audio plus independent annotations, so it cannot establish real-world accuracy.

## Metrics

| Task | Primary metrics | Diagnostic splits |
| --- | --- | --- |
| Tempo | Acc1 within 4%; Acc2 allowing half/double tempo; absolute log2 error | exact, half, double, other |
| Beats | F-measure at 70 ms; Cemgil; CMLc/CMLt; AMLc/AMLt | missing events, phase/localization, continuity, metrical-level errors |
| Downbeats | same event and continuity metrics as beats | beat-grid failure vs bar-phase/meter failure |
| Key | exact accuracy; MIREX weighted score | exact, perfect fifth, relative, parallel, other |
| Runtime | per-track wall time, p50, p95 | analyzer errors are counted, never dropped |

Camelot is a deterministic projection of tonic and mode; test that mapping as a unit contract, but measure audio inference against the underlying musical key.

## Dataset ladder

1. **GuitarSet 1.1.0** — CC BY 4.0 audio and annotations; includes beats, downbeats, and key. The mono mic archive is about 657 MB. It is legally clean and annotation-rich, but solo acoustic guitar is deliberately out of SoundQ's main distribution.
2. **GiantSteps tempo/key** — the most relevant public EDM benchmark: 664 tempo and 604 key two-minute Beatport previews with human-corrected labels. The repository provides checksums and download scripts, but declares no dataset license. Use locally for research after reviewing source terms; do not redistribute audio or make it a public CI dependency.
3. **Private SoundQ dogfood corpus** — 50–100 fingerprinted library files, stratified across steady dance music, hip-hop/trap half-time, sparse intros, live/variable tempo, non-4/4 meter, remixes, and modulating/tonally ambiguous tracks. Store only hashes, annotations, and provenance in a private eval location. Manually validate disputed cases by listening to clicks overlaid on audio.
4. **MUSDB18** — use the package's seven-second excerpts only for source-separation plumbing smoke. Full MUSDB18 requires approved academic access and carries per-track rights; use its 50-track test set with `museval`/BSSEval v4 only after a stem model exists. Do not mix stem scores into tempo/key reports.

Tunebat has two distinct products. Its public database says its BPM/key fields are supplied by Spotify. Its upload analyzer runs different Music Technology Group-derived algorithms in the browser. Therefore a scraped Tunebat song page is an `external_reference`, not an independent Tunebat analysis and not training ground truth.

## Commands

Prepare a local GiantSteps checkout with its upstream script, then build a manifest only for audio that is present:

```bash
scripts/eval audio-mir prepare-giantsteps \
  --dataset-root /private/evals/giantsteps-tempo-dataset \
  --task tempo \
  --limit 20 \
  --output /tmp/giantsteps-tempo-20.jsonl
```

For legally clean beat/downbeat coverage, download GuitarSet 1.1.0's `annotation.zip` and one mono audio archive from Zenodo, verify the published checksums, then prepare all four supported tasks from the JAMS records:

```bash
scripts/eval audio-mir prepare-guitarset \
  --annotation-zip /private/evals/guitarset/annotation.zip \
  --audio-dir /private/evals/guitarset/audio_mono-mic \
  --limit 20 \
  --output /tmp/guitarset-20.jsonl
```

Run the exact OMP helper from a Python environment containing the pinned analyzer dependencies and checkpoint:

```bash
scripts/eval audio-mir run \
  --manifest /tmp/giantsteps-tempo-20.jsonl \
  --analyzer-python /private/evals/omp-mir-runtime/bin/python \
  --analyzer-script backend/cmd/audio-analyzer/audio_mir.py \
  --model /private/evals/models/beat_this-final0.ckpt \
  --output /tmp/omp-mir-predictions.jsonl
```

Score the complete artifact:

```bash
scripts/eval audio-mir score \
  --manifest /tmp/giantsteps-tempo-20.jsonl \
  --predictions /tmp/omp-mir-predictions.jsonl \
  --output /tmp/omp-mir-report.json
```

The analyzer runner uses argument arrays, not a shell template. It accepts local files only, fingerprints each audio asset, records exact analyzer metadata, counts timeouts/errors, and exits nonzero for incomplete runs.

## Measured smoke runs

A real local run at repository head `960db87063ba98651a03110069bc691fa8177464` used the exact pinned CPU runtime with checksum-verified GiantSteps previews and GuitarSet 1.1.0 archives. The aggregate, source revisions, artifact hashes, environment, and limitations are recorded in [`docs/evidence/audio-mir/2026-07-25-smoke-summary.json`](evidence/audio-mir/2026-07-25-smoke-summary.json).

- GiantSteps tempo: 5/5 within 4%, 5/5 with octave tolerance, no half/double errors; p50 16.44 seconds per two-minute preview.
- GiantSteps key: 2/5 exact, MIREX weighted score 0.44, coverage 4/5; errors were one parallel-major/minor miss, one unrelated/semitone miss, and one abstention; p50 14.60 seconds.
- GuitarSet: 5/5 tempo Acc1; beat F-measure 0.924 but CMLc only 0.575; downbeat F-measure 0.732 and CMLc 0.560; key exact/MIREX 0.60; p50 3.94 seconds per roughly 30-second clip.

This is plumbing evidence, not an accuracy claim. Tempo is not obviously broken on these ten tracks. The GuitarSet continuity gap says global BPM can be right while the event grid is incomplete or unstable, especially on solo recordings. Downbeat alignment is the clearest measured beat-side weakness. Key is weak enough to justify a larger S-KEY comparison before tuning fixed profiles.

## Experiment order

1. Freeze a baseline report from the current analyzer.
2. For tempo/beats/downbeats, compare three arms on identical audio and annotations: upstream Beat This minimal output, current OMP regularization, and Beat This DBN. A DBN may improve stable 3/4 or 4/4 continuity while breaking variable tempo, meter changes, or tempos outside 55–215 BPM; do not select it from one aggregate score. The five-track tempo smoke is already clean, so no tempo algorithm change is justified yet.
3. For key, compare current CQT/Krumhansl against Deezer S-KEY first. S-KEY code and bundled checkpoint are MIT-licensed, CPU-capable, and specifically target 24-class major/minor estimation. Essentia KeyExtractor is a useful research control with tuning correction and richer profile choices, but Essentia is AGPLv3; do not ship it inside SoundQ without deliberate license compliance or a commercial license. Keep model size, p95 CPU time, and calibrated abstention in the decision.
4. Calibrate confidence separately for each task. In the five-track key smoke, a wrong prediction at 0.563 outranked a correct prediction at 0.517; in the tempo smoke, a correct estimate scored only 0.185. Those five points prove the current scalar is not itself a correctness probability. Fit thresholds only on a held-out, stratified corpus and report coverage versus error/false-auto-lock rate.
5. Improve the fixed-profile key arm only as a cheap baseline: compare time-window consensus instead of one full-track mean, robust frame aggregation, explicit tuning correction, pitch-class whitening/thresholding, and beat-synchronous chroma. Do not pile these heuristics into production unless paired ablations beat both the current arm and S-KEY.
6. Only tune tempo/downbeat thresholds or postprocessing after per-track event failure classes are visible. Do not train on scraped catalog estimates.
7. Treat stems as a separate product experiment. Benchmark an explicit separator on MUSDB18 before accepting the roughly 4x output storage, CPU/GPU scheduling, model licensing, and playback/API work. Demucs code is MIT but its original repository is archived and the full benchmark corpus is academic/per-track licensed; verify the exact maintained fork, checkpoint, and deployment rights. Do not add separation merely to improve Beat This unless an ablation proves it helps.

## Promotion rule

Promote a candidate only if it improves the target-domain holdout without materially regressing open-dataset hard cases, keeps analyzer failures at zero, and fits the self-hosted CPU/RAM/runtime budget. Report paired per-track deltas and bootstrap confidence intervals once the corpus is large enough; a 5–20 track smoke is plumbing evidence, not a model-quality conclusion.
