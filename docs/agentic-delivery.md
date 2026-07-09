# Agentic Delivery Policy

This repo uses the global `agentic-engineering-delivery` workflow adapted from
the Hermes/Ocean and EBI pipeline. The local rule is simple: production work
ships with intent, context, deterministic backpressure, and exact evidence.

## Work Packet

For substantial work, capture this packet in the issue, PR body, or handoff:

- Intent: user/system outcome, current behavior, target behavior, non-goals.
- Context map: domain concepts, files/modules, docs/ADRs, APIs, data, deploy
  path, and similar local patterns.
- Harness / backpressure: tests, lint/type/build checks, architecture
  guardrails, smoke checks, logs/artifacts, and manual evidence only when it
  cannot be automated.
- Risk seams: auth/security, persistence/migrations, async playback/session
  state, public API contracts, UI/device behavior, and deploy/rollback.
- Handoff evidence: head SHA, commands plus exit codes, artifact IDs, device
  IDs when relevant, caveats, and follow-ups.

## Exact-Head Gates

Exact-head evidence is the release invariant. Before merge, the QA/review/build
evidence must cite the current PR head SHA.

Use this rerun policy when the head changes:

- Same head: reuse existing QA/review only if it cites the live head SHA.
- Non-semantic delta: docs, comments, formatting, or metadata can reuse prior
  evidence after a brief incremental note.
- Test/harness-only delta: run targeted checks for the affected harness behavior;
  rerun full review only if the test change can hide runtime behavior.
- Behavior/security/protocol/destructive/runtime delta: require fresh targeted
  QA plus review for the new head.
- Mobile/audio/device delta: require physical-device dogfood when unit tests
  cannot prove the central claim.

Do not store stale PR numbers, head SHAs, or one-off gate verdicts in semantic
memory. Keep per-PR/head state in PR comments, board artifacts, or local logs.

## Canonical Commands

CI and humans should prefer the root scripts so local and remote backpressure
exercise the same behavior:

- `scripts/lint delivery`
- `scripts/lint backend|client|extension`
- `scripts/test backend|client|extension`
- `scripts/build backend|client|extension`
- `scripts/dev isolated`
- `scripts/smoke isolated`
- `scripts/smoke playback-isolated`

Heavy mobile build checks can stay targeted, but the handoff must say whether
the build was local, CI artifact, emulator, or physical device.

## Mobile And Audio Dogfood

For Android/audio/playback claims, unit tests are necessary but not sufficient
when the bug depends on device media controls, physical gestures, audio focus,
notification controls, stream timing, or installed APK configuration.

Record:

- `OMP_API_BASE_URL`, `OMP_SOURCE_REF`, and `OMP_BUILD_ID`;
- APK path or CI artifact name;
- APK SHA256 when handed off outside CI;
- install target from `adb devices -l`;
- backend URL and health check used by the device;
- relevant log tail path under `/tmp`, not pasted raw into the PR.

## Resource Closeout

Before final handoff, name any resources created or reused:

- dev servers and ports;
- Docker containers or Compose projects;
- emulator/physical device state;
- APK hosts or temporary artifact directories;
- background processes, logs, and temporary worktrees.

Stop temporary resources unless the user explicitly wants them left running.
