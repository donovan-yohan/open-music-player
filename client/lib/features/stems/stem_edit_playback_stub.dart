// Playback wiring intentionally stubbed — see ADR 0006 Rung A/B. The
// StemChannel / StemChannelSource / StemsStatus / UnavailableStemChannelSource
// declarations this file implements now live in the single shared home at
// client/lib/core/stems/stem_channel_source.dart, which is re-exported below so
// existing importers of this file keep compiling.
//
// Nothing in this file may touch the audio engine, VoicePool, PlaybackState, or
// QueueTimelineController. It is a pure in-memory adapter over a [StemEdits]
// authoring document (ADR 0001: no second playback or current-track authority).

import '../../core/stems/stem_channel_source.dart';
import '../../models/stem_edits.dart';

export '../../core/stems/stem_channel_source.dart';

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
            honestyCopy: descriptor.honestyCopy,
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
