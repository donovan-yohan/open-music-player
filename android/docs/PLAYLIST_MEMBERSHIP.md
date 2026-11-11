# Add one acknowledged Library track to a playlist

This native vertical slice supports Library → track More → **Add to playlist** → paged owned choices → explicit **Add track**. It uses the existing AccountSession and SoundQApi, with no queue, player or Library mutation.

## Authority and recovery

- A Library row capture contains the exact acknowledged object, accepted account and query lifetime. The mounted Library route supplies a separate disposable caller lifetime. Reads and submits claim tickets before IO enqueue; replaced routes, accounts, queries and retained callbacks cannot acquire a new identity.
- Owned playlists are fetched through GET `/playlists?limit=20&offset=…`. Loading, empty, failed and explicit Retry states are distinct; Load more exposes choices beyond the first page. A partial/invalid continuation fails rather than silently completing.
- An explicit one-track POST `/playlists/{id}/tracks` sends `{"trackIds":[id]}` exactly once per admitted intent. Only status 200 and a strict `{added, skipped, playlist}` response matching the requested playlist and partitioning that one ID can acknowledge it. This deliberately single-ID decoder does not redefine the backend's batch/repeated-ID contract.
- Added and skipped acknowledgement are separate visible outcomes: **Added to …** versus **Already in this playlist**. No optimistic count or membership is published. Acknowledgement is published before the follow-up GET detail and owned-list read.
- Failed readback keeps the known acknowledgement. **Check playlist** sends only GETs and retires readback failure on success. A dispatched network/server/malformed-success uncertainty remains **Add not confirmed** even after a successful read. Recovery never replays POST or turns inventory into acknowledgement.
- Account-owned active receipt/no-replay evidence survives sheet/route closure while the process lives. Queued-but-unentered submits settle as refused on close. Already-entered work can finish its receipt but cannot borrow retired read authority; reopen offers explicit Check playlist. Old submit tickets remain consumed. A deliberately new choice is explicit; after uncertainty and reconciliation the uncertain target is excluded from that new intent. A different playlist can be chosen.
- Reopening playlist detail uses its existing reader and receives real membership; this feature does not patch its track list. Library query/Like/row identity and playback occurrence/order/intent remain owned by their existing repositories/controller.

## Verification boundary

Host JUnit tests use trusted loopback HTTPS and the actual API/repository/actions. The ordinary `PlaylistMembershipJourneyTest` uses MainActivity, login and the unchanged ProductFixtureRunner. Its held POST, failed-readback recovery, duplicate, detail membership and unchanged queue assertions are compiled into the test APK, **not executed in this source/build lane**. No emulator, installation, audio, production endpoint request or account write is part of this lane.

Run the app/design-system unfiltered units, app/test APKs and lint with a compatible JDK/SDK and an explicitly private TMPDIR. This lane further restricts Gradle to one worker, one active processor, 1536 MiB heap and in-process Kotlin. Private build receipts retain exact commands and compiler inputs.

Final playlist presentation remains Hotate-owned. This slice consumes existing stable angular, scrollable sheet/row/button/feedback primitives and does not assert designer or native visual acceptance.

## Deferred

Creating inside the picker, batch add, remove, reorder, Undo, rename/delete, save queue, process durability and full playlist parity are not included and have no dead controls here. Independent source review, integrated native journey execution, enlarged-text/compact/device visual acceptance and any later publication remain separate gates owned by the parent.
