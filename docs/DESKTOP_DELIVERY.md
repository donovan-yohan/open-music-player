# Desktop Delivery

## Product target

SoundQ desktop retains the mobile library, discovery, downloads, queue, playlists, listening settings and canonical audio behavior. Desktop also provides the mixed-playlist production workspace. Use the strict, edge-aligned operating-console composition in [Desktop Visual System](DESKTOP_VISUAL_SYSTEM.md), not a uniformly enlarged mobile screen.

Persistent navigation, independently scrolling content and docked transport remain functional requirements. Visual composition follows SoundQ's aerospace/space-program architectural direction: consistent grid cells, flat shared dividers, visible orange/cyan interaction and deliberate bundled typography. Existing feature routes and playback commands remain authoritative.

## Current implementation boundary

The local macOS implementation is built and verified. This is not a notarized public release or a claim that every authenticated mobile journey has been exercised on desktop. Source is branch `feat/four-deck-audit`, base `34688c31d191289ab0eb42c586c7ed3a61883c6b` plus preserved uncommitted changes. Nothing was committed, pushed or deployed.

Local verification targets macOS arm64 first. Windows and Linux require their own audio host, plugin, packaging and runtime qualification. A macOS build cannot certify them.

## Verified local delivery

- Self-contained macOS release app embeds the mixer/CoreAudio host and pinned Opus decoder. Native dependencies are system libraries only. Cold and three changed-code incremental builds retain valid signatures; the canonical build fails if strict/deep signature verification fails. Signing is local ad-hoc, not Developer ID/notarized.
- Ordinary production startup and real macOS plugin smoke passed: secure-storage roundtrip, SQLite, local WAV loading without playback, and login startup. No OS audio output was started.
- Desktop sidebar, independently scrolling content, full-width canonical transport, mixes/imports/downloads, Connected devices and Jam are reachable. Compact/mobile navigation is preserved. Enlarged navigation labels get measured width; Jam actions and dialogs retain at least 40px targets.
- Final canonical client gate passed 2,785 tests with zero failures. Ten opt-in capture/benchmark tests were skipped in that invocation. The eight real-font route matrices and target audit passed separately, as did the earlier listening capture. All five native mixer CTests passed. Analysis and formatting passed; macOS release, web release and Android debug builds passed.
- Rendered production-root fixtures cover four window sizes at 1×/2× text, real dialogs, keyboard navigation, route coverage and scroll reachability. All eight rendered invitation QR images independently decoded to the exact fixture payload. These are controlled fixtures, not production-account journeys.
- Connect and Jam independent reviews found defects; the demonstrated account/credential/recovery and decision-lifetime defects were repaired and their bounded independent re-reviews passed. Real disposable PostgreSQL/Redis tests exercise production JWT/router/generation boundaries and guest capability isolation.
- Native profile-mode scrolling of actual production rows at 1440×900/DPR2 used five measured runs and 4,782 frames. UI/raster p95 were 1.256/1.027ms; two frames exceeded 16.667ms in either stage. An earlier cohort retained larger raster stalls. This is a baseline, not a speedup or smoothness guarantee; physical trackpad input, remote artwork, database cost and audio were excluded.

## Remaining shipping gates

- Physical audio, device switching/interruption, sustained playback and authenticated full-feature journeys on desktop still need qualification. Existing source/build/test parity is not physical parity proof.
- The desktop transport has no master-volume slider because the canonical owner exposes no master-volume API. Do not add local-only volume truth to imitate a reference layout.
- Connected devices show account-private listening reports; remote control, playback transfer and synchronized multi-device sound are not implemented.
- Jams provide host-approved requests and host-only playback, not guest audio streaming. Public guest hosting/origin/ingress and an outside-tailnet phone scan remain unconfigured and undeployed.
- Developer ID signing/notarization, installer/update distribution, Windows/Linux packages and x86_64 execution remain unqualified.

## Acceptance matrix

| Surface | Required desktop behavior | Evidence required |
| --- | --- | --- |
| Startup | Launch without external native library environment variables or plugin exceptions | Release app, embedded-library inspection, process/startup logs |
| Account | Login, refresh, logout and account-change playback isolation | Existing auth tests plus desktop keychain/plugin checks |
| Listening | Existing queues, repeat/shuffle, seek, volume, media controls and restoration | Canonical-owner tests, desktop plugin composition, manual audio qualification |
| Library | Search/filter/sort, likes, local browse, metadata/actions and artwork | Existing regression suite plus desktop rendering/navigation |
| Downloads | Explicit offline assets and bounded playback cache retain separate ownership | Existing storage/cache tests, desktop database/path composition |
| Discovery and playlists | Existing routes and actions remain reachable | Navigation tests and rendered checks |
| Mixed playlists | Four simultaneous occurrences, saved curves, record/save/replay, import/export | Existing native/performance tests plus desktop host packaging/runtime checks |
| Layout | Useful widths at 1024, 1440, 1920 and 2560; compact fallback and enlarged text | Layout tests and captured desktop renders |
| Keyboard | Existing command registry, visible focus, accessible navigation and transport | Keyboard/action regression tests |
| Motion | Short feedback and weighted panel transitions; reduced-motion support | Duration/behavior tests and rendered interaction checks |
| Scrolling | Lazy lists, stable artwork/layout, bounded playback rebuilds and native trackpad behavior | Rebuild tests plus profile frame timing on a named workload |
| Distribution | Self-contained app and reproducible package | Native dependency/link inspection, install/run check; signing/notarization separately qualified |

## Motion and performance policy

Use motion to explain state change. Hover/focus feedback should be quick. Larger transitions can settle more slowly, with a decelerating curve. Do not animate continuously for decoration or add a synthetic smooth-scroll loop over the operating system's trackpad momentum.

Honor platform reduced-motion settings. Avoid broad theme or player subtree rebuilds on position notifications. Keep scrolling collections lazy and constrain artwork decode size to actual display requirements when a profile demonstrates a decode bottleneck. Preserve large-text layout instead of fixing row extents blindly.

Frame-time claims must identify build mode, viewport/display refresh rate, workload, sample count and observed UI/raster timing distribution. Widget tests prove rebuild boundaries, not frame rate. Fixes need comparable baseline/candidate measurements; no percentage claims from unrelated runs.

## Connected listening

Connected devices belong to one authenticated account. Each installation/process publishes an expiring device presence lease and a narrow projection of its canonical playback snapshot. Device presence is not a second local playback controller.

The first user-facing slice is visibility: device name/type, current listening and last report. Do not advertise transfer or remote control until command acknowledgement, stale generation/version rejection, logout isolation and offline recovery are implemented. Distinguish simultaneous open clients from synchronized audio output.

Device presence and host heartbeats must survive ordinary desktop focus loss and minimization while the process continues. Panel polling is visibility-bound; the listening lease is not. Hard OS suspension may prevent execution and lets the server lease expire. Do not describe best-effort mobile background reporting as a guaranteed background wake service.

## Jams

A signed-in user can host. A guest should be able to open a share link or scan a QR code, choose a display name, view current listening and contribute to a bounded host queue through a pared-down web UI. The host owns playback. Guest capability never grants private library enumeration, signed audio URLs, arbitrary playback control or account access.

Host and guest routes have separate authentication scopes. Join capabilities need cryptographic entropy, expiry/revocation, bounded membership and request rates. Queue mutation requires version/idempotency handling so retries do not duplicate requests. Host offline/end must be visible, not an indefinitely live room.

The existing tailnet API default remains unchanged, as does `OMP_API_BASE_URL`. An internet guest experience requires an explicitly chosen reachable HTTPS origin and reviewed deployment/CORS/rate-limit configuration. Local source work does not publish a public endpoint or silently open the home-lab backend.

## Carried audio work

Live structural arrangement Apply remains separate from draft editing/replay. Native non-one tempo stretching and annotated detector accuracy remain unqualified. The desktop layout does not erase these limitations.
