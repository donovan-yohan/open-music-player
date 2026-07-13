# Sound Q Design Tokens

Issue #177 establishes a shared visual language before screen-level redesigns.
`client/lib/app/theme.dart` is the Flutter source of truth.

## Color roles

| Role | Token | Use |
| --- | --- | --- |
| App background | `AppTheme.background`, `AppTheme.lightBackground` | Dark and light page or shell backgrounds. |
| Surface / raised surface | `AppTheme.surface`, `AppTheme.surfaceRaised` and light equivalents | Fields and small panels; use the raised token for cards and queue rows. |
| Primary / secondary text | `AppTheme.textPrimary`, `AppTheme.textSecondary` and light equivalents | Content and supporting metadata. |
| Outline | `AppTheme.outline`, `AppTheme.inputOutline` and light equivalents | Keep quiet dividers separate from stronger interactive boundaries. |
| Safety orange | `AppTheme.orange`, `AppTheme.orangePressed` and light equivalents | Primary actions, selected state, playback progress, and pressed feedback. |
| Accent | `AppTheme.accent` | Small secondary metadata or analysis signal; never a second primary theme. |
| Status | `AppTheme.success`, `AppTheme.warning`, `AppTheme.error` | Outcome and validation meaning; do not substitute orange. |
| Waveform | `AppTheme.waveformBase`, `AppTheme.waveformBeat`, `AppTheme.waveformPlayhead`, `AppTheme.waveformSelection` | Future waveform layers. |
| Player state | `AppTheme.playerPlaying`, `AppTheme.playerPaused`, `AppTheme.playerBuffering`, `AppTheme.playerError` | Future player status indicators. |

## Type, Shape, And Space

Use the supplied fixed type scale: 22-30px headlines, 14-20px titles, 11-14px labels, and 12-16px body text. Font weights define hierarchy, letter spacing remains zero, and compact navigation or control labels stay at 11-14px. Font fallbacks prioritize Japanese-capable system faces. Use `radiusMedium` (8) for cards and compact controls, `radiusSmall` for tight elements, and `radiusLarge` only for larger contained surfaces. Build gutters and component gaps from `space1` through `space6` rather than introducing arbitrary values.

## Usage Rules

The dark direction is matte orange-on-black; the light theme carries the same hierarchy on neutral white surfaces without changing system/light/dark behavior. The orange token means the primary interactive or active state, with `orangePressed` used through Material state resolution and a distinct disabled treatment. The teal accent is reserved for a small secondary signal. Unfocused input boundaries maintain at least 3:1 contrast against their fill; focused and error borders use their semantic colors.

Do not introduce glow, gradients, large ivory panels, dense sci-fi microtext, or a competing teal theme. This slice defines tokens only: future screen work should adopt these tokens instead of hard-coded colors, without changing audio or playback behavior.

## Logo Assets

`client/assets/brand/soundq-logo.svg` is the canonical Sound Q mark. It is a flat safety-orange (`#FF5A00`) stamp on ink black (`#050505`), with no gradients, glows, shadows, or bevels. The 16px extension icon uses the simplified `soundq-logo-micro.svg`; maskable web icons place the complete canonical mark inside the W3C centered 80%-diameter safe circle.

`scripts/generate_soundq_brand_assets.py` derives the Flutter, web, Android, and extension PNGs and records their source, generator, dimension, and file hashes in `soundq-brand-assets.json`. Generation is pinned to Debian 12 FFmpeg `5.1.9-0+deb12u1` built with librsvg. The `--check` path uses only Python's standard library, invokes no renderer, and is enforced by `scripts/lint delivery`.
