import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart' as core_api;
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/playlists/mix/mix_models.dart';
import 'package:open_music_player/features/playlists/mix/mix_reorder.dart';
import 'package:open_music_player/features/playlists/playlist_detail_screen.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _track(
  int id, {
  double? bpm,
  String? camelot,
}) =>
    Track(
      id: id,
      identityHash: 'h$id',
      title: 'Track $id',
      artist: 'Artist',
      durationMs: 200000,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      analysis: _analysis(bpm: bpm, camelot: camelot),
    );

TrackAnalysis? _analysis({double? bpm, String? camelot}) {
  if (bpm == null && camelot == null) return null;
  return TrackAnalysis(
    status: TrackAnalysisStatus.analyzed,
    summary: TrackAnalysisSummary(
      bpm: bpm == null
          ? null
          : AnalysisValue(value: bpm),
      camelot: camelot == null ? null : AnalysisValue(value: camelot),
    ),
  );
}

Map<String, dynamic> _transitionJson(
  int outgoing,
  int incoming, {
  bool keyMatch = true,
  bool tempoMatched = false,
}) =>
    {
      'index': 0,
      'outgoingTrackId': outgoing,
      'incomingTrackId': incoming,
      'preset': 'Blend',
      'bars': 8,
      'overlapMs': 14769,
      'confidence': {
        'keyMatch': keyMatch,
        'tempoMatched': tempoMatched,
      },
    };

class _StubPlaylistService extends PlaylistService {
  _StubPlaylistService({
    required this.tracks,
    this.autoMixResult,
    this.failAutoMix = false,
  }) : super(api: core_api.ApiClient(storage: SecureStorage()));

  final List<Track> tracks;
  final Map<String, dynamic>? autoMixResult;
  final bool failAutoMix;
  int autoMixCalls = 0;

  @override
  Future<Playlist> getPlaylist(int id) async => Playlist(
        id: id,
        name: 'Mix',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        tracks: tracks,
      );

  @override
  Future<AutoMixResult> autoMix(int playlistId) async {
    autoMixCalls++;
    if (failAutoMix) throw Exception('auto-mix unavailable');
    final result = autoMixResult!;
    return AutoMixResult.fromJson(result);
  }
}

class _FakePlayback extends Fake implements PlaybackState {
  @override
  MediaItem? get currentItem => null;

  @override
  PlaybackContext? get playbackContext => null;

  @override
  bool get isPlaying => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

Future<void> _pumpDetail(
  WidgetTester tester,
  PlaylistService service,
) async {
  await tester.pumpWidget(
    ListenableProvider<PlaybackState>.value(
      value: _FakePlayback(),
      child: MaterialApp(
        home: PlaylistDetailScreen(playlistId: 7, playlistService: service),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('mix toggle calls auto-mix and shows mixed view with seams',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _StubPlaylistService(
      tracks: [
        _track(1, bpm: 124, camelot: '10B'),
        _track(2, bpm: 126, camelot: '10A'),
        _track(3, bpm: 125, camelot: '11B'),
      ],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [
          _transitionJson(1, 2, keyMatch: true),
          _transitionJson(2, 3,
              keyMatch: false, tempoMatched: true),
        ],
      },
    );

    await _pumpDetail(tester, service);

    // Normal view first: no seams.
    expect(find.byKey(const ValueKey('mix_toggle')), findsOneWidget);
    expect(find.byKey(const Key('mix_seam_1_2')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();

    expect(service.autoMixCalls, 1);

    // Mixed view: badges per row and seam connectors between rows.
    expect(find.byKey(const Key('mixed_track_1')), findsOneWidget);
    expect(find.byKey(const Key('mix_seam_1_2')), findsOneWidget);
    expect(find.byKey(const Key('mix_seam_2_3')), findsOneWidget);

    // Preset chip text from the plan.
    expect(find.text('Blend'), findsNWidgets(2));
    // Overlap label: 14769 ms -> "15s · 8 bars".
    expect(find.text('15s · 8 bars'), findsNWidgets(2));

    // BPM + Camelot badges render for analyzed tracks.
    expect(find.text('124 BPM'), findsOneWidget);
    expect(find.text('10B'), findsOneWidget);

    // Reorder button appears only while mix is on.
    expect(
      find.byKey(const ValueKey('mix_reorder_button')),
      findsOneWidget,
    );
  });

  testWidgets('seam confidence mapping: key match, tempo shift, simple fade',
      (tester) async {
    final keyMatch = MixTransition.fromJson(_transitionJson(1, 2));
    expect(keyMatch.confidence, MixTransitionConfidence.keyMatch);

    final tempoShift = MixTransition.fromJson(
      _transitionJson(1, 2, keyMatch: false, tempoMatched: true),
    );
    expect(tempoShift.confidence, MixTransitionConfidence.tempoShift);

    final simpleFade = MixTransition.fromJson(
      _transitionJson(1, 2, keyMatch: false, tempoMatched: false)
        ..['preset'] = 'Fade',
    );
    expect(simpleFade.confidence, MixTransitionConfidence.simpleFade);
  });

  testWidgets('tapping a seam shows the slice-2 placeholder snackbar',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _StubPlaylistService(
      tracks: [_track(1, bpm: 124), _track(2, bpm: 126)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
      },
    );

    await _pumpDetail(tester, service);
    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();

    // Dismiss the toggle's summary toast first so the seam toast can show.
    await tester.drag(find.text('Blended 1 transitions. Tap any seam to adjust.'), const Offset(0, 40));
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('mix_seam_1_2')),
        matching: find.byType(InkWell),
      ).first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Transition editor coming in slice 2'), findsOneWidget);
  });

  testWidgets('mix off reverts to the normal playlist view', (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _StubPlaylistService(
      tracks: [_track(1, bpm: 124), _track(2, bpm: 126)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
      },
    );

    await _pumpDetail(tester, service);
    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('mix_seam_1_2')), findsOneWidget);

    // Toggle back off.
    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();

    // No additional API call on toggle-off; plan stays server-side.
    expect(service.autoMixCalls, 1);
    expect(find.byKey(const Key('mix_seam_1_2')), findsNothing);
    expect(find.byKey(const Key('mixed_track_1')), findsNothing);
    expect(find.byKey(const ValueKey('mix_reorder_button')), findsNothing);

    // Normal view still renders its track tiles.
    expect(find.text('Track 1'), findsOneWidget);
  });

  testWidgets('smart reorder places nearest track second by key and tempo',
      (tester) async {
    // First track (124 BPM / 10B). Candidate distances from it:
    //  - track 3: 125 BPM (+0.1) + same-number letter hop 10B->10A (+1) = 1.1
    //  - track 4: 128 BPM (+0.4) + adjacent number 10B->9B (+1) = 1.4
    //  - track 5: 130 BPM (+0.6) + far key 10B->3B (+7) = 7.6
    // Greedy order should be 1, 3, 4, 5.
    final analyses = <TrackAnalysis?>[
      _analysis(bpm: 124, camelot: '10B'),
      _analysis(bpm: 999, camelot: '1A'),
      _analysis(bpm: 125, camelot: '10A'),
      _analysis(bpm: 128, camelot: '9B'),
      _analysis(bpm: 130, camelot: '3B'),
    ];

    final order = MixReorder.orderIndices(analyses);

    expect(order.first, 0, reason: 'first track stays in place');
    expect(order[1], 2, reason: 'second track is nearest by key and tempo');
    expect(order, [0, 2, 3, 4, 1]);

    // The screen wires the reorder through the displayed list only.
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _StubPlaylistService(
      tracks: [
        _track(1, bpm: 124, camelot: '10B'),
        _track(2, bpm: 130, camelot: '3B'),
        _track(3, bpm: 125, camelot: '10A'),
      ],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [
          _transitionJson(1, 2),
          _transitionJson(2, 3),
        ],
      },
    );

    await _pumpDetail(tester, service);
    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();

    // Dismiss the toggle's summary toast so the reorder toast can show.
    await tester.drag(
      find.text('Blended 2 transitions. Tap any seam to adjust.'),
      const Offset(0, 40),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('mix_reorder_button')));
    await tester.pumpAndSettle();

    expect(find.text('Reordered by key and tempo'), findsOneWidget);
    // Track 3 (nearest) moves into second position.
    final track1Center = tester.getCenter(find.byKey(const Key('mixed_track_1')));
    final track3Center = tester.getCenter(find.byKey(const Key('mixed_track_3')));
    final track2Center = tester.getCenter(find.byKey(const Key('mixed_track_2')));
    expect(track3Center.dy, greaterThan(track1Center.dy));
    expect(track3Center.dy, lessThan(track2Center.dy));
  });

  testWidgets('auto-mix failure keeps normal view and shows an error toast',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _StubPlaylistService(
      tracks: [_track(1), _track(2)],
      failAutoMix: true,
    );

    await _pumpDetail(tester, service);
    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();

    expect(service.autoMixCalls, 1);
    expect(find.byKey(const Key('mixed_track_1')), findsNothing);
    expect(find.text('Could not blend this playlist. Try again.'),
        findsOneWidget);
  });
}
