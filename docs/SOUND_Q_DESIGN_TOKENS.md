# Sound Q Design Tokens

Issue #177 establishes a shared visual language before screen-level redesigns.
`client/lib/app/theme.dart` is the Flutter source of truth.

Desktop composition, typography and interaction follow [Desktop Visual System](DESKTOP_VISUAL_SYSTEM.md). Its aerospace-inspired strict grid, stronger feedback and shadow-free geometry replace prior desktop visual guidance. `client/lib/app/desktop_theme.dart` owns the desktop adaptation; shared semantic tokens remain in `theme.dart`.

## Color roles

| Role | Token | Use |
| --- | --- | --- |
| App background | `AppTheme.background`, `AppTheme.lightBackground` | Dark and light page or shell backgrounds. |
| Surface / raised surface | `AppTheme.surface`, `AppTheme.surfaceRaised` and light equivalents | Fields and small panels; use the raised token for cards and queue rows. |
| Primary / secondary text | `AppTheme.textPrimary`, `AppTheme.textSecondary` and light equivalents | Content and supporting metadata. |
| Outline | `AppTheme.outline`, `AppTheme.inputOutline` and light equivalents | Keep quiet dividers separate from stronger interactive boundaries. |
| Safety orange | `AppTheme.orange`, `AppTheme.orangePressed` and light equivalents | Primary actions, selected state, playback progress, and pressed feedback. |
| Accent | `AppTheme.accent` | Cyan secondary actions, metadata, instrumentation and clear hover/focus feedback; orange retains primary/selected identity. |
| Status | `AppTheme.success`, `AppTheme.warning`, `AppTheme.error` | Outcome and validation meaning; do not substitute orange. |
| Waveform | `AppTheme.waveformBase`, `AppTheme.waveformBeat`, `AppTheme.waveformPlayhead`, `AppTheme.waveformSelection` | Future waveform layers. |
| Player state | `AppTheme.playerPlaying`, `AppTheme.playerPaused`, `AppTheme.playerBuffering`, `AppTheme.playerError` | Future player status indicators. |

## Type, Shape, And Space

Keep readable semantic text roles and full accessibility scaling. Desktop UI/content uses a modern, clean, square/geometric, normal-width face; condensed typography is rejected. Space Grotesk is the next candidate, not a user-approved final selection. Retain locally bundled IBM Plex Mono for technical numeric readouts and script-capable fallbacks. Desktop controls and panels have zero corner radius, consistent painted dimensions and 1px rules on a 4px/8px grid. Shared mobile radius and text tokens remain available only for mobile presentation; they are not desktop design guidance. Measure actual text before sizing controls so labels such as Timeline remain complete; never compress type to force a fit.

## Usage Rules

The dark direction is matte orange/cyan on neutral black; the light theme carries semantic hierarchy on neutral white surfaces without changing system/light/dark behavior. Orange means primary/current/selected identity. Cyan is visibly present in secondary controls and hover/focus feedback. Disabled controls retain the same geometry with muted boundaries. Unfocused input boundaries maintain at least 3:1 contrast against their fill; normal text maintains at least 4.5:1 through combined interaction states.

Desktop uses no drop shadows, glow, blur, gradients, decorative telemetry or tiny sci-fi microtext. Use flat surface changes, crisp state boundaries and continuous dividers instead. Future screen work follows the current desktop visual authority and shared semantic tokens without changing audio or playback behavior.

## Logo Assets

`client/assets/brand/soundq-logo.png` is the canonical historical striped-Q mark, rendered in orange and black with cream and teal. It is generated cross-platform by `scripts/generate_soundq_brand_assets.py`; maskable web icons place the complete canonical mark inside the W3C centered 80%-diameter safe circle.

`scripts/generate_soundq_brand_assets.py` derives the Flutter, web, Android, and extension PNGs and records their source, generator, dimension, and file hashes in `soundq-brand-assets.json`. Generation is pinned to Debian 12 FFmpeg `5.1.9-0+deb12u1` built with librsvg. The `--check` path uses only Python's standard library, invokes no renderer, and is enforced by `scripts/lint delivery`.
