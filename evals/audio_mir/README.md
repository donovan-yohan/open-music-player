# Audio MIR evaluation package

This package scores Open Music Player analyzer outputs without changing the production analyzer contract.

Use the repository wrapper:

```bash
scripts/eval audio-mir --help
```

The scorer hard-separates human/dataset `ground_truth`, `external_reference` labels such as Tunebat or Spotify estimates, and `synthetic` fixtures. It fails on duplicate IDs, partial prediction sets, malformed artifacts, and analyzer infrastructure errors. Manifest adapters cover GiantSteps tempo/key and GuitarSet tempo/beat/downbeat/key annotations.

For downbeat experiments, local manifest rows can declare `evaluation_split`
(`pilot`, `calibration`, or `holdout`) and a stable `stratum`. Schema-3 reports
then expose annotation-bounded bar-phase precision/recall, one/two/three-beat
confusion, continuity, local-tempo interval coverage/error and tempo-change FPR, confidence
reliability/coverage, runtime, and peak RSS without changing production analyzer
output. `run` accepts all four experiment
provenance fields (`--experiment-id`, `--experiment-arm`, `--experiment-factor`,
and `--freeze-id`) as an all-or-nothing packet. Use `promote` with a separate,
explicit calibration-derived policy; it fails closed rather than supplying an
automatic confidence threshold. Promotion rejects pilot/unspecified splits,
cross-split duplicate audio, dirty checkout artifacts, unknown meter/phase locks,
and a non-positive deterministic paired-bootstrap lower CI. `promote` requires an
evidence-output packet that canonically SHA-256-binds the policy, reports,
decision, manifest, audio, model, and repository identities. The freeze ID is
itself a required canonical hash of the frozen non-arm context, and the policy
must declare a hash calculated from calibration rows only; an arbitrary label or
holdout-derived threshold provenance fails promotion.
See
[`docs/AUDIO_MIR_EVALS.md`](../../docs/AUDIO_MIR_EVALS.md) for datasets,
metrics, artifact contracts, commands, and promotion rules.
