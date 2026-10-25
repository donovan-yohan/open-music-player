# Mixed Playlist Performance Contract

## Product intent

A mixed playlist stores an authored performance, not only song order. It retains clip placement, source trims, transitions and stem gain automation. Saving and sharing a mix must preserve those edits. Shared metadata does not grant access to the underlying audio or stem artifacts.

Desktop has a dedicated playlist production surface. Mobile keeps a listening-oriented layout and lighter editing controls. Both consume the same versioned mix document and playback owner.

## Playback invariants

- The arrangement may span an hour or longer and contain many clips. At most four track instances may sound simultaneously. Duplicate occurrences of one recording consume separate deck cursors.
- The native output clock is authoritative. UI timers observe transport; they do not schedule sample starts, loops or gain events.
- A future edit never pauses, reloads, seeks or resets the buffers, cursor, gain ramps or stem settings of an unaffected on-air instance.
- Drag preview is local editor state. A released edit validates the entire candidate and prepares changed material before submission. Publish accepted state only after the renderer acknowledges application.
- An invalid, unready or unsupported edit leaves the last accepted arrangement and healthy playback intact. Never truncate a fifth overlap.
- Moving or retrimming an on-air clip must not implicitly seek it. An audible reposition is an explicit command with a defined transition policy. Do not borrow a fifth transport for an unnoticed replacement.
- Keep compressed files on disk and bounded decoded windows in memory. Active and imminent assets hold leases through decoder retirement. Preparation work has count, byte and concurrency budgets and must prioritize active and selected material over distant speculation.
- A long arrangement requires native future-event scheduling or an equivalent deadline-safe prepared schedule, not Dart wakeups at every clip boundary. The immutable native arrangement schedule provides that mechanism; bounded PCM residency must still keep up with playback.

## Stem performance recording

- Each disjoint stem has a continuous linear gain in `[0, 1]`. The default is `1`; `0` means that bus contributes silence. Instrumental is a group of non-vocal buses, not an additional full-band asset summed with them.
- Record mode captures slider movements into the existing `StemEdits` document. With record off, controls are temporary performance overrides unless explicitly saved by an authoring action.
- Record only a control accepted by the playback owner. A failed or superseded native command must not create a fictitious recorded movement.
- Events are anchored to source milliseconds and immutable source/model/channel-set identity. Moving a clip changes its placement, not the recorded source timestamps. Trims select which recorded events are audible.
- Preserve continuous fades through deterministic source-time ramp evaluation. Existing v1 short `rampMs` events can represent a long gesture through a bounded sequence of sampled points. Do not silently reinterpret a short de-click ramp as an arbitrarily long fade.
- Define punch/loop/seek recording behavior explicitly. Edits must not erase unrelated channels or existing automation outside the recorded region. Undo treats a recorded gesture as a coherent edit.
- Save/read/reorder must round-trip supported automation without loss. Optimistic version conflicts must not overwrite someone else's edits. Unknown unsupported data must fail visibly rather than disappear.
- Encoded member integrity, decoder-ready PCM, accepted control revision and actual audible output are separate gates. Do not present authoring-only faders as audible controls.

## Beat, BPM and snapping priorities

Treat tempo estimate, beat locations, bar/downbeat phase and phrase landmarks as separate facts. A plausible BPM does not establish the correct beat phase or first beat of a bar.

- Investigate half/double-tempo mistakes, sparse intros, breakdowns and variable-tempo material separately.
- Anchor four-beat and sixteen-beat landmarks to an accepted musical grid. Taking every fourth array element from an arbitrary beat list does not establish a downbeat.
- Sixteen-beat boundaries are grid-derived authoring landmarks unless phrase structure is independently established. Do not label every grid group a detected musical phrase.
- Manual BPM, half/double correction, beat anchor and bar phase must remain available. Reanalysis must not move source-time automation.
- Diagnose automix mapping independently from detection. Verify source-to-timeline integration, rate-curve continuity, onset alignment and end geometry with exact probes before attributing audible failure to the model.
- Do not replace the detector or tune confidence thresholds from synthetic tests alone. Use annotated music and retain calibration/holdout separation through the existing Audio MIR evaluator. Third-party estimates are reference signals, not ground truth.
- VirtualDJ reverse engineering is read-only evidence gathering. Static mechanics do not establish detector accuracy or recover proprietary trained models.

## Acceptance gates

1. Long-arrangement edits preserve unaffected output sample-for-sample in the real native renderer, including pending preparation and repeated future moves.
2. Fifth-overlap rejection preserves all authored instances and the accepted revision.
3. Actual authenticated stem manifest to verified local members to aligned decoded PCM to native gain changes works through the application owner.
4. Record, save, reload and replay reproduce known gain movements. Clip moves/trims and seek/loop recording follow the declared policy.
5. Desktop editing and mobile listening round-trip the same document without hidden data loss.
6. Beat/BPM repairs have runnable regression evidence and annotated holdout results before claiming musical accuracy gains.
7. Actual device output, focus, route changes, background behavior and sustained four-deck load receive separate qualification. Offline tests are not mobile audio acceptance.

## Current implementation boundary

The application now composes optional prepared-stem playback into its existing playback engine. Android and macOS select the packaged native library; web remains unsupported for native output. An explicit native library override remains available for development but is not needed by the bundled macOS app. Ordinary listening queues retain the legacy backend. Verified encoded members feed a decoder isolate and bounded rolling PCM windows. The app control path has fake-device integration coverage, not physical output qualification.

The application uses the native compiler to render saved source-time stem curves, negative clip gain and linear/equal-power fades. Native, sanitizer, real-FFI and saved-JSON-to-decoded-PCM application gates pass. Prepared playback and restore do not require original signed stream URLs. Non-one playback rates and all explicit rate segments remain unsupported in this prepared path, even when a document requests constant-tempo locking. Do not silently substitute a different tempo policy.

The dedicated desktop editor now explicitly plays, pauses and stops through the existing playback owner. Record mode saves only identity-verified native gain acknowledgements after whole-plan preflight and a second acknowledged metadata revision. Record-off movements remain live-only; Restore recorded mix clears overrides after acknowledgement. Versioned manual Save and exact readback remain the persistence boundary. The real desktop-to-native-to-save composition has focused test coverage, including original stream signing being unavailable.

Recorded gesture timestamps use canonical pre-submit source snapshots, not an atomic first-applied sample timestamp. The UI preserves existing interior points across potentially skipped source regions because there is no public seek-discontinuity token; it does not yet provide contiguous overwrite/punch takes. Undo/Redo and structural edits remain local draft changes until explicit replay. Future native revisions can preserve unaffected on-air clips, but the desktop does not yet expose a live structural Apply operation. The separate DJ view remains a two-deck direct-voice surface and has not been migrated to this native arrangement owner.

Source-to-timeline integration, tempo-policy persistence and anchored four-/sixteen-beat snapping have regression coverage. No new annotated-music holdout result establishes improved detector accuracy.

Authenticated portable exchange exports `soundq-mix` version 1 metadata without server track IDs or audio credentials. Import resolves source hashes only through the recipient's own library and refuses missing or ambiguous sources before creating a new saved plan. Real HTTP/JWT/PostgreSQL round trips cover occurrence identity and automation preservation. Client copy/paste dialogs are mounted in the saved-mix picker and editor; unsaved drafts cannot be mistaken for exported saved state. No public playback link or shared-audio grant is implied. Nothing in these gates establishes deployment, physical audibility or sustained mobile performance.

Import revalidates source identity, ownership, ambiguity and known duration inside the same transaction that creates the plan. It briefly locks the recipient's library and its source rows to fence concurrent replacements and new duplicate matches. This verifies identity at import time, not permanent source immutability. Client import confirmation compares raw POST and GET documents before model normalization; ordinary saved authoring reads reject lossy gain/ramp/time conversions and unsupported clip fields.

Recording acceptance distinguishes the command's valid pre-submit capture from its later acknowledgement cursor. A capture inside a clip remains recordable when the acknowledgement crosses that clip's end. A value-identical save readback changes the saved baseline without invalidating pending controls through a new list identity. Explicit transport intent changes, route changes and real document edits still cancel stale work.

Explicit seek and every local/timeline scrub entrypoint invalidate the recording intent synchronously, before transport commands wait in the canonical queue. Native scrub commands drain an already-submitted gain acknowledgement before pausing the callback consumer. This preserves cancellation without stranding an accepted native revision behind a paused device.
