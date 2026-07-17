# candidate_assembly

Bounded, evals-first **candidate-assembly** orchestrator prototype for OMP
natural-language song search (issue #265). An arm assembles a sorted, structured
list of source candidates by calling read-only tools; deterministic code then
verifies the result. This package is self-contained and does not modify the
shipped deterministic + optional-Ollama discovery path.

See `../../docs/AI_EVALS.md` for the full contract. This README is the quickstart.

## Layout

```
src/candidate_assembly/
schemas.py        # pydantic v2 contract — single source of truth
budgets.py        # Budget dataclass + BudgetExceeded
fixture_tools.py  # read-only tools + deterministic retrieval + ToolBox enforcement
gateway_tools.py  # explicit Go-owned HTTP gateway adapter (not eval default)
tool_transport.py # fixture/gateway read-only transport protocol + safe observations
  orchestrator.py   # framework-neutral CandidateAssembler protocol + arm registry
  validate.py       # deterministic post-agent verifier (the guard)
  go_ranker.py      # bridge to the real Go sourcequality-rank scorer
  model_client.py   # env-only endpoint config + tool-support probe (live only)
  arms/             # deterministic, direct_judge, deep_agent
  evalrunner/       # corpus, graders, runner, cli
  fixtures/         # corpus.v1.json, pools/, recorded/
tests/              # pytest, all network-free
```

## Run

From the repo root (preferred — wires the Go scorer and stays network-free):

```bash
scripts/eval agent-search --mode replay
```

Or directly in the package:

```bash
uv sync
uv run pytest -q
uv run python -m candidate_assembly.evalrunner.cli --mode replay
```

`uv sync` installs only the light default dependencies (pydantic + pytest). The
agent stack (deepagents / langchain) is an optional `live` extra used only by the
model arms:

```bash
uv sync --extra live
```

## Modes

- **replay** (default, CI gate): network-free. The `deterministic` arm executes
  live (fixture pool + real Go scorer) and is diffed against its recording;
  drift fails. The `direct_judge` and `deep_agent` arms are replayed from
  recordings under `fixtures/recorded/<arm>/<case-id>.json`, or SKIPPED with
  explicit counting when a recording is absent.

### Pinned known-failures manifest

Replay is an EXACT-match gate against `fixtures/known_failures.v1.json`
(`schemaVersion: omp.agent-search.eval.known-failures.v1`): each entry pins a
`(caseId, arm)`, the exact `graders` it should fail, and a one-line `reason`.
Replay exits 0 only when the actual failing set matches the manifest exactly —
any unexpected failure, any pinned-but-now-passing entry (stale manifest), or any
failing-grader-set mismatch fails the gate and prints the deltas. A summary line
reports `known_failures=<n> matched` so the green gate stays self-explanatory.
Safety-grader failures can never be excused by the manifest, and live mode
ignores it (its `--min-pass-rate` stays advisory). The
`agent-search-system-prompt-v2` rewrite closed every `deep_agent` gap the issue
#265 spike surfaced, so the manifest currently pins **zero** intended failures
and all three arms pass replay — the exact-match machinery stays so any
regression is caught, and a deliberate future finding can be re-pinned with its
exact grader set.
- **live**: executes the selected arms against the real OpenAI-compatible
  endpoint. Env-only: `AGENT_SEARCH_BASE_URL`, `AGENT_SEARCH_API_KEY`,
  `AGENT_SEARCH_MODEL`, `AGENT_SEARCH_TIMEOUT_S`, `AGENT_SEARCH_RUN_TIMEOUT_S`.
  Pass `--update-recordings` to refresh recordings. Never commit credentials.
  `scripts/eval agent-search --mode live` runs `uv run --extra live` so the
  agent stack is present; replay stays on the light default env.

## Go-owned agent-tools gateway (future worker opt-in)

`GatewayToolBox` is an explicit construction seam for a future asynchronous
candidate agent. It is **not** selected by `scripts/eval agent-search`, fixture
replay, or synchronous discovery. Existing fixture `ToolBox` remains the
network-free default and the replay recordings remain byte-stable.

The Python side has no provider or Firecrawl client. It can only POST to the
configured Go gateway base URL plus `/internal/agent-tools/v1`:

- `POST /capabilities` uses `X-OMP-Agent-Service-Token` and returns an opaque,
  expiring capability.
- `POST /search-sources`, `/search-catalog`, `/inspect-source-metadata`, and
  `/extract-web` use that capability as `Authorization: Bearer ...`.
- The read-only tool surface is `search_sources`, `search_catalog`,
  `inspect_source_metadata`, and `extract_web(evidence_ref)`; it has no queue,
  download, write, or URL-fetch argument.

All settings are environment-only and are required together:

```bash
export AGENT_TOOL_GATEWAY_URL=https://gateway-host.example
export AGENT_TOOL_GATEWAY_SERVICE_TOKEN=from-a-secret-store
export AGENT_TOOL_GATEWAY_TIMEOUT_S=5
# Local development only; omit for HTTPS.
# export AGENT_TOOL_GATEWAY_ALLOW_INSECURE_HTTP=true
```

`AGENT_TOOL_GATEWAY_TIMEOUT_S` must be finite and strictly positive. The base
URL must use HTTPS without embedded credentials, query, or fragment. Plain HTTP
is rejected even for direct `GatewayConfig` construction unless
`allow_insecure_http=True`; the env factory accepts only the exact lowercase
`AGENT_TOOL_GATEWAY_ALLOW_INSECURE_HTTP=true` opt-in for local development.
Redirects are never followed, so neither the service token nor an issued bearer
capability can be forwarded to a redirect target. The factory is deliberately
explicit:

```python
from candidate_assembly.budgets import Budget
from candidate_assembly.gateway_tools import build_gateway_toolbox_from_env

toolbox = build_gateway_toolbox_from_env(Budget.default())
```

Gateway wire responses are strict Pydantic envelopes; bounded safe metadata is
validated then projected out of the model-facing candidate result. Model-facing
candidates, catalog entries, metadata attributes, and bounded evidence
structurally reject URL fields, arbitrary metadata, URL-like text, and
secret-shaped text. Candidate and evidence refs are opaque allowlisted IDs;
metadata and web extraction reject unknown refs locally before a network call.
Wire and model-facing evidence share one 4 KiB UTF-8 ceiling. Strict, bounded Go
error envelopes preserve only allowlisted backend codes; server messages and
unknown codes are never copied into errors or traces.
Traces contain only timing, result counts, and argument digests. Configurations,
errors, artifacts, and progress events never include the base URL, service token,
capability, source URL, or response body.

## Endpoint behavior

Probed on the target llama-swap endpoint and relied on by the model arms:
`response_format` json_object is honored — grammar-enforced JSON arrives in
`message.content`, and the model's chain-of-thought is returned separately in
`reasoning_content`, which is never read into results, recordings, or artifacts.
`response_format` json_schema is silently ignored (prose comes back), and native
tool-calling is unsupported. So every model call sends json_object with the
expected schema embedded in the prompt, parses `message.content` defensively, and
takes one bounded repair retry on a parse/validation failure before failing typed.

## Budgets (defaults)

`max_tool_calls=8`, `max_model_calls=10`, `recursion_limit=12`,
`max_candidates_in=64`, `max_recommendations=10`, `wall_clock_s=180`,
`max_request_bytes=48KiB`, `max_response_bytes=64KiB`,
`max_tokens_per_completion=4096`. All overridable via CLI flags; enforced in the
tool layer, and every result records the amount spent.

## Durable worker command

`candidate-assembly-worker` (or `python -m candidate_assembly.worker_runner`)
is the production-shaped JSONL subprocess boundary for the Go durable-job
runner. It reads exactly one `omp.agent-search.worker.request.v1` object from
stdin and writes only versioned JSONL records to stdout:

1. A validated `omp.agent-search.worker.revision.v1` for `direct_judge`, when
   enabled and valid.
2. A validated revision for `deep_agent`, when enabled and valid.
3. One `omp.agent-search.worker.terminal.v1` outcome record.

The request contains `jobId`, `runId`, query, limit, explicit stage/budget
settings, and bounded URL-free candidate/catalog/metadata projections. It
rejects extra fields, duplicate candidate IDs, URLs, secrets, provider blobs,
and user credentials. Candidate projections carry server-owned deterministic
`sourceQuality`; the direct stage may only make a bounded score adjustment and
the DeepAgent stage can inspect only the same immutable snapshot.

Live inference is disabled unless the process has
`OMP_CANDIDATE_WORKER_LIVE=1` plus the existing `AGENT_SEARCH_*` model
configuration. Otherwise the command exits `0` after a typed `unavailable`
terminal record. Go should pass the request as one stdin line, consume stdout
line-by-line, treat any non-JSON stdout as a runner failure, and terminate the
process with `SIGTERM` for cancellation. One request-level ledger debits direct
and DeepAgent together: model/tool calls, wall time (from the start of stdin
read), and aggregate tool request/response bytes never reset for stage two.
Timing records distinguish process startup-to-request-acceptance (after strict
stdin validation), direct first-revision latency, final latency, per-attempt
model durations, and tool-call totals.
