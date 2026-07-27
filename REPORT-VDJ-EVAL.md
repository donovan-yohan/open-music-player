# VirtualDJ comparison exporter report

## All-new files

- `TASK-VDJ-EVAL.md` — source task, included unchanged; baseline and final
  SHA-256: `18eeec40a62cd3962a58f27f1521076b777e97db2264ef955a2e24756e61c796`.
- `evals/audio_mir/src/audio_mir_eval/vdj_export.py` — standalone
  `python -m audio_mir_eval.vdj_export` exporter.
- `evals/audio_mir/tests/test_vdj_export.py` — focused and end-to-end coverage.
- `evals/audio_mir/tests/fixtures/vdj_database_sample.xml` — hand-written VDJ
  database fixture.
- `evals/audio_mir/docs/vdj-comparison.md` — operator workflow and caveats.
- `REPORT-VDJ-EVAL.md` — this delivery and verification record.

No tracked file that existed at task start was edited.

## Verification

From the repository root of the `codex/vdj-compare-eval` worktree:

```text
$ rtk scripts/lint audio-mir
All checks passed!
14 files already formatted
```

```text
$ rtk scripts/test audio-mir
.........................................                                [100%]
```

The test gate includes 14 focused exporter tests. Its end-to-end test generates
a real WAV file, exports a complete schema-v2 prediction artifact, invokes the
existing score CLI, and verifies that the scorer writes a report.

## Assumptions and behavior

- Joining is SHA-256-only after applying explicit, repeatable
  `--audio-root-map OLD=NEW` prefix mappings. There is no basename fallback.
  XML-only songs are skipped and manifest-only items become explicit missing
  prediction errors so the existing scorer receives the exact manifest ID set.
- `--bpm-encoding auto` treats values below 30 as beat periods in seconds and
  computes `60 / value`; larger values are treated as BPM. `period` and `bpm`
  force either interpretation. The chosen interpretation is retained per
  prediction and in scorer-visible run metadata.
- Beat grids are constant-tempo grids starting at `Scan FirstBeat` or a
  beatgrid POI. Duration prefers `Infos SongLength`, then supported Scan/Song
  duration attributes, then a WAV probe or `ffprobe`.
- Downbeats are absent by default. `--assume-44-bars` emits every fourth
  synthesized beat starting at the selected anchor and records the 4/4
  assumption in provenance.
- Musical keys and Camelot keys are normalized to the harness convention:
  chromatic `key_index` from C=0 through B=11, with `major` or `minor` mode.
  Unparseable keys are omitted and counted.
- Run provenance identifies `virtualdj`, records observed Scan versions and
  the `database.xml` SHA-256, and satisfies the existing prediction loader's
  required schema-v2 digests and completeness fields.

## Open questions for a real database

- Does the user's VirtualDJ build consistently store `Scan Bpm` as a period,
  and when is `AltBpm` populated?
- Are `Scan FirstBeat` and beatgrid `Poi Pos` consistently expressed in
  seconds and aligned to the intended beat phase?
- Which duration attribute is present for the user's benchmark files, and
  does it agree with the local audio probe?
- Does the selected key-display setting change the XML value or only the UI?
- Most importantly, the XML does not establish bar phase. A VirtualDJ
  downbeat comparison remains best-effort until the user's database and a few
  known tracks confirm the 4/4 anchor assumption.

## Suggested next step

Batch-analyze a small GuitarSet/GiantSteps subset in the user's licensed local
VirtualDJ installation, copy its `database.xml`, run the documented exporter
with an explicit root mapping, and inspect the logged match counts plus
per-track BPM interpretations. Score the default artifact first; run a second
export with `--assume-44-bars` only as a labeled exploratory downbeat result.

## Fix addendum: case-insensitive Windows root mapping

Review finding: `--audio-root-map` prefix matching was case-sensitive, so a
Windows-cased mapping mismatch (VDJ paths originate on case-insensitive
filesystems) silently skipped every song.

Fix: mapping prefixes that look Windows-style (drive letter or backslash) now
match case-insensitively while preserving the path remainder; POSIX prefixes
stay case-sensitive. The exporter tracks per-mapping applied counts, logs them,
and warns on stderr when a provided mapping matched zero songs.

Evidence (this worktree): `scripts/lint audio-mir` — "All checks passed!";
`scripts/test audio-mir` — 44 passed, including new tests for case-mismatched
Windows prefixes, POSIX case sensitivity, path-boundary handling, and the
zero-match warning. Implementation by Codex (gpt-5.6-sol); its run was killed
by a full disk mid-commit, so the final commit and this addendum were completed
by the orchestrator after re-running both gates.
