# SoundQ W9 · Light / System appearance

**Owner: Hotate (`hotate-design`). Outcome: bounded additive native implementation input, authored and locally browser-exercised.** Continue the accepted W5/W6/W7/W8 aerospace system; no app-source changes or canonical replacement. This release removes the missing design prerequisite, not native runtime acceptance.

## Consume first

- Open `index.html` directly: complete Settings appearance context with persistent compact player, navigation, populated Library and Up next colors. Open `lab.html` for separate synthetic brightness/save-failure controls and Light/Dark side-by-side phones. Bundled canonical assets; no server, network or account dependency.
- Numerical authority: immutable `canonical/tokens/soundq.tokens.json` → additive `tokens/shared.roles.json` → `tokens/light.overlay.json` **only for Light**. `build.py` imports the byte-identical canonical exporter in `tools/build_tokens.py`. No phone CSS hex palette. `generated/resolved.json` exposes both 278-token maps; original dark values are unchanged.
- Engineering inputs: `generated/dark.SoundQComposeTokens.kt`, `generated/light.SoundQComposeTokens.kt`, `generated/SoundQAppearanceMapping.kt`, `CONTRACT.json`. Generated types include Color / Dp / TextUnit / Easing from the existing exporter; the mode adapter is typed Color roles. No Compose compilation was performed.
- `MANIFEST.json` binds sealed files. `releases/RELEASE.json` names the content-addressed archive and SHA256. Archive includes source, generated mapping, bundled dependencies, tests and original captures, excluding disposable browser profile/cache. Do not edit the sealed release; implement against its contract.

## Visual decisions / rationale

Light is warm paper (`#F8F4EB`), warm surface (`#F0E9DD`), raised deck (`#E6DCCD`), dark ink (`#211A13`), muted ink (`#625749`). Readable orange `#B63D00` and cyan `#006C65` are semantic derivatives, **not replacement primitive brand colors**. The logo, synthetic cover assets, type families, numerical spacing, icon paths and motion tokens remain unchanged. No gradients, shadows, glow, rounded-card redesign or dynamic Material palette.

The Appearance row is one icon-led disclosure. Its bottom sheet uses a conventional single-select radio group (System / Light / Dark), full-row hit area, filled radio and check—not color alone. Only the close action is icon-only with a name. Library/queue are populated static previews of actual resolved roles, not new playback owners or fake reorder controls. The compact player's transport changes reference intent only; no media is decoded.

Semantic/component role coverage includes background/surface/raised/text/muted/rule/input/focus/error/disabled/selection; primary/on-primary and hover/pressed/selected; compact player/progress; sheet/scrim; row reveal; waveform base/beat/playhead/selection/deck/cue/origin. All derive from one selected map. Keep waveform selection as boundary geometry, not an opaque overlay; label cue/origin/beat and retain accepted native dimensions/analysis. This packet does not visually qualify native waveform paint. Decorative subtle rules are not focus/control boundaries and are not claimed to meet 3:1.

## Native integration seam — finite delta

1. Extend the existing appearance preference to System / Light / Dark, default System for absent/invalid input; preserve an already-valid explicit Dark. Use explicit stable serialization, not inferred cross-platform enum ordinals. Selection is device-local; never write auth/library/queue state.
2. Resolve once at the theme boundary from selected preference + actual OS night state (`isSystemInDarkTheme()`). System remains selected during OS changes. Explicit Light/Dark ignores OS brightness. Replace static `SoundQ.colors` access with a resolved composition-local color set; reuse existing spacing/type/motion. Map Material host roles explicitly with light/dark colorScheme adapters—do not inherit dynamic/default Material colors.
3. Reuse SoundQRow, icon button, sheet and existing compact player. Do not key/recreate route, service or queue on mode changes. Preserve mounted content, selection, focus and scroll. A mode change is immediate semantic repaint, not a full-screen animation or sheet exit.
4. Reuse existing preference owner/write result. Failure keeps the prior accepted selection/palette with inline retry. Initial read failure is specified in CONTRACT only; it is not simulated in this browser. Back/close/Escape restore opener focus. Native Back, persistence/restart and actual OS delivery must be exercised by engineering.
5. Existing motion: quick 120ms; row/list 180ms; sheet enter 260ms standard; exit 160ms exit; page 280ms; reduced 0ms; scrim .64. No new waveform/player state controller and no audio calls on selection.

Source inspection confirmed the actual blocker: native Theme.kt is static darkColorScheme; PreferencesScreen.kt says Light/System unavailable; ListeningPreferences.kt has only Appearance.Dark. Parent-supplied Flutter SettingsModel probe reports 18 passing assertions for defaults/three choices/roundtrips/fallbacks. That is parent model evidence, not rerun here and not OS/widgets proof.

## Real evidence

- `evidence/browser-checks.json`: **29/29** locally executed checks, **11 original PNG captures**. Owned installed Chrome, isolated profile, direct `file://` opening; real CDP mouse press/release and keyboard events. Phone 412×915; compact 360×740; side-by-side lab at 1000×1280 with two 412×915 frames.
- System default Light; emulated dark/bright OS changes while System stays selected; explicit Light/Dark ignore opposite brightness; reference selection survives sheet reopening; close/Escape and Back adapter focus return; keyboard radio choice and contained visible focus; failed write retains accepted choice and explicit retry; queue/player identity, position and intent retained; reference transport toggle; compact overflow/visible 48px targets; reduced-motion 0ms and synchronous dismissal; fixture Apply and actual file-origin frame messaging; no captured JS exceptions.
- `evidence/contrast.json`: **22/22** computed-style text/icon/selection-rule/keyboard-focus pairs meet their stated thresholds. Lowest measured ratio 4.7599:1. Body Light 15.66:1; muted Light 6.42:1; current-title orange/surface Light 4.76:1; actual focus Light 5.22:1, Dark 8.90:1. These are browser rendered-role checks, not universal accessibility/native paint acceptance.
- `evidence/token-checks.json`: **24/24** numerical/custody assertions, including all original dark values, all Light non-color values and brand primitives unchanged, identical mode keysets and semantic contrast. `INPUTS.json` hashes all copied W8 canonical inputs/exporter. `SOURCE_REVIEW.json` hashes inspected source/provenance.
- Original captures inspected: Light complete Settings, Dark choice sheet, compact Light sheet, failed-save recovery, final keyboard Light focus, final full side-by-side. Scoped verdict: coherent canonical continuation, no observed blocking overlap/clipping; clear hierarchy and correctly placed cyan focus. At compact height content scrolls above persistent player; targets are not shrunk. Side-by-side was recaptured taller to include full navigation.

Earlier attempts exposed harness key-code/timing/file-origin issues and a real reference Tab-containment defect. Final harness uses rawKeyDown with Windows virtual codes (not macOS native codes), pins the owned W9 target and awaits actual animation completion. Lab uses postMessage, not forbidden file-origin cross-frame reads. The reference now explicitly contains Tab focus. `evidence/attempt-failed.json` preserves the last failing attempt, not release acceptance.

## Limits / custody

All persistent state in this reference is **in-memory simulation across reopening only**. Full reload resets System. OS changes are browser media emulation; Back invokes the reference adapter. No Android storage, process death, native Back/TalkBack/IME/OS lifecycle, native paint, audio, network/API or broad enlarged-text/performance result is claimed. Engineering owns those checks.

Only new W9 design files and the authorized W9 design-report directory were written. No edits to existing tokens/exports, Flutter/native code, configs, accounts, production, staging, commits or paid jobs. No compiler/Gradle/ADB/device actions. No preview server was needed. The owned renderer was closed and its debugging listener verified closed (`evidence/runtime-closed.json`). Direct-file deliverables remain usable without a running process. Reproduction commands and bounded workflow notes are in `RUN.md`.
