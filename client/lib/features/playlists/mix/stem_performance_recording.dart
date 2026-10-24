import '../../../models/stem_edits.dart';

/// A captured command, not an assertion that a renderer applied it.
class StemPerformanceSample {
  StemPerformanceSample._(this._owner, this.event, this.gestureId, this._edits);

  final StemEdits _edits;

  /// Prospective document for plan-wide admission, not an applied revision.
  StemEdits get prospectiveEdits => _edits;

  final StemPerformanceRecording _owner;
  final StemGainEvent event;
  final String gestureId;
}

/// Immutable editing state over the existing per-clip `stemEdits` v1 document.
/// Owns no clock, position, transport, persistence or renderer.
///
/// A gesture punches only its channel: accepted forward samples remove known
/// points in `(previousSourceMs, capturedSourceMs]` and write the new endpoint.
/// Its previous endpoint remains. The first sample, a new gesture, or backward
/// source time replaces only the exact `(channel, atMs)` key. Repeated loop
/// timestamps are last-write-wins, not appended takes. Call
/// [withSourceDiscontinuity] on every seek/loop boundary so a forward jump
/// cannot erase the skipped source range. No end-of-gesture restore is added:
/// each endpoint holds until that channel's next persisted point.
class StemPerformanceRecording {
  StemPerformanceRecording({
    required this.clipId,
    required this.sourceFileHash,
    required this.stemModelVersion,
    required this.edits,
    this.maxEvents = 2048,
  })  : recordingArmed = false,
        liveOverrides = const {},
        _lastSamples = const {} {
    if (maxEvents < 1 || maxEvents > 2048 || edits.events.length > maxEvents) {
      throw ArgumentError.value(
          maxEvents, 'maxEvents', 'Event budget is 1..2048');
    }
    if (clipId.trim().isEmpty) {
      throw ArgumentError.value(clipId, 'clipId');
    }
    if (!RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(sourceFileHash) ||
        sourceFileHash != edits.sourceFileHash) {
      throw ArgumentError.value(sourceFileHash, 'sourceFileHash');
    }
    for (final event in edits.events) {
      if (!edits.channelSet.contains(event.channel) ||
          event.atMs < 0 ||
          event.atMs > 9007199254740991 ||
          (event.beatIndex != null &&
              (event.beatIndex! < 0 || event.beatIndex! > 9007199254740991))) {
        throw ArgumentError.value(
            event, 'edits.events', 'Unsafe event identity/time');
      }
    }
    if (stemModelVersion != edits.stemModelVersion ||
        !edits.hasCanonicalStemModelVersion) {
      throw ArgumentError.value(stemModelVersion, 'stemModelVersion');
    }
  }

  StemPerformanceRecording._({
    required this.clipId,
    required this.sourceFileHash,
    required this.stemModelVersion,
    required this.edits,
    required this.maxEvents,
    required this.recordingArmed,
    required Map<String, double> liveOverrides,
    required Map<String, (String, int)> lastSamples,
  })  : liveOverrides = Map.unmodifiable(liveOverrides),
        _lastSamples = Map.unmodifiable(lastSamples);

  final String clipId;
  final String sourceFileHash;
  final String stemModelVersion;
  final StemEdits edits;

  /// Per-clip budget including existing events, 1..2048. Plan-wide event/body
  /// limits remain the save boundary's responsibility. No points are evicted
  /// or time/gain-quantized to make an overflowing gesture fit.
  final int maxEvents;
  final bool recordingArmed;
  final Map<String, double> liveOverrides;
  final Map<String, (String, int)> _lastSamples;

  StemPerformanceRecording withRecordingArmed(bool armed) =>
      _copy(armed: armed, lastSamples: const {});

  /// The existing position owner must signal seeks/loop boundaries (including
  /// forward jumps). The next accepted point begins a new punch, not a bridge.
  StemPerformanceRecording withSourceDiscontinuity() =>
      _copy(lastSamples: const {});

  /// Drops transient editor overrides only. Applying the resulting replay
  /// gains to a renderer remains the caller's responsibility.
  StemPerformanceRecording withLiveOverridesCleared() =>
      _copy(overrides: const {}, lastSamples: const {});

  /// Validates identity, finite continuous gain, v1 ramp and prospective budget
  /// before the caller sends any control command. Does not mutate this value.
  /// [capturedSourceMs] is absolute source-file time supplied by the existing
  /// position owner, never timeline/trim-local time. [gestureId] must change for
  /// each new gesture. Throws [ArgumentError] for invalid inputs or [StateError]
  /// for capacity/unknown interior-event conflicts; callers must surface these.
  StemPerformanceSample stage({
    required String clipId,
    required String sourceFileHash,
    required String stemModelVersion,
    required String channel,
    required int capturedSourceMs,
    required double gain,
    required String gestureId,
    int rampMs = stemRampDefaultMs,
  }) {
    if (clipId != this.clipId ||
        sourceFileHash != this.sourceFileHash ||
        stemModelVersion != this.stemModelVersion) {
      throw ArgumentError(
          'Sample identity does not match this clip/source/model');
    }
    if (!gain.isFinite || gain < 0 || gain > 1) {
      throw ArgumentError.value(gain, 'gain', 'Must be finite in [0,1]');
    }
    if (capturedSourceMs < 0 || capturedSourceMs > 9007199254740991) {
      throw ArgumentError.value(capturedSourceMs, 'capturedSourceMs');
    }
    if (rampMs < stemRampMinMs || rampMs > stemRampMaxMs) {
      throw ArgumentError.value(rampMs, 'rampMs', 'Must be in [1,250]');
    }
    if (!edits.channelSet.contains(channel)) {
      throw ArgumentError.value(channel, 'channel');
    }
    if (gestureId.trim().isEmpty) {
      throw ArgumentError.value(gestureId, 'gestureId');
    }
    StemGainEvent? previous;
    for (final existing in edits.events) {
      if (existing.channel == channel && existing.atMs == capturedSourceMs) {
        previous = existing;
        break;
      }
    }
    final event = previous?.copyWith(gain: gain, rampMs: rampMs) ??
        StemGainEvent(
          channel: channel,
          atMs: capturedSourceMs,
          gain: gain,
          rampMs: rampMs,
        );
    final document =
        recordingArmed ? _recordedDocument(event, gestureId) : edits;
    if (document.events.length > maxEvents) {
      throw StateError('Stem event budget exceeded; sample was not staged');
    }
    return StemPerformanceSample._(this, event, gestureId, document);
  }

  /// Call only after the external control path accepts [sample]. A failed
  /// command is discarded, leaving this value unchanged.
  /// Serialize stage -> external acceptance -> recordAccepted on the owning
  /// clip revision; no parallel pending samples or mode/seek changes in between.
  /// A stale acknowledgement throws instead of being silently rebased. This
  /// caller assertion does not itself prove native application or audibility.
  StemPerformanceRecording recordAccepted(StemPerformanceSample sample) {
    if (!identical(sample._owner, this)) {
      throw StateError('Sample belongs to a different editing revision');
    }
    final event = sample.event;
    return _copy(
      document: sample._edits,
      overrides: {...liveOverrides, event.channel: event.gain},
      lastSamples: recordingArmed
          ? {
              ..._lastSamples,
              event.channel: (sample.gestureId, event.atMs),
            }
          : const {},
    );
  }

  StemEdits _recordedDocument(StemGainEvent event, String gestureId) {
    final last = _lastSamples[event.channel];
    final punching =
        last != null && last.$1 == gestureId && last.$2 <= event.atMs;
    if (punching) {
      for (final existing in edits.events) {
        if (existing.channel == event.channel &&
            existing.atMs > last.$2 &&
            existing.atMs < event.atMs &&
            existing.unknownKeys.isNotEmpty) {
          throw StateError('Punch would erase an event with unknown fields');
        }
      }
    }
    return StemEdits(
      channelSet: edits.channelSet,
      sourceFileHash: edits.sourceFileHash,
      stemModelVersion: edits.stemModelVersion,
      beatGridRef: edits.beatGridRef,
      unknownKeys: edits.unknownKeys,
      events: [
        for (final existing in edits.events)
          if (!(punching &&
              existing.channel == event.channel &&
              existing.atMs > last.$2 &&
              existing.atMs <= event.atMs))
            existing,
        event,
      ],
    );
  }

  /// Offline envelope value at an absolute source-file millisecond. Events
  /// ramp from the value reached at their start, not from the previous target.
  /// Seeking needs no remembered cursor; live overrides are deliberately ignored.
  double replayGainAt({required String channel, required int sourceMs}) {
    if (!edits.channelSet.contains(channel)) {
      throw ArgumentError.value(channel, 'channel');
    }
    if (sourceMs < 0 || sourceMs > 9007199254740991) {
      throw ArgumentError.value(sourceMs, 'sourceMs');
    }
    var startGain = 1.0;
    var targetGain = 1.0;
    var startMs = 0;
    var rampMs = 1;
    double valueAt(int ms) {
      final elapsed = ms - startMs;
      if (elapsed >= rampMs) return targetGain;
      return startGain + (targetGain - startGain) * (elapsed / rampMs);
    }

    for (final event in edits.events) {
      if (event.atMs > sourceMs) break;
      if (event.channel != channel) continue;
      startGain = valueAt(event.atMs);
      targetGain = event.gain;
      startMs = event.atMs;
      rampMs = event.rampMs;
    }
    return valueAt(sourceMs);
  }

  StemPerformanceRecording _copy({
    bool? armed,
    StemEdits? document,
    Map<String, double>? overrides,
    Map<String, (String, int)>? lastSamples,
  }) =>
      StemPerformanceRecording._(
        clipId: clipId,
        sourceFileHash: sourceFileHash,
        stemModelVersion: stemModelVersion,
        edits: document ?? edits,
        maxEvents: maxEvents,
        recordingArmed: armed ?? recordingArmed,
        liveOverrides: overrides ?? liveOverrides,
        lastSamples: lastSamples ?? _lastSamples,
      );
}
