# ADR 0002: Agentic Delivery Harness

## Status

Accepted.

## Context

Open Music Player has high-risk seams across mobile audio playback, queue/mix
state, signed object-storage URLs, analyzer metadata, Tailnet staging, and a
multi-component backend/client/extension build. Agents need a stable way to
find the right files and commands, but process docs alone do not stop a bad PR.

The Hermes/EBI pipeline pattern we want is: intent, context map, deterministic
harness, adversarial doctrine-vs-harness review, exact-head evidence, and
runtime proof for mobile/audio claims.

## Decision

The repository owns root wrappers for repeated dev cycles:

- `scripts/dev`
- `scripts/test`
- `scripts/lint`
- `scripts/build`
- `scripts/smoke`
- `scripts/agentic-harness`
- `scripts/agentic-cycle`
- `scripts/release-audit`
- `scripts/dogfood-android`

The delivery harness is wired into CI through `scripts/lint delivery` and fails
on missing repo maps, missing executable root commands, missing evidence
templates, broken script syntax, missing CI wiring, architecture guardrail drift,
secret-like values, and review-bypass patterns such as workflows or scripts that
push directly to `main` without an explicit human override.

Backend test dependencies use `scripts/dev test-infra` so Redis queue tests do
not race a running backend worker from the dogfood profile. Android/audio PRs
use `scripts/dogfood-android` to record build metadata, APK hash, ADB target,
and logcat evidence when physical-device behavior matters.

## Consequences

- New agents have stable entry points and do not need to rediscover safe
  component-specific commands before changing production code.
- CI catches delivery scaffold drift separately from backend/client/extension
  behavior.
- Process improvements must include executable backpressure or clearly state the
  remaining doctrine-only gap.
- Full physical-device dogfood remains a release-gate responsibility, not a
  mandatory lint step.
- Root wrappers and docs must stay in sync with component workflow changes.
