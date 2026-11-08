# Queue list — side-grip reorder correction

**Authoring/exercised browser subset, not native acceptance.** Same angular SoundQ direction. Borrow the familiar queue **interaction**, not Spotify colors, typography, pills or surfaces.

## Composition

Each row is one horizontal grid: canonical **Drag** three-bar grip, flexible title/artist/current-state content, then More. No permanent Earlier/Later buttons or second editing-control row. Handle and More use the existing minimum target; do not reduce painted dimensions to make the metadata fit. At enlarged text the content wraps and row height grows; the grip remains reachable.

The main content action selects that precise occurrence. The handle never starts playback. More exposes Play, Earlier, Later and Remove; keyboard Alt+Up/Down on the grip offers reorder equivalents. Native row/grip semantics must additionally provide named Move earlier/Move later custom accessibility actions, disabled at boundaries. Browser tests do not verify TalkBack custom actions.

## State and intents

`reference/queue-drag.js` is reusable visual interaction code: `SoundQQueueDrag.install({onPreview,onCommit,onCancel,onHandleActivate})`. It reads the rendered occurrence identities and emits intent payloads with occurrence, original order, from/to positions. The feature adapter in `reference/listening-release.js` validates the source view/order and signed-out state before applying a reference reducer event. This is not a production queue/controller implementation.

- Pressed: capture pointer on the grip, no activation.
- Dragging: after canonical slop, the row follows the pointer. Neighboring rows interpolate to reveal an insertion gap. Current occurrence, position and playback state remain unchanged during preview.
- Edge scroll: a held pointer in the edge zone moves the scroll viewport and updates the insertion preview. It does not move unrelated identities or select a track.
- Release: settle the lifted row using the canonical list duration/easing; publish the reorder after animation completion, not an elapsed-time guess. A movement from index A to B is insertion, not swapping A and B.
- Cancel/reverse/Escape: original order remains authoritative. First Escape cancels the gesture without dismissing the queue; a later Escape may dismiss the presentation. Pointer-cancel/lost capture/view retirement discard the preview.
- Keyboard/overflow reorder: emit the same occurrence-aware intent. Feature/controller validation remains authoritative. Restore focus to the moved grip after the resulting snapshot is rendered.
- Reduced motion: direct pointer follow and insertion feedback remain; timed settle/interpolation become zero-duration. No shadow, blur, scale bounce or decorative lift.

Native adapter input types are declared in `components/compose/SoundQQueueVisuals.kt`: occurrence/revision/position wrappers, drag metrics, grip visual state, insertion preview and sealed visual intents. This is a source contract, **not a compiled native widget claim**. `:app` supplies validated queue state and executes commands; `:designsystem` owns only visual state and gesture/semantics presentation. Neither the grip nor the row mutates audio, trims, timeline placement, HTTP or account state.

## Canonical bindings

- Handle target: `semantic.dimension.targetMin`.
- Slop: `motion.gesture.slop`.
- Neighbor/release settle: `motion.duration.list`; easing `motion.easing.standard`.
- Reduced duration: `motion.duration.reduced`.
- Edge zone: `motion.queue.edgeZone`.
- Edge scroll speed: `motion.queue.edgeScrollSpeed` (reference CSS px/ms; native uses a density-aware Dp/ms wrapper, not an untyped px/s reinterpretation).
- Geometry: `assets/icons/source.json` → generated `SoundQIcon.Drag`, browser map and SVG sprite. No per-screen grip SVG copy.
- Colors, outlines and spacing remain existing semantic/component roles.

## Distinct from arrangement

This is vertical **queue order**, not horizontal timeline placement. The phone stacked waveform lane editor is explicitly in scope under W24. Its source trim in/out, global start, shared ruler/playhead, preview/commit/cancel, snap/overlap validation, viewport pan/zoom and scrub are separate typed visual primitives; do not substitute row swipe or this vertical grip. Dedicated desktop studio gating does not defer that phone editor.

## Actual evidence so far

`node scripts/queue-drag-tests.mjs` passed **9 grouped checks**, retaining **11 captures** under `captures/releases/queue-grip-r1/`. Receipt: `evidence/releases/queue-grip-r1/browser-tests.json`.

Checks exercise actual touch-like insertion, original/current/time invariants, pointer cancellation, reversal, Escape priority, held-edge auto-scroll, Alt+Up and overflow alternatives, compact/short/wide 130/200% geometry and reduced-motion zero-duration settle. Inspected originals include the settled side grips, in-progress insertion preview and enlarged-text scrolled queue. Native reorder, platform accessibility, controller retirement and Media3 behavior remain unverified.

This document is an authoring checkpoint input. The engineering-consumable immutable release will bind this source, the collection ACK work and the arrangement work at the actual release return; do not consume mutable authoring paths as production dependencies.
