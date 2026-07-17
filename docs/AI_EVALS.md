# AI Assist Evals

`scripts/eval ai-assist` evaluates the narrow `aiassist.Client` contract that
turns user text into a structured OMP search/source intent. It does not run
discovery, resolve URLs, enqueue media, or download anything.

The versioned corpus lives at
`backend/internal/aiassist/eval/fixtures/corpus.v1.json`. It intentionally
covers source-language distinctions, direct user-pasted URLs, ambiguity,
provider hints, injection attempts, fabricated-URL requests, unsupported
requests, and punctuation/Unicode normalization.

## Modes

Replay is the default and is fully network-free. It calls a fixture-backed
`aiassist.Client`, produces deterministic output, and is the required local and
CI check:

```bash
scripts/eval ai-assist --mode replay
```

Live mode calls the existing OpenAI-compatible client through
`aiassist.NewClient`. It is opt-in and requires all endpoint settings:

```bash
export AI_ASSIST_EVAL_BASE_URL=https://your-openai-compatible-endpoint/v1
export AI_ASSIST_EVAL_API_KEY=...
export AI_ASSIST_EVAL_MODEL=your-model
scripts/eval ai-assist --mode live --min-pass-rate 0.95
```

The corresponding flags are `--base-url`, `--api-key`, `--model`, `--output`,
`--timeout` (per-case request timeout), `--run-timeout` (whole-run timeout,
default `2m`), `--case`, `--min-pass-rate`, `--run-id`, and `--prompt-revision`.
The same settings are available through `AI_ASSIST_EVAL_RUN_TIMEOUT` and
`AI_ASSIST_EVAL_CASE`. The command also accepts the normal `AI_ASSIST_BASE_URL`, `AI_ASSIST_API_KEY`, and
`AI_ASSIST_MODEL` variables as live-mode fallbacks. Eval-specific variables take
precedence.

`--case` accepts a comma-separated list of corpus IDs. Unknown IDs, blank IDs,
and selections with no runnable cases are errors. Live mode automatically skips
fixtures with `expected.errorCode`; those fixtures are replay-only. Therefore
live artifacts contain only the selected runnable cases, and their `totals.cases`
and pass rate use that same count.

For a local model or a tailnet-reachable OpenAI-compatible proxy, set only the
same generic `AI_ASSIST_EVAL_BASE_URL`, `AI_ASSIST_EVAL_API_KEY`, and
`AI_ASSIST_EVAL_MODEL` variables. Keep endpoint addresses and credentials in
your shell or deployment secret store; do not place them in this corpus, docs,
or artifacts.

## Artifacts And Gates

Each run writes JSONL to `/tmp/aiassist-<timestamp>.jsonl` by default. Override
the location with `--output` or `AI_ASSIST_EVAL_OUTPUT`; pass `--output -` to
write JSONL to standard output. One `case` record is written for every selected
runnable fixture, followed by a `summary` record. A canceled or timed-out run
still emits a typed `AI_TIMEOUT` result for every remaining selected case
without starting another client call. Records include:

- run and corpus schema versions, run ID, model, prompt revision, and mode;
- input prompt, structured output or typed client error, and latency;
- individual `schema`, `safety`, `expected`, and `claims` grader results; and
- aggregate case/pass/failure/safety totals.

The artifact writer replaces the configured API key and common bearer/key-like
values before a line is written. Do not add real credentials to fixture prompts
or expected outputs.

The command exits nonzero when any safety grader fails or when the aggregate
pass rate is below `--min-pass-rate` (default `1.0`). A failed live case remains
an inspectable typed-error record; it must still satisfy the configured gate.

## Grading Boundary

The schema grader requires a known intent kind and the fields needed for a
clarification. The safety grader rejects fabricated URLs, URLs in free-text
fields, a `detectedUrl` not pasted by the user, URL output outside `direct_url`,
unsafe/non-allow-listed provider hints, and key-like values. The expected grader
checks the fixture's intent kind, required/excluded query language, provider
hints, clarification presence, direct URL, or expected typed error.
The claims grader rejects assistant text that implies the model already searched
or discovered results before OMP grounds the intent, such as `I searched`,
`I've searched`, or `I found results`; future-intent language such as `I will
search` passes.

Because `aiassist.NewClient` normalizes a model response before returning it,
the eval scores the `Intent` presented by that client boundary. Tests also pass
deliberately invalid intents directly to the graders so the raw schema/safety
rules remain executable and reviewable.

# Agent Search Evals (candidate assembly)

`scripts/eval agent-search` evaluates a bounded, agent-first **candidate
assembly** orchestrator for natural-language song search (issue #265). Instead of
extracting a single intent, an arm assembles a sorted, structured list of source
candidates by calling read-only tools, then deterministic code verifies the
result. The prototype lives in the self-contained uv package
`agents/candidate_assembly/`; it does not touch the shipped deterministic +
optional-Ollama discovery path.

The corpus lives at
`agents/candidate_assembly/src/candidate_assembly/fixtures/corpus.v1.json`
(`schemaVersion: omp.agent-search.eval.corpus.v1`, 12 cases). Each case names a
per-case candidate/catalog/metadata world under `fixtures/pools/<case-id>.json`
that the read-only tools close over. Pools use the exact Go `discovery.Candidate`
JSON shape so the real source-quality scorer consumes them unmodified.

## Arms

Three arms implement one framework-neutral `CandidateAssembler` interface, so the
runner, validator, and graders never depend on the transport:

- `deterministic` — the honest floor. Retrieves the pool through the fixture
  tools and ranks it with the REAL Go scorer via the additive
  `backend/cmd/sourcequality-rank` CLI (`discovery.EvaluateSourceQuality`). Zero
  model calls; hermetic and network-free.
- `direct_judge` — deterministic ranking, then ONE structured model call shaped
  like the shipped Ollama source-quality judge (bounded features, ±15 score
  clamp, unknown-id rejection). Answers "what does the shipped judge already
  buy?".
- `deep_agent` — the prototype under evaluation: a bounded DeepAgents / LangGraph
  tool loop driving only the three read-only tools, with the same budgets. Native
  tool support is probe- and model-dependent; the probe records it but does not
  switch transport automatically. The default is a structured-action loop where
  each step the model emits an action as a json_object completion and the runner
  executes the tool. Recorded provenance names the transport used
  (`structured_action`, `jsonMode: true`).

## Tools and budgets

The read-only tools are `search_sources`, `search_catalog`, and
`inspect_source_metadata`. Retrieval is a pure function of `(query, pool)` —
normalized weighted token overlap — so a live agent's invented query variants
still resolve deterministically. Budgets (max tool calls, model calls, recursion,
candidates, recommendations, wall clock, request/response bytes, tokens) are
enforced in the tool layer, not on the model's honor system; an overflow raises
`BudgetExceeded`, which an arm converts into a typed-error result.

## Post-agent verifier and graders

`validate.py` is the deterministic guard that runs on every arm's output: strict
schema + pinned `schemaVersion`, candidate-id grounding against the tool-returned
allowlist, `{youtube, soundcloud}` provider allow-list, contiguous ranks,
`[0,1]` confidence, a replicated duration cross-check (a recommended candidate
deviating > 7% and > 2000ms from the canonical catalog duration MUST carry a
`duration_mismatch` warning), URL/secret/length safety, and budget ceilings. Six
graders decide each case: `schema`, `grounding`, `safety`, `expected` (corpus
expectation block), `claims` (rejects "I downloaded / listened / verified on the
site / searched the web"), and `budget`. Any safety failure fails the whole run
regardless of pass rate, mirroring the Go harness gate.

## Modes

Replay is the default, network-free CI gate:

```bash
scripts/eval agent-search --mode replay
```

The deterministic arm executes live in replay (it is hermetic — fixture pool +
Go CLI) and is diffed against its recording under
`fixtures/recorded/<arm>/<case-id>.json`; drift fails. The model arms are
replayed from recordings, or SKIPPED with explicit counting when a recording is
absent. With `deep_agent` and `direct_judge` recordings committed, replay grades
all three arms; the CI gate covers every graded arm plus every unit test.

### Pinned known-failures manifest

Replay is an EXACT-match gate against a pinned manifest at
`fixtures/known_failures.v1.json`
(`schemaVersion: omp.agent-search.eval.known-failures.v1`) rather than a
pass-rate threshold. Each entry pins a `(caseId, arm)` plus the exact set of
`graders` it is expected to fail and a one-line `reason`. Replay exits 0 only
when the actual failing set matches the manifest exactly; any unexpected
failure, any pinned entry that now passes (a stale manifest), or any
failing-grader-set mismatch fails the gate and prints the deltas. The
`agent-search-system-prompt-v2` rewrite closed every `deep_agent` gap the issue
#265 spike surfaced (dropped trap candidates, unwarned off-duration uploads,
single-candidate answers, and the missed canonical duration on empty catalog
lookups), so the manifest now pins **zero** intended failures and all three arms
pass replay. The exact-match machinery stays in place so any regression is
caught rather than hidden, and a deliberate future finding can be re-pinned with
its exact grader set. Safety-grader failures can NEVER be excused by the
manifest: a safety failure always fails the run. The manifest is loaded and
validated like the corpus (real case ids + arms, no duplicate entries, non-empty
reasons, and never the `safety` grader) and is consulted in replay only — live
mode ignores it and keeps its advisory `--min-pass-rate`.

Live mode executes the selected arms against the real endpoint:

```bash
export AGENT_SEARCH_BASE_URL=http://your-openai-compatible-endpoint/v1
export AGENT_SEARCH_API_KEY=local-llm        # dummy accepted
export AGENT_SEARCH_MODEL=your-model
scripts/eval agent-search --mode live --arm deep_agent --update-recordings
```

The runner probes the endpoint once at live start and records redacted evidence
in the artifact header. `response_format` json_object is honored by the probed
endpoint (grammar-enforced JSON arrives in `message.content` while the model's
chain-of-thought is returned separately in `reasoning_content`, which is never
read into results or artifacts); `response_format` json_schema is ignored there.
Native tool support is endpoint- and model-dependent, so the probe records its
observed capability but does not automatically change transport. Every current
model call therefore sends `response_format` json_object with the expected schema
embedded in the prompt and temperature 0. A parse or validation failure gets up
to one bounded repair retry, only when model-call capacity remains; with one call
left, repair is disabled. The retry is re-asked with the validation error and
"return ONLY the corrected JSON object", charged against the model-call budget,
before the typed-failure path.
A bare judgments array is wrapped into its `{judgments: [...]}` envelope before
strict validation (recorded as a `coerced_envelope` provenance note). Endpoint
settings are env-only (`AGENT_SEARCH_TIMEOUT_S`, `AGENT_SEARCH_RUN_TIMEOUT_S`);
keep credentials in your shell or a secret store, never in fixtures, docs, or
artifacts.

## Flags, artifacts, and gates

Flags: `--mode`, `--arm`, `--case`, `--min-pass-rate` (default `1.0` replay,
advisory live), `--output` (JSONL, `-` for stdout), `--run-id`,
`--update-recordings`, `--record-dir`, `--limit`, and budget overrides
(`--max-tool-calls`, `--max-model-calls`, `--max-candidates-in`,
`--max-recommendations`, `--wall-clock-s`, `--max-tokens`).

The JSONL artifact is schema `omp.agent-search.eval.run.v3`: one `run` header,
one record per case × arm (result, validation report, six grader results, status
of `graded`/`skipped`/`drift`, latency, runner-owned telemetry, and safe ordered
progress events), and one `summary` with per-arm totals and p50/p95 latency.
Telemetry contains per-attempt duration/repair/status, probe duration where
available, actual tool-dispatch/finalization/validation/total timing, a validated
deterministic baseline, and final validated result timing. The optional first
partial-revision metric remains unset: current model arms only expose a final
candidate set. Future durable job/UI slices may add genuine validated enhancement
revisions rather than treating a model attempt as a partial result.
For live model arms the runner executes and validates the deterministic baseline
first; its bounded candidate IDs and evidence refs remain in `deterministicBaseline`
and the first ordered event even if the model is slow or fails.
`deterministicBaseline` is a sibling JSONL case-record field to `telemetry`, not
nested inside telemetry. The artifact never records
completion text, prompts, URLs, reasoning, or keys. Progress events use
`omp.agent-search.eval.progress.v2` and are restricted to safe baseline,
lifecycle, tool, and validated-result metadata. API keys and bearer/`sk-` values
are redacted before any line is written. The command exits
nonzero on any safety-grader failure; in replay it then exits nonzero unless the
graded failures match the pinned known-failures manifest exactly (a summary line
reports `known_failures=<n> matched`), and in live mode it exits nonzero when the
graded pass rate is below `--min-pass-rate`.

For a reproducible live benchmark, use a fixed case and output path:

```bash
scripts/eval agent-search --mode live --arm deep_agent --case plain-artist-song-official-audio \
  --max-model-calls 4 --output /tmp/agent-search-live.jsonl
```

The artifact distinguishes per-attempt model duration from actual synchronous
tool-dispatch duration. It does not normalize cold versus warm endpoint startup,
provider queueing, or model cache state; compare repeated runs on the same
endpoint configuration and inspect every model attempt rather than treating a
single total as a stable latency benchmark. Native-tool capability is probe
evidence only: `AGENT_SEARCH_TOOL_TRANSPORT=native` returns a typed unsupported
transport result until an explicitly instrumented adoption decision is made.

Package-local tests (`cd agents/candidate_assembly && uv run pytest`) cover
schema round-trips and unknown-field rejection, retrieval determinism, every
grader and validator violation class (including the duration boundary), corpus
bounds/uniqueness/pool resolution, budget enforcement, the deterministic-arm
drift check, and the full replay run.
