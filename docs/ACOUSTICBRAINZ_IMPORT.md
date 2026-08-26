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
