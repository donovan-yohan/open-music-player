# Native queue motion slice

This slice replaces the immediate-release queue grip with measured insertion preview and an actual Compose animation-completion gate. The authoritative queue remains the Media3 service; the design system holds only ephemeral gesture geometry.

## Implemented

- Canonical generated `SoundQIcon.Drag`, minimum 48dp grip/More targets, flexible wrapping row content.
- Native drag slop, direct pointer follow, variable-height insertion gaps, no preview selection/order/play command.
- Parallel neighbor and lifted-row `Animatable.animateTo` jobs joined through `coroutineScope` before the one-shot occurrence command. Zero-duration reduced motion follows the same completion path.
- Frame-clock held-edge scrolling, canonical density-aware Dp/ms speed, one job per active gesture, pinned lifted lazy row, immediate cancellation on release/retirement.
- Escape ownership shared with the real sheet, pointer cancellation/reversal, revision and disposal retirement.
- Boundary-aware named accessibility actions, Alt+Up/Down, overflow Play/earlier/later/remove, focus return after the accepted order renders.
- A narrow controller command snapshot captures controller incarnation, monotonic timeline revision and original occurrence order. The route captures a revocable `AccountScope`, is closed on disposal, validates the live controller immediately before move, and consumes at most one move. No new playback owner, API route or dependency.

## Inputs and qualification

`design-input/queue-r1/manifest.json` labels a **consumed subset**, not a full Hotate release. It binds the immutable R1 manifest `3a4f3205f09a5fec17dcb5a9789a7f0da11c0a5bd82772194be8196a8ccd55f6`. Canonical additive token/icon inputs and generated native outputs are checked by `scripts/check-design.py`; old provisional release inputs remain historical. Fonts, palette, pins and service pause/Undo/capacity policy are unchanged. Arrangement tokens arrive as additive canonical generated inputs only: horizontal waveform arrangement is not implemented or accepted by this slice.

Host JUnit covers measured insertion, midpoint discrimination, cancellation/reversal, one-shot completion, held-edge frame math, scroll compensation and validated stale-command refusal. The same production helpers are used by the real queue/controller. Native Compose tests cover touch release, accepted cancel/reversal, Escape priority including the real sheet, revision/unmount, reduced motion/enlarged text, held-edge updates and focus/keyboard/semantics. An app instrumentation journey uses the actual Activity, controller and fixture service, asserting preview nonmutation, insertion, selected occurrence and paused Undo.

Native tests are **compiled, not executed** in this lane. Parent must execute the test APKs, inspect motion on the actual target at enlarged text, qualify TalkBack and obtain actual Hotate acceptance. Host math and compilation do not establish pointer/animation, modal Escape, focus or accessibility runtime correctness.

## Commands

Use the existing `android/scripts/check` or Gradle root with the caller's admitted toolchain and worker limits. Required final tasks: `:app:testDebugUnitTest :designsystem:testDebugUnitTest :app:assembleDebug :app:assembleDebugAndroidTest :designsystem:assembleDebugAndroidTest :app:lintDebug :designsystem:lintDebug :verifyDesignInput :designsystem:verifyBoundary`.

New native selectors: `com.soundq.designsystem.QueueMotionTest` (design-system test APK) and `com.soundq.android.QueueReorderJourneyTest` (app test APK, existing HTTPS fixture runner). No production/device/account execution is implied.
