# Roadmap — Spotify Parity for Daily-Driver Use

Dependency-ordered, PR-sized implementation plan derived from
[`UX_GAP_ANALYSIS.md`](UX_GAP_ANALYSIS.md). Each chunk is one reviewable PR with concrete
backend/client changes, testable acceptance criteria, and named tests. Lanes: `kani-backend` (Go),
`ika-frontend` (Flutter), `both`. Sizes: S/M/L. This plan was adversarially reviewed; oversized
chunks were split (C2→C2a/b/c, C11→C11a/b/c, C13→C13a/b) and missing dependency edges were added.

Validation contract (this dev box):
- Backend: `go test ./...` with docker postgres (`localhost:5544`) + redis (`:6380`); integration
  tests read `OMP_POSTGRES_TEST_DSN`. Migrations live in `backend/internal/db/db.go` (idempotent).
- Client: `flutter test` + `flutter analyze --no-fatal-warnings --no-fatal-infos` + `flutter build web`.
- File-backed playback/downloads are **mobile-only** and cannot be dogfooded here; VM unit/widget
  tests are the acceptance proof.

---

## Milestones (all of M1–M5 gate "daily-driver ready")

| # | Milestone | Goal |
|---|-----------|------|
| M1 | Local search reachable | Search your own library from the routed screen: sectioned tracks/artists/albums with loading/empty/error states; special-character queries no longer 500. |
| M2 | Playback that keeps playing | Tapping a track/playlist/album plays the whole context; the active queue **is** the engine queue (Add-to-queue / Play-next are audible); queue + position survive an app restart. |
| M3 | Library management | Sort controls, Liked Songs, per-row context actions, tap-to-artist/album, local artist/album pages, wired to the backend. |
| M4 | Home & recently-played | Play events captured with a real ≥30s threshold; Home replaces the stub with Recently-played / Your-playlists / Top-tracks; cleared on account switch. |
| M5 | Playlist parity | Playlists play/shuffle, batch-edit, search/sort, cover+visibility, duplicate-add reported — from anywhere a track appears. |
| M6 | Phase-2 DJ seams (non-gating) | Read-only analysis surfacing + save-playlist-as-mix handoff seam as clean hooks. **No** DJ/waveform tooling built. |

---

## Parallelizable front (no dependencies — start these first)

`C1` (FE) · `C2a` (BE) · `C4` (FE) · `C7` (BE) · `C8` (BE) · `C12` (BE) · `C14` (BE)

These unblock the largest fan-out of client work. **First shipment (highest leverage / lowest risk /
self-contained): C1, C2a, C7** — plus `C4` as the root of the playback critical path.

## Critical path (daily-driver gating)

`C4 → C5 → C8 → C9 → C11a`  (context menu is the convergence point — needs play-from-context,
favorites, and local artist/album pages). Parallel gating branches: `C14 → C16`, `C14 → C15`,
`C12 → C13a`. Search branch: `C1 → C2a → C2b → C3`.

---

## Chunks

### Phase 1 — fundamentals

| id | lane | size | deps | title |
|----|------|------|------|-------|
| **C1** | FE | S | — | Fix SearchService local route + response-shape mismatch |
| **C2a** | BE | S | — | Harden `to_tsquery` (sanitize) in `track_repository.go` **and** `library_repository.go`, preserve prefix match |
| **C2b** | BE | M | C2a | Unified `GET /api/v1/search` endpoint (sectioned tracks/artists/albums, one round-trip) |
| **C4** | FE | M | — | Make `PlaybackState` the single listening-queue source of truth (`playNext` + manual-vs-context ordering) |
| **C7** | BE | M | — | Liked Songs (favorites): `track_favorites` table, like/unlike endpoints, `is_liked` + `liked=` filter on `/library` |
| **C8** | BE | L | — | Library query expansion: duration sort, real `genre` column, local artist/album listings |
| **C12** | BE | M | — | Playlist ops: batch-remove, duplicate-report, list search/sort, `cover_url`/`is_public` round-trip |
| **C14** | BE | M | — | `play_events` schema + record-play + recently-played + top-tracks |
| **C3** | FE | L | C1, C2b, C4 | Local search in routed screen: states, type chips, scope toggle, recent searches |
| **C5** | FE | L | C4 | Play-from-context wiring + Play/Shuffle + now-playing context label |
| **C6** | FE | M | C4 | Queue persistence/resume + shuffle/repeat/previous parity (proactive URL-prefetch dropped as non-MVP) |
| **C9** | both | M | C8, C5 | Local artist + album pages |
| **C10** | FE | M | C8 | Library sort control + pagination/state hardening |
| **C11a** | FE | M | C7, C4, C5 | Per-row context menu + optimistic like toggle |
| **C11b** | FE | M | C7, C8, C9 | Liked Songs collection + genre/liked chips + in-library search field |
| **C11c** | FE | S | — | Read-only analysis Song-info hook (bpm/key, "Analysis unavailable" when null) |
| **C13a** | FE | M | C12, C4 | Playlist multi-select/batch + list search/sort + cover/visibility edit + duplicate feedback |
| **C13b** | FE | S | — | Unify/dedupe playlist-picker (refactor; regression risk isolated) |
| **C15** | FE | M | C14, C4, C5 | Play-event recorder + ≥30s threshold gate + playing-from context tagging |
| **C16** | FE | M | C14, C4, C5 | HomeService + Home sections (replace stub) |

### Phase 2 — DJ-adjacent seams (non-gating, flag-gated)

| id | lane | size | deps | title |
|----|------|------|------|-------|
| **C2c** | BE | M | C2a | `pg_trgm` fuzzy/typo tolerance — optional, degrades gracefully to FTS if extension absent |
| **C17** | both | S | C12 | Save-playlist-as-mix hook: create a `mix_plan` from a playlist's ordered tracks (flag off by default; no DJ UI) |

---

## Acceptance-criteria highlights (per chunk)

- **C1** — `searchTracks`→`/search/recordings`, `searchAlbums`→`/search/releases`, `searchArtists`→`/search/artists`
  (asserted via mocked `ApiClient` capturing the path); a `data`-shaped fixture parses, a `results`-only fixture fails.
- **C2a** — `AC/DC`, `foo!`, `a:b`, `(x)`, trailing `&` return HTTP 200 with a valid body (`data=[]` on no match),
  never 500, for **both** `/search/*` and `/library?q=`; a stored-title prefix token still matches.
- **C2b** — `GET /search?q=` returns one body with populated `tracks`/`artists`/`albums`; empty `q` → 400.
- **C4** — `enqueue(track)` appends exactly one item after current+existing manual items (length +1, index unchanged);
  `playNext(track)` inserts at `currentIndex+1`; manual items are consumed before the context tail.
- **C7** — like → 201 idempotent; unlike → 204; `GET /library` exposes `is_liked`; `liked=true` returns only liked
  with correct total; liking does **not** change library membership.
- **C8** — `sort=duration&order=asc` (NULLS LAST); `genre=` narrows and legacy tracks bucket to `Unknown`;
  local artist/album listing returns only the caller's tracks (cross-user isolation seeded), empty → 200 `[]` not 404.
- **C12** — batch-remove 3 of 5 leaves contiguous positions 0..1 in one txn; mixed add returns added+skipped (union,
  no dup rows); `ListPlaylists?q=&sort=name|track_count&order=` filters+orders; `cover_url`/`is_public` round-trip.
- **C14** — `POST /me/plays` inserts one user-scoped row with server `played_at` (201); missing JWT 401; unknown track
  4xx inserts nothing; recently-played deduped newest-first with isolation; top-tracks by in-window count then recency;
  index on `(user_id, played_at DESC)` asserted via `pg_indexes`.
- **C5** — tapping row *i* of *N* calls `playQueue(N, startIndex=i)`; Shuffle permutes every id exactly once;
  player shows "Playing from &lt;label&gt;" and hides it after a context-less play.
- **C15** — exactly ONE play posted after threshold; ticks/pause/resume/loop of the same play post nothing;
  skip-before-threshold posts zero; retried on failure; cleared on logout/account switch. `context_type` enum must
  match C5's context kinds `{playlist, album, artist, library, queue, search}`.
- **C16** — four sections render with fake data; all-empty → single "Play something to get started" (no spinner, no
  error); pending → skeletons; rejection → error+retry; tapping a tile invokes the player via mock.

---

## Notes & risks

- **C2a is M1-critical and covers two files.** The `to_tsquery` injection exists in both
  `track_repository.go` and `library_repository.go`; both must be fixed or in-library search still 500s.
- **`pg_trgm` (C2c) is deferred to phase-2** precisely because its `CREATE EXTENSION` dependency
  cannot cleanly test both present/absent branches in one CI DB, and it is not required for daily-driver.
- **Cross-chunk contract:** C14 `context_type` enum ≡ C5 context kinds ≡ C15 tags. Keep them identical.
- **Redis queue stays ingest/DJ-staging** and is never merged into the listening queue (C4 owns the split).
- Phase-2 (C2c, C17, and the C11c analysis hook) is seam-only: no DJ/waveform/mix-editing UI is built.
</content>
