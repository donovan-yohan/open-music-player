# ADR 0003: Bounded Async Research Rollout

## Status

Accepted for internal dark-launch research only. DeepAgents is not adopted as a
production framework dependency.

## Decision

Synchronous discovery remains the existing deterministic, direct judge path.
It builds baseline revision 1 before the durable job is created and never waits
for asynchronous research. Revision 1 is immutable and is always available,
including when research is globally disabled, the worker is stopped, a model is
unavailable, or a job is cancelled.

The optional follow-up is a framework-neutral, bounded structured-action loop
run only by the dedicated durable worker. The server assigns and persists one
immutable variant at creation:

- `deterministic_only`: terminalize the job at creation with `model_disabled`;
  reserve no enhancement budget and run no worker.
- `direct_structured_judge`: the worker may request only the direct stage.
- `bounded_agent_dark_launch`: the worker may request only the deep stage.

Assignment is a stable BPS hash of the canonical request digest, not raw query
text, URLs, tokens, or credentials. Existing persisted assignments are the
authority for retry and lease recovery; changing flags cannot promote an
already-created job. Global enablement never changes a deterministic or direct
assignment into a deep execution.

`RESEARCH_ENABLED=false`, all deep/dark/surface/web flags false, and cohort
zero are the safe defaults. Startup validates the controls before any worker can
start. Contradictory deep/dark/surface/cohort combinations fail fast.
Every production worker configuration explicitly rejects
`RESEARCH_DEEP_AGENT_WEB_ENABLED`; a gateway that needs Firecrawl or service
credentials is eval-only until a topology can preserve the credential boundary.
Only the model credential allowlist may enter the child environment. Raw model
tokens, chain of thought, and streaming provider frames are never persisted or
emitted.

Dark revisions append as immutable, validated durable records and retain safe
terminal telemetry. With `RESEARCH_DEEP_AGENT_SURFACE_REVISIONS=false`, the
repository/API projection returns revision 1 as latest, hides dark revision
events and terminal telemetry, and resolves reviews/source selection against revision 1. With the flag
true, the normal validated immutable append path may surface the dark revision.

## Ownership and limits

The Go server owns assignment, deterministic baseline creation, validation,
revision persistence, review/source decisions, and API projection. The worker
owns one bounded child invocation for the persisted variant only. Candidate
assembly remains an isolated eval/worker contract, not a production framework
dependency. Tool, model-call, recursion, candidate, response-size, token, and
wall-clock budgets are supplied by Go and verified at the worker boundary.

Metrics are aggregate and allowlisted: lifecycle status, safe stage/kind,
bounded tool/model counts, repair marker, and durations. They exclude request
content, IDs, provider URLs, prompts, secrets, model output, and credentials.

## Measured #272 evidence

The #272 evaluation measured:

- process start: 648ms;
- cold simple: 12.589s;
- warm: 1.959s;
- stream first chunk: 202ms;
- direct: 7.692s;
- bounded agent: 68.821s, including 68.799s in four model calls and less than
  0.3ms in tools.

This supports the split: the bounded agent is asynchronous dark-launch research,
not a synchronous discovery dependency.

## Cloud pilot evidence

The completed cloud pilot used redacted artifacts and a clean leak scan:

- DeepSeek direct: correct `3/3`; model durations 3316ms, 2135ms, and 2915ms
  (`p50` 2915ms).
- Kimi K2.6 direct: correct `3/3`; model durations 16164ms, 7697ms, and
  11915ms (`p50` 11915ms).
- One-attempt bounded-agent official-audio runs produced zero recommendations
  for both models and safely fell back: DeepSeek 2173ms; Kimi 17051ms.

The recorded local #272 representative direct model time was 7632ms; the local
agent was 68799ms across four calls. Those local multi-call measurements are
not apples-to-apples with the one-call cloud pilot. The pilot nevertheless
shows that cloud DeepSeek substantially improves direct latency, Kimi is slower
with no quality gain in this sample, and neither agent arm demonstrated added
value. This reinforces the decision to reject a DeepAgents framework dependency
and retain the bounded agent only as default-off dark-launch research.

The redacted evidence artifacts are:

```text
/tmp/soundq-275-pilot-cloud-deepseek-direct.jsonl
/tmp/soundq-275-pilot-cloud-deepseek-agent.jsonl
/tmp/soundq-275-pilot-cloud-kimi-direct.jsonl
/tmp/soundq-275-pilot-cloud-kimi-agent.jsonl
```

## Rollout and rollback

Start with deep cohort `0` and the dedicated worker stopped. Enable only after
the configuration validator, focused Go tests, and replay/eval evidence pass.
Rollback is setting cohort to `0` (for new jobs) and stopping the worker; it
preserves baseline revisions and durable jobs. It does not delete records or
reinterpret persisted assignments.

## Eval commands

```bash
scripts/eval agent-search --mode replay
GOFLAGS=-buildvcs=false go -C backend test ./internal/config ./internal/research ./internal/api ./cmd/server
```

Live evaluation remains opt-in and must use redacted artifacts. It is not a
production gateway rollout.

The cloud pilot used a reviewed OpenAI-compatible endpoint supplied only through
the environment. These redacted commands reproduce its bounded shape without
recording the endpoint or credential:

```bash
export AGENT_SEARCH_BASE_URL=https://reviewed-openai-compatible-endpoint/v1
export AGENT_SEARCH_API_KEY=from-a-secret-store

scripts/eval agent-search --mode live --skip-probe --max-model-calls 1 \
  --arm direct_judge --model deepseek-v4-flash \
  --case plain-artist-song-official-audio,live-trap-not-requested,artist-only-ambiguous \
  --output /tmp/soundq-275-pilot-cloud-deepseek-direct.jsonl
scripts/eval agent-search --mode live --skip-probe --max-model-calls 1 \
  --arm deep_agent --model deepseek-v4-flash \
  --case plain-artist-song-official-audio \
  --output /tmp/soundq-275-pilot-cloud-deepseek-agent.jsonl
scripts/eval agent-search --mode live --skip-probe --max-model-calls 1 \
  --arm direct_judge --model kimi-k2.6 \
  --case plain-artist-song-official-audio,live-trap-not-requested,artist-only-ambiguous \
  --output /tmp/soundq-275-pilot-cloud-kimi-direct.jsonl
scripts/eval agent-search --mode live --skip-probe --max-model-calls 1 \
  --arm deep_agent --model kimi-k2.6 \
  --case plain-artist-song-official-audio \
  --output /tmp/soundq-275-pilot-cloud-kimi-agent.jsonl
```
