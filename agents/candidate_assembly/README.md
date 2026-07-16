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
