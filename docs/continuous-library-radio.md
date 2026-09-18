# Continuous own-library radio (reactive MVP)

ADR 0001 authority is unchanged: PlaybackState owns intent/IO, the existing
QueueTimelineController commits queue mutation and next occurrence atomically.
Only natural repeat-off clock exhaustion triggers selection. No Home workaround,
new player, backend discovery, import, or unowned playback is involved.

Library reads use authenticated pages of 100, initial total as a finite scan
bound, deduplication and no-progress termination. IDs must be positive and
library duration at least one whole second (playback JSON uses whole seconds).
Current and pending tracks are hard excluded; up to 20 recently observed
canonical track transitions are a soft oldest-first preference. Fetch plus
source resolution has a shared 15-second deadline. Empty/error/timeout stops
without retries. A later genuine completion may request again.

Fixed MixSession plans persist continuationAllowed=false; legacy mix_plan_
identities migrate at deserialize only. Session edits retain policy. Queue
restore is unchanged and paused. Preview borrows/restores the existing session.

Fresh settings and absent keys select Shuffle library. Explicit persisted Off
is preserved, including old automatically serialized Off: past intent cannot be
reconstructed. Settings remain device-local. A current installation may need a
manual settings change; this implementation does not mutate user preferences.

## Player and system presentation

`PlayerPresentation.fromSnapshot` is a pure value projection shared by full and
mini players, song rows and the AudioService adapter. It adds no lifecycle owner.
Waiting shows “Finding more music…” and Cancel invokes the existing pause intent
fence. Canonical completed shows “Queue ended”; Replay calls existing play and
restarts the selected cue. Ordinary paused playback resumes at its cursor.
A clip-level processing completion or paused cursor at duration alone does not
mean queue exhaustion; Radio Off uses the same canonical completed disposition.
Song rows withdraw current/playing badges during waiting and completed states.
Mini-player selectors include the presentation value but exclude position ticks.

The handler exports loading while waiting, completed for terminal exhaustion,
and actual transport `playing`; it does not fake idle to manipulate Android.
Empty queues advertise no transport actions. Previous/next use existing queue
capabilities; compact indices follow the available transport controls. Hardware
command implementations remain intact. Album art/header forwarding and native
transport glyphs are preserved. Android/OEMs own media-card artwork placement,
size and full-shade composition: app metadata cannot guarantee full-shade art.
The stock audio_service 0.18.18 native completed mapping is paused, not stopped;
its separate native integration and exact-head physical shade test remain gates.

## Limits and UI contract

This is reactive refill after completion, **not gapless**. The canonical
`PlaybackSnapshot.continuationDisposition` is controller-owned:
- `ContinuationDisposition.waiting`: accepted radio attempt, across candidate,
  signing, model load and guarded start IO.
- `ContinuationDisposition.completed`: genuine natural end, including Off,
  finite mix, unavailable source, empty/error/timeout fallback.
- `ContinuationDisposition.none`: ordinary playback or canceled/replaced attempt.

`playing` remains actual transport truth. ProcessingState and
`isResolvingSignedUrl` are not radio-pending indicators. UI consumers should use
this disposition rather than inventing widget-local pending/ended flags.

The production auth owner is `core/auth/auth_state.dart` (not the unused
Riverpod auth provider). Its monotonic `sessionRevision` notifies synchronously
at login/register/logout/password fallback/check intent, before storage awaits.
The existing main auth listener calls the existing PlaybackState.stop, fencing
pending radio and direct resolution immediately, even for A → B → A. No account
ID equality check is used as a substitute for intent invalidation.

Continuation passes its existing intent predicate into `PlaybackEngine.playGuarded`.
It is checked before clock dispatch and at VoicePool's actual Voice.play dispatch,
including late joins. Cancellation does not depend on a post-hoc pause to prevent
a new voice start. Already-dispatched playback is stopped normally. Controller
disposal invalidates synchronously, drains queued work before closing streams,
and disposes the engine without scheduling a new click-audition transport task.
Engine disposal releases voices and its owned clock; externally supplied clocks
retain their existing external ownership/disposal contract.
Canceled model loads may retain an unplayed appended tail; no destructive rollback.

Retained queue history is NOT bounded. Long-soak memory/model rebuilding remains
an explicit follow-up; small batches do not make total session size bounded.
Library edits during paging may omit rows; offline library radio has no local
catalog fallback. Batch signing failures stop rather than bypass ownership.
Physical audibility, notification behavior and exact-head device testing are
outside this slice. HTTP cancellation remains logical; late responses are ignored.
Regression coverage includes auth intent/storage and queued commits, disposal at
model/start awaits, internal resume voice barriers, and repeated natural shuffle exhaustion.
