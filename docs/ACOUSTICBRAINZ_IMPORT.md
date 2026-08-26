# AcousticBrainz Import (issue #390)

The `acousticbrainz-import` command loads the frozen CC0 AcousticBrainz dump
into the `mb_acousticbrainz` cache table so tracks without local analyzer
coverage can still surface bpm/key in mix and library projections.

## Dataset

- Source: https://acousticbrainz.org/download
- Pinned revision: `acousticbrainz-dump-2022-06` — submissions ended 2022; the
  final dumps were published June 2022 (~7M recordings, ~29.4M rows across the
  rhythm/tonal CSVs, a few GB compressed).
- License: CC0 1.0 (no rights reserved).

## Usage

```
go -C backend run ./cmd/acousticbrainz-import \
  -rhythm /path/to/acousticbrainz-rhythm.csv \
  -tonal /path/to/acousticbrainz-tonal.csv \
  -db-host localhost -db-port 5434 \
  -db-user omp -db-password ... -db-name openmusicplayer
```

Database flags default from `OMP_AB_DB_*` environment variables. `-tonal` is
optional; when present, key/scale rows are joined to rhythm rows by recording
MBID and converted to Camelot at load time.

## Loader contract

- Rows with an unparseable MBID or BPM are rejected and counted, not fatal.
- BPM outside [30, 300] is rejected, matching the compact analysis validator's
  "out of range decodes as absent" behavior.
- Duplicate MBIDs within one import resolve last-row-wins via upsert; re-running
  over the same dump is idempotent because each row deterministically upserts to
  the same values.
- Unparseable key/scale pairs are dropped rather than guessed.
- The loader never writes to `track_analysis`.

## Merge policy

AcousticBrainz values are an external coverage REFERENCE class per
`docs/AUDIO_MIR_EVALS.md` — never ground truth, never an override of the local
analyzer. At read time (`db.BackfillAcousticBrainzSummary`,
`backfillLibrarySummariesFromAcousticBrainz`, and the analysis detail handler),
cached AB values only backfill bpm/camelot fields that local analyzer output
AND user overrides left entirely absent. Every backfilled value carries
provenance (`acousticbrainz:<dump_revision>`) and a lowered confidence marker so
API payloads can mark it externally sourced.

## Discovery candidate hints (issue #400)

AcousticBrainz is an external coverage REFERENCE class per
`docs/AUDIO_MIR_EVALS.md`: frozen crowd-submitted Essentia output, sometimes
octave-wrong on tempo, with no beat grids. It is never ground truth. Discovery
candidate hints inherit that policy in full — they are advisory display data and
they never block, reject, reorder, downrank, or delay a download.

Hints are attached at exactly one place, `discovery.Service.search`, which is the
single choke point behind `GET /api/v1/discovery/search`, the assist search
envelope (`SearchRanked`), and the persisted untrusted source-selection snapshot.
The attach is a pure cache read over `mb_acousticbrainz`: one batched,
deduplicated `GetAcousticBrainzByRecordingIDs` call per search response, bounded
by a 750 ms child of the discovery request budget. There is no runtime
AcousticBrainz network client anywhere in this repository and none may be added
behind the hint seam. A lookup error, an exhausted deadline, an empty table, or a
nil hint source all return the candidates untouched.

On a cache hit the whole block is written at once into `candidate.metadata`; on a
miss not one key is written. There is never provenance without a value and never
a value without `ab_source`.

| key | type | present when |
|---|---|---|
| `ab_bpm` | number | the cached row has a BPM |
| `ab_key` | string | the cached row has a key tonic |
| `ab_key_scale` | string | the cached row has a key scale |
| `ab_camelot` | string | the cached row has a Camelot key |
| `ab_source` | string, always `acousticbrainz` | every hit |
| `ab_dump_revision` | string | the cached row has a non-empty dump revision |
| `ab_retrieved_at` | string, RFC3339 UTC | the cached row has a retrieval time |

`ab_source`, `ab_dump_revision`, and `ab_retrieved_at` are the provenance triple:
together they say which external dataset a value came from, which pinned dump
revision produced it, and when it was loaded, so a client can always mark a
hinted value as externally sourced and stale-able.

MBID resolution reads `mbRecordingId` then `mb_recording_id` from candidate
metadata — the same keys the download queue already consumes to populate
`download_jobs.mb_recording_id`. A missing, malformed, or nil-UUID value is
simply skipped and never fails a search. No discovery provider populates either
key today, so the seam is dormant in production and is exercised by fixtures; it
lights up with no further changes the day a provider or a MusicBrainz matching
step writes one.

UI display of hints, and any automatic rejection or downranking based on them,
are explicitly out of scope.

## Dump artifacts

Base URL:
`https://data.metabrainz.org/pub/musicbrainz/acousticbrainz/dumps/acousticbrainz-lowlevel-features-20220623/`

| file | bytes | sha256 |
|---|---|---|
| `acousticbrainz-lowlevel-features-20220623-rhythm.tar.zst` | 1,260,693,156 (1.17 GiB) | `5f813ff49c2ac1f35cca3947e081178758cddbd9b5292163dff58bdf3a025fad` |
| `acousticbrainz-lowlevel-features-20220623-tonal.tar.zst` | 883,618,800 (843 MiB) | `fa1d9e4c5e1af80372d9dbf96bc25bb84a3b0165600fbe2684496dbd1445bc0d` |
| `acousticbrainz-lowlevel-features-20220623-lowlevel.tar.zst` | 1,159,433,718 | `cf1b6511d9c33996edb1bbf1c6415b428bf45f263b0f87af4a7afa8ed70985ea` — **unused, do not download** |
| `sha256sums` | 370 | — |

Verify before use **against the digests in the table above**, not only against
the downloaded `sha256sums`: that manifest ships from the same base URL as the
archives, so a re-cut dump arrives with a matching re-cut manifest and passes.
`scripts/acousticbrainz-import.sh fetch` enforces the pinned digests
(`AB_RHYTHM_SHA256` / `AB_TONAL_SHA256` in the script) and keeps the manifest as
a cross-check. By hand:

```bash
printf '%s  %s\n%s  %s\n' \
  5f813ff49c2ac1f35cca3947e081178758cddbd9b5292163dff58bdf3a025fad acousticbrainz-lowlevel-features-20220623-rhythm.tar.zst \
  fa1d9e4c5e1af80372d9dbf96bc25bb84a3b0165600fbe2684496dbd1445bc0d acousticbrainz-lowlevel-features-20220623-tonal.tar.zst \
  | sha256sum -c -
grep -E 'rhythm|tonal' sha256sums | sha256sum -c -   # cross-check only
```

**If the pinned digests do not match, STOP.** The loader stamps
`dump_revision = acousticbrainz-dump-2022-06` and the matching provenance onto
whatever bytes it is given, so loading a different cut silently mislabels the
cache, and every number recorded under "Observed run" stops describing it.

Each archive holds exactly one member,
`acousticbrainz-lowlevel-features-20220623/<name>.csv`. Uncompressed: rhythm
2,870,186,517 B (2.67 GiB), tonal 2,287,794,469 B (2.13 GiB). The `lowlevel`
archive carries nothing the loader reads — skip it.

### Revision mapping

The artifact directory is named `...-20220623`, but the loader stamps
`dump_revision = "acousticbrainz-dump-2022-06"`
(`backend/cmd/acousticbrainz-import/main.go`, `PinnedAcousticBrainzDumpRevision`).
Provenance therefore renders as `acousticbrainz:acousticbrainz-dump-2022-06`.
The two strings are not interchangeable; the pinned constant is the one that
appears in the database and in API payloads.

## Dump layout vs loader input

**The published dump does not match the CSV the loader parses.** Both files
carry a `submission_offset` column in position 2 that the loader does not
expect. Real headers:

```
rhythm.csv: mbid,submission_offset,bpm,bpm_histogram_first_peak_bpm_mean,bpm_histogram_first_peak_bpm_median,bpm_histogram_second_peak_bpm_mean,bpm_histogram_second_peak_bpm_median,danceability,onset_rate
tonal.csv:  mbid,submission_offset,key_key,key_scale,tuning_frequency,tuning_equal_tempered_deviation
sample:     0e11c0fd-a1da-4b88-a438-7ef55c5809ec,0,120.763885498,120,120,133,133,0.996203362942,2.86757659912
```

`parseRhythmRow` reads `record[1]` as BPM, so on a raw dump row it parses
`submission_offset` — which fails the `[30, 300]` guard for the overwhelming
majority of rows, **but not for all of them**. A recording with 30 or more
submissions has raw rows whose `submission_offset` parses as a perfectly legal
BPM, and those rows are imported with a BPM equal to the submission counter. In
a 1,379,684-row sample of the real rhythm dump, 757 rows (0.055%) carried an
offset in `[30, 300]` (observed maximum 61) — order 10⁴ silently wrong BPM
values across the whole dump, each of which passes the
`chk_mb_acousticbrainz_bpm` CHECK and then backfills user-visible bpm/camelot
with AcousticBrainz provenance. `parseTonalRow` reads `record[1]`/`record[2]` as
key/scale, so a raw row silently yields `key="0", scale="A"` and
`camelotFromKey` returns `""`.

**A nonzero `imported=` count is therefore NOT proof that the input was
projected.** The reliable checks are the projected header itself
(`mbid,bpm` / `mbid,key,scale`, no `submission_offset` column) and, after a
load, `SELECT count(*) FROM mb_acousticbrainz WHERE bpm < 70;` — raw-layout
contamination clusters at the bottom of the range (30–61 in the sampled data).

Project the dump before loading:

| input | keep | emit |
|---|---|---|
| `rhythm.csv` | `submission_offset == 0` | `$1,$3` → `mbid,bpm` |
| `tonal.csv` | `submission_offset == 0` | `$1,$3,$4` → `mbid,key,scale` |

`submission_offset == 0` selects one canonical submission per recording. It is
the O(1)-memory dedup: the dumps hold ~29.46M submission rows, of which
**7,564,449 have `submission_offset == 0`** (measured — see "Observed run";
acousticbrainz.org's "~6.06M unique recordings" counter is 25% lower and is not
the number to budget against). De-duplicating instead by hashing 7.5M UUIDs
would cost ~1 GB of RAM for no extra determinism.

This contract is pinned by `TestParseRhythmRowRejectsRawDumpLayout`,
`TestParseTonalRowRejectsRawDumpLayout` and
`TestParseRhythmRowAcceptsRawRowsWhoseOffsetLooksLikeBPM` (the residue above) in
`backend/cmd/acousticbrainz-import/main_test.go`. If any of them fails, the
projection rule above has drifted.

## Disk and time budget

Every figure below is measured from the issue #399 run on the dogfood box
(details and raw numbers under "Observed run"). Size the maintenance window
from these, not from the pre-run estimates they replaced.

- Download: ~2.14 GB for the two archives (72 s measured, ~30 MB/s).
- Projection: streaming (`zstd -dc | tar -xOf - | awk`), no multi-GB
  intermediate files; 19.4 s, and the projected shards total ~0.7 GB.
- Peak working set: ~2.7 GB on disk (archives + shards). Require at least
  10 GB free.
- Rows to load: **7,564,449** (`submission_offset == 0`), i.e. **~473k per
  shard** across 16 shards.
- Loader throughput is **per row, not batched**: `flush()` issues one
  `UpsertAcousticBrainz` per entry and opens no transaction, so `-batch-size`
  only controls flush cadence — its "rows per transaction batch" help text is
  inaccurate. **Measured on the real load: ~309 upserts/s** (shard 0 =
  477,178 rows in 1544 s) on a box running several concurrent agent lanes.
  An earlier synthetic benchmark against an idle single-container Postgres
  reached ~1,235 upserts/s and implied an 82-minute full load; that rate did
  **not** hold and must not be used for planning.
- **Full load: ~7.56M rows ≈ 7 h serial** (16 shards × ~26 min at the measured
  rate), ≈ **1.2 GB table + index** (~158 B/row, measured: 72 MB for
  477,161 rows).
- Each run has a hard 2 h `context.WithTimeout` and holds that shard's whole
  tonal side in memory as a `map[uuid.UUID]tonalRow` — **~473k entries per
  shard** (an unsharded run would need ~7.5M entries, ~2 GB).
- **Stop rule for a bounded window:** after shard 0 finishes, extrapolate
  `elapsed × 16`. If that exceeds the window you budgeted — issue #399 budgeted
  **180 minutes** — stop after the current shard and load the rest later. This
  is the rule that fired in the #399 run (411 min projected vs. 180 budgeted).

**Therefore: shard the load.** Split on the first hex character of the MBID into
16 `rhythm-<h>.csv` / `tonal-<h>.csv` pairs. Sharding on the join key keeps a
recording's rhythm and tonal rows in the same shard, so `-rhythm`/`-tonal`
pairing stays lossless while each run holds ~473k map entries and completes in
~26 min on a loaded box, well inside the context deadline.

Shards are independent and idempotent, so a failed or interrupted shard is
simply re-run. A partial load is valid — the table is a pure cache.

## Running against a target

`scripts/acousticbrainz-import.sh` wraps the whole procedure:

```bash
export AB_DIR=/var/tmp/ab-dumps          # keep the workspace OUTSIDE the repo
export OMP_AB_DB_PORT=5434               # target's published Postgres port
scripts/acousticbrainz-import.sh fetch     # df guard + download + sha256 verify
scripts/acousticbrainz-import.sh project   # stream-project + 16-way shard
scripts/acousticbrainz-import.sh snapshot  # BEFORE census, save it verbatim
scripts/acousticbrainz-import.sh scope     # narrow to the target library's MBIDs
scripts/acousticbrainz-import.sh load-lib  # library-scoped pass
scripts/acousticbrainz-import.sh load-full # all 16 shards, timed, into load.log
scripts/acousticbrainz-import.sh verify    # post-load query block
scripts/acousticbrainz-import.sh snapshot  # AFTER census; only ab_rows may move
scripts/acousticbrainz-import.sh clean     # drop the .tar.zst archives
```

Operational notes:

- `psql` is not installed on the ops host. All SQL goes through
  `docker exec <container> psql -U omp -d openmusicplayer ...`.
- **Resolve the container by published port, never by a hardcoded name** —
  compose project names change on redeploy:
  `docker ps --filter publish=5434 --format '{{.Names}}' | grep -m1 postgres`.
- Loader DB flags default from `OMP_AB_DB_*` and already point at
  `localhost:5434`.
- The loader always calls `database.Migrate()` on startup. Against a target
  already at or ahead of the current schema this is a no-op, but confirm it with
  the before/after census rather than assuming.
- **The only table the *import* writes is `mb_acousticbrainz`** — but that is
  not the same as "the loader writes nothing else". `Migrate()` also runs
  data-normalizing `UPDATE`s on `research_jobs`, `research_runs`,
  `research_revisions` and `research_events` (assigned variant/cohort, status
  and kind remaps, `result_limit` clamped to 25) and drops
  `research_revisions.is_terminal` (`backend/internal/db/db.go`,
  `refreshResearchSchemaConstraints`). Those are the backend's own idempotent
  startup normalizations, so they are no-ops against a target whose backend
  already boots this schema — but they are **not** covered by the rollback, and
  `snapshot` cannot detect them (they are `UPDATE`s and a `DROP COLUMN`, not
  row-count changes). If the target's backend is older than this checkout,
  migrate it first or accept the normalization.
- The before/after census is the proof for `mb_acousticbrainz` and the row-count
  tables it lists; any other counter moving is a failure to report, not to paper
  over. It says nothing about the `research_*` normalizations above.
- `snapshot`, `verify` and `scope` run `psql` through `docker exec` on the
  **local** docker daemon while the loader connects over TCP to
  `OMP_AB_DB_HOST`. The script refuses a non-local `OMP_AB_DB_HOST` for exactly
  this reason: otherwise the census would describe a different database than the
  one that was written.
- ⚠️ **Never point `OMP_POSTGRES_TEST_DSN`, `DATABASE_URL`, or
  `QA_DATABASE_URL` at a dogfooded database.** The db integration tests
  `TRUNCATE TABLE play_events, user_library, tracks, users RESTART IDENTITY
  CASCADE` (`backend/internal/db/play_event_repository_integration_test.go`).
  Seed fixtures only on a disposable stack.

### Rejected-row accounting

Rejections are expected and non-fatal. A row is rejected when the MBID or BPM is
unparseable, or the BPM falls outside `[30, 300]` — the same bound the DB CHECK
constraint enforces. Report `rejected` as an absolute count and as a share of
attempted rows, alongside `camelot_mapped`.

A recording that appears **only** in the tonal dump is not imported at all:
`run()` drives off the rhythm file and the tonal map is a lookup side. Rows can
also land with `camelot IS NULL` when the tonal row is absent or the key/scale
pair is not a known major/minor.

## Verification queries

```sql
SELECT count(*) AS ab_rows, count(bpm) AS with_bpm, count(camelot) AS with_camelot,
       pg_size_pretty(pg_total_relation_size('mb_acousticbrainz')) AS size
FROM mb_acousticbrainz;

SELECT dump_revision, source, count(*) FROM mb_acousticbrainz GROUP BY 1,2 ORDER BY 3 DESC;

-- join coverage: how much of the library the dump actually covers
SELECT (SELECT count(DISTINCT t.mb_recording_id)
          FROM tracks t JOIN mb_acousticbrainz ab ON ab.recording_mbid = t.mb_recording_id) AS covered_mbids,
       (SELECT count(DISTINCT mb_recording_id) FROM tracks WHERE mb_recording_id IS NOT NULL) AS library_mbids;

-- covered AND actually missing local bpm/camelot (i.e. the backfill can do work)
SELECT count(*) AS backfill_eligible_and_covered
FROM tracks t
JOIN mb_acousticbrainz ab ON ab.recording_mbid = t.mb_recording_id
LEFT JOIN track_analysis ta ON ta.track_id = t.id
WHERE ta.track_id IS NULL OR ta.effective_bpm IS NULL OR ta.effective_camelot IS NULL;

-- per-track provenance for every match
SELECT t.id, t.artist, t.title, ab.recording_mbid, ab.bpm, ab.key_key, ab.key_scale,
       ab.camelot, ab.source, ab.dump_revision, ab.retrieved_at
FROM tracks t JOIN mb_acousticbrainz ab ON ab.recording_mbid = t.mb_recording_id
ORDER BY t.id;

SELECT * FROM mb_acousticbrainz ORDER BY recording_mbid LIMIT 5;
```

## Observed run (issue #399)

Target: the local dogfood stack on port 5434 (compose project
`omp-local-run-vruka8`), 2026-08-26. Resolve the container by port — the compose
project name has already changed once.

**Dump handling**

| step | result |
|---|---|
| download | rhythm 42.0 s, tonal 30.0 s (~30 MB/s); both `sha256sum -c` → `OK` |
| projection + 16-way shard | 19.4 s total, streaming |
| projected rows | rhythm 7,564,449 / tonal 7,564,449 (identical — pairing is lossless) |
| peak disk | 2.7 GB (archives + shards); 694 MB after deleting the archives |

Row counts: `submission_offset == 0` yields **7,564,449** rows, not the ~6.06M
"unique recordings" figure quoted on acousticbrainz.org; the budget section
above is written against this measured number. Within one shard, MBIDs are very
nearly unique — shard 0 held 477,218 rows for 477,201 distinct MBIDs
(17 duplicates, 0.004%), which the loader resolves last-row-wins.

**Load**

Only shard `0` was loaded, plus a library-scoped pass. Shard 0 took
**1544 s (25.7 min)** on a box running several concurrent lanes —
**309 upserts/s** (477,178 / 1544), roughly 4× below the ~1,235/s synthetic
benchmark. Extrapolating `1544 s × 16 = 411 min` blew past the 180-minute stop
rule budgeted for this run (see "Disk and time budget"), so the load was stopped
after shard 0. **A partial load is a valid state**: the table is a
pure cache, shards are independent, and the remaining shards can be loaded later
with `scripts/acousticbrainz-import.sh load-full 1 2 3 ...`.

```
shard 0: imported=477178 rejected=40 camelot_mapped=475590 total=477178  elapsed=1544s
lib    : imported=1      rejected=0  camelot_mapped=1      total=1
```

Rejections: **40 of 477,218 attempted rows (0.0084%)** — out-of-range or
unparseable BPM. 1,588 rows landed with `camelot IS NULL` (477,161 rows,
475,573 with camelot): no tonal row, or a key/scale pair outside the known
major/minor set.

Idempotence: re-running the library pass and a 20,000-row slice of shard 0 left
the count at **477,161 → 477,161**.

**Result on staging**

```
 ab_rows | with_bpm | with_camelot | size
  477161 |   477161 |       475573 | 72 MB

 covered_mbids | library_mbids          backfill_eligible_and_covered
             1 |            26                                      0
```

**Join coverage is 1 / 26 (3.8%), and the backfill did no work.** This is the
honest result, not a defect:

- The dump is frozen at 2022; the dogfood library is mostly 2023–2025 releases.
- All 26 library MBIDs were probed against the AcousticBrainz API and 25 are
  genuinely absent upstream — loading more shards cannot change this.
- The single hit (`007cefd7-58f5-434a-b772-6e8365f37cd7`, Porter Robinson —
  "Something Comforting", bpm 143.99, D# major → 3B) already has analyzer
  output (`effective_bpm=144.23`, `effective_camelot=5B`), so the analyzer wins
  and AB backfills nothing. That is the merge policy working correctly.

Expect low coverage on any modern library. AcousticBrainz is a long-tail
back-catalogue safety net, not a primary source.

Only `mb_acousticbrainz` changed. Every other counter was byte-identical across
the before/after census (`tracks=48 with_mbid=26 distinct_mbid=26
track_analysis=47 users=31 user_library=202 playlists=7 play_events=619
track_sources=46 tables=30`), confirming the implicit `Migrate()` was a schema
no-op against an already-current target.

**End-to-end backfill check** (run on a disposable isolated stack, *not*
staging, because staging has no backfill-eligible covered track and this lane
may not seed fixtures there): 6 real dump recordings were loaded, 5 tracks with
an empty `track_analysis` row plus 1 control carrying analyzer values
(`123.4` / `9A`). Over `/api/v1/library` all 5 returned the dump's bpm/camelot
with `"provenance":"acousticbrainz:acousticbrainz-dump-2022-06"` and
`"confidence":0.5`; the control kept `123.4` / `9A` with no AB provenance.

## API visibility caveat

`backfillLibrarySummariesFromAcousticBrainz` computes a backfilled summary for
any covered track, but the API only ever shows it when a `track_analysis` row
already exists:

- `backend/internal/api/library.go` emits `analysis_summary` only when
  `t.AnalysisStatus.Valid`.
- `backend/internal/api/analysis.go` returns `404 ANALYSIS_NOT_FOUND` before it
  gets as far as the backfill.

So a track that has an MBID and AB coverage but **no `track_analysis` row at
all** shows nothing over the API, even though the cache holds usable bpm/key.
Fixtures used to verify the backfill must therefore carry a `track_analysis`
row (`summary_json = '{}'` is enough). Surfacing AB-only coverage for tracks
with no analysis row is a follow-up candidate, not a bug in this loader.

## Rollback

```sql
TRUNCATE mb_acousticbrainz;
```

That is the whole rollback **of the import**. The table is a pure cache: the
import never writes `track_analysis`, user overrides, or any other table, and
the backfill happens at read time. After truncation, bpm/camelot projections
simply revert to analyzer-only values, and provenance markers disappear with
them.

It does **not** undo the `database.Migrate()` side effects described under
"Running against a target" (the `research_*` normalizations and the
`research_revisions.is_terminal` drop). Those are the backend's own startup
migrations, they are no-ops against a target already running this schema, and
there is no rollback for them here — check the target's backend version before
importing rather than planning to reverse them.
