# SoundQ Desktop Visual System

## Authority

This is the current desktop design authority. It replaces previous Spotify-inspired spacing, floating inset panels, rounded Material defaults, low-alpha-only hover guidance and system-font-only direction. Source snapshots and historical test receipts describe previous implementations, not current visual requirements. Do not use them as competing design instructions.

## Surface and identity

SoundQ desktop is an operating console for a music library and playback arrangement. Draw from aerospace instrumentation, golden-era space-program industrial graphics, Mirror's Edge architectural clarity and restrained cyberpunk contrast. Produce an original SoundQ interface, not a game HUD replica. No decorative telemetry, invented controls, fake status labels, glows or drop shadows.

Resolve the in-app identity as a composition: a deliberate existing-emblem/SoundQ wordmark lockup in the expanded masthead, and a clearly visible emblem in the compact masthead. Do not rely on the operating-system titlebar to identify the app. Preserve useful structural header space; no promotional slogan or wholesale logo replacement is required.

Home must retain meaningful real-data sections, not flatten tracks and playlists into interchangeable poster cells. Recently played and top tracks remain identifiable source sections with contiguous shared-rule track regions. Playlists use an explicit collection identity and track counts. Use a deliberate main/secondary composition at wide widths and reflow that hierarchy at compact widths. Sparse data remains sparse; do not manufacture content or a hero banner.

## Grid and edges

- Use a 4px base unit and 8px layout rhythm. One-pixel rules may sit between grid cells.
- Panels meet their structural dividers. Remove the floating 12px outer content moat. Borders terminate at shared junctions, not arbitrary inset cards.
- Adjacent controls in one group share painted height, baseline, icon scale and border weight. Invisible hit padding alone does not establish visual alignment.
- Use 48px cells for the transport cluster, 40px minimum secondary control cells, 20px secondary glyphs and 24px transport glyphs. A primary action differs by color, not accidental size. Grow or reflow at enlarged text without clamping.
- Navigation is a column of full-width, consistently pitched rows/cells. Hover and selection cover the intended row, not only a small icon badge. Tooltips are not navigation labels floating out of alignment.
- Preserve useful whitespace inside content, but do not substitute padding for hierarchy. Align headings, toolbars and content to deliberate shared tracks.

## Typography

Use a modern, clean, square/geometric, normal-width desktop UI face. Condensed typography is explicitly rejected; do not revive IBM Plex Sans Condensed or use compressed lettering to fit the grid. Space Grotesk is the next implementation candidate, subject to actual rendered user/designer judgment, not an already approved font choice. Keep appropriate system fallback for scripts it does not cover. Retain IBM Plex Mono for timestamps, BPM and technical numeric readouts, with tabular figures. Use locally bundled licensed assets in rendered acceptance tests, not Ahem or a font-name assertion alone. No runtime font requests or new font package is required.

Keep readable body sizes and full accessible text scaling. Control labels such as Timeline must be fully visible at normal desktop widths. Measure actual glyph bounds and reflow the toolbar when necessary; do not shorten Timeline to Time, crop it, scale it down or rely on a tooltip to repair its primary label.

## Color and interaction

Retain SoundQ orange #FF5A00 for primary/current/selected identity and cyan #39C6B6 for secondary actions and explicit pointer/focus feedback. Use neutral surfaces and readable neutral text when interacting.

Ordinary artist and secondary descriptive metadata use neutral text so that cyan actions and focus are distinct at rest. Reserve cyan metadata for genuinely meaningful technical distinctions, not every repeated artist line. Keep section hierarchy, content identity and current playback more prominent than repeated outlines.

Hover must be obvious across the whole control or row. Use a deliberate resolved surface change or color inversion plus a crisp border, not barely visible stacked translucent ink. Keyboard focus remains separately visible while hover/press coexist. Disabled controls retain the same cell geometry and a visible muted boundary, never an actionable hover fill.

Preserve the independently established normal-text 4.5:1 contrast minimum for all reachable state compositions, including focus plus hover plus held press and release fades. Keep feedback visible without reintroducing the native ink stacking failure. Selection remains recognizable during hover.

## Elevation and shapes

Zero corner radius on desktop control and panel surfaces. No pills, drop shadows, glows, blur, raised elevation or hover scaling. Boundaries come from flat surfaces, thin continuous rules and clear state color. Native operating-system window controls and circular semantic indicators need not be redrawn as square buttons.

## Behavior and scope

Keep canonical playback, command availability, account isolation, native feedback queues, lazy scrolling and progress-only rebuild boundaries. Mobile behavior below the existing 960px desktop breakpoint remains unchanged unless separately requested. No synthetic smooth-scroll controller or second navigation/playback owner.

Desktop playlist creation has one clearly labeled New playlist action in its structural toolbar, not competing header-plus and floating-plus controls. A useful empty-state creation path may replace that entry when empty. Compact navigation and intentionally truncated playback/playlist names require reliable pointer and keyboard disclosure with full accessible names.

## Acceptance

Verify the actual application root and nested theme overrides. At 960, 1200, 1440 and wide desktop windows, check neighboring painted control rectangles and icon centers, continuous divider junctions, full Timeline label glyph bounds, disabled geometry, obvious hover and native keyboard activation. Include real bundled fonts and enlarged text. Contrast tests must cover combined native states. Native screenshots establish appearance; tests, builds, reviews and installed delivery remain separate claims. Run only one disposable native preview and close/reap it after validation.

The actual hotate-design profile reviews screenshot-led brand, UI and UX acceptance. Return revised fresh native screenshots and observed journey outcomes at compact/wide widths until she explicitly accepts the design. Current widget fixtures, previous native captures and passing tests are not that sign-off. Capture provenance and limitations without placing audit disclaimers in the product UI.
