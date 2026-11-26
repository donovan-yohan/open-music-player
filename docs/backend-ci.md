# Backend CI test lanes

`Backend (Go)` is the only required backend check. It fails unless the test
matrix, backend lint (repository format/vet and pinned golangci-lint), and
build/replay jobs all succeed, and all test artifacts validate. Codecov delivery
remains best-effort; the merged atomic profile itself is a required artifact.

The test matrix uses the Go version in `backend/go.mod`. It discovers the
module's `go list -race ./...` inventory and gives each package one owner. API, DB,
MusicBrainz and the composition/integration packages have explicit owners; new
packages go to `remaining`. Jobs with multiple packages run them serially to
avoid racing fixture migrations, truncation and Redis writes.

The API package has four test lanes: the measured weekly export ceiling case,
the rest of `TestWeekly*`, playlist/mix/manual-sync tests, and everything else.
Each lane enumerates the pinned,
race-instrumented API test binary, selects exact top-level names, and compares
observed terminals against that selection. New tests, examples and fuzz seeds
are included; benchmarks are still not run by the normal test gate. The join
requires the same inventory from every API lane and sums the atomic counters
only for identical ranges and statement counts. Non-API ranges are disjoint and
are copied unchanged. Every package whose Go summary reports coverable statements
must contribute a profile fragment, even at zero percent coverage. Missing,
empty, foreign, duplicated or stale shard receipts fail the required check.

Each test lane launches fresh PostgreSQL 15 and Redis 7 containers on
Docker-assigned loopback ports. It validates PostgreSQL database/role/comment
and unprotected marker, checks a Redis ownership token through the host
binding, and removes only its own containers and volumes. It does not consume
caller-supplied database, cache or provider settings. Weekly, Radar and private
fence have separate database credentials and strict fixture formats; normal,
Connect and Jam use explicit test databases. Checks demand named fixture tests
and protected-marker refusal subtests pass, not just package success. Jam and
Connect provision newly generated databases with the canonical startup schema;
their fixture role needs `CREATEDB`. Browser/device/optional object-store or
restart qualification inputs are not synthesized by this job.

Local reproduction requires the pinned Go toolchain with race detector support
(including a Go-compatible C compiler on Linux), Python 3.10 or later, FFmpeg,
and a local Docker daemon with no `DOCKER_HOST`/`DOCKER_CONTEXT` override:

```sh
# Set RUN_ROOT to an existing, empty directory you own outside the checkout.
set -e
mkdir "$RUN_ROOT/shards"
python3 -B scripts/test_ci_backend.py -v
python3 -B scripts/test_ci_backend_fixtures.py -v
for shard in api api-playlists api-weekly api-weekly-ceiling database provider application remaining; do
  python3 -B scripts/ci_backend.py run "$shard" "$RUN_ROOT/shards/backend-go-$shard"
done
python3 -B scripts/ci_backend.py merge "$RUN_ROOT/shards" "$RUN_ROOT/coverage.out" "$(git rev-parse HEAD)"
```

`scripts/test backend` remains the unsharded developer command. If you supply
fixtures for the Jam and Connect integration tests, their PostgreSQL URLs must
point to explicitly disposable, unprotected loopback databases, and the roles
must have `CREATEDB` for their temporary databases. Do not use a shared or
protected database. Use the shard runner above if you need it to provision and
retire these fixtures for you.

Measure the critical path from workflow dispatch through the required join,
including Docker pulls, FFmpeg and Go setup, and artifact transfer; the sum of
individual package times or a warm local run is not hosted timing evidence.
