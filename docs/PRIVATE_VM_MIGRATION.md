# Private VM migration preparation — cutover HELD

No new production hostname, address, API prefix, health/login path, media origin,
or published port is selected here. Dedicated VM enrollment, restore and route
verification belong to **Anko**. This change is preparation, not deployment.
Do not run the legacy devbox recipes as production instructions.

## Intent and risk seams

Move Sound Q's consumers together after Anko supplies verified reachability and
restore evidence. Keep ordinary local development working. Do not infer a
frontend login URL, health route or S3 public endpoint from an API base.
The risky boundaries are authenticated destination changes, reverse-proxy path
mapping, presigned media, CORS, restored database migrations and reboot recovery.
No secrets, restored records or live VM services are needed for code gates.

## Configuration contracts

| Consumer | Input | Meaning |
| --- | --- | --- |
| Flutter | `--dart-define=OMP_API_BASE_URL=...` | Complete HTTP(S) API base including verified prefix/port; immutable per build. `ApiEndpoint` is shared by `ApiClient`, Settings and token stores. Unconfigured **local** runs still use `http://localhost:8080/api/v1`. |
| Flutter dogfood | `OMP_API_BASE_URL`, `OMP_SOURCE_REF`, `OMP_BUILD_ID` | Dogfood refuses a missing/invalid API value before Flutter/ADB/evidence creation. Existing source/build defaults remain for local convenience; migration preflight requires explicit identities. |
| Extension webpack | `OMP_API_BASE_URL`, `OMP_HEALTH_URL`, `OMP_WEB_LOGIN_URL`, optional `OMP_WS_URL` | Complete explicit bundle. Setting any endpoint requires all three HTTP(S) inputs. No mutable stored server setting. Health/login are independent, not derived paths. Optional WS input is a full WS(S) URL. |
| Backend storage | `MINIO_ENDPOINT`, `MINIO_PUBLIC_ENDPOINT`, `MINIO_USE_SSL`, credentials, bucket, region | Internal S3 connection versus browser/device-reachable signing origin. Backend issues absolute presigned URLs. There is **no client media-base override**. Public MinIO endpoint supports an origin/host:port, **not a path prefix**. |
| Backend browser access | `OMP_CORS_ALLOWED_ORIGINS` (legacy alias `CORS_ALLOWED_ORIGINS`) | Comma-separated exact frontend origins; prefixes are not origins. Main Compose forwards `OMP_...` explicitly; empty denies browser origins rather than invoking router local defaults. |
| Main Compose | `OMP_BIND_ADDRESS`, existing `SERVER_PORT`, `POSTGRES_PORT`, `REDIS_PORT`, `MINIO_PORT`, `MINIO_CONSOLE_PORT`, `HTTP_PORT`, `HTTPS_PORT` | Published bindings now default to loopback. This is not tailnet enrollment/firewalling. Anko must verify the chosen proxy/bind arrangement before any access change. Internal service ports remain unchanged. |

HTTP config rejects credentials, queries, fragments, unsupported schemes and
ambiguous paths (including doubled separators, dot traversal and encoded
separators). The API base must end in `/api/v1`, optionally preceded by a proxy
prefix; an origin alone, another version or a resource path is rejected. API
trailing slash is removed once; prefixes and nondefault ports
are retained. Health/login paths retain trailing slash semantics. Extension
callers still pass `/api/v1/...`; the adapter maps that contract onto the
configured API base once, including refresh/retry.

Manifest permissions are generated at build time from the configured HTTP/WS
hosts plus the existing YouTube/SoundCloud providers. No `<all_urls>`, broad
Sound Q wildcard or stale local host remains in a custom build. Browser match
patterns do not restrict ports, so permissions are scheme + exact hostname;
actual requests retain the configured ports. A rebuilt extension requires
reload/reinstallation and permission review.

The extension `WebSocketManager` remains **uninstantiated**. The optional full
`OMP_WS_URL` is validated/prepared, not live progress wiring. Its existing manager
still accepts a base and appends `/ws/progress`; do not pass the full URL into
that legacy interface without a separately tested integration.

### Ordinary local-browser development (not migration approval)

Main Compose deliberately defaults to **no allowed browser origins**. For a
local Flutter web client on port 3000, explicitly opt into those exact origins:

```sh
export OMP_CORS_ALLOWED_ORIGINS='http://localhost:3000,http://127.0.0.1:3000'
docker compose --env-file /dev/null -f docker-compose.yml config --quiet
# Only when intentionally starting your disposable local stack (not this task):
# docker compose --env-file /dev/null -f docker-compose.yml up -d
# cd client && flutter run -d chrome --web-port 3000
```

Use the actual frontend origin if you choose a different local port; do not use
wildcards or copy these origins into an Anko record. This explicit local
override does not weaken the empty production default, change bindings, or
configure media. Rendering config alone starts no services and reads no `.env`.

### Session compatibility

Changing destinations must not send the previous endpoint's credentials to the
new host. Extension tokens are bound to the API base. Unbound legacy extension
tokens are accepted only at the unchanged local default; custom bundles require
fresh sign-in. Flutter secure/native and web-session keys are now scoped to the
immutable API base. Unbound Flutter credentials are deliberately not adopted:
**the first upgrade requires sign-in**, including biometric unlock setup again.
Web still uses sessionStorage and clears legacy durable token keys. No account,
library or media data is migrated by these client storage changes.

## Inventory of existing endpoint assumptions

| Location | Existing assumption / required disposition |
| --- | --- |
| `AGENTS.md`, `docs/ANDROID_PR_ARTIFACTS.md` | `dev.fish-rattlesnake.ts.net:8080` examples are legacy local/tailnet dogfood, not VM production authority. AGENTS now labels them. Leave historical docs scoped, do not globally replace names. |
| `scripts/dogfood-android` | Removed automatic old-devbox API fallback; an explicit valid API URL is mandatory. Node is required for offline URL validation, in addition to Flutter/ADB when invoked. |
| `scripts/tailnet-staging.sh`, `docs/TAILNET_STAGING.md` | Derive legacy host/root/API/media/health URLs from local staging inputs; not an arbitrary-prefix VM deployment tool. Leave inactive for migration. |
| `scripts/dev`, `scripts/local-low-memory.sh`, `scripts/smoke`, `scripts/local-e2e-smoke.py` | Local defaults remain; smoke/root helpers append documented local paths. Use only explicit reviewed overrides if later verifying a proxy layout. |
| `backend/cmd/mix-qa-seed/main.go` | Still has old dev media default on port 9000. It is a data-writing QA seed, **not migration verification**. Do not run against restored data. |
| `backend/cmd/local-playback-smoke/main.go` | Local media/API fixture defaults, not private VM endpoint discovery. |
| `extension/src/` | API, refresh, health and popup login now consume the immutable bundle; unused storage API setters/getters and disconnected API default retired. |
| `docker-compose.yml` | Now forwards public signing origin and CORS; bucket init uses `anonymous set none`, fails on errors and defaults published ports to loopback. Rendering config does not reset an existing bucket policy; operator action is held. Still contains local default passwords/JWT placeholder: **not a production-ready secrets manifest**. |
| `docker-compose.local-low-memory.yml`, `deploy/README.md`, `scripts/deploy.sh` | Separate local/deploy environment and public media default. Low-memory stack already requests private bucket but has different binding/CORS/init semantics; it is **not hardened by main Compose changes**. Deployment choice is an Anko gate, not assumed here. Never source a real `.env` for code-only tests. |
| `nginx/nginx.conf` | Existing proxy routing/TLS config is not evidence for a new API prefix, frontend hosting or media route. Review exact mappings with Anko. |
| `.github/workflows/nightly-apk.yml`, README nightly section | Workflow consumes repository variable `OMP_NIGHTLY_API_BASE_URL`; fallback is the Android emulator local URL. Parent verified current variable as `http://dev.fish-rattlesnake.ts.net:8080/api/v1`. **Variable and workflow activation are unchanged; cutover HELD.** |

### Auth is JWT, not OAuth

Backend routes register/login/refresh/logout under `/api/v1/auth/...` and issue
JWTs. There is no shipped OAuth redirect/client-id/client-secret configuration
to transplant. The independent frontend login page is not an OAuth callback and
opening it alone does not prove extension token handoff. Audit the actual
`SET_AUTH_TOKEN` flow in browser dogfood; never treat a successful tab open as
successful authentication. Preserve or intentionally rotate `JWT_SECRET` under
Anko's restore/session plan; do not copy secret values into evidence.

## Anko verification and cutover gates

All remain **pending** until Anko provides actual evidence; test fixtures are
not acknowledgments. Do not enroll Tailscale, restore, reboot, deploy, publish
ports, activate workflows or change repository variables from this task.

1. **VM enrollment (`vmEnrollment`)**: dedicated VM identity/ownership, private
   tailnet enrollment, ACLs, DNS/device resolution, host firewall and chosen
   published bindings. Verify from intended browser/mobile devices, not only
   inside containers. No assumed hostname or port.
2. **Restore (`restore`)**: backup provenance/checksum and timestamps, PostgreSQL
   schema/data/users/playlists/queue census and protected environment marker;
   object bucket counts/keys and sampled integrity; credentials/ownership and
   private bucket policy. Backend startup runs idempotent schema migrations,
   which may modify restored rows. Snapshot and rollback before first startup;
   no QA seed/truncating test against protected data.
3. **Routes (`apiRoutes`)**: exact API base (prefix + port), health URL and
   separate web login URL, TLS/proxy rewrite behavior, login + library + queue
   + analysis requests and refresh retry. Local `/api/v1`, `/health` and WS route
   contracts do not prove the external mapping. Confirm Settings/build identity
   and extension custom manifest/bundle contain no stale devbox destinations.
4. **JWT (`jwtAuth`)**: login, refresh rotation/coalescing, logout, expired and
   rejected token behavior; reauthentication after endpoint changes. Verify
   extension handoff independently; do not invent OAuth configuration.
5. **Media (`media`)**: verified `MINIO_PUBLIC_ENDPOINT` origin (no prefix),
   absolute presigned host/scheme/port/expiry; stream, cover, waveform/artifacts,
   seek/range on browser and device; anonymous object reads denied. Never log
   presigned query strings. Review MinIO browser CORS separately if needed.
6. **CORS (`cors`)**: exact frontend origins and extension requests/preflight,
   unauthorized origins denied; no wildcard credential policy or mixed content.
   CORS is not access control for non-browser callers.
7. **Reboot (`reboot`)**: approved reboot/startup exercise, durable mounts,
   service health/order, private bucket policy, DNS/tailnet rejoin, restore census,
   login, library and media/range checks repeated after reboot.
8. **Rollback (`rollback`)**: snapshot/backup retention, tested isolated restore,
   old/new writer ownership (never concurrent), rollback endpoint/build artifact
   and session policy, explicit owner and go/no-go acknowledgment.

After these, request a separate human-approved cutover. Updating
`OMP_NIGHTLY_API_BASE_URL`, enabling any migration/deployment workflow and
rebuilding/distributing clients are distinct actions. This preflight cannot
authorize or execute them and always records `cutover: HELD`.

## Offline preflight / build preparation

`scripts/private-vm-preflight` only reads a manually supplied, non-secret Anko
verification JSON and writes local evidence. It makes no network calls and
cannot independently authenticate the person named `approvedBy` or verify their
claims. Require the real review/evidence reference, never reuse a test fixture.

Record shape (deliberately **no runnable endpoint values**):

```text
approvedBy: "Anko"
verificationRef: reference to reviewed enrollment/restore/route/reboot evidence
inputs:
  OMP_API_BASE_URL: complete verified API base
  OMP_HEALTH_URL: complete verified health URL
  OMP_WEB_LOGIN_URL: complete verified frontend login URL
  OMP_WS_URL: optional complete verified WS(S) URL (omit if unused)
  MINIO_PUBLIC_ENDPOINT: verified media signing origin, no prefix
  OMP_CORS_ALLOWED_ORIGINS: JSON array of exact verified frontend origins
  OMP_SOURCE_REF: exact full lowercase 40-character Git commit SHA
  OMP_BUILD_ID: explicit build identity
checks:
  vmEnrollment, restore, apiRoutes, jwtAuth, media, cors, reboot, rollback: true
```

Offline command, once a real reviewed record exists:

```sh
scripts/private-vm-preflight --opt-in \
  --anko-verification "$ANKO_VERIFICATION_JSON" --evidence "$MIGRATION_EVIDENCE_JSON"
```

Choose a **fresh** evidence path under the agent scratch directory, not a live
stack. Both commands exclusively create evidence: they refuse existing files,
including the input record, rather than overwriting it. A failed rerun does not
refresh an old passing receipt; existing evidence is not current-run approval.
Preflight fails without opt-in, complete URLs/identities and every acknowledgment.
It does **not** build or deploy.

After a separate approved **artifact-only** build request, use the enforced
migration entrypoint, not hand-copied environment variables:

```sh
scripts/private-vm-build --opt-in \
  --anko-verification "$ANKO_VERIFICATION_JSON" \
  --evidence "$FRESH_BUILD_PREFLIGHT_JSON" --target all
```

Targets are `client` (arm64 debug APK), `client-web`, `extension`, or `all`.
The existing record and receipt are unversioned JSON objects (no `schemaVersion`
field). `OMP_SOURCE_REF` accepts only the literal full lowercase SHA-1 commit
identifier: no branch/tag names, abbreviated SHAs, `branch@sha`, uppercase,
surrounding whitespace or SHA-256 identifiers. Tokens are rejected, not repaired.
Standalone preflight validates this format but does not verify a checkout.

The entrypoint runs the same offline preflight validator, reads one reviewed
record snapshot, verifies that the literal source SHA equals its own checkout's
`HEAD` and rejects staged, unstaged or untracked source before creating a receipt
or invoking build tools. Ignored build outputs/dependencies do not constitute
source approval; the extension always runs `npm ci`, even if `node_modules`
already exists, before `npm run build`. Keep the checkout unchanged throughout
the build, and place approval/receipt files outside its source tree. The build
adds `source: {commit, tree, clean: true}` to the existing receipt; this records
the local Git check, not operator authentication or live route verification.
It then exclusively writes a **preflight-only** receipt and invokes
Flutter/npm. It passes the reviewed API/source/build identities as Flutter
`--dart-define` arguments and the exact reviewed HTTP/optional WS bundle to
webpack. Shell endpoint/identity values cannot replace the record; additional
or duplicate arguments are rejected. No media-base override is passed to a
client: media origin and CORS are validated backend evidence only. Build
artifacts remain local; **cutover and distribution stay HELD**, even on success.
No install, publish, deployment, live endpoint probe or repository-variable
change is provided. A preflight receipt alone never claims build success.

Ordinary `scripts/build`, direct Flutter/npm commands and
`scripts/dogfood-android` remain local/dev/dogfood tools, including custom test
fixtures; **none produce production-approved migration artifacts**. Shell
`OMP_API_BASE_URL` alone is not a Dart compile define. Use this enforced
entrypoint for any approved migration build, then request a separate human
cutover/distribution decision. Synthetic fixture tests use stub Flutter/npm,
not a replacement endpoint build, and claim no install/device/live-media result.

## Executable checks

- `scripts/test extension`: URL/bundle/manifest and custom-prefix request +
  refresh/retry/health + token binding regressions, existing auth/brand gates.
- `scripts/test private-vm`: fail-closed preflight and migration-build binding
  (stub Flutter/npm only), exclusive evidence, dogfood boundary and main Compose
  rendering/local CORS override (`--env-file /dev/null`, no services started).
- Flutter endpoint/Settings tests with a non-routable custom prefix + port;
  native token scoping and Chrome web-session token tests.
- `scripts/test backend`: storage/public signing endpoint tests plus backend
  suite; integration tests still require isolated test infrastructure.
- `scripts/test client`, component lint/build gates and `scripts/agentic-cycle`
  evidence. A passing code gate is not enrollment/restore/reboot evidence.
