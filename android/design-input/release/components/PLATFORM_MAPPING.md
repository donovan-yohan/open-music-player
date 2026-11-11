# Compose-first platform mapping

This supersedes any engineering implication in the preserved first checkpoint. The accepted architecture is recorded in read-only `soundq-android-compose-20261028/docs/adr/0014-platform-native-android-client.md`: separate platform-native clients, Android first, Flutter behavior baseline, existing Go shared backend. No mandatory Rust application core, old View/JNI adapter, or additional backend is imposed by this design.

## Numerical authority and generated adapter

Edit `tokens/soundq.tokens.json`, then run `python3 -B scripts/build_tokens.py` and `python3 -B scripts/build_tokens.py --check`.

The target adapter is `generated/SoundQComposeTokens.kt`, package `soundq.design.generated`:

- Semantic color aliases become Compose `Color` values, not a second Kotlin palette.
- Layout and target dimensions become `Dp`; font sizes and typography letter spacing become `TextUnit` via `sp` (never `Dp` tracking), preserving native font scaling rather than compressing a bitmap or widget.
- Weight becomes `FontWeight`; cubic curves become `CubicBezierEasing`; durations remain integer milliseconds.
- Local font-family names are mapped as strings. Engineering binds the supplied licensed font files to actual Compose `FontFamily` resources. This generator does not invent Android `R` identifiers or claim that a family-name string registers a font.
- Scalar Kotlin/XML outputs are optional portability exports, not requirements to retain the retired Android implementation.

Export source/alias/drift/negative tests run; Compose property types and semantic values are structurally checked. **No Compose dependency resolution, compilation, Activity, Media3 service or native rendering was executed in this design lane.** Ebi verifies those in the separate engineering worktree.

## Native platform behavior, custom SoundQ visuals

Use platform/Compose sheet and navigation primitives for focus, accessibility semantics, IME/insets and predictive Back. Keep the authored square shape, semantic colors, normal-width type, flat divider rules and icon language. Do not clone the HTML dialog implementation into Android or inherit default rounded Material product styling.

A `ModalBottomSheet`-style lifecycle can supply native sheet state and dismissal. Treat the browser's content-fit/medium/full reference snaps as interaction intent; native system-supported anchors, touch slop, velocity handling and edge-Back take precedence where a direct numeric translation would fight the platform. Preserve every action and cancellation/recovery path. The temporary refinement drawer is a phone overlay, not a mandatory desktop sidebar; an appropriate native modal refinement surface is an allowed documented platform adaptation. Do not add a hand-rolled Back/focus owner merely to reproduce browser mechanics.

At 200% text, allow native measurement and wrapping, grow controls, make sheet content scroll, and expand a sheet when necessary. Do not reduce the `sp` values to fit. Honor system reduced-animation policy while retaining direct gesture-follow, orientation, focus and selection feedback. Native TalkBack actions and explicit More/close/apply controls remain required alternatives to gestures.

## Media surfaces and car UI are separate acceptance families

The phone UI consumes one Media3 playback/session owner. Its compact/full player and queue are projections; no screen starts a second player. Media3 metadata/artwork and available commands must also feed notifications, lockscreen/media previews and headset/Bluetooth/voice controllers. These surfaces need actual account-scoped controller, missing-artwork, unavailable-command, interrupted playback, process recreation and background tests.

Android Auto browses/searches/plays through a standard media-library hierarchy and driver-safe platform UI. Do not transplant phone swipe trays, custom filter drawers, keyboard auth forms or tiny transport controls into the car. Sign-in/account repair happens on the phone. Empty/error/unavailable/loading and explicit account-required messaging must be honest and controller-appropriate. Manifest/service existence is not Auto or assistant support; later real controller/vehicle-emulator/device checks remain open.

## Current official references consulted

- https://developer.android.com/develop/ui/compose/components/bottom-sheets
- https://developer.android.com/develop/ui/compose/system/predictive-back
- https://developer.android.com/media/media3/session/serve-content

These references support the mapping, not a claim that the new app has resolved or exercised those APIs. No library version is selected or installed by this design packet.
