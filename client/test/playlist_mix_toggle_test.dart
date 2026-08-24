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
import 'package:open_music_player/features/playlists/mixed_playlist_view.dart';
import 'package:open_music_player/features/playlists/playlist_detail_screen.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:provider/provider.dart';

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
      bpm: bpm == null ? null : AnalysisValue(value: bpm),
      camelot: camelot == null ? null : AnalysisValue(value: camelot),
    ),
  );
}

Map<String, dynamic> _transitionJson(
  int outgoing,
  int incoming, {
  bool keyMatch = true,
  bool tempoMatched = false,
  bool tempoShift = false,
  bool simpleFade = false,
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
        'tempoShift': tempoShift,
        'simpleFade': simpleFade,
      },
    };

Map<String, dynamic> _mixPlanJson(List<int> trackIds) {
  var cursorMs = 0;
  final clips = <Map<String, dynamic>>[];
  for (var index = 0; index < trackIds.length; index++) {
    final startMs = index == 0 ? 0 : cursorMs - 10000;
    clips.add({
      'clipId': 'clip-${index + 1}',
      'queueItemId': 'queue-${index + 1}',
      'trackId': trackIds[index],
      'sourceStartMs': 0,
      'sourceEndMs': 200000,
      'timelineStartMs': startMs,
      'gainDb': index == 1 ? -1.5 : 0,
      if (index > 0) 'fadeInMs': 7000,
      if (index < trackIds.length - 1) 'fadeOutMs': 9000,
    });
    cursorMs = startMs + 200000;
  }
  return {
    'id': 'plan-1',
    'schemaVersion': 1,
    'name': 'Auto mix',
    'clips': clips,
    'summary': {
      'clipCount': clips.length,
      'trackIds': trackIds,
      'durationMs': cursorMs,
    },
    'version': 1,
    'createdAt': '2026-08-24T00:00:00Z',
    'updatedAt': '2026-08-24T00:00:00Z',
  };
}

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
  _FakePlayback({this.rejectMixPlan = false});

  final bool rejectMixPlan;
  final List<
      ({
        List<Map<String, dynamic>> tracks,
        MixPlan plan,
        int startIndex,
        PlaybackContext? context,
      })> mixPlanCalls = [];
  final List<
      ({
        List<Map<String, dynamic>> tracks,
        int startIndex,
        PlaybackContext? context,
      })> playQueueCalls = [];

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

  @override
  Future<void> playMixPlan(
    List<Map<String, dynamic>> tracks,
    MixPlan plan, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    mixPlanCalls.add((
      tracks: tracks,
      plan: plan,
      startIndex: startIndex,
      context: context,
    ));
    if (rejectMixPlan) {
      throw const FormatException('stale mix plan');
    }
  }

  @override
  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    playQueueCalls.add((
      tracks: tracks,
      startIndex: startIndex,
      context: context,
    ));
  }
}

Future<_FakePlayback> _pumpDetail(
  WidgetTester tester,
  PlaylistService service, {
  _FakePlayback? playback,
  Future<MixPlan> Function(MixPlan plan, List<MixPlanClip> clips)?
      onSaveMixPlan,
}) async {
  final fakePlayback = playback ?? _FakePlayback();
  await tester.pumpWidget(
    ListenableProvider<PlaybackState>.value(
      value: fakePlayback,
      child: MaterialApp(
        home: PlaylistDetailScreen(
          playlistId: 7,
          playlistService: service,
          onSaveMixPlan: onSaveMixPlan,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fakePlayback;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('auto-mix response retains a valid canonical plan tolerantly', () {
    final parsed = AutoMixResult.fromJson({
      'transitions': [_transitionJson(1, 2)],
      'mixPlan': _mixPlanJson([1, 2]),
    });

    expect(parsed.mixPlan?.id, 'plan-1');
    expect(parsed.mixPlan?.clips.map((clip) => clip.trackId), ['1', '2']);
    expect(parsed.mixPlan?.clips.first.fadeOutMs, 9000);
    expect(parsed.mixPlan?.clips.last.fadeInMs, 7000);

    final malformed = AutoMixResult.fromJson({
      'transitions': [_transitionJson(1, 2)],
      'mixPlan': {'id': 7},
    });
    expect(malformed.mixPlan, isNull);
    expect(malformed.transitions, hasLength(1));

    final trimmedPreset = MixTransition.fromJson(
      _transitionJson(1, 2)..['preset'] = '  Blend  ',
    );
    expect(trimmedPreset.preset, 'Blend');
  });

  testWidgets('mix action is unavailable for zero and one-track playlists',
      (tester) async {
    for (final tracks in <List<Track>>[
      const [],
      [_track(1)],
    ]) {
      final service = _StubPlaylistService(tracks: tracks);
      await _pumpDetail(tester, service);

      expect(find.byKey(const ValueKey('mix_toggle')), findsNothing);
      expect(service.autoMixCalls, 0);
    }
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
          _transitionJson(2, 3, keyMatch: false, tempoShift: true),
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

    // Smart Reorder belongs to slice 3, where it can regenerate the plan.
    expect(
      find.byKey(const ValueKey('mix_reorder_button')),
      findsNothing,
    );
  });

  testWidgets('seam confidence mapping: key match, tempo shift, simple fade',
      (tester) async {
    final keyMatch = MixTransition.fromJson(_transitionJson(1, 2));
    expect(keyMatch.confidence, MixTransitionConfidence.keyMatch);

    final tempoShift = MixTransition.fromJson(
      _transitionJson(1, 2, tempoShift: true),
    );
    expect(tempoShift.confidence, MixTransitionConfidence.tempoShift);

    final tempoOnly = MixTransition.fromJson(
      _transitionJson(1, 2, keyMatch: false, tempoMatched: true),
    );
    expect(tempoOnly.confidence, MixTransitionConfidence.tempoShift);

    final simpleFade = MixTransition.fromJson(
      _transitionJson(1, 2, tempoShift: true, simpleFade: true)
        ..['preset'] = 'Fade',
    );
    expect(simpleFade.confidence, MixTransitionConfidence.simpleFade);
  });

  testWidgets('tapping a seam opens the transition editor and saves fades',
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
        'mixPlan': _mixPlanJson([1, 2]),
      },
    );

    MixPlan? savedPlan;
    List<MixPlanClip>? savedClips;
    await _pumpDetail(
      tester,
      service,
      onSaveMixPlan: (plan, clips) async {
        savedPlan = plan;
        savedClips = clips;
        return MixPlan(
          id: plan.id,
          schemaVersion: plan.schemaVersion,
          name: plan.name,
          clips: clips,
          summary: plan.summary,
          version: plan.version + 1,
          createdAt: plan.createdAt,
          updatedAt: DateTime.utc(2026, 8, 24, 12),
        );
      },
    );
    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();

    // Dismiss the toggle's summary toast first so it cannot eat the tap.
    await tester.drag(
        find.text('Blended 1 transitions. Tap any seam to adjust.'),
        const Offset(0, 40));
    await tester.pumpAndSettle();

    await tester.tap(
      find
          .descendant(
            of: find.byKey(const Key('mix_seam_1_2')),
            matching: find.byType(InkWell),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.text('Edit transition'), findsOneWidget);

    await tester.tap(find.text('Save transition'));
    await tester.pumpAndSettle();

    expect(find.text('Transition saved'), findsOneWidget);
    expect(savedPlan?.id, 'plan-1');
    expect(savedClips?.first.fadeOutMs, isNotNull);
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

  testWidgets('mixed row playback routes the canonical plan through playback',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _StubPlaylistService(
      tracks: [_track(1), _track(2)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
        'mixPlan': _mixPlanJson([1, 2]),
      },
    );

    final playback = await _pumpDetail(tester, service);
    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('mixed_track_2')),
        matching: find.text('Track 2'),
      ),
    );
    await tester.pumpAndSettle();

    expect(playback.playQueueCalls, isEmpty);
    expect(playback.mixPlanCalls, hasLength(1));
    expect(playback.mixPlanCalls.single.plan.id, 'plan-1');
    expect(playback.mixPlanCalls.single.startIndex, 1);
    expect(
      playback.mixPlanCalls.single.tracks.map((track) => track['id']),
      [1, 2],
    );
    expect(playback.mixPlanCalls.single.context?.id, '7');
  });

  testWidgets('unmappable canonical plan falls back to ordinary playback',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final service = _StubPlaylistService(
      tracks: [_track(1), _track(2)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
        'mixPlan': _mixPlanJson([1, 2]),
      },
    );
    final playback = _FakePlayback(rejectMixPlan: true);

    await _pumpDetail(tester, service, playback: playback);
    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('mixed_track_2')),
        matching: find.text('Track 2'),
      ),
    );
    await tester.pumpAndSettle();

    expect(playback.mixPlanCalls, hasLength(1));
    expect(playback.playQueueCalls, hasLength(1));
    expect(playback.playQueueCalls.single.startIndex, 1);
    expect(
      playback.playQueueCalls.single.tracks.map((track) => track['id']),
      [1, 2],
    );
  });

  testWidgets('collapsed seams re-expand on timeout and scroll end',
      (tester) async {
    tester.view.physicalSize = const Size(600, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final tracks = [for (var id = 1; id <= 8; id++) _track(id)];
    final service = _StubPlaylistService(
      tracks: tracks,
      autoMixResult: {
        'playlistId': 7,
        'transitions': [
          for (var id = 1; id < tracks.length; id++)
            _transitionJson(id, id + 1),
        ],
      },
    );
    await _pumpDetail(tester, service);
    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();

    final scrollable =
        tester.state<ScrollableState>(find.byType(Scrollable).first);
    final listContext = tester.element(find.byType(CustomScrollView));

    Future<void> dispatchFastPair() async {
      ScrollUpdateNotification(
        metrics: scrollable.position,
        context: listContext,
        scrollDelta: 1,
      ).dispatch(listContext);
      await tester.pump(const Duration(milliseconds: 1));
      ScrollUpdateNotification(
        metrics: scrollable.position,
        context: listContext,
        scrollDelta: 500,
      ).dispatch(listContext);
      await tester.pump();
    }

    await dispatchFastPair();
    expect(
      tester
          .widget<MixSeamConnector>(find.byType(MixSeamConnector).first)
          .collapsed,
      isTrue,
    );

    await tester.pump(const Duration(milliseconds: 181));
    expect(
      tester
          .widget<MixSeamConnector>(find.byType(MixSeamConnector).first)
          .collapsed,
      isFalse,
    );

    await dispatchFastPair();
    expect(
      tester
          .widget<MixSeamConnector>(find.byType(MixSeamConnector).first)
          .collapsed,
      isTrue,
    );
    ScrollEndNotification(
      metrics: scrollable.position,
      context: listContext,
    ).dispatch(listContext);
    await tester.pump();
    expect(
      tester
          .widget<MixSeamConnector>(find.byType(MixSeamConnector).first)
          .collapsed,
      isFalse,
    );
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
    expect(
        find.text('Could not blend this playlist. Try again.'), findsOneWidget);
  });
}
