# Backend observability

## Local store and Collector

`deploy/observability/compose.yaml` runs a single-node OpenObserve store/UI and an
OpenTelemetry Collector. It is not the development-only LGTM bundle. Both are
self-hosted open-source images. No cloud account, cloud exporter, or paid service
is configured. Local compute and disk still have a cost.

The transport contract is OTLP/HTTP for logs, traces, and metrics. The Collector
accepts explicit SDK producers only. It does not collect stdout, scrape Docker
logs, or mount the Docker socket. The Go backend owns its safe request-completion
projection. Arbitrary legacy log strings must remain stdout-only.

The image versions and manifest digests are pinned in Compose. On 2026-11-02 the
GitHub latest stable releases were OpenObserve v1.1.2 and Collector v0.164.0. Both
images were pulled, the Collector validated its config, and all three signals
were ingested and searched locally. The integrated checker below verifies the
backend's own producer through that pipeline.

## Start your own local instance

Python 3 and Docker Compose are required. Run from the repository root. Do not
reuse a private production password for a preview.

```sh
python3 deploy/observability/bootstrap.py --env-file "$TMPDIR/soundq-observability-private/local.env"
python3 deploy/observability/stack.py --env-file "$TMPDIR/soundq-observability-private/local.env" validate
python3 deploy/observability/stack.py --env-file "$TMPDIR/soundq-observability-private/local.env" up
python3 deploy/observability/check.py --env-file "$TMPDIR/soundq-observability-private/local.env" fixtures
```

The bootstrap writes a new mode-0600 file outside the repository, refuses to
overwrite an existing file, checks port availability, and prints only its path.
The parent directory is mode 0700 when newly created. `.env.example` contains
placeholders only. For collisions, bootstrap supports `--ui-port`, `--otlp-port`,
and `--health-port`. Defaults are 15080, 14318, and 14333. Do not start a second
copy under the same Compose project while the handed-off preview is running.

The wrapper passes private values through a subprocess environment, not command
arguments or stdout. Do not run `compose config` without `--quiet`, print the env
file, dump container environments, or enable shell tracing. Docker operators can
read container environment values, so Docker daemon access remains privileged.
OpenObserve bootstrap credentials initialize an empty database. Changing an env
file is not a supported password rotation procedure for an existing database.

Default URLs are `http://127.0.0.1:15080/web/` for the UI,
`http://127.0.0.1:14318` for OTLP/HTTP, and `http://127.0.0.1:14333/` for Collector
health. The store API requires authentication. The UI HTML/login shell and health
endpoints are public on loopback. `check.py` reads credentials privately and can
query the authenticated API without exposing passwords in arguments.

Stop or remove only this project, retaining its named volumes.

```sh
python3 deploy/observability/stack.py --env-file /absolute/private/local.env status
python3 deploy/observability/stack.py --env-file /absolute/private/local.env stop
python3 deploy/observability/stack.py --env-file /absolute/private/local.env down
```

Do not use `down --volumes` unless deliberate telemetry deletion is authorized.
Stop unused previews explicitly; a persistent Serve route can outlive its origin.

## Producer identity

Set resource identity explicitly in each producer's deployment configuration.
The Collector does not add or overwrite service/environment/version/instance.
In particular, it never stamps `development` over a production producer. A
missing label remains missing and should fail the deployment's producer check.

```sh
export OTEL_SERVICE_NAME=soundq-backend
export OTEL_RESOURCE_ATTRIBUTES='deployment.environment.name=development,service.version=YOUR_SOURCE_REF,service.instance.id=YOUR_UNIQUE_PROCESS_ID'
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:14318
export OTEL_TRACES_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
export OTEL_METRICS_EXPORTER=otlp
```

The backend initializes the official Go OpenTelemetry SDK from these variables.
Exports default to `none` independently for each signal. Enable them explicitly;
setting an endpoint alone does not enable export. `OTEL_SDK_DISABLED=true`
disables every exporter. Use `OTEL_TRACES_SAMPLER=always_on` only for a bounded
local correlation test. Production should explicitly choose sampling, identity,
transport credentials, and bounded export/shutdown policy.

The request observer emits one server span, one typed `http.request.completed`
log and HTTP count/duration metrics per completed request. Response status and
bytes are observed after compression/conditional response handling. It generates
a canonical `X-Request-ID` shared by stdout, API error responses and telemetry.
It accepts W3C trace parentage, not a caller's arbitrary `X-Trace-ID`, and exports
no baggage, tracestate, raw request paths, query strings, headers, request bodies,
user IDs or exception text. Registered route templates replace IDs; unmatched
requests use `unknown`. Other legacy application logs remain local stdout-only.
This is HTTP observability, not DB query, download-worker or Android telemetry.

Supported SDK configuration follows. Unsupported explicit values fail startup
instead of silently selecting a different transport.

| Variable | Supported values/default |
| --- | --- |
| `OTEL_SERVICE_NAME` | `soundq-backend`; overrides resource `service.name` |
| `OTEL_RESOURCE_ATTRIBUTES` | Comma-separated `key=value`; environment defaults to `development`, version to the server version, instance to a process UUID |
| `OTEL_TRACES_EXPORTER`, `OTEL_LOGS_EXPORTER`, `OTEL_METRICS_EXPORTER` | `none` (default) or `otlp` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `http/protobuf` only |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Explicit HTTP(S) base; enabled signals append `/v1/traces`, `/v1/logs`, `/v1/metrics` |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT`, `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` | Optional exact per-signal URLs, including the signal path |
| `OTEL_EXPORTER_OTLP_HEADERS` | Shared `key=value` headers, with percent-encoded values supported; manage privately |
| `OTEL_TRACES_SAMPLER` | `traceidratio` (default), `always_on`, `always_off` |
| `OTEL_TRACES_SAMPLER_ARG` | Ratio 0..1, default 1 |
| `OTEL_EXPORTER_OTLP_TIMEOUT` | Milliseconds, default 3000 |
| `OTEL_BSP_SCHEDULE_DELAY` | Milliseconds, default 1000; shared trace/log batch interval |
| `OTEL_METRIC_EXPORT_INTERVAL` | Milliseconds, default 15000 |
| `SOUNDQ_OTEL_SHUTDOWN_TIMEOUT_MS` | Aggregate flush/shutdown milliseconds, default 5000 |
| `OTEL_BSP_MAX_QUEUE_SIZE` | 1..65536 records, default 2048, shared trace/log policy |
| `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` | At most queue size, default 256 |

All duration settings accept 1..60000 milliseconds. SDK retries are disabled;
the local Collector owns bounded durable retry. Parent-based sampling is
intentionally unsupported so incoming sampled flags cannot override the server's
ratio. Logs and metrics do not depend on trace sampling. Signal-specific header,
protocol and timeout overrides are not supported by this configuration API.
Telemetry overflow/outage must not block ordinary requests, and shutdown has one
aggregate deadline for all providers.

For a container on the dedicated Compose network, use `http://collector:4318`.
For a host process, use the published loopback endpoint above. A container's
`localhost` is not the host. Do not publish the Collector on a LAN address to
solve a container networking mistake.

`deployment.environment.name=production` is a filter, not authorization and not
proof of VM ingestion. The fixture checker deliberately emits synthetic
production-labelled telemetry with `telemetry.fixture=synthetic` and a
`synthetic-stack-smoke-*` instance ID. It cannot pass the actual-producer checker.
Exercise real HTTP requests through the integrated router and verify
its particular instance with `received`. Real VM instrumentation requires remote
installed-runtime and received-data evidence. This preview does not deploy to or
contact a production VM.

## Search

OpenObserve flattens OTLP resource keys differently by signal in v1.1.2.

| OTLP resource | Logs and metrics column | Traces column |
| --- | --- | --- |
| `service.name` | `service_name` | `service_name` |
| `deployment.environment.name` | `deployment_environment_name` | `service_deployment_environment_name` |
| `service.version` | `service_version` | `service_service_version` |
| `service.instance.id` | `service_instance_id` | `service_service_instance_id` |
| `telemetry.fixture` | `telemetry_fixture` | `service_telemetry_fixture` |

Logs and traces both use stream `soundq_backend`, distinguished by API `type`.
Metric streams use metric names, not the `stream-name` header. List the actual
metric streams first. Counter/histogram naming may be normalized by the store.

```sh
python3 deploy/observability/check.py --env-file /absolute/private/local.env streams --type metrics
python3 deploy/observability/check.py --env-file /absolute/private/local.env query --type logs \
  --sql "SELECT * FROM soundq_backend WHERE deployment_environment_name = 'development' ORDER BY _timestamp DESC"
python3 deploy/observability/check.py --env-file /absolute/private/local.env query --type traces \
  --sql "SELECT * FROM soundq_backend WHERE service_deployment_environment_name = 'production' ORDER BY _timestamp DESC"
python3 deploy/observability/check.py --env-file /absolute/private/local.env query --type metrics \
  --sql 'SELECT * FROM soundq_observability_smoke_total'
python3 deploy/observability/check.py --env-file /absolute/private/local.env query --type logs \
  --sql "SELECT * FROM soundq_backend WHERE trace_id = 'YOUR_ACTUAL_TRACE_ID'"
```

The authenticated Search API is `POST /api/default/_search?type=logs|traces|metrics`.
The request has a `query` object with `sql`, microsecond `start_time` and
`end_time`, `from`, and `size`. The helper defaults to the past 30 minutes and
100 rows. It does not claim exhaustive results beyond that cap. Filter by the
specific instance and request/trace when inspecting E2E evidence.

## Verify the integrated backend

The finite checker below executes the real Go API router, exports all three
signals through the Collector, and searches OpenObserve for the exact emitted
identities. It verifies stdout/log/span correlation, HTTP count and duration
metrics, environment separation and absence of a privacy canary supplied in
paths, query strings, headers and bodies.

```sh
python3 deploy/observability/backend_smoke.py \
  --env-file /absolute/private/local.env \
  --output "$TMPDIR/soundq-backend-telemetry-e2e"
```

The output directory must not already exist. This checker uses DB-free synthetic
requests through production router code. Its development and production-labelled
cohorts are both local test traffic, not evidence that the VM was deployed. The
receipt says `productionVMInstrumented: false` explicitly.

Read-only actual-producer acceptance, after the parent exercises its HTTP server
and flushes the SDK, is below. Repeat `--metric-stream` for each required metric
stream returned by the store. This fails on no received rows, missing version,
synthetic fixture rows, or no exact log/span trace+span pair. It does not by
itself check privacy canaries. The backend integration E2E owns that assertion.

```sh
python3 deploy/observability/check.py --env-file /absolute/private/local.env received \
  --environment development --instance YOUR_UNIQUE_PROCESS_ID \
  --metric-stream YOUR_RECEIVED_COUNT_STREAM --metric-stream YOUR_RECEIVED_DURATION_STREAM
```

## Storage and failure boundaries

- OpenObserve persists `/data` in `soundq-observability-preview_openobserve_data`.
  The Collector queue uses the separate
  `soundq-observability-preview_collector_queue` volume.
- Global OpenObserve retention defaults to seven days, configurable with
  `OBS_RETENTION_DAYS`. v1.1.2 rejects positive retention below three days. Do not
  set zero, which disables retention. Stream-specific retention settings can
  override the global policy, so audit them before using this as a shared store.
  Newly created streams inherit the global policy. Compactor deletion is
  asynchronous, with a configured ten-minute pending-file deletion delay. This is
  an age policy, not an instantaneous deletion deadline or disk quota. Seven-day
  deletion has not been time-travel tested in this preview.
- The Collector has a 384 MiB memory limiter inside a 512 MiB container, a 4 MiB
  receiver body limit, bounded batches, and a persistent queue per signal.
  Each signal queue accepts at most 16 MiB of serialized data. Each bbolt file is
  capped at 64 MiB; metadata/allocation and compaction need extra disk. Three
  files plus transient compaction do not constitute a filesystem quota. Retries
  stop after 120 seconds per batch. Overflow, permanent ingest errors, exhausted
  retries, and full disk may drop telemetry. SDK queues and shutdown must also be
  bounded. The batch processor can lose its unpersisted one-second batch on a
  crash. This is not exactly-once storage.
- The owned store-outage/Collector-restart probe successfully recovered queued
  logs, spans, and metrics through the actual Search API. Volumes also survived
  store container recreation. This does not prove disaster recovery.
- Docker's own service logs rotate at 2 x 10 MiB per service; they are not
  ingested. Store memory is limited to 2 GiB. Monitor host disk capacity and
  provision backups for durable deployments. Named volumes share the host disk
  and cannot bound total data bytes by themselves.

## Remote or production deployment

Do not change loopback port bindings to `0.0.0.0`. This unauthenticated Collector
receiver is suitable only for a trusted local host and its isolated Docker
network. Other local processes, or containers admitted to that network, can
submit telemetry and spoof labels. CORS is not an OTLP authentication boundary.

For a tailnet/VM deployment, prefer a host-local Collector on each producer with
loopback-only SDK export. Its upstream traffic must use TLS with certificate
verification and an authenticated ingestion endpoint, such as a Collector with
mTLS or an authenticating TLS reverse proxy restricted to OTLP routes. Restrict
peer access with tailnet ACLs and firewall policy. A tailnet hostname or source
IP alone is not application authentication. Never forward a public/tailnet TCP
port straight to this unauthenticated receiver. TLS termination must not leave
an untrusted network hop to the receiver. Keep store credentials on the trusted
Collector side, not in clients or request headers logged by the application.

Use separate production and development store instances, volumes, secrets, and
receiver trust domains when access/data isolation matters. Labels and filters
are not RBAC, and this local preview intentionally demonstrates two identities
in the same `default` organization. The preview uses throwaway bootstrap root
credentials only for an empty local store. Before shared use, provision a
supported dedicated ingestion identity/token and separate operator access.
Protect the store UI with TLS and authenticated access. Keep Docker/admin access
restricted. No production ingress, ACL, password rotation, or remote deployment
is provided or claimed by this local Compose recipe.

## Official references

- [OpenObserve v1.1.2 release](https://github.com/openobserve/openobserve/releases/tag/v1.1.2)
- [Collector v0.164.0 release](https://github.com/open-telemetry/opentelemetry-collector-releases/releases/tag/v0.164.0)
- [Unified OTLP ingestion](https://openobserve.ai/docs/ingestion/logs/otlp/)
- [Search API](https://openobserve.ai/docs/reference/api/search/search/)
- [Environment reference](https://openobserve.ai/docs/administration/configuration/environment-variables/)
- [Versioned OpenObserve config source](https://github.com/openobserve/openobserve/blob/v1.1.2/src/config/src/config.rs)
- [Versioned OTLP HTTP exporter](https://github.com/open-telemetry/opentelemetry-collector/blob/v0.164.0/exporter/otlphttpexporter/README.md)
- [Versioned persistent queue](https://github.com/open-telemetry/opentelemetry-collector/blob/v0.164.0/exporter/exporterhelper/README.md)
- [Versioned file storage extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.164.0/extension/storage/filestorage/README.md)

Current documentation lists some retention variables not present in the pinned
v1.1.2 config source. This recipe does not set unsupported variables. Recheck
versioned config and rerun validation/ingestion before upgrading images.
