## Intent

- User/system outcome:
- Current behavior:
- Target behavior:
- Non-goals:

## Context map

- Domain concepts:
- Relevant files/modules:
- Docs/ADRs/specs:
- External systems/data:

## Harness / backpressure

- Tests:
- Lint/type/build:
- Architecture guardrails:
- Runtime/API/device smoke:
- Logs/artifacts:

## Gate classification

- Head delta risk tier: same-head / non-semantic / test-harness-only / behavior-runtime / security-protocol-destructive / mobile-audio-device
- Fresh QA/review required? yes/no + why:
- Physical device dogfood required? yes/no + target:

## Risk seams

- Auth/security:
- Persistence/migrations:
- Async/playback/session state:
- Public API/contracts:
- UI/device behavior:
- Deploy/rollback:

## Exact-head evidence

- Head SHA:
- Commands + exit codes:
- Build/deploy/device IDs:
- Caveats/follow-ups:

See `docs/agentic-delivery.md` for the exact-head gate policy and mobile/audio
dogfood evidence requirements.
