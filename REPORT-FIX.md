# Timeline Artifact Parsing Fix

## Delivered

- Passed the top-level analysis `artifacts` envelope into
  `TrackAnalysis.fromJson` for both analysis GET and override PATCH responses.
- Added mocked-Dio contract tests using a full descriptor-only `bands3-v1`
  summary with artifact-backed waveform and channel samples.
- Verified rich waveform frames and resolved low/mid/high channel values survive
  both hydration and correction-save responses.

## Evidence

- Mutation proof: removing both `artifacts` handoffs made both new tests fail
  with empty waveform minima; restoring them made both tests pass.
- `cd client && flutter test test/analysis_api_client_contract_test.dart`:
  2 passed.
- Adversarial review: no P0/P1 findings and no lower-risk notes.
- `cd client && flutter analyze`: exactly 9 known info-level findings, with no
  warnings or errors.
- `cd client && flutter test` on a clean detached commit tree: 1,080 passed.
- `git diff --check`: passed.

## Scope

Pre-existing changes in `client/test/queue_provider_timeline_editing_test.dart`
and the untracked task prompt were preserved and excluded from this fix commit.
