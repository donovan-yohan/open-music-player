# Phase-2 Design — DJ Metadata, Audio Analysis & Live Mix Tools

This is the design for the **second** phase of work, to begin **after** the daily-driver
fundamentals in [`ROADMAP_SPOTIFY_PARITY.md`](ROADMAP_SPOTIFY_PARITY.md) land. Goal: make the app a
credible tool for **live queue editing with real waveforms**, **DJ-esque transition tools**, and
**saving playlists as mixes**.

It builds on contracts that already exist — do not re-invent them:
- [`AUDIO_ANALYZER_SERVICE.md`](AUDIO_ANALYZER_SERVICE.md) — out-of-process analyzer + `track_analysis` contract.
- [`MIX_PLAN_TIMING_CONTRACT.md`](MIX_PLAN_TIMING_CONTRACT.md) — `mix_plans` clip timing (source trim + timeline placement, gain/fade hooks).
- [`QUEUE_WAVEFORM_TRIM_UX.md`](QUEUE_WAVEFORM_TRIM_UX.md) — the landed queue waveform/trim UX (currently deterministic/mock peaks).

## What already exists (do not rebuild)

| Capability | State | Where |
|---|---|---|
| Analyzer service contract | Defined; **disabled by default** (`ANALYZER_ENABLED`/`ANALYZER_BASE_URL`) | `AUDIO_ANALYZER_SERVICE.md`, backend processor |
| `track_analysis` table | Exists: `summary_json` = bpm, key, camelot, energy, waveform, intro, outro, sections, cue_candidates | `internal/db`, `GET /tracks/{id}/analysis` |
| `mix_plans` table + API | Exists: JSONB clips, source-trim + timeline placement, gain/fade hooks, optimistic version | `/api/v1/mix-plans`, `MIX_PLAN_TIMING_CONTRACT.md` |
| Waveform trim UX | **Landed** but on deterministic/mock peaks | `queue_waveform_trim_control.dart`, `stacked_waveform_timeline.dart`, `queue_provider.dart` |
| Client analysis model | Fully parses bpm/key/camelot/energy/waveform/cues | `models/track_analysis.dart` — **not surfaced in UI** |

So the phase-2 job is mostly **activation + real data + editor UX**, not greenfield schema.

## Gap between "hooks exist" and "DJ tool"

1. **Analysis is off and never surfaced.** The analyzer is disabled by default and `TrackAnalysis`
   (bpm/key/camelot/energy) is parsed but rendered nowhere except an optional queue label.
2. **Waveforms are mock.** The trim UX draws deterministic peaks from the track id, not real audio —
   so "where does the beat drop" is not truthful yet.
3. **Two queues, and the DJ timeline sits on the operational one.** The listening queue (`just_audio`)
   and the Redis/queue-screen timeline are separate (see gap analysis). The DJ timeline must edit an
   **arrangement** (`mix_plan`), not the live playback queue.
4. **No harmonic/tempo assistance.** camelot/bpm are computed but there's no "compatible next track"
   or beat-matched transition suggestion.
5. **Playlists and mixes are disconnected.** No path from a saved playlist to an editable `mix_plan`.

## Phase-2 chunks (dependency-ordered)

Phase-1 already seeds two seams: **C11c** (read-only analysis Song-info hook) and **C17**
(save-playlist-as-mix, flag-gated). Phase-2 continues from there.

| id | lane | size | deps | title |
|----|------|------|------|-------|
| **D1** | BE | M | — | Turn analyzer on in a supported dev/prod profile; backfill `analysis_status`/summary for existing library tracks; expose a batch `analysis` field on `GET /library` so lists don't N+1. |
| **D2** | both | M | D1, C11c | Surface DJ metadata read-only: bpm, musical key + camelot, energy, on the song-info sheet and (compact) on track rows behind a "DJ info" toggle. |
| **D3** | BE | L | D1 | Real waveform peaks: have the analyzer emit a coarse peak array (already in the `waveform` summary contract), persist it, and serve a `GET /tracks/{id}/waveform` (or fold into analysis) so the client can replace mock peaks. |
| **D4** | FE | L | D3 | Replace deterministic peaks in `queue_waveform_trim_control` / `stacked_waveform_timeline` with real peaks; keep the mock generator as the offline/loading fallback. |
| **D5** | both | L | C17, MIX_PLAN | Mix editor surface: open a `mix_plan` (from a playlist via C17 or from the queue) in a dedicated timeline editor that edits **arrangement** state (`mix_plans.payload`), not the live queue. Reuses the trim/timeline widgets. Source-trim vs timeline-placement independence per `MIX_PLAN_TIMING_CONTRACT.md`. |
| **D6** | FE | M | D2 | Harmonic/tempo assist (advisory only): given the current/last track's camelot+bpm, mark library/queue candidates as compatible (adjacent camelot, ±BPM window). No auto-mixing — a suggestion badge. |
| **D7** | both | M | D5 | Persist per-clip transition intent already in the contract (gainDb, fadeInMs, fadeOutMs) from the editor; still **no** server-side audio rendering — these remain playback hints consumed client-side. |
| **D8** | FE | M | D4, D5 | Live queue editing with waveforms: the queue screen's timeline mode edits entry/exit trims against **real** peaks and writes them to the active mix plan, so a set can be shaped while listening. |

## Hard boundaries (kept from the existing contracts)

- **No server-side audio mixing/rendering engine.** gain/fade/transition fields are stored hints only
  (`MIX_PLAN_TIMING_CONTRACT.md` non-goals). Any crossfade is client playback behavior.
- **The Redis queue stays ingest/DJ-staging** and is never merged into the `just_audio` listening
  queue. Arrangement lives in `mix_plans`, operational playback in `just_audio`, ingest in Redis.
- **Analyzer stays optional and async.** Import/playback never block on analysis; disabled deployments
  must degrade to "Analysis unavailable" everywhere (the C11c hook already establishes this).
- **Mobile-only file-backed constraints still apply.** DSP is out-of-process (analyzer service), not on
  the Flutter/mobile client. VM unit/widget tests remain the acceptance proof.

## Why this ordering

Real DJ value needs **real data first** (D1 analyzer on → D3 real waveforms) before any editor is
worth building; surfacing read-only metadata (D2) is cheap and immediately useful and de-risks the
data path; the mix editor (D5) depends on the phase-1 save-as-mix seam (C17) and the timing contract;
harmonic assist (D6) is advisory and can land any time after D2. D5/D8 are the "live DJ tools" the
product vision asks for, and they deliberately edit arrangement state, not the listening queue, so
they can't destabilize everyday playback.
