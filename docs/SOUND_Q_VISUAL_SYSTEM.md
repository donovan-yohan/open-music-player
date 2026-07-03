# Sound Q visual system

Refs #176, #177, #178.

Sound Q is the product brand. `SQ` is the short mark. `三九` is the stamped glyph identity. The UI should feel like a modern Japanese music poster translated into a usable player: bold, flat, orange on black, and queue/DJ-forward.

## Brand names

- Primary product name: **Sound Q**.
- Short mark: **SQ**.
- Glyph mark: **三九**.
- Avoid falling back to “Open Music Player” in user-facing client chrome. Keep old names only where protocol/package compatibility needs them.

## Core palette

| Role | Token | Hex | Usage |
| --- | --- | --- | --- |
| Ink black | `AppTheme.inkBlack` | `#050505` | App/page background, icon backing, stamp field. |
| Poster black | `AppTheme.posterBlack` | `#0B0A08` | Broad shell blocks that need a barely lifted black. |
| Surface | `AppTheme.darkSurface` | `#14110D` | App bars, sheets, fields, quiet panels. |
| Raised card | `AppTheme.darkCard` | `#211A13` | Cards, mini-player, queue/list rows. |
| Safety orange | `AppTheme.brandColor` | `#FF5A00` | Primary actions, active states, progress, selected navigation, brand marks. |
| Orange pressed | `AppTheme.orangePressed` | `#D84400` | Pressed/hover states when needed. |
| Ivory text | `AppTheme.lightText` | `#F4EDDC` | Primary text and small separators. Do **not** use as large app backgrounds. |
| Muted text | `AppTheme.greyText` | `#A89F90` | Secondary text, inactive icons, helper labels. |
| Divider | `AppTheme.divider` | `#32281F` | Thin separators and outlines. |
| Optional teal | `AppTheme.tealAccent` | `#39C6B6` | Tiny metadata/status accent only; never a second primary brand color. |

Semantic success/warning/error colors stay separate from orange so user feedback does not look like branding.

## Typography

Use bold, condensed-feeling hierarchy with wide tracking on labels. Current Flutter uses system font fallbacks (`Noto Sans CJK JP`, `Noto Sans JP`, `Roboto Condensed`, `Roboto`, `Arial`) until custom font assets are committed.

- Page/display titles: uppercase-friendly, `w800`/`w900`, slightly negative or tight spacing.
- Section labels and badges: all-caps or glyph labels, wider tracking, safety orange or muted ivory.
- Body text: readable first. Do not force poster styling into long paragraphs or metadata blobs.
- `三九` glyphs can be used as a small stamp/motif, not as filler spam.

## Composition rules

- Prefer matte blocks, hard edges, poster-grid alignment, and deliberate negative space.
- Use crisp diagonals/cropped blocks sparingly for motion and queue/planning energy.
- Queue/player screens should feel like a DJ planning surface: waveform/progress can be graphic, but still readable.
- Desktop should avoid dense dashboard panels; mobile should avoid tiny controls.

## Do not do this, bro

- No neon/glowy cyberpunk dashboards.
- No giant ivory desktop panels.
- No noisy microtext fields everywhere.
- No gamer-router orange sludge.
- No random teal as a second brand theme.
- No gradients in the logo/app icon.

## Logo and icon rules

The canonical source lives at `client/assets/brand/soundq-logo.svg`; generated PNG/app-icon variants are produced by `scripts/generate_soundq_brand_assets.py`.

- The logo is a boxed/stamped geometric mark: orange on ink black, with `三` strokes hinting at an S and the `九`/queue-tail form hinting at a Q.
- Keep it flat. Do not add glow, bevel, blur, drop shadow, or gradient.
- Keep enough border/negative space to survive at 16px extension-icon size.
- Use ivory only next to the mark in surrounding UI copy; the app icon itself stays orange/black for small-size clarity.

Regenerate assets after editing the SVG:

```bash
python3 scripts/generate_soundq_brand_assets.py
```

## First implementation targets

- Theme tokens in `client/lib/app/theme.dart` are the source of truth for Flutter surfaces.
- Login/splash/app icons should use `AppTheme.brandLogoAsset`, not placeholder assets.
- Future desktop/mobile/player issues (#179–#181) should reuse these tokens instead of hard-coded orange/grey values.
