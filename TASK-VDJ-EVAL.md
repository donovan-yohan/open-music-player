# TASK: VirtualDJ comparison exporter for audio-mir eval harness

## Intent

We want to compare VirtualDJ's analysis (BPM, downbeat, key) against our own analyzer
using the existing `evals/audio_mir` benchmark harness. VirtualDJ batch-analyzes audio
on the user's desktop and writes results to its `database.xml`. Build an exporter that
converts that XML into the harness's prediction JSONL so the existing `score`
subcommand can score VDJ against the same ground truth manifests (GuitarSet,
GiantSteps) we already use.

## Hard boundaries — read first

- **NEW FILES ONLY.** Do NOT edit any existing file in this repo. A parallel lane
  (`codex/issue-312-downbeat-calibration-resume`) has large in-flight changes to
  `evals/audio_mir` including `io.py`, `cli.py`, `score.py`, tests, and pyproject.
  Any edit you make to an existing file will conflict. This includes:
  - no new subcommand in `cli.py` — expose the tool as `python -m audio_mir_eval.vdj_export`
  - no console-script entry in `pyproject.toml`
  - no edits to `evals/audio_mir/README.md`
- Other agents are working in this repo right now. Stay inside this worktree, touch
  only your new files, and do not run repo-wide formatters.
- Import existing harness code read-only (`audio_mir_eval.io` etc.) rather than
  duplicating record formats — if the parallel lane later changes the schema, a
  new-files-only diff rebases trivially.

## Context map (verified file:line on this branch)

- CLI + subcommands: `evals/audio_mir/src/audio_mir_eval/cli.py:33-82`; `score`
  subcommand at `cli.py:139-169` takes `--manifest --predictions --output`.
- Manifest format (JSONL: id, label_kind, reference, audio_sha256, provenance):
  `evals/audio_mir/src/audio_mir_eval/io.py:89-152`.
- Prediction artifact format (JSONL: schema_version 2 run record, then prediction
  records): `io.py:156-213`. Prediction fields used by the analyzer runner: bpm,
  tempo_confidence, beats_ms, downbeats_ms, downbeat_confidence, key_index, mode,
  key_confidence (`runner.py:17-26`).
- `sha256_file()` helper: `io.py:274-279`.
- Scoring: tempo acc1/acc2 (`score.py:71-101`), beats/downbeats mir_eval.beat
  (`score.py:129-188`), key exact/weighted (`score.py:191-217`).
- Read these files yourself before writing code; the line numbers are from a recent
  scan and the loader/validation details (especially what the score path requires of
  the run record) are authoritative in code.

## Deliverables (all new files)

1. `evals/audio_mir/src/audio_mir_eval/vdj_export.py` — module with
   `python -m audio_mir_eval.vdj_export` entry point (`__main__` guard or a
   `main(argv)` invoked via `if __name__ == "__main__"`).

   Inputs:
   - `--database` path to VirtualDJ `database.xml`
   - `--manifest` path to a harness manifest JSONL
   - `--audio-root-map OLD=NEW` (repeatable) prefix remap, because VDJ ran on a
     different machine so `FilePath` values in the XML won't match local paths
   - `--output` predictions JSONL path
   - `--bpm-encoding {auto,period,bpm}` default `auto` (see BPM notes)
   - `--assume-44-bars` flag, default off (see downbeat notes)

   Behavior:
   - Parse `database.xml`: `<Song FilePath="...">` elements with `<Scan ...>`
     (attributes seen in the wild: `Version`, `Bpm`, `AltBpm`, `Key`, `Volume`,
     `FirstBeat`, `Flag`) and `<Poi ...>` elements (beatgrid anchor POIs).
     Parse defensively — attributes vary by VDJ version; missing attribute means
     that field is absent, never a crash.
   - Join songs to manifest items by SHA-256 of the (remapped) local audio file.
     Path-basename fallback is NOT acceptable as a default; if you add it, put it
     behind an explicit flag. Log counts: matched, XML-only (skipped), manifest-only
     (missing prediction).
   - Emit a predictions JSONL that the existing `score` subcommand accepts against
     that manifest. Satisfy whatever run-record validation the score path enforces;
     for provenance use analyzer="virtualdj", analyzer_version from the Scan
     `Version` attribute, plus the database.xml sha256.

2. BPM handling: VirtualDJ's XML `Bpm` attribute is widely reported to store the
   beat *period* (seconds per beat, e.g. 0.4615 ≈ 130 BPM), not BPM. Do not trust
   this blindly: `auto` mode should use a heuristic (value < 30 → treat as period,
   convert 60/value; else treat as BPM) and record which interpretation was used in
   the prediction/provenance so a bad guess is visible in the report. `period` /
   `bpm` force the interpretation.

3. Beats/downbeats: if a beat anchor is derivable (FirstBeat attribute or a
   beatgrid POI position) plus a BPM, synthesize a constant-tempo beat grid over
   the track duration and emit `beats_ms`. Track duration: prefer a duration
   attribute from the XML if present; otherwise probe the local audio file
   (ffprobe or mutagen — pick what the harness image already has; check the
   analyzer/eval Docker context before adding any dependency).
   Downbeats: VDJ's XML does not clearly export bar phase. Default: emit
   `downbeats_ms` null/absent. With `--assume-44-bars`: emit every 4th beat
   starting from the anchor, and mark that assumption in provenance. Be honest in
   the report that VDJ downbeat comparison is best-effort until we inspect a real
   database.xml from the user's machine.

4. Key: parse both notations VDJ can be configured to write: standard musical
   ("Am", "G#m", "F#", "Db") and Camelot ("8A", "12B"). Map to the harness's
   key_index/mode convention (read how our analyzer output and `score.py` key
   scoring interpret key_index/mode; match it exactly). Ambiguous/unparseable key
   → key fields absent, counted in the log.

5. Tests: `evals/audio_mir/tests/test_vdj_export.py` (new file only; do not touch
   existing test files) plus a fixture `evals/audio_mir/tests/fixtures/vdj_database_sample.xml`
   you hand-write. Cover:
   - BPM period-vs-bpm heuristic (both interpretations, forced modes)
   - key parsing: standard + Camelot + garbage
   - sha256 join incl. remap, XML-only and manifest-only songs
   - beat grid synthesis + `--assume-44-bars` downbeats
   - end-to-end: build a tiny manifest + tiny real audio fixture (generate a short
     silent/wav tone in-test), run exporter, then run the existing score path on the
     result and assert it produces a report (this proves format compatibility
     without editing harness code).
   - Match the existing tests' style/pytest layout in `evals/audio_mir/tests/`.

6. `evals/audio_mir/docs/vdj-comparison.md` (new) — short operator guide: how the
   user batch-analyzes the benchmark audio in VirtualDJ (drag folder into VDJ,
   let it scan; note the key-notation setting), where database.xml lives on
   Windows/macOS, the exact exporter + score commands to run, known caveats
   (BPM encoding, downbeat assumption, licensing note: local desktop analysis of
   your own files, no VDJ in the ingest path).

## Verification (required before claiming done)

- `scripts/lint audio-mir` passes from repo root of THIS worktree.
- `scripts/test audio-mir` passes (runs the eval package tests; check the script to
  see how it invokes them — it may build a Docker image; if the containerized run
  can't work in this environment, run the package's pytest directly with uv/python
  and say exactly what you ran).
- Paste exact commands + tail of output in the report.

## Report contract

Write `REPORT-VDJ-EVAL.md` in the worktree root: changed (all-new) files list,
test/lint evidence, the BPM/downbeat/key assumptions you baked in, open questions
for the user (things only a real database.xml from their machine can settle), and
suggested next step. Then commit everything on this branch (`codex/vdj-compare-eval`)
with a conventional-commit message. Do NOT push, do NOT open a PR.
