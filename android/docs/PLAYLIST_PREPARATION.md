# Playlist caller contract — preparation only

No production types or logic are added by this packet. The code blocks are a concrete proposed API sketch, not compiled Kotlin and not evidence of support. The frozen 117-file product remains unchanged. The parent owns admission of the repaired AccountSession/SoundQApi contract; the four core-review findings are NOT repaired here.

## First vertical tracer

`Playlists list → captured private-create form → POST → acknowledged ID → scoped list readback` is the first implementable outcome. Candidate JUnit classes in `app/src/test/kotlin/com/soundq/android/data/PlaylistCandidateTest.kt` reuse the existing `HttpsFixture`, `MemoryStore`, real `AccountSession` and real `SoundQApi`. They do not supply a fake playlist repository, second authenticated client or a fallback implementation.

The temporary reflection bridge only resolves proposed public methods/types and reads their actual state. Missing symbols throw `CAPABILITY_DISCOVERY_ONLY`, before behavior. Such a result is NOT behavioral RED. All candidates are UNEXECUTED because the compiler lane is reserved for the parent's core-repair owner. Compilation is also unverified. No promised symbol or assertion failure grants permission to implement logic. Parent/successor must establish real executable RED against the admitted production caller/transport boundary before implementing behavior; keep capability/setup failures separately.

The candidate scope is deliberately NOT an imagined entire CRUD test suite. It checks list DTO provenance and the first create/ACK/readback tracer, plus uncertain/no-replay, route-retirement and held-account completion controls for that same tracer. Next tests are added one real RED/GREEN slice at a time.

## Concrete immutable domain types

Package: `com.soundq.android.data.playlists`. Existing `TrackId`, `Track`, `AccountScope`, `AccountSession`, `SafeFailure` and `MutationOutcome` remain canonical. Kotlin `List`/`Map` interfaces alone are not immutable: implementations must copy incoming collections and never publish a subsequently mutated backing list. Avoid speculative dependencies to enforce that.

```kotlin
@JvmInline value class PlaylistId(val value: Long) // strictly positive at construction
@JvmInline value class PlaylistGeneration(val value: Long)
@JvmInline value class PlaylistMutationId(val value: Long)

// Explicit complete PUT payload. Never overload null to mean "preserve".
data class PlaylistDraft(
    val name: String,
    val description: String,
    val coverUrl: String,
    val isPublic: Boolean,
)
// A private-create form supplies false explicitly. Rename copies the whole observed
// draft and changes only name. Empty optional server strings normalize to "".

data class PlaylistSummary(
    val id: PlaylistId,
    val name: String,
    val description: String,
    val coverUrl: String,
    val isPublic: Boolean,
    val trackCount: Int,
    val durationMs: Long,
    val createdAt: Instant,
    val updatedAt: Instant,
)
data class PlaylistMemberId(val playlistId: PlaylistId, val trackId: TrackId)
data class PlaylistMember(val id: PlaylistMemberId, val track: Track)
data class PlaylistDetail(val summary: PlaylistSummary, val members: List<PlaylistMember>)
data class PlaylistPage(val rows: List<PlaylistSummary>, val total: Int, val limit: Int, val offset: Int)
data class PlaylistAddAcknowledgement(
    val added: List<TrackId>,
    val skipped: List<TrackId>,
    val playlist: PlaylistSummary,
)
```

Membership is playlist ID + track ID, not listening occurrence ID. `members` order is server order. Reject duplicate member identities in detail rather than using row index as identity. Server counts are not inferred from local rows; unloaded list total stays null. Track DTO adaptation is explicit: playlist detail reads `durationMs`, `artist`, `album`; Library reads `duration_ms`, `is_liked`, `artwork_url`. No `is_liked`/artwork aliases are invented for playlist DTOs which do not supply them. Preserve unsupported/not-owned failures rather than treating display metadata as source permission.

## Captured ownership and feedback

Opaque captures are minted by one repository and checked against that same owner, account scope and route generation. Re-entering the same account, same playlist ID or equal row values does not resurrect a capture. Keep constructors internal and redacted debug output for captured internals. Do not expose bearer tokens or raw request URLs.

```kotlin
class PlaylistListCapture internal constructor(
    internal val repository: PlaylistRepository,
    internal val scope: AccountScope,
    internal val generation: PlaylistGeneration,
)
class PlaylistTarget internal constructor(
    internal val list: PlaylistListCapture,
    val id: PlaylistId,
    internal val detailGeneration: PlaylistGeneration,
)
class PlaylistMemberCapture internal constructor(
    internal val target: PlaylistTarget,
    val member: PlaylistMemberId,
    internal val observedDetail: PlaylistDetail,
)
class PlaylistTrackSelection internal constructor(
    internal val scope: AccountScope,
    internal val selectionGeneration: Long,
    val rows: List<Track>,
)
class PlaylistUndoReceipt internal constructor(
    internal val scope: AccountScope,
    internal val playlist: PlaylistId,
    internal val removal: PlaylistMutationId,
    internal val removed: List<TrackId>,
    internal val observedAfterRemoval: PlaylistDetail,
)

data class PlaylistMutationState(
    val id: PlaylistMutationId,
    val outcome: MutationOutcome, // existing Pending/Confirmed/Refused/Uncertain/ReadbackFailed
    val error: SafeFailure.Reason?,
    val added: List<TrackId>,
    val skipped: List<TrackId>,
)
data class PlaylistState(
    val rows: List<PlaylistSummary>,
    val total: Int?,
    val loading: Boolean,
    val error: SafeFailure.Reason?,
    val detail: PlaylistDetail?,
    val mutation: PlaylistMutationState?,
    val created: PlaylistSummary?, // set only by a validated current create ACK, not reconciliation
    val undo: PlaylistUndoReceipt?,
)
```

For the first tracer, one repository-level mutation can be admitted at a time with explicit refusal/disabled feedback; do not increment a shared page generation for every write and strand unrelated mutation states as Pending (core finding L3). Each admitted mutation has its own completion identity. Detail/list generations fence publication separately. Terminal feedback is sanitized `SafeFailure.Reason`, never server text.

`PlaylistUndoReceipt` binds the removed server identity, originating account and one removal operation. Undo explicitly adds those IDs back to the originating playlist; it is not an index-based local resurrection or a claim that original order is restored. Opening playlist B invalidates A's current detail action captures; A's Undo may either be refused visibly on route retirement or explicitly use A's still-valid receipt in an origin-labelled action. It must NEVER use a mutable selected-playlist ID. The first implementation should choose refusal on route retirement and test it; don't leave policy implicit. Same-account positive Undo still needs real ACK/readback. Cross-account receipt rejection is synchronous and permanent even before auth collector cleanup (core finding S1).

## API and repository signatures

The first candidate binds the exact signatures below using reflection to avoid nonexistent-symbol compiler errors. Return types are real proposed types, not test DTO stand-ins. Replace reflection with direct calls once concrete symbols are admitted; replay final identical behavioral assertions on pre/post source to establish causal evidence.

```kotlin
// Existing sole owner: com.soundq.android.data.SoundQApi
fun playlists(scope: AccountScope, offset: Int): PlaylistPage // fixed first-slice page limit 20
fun playlist(scope: AccountScope, id: PlaylistId): PlaylistDetail
fun createPlaylist(scope: AccountScope, draft: PlaylistDraft): PlaylistSummary
fun updatePlaylist(scope: AccountScope, id: PlaylistId, draft: PlaylistDraft): PlaylistSummary
fun deletePlaylist(scope: AccountScope, id: PlaylistId): Unit
fun addPlaylistTracks(scope: AccountScope, id: PlaylistId, tracks: List<TrackId>): PlaylistAddAcknowledgement
fun removePlaylistTracks(scope: AccountScope, id: PlaylistId, tracks: List<TrackId>): PlaylistDetail
fun reorderPlaylistTrack(scope: AccountScope, member: PlaylistMemberId, newPosition: Int): PlaylistDetail

// Proposed narrow feature owner, blocking calls dispatched by feature ViewModel on IO.
class PlaylistRepository(api: SoundQApi) {
    val state: StateFlow<PlaylistState>
    fun reload(): Unit
    fun loadMore(): Unit
    fun captureList(): PlaylistListCapture?
    fun create(capture: PlaylistListCapture, draft: PlaylistDraft): Unit
    fun retire(): Unit
    // Later tracer signatures, not implemented/tested by this preparation packet:
    fun open(capture: PlaylistListCapture, id: PlaylistId): Unit
    fun captureTarget(): PlaylistTarget?
    fun add(target: PlaylistTarget, selection: PlaylistTrackSelection): Unit
    fun rename(target: PlaylistTarget, completeDraft: PlaylistDraft): Unit
    fun delete(target: PlaylistTarget): Unit
    fun move(member: PlaylistMemberCapture, destination: Int): Unit
    fun remove(member: PlaylistMemberCapture): Unit
    fun undo(receipt: PlaylistUndoReceipt): Unit
}
```

Do not duplicate `authorized`/`wire`, expose private token access, or add an extension that owns another OkHttp client. Adding concrete methods on existing `SoundQApi` is the smallest seam. Account validity alone is insufficient for route/selection retirement before actual network send: the repaired central request path must also check a captured feature validity predicate at admission, each refresh/retry/send and publication. A repository-level check only before calling a blocking API does not close the interceptor/refresh window. Decide that narrowly scoped internal JSON/predicate seam after parent releases the repaired core source; do not preemptively edit its internals here. Public feature callbacks carry opaque captures, not a caller-supplied bearer/URL.

## Exact transport and acknowledgement map

| Operation | Request | Successful response / consumer rule |
|---|---|---|
| List | `GET /playlists?limit=20&offset=n` | `{data,total,limit,offset}`; strict required total/page bounds; initial total unknown, never rows.length fallback |
| Create private | `POST /playlists` all four draft fields, `isPublic:false` explicitly | 201 summary with positive server ID; no created row before ACK; invalidate/read list once; accepted ACK + readback failure = ReadbackFailed, retain ACK separately |
| Detail | `GET /playlists/{id}` | summary + `tracks`; camelCase Track conversion; validate requested ID |
| Rename | `PUT /playlists/{id}` all observed editable fields, only name changed | summary; retain description/cover/public; invalidate detail/list, never sparse PUT |
| Delete | `DELETE /playlists/{id}` | 204 accepted; validate status through shared transport; no invented JSON requirement; scoped list readback |
| Add | `POST /playlists/{id}/tracks` `{trackIds:[...]}` | explicit `added`, `skipped`, `playlist`; reject missing ACK, unknown IDs or impossible multiplicity; reload detail without repeating POST |
| Move | `PUT /playlists/{id}/tracks/reorder` `{trackId,newPosition}` | ordered detail; validate requested member and destination, publish only current target |
| Remove | `POST /playlists/{id}/tracks/batch-remove` `{trackIds:[...]}` | updated detail; issue receipt only after validated removal ACK; failed/uncertain cannot mint Undo |
| Undo | add endpoint for exact receipt IDs | explicit ACK + detail readback, no optimistic resurrection, receipt cannot replay after accepted consumption |
| Save queue | capture visible `PlaybackProjection.queue`, map supported positive track IDs preserving order and multiplicity, then create/add | explicit duplicate report; no selected/position/play intent/timeline changes; unsupported IDs reported as excluded, not silently called saved |

The actual Go repository initializes both add-report slices as empty arrays (`backend/internal/db/playlist_repository.go:376–377`), and the API serializes them directly (`playlist_handlers.go:448–452`). Require both arrays and playlist summary in this native contract; missing/null arrays or missing whole body are not acknowledgement. Preserve server-reported repeated input multiplicity in added/skipped; do not require these arrays to be disjoint by ID when a repeated occurrence is added once then skipped.

Uncertain create/add/delete/remove never auto-replays, including after 401, 5xx, lost response, timeout or ambiguous response shape. A safe explicit reload can reconcile observed state but cannot turn an uncertain create into a proven created identity. On malformed successful write response, outcome must conservatively remain uncertain, not a fresh retry suggestion. Refused mutation preserves prior data and shows safe refusal. Queue save has two acknowledgement stages (create then add): an accepted empty created playlist followed by uncertain add must retain the known playlist ID for reload, not silently create another playlist on retry.

## Product composition after real RED/GREEN

Use the actual `AppGraph.api/session`, one PlaylistRepository, and a feature ViewModel dispatching blocking methods on IO; sign-out must synchronously retire UI captures before scheduling cleanup (core finding L1). Do not use startup/explicit restore as a feature-owned account refresh path (core finding L2). Parent composes core fixes before these callers.

Mount a real Playlists destination from existing product navigation and a return to Library; no Home/Discover placeholder. Use shared `SoundQTabs`, `SoundQSheet`, `SoundQEntryField`, `SoundQFeedback`, `SoundQMediaRow`, existing buttons/icon vocabulary. Do not import feature/domain/HTTP/player types into `:designsystem`. Reuse three-bar side grip/preview/cancel and overflow/TalkBack/keyboard equivalents from `OccurrenceQueue.kt` through a typed stateless visual adapter if member identity differs; no permanent up/down buttons. Form drafts and focus remain native. No new tokens or mutable Hotate edits.

Playlist Play captures the accepted displayed member list, then sends its existing Track values via `AppGraph.rememberTracks` and `ControllerProjection.playContext`; relocate tapped identity after any eligibility filtering. Do not reuse a stale row index or add an ExoPlayer/queue owner. Queue Save captures `PlaybackProjection` on its owning UI/controller boundary and passes only an immutable snapshot into IO. A later unit test must assert exact before/after queue, selected occurrence, position and play intent; a native case must additionally observe no decoder interruption.

## Successor order and pending gates

1. Parent consumes finite core-repair verdict and explicitly admits the successor compiler lane. Do not infer permission from a completed review subprocess or a source read.
2. Rebase/reconcile only the NEW preparation files onto the parent's accepted 117-file successor; never overwrite SoundQApi/AccountSession/ProductViewModel/service with this older snapshot.
3. Compile these candidates with the exact selected command in the private receipt. Record compiler/setup failures as setup, missing symbols as discovery. No execution result exists yet.
4. Establish actual behavioral RED through the admitted caller/API/repository/real HTTPS seam. Concrete declaration-only types may need explicit parent admission; reflection absence alone cannot justify production logic. Run the private-create tracer green before expanding to rename, membership, order, removal/Undo and queue save.
5. Add the mounted Activity journey only after API/repository behavior exists. Required later native path: Library Add → private create → duplicate ACK → detail/play → rename retains fields → grip move/cancel → remove/Undo → queue save preserves playback → logout/retained callback refusal. Instrumentation compilation is not execution.
6. Relevant full unit suite + APK/test APK + lint, independent finite review, then parent-owned isolated native qualification. No emulator/physical-device/install lane is granted here. Do not borrow acceptance from the predecessor core artifacts.

Private release/report paths and exact source/delta hashes live in `playlists/receipt.json` and `IMPLEMENTATION.md`. The downstream consumer is the parent's single admitted successor after core repair. This packet delivers no newly usable playlist feature and no passing/failing test execution claim.
