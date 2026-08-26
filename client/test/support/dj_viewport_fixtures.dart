import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';

import 'analysis_envelope_fixture.dart';
import 'fake_voice.dart';

/// A real device geometry the DJ deck has to survive.
///
/// [physicalSize] and [padding] are **physical pixels**; [dpr] converts both to
/// the logical dp the layout actually sees. The Pixel 10 Pro is 2856x1280
/// physical, so at dpr 3.0 the landscape deck gets 952 x 426.67 dp — not the
/// 980 x 448 dp the spec used to claim.
class DjViewport {
  const DjViewport(
    this.name,
    this.physicalSize,
    this.dpr,
    this.padding, {
    this.textScale = 1.0,
  });

  final String name;
  final Size physicalSize;
  final double dpr;
  final FakeViewPadding padding;
  final double textScale;

  Size get logicalSize => physicalSize / dpr;

  /// The box `DjLayout`'s LayoutBuilder actually receives, after SafeArea.
  Size get safeAreaSize => Size(
        logicalSize.width - (padding.left + padding.right) / dpr,
        logicalSize.height - (padding.top + padding.bottom) / dpr,
      );

  DjViewport withTextScale(double scale) => DjViewport(
        '$name @ textScale $scale',
        physicalSize,
        dpr,
        padding,
        textScale: scale,
      );

  void apply(WidgetTester tester) {
    tester.view.physicalSize = physicalSize;
    tester.view.devicePixelRatio = dpr;
    tester.view.padding = padding;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
  }
}

/// 159px leading display cutout, 24dp of status bar and 24dp of gesture bar.
const _referencePadding =
    FakeViewPadding(left: 159, top: 72, right: 0, bottom: 72);

/// Pixel 10 Pro landscape at native density: 952 x 426.67 dp.
const landscapeReference = DjViewport(
  'landscape 952x426.7 @3.0',
  Size(2856, 1280),
  3.0,
  _referencePadding,
);

/// Android Settings > Display > Display size one notch up (density 540).
const landscapeLargeDensity = DjViewport(
  'landscape 846x379 @3.375 (density 540)',
  Size(2856, 1280),
  3.375,
  FakeViewPadding(left: 159, top: 81, right: 0, bottom: 81),
);

/// The dpr-3.5 probe that produced the reported pitch-fader overflow.
const landscapeDisplaySizeLarge = DjViewport(
  'landscape 816x365.7 @3.5',
  Size(2856, 1280),
  3.5,
  FakeViewPadding(left: 159, top: 84, right: 0, bottom: 84),
);

/// Density 640: below the minimum serviceable deck height.
const landscapeMinimum = DjViewport(
  'landscape 714x320 @4.0 (density 640)',
  Size(2856, 1280),
  4.0,
  FakeViewPadding(left: 159, top: 96, right: 0, bottom: 96),
);

/// Zero insets: the freeform / connected-display windows below are described
/// directly in dp, so there is nothing to subtract.
const _noPadding = FakeViewPadding(left: 0, top: 0, right: 0, bottom: 0);

/// Just inside *both* gates: 490 x 290dp, two dp above `kDjMinDeckWidth` and
/// six above `kDjMinDeckHeight`. This is the serviceable-but-narrow band where
/// `DjDeckGrid.of` clamps the centre column to its 120dp floor, i.e. the
/// strongest new claim the gate makes ("this viewport IS serviceable"), and the
/// band Android freeform / connected-display windows land in.
const landscapeNarrowServiceable = DjViewport(
  'landscape 490x290 (narrow but serviceable)',
  Size(490, 290),
  1.0,
  _noPadding,
);

/// Below `kDjMinDeckWidth` on *width alone*, with height comfortably above
/// `kDjMinDeckHeight`, so the width half of the gate is what fires.
const landscapeBelowMinimumWidth = DjViewport(
  'landscape 480x300 (below the minimum deck width)',
  Size(480, 300),
  1.0,
  _noPadding,
);

/// A near-minimum freeform window: shorter than the too-small notice's own
/// intrinsic height, which is where the notice used to overflow.
const landscapeTinyWindow = DjViewport(
  'landscape 300x120 (near-minimum freeform window)',
  Size(300, 120),
  1.0,
  _noPadding,
);

/// The frames between a route push and the OS honouring the rotation request,
/// and the permanent state in split-screen / freeform / connected-display.
const portraitReference = DjViewport(
  'portrait 426.7x952 @3.0',
  Size(1280, 2856),
  3.0,
  FakeViewPadding(left: 0, top: 144, right: 0, bottom: 72),
);

/// Every landscape fixture that must render the full deck.
const djServiceableViewports = <DjViewport>[
  landscapeReference,
  landscapeLargeDensity,
  landscapeDisplaySizeLarge,
];

/// Analysis summary for a deck that has *everything* the header can show.
///
/// [productionCompactAnalysisSummary] supplies bpm / beat grid / key / camelot
/// but leaves meter and downbeat phase generated, and `DjDeckState.beatPhase`
/// deliberately refuses generated meter authority (tempo_automation.dart:117).
/// The manual meter/phase authority below is what makes the beat-phase counter
/// render, so the header fixture exercises its widest content case.
Map<String, dynamic> djLoadedAnalysisSummary({double bpm = 124.5}) {
  final beatMs = (60000 / bpm).round();
  return <String, dynamic>{
    ...productionCompactAnalysisSummary(bpm: bpm),
    'beat_grid': {
      'bpm': bpm,
      'offset_ms': 0,
      'beats_ms': [for (var i = 0; i < 16; i++) beatMs * i],
      'confidence': 1,
      'provenance': 'manual_override',
    },
    'meter': {
      'beats_per_bar': 4,
      'confidence': 1,
      'provenance': 'manual_override',
    },
    'downbeat_phase': {
      'index': 0,
      'confidence': 1,
      'provenance': 'manual_override',
    },
    'downbeats': {
      'positions_ms': [0, beatMs * 4, beatMs * 8],
      'confidence': 1,
      'provenance': 'manual_override',
    },
  };
}

TrackAnalysis djLoadedAnalysis({double bpm = 124.5}) => TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: djLoadedAnalysisSummary(bpm: bpm),
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

const djFixtureTitle = 'Long enough track title to exercise the header';

QueueTrack djLoadedQueueTrack({
  String id = '42',
  String title = djFixtureTitle,
  double bpm = 124.5,
  int durationMs = 245000,
}) =>
    QueueTrack(
      id: id,
      queueItemId: 'dj-fixture-$id',
      playbackTrackId: id,
      title: title,
      artist: 'Fixture artist',
      duration: durationMs,
      addedAt: DateTime.utc(2026, 1, 1),
      analysis: djLoadedAnalysis(bpm: bpm),
    );

DjDeckLoad djLoadedDeckSeed({
  String id = '42',
  String title = djFixtureTitle,
  double bpm = 124.5,
  int durationMs = 245000,
}) {
  final track = djLoadedQueueTrack(
    id: id,
    title: title,
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
    localUri: Uri.file('/tmp/dj-fixture-$id.mp3'),
  );
}

/// A deck snapshot with every header segment populated: title, BPM, pitch %,
/// key + camelot, beat phase and clock.
DjDeckState djLoadedDeckState({
  DjDeckId deckId = DjDeckId.a,
  String title = djFixtureTitle,
  double bpm = 124.5,
  int durationMs = 245000,
  int positionMs = 0,
}) {
  final track = djLoadedQueueTrack(
    title: title,
    bpm: bpm,
    durationMs: durationMs,
  );
  return DjDeckState(
    deckId: deckId,
    queueItemId: track.queueItemId,
    trackRef: track.id,
    title: title,
    queueTrack: track,
    durationMs: durationMs,
    positionMs: positionMs,
    beatsMs: track.analysis?.summary?.beatGrid?.beatsMs ?? const [],
  );
}

DjSessionProvider djFixtureSession() => DjSessionProvider.prototype(
      voiceFactory: () => FakeVoice('dj-fixture'),
      resolver: const DirectEngineAudioSourceResolver(),
    );

/// Loads both decks before the screen mounts. `DjScreen`'s post-frame seed sees
/// an empty queue and a null picker, so it leaves these loads alone.
Future<void> loadBothDecks(DjSessionProvider session) async {
  await session.load(DjDeckId.a, djLoadedDeckSeed());
  await session.load(
    DjDeckId.b,
    djLoadedDeckSeed(id: '43', title: 'Deck B fixture track', bpm: 128),
  );
}

/// Holds the fixture session for a test group.
class DjSessionRef {
  late DjSessionProvider session;
}

/// Builds a loaded fixture session in `setUp` and retires it in `tearDown`.
///
/// The session must be constructed *outside* the test body: its 33Hz snapshot
/// timer would otherwise be a pending fake timer at the end of every test.
DjSessionRef useLoadedDjSession() {
  final ref = DjSessionRef();
  setUp(() async {
    ref.session = djFixtureSession();
    await loadBothDecks(ref.session);
  });
  tearDown(() => ref.session.dispose());
  return ref;
}

/// Same, without loading either deck.
DjSessionRef useEmptyDjSession() {
  final ref = DjSessionRef();
  setUp(() => ref.session = djFixtureSession());
  tearDown(() => ref.session.dispose());
  return ref;
}

Future<void> pumpDjScreen(
  WidgetTester tester, {
  required DjSessionProvider session,
  required DjViewport viewport,
  ThemeData? theme,
}) async {
  viewport.apply(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: viewport.textScale == 1.0
          ? null
          : (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(viewport.textScale),
                ),
                child: child!,
              ),
      home: DjScreen(session: session, filePicker: () async => null),
    ),
  );
  await tester.pump();
}

/// Captures layout errors without stealing them from `takeException()`.
class DjErrorCollector {
  final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
  void Function(FlutterErrorDetails)? _previous;

  void install() {
    _previous = FlutterError.onError;
    FlutterError.onError = (details) {
      errors.add(details);
      _previous?.call(details);
    };
  }

  void restore() {
    FlutterError.onError = _previous;
  }

  List<String> get overflows => errors
      .map((e) => e.exceptionAsString())
      .where((e) => e.contains('overflowed'))
      .toList();
}
