// Playback wiring intentionally stubbed — see ADR 0006 Rung A/B; designed to
// satisfy the StemChannelSource interface defined in the DJ deck lane at
// client/lib/features/dj/models/stem_channel_source.dart
//
// Nothing in this file may touch the audio engine, VoicePool, PlaybackState, or
// QueueTimelineController. It is a pure in-memory adapter over a [StemEdits]
// authoring document (ADR 0001: no second playback or current-track authority).

import '../../models/stem_edits.dart';

/// Availability of rendered stems for a clip, as reported by the backend.
enum StemsStatus {
  /// Separation has not been requested, or the channel set is not
  /// audio-addressable.
  unavailable,

  /// Separation/render is queued or running.
  pending,

  /// Stems exist, but Rung A still plays the pre-rendered mixdown — this stub
  /// never becomes `isAvailable`.
  ready,

  /// Separation or render failed.
  failed,
}

/// One mixer channel exposed to a deck surface.
///
/// Mirrors the DJ deck lane's `StemChannel` exactly so the two branches can be
/// merged onto a single declaration.
class StemChannel {
  const StemChannel({
    required this.id,
    required this.label,
    required this.gain,
    required this.muted,
  });

  final String id;
  final String label;
  final double gain;
  final bool muted;
}

/// Narrow adapter for the future stems5-v1 contract.
///
/// Mirrors the DJ deck lane's `StemChannelSource` exactly.
abstract class StemChannelSource {
  bool get isAvailable;
  bool get isPending;
  List<StemChannel> get channels;
  Future<void> setGain(String id, double gain);
  Future<void> setMute(String id, bool muted);
}

/// Authoring-only [StemChannelSource].
///
/// Reads channel gains out of a [StemEdits] document at [positionMs] and writes
/// edits back through [onEditsChanged]. `isAvailable` is permanently `false`:
/// live per-stem playback is Rung B, and until then a deck must show the honest
/// unavailable state rather than pretend the mixer exists.
class StemEditPlaybackStub implements StemChannelSource {
  StemEditPlaybackStub({
    required StemEdits edits,
    this.status = StemsStatus.unavailable,
    int positionMs = 0,
    this.rampMs = stemRampDefaultMs,
    this.onEditsChanged,
  })  : _edits = edits,
        _positionMs = positionMs < 0 ? 0 : positionMs;

  StemEdits _edits;
  int _positionMs;

  /// Backend separation/render status. Drives [isPending] only.
  StemsStatus status;

  /// Ramp length written into every change point this stub authors.
  final int rampMs;

  /// Called with the new document whenever [setGain] / [setMute] mutate it.
  final void Function(StemEdits edits)? onEditsChanged;

  /// The current in-memory authoring document.
  StemEdits get edits => _edits;

  /// Source-time position that channel gains are read at, and that new change
  /// points are written at.
  int get positionMs => _positionMs;

  set positionMs(int value) => _positionMs = value < 0 ? 0 : value;

  /// Replaces the document without emitting [onEditsChanged].
  void adoptEdits(StemEdits edits) => _edits = edits;

  /// Rung A never mixes stems live; the deck always falls back to the
  /// pre-rendered mixdown or the untouched original.
  @override
  bool get isAvailable => false;

  @override
  bool get isPending => status == StemsStatus.pending;

  @override
  List<StemChannel> get channels => List<StemChannel>.unmodifiable(<StemChannel>[
        for (final descriptor in _edits.channelSet.channels)
          StemChannel(
            id: descriptor.id,
            label: descriptor.label,
            gain: _edits.gainAt(descriptor.id, _positionMs),
            muted: _edits.gainAt(descriptor.id, _positionMs) <= 0,
          ),
      ]);

  @override
  Future<void> setGain(String id, double gain) async =>
      _writeChangePoint(id, gain);

  @override
  Future<void> setMute(String id, bool muted) async =>
      _writeChangePoint(id, muted ? 0.0 : 1.0);

  void _writeChangePoint(String channelId, double gain) {
    if (!_edits.channelSet.contains(channelId)) {
      throw StemEditsFormatException(
        'channel "$channelId" is not part of channel set '
        '"${_edits.channelSet.id}"',
      );
    }
    _edits = _edits.withEvent(
      StemGainEvent(
        channel: channelId,
        atMs: _positionMs,
        gain: gain,
        rampMs: rampMs,
      ),
    );
    onEditsChanged?.call(_edits);
  }
}

/// Honest empty source for clips with no stems at all.
///
/// Mirrors the DJ deck lane's `UnavailableStemChannelSource`.
class UnavailableStemChannelSource implements StemChannelSource {
  const UnavailableStemChannelSource({this.isPending = false});

  @override
  final bool isPending;
  @override
  bool get isAvailable => false;
  @override
  List<StemChannel> get channels => const [];
  @override
  Future<void> setGain(String id, double gain) async {}
  @override
  Future<void> setMute(String id, bool muted) async {}
}
