/// Pure, side-effect-free brain for the play-event recorder.
///
/// It answers a single question: for the track currently playing, should we
/// record exactly ONE play event yet? The rule is "record once a continuous
/// listen crosses [threshold] (default 30s) OR the track completes". Every
/// subsequent position tick, pause/resume, or loop of the SAME track posts
/// nothing; the counter only re-arms when the track actually changes.
///
/// The class is deliberately free of streams, timers, and network calls so it
/// can be unit-tested by feeding it position/duration/track-change/completion
/// events and asserting exactly one "record" signal.
class PlayRecordDecider {
  PlayRecordDecider({this.threshold = const Duration(seconds: 30)});

  /// Minimum continuous listen time before a play is recorded.
  final Duration threshold;

  String? _trackId;
  bool _recorded = false;

  /// The track the decider is currently armed on, or null when playback is
  /// stopped. Exposed for wiring/telemetry; not required for the decision.
  String? get currentTrackId => _trackId;

  /// Whether a play has already been recorded for the current track this play.
  bool get hasRecorded => _recorded;

  /// Feed the id of the now-playing track (null when playback stops). A change
  /// re-arms the decider so the next track can record its own single play; the
  /// same id repeated (pause/resume/loop) is a no-op that preserves dedup.
  void onTrackChanged(String? trackId) {
    if (trackId == _trackId) return;
    _trackId = trackId;
    _recorded = false;
  }

  /// Feed a position tick against the (possibly unknown) track [duration].
  /// Returns the track id to record when the [threshold] milestone is crossed
  /// for the first time this play, otherwise null.
  String? onPosition(Duration position, Duration duration) {
    return _maybeRecord(position >= threshold);
  }

  /// Feed a track-completed event. Returns the track id to record when the
  /// track finished before it was recorded (e.g. a sub-threshold track that
  /// still played to the end), otherwise null.
  String? onCompleted() {
    return _maybeRecord(true);
  }

  /// Drop any pending/armed state. Call on logout or account switch so a play
  /// from one session can never be attributed to the next.
  void reset() {
    _trackId = null;
    _recorded = false;
  }

  String? _maybeRecord(bool crossed) {
    if (_recorded || _trackId == null || !crossed) return null;
    _recorded = true;
    return _trackId;
  }
}
