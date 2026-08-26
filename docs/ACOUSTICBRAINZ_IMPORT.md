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
