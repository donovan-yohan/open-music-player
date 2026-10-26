# Native Library Favorites

## Supported boundary

The macOS preview exposes Favorites → Like selected track / Unlike selected
track for the selected, loaded Library row. The native menu sends an explicit
`set_favorite` desired state to Rust. Rust calls the existing authenticated Go
Library API. This is not a Liked Songs screen, a filter, playlist membership, or
an independent playback controller.

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

## Remaining parity

A Library-scoped Liked Songs filter, in-row favorite annotation, Android favorite
controls, screenshot-led designer acceptance of the added menu, existing-data
migration, and platform distribution remain separate acceptance gates. Passing
these source checks does not establish full Library or application parity.
