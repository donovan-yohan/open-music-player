# Task: Issue #292 — client unification cleanup batch

Worktree: this directory, branch `chore/292-unification-cleanup`, based on origin/main (f988290 — includes #286/#287/#285-slice-1 merges).
Work ONLY here. Conventional commits (this can be 2-4 commits by theme). Closes #292.

ISSUE-292.md in this worktree root is the authoritative work list (audit-verified fold-ins with file:line at baseline 244046d — LINE NUMBERS HAVE DRIFTED since; re-locate each item, and some may already be partially resolved by the merged PRs #294-#297. Verify each item's current state before acting; report any already-resolved item as such).

## Sequencing + caveats on top of the issue text

1. **Dead-code deletions first** (core Track + mb_suggestion.dart, LibraryTrack + TrackTile.fromLibraryTrack, dead parallel search UI, dead local playlist tables, MixNowPlayingInfo/nowPlayingStream + loadSequentialQueue): confirm zero references before each deletion (grep imports + symbol uses in lib AND test); a deletion that breaks a test means the item was NOT dead — investigate, don't force.
2. **Rename models/track.dart Track → QueueTrack**: mechanical but wide; keep it one dedicated commit so review is trivial. Update import aliases that existed only to disambiguate.
3. **analysisPlaybackFields helper + single playback-payload builder**: NOTE — #294 added isLiked/sourceUrl threading with tri-state semantics (emit only when known) and #295 added quality facts to extras with camel-over-snake precedence. The unified builder MUST preserve those exact semantics (read shared/models/track.dart toPlaybackJson and playback_source_resolver extras handling first; the tri-state liked rule is load-bearing — ADR-0004). albumTrackToPlaybackJson gains analysis forwarding via the helper.
4. **Queue vocabulary**: remove dead repeatMode/shuffled from client queue_state.dart + copyWith sites. Backend: delete uncalled Service.SetCurrentPosition; do NOT do the broader playqueue→import vocabulary rename this pass (schema-touching; the issue defers it to "next schema-touching change") — just leave a code comment marking the intent.
5. **Shared "play collection (shuffled)" helper**: decide ONE semantic — recommended: one-shot shuffle does NOT enable the controller's persistent shuffle flag (matches current dominant behavior), but uses a single injectable-RNG helper. All four call sites migrate; note the semantic in the helper's doc comment.
6. **Resolution-policy extraction** (shared ordering function for PlaybackSourceResolver + DefaultEngineAudioSourceResolver + conformance test) and **voice_pool._stableUriIdentity fold into audioObjectIdentity**: behavior-preserving refactor; the conformance test is the point — write it FIRST against both current implementations, then extract.
7. **formatBytes helper** with GB branch replacing the three copies (cache display was rewired by #294 — locate current call sites fresh).
8. **fadeInMs/fadeOutMs removal from MixSessionClip**: verify still unconsumed after #296 (envelopes derive from overlap; #296 did not wire them). Remove fields + serialization; keep fromJson tolerant of old snapshots carrying the keys (ignore them). Persistence round-trip test.

## Boundaries
- Behavior-preserving except where the issue explicitly says otherwise; full suite must stay green with NO test-expectation changes except tests that referenced deleted dead code or renamed symbols.
- Do not touch: liked semantics (ADR-0004), crossfade/MixSession behavior (#296), command registry surfaces (#297), downloads-store vs playback-cache separation, backend beyond the single SetCurrentPosition deletion.
- Client suite baseline: 1014. Backend: golangci + go test must stay green (backend delta is one deletion — if SetCurrentPosition has tests, delete those too as dead).

## Verification (record exact results)
- `cd client && flutter analyze` (9 known pre-existing infos; deleting dead files must not add new ones) and `flutter test`.
- `go -C backend vet ./...` + `go -C backend build ./...`; run backend unit tests that compile without infra; note that integration tests need infra (skip cleanly).
- `scripts/agentic-harness`; `git diff --check origin/main...HEAD` at final head.
- Adversarial self-review before finishing; record findings/fixes.

## Report
REPORT-292.md at worktree root: per issue item — current-state verification (done/already-resolved/deviated), files, commands + exact results, commits, residual risks.
