# Audio MIR evaluation package

This package scores Open Music Player analyzer outputs without changing the production analyzer contract.

Use the repository wrapper:

```bash
scripts/eval audio-mir --help
```

The scorer hard-separates human/dataset `ground_truth`, `external_reference` labels such as Tunebat or Spotify estimates, and `synthetic` fixtures. It fails on duplicate IDs, partial prediction sets, malformed artifacts, and analyzer infrastructure errors. Manifest adapters cover GiantSteps tempo/key and GuitarSet tempo/beat/downbeat/key annotations.

See [`docs/AUDIO_MIR_EVALS.md`](../../docs/AUDIO_MIR_EVALS.md) for datasets, metrics, commands, and promotion rules.
