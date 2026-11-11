# Private playlist management

## Mounted slice

The ordinary Playlists detail route composes Rename, member More → Remove from playlist, captured Undo removal, and Delete playlist → Cancel/confirm through the existing SoundQ typed visual primitives. Repeated row actions are icon-led with the shared minimum 48dp target. The immutable canonical design input is Hotate `playlist-r2-dbeedb1c29177d4c` (`components/PRIVATE_COLLECTIONS.md`, `components/compose/SoundQCollectionVisuals.kt`, `reference/playlist-release.js`). No palette, playback controller, Flutter, or Go changes are introduced.

## Ownership decision

Compared extending the existing detail reader with a separate management owner. A separate `PlaylistManagementRepository` is the smaller lifetime boundary: detail still owns acknowledged reads and playback captures; management owns mutation targets, confirmation identity, pending operation, read recovery and captured Undo. The sole shared seam permits publication into the exact acknowledged detail reference, plus its destination generation. Actions claim work before enqueueing. Route exit, account incarnation, old operation, successful recovery, and detail reopen permanently invalidate old capabilities. Account-owned outcome/Undo survives ordinary playlist navigation; old route callbacks do not.

## Actual contracts

- Rename is `PUT /playlists/{id}` with **all four** editable fields. Go replaces description/cover/privacy when omitted. Only exact 200, matching positive ID and complete private draft acknowledges rename; the existing acknowledged detail remains until matching GET readback.
- Remove is Flutter's `POST /playlists/{id}/tracks/batch-remove`, captured unique track ID. Only exact 200, strict returned detail and expected remaining order publishes. The receipt captures account scope, original playlist, removed track and original order/index.
- Undo has no invented endpoint. Read the original playlist, require the captured remaining order, add the member once through `POST /tracks`, validate exact added/skipped arrays, then `PUT /tracks/reorder` to the captured zero-based index. Require acknowledged original order before success. Another visible playlist is never mutated. Add/reorder is not atomic: partial, malformed and uncertain outcomes lock Undo and expose GET-only recovery, never replay add/reorder. An uncertain removal does not manufacture an Undo receipt.
- Delete requires a live feature-owned confirmation; cancellation is inert, consumed/stale confirmations cannot dispatch. Only exact 204 acknowledges deletion. GET recovery distinguishes exact 404 from refusal without retrying DELETE. Music/Library and live listening state are untouched.

## Uncertainty

Pending/refused/uncertain/readback-failed/confirmed and reconciled observations remain separate. Failed reads preserve acknowledged detail. Recovery captures the affected playlist, account, operation, route, current destination generation and acknowledged reference at admission. No automatic write replay or 401 mutation replay. Recovery does not turn an uncertain operation into a write acknowledgement. Fresh explicit actions require current captures after reconciliation.

## Verification boundary

Host TLS tests exercise the actual actions → repositories → `SoundQApi` decoders/transport, captured targets, complete PUT preservation, valid Unicode, malformed ACKs, strict deletion status, uncertain removal, composite Undo partial failure, readback failure, account ABA, queued and held requests, same-ID reopen and old recovery callbacks. `PlaylistManagementJourneyTest` compiles two actual mounted ProductApp journeys including paused Media3 queue preservation, rename/removal/Undo/delete cancel/destructive ACK and uncertain-rename GET recovery. Runtime execution and native visual/IME/accessibility acceptance remain parent integration work; host/build success is not device proof.
