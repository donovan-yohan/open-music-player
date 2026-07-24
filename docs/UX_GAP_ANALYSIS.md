# UX Gap Analysis — Spotify Parity for Daily-Driver Use

Goal: get the app to a state where it can replace a mainstream music player (Spotify) for
daily use, focused on **search, filter, ordering, and managing playlists / artists / songs**.
This document enumerates the gaps between the current app and Spotify. The prioritized,
dependency-ordered implementation plan lives in [`ROADMAP_SPOTIFY_PARITY.md`](ROADMAP_SPOTIFY_PARITY.md).

DJ / live-mix / waveform tooling is deliberately **out of scope here** and lives in a later phase
(`AUDIO_ANALYZER_SERVICE.md`, `MIX_PLAN_TIMING_CONTRACT.md`, `QUEUE_WAVEFORM_TRIM_UX.md`). Only the
clean *hooks* toward that phase are noted below.

Method: two read-only code maps (backend Go API + Flutter client) followed by a product/planning
pass (product framing → dependency plan → adversarial review). Severity and lane (BE = backend,
FE = client) are per gap.

---

## The single biggest daily-driver blocker

**You cannot actually listen to a playlist, and "Add to queue" is invisible to playback.**

- Playlist header **Play** and **Shuffle** are TODO stubs (`playlist_detail_screen.dart`), and
  `album_detail` / library rows have no play action — so "Play playlist / Play album" is impossible.
- There are **two disconnected queues**: the backend Redis queue (`QueueProvider`, shown in
  `queue_screen`, appended to by search "Add to queue") is **not** the queue the audio engine plays.
  `just_audio` (`PlaybackState`) is the real playing queue and only receives the Redis queue's
  contents one-shot when the user manually taps a row in `queue_screen`. "Add to queue" from search
  never reaches the current listening session.

Everything else is secondary to fixing this. See roadmap chunks **C4 → C5** (playback spine).

---

## Domain 1 — Search & Discovery

| Sev | Lane | Gap | Current state (evidence) |
|-----|------|-----|--------------------------|
| resolved | FE | ~~Local library search is unreachable from the UI~~ | Resolved: the routed `features/search/search_screen.dart` wires local search via `SearchService` (C3); the orphaned non-routed screen this row referenced was deleted in #292. |
| critical | FE | SearchService route mismatch (404s) | `search_service.dart` calls `/search/tracks` and `/search/albums`; router serves `/search/recordings` and `/search/releases`. Every call 404s. (Router is canonical; client is the side to fix.) |
| critical | FE | SearchService response-shape mismatch | `SearchResponse.fromJson` reads `json['results']`; backend `PaginatedResponse` emits `data`. Parsing throws even after the path is fixed. |
| high | BE | Unsanitized input → `to_tsquery` 500s | `track_repository.go` joins raw tokens with ` & `, appends `:*`, passes to `to_tsquery('english',$1)`. Inputs like `AC/DC`, trailing `&`, `:`, `!`, `(` produce invalid-tsquery 500s. **Same bug in `library_repository.go`** (caught in review — no chunk originally owned it). |
| high | BE+FE | No unified multi-entity local search | Three separate endpoints; no single sectioned tracks+artists+albums payload. |
| medium | FE | No result-type filter chips (All/Songs/Artists/Albums) | No chip UI; results are provider-sectioned, not entity-filterable. |
| medium | BE | No fuzzy / typo tolerance | Only prefix `:*` on `to_tsquery`; no `pg_trgm`. `beatls` returns nothing. |
| medium | FE | No recent-searches persistence/UI | Focused-empty box shows a static prompt, not recent queries. |
| medium | FE | No library-vs-catalog scope toggle | Library search exists only as `GET /library?q=`; search screen offers no scope switch. |
| low | BE+FE | No "Top result" best-match card | Backend returns flat `ts_rank` lists; no best-match selection. |
| low | BE+FE | Playlists not searchable | No `/search` covers playlists. |
| low | BE+FE | No user-facing sort/relevance control | Search orders by `ts_rank`; no sort param, no UI. |

## Domain 2 — Library management & organization

| Sev | Lane | Gap | Current state |
|-----|------|-----|---------------|
| high | BE+FE | No sort UI in library | Backend already supports `sort=added_at\|title\|artist`; the client exposes none of it. |
| medium | BE+FE | Duration sort unsupported | Not a backend sort option. |
| high | BE+FE | No Liked Songs / favorites distinct from membership | Only binary in-library state; no `track_favorites` table. |
| high | BE+FE | Genre not queryable/filterable | Genre only inside `track_analysis.summary_json`; no `tracks.genre` column. Client `Track.genre` is always null. |
| high | FE | Track tile has no context menu | No add-to-queue, add-to-playlist, remove, go-to-artist/album on library rows. |
| high | BE+FE | No tap-to-artist/album + no local artist/album listings | Only MB-id browse exists; cannot list all **local** tracks by an artist/album. |
| medium | BE+FE | "Downloaded" filter is client-side only | Interacts poorly with server pagination. |
| medium | BE+FE | Offset pagination, no virtualization contract | First page re-runs 3 count queries. |

## Domain 3 — Playlist management

| Sev | Lane | Gap | Current state |
|-----|------|-----|---------------|
| critical | FE | Play / Shuffle do nothing | Header buttons are TODO stubs. Biggest daily-driver blocker. |
| high | BE+FE | No batch remove | Only one track deleted per HTTP call. |
| high | BE+FE | Playlist list not searchable/sortable | `q`/`sort` params ignored; order hardcoded. |
| high | FE | Add-to-playlist unreachable from Library | "Add from anywhere" is only half-wired. |
| medium | BE+FE | `cover_url` / `is_public` are dead columns | Schema has them; Create/Update/List never read/write them. |
| medium | BE+FE | Duplicate adds silently swallowed | Schema forbids dups; no user feedback. |
| medium | FE | No multi-select mode in playlist detail | Needed for batch remove / add-selected. |
| low | FE | No in-playlist sort/filter view | Large playlists only in stored order. |
| low | FE | Duplicated add-to-playlist picker code | Two implementations, one unused. |
| low | BE+FE | No "save playlist as mix" hook | The playlist and `mix_plan` models are disconnected (DJ-phase seam). |

## Domain 4 — Artists & Songs

| Sev | Lane | Gap | Current state |
|-----|------|-----|---------------|
| critical | FE | Local track/album search broken by route mismatch | Blocks "go to album" seeds (see Domain 1). |
| high | BE+FE | No local artist page | Cannot list all library tracks/albums by an artist. |
| high | BE+FE | No local album page | Cannot list library tracks for a release. |
| high | FE | No general song context menu | (see Domain 2). |
| medium | FE | No "now playing from" context | Player never shows/carries the source. |
| medium | FE | Analysis (bpm/key/camelot/energy) never surfaced | `TrackAnalysis` fully parsed, rendered only as an optional queue label. Read-only surfacing is the DJ-phase bridge. |
| medium | BE+FE | Artist identity ambiguous for grouping | Multi-artist strings, null `mb_artist_id`. |

## Domain 5 — Home / recently-played / personalization

| Sev | Lane | Gap | Current state |
|-----|------|-----|---------------|
| critical | BE+FE | No play-event capture primitive | Nothing records that a track played, when, or in what context. No `play_count` / `last_played_at`. |
| critical | BE+FE | No recently-played API | Home cannot list "what I just listened to". |
| high | BE+FE | No play-count / top-items primitive | Cannot compute "your top tracks". |
| critical | FE | Home screen is a non-functional stub | Just an icon + "Recently Played" placeholder text. |
| high | FE | No defined "what counts as a play" threshold | Risk of play-event spam. Decision: **≥30s listened OR track completed**, `played_at` set server-side. |
| medium | BE+FE | Cross-user / stale-data isolation on home unproven | Must clear on account switch. |

## Domain 6 — Playback & queue parity

| Sev | Lane | Gap | Current state |
|-----|------|-----|---------------|
| critical | FE | No play-from-context | Tapping a library track plays only that track and wipes the queue; playlist/album have no play action. |
| critical | FE | Two disconnected queues | Redis queue ≠ the audio engine's `just_audio` queue (see top of doc). |
| high | FE | No add-to-queue / play-next on the active queue | No manual-vs-context distinction. |
| high | FE | No queue/resume-position persistence | `just_audio` queue is in-memory; Redis queue is ephemeral. App kill loses everything. Decision: persist **locally** (client store), re-resolve signed URLs on restore. |
| medium | FE | No now-playing context identity | No "Playing from &lt;playlist/album/library&gt;" descriptor. |
| medium | FE | Shuffle semantics engine-default, not context-aware | `QueueState.shuffled` is a separate unused flag. |
| low | FE | Previous-button parity | Does not restart current track when >~3s in. |
| low | FE | Repeat cycle wrap/label unverified | Backend `repeatMode` is a separate unused field. |

---

## Key product decisions (locked to make acceptance testable)

1. **Liked Songs = membership + timestamp only.** Liking does **not** auto-add to `user_library`;
   removing from library does **not** unlike. (Unblocks context-menu like actions.)
2. **A "play" = ≥30s listened OR track completed**, `played_at` stamped server-side (no client clock skew).
3. **Queue + resume position persist locally** (client store), not a new server playback-state table;
   `restore()` re-resolves signed URLs to avoid replaying expired ones.
4. **Genre becomes a real queryable `tracks.genre` column**, backfilled from `metadata_json` /
   `track_analysis`, with an `Unknown` bucket. `release_date`/`year` sort is explicitly out of scope.
5. **`pg_trgm` fuzzy search is optional** and must degrade gracefully to FTS if the extension is
   absent; it must not block the tsquery-500 fix or the unified endpoint.
6. **Redis queue is re-scoped as ingest/DJ-staging** and never merged into the listening queue.
7. **Cover art = URL string reference only** (no MinIO upload pipeline yet). `is_public` is stored
   and toggled but no public-playlist browse is built.
</content>
</invoke>
