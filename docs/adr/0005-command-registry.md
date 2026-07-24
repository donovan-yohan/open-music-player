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

## Consequences

- New command surfaces extend the registry instead of copying action lists.
- Focused text input can retain Space and arrow keys without a global raw-key
  listener.
- Availability changes follow playback state without synchronization code.
- OS media-key expansion remains a separate runner/platform slice.
