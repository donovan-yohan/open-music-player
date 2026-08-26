import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/features/dj/widgets/dj_beat_ruler_painter.dart';
import 'package:open_music_player/features/dj/widgets/dj_waveform_lane.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';

import 'analysis_envelope_fixture.dart';
import 'dj_viewport_fixtures.dart';
import 'fake_voice.dart';

/// Analysis fixtures for the deck's hydration path and beat ruler (#410, #416).
///
/// Kept separate from `dj_viewport_fixtures.dart`, which is shared with the
/// deck-chrome lanes.

/// 120 BPM, so one beat is exactly 500ms and 45.0px at the deck's detail zoom.
const double djBeatBpm = 120;

/// Four phrases of 4/4 at [djBeatBpm]: enough grid for phrase-level ticks.
const int djBeatGridBeats = 64;

/// Whole seconds, matching `QueueTrack.duration`'s unit (track.dart:285).
const int djBeatTrackSeconds = 245;

int get djBeatMs => (60000 / djBeatBpm).round();

/// Analyzer summary with a beat grid and nothing else timing-related.
///
/// Meter, downbeat phase and downbeats are deliberately absent so each tier
/// fixture below adds exactly the authority it is testing.
Map<String, dynamic> djBeatGridSummary({
  double bpm = djBeatBpm,
  int beats = djBeatGridBeats,
}) {
  final beatMs = (60000 / bpm).round();
  return <String, dynamic>{
    'bpm': {'value': bpm, 'confidence': 0.96, 'provenance': 'beat-this-v1'},
    'beat_grid': {
      'bpm': bpm,
      'offset_ms': 0,
      'beats_ms': [for (var i = 0; i < beats; i++) beatMs * i],
      'confidence': 0.94,
      'provenance': 'beat-this-v1',
    },
    'key': {'value': 'A minor', 'confidence': 0.88, 'provenance': 'key-v1'},
    'camelot': {'value': '8A', 'confidence': 0.88, 'provenance': 'key-v1'},
  };
}

/// Tier A: manual downbeat authority, so the ruler is numbered.
///
/// The phase arrives as a `manual_timing_v2` correction, which is the real
/// path: `ManualTimingOverride.applyTo` rewrites `downbeats.positions_ms` to
/// `beats[phase], beats[phase + meter], …` with `provenance: manual_override`
/// and `confidence: 1.0`, and leaves the beat grid alone because no bpm or
/// beat anchor was overridden.
TrackAnalysis djNumberedAnalysis({
  double bpm = djBeatBpm,
  int beats = djBeatGridBeats,
  int beatsPerBar = 4,
  int downbeatPhaseIndex = 0,
  int? phraseLengthBars,
}) =>
    TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: djBeatGridSummary(bpm: bpm, beats: beats),
      overrides: {
        'manual_timing_v2': {
          'schema_version': 2,
          'beats_per_bar': beatsPerBar,
          'downbeat_phase_index': downbeatPhaseIndex,
          if (phraseLengthBars != null) 'phrase_length_bars': phraseLengthBars,
          'confidence': 1,
          'provenance': 'manual_override',
        },
      },
      overridesPresent: true,
    );

/// Tier B: a beat grid with **generated** meter, phase and downbeats.
///
/// This is the shape every dogfood track has today, so `hasReliableDownbeats`
/// is false and the ruler draws bars without numbering them
/// (docs/dj-deck-spec.md:83).
TrackAnalysis djUnnumberedAnalysis({
  double bpm = djBeatBpm,
  int beats = djBeatGridBeats,
  int beatsPerBar = 4,
}) {
  final beatMs = (60000 / bpm).round();
  return TrackAnalysis.fromJson(
    status: 'analyzed',
    summary: <String, dynamic>{
      ...djBeatGridSummary(bpm: bpm, beats: beats),
      'meter': {
        'beats_per_bar': beatsPerBar,
        'confidence': 0.72,
        'provenance': 'beat-this-v1',
      },
      'downbeat_phase': {
        'index': 0,
        'confidence': 0.68,
        'provenance': 'beat-this-v1',
      },
      'downbeats': {
        'positions_ms': [
          for (var i = 0; i < beats; i += beatsPerBar) beatMs * i,
        ],
        'confidence': 0.7,
        'provenance': 'beat-this-v1',
      },
    },
  );
}

/// Tier C: analyzed, but no beat grid at all.
TrackAnalysis djNoGridAnalysis() => TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: const {
        'key': {'value': 'A minor', 'confidence': 0.88, 'provenance': 'key-v1'},
        'camelot': {'value': '8A', 'confidence': 0.88, 'provenance': 'key-v1'},
      },
    );

/// The queue-payload shape: tempo metadata, deliberately no waveform arrays.
TrackAnalysis djCompactAnalysis({double bpm = djBeatBpm}) =>
    TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: productionCompactAnalysisSummary(bpm: bpm),
    );

/// What the per-track analysis endpoint returns: real `artifacts.waveforms`
/// peak/minima/maxima/rms arrays, so `richWaveformForTrack` builds frames.
TrackAnalysis djHydratedAnalysis({double bpm = djBeatBpm}) {
  final envelope = productionBands3AnalysisEnvelope(bpm: bpm);
  return TrackAnalysis.fromJson(
    status: 'analyzed',
    summary: envelope['summary'],
    artifacts: envelope['artifacts'],
  );
}

TrackAnalysis djFailedAnalysis() => TrackAnalysis.fromJson(
      status: 'failed',
      summary: productionCompactAnalysisSummary(),
    );

QueueTrack djAnalysisTrack({
  String id = '42',
  TrackAnalysis? analysis,
  String title = 'Deck analysis fixture',
  int durationSeconds = djBeatTrackSeconds,
}) =>
    QueueTrack(
      id: id,
      queueItemId: 'dj-analysis-$id',
      playbackTrackId: id,
      title: title,
      artist: 'Fixture artist',
      duration: durationSeconds,
      addedAt: DateTime.utc(2026, 1, 1),
      analysis: analysis,
    );

/// A deck seed that bypasses the resolver, so a lane test never depends on
/// download or cache state.
DjDeckLoad djAnalysisSeed(QueueTrack track) {
  final analysis = track.analysis;
  return DjDeckLoad(
    trackRef: track.id,
    queueItemId: track.queueItemId,
    title: track.title,
    queueTrack: track,
    durationMs: track.durationMs,
    beatsMs: analysis == null
        ? const <int>[]
        : ClipTempoMetadata.fromTrackAnalysis(analysis).beatsMs,
    localUri: Uri.file('/tmp/dj-analysis-${track.id}.mp3'),
  );
}

/// A seed the deck must refuse: a non-file picker URI.
DjDeckLoad djRefusedSeed({String id = '99'}) => DjDeckLoad(
      trackRef: id,
      queueItemId: 'dj-analysis-$id',
      title: 'Refused fixture',
      localUri: Uri.parse('https://example.test/$id.mp3'),
    );

/// [FakeVoice] that records how many times audio was loaded, which is how the
/// hydration tests prove a re-seed never became a second `Voice.load`.
class CountingFakeVoice extends FakeVoice {
  CountingFakeVoice(super.debugId);

  int loadCount = 0;

  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) {
    loadCount++;
    return super.load(source, initialLocalPositionMs: initialLocalPositionMs);
  }
}

/// A session whose voices count their loads.
DjSessionProvider djCountingSession(List<CountingFakeVoice> voices) =>
    DjSessionProvider.prototype(
      voiceFactory: () {
        final voice = CountingFakeVoice('dj-analysis-${voices.length}');
        voices.add(voice);
        return voice;
      },
      resolver: const DirectEngineAudioSourceResolver(),
    );

/// Loads deck A (and optionally deck B) from analysis fixtures.
Future<void> djLoadDecks(
  DjSessionProvider session, {
  required QueueTrack deckA,
  QueueTrack? deckB,
}) async {
  await session.load(DjDeckId.a, djAnalysisSeed(deckA));
  if (deckB != null) await session.load(DjDeckId.b, djAnalysisSeed(deckB));
}

/// Width the deck lane actually gets at [landscapeReference]: 952dp of logical
/// width less the Pixel 10 Pro's 53dp leading cutout.
const double djLaneWidth = 899;

/// One lane of the 120dp waveform stack, less the 8dp gap.
const double djLaneHeight = 56;

/// Pumps a bare [DjWaveformLane] at the deck's real lane geometry.
///
/// Used where the zoom has to be varied, which `DjLayout` deliberately does not
/// expose; the layout-mounted case is covered by pumping `DjScreen` itself.
Future<void> pumpDjLane(
  WidgetTester tester, {
  required DjDeckState deck,
  required QueueTrack? track,
  double pixelsPerSecond = kDjLaneDetailPixelsPerSecond,
  DjViewport viewport = landscapeReference,
}) async {
  viewport.apply(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: djLaneWidth,
            height: djLaneHeight,
            child: DjWaveformLane(
              deck: deck,
              track: track,
              color: const Color(0xFF4FC3F7),
              pixelsPerSecond: pixelsPerSecond,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

/// Every [DjBeatRulerPainter] currently mounted, in tree order (deck A first).
List<DjBeatRulerPainter> djRulerPainters(WidgetTester tester) => tester
    .widgetList<CustomPaint>(find.byType(CustomPaint))
    .map((paint) => paint.painter)
    .whereType<DjBeatRulerPainter>()
    .toList();

/// The x positions of one ruler level, ascending.
List<double> djTickXs(DjBeatRulerPainter painter, DjBeatTickLevel level) => [
      for (final tick in painter.ticks)
        if (tick.level == level) tick.x,
    ]..sort();

/// Tears a fixture session (and optionally its queue) down **inside** the test
/// body.
///
/// `DjSessionProvider`'s 33 Hz snapshot timer is a FakeTimer when the session is
/// built in a widget test, and `addTearDown` runs after the binding's
/// pending-timer invariant check — so the dispose has to happen here.
Future<void> djRetireSession(
  WidgetTester tester,
  DjSessionProvider session, {
  ChangeNotifier? queue,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 20));
  session.dispose();
  queue?.dispose();
}
