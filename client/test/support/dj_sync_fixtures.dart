import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';

import 'dj_viewport_fixtures.dart';
import 'fake_voice.dart';

/// Fixtures for the deck sync tests (#413).
///
/// Deliberately additive to `dj_viewport_fixtures.dart`, which stays the
/// manual-authority deck fixture: everything here that needs a trustworthy
/// grid reuses [djLoadedAnalysis], and only the deliberately *untrustworthy*
/// and *overridden* cases are built from raw maps.

/// A generated analysis whose BPM confidence is the variable under test.
///
/// `hasReliableBpm` reads `effectiveTiming.bpm.confidence` first, so a value
/// below `reliableBpmConfidenceFloor` (0.55) is what makes the sync gate refuse.
TrackAnalysis djSyncGeneratedAnalysis({
  double bpm = 124.5,
  double confidence = 0.96,
}) {
  final beatMs = (60000 / bpm).round();
  return TrackAnalysis.fromJson(
    status: 'analyzed',
    summary: <String, dynamic>{
      'bpm': {
        'value': bpm,
        'confidence': confidence,
        'provenance': 'beat-this-v1',
      },
      'beat_grid': {
        'bpm': bpm,
        'offset_ms': 0,
        'beats_ms': [for (var i = 0; i < 16; i++) beatMs * i],
        'confidence': confidence,
        'provenance': 'beat-this-v1',
      },
      'key': {
        'value': 'A minor',
        'confidence': 0.88,
        'provenance': 'key-estimator-v1',
      },
      'camelot': {
        'value': '8A',
        'confidence': 0.88,
        'provenance': 'key-estimator-v1',
      },
    },
  );
}

/// A track whose generated BPM is [generatedBpm] but whose canonical manual
/// override says [overrideBpm]. `ClipTempoMetadata` must report the override.
TrackAnalysis djSyncOverriddenAnalysis({
  double generatedBpm = 124.5,
  double overrideBpm = 100,
}) {
  final beatMs = (60000 / generatedBpm).round();
  return TrackAnalysis.fromJson(
    status: 'analyzed',
    summary: <String, dynamic>{
      'bpm': {
        'value': generatedBpm,
        'confidence': 0.96,
        'provenance': 'beat-this-v1',
      },
      'beat_grid': {
        'bpm': generatedBpm,
        'offset_ms': 0,
        'beats_ms': [for (var i = 0; i < 16; i++) beatMs * i],
        'confidence': 0.94,
        'provenance': 'beat-this-v1',
      },
    },
    overrides: <String, dynamic>{
      'manual_timing_v2': {
        'schema_version': 2,
        'bpm': overrideBpm,
        'beat_anchor_ms': 0,
        'confidence': 1,
        'provenance': 'manual_override',
      },
    },
    overridesPresent: true,
  );
}

/// A manual-authority analysis whose grid spans [beats] beats.
///
/// `djLoadedAnalysis` stops at 16 beats (about 7.7s), which is shorter than the
/// convergence window this ticket has to demonstrate: once a deck walks off the
/// end of its grid the alignment signal goes null and the run proves nothing.
TrackAnalysis djSyncLongGridAnalysis({double bpm = 128, int beats = 256}) {
  final beatMs = (60000 / bpm).round();
  return TrackAnalysis.fromJson(
    status: 'analyzed',
    summary: <String, dynamic>{
      ...djLoadedAnalysisSummary(bpm: bpm),
      'beat_grid': {
        'bpm': bpm,
        'offset_ms': 0,
        'beats_ms': [for (var i = 0; i < beats; i++) beatMs * i],
        'confidence': 1,
        'provenance': 'manual_override',
      },
      'downbeats': {
        'positions_ms': [for (var i = 0; i * 4 < beats; i++) beatMs * i * 4],
        'confidence': 1,
        'provenance': 'manual_override',
      },
    },
    overrides: const {
      'manual_timing_v2': {
        'schema_version': 2,
        'beats_per_bar': 4,
        'downbeat_phase_index': 0,
        'confidence': 1,
        'provenance': 'manual_override',
      },
    },
    overridesPresent: true,
  );
}

/// A trustworthy BPM on an untrustworthy grid.
///
/// `minReliableBeatGridMarkers` is 4 (tempo_automation.dart:9), so three
/// markers clear `hasReliableBpm` and fail `hasReliableBeatGrid`. That is the
/// exact pair of gates the correction has to honour: the tempo match still
/// runs, the alignment correction does not. The grid is still long enough for
/// `djSyncPhaseReading` to return a number, so a test that sees zero
/// corrections is seeing the gate and not a missing signal.
TrackAnalysis djSyncShortGridAnalysis({double bpm = 128}) {
  final beatMs = (60000 / bpm).round();
  return TrackAnalysis.fromJson(
    status: 'analyzed',
    summary: <String, dynamic>{
      'bpm': {
        'value': bpm,
        'confidence': 0.96,
        'provenance': 'beat-this-v1',
      },
      'beat_grid': {
        'bpm': bpm,
        'offset_ms': 0,
        'beats_ms': [for (var i = 0; i < 3; i++) beatMs * i],
        'confidence': 0.94,
        'provenance': 'beat-this-v1',
      },
    },
  );
}

QueueTrack djSyncQueueTrack({
  String id = '90',
  String title = 'Sync fixture track',
  TrackAnalysis? analysis,
  double bpm = 124.5,
  int durationMs = 245000,
}) =>
    QueueTrack(
      id: id,
      queueItemId: 'dj-sync-$id',
      playbackTrackId: id,
      title: title,
      artist: 'Fixture artist',
      duration: durationMs,
      addedAt: DateTime.utc(2026, 1, 1),
      analysis: analysis ?? djLoadedAnalysis(bpm: bpm),
    );

/// A loaded deck snapshot with an explicit tempo, rate and position.
DjDeckState djSyncDeckState({
  DjDeckId deckId = DjDeckId.a,
  double bpm = 124.5,
  double rate = 1,
  int positionMs = 0,
  int durationMs = 245000,
  TrackAnalysis? analysis,
  String id = '90',
}) {
  final track = djSyncQueueTrack(
    id: id,
    analysis: analysis,
    bpm: bpm,
    durationMs: durationMs,
  );
  return DjDeckState(
    deckId: deckId,
    queueItemId: track.queueItemId,
    trackRef: track.id,
    title: track.title,
    queueTrack: track,
    durationMs: durationMs,
    positionMs: positionMs,
    rate: rate,
    beatsMs: track.analysis?.summary?.beatGrid?.beatsMs ?? const [],
  );
}

/// A deck seed the local-file path accepts, with an explicit analysis.
DjDeckLoad djSyncDeckSeed({
  String id = '90',
  String title = 'Sync fixture track',
  TrackAnalysis? analysis,
  double bpm = 124.5,
  int durationMs = 245000,
}) {
  final track = djSyncQueueTrack(
    id: id,
    title: title,
    analysis: analysis,
    bpm: bpm,
    durationMs: durationMs,
  );
  return DjDeckLoad(
    trackRef: id,
    queueItemId: track.queueItemId,
    title: title,
    queueTrack: track,
    durationMs: durationMs,
    beatsMs: track.analysis?.summary?.beatGrid?.beatsMs ?? const [],
    localUri: Uri.file('/tmp/dj-sync-$id.mp3'),
  );
}

/// Counts the voices a session actually allocated (ADR 0001, issue AC 7).
class DjSyncVoiceFactory {
  final List<FakeVoice> created = <FakeVoice>[];

  Voice make() {
    final voice = FakeVoice('dj-sync-${created.length}');
    created.add(voice);
    return voice;
  }
}

/// One deck controller drawn from [factory], so a widget test can count every
/// voice the session ever allocated.
DeckController djSyncDeck(DjDeckId deckId, DjSyncVoiceFactory factory) =>
    DeckController.empty(
      deckId: deckId,
      voice: factory.make(),
      resolver: const DirectEngineAudioSourceResolver(),
    );

/// A session whose two voices the test holds directly, so rate and pitch
/// commands can be asserted per deck.
class DjSyncRig {
  DjSyncRig(this.session, this._voices);

  final DjSessionProvider session;
  final Map<DjDeckId, FakeVoice> _voices;

  FakeVoice voiceFor(DjDeckId deck) => _voices[deck]!;
}

DjSyncRig djSyncRig({bool pitchSupported = true, DjSyncClock? clock}) {
  final voiceA = FakeVoice('dj-sync-a', pitchSupported: pitchSupported);
  final voiceB = FakeVoice('dj-sync-b', pitchSupported: pitchSupported);
  const resolver = DirectEngineAudioSourceResolver();
  return DjSyncRig(
    DjSessionProvider(
      deckA: DeckController.empty(
        deckId: DjDeckId.a,
        voice: voiceA,
        resolver: resolver,
      ),
      deckB: DeckController.empty(
        deckId: DjDeckId.b,
        voice: voiceB,
        resolver: resolver,
      ),
      clock: clock,
    ),
    {DjDeckId.a: voiceA, DjDeckId.b: voiceB},
  );
}

/// A deterministic wall clock for the correction throttle.
///
/// The throttle is stated in milliseconds, so a tick-counting test would pin
/// the wrong contract; this advances the same number of milliseconds the 33ms
/// snapshot pass would have.
class DjSyncFakeClock {
  int nowMs = 0;
  int read() => nowMs;
  void advance(int ms) => nowMs += ms;
}
