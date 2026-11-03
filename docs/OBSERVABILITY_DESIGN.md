# Backend observability implementation

## Outcome

Search backend request logs, traces, and HTTP metrics by `deployment.environment.name`, with one canonical request ID and real W3C trace/span correlation. No phone USB connection is required. Backend telemetry cannot diagnose a direct signed-media fetch or native decoder without a separate client diagnostic producer.

## Chosen shape

Use the Go OpenTelemetry SDK with bounded OTLP/HTTP export. Retain JSON stdout logging, add resource identity and actual span correlation, and export only allowlisted HTTP completion events through a logger observer. Do not forward arbitrary legacy messages, errors, payloads, headers, queries, user identifiers, or signed URLs. Preserve existing business Prometheus metrics; instrument HTTP request count/duration through OTel with route-template labels.

Use a single-node OpenObserve store/UI and Collector locally. The collector accepts OTLP from explicitly configured producers and forwards to the authenticated store. It does not scrape arbitrary Docker logs or mount the Docker socket. Pin image versions. Bind local ports to loopback, persist data, and document secure tailnet deployment and retention. Environment labels are filters, not access isolation.

SDK-first with a strict event projection was selected over shipping all stdout through a collector. Existing logger redaction is not a safe export boundary. A two-service store/collector avoids treating the development-only LGTM bundle as production infrastructure.

## Public seam

`observability.ConfigFromEnv` resolves service identity, environment, exporter mode, OTLP transport, sampling and bounded timeouts. `observability.New` returns a runtime with `HTTP(http.Handler) http.Handler`, a logger observer, and bounded `Shutdown(context.Context) error`. Exact names may follow repository conventions, but the runtime owns providers and the composition root owns its lifetime. Disabled export remains a functioning ordinary backend.

One shared request observation owns request ID, span, route template, status, bytes and duration. No raw path/query telemetry. Unknown routes use a fixed label. Legacy `X-Trace-ID` is not trusted as an actual trace ID. Only W3C trace context is extracted, not baggage. Server-controlled sampling prevents incoming sampled flags from bypassing configured limits.

## Ownership and sequence

The Go implementation owner handles backend-only code and module dependencies. The infrastructure owner handles `deploy/observability/` and operator documentation in a separate worktree. Ebi integrates, reviews, executes the combined path, and owns production-access discovery. There is no concurrent shared file ownership.

Prerequisites are existing middleware/route inspection and a clean isolated candidate. Parallel units are Go telemetry and the independently runnable collector/store stack. Integration consumes the standard OTLP/HTTP protocol, not unfinished private APIs.

## Acceptance

- Real HTTP requests traverse the actual router and produce correlated logs, spans and metrics in the searchable store.
- Development and a clearly synthetic production-labelled producer are distinguishable; synthetic labels do not prove VM instrumentation.
- Privacy canaries in URL query, headers and bodies do not reach telemetry.
- Disabled mode, exporter outage, bounded shutdown and actual streaming/WebSocket writer behavior are checked.
- Build, focused/race tests and repository-required affected backend gates run with actual exits retained.
- Production is not reported instrumented until installed runtime and remote ingestion are read back. Unknown SSH host identity is not bypassed.
