# Flutter Native Player Readback

## Scope

The source-pinned `just_audio` 0.10.6 fork adds an experimental, default-off
`AudioPlayer.soundqNativeReadback(capability: ...)` method. It observes the
already-active macOS AVPlayer and its current item. It does not create a player,
activate an idle platform, or issue play/pause/seek/source/volume/speed commands.
Android and iOS native readback are unavailable. Ordinary playback remains the
existing just_audio implementation.

This is an endpoint diagnostic, not a qualified performance baseline or proof of
continuous audio-active scrolling. `PlaybackState` and `JustAudioVoice` compose
the read through the existing canonical playback owner. Existing nonaudio fixture
reports and cohorts retain their original schema and exclusions.

## Explicit opt-in

Dart requires profile mode and the compile define
`SOUNDQ_NATIVE_PLAYER_READBACK=true`. Native macOS requires process environment
`SOUNDQ_NATIVE_PLAYER_READBACK=1` and a generated
`SOUNDQ_NATIVE_PLAYER_READBACK_TOKEN` of 64 lowercase hexadecimal characters.
The caller supplies that capability to the method. Capabilities must be kept in
private fixture memory, never source, logs, receipts, or result payloads. Native
refusal uses fixed error codes and does not expose exceptions or URLs.

The Dart method refuses before method-channel dispatch when disabled, invalid,
disposed, or inactive. It uses the current platform's existing per-player
channel and verifies that exact platform identity remains current after the
await. Sampling has a two-second caller timeout; timeout does not mutate player
state.

## Observation domain

The native method uses only its directly owned AVPlayer and current AVPlayerItem
on the main thread. Successful schema `soundq.just-audio.native-readback.v1`
contains:

- platform player UUID, process ID, opaque source UUID, plugin current index;
- opaque observed player/item generation witnesses, not pointer addresses;
- raw `mach_absolute_time` before/after ticks and conversion numerator/denominator;
- raw native player and item CMTime value/timescale/epoch/flags;
- native player rate, time-control status, player/item status, and error-presence flag.

Zeroing weak identity observations do not retain retired playback resources.
Strong local player/item references protect one read. Stable before/after native
ownership checks bound the snapshot but do not make all AVFoundation properties
atomic. A generation witness identifies sampled objects within this plugin
instance; it is not a globally durable playback identity or proof that no
intermediate transition occurred.

The method accepts only standard UUID platform/source identifiers to prevent
arbitrary source labels leaking into the report. URLs, headers, account IDs,
paths, tokens, and native error descriptions are excluded. A caller must still
join and fence its own current account/session/occurrence and source provenance.
Raw samples alone do not authenticate those caller labels. The application
wrapper fences account retirement, replacement intent, transport requests and
session/cue/occurrence around each await. Its opaque single-use source-read
capture binds the existing pool source owner and a permanently revocable read
scope, admitting only one fully loaded, ready, nonterminal legacy assignment.
Source/mapping/assignment/cardinality changes and stop/disposal revoke before
queued mutation; errors cannot be undone by a later ready event. Failed native
unload still retains the independent source lease. Sampling holds neither the
scheduling queue nor the native mutation queue and never delays retirement.
Ordinary clock/gain work, equivalent metadata allocations and future-only edits
that preserve the active source/time mapping remain admissible. `pool_generation`
remains diagnostic: scheduling advances it during healthy playback, so it is not
an observation fence within or across reads.

Native current-time interpolation and positive endpoint rate/cursor advancement
are not proof of continuous uninterrupted media rendering, device routing,
audibility, acoustic output, or physical presentation. Consumers must validate
readiness, errors, identities, clocks, and meaningful advancement independently.

## Reproducible source custody

`client/third_party/just_audio_provenance/upstream.json` records the exact
installed-package runtime files used, their hashes and modes. Original LICENSE
bytes are unchanged. This is installed-cache provenance, not independently
verified upstream archive authentication. The reversible
`native-readback.patch` lists every local vendor modification. No package-cache
file is edited.

Run the offline integrity check from the client root:

    python3 -B test/just_audio_vendor_check.py

It requires the exact file inventory, unchanged license, declared method, path
override, and exact upstream bytes after reversing the patch. The default-off
Dart regression uses the real public AudioPlayer method and checks no native
initialization/dispatch. It is a refusal control, not a native sample fixture.

Additional controls exercise the extracted production native method against
synthetic player/item facades and the extracted Dart method against synthetic
method-channel responses. They test refusal/identity/error boundaries, not real
playback. The endpoint oracle and ordinary Library DTO conversion have separate
regressions in `test/native_player_profile_probe_test.dart`.

`voice_pool_source_read_capture_test.dart` exercises real pool ownership with
held resolver/load/sample/unload boundaries. The enabled application-wrapper
controls in `playback_state_native_readback_contract_test.dart` run only in an
exact-production private extraction with a declared profile-mode alias and real
pool/engine; ordinary debug tests deliberately skip those controls. These
synthetic controls do not execute the package/native AVPlayer sampling path or
replace actual profile-root runtime acceptance.

The opt-in `integration_test/native_player_profile_probe.dart` mounts the real
application root, loads a Library row through the authenticated API, converts it
through the production `Track.toPlaybackJson()` path and invokes ordinary
playback. It emits `soundq.flutter.native-player-diagnostic.v1` with two native
endpoint snapshots and fixed stage/refusal diagnostics. Readiness, rate, errors,
canonical/native identity, positive cursor advancement and raw clock ordering
must pass. The native item cursor and player cursor remain separate raw values.

One private macOS profile pilot observed positive native endpoint progress;
earlier failed attempts remain retained. This does not qualify a population,
uninterrupted rendering, acoustic output, frame budget, matched comparison,
durable data migration or another platform. Private package/source manifests and
runtime reports are not publication artifacts. No native sampling acceptance
follows from the Python integrity check alone.
