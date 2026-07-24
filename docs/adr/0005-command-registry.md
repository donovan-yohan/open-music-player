# ADR 0005: Command Registry Above PlaybackState

Status: Accepted

## Context

Sound Q exposed transport and item actions through individual widgets,
`MixAudioHandler`, and direct `PlaybackState` calls. Desktop shortcuts and
context menus need one stable vocabulary without creating another playback or
collection authority.

## Decision

`CommandRegistry` is the canonical in-app command vocabulary. It sits above
`PlaybackState`; commands delegate transport work to that existing bus.
`MixAudioHandler` continues to delegate OS media actions directly to
`PlaybackState` and does not become the command bus.

Every command exposes a `ValueListenable<CommandAvailability>`. Availability is
derived on demand from `PlaybackState`, queue timeline snapshots, or the
existing item authority. It is never persisted as registry state.

Item commands receive a stable `queueItemId`. The command layer never captures
or mutates a playback queue by index. App dependencies and item targets arrive
through an injected `CommandContext`; the command core does not read Riverpod.

Flutter `Shortcuts` and `Actions` dispatch `CommandIntent` above the navigator.
Context menus, overflow sheets, shortcut hints, and help enumerate the same
registry descriptors so labels and enabled states stay aligned by construction.
Queue-row affordance rules, including the ban on removing the currently playing
entry, are registry availability rules; surfaces consume that result rather
than recreating it.

Space is a global Play / Pause transport key whenever focus is outside a text
field. The action consumes Space even when no track is loaded, preventing a
focused control from activating as a fallback. Focused text fields retain
Space and every other character-producing shortcut. Escape unfocuses a text
field before a later Escape may navigate back.

Apple platforms (macOS and iOS/iPadOS hardware keyboards) use Cmd shortcuts and
Cmd hints. `/` and `?` use character activators, so their physical key location
follows the active keyboard layout.

## Consequences

- New command surfaces extend the registry instead of copying action lists.
- Focused text input retains keyboard input without a global raw-key listener;
  outside text fields, Space is reserved for transport.
- Availability changes follow playback state without synchronization code.
- OS media-key expansion remains a separate runner/platform slice.
