# Native Library Favorites

## Supported boundary

The macOS preview exposes Favorites → Like selected track / Unlike selected
track for the selected, loaded Library row. The native menu sends an explicit
`set_favorite` desired state to Rust. Rust calls the existing authenticated Go
Library API. The Library toolbar also exposes a Liked toggle. It is a
server-filtered Library projection, not playlist membership or an independent
playback controller.

The menu is unavailable without an authenticated, current Library projection,
valid selection, and idle command boundary. Opening the menu captures account,
epoch, session, track identity, and favorite state. Validation repeats those
checks immediately before dispatch. Replaced menu items and consumed actions
cannot dispatch again. Unrelated scalar playback updates do not invalidate an
otherwise current selection. A missing favorite projection remains unavailable,
including through a `library_unchanged` scalar merge.

## Authority and failure semantics

`SetFavorite { track_id: i64, liked: bool }` accepts only a positive ID present
in the current account's loaded Library. Favorite truth is a separate
`favorite_track_ids` Library projection. The persisted `Track`, `Occurrence`, and
saved queue v1 shapes are unchanged.

- Like uses `POST /library/tracks/{track_id}/like`. Rust accepts HTTP 201 only
  with a matching `track_id` and `liked: true` acknowledgment.
- Unlike uses `DELETE /library/tracks/{track_id}/like`. Rust accepts HTTP 204.
- No optimistic update, mutation replay, or automatic credential-refresh retry
  is performed for these requests.
- An HTTP 4xx response is a refusal. Transport errors, 5xx, redirects,
  unexpected success statuses, and malformed acknowledgments produce
  `favorite_uncertain`. A server write may already have committed. No rollback
  is promised; refresh the Library to reconcile authoritative state.
- Account retirement clears the projection. Revocation during an in-flight
  request suppresses stale local publication, not a server write already made.

The mutation does not replace the playback session, queue, selected occurrence,
position, cached decoder, or persisted queue. Favorites do not add or remove
Library membership.

## Liked Library reads

`LibraryLiked { offset: u32, query: String, sort: String, order: String }`
serializes as `{"command":"library_liked","offset":0,"query":"","sort":"added_at","order":"desc"}`.
The existing `Library` Rust constructor and `library` JSON are unchanged; ABI1,
Track, Occurrence and saved queue v1 remain unchanged. Both variants use the
same authenticated `GET /library?limit=50&offset=…&q=…&sort=…&order=…` reader.
Only LibraryLiked adds `liked=true`; it retains the existing safe-read refresh
retry. It does not change the selected-favorite mutation policy above.

A private successful identity binds exact query bytes, filter, sort and order.
Append with a different identity is refused before HTTP. Failed offset-zero
reads preserve the acknowledged rows and identity. Successful empty responses
are valid projections. Account retirement clears identity. Select builds the
existing queue from loaded rows only, never from the unloaded total. Unlike
changes favorite truth but retains fetched membership until Refresh. A successful
Unlike invalidates only the Liked pagination identity, so an old nonzero offset
is refused before HTTP; explicitly read offset zero to reconcile, then append.
An uncertain favorite outcome also invalidates Liked pagination because the
server may have changed the filtered set. Cancellation after dispatch likewise
retires append authority: revoking publication cannot prove no server write.
Cancellation before dispatch preserves safe pagination. A producer-refused
mutation retains pagination, and an acknowledged Like of an already-liked loaded
row does too.
Plain Library pagination, loaded rows/totals/revision, playback and saved bytes
are unchanged by this invalidation. No mutation or reconciliation is replayed.

The App commits the selected Liked state only on its current decoded successful
reply with an authenticated, current, non-`library_unchanged` snapshot. A held
read retains the old rows/mode, disables conflicting list controls and row-derived
Play selected/details/favorite/append admission, and retires existing disclosure
capabilities. Canonical transport controls remain available. Account/epoch and
request-serial fences reject stale callbacks without clearing newer work.
Malformed/error/immediate refusal paths clear only matching pending intent.
Search/Refresh use acknowledged mode; Load more restarts at zero if edited query
bytes differ. Browsing does not revoke the bridge or replace playback.

Pending and refused reads do not show successful no-match copy. A refusal keeps
the acknowledged rows and places its feedback below the toolbar. An over-limit
query asks the user to shorten the search. Refused pagination with a valid query
asks for Refresh before loading more; only explicit user action reads offset zero.
No automatic recovery read or mutation replay is issued.

Each successful read/page also advances transient `Snapshot.library_revision`.
Full and scalar replies carry this additive authority marker; it is not written
into Track, Occurrence or saved queue v1. A current admitted read acknowledges
its marker and selected mode together. A retired read's new membership cannot
reappear through Next/Previous, queue, favorite, snapshot or scalar replies.
Those replies still deliver current transport, queue, effects and credentials.
An older Library revision cannot invalidate a newer acknowledged read or roll
back its rows; only a newer, unacknowledged revision makes them unavailable.
If Rust's loaded membership differs from the acknowledged native display,
rows stay visible but Play selected, append, favorites, details and Load more
are unavailable. Feedback asks for Refresh. Explicit Refresh/search/filter
success restores authoritative rows; failed recovery leaves them unavailable.
A direct Load more invocation while invalid restarts offset zero. If a current
reply proves a failed read never changed the acknowledged producer revision,
row authority can recover without another read. No automatic reconciliation
request or playback mutation is hidden in this policy.

Revision-less ABI1 reads still decode and may acknowledge fresh legacy browsing
before any revision or retirement uncertainty is known. Once either is known,
a successful read without the marker cannot acknowledge mode, identity or rows,
erase the known revision, or restore row actions. A current marker-bearing read
is required to recover; transport, credential delivery and pending cleanup stay
independent of that refusal.

Device-free producer-to-native regression (supply a freshly built core):

    python3 -B native/tests/library_projection_regressions.py --core-library "$CORE_LIBRARY" --output "$EVIDENCE/library-projection"

This runner executes real ABI1 responses through extracted native Next,
queue-command, command, apply and credential-storage-owner methods. It holds
only delivery and substitutes synthetic HTTP/OS-storage boundaries; no app,
window, keychain or decoder is opened. It includes post-race real core Select,
append and paging authority, both modes/delivery orders and failed recovery.
It also joins the actual favorite menu with HTTP Unlike, stale Load more refusal,
truthful Refresh guidance, explicit recovery and exact no-replay request counts
for empty, Unicode and 512-byte searches; oversized UTF-8 queries retain their
shortening guidance. The Rust favorites suite separately holds a sent Unlike
across same-account Next revocation, commits the synthetic server membership,
and requires pre-HTTP stale-append refusal while retaining the canonical Next
transition and suppression of stale favorite publication. Stale queued and
pre-dispatch cancellation controls retain safe pagination.
Native Clients CI runs the combined canonical/compatibility suite against its
fresh release core alongside the existing macOS feedback checks.

Swift keeps a separate legacy `command(_:completion:)` overload forwarding to
`command(_:result:completion:)`; the explicit result argument is required on the
latter so old trailing no-argument closures cannot bind to the decoded-result
callback under Swift's trailing-closure matching rules.

## Executable checks

Run the shared policy controls with the installed Rust toolchain:

    cargo test --offline --locked --manifest-path native/core/Cargo.toml --test favorites

Run the production native menu and scalar-merge controls on macOS into a new
private output directory:

    python3 -B native/tests/library_favorites_regressions.py --output "$EVIDENCE/library-favorites"

The menu probe compiles the actual `LibraryFavoriteMenu`, snapshot types, and
favorite scalar-merge statement. Its observed App command boundary records
outbound intent; it does not replace the Rust/API mutation tests or actual app
runtime. Controls cover explicit like/unlike, no optimistic update, consumed
and replaced actions, stale selection/account/epoch/session/state, busy/logout,
missing projection, and same-owner scalar updates. Native Clients CI registers
this probe alongside the existing metadata and Library layout regressions.

The disposable Go `native-fixture` helper exposes both existing authenticated
favorite handlers. Its fresh-database, loopback, ownership, and private
credential requirements are unchanged. A runtime check must drive the real menu
and read back authoritative state after acknowledgment. Paginate the API when
checking all 500 fixture rows: the server caps each response at 100, even when a
larger `limit` is requested. Immediate readback can precede asynchronous command
completion; retain that attempt and verify settled state without replaying the
mutation.

## Qualification and remaining parity

A disposable real Go fixture exercised 500 tracks and 100 seeded likes, native
filter/search/paging, the exact loaded filtered queue, playback progress,
Next/Previous, and Unlike followed by Refresh and independent membership
readback. Detailed journeys used a separately identified QA-derived production
app with passive observation and process-local layout controls; the normal
self-contained package was built, signature-checked, and captured at startup.

The actual design reviewer accepted the incremental Liked presentation after
fresh selected/off hover, held/released, compact enlarged free-caret and visible
query-refusal captures. A separate successor fixture retained all 500 tracks and
100 likes through its final authenticated read-only scan. Earlier acquisition
and collector failures remain attributed to their original attempts. Those
captures predate the native-cell-aware toolbar width repair; changed wrapping
and feedback geometry still require fresh affected-runtime/design acceptance.

In-row favorite annotation, Android favorite controls, existing-data migration,
matched and calibrated performance, broader Library parity, and platform
distribution remain separate gates. These observations do not establish
acoustic output, uninterrupted playback, full application parity or Flutter
replacement readiness.
