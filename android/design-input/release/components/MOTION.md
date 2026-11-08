# Mobile interaction and motion contract — continuation

Status: authored reference contract. Runtime evidence is recorded separately in `MOTION_CHECKPOINT.md`; this document does not establish Android conformance.

## Authority

`tokens/soundq.tokens.json` is the editable numerical authority. `generated/tokens.css` and `generated/tokens.runtime.js` are consumed by the reference. Fresh Kotlin/Jetpack Compose adoption consumes the typed generated Compose mapping; no production files are written here. The old Views/MediaPlayer/JNI/Rust client preview is retired and is not a design constraint. Motion phases use token references, not undocumented spring/bounce behavior.

## Icon language

Project-owned 24-unit SVGs, consistent dark/light foreground role and 1.7-unit stroke, optically centered in at least 48×48 CSS-reference targets. Filled Play and paired Pause strokes deliberately carry transport weight. Bottom-navigation destinations retain concise visible labels: icons do not replace an information architecture. Sort, refine, transport, queue, row More, move-earlier/later, and disclosure are icon-led. Recovery, filter application, form submission and removal retain explicit words. Icons always have accessible names; no tooltip-only or gesture-only command.

Action sheets lead with three icon-led actions (Play, Like/Unlike, Queue). They reflow into vertically stacked icon+label rows at enlarged text without reducing the relative label size. Queue removal says **Remove from queue**, never a contextless trash action. Screen-reader implementations must expose equivalent named actions through Android accessibility actions or the reachable More button. Browser accessible names are reference evidence, not a TalkBack qualification.

## Library row reveal

Anatomy: fixed row action tray behind a translating full-width content front. Leading artwork/fallback, neutral title/artist metrics, orange current state, and explicit trailing More remain intact. Tray actions are non-destructive Like/Unlike and Add to listening queue.

- Left drag reveals actions; right drag closes. Maximum travel binds `motion.row.reveal`. No full-swipe auto-execution. The release threshold binds `motion.row.commitProgress`.
- Before `motion.gesture.slop`, a gesture is undecided. Horizontal movement must dominate vertical by `motion.gesture.axisRatio`; dominant vertical movement yields to normal scrolling. No whole-list horizontal drag trap.
- Gesture-follow is direct displacement, clamped at closed/revealed bounds; no rubber band or overshoot. Release settles with `motion.duration.settle` / `motion.easing.standard`.
- Short/slow partial drags return closed. Reversing toward closed before release closes instead of committing an earlier displacement. Pointer cancellation restores the gesture's starting open/closed state. Interruption/navigation closes safely. One row at most is open.
- Tray controls stay inert during raw drag; deliberate settled reveal enables them. A swipe's synthetic click cannot start playback. Tap an open row's content to close it; a separate subsequent tap plays. Tapping outside or navigating closes the tray.
- Explicit alternatives: More opens the same actions; focused row ArrowLeft/ArrowRight reveal/close, Escape closes. Native implementation should add named accessibility actions but must not require them for discoverability. The inline one-time hint explains swipe and More.
- Focus/pressed/selected are separate roles. Selection and current identity must not depend on an animated entry; no all-row entrance stagger.

## Collection mutations

Queue entries have **occurrence IDs distinct from track IDs**. Duplicate tracks can be moved/removed independently. FLIP-style vertical position interpolation binds `motion.duration.list`; it communicates changed order rather than replaying decorative entrances. Insertions use a short translation from one grid step plus opacity. Removal collapses only the removed row, commits when its animation resolves, and presents a persistent Undo action. No arbitrary animation-duration timer is the state owner. Reduced-motion removal commits without timed collapse.

Removing the active occurrence pauses and selects its successor (or prior last entry); removing the final occurrence leaves disabled transport. Undo restores the occurrence list but never auto-resumes audio. Preparation replies are fenced by serial; cancellation/removal prevents a stale delayed simulated preparation from starting another entry. These are reference semantics, not a claim that native queue parity is implemented.

## Phone presentation model

No persistent desktop sidebar is imposed. Library refinement is a **temporary right-side drawer**; short choices/track actions are **bottom sheets**. Full player and listening queue are near-full-height sheets. Navigation remains underneath, inactive while a modal is open.

All use the same flat square boundary, dark scrim with `motion.scrim.opacity`, no blur, shadow, scale or spring. Bottom entry/exit translates on Y; right drawer translates on X. Opening uses `motion.duration.sheet`, closing `motion.duration.exit`. A partial transition can be cancelled/retargeted; a stale completion cannot close a replacement panel.

### Drag, snap and dismiss

- Drag begins only on the dedicated 48px header/grab target, not arbitrary content. Sheet content remains independently vertically scrollable. Drawer content is never converted to a sideways scroll trap.
- Medium sheets fit their content up to the `motion.sheet.medium` viewport-fraction ceiling; full snap binds `motion.sheet.full` of the declared visual viewport. At 200% text the default sheet opens full to retain readable content.
- Upward header drag can expand medium to full; downward drag follows the pointer. Release below `motion.sheet.dismissProgress` settles back, while sufficient displacement or deliberate downward velocity (`motion.sheet.dismissVelocity`) dismisses. Reverse/cancel returns to a coherent snap, not an in-between stranded surface.
- Drawer header follows rightward dismissal. Partial/cancelled dismissal returns to open. Close button and scrim are explicit alternatives. Keyboard handle Up/Down offers full/medium snap without dragging.

### Focus, Back and retained state

Native HTML dialog modal behavior provides browser focus trapping and background interaction exclusion. On open, focus enters the panel heading. On nested disclosure return, the previous panel scroll position is restored; on final close, focus returns to its opening action, with a compact-player fallback if that DOM node no longer exists. Escape is intercepted as panel Back, not uncoordinated `dialog.close()`.

Library query, active filters, scroll and listening state survive player/queue presentation. Refinement is a draft until Apply. Closing the drawer does not mutate results; a retained draft is available on reopening. Filter reset and Apply remain named text actions.

VisualViewport resize informs a reference keyboard inset. The panel's scroll area and maximum height remain bounded above the declared inset; inputs are not placed behind fixed transport. This is a browser adaptation only. Actual Android WindowInsets, IME composition/autofill, gesture navigation, predictive Back, native focus restoration and TalkBack remain **unverified** pending native execution. Ebi maps the intent to platform-native Compose sheet/gesture/inset/accessibility/navigation APIs and a single Media3 playback owner against the existing Go backend. The HTML mechanics are not a mandated Android implementation.

## Reduced motion

`prefers-reduced-motion: reduce` maps all timed travel/settle to `motion.duration.reduced`. Direct finger-follow remains spatially truthful; release reaches the same state without timed interpolation. No action disappears. Scrim/focus/current-state feedback remains. Tests must check zero-duration recorded transitions and state completion, not simply disable CSS while JS still animates.

## Evidence requirements

The motion checkpoint must include actual touch-like pointer paths, cancellation/reversal and vertical-scroll arbitration, one-open-row closure, modal focus/Back, nested player/queue return, drafts, mutation transitions and 200%/compact/reduced-motion cases. A browser screencast replay and timestamped intermediate captures must show movement; static settled images alone cannot close this requirement. No browser receipt qualifies native Android behavior.
