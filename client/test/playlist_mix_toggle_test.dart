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
      // Consistent with _mixPlanJson: fades equal the placement overlap.
      'overlapMs': 10000,
      'confidence': {
        'keyMatch': keyMatch,
        'tempoMatched': tempoMatched,
        'tempoShift': tempoShift,
        'simpleFade': simpleFade,
      },
    };

Map<String, dynamic> _mixPlanJson(List<int> trackIds) {
  var cursorMs = 0;
  const overlapMs = 10000;
  final clips = <Map<String, dynamic>>[];
  for (var index = 0; index < trackIds.length; index++) {
    final startMs = index == 0 ? 0 : cursorMs - overlapMs;
    clips.add({
      'clipId': 'clip-${index + 1}',
      'queueItemId': 'queue-${index + 1}',
      'trackId': trackIds[index],
      'sourceStartMs': 0,
      'sourceEndMs': 200000,
      'timelineStartMs': startMs,
      'gainDb': index == 1 ? -1.5 : 0,
      // Generator invariant: fadeOut(i) == fadeIn(i+1) == placement overlap.
      if (index > 0) 'fadeInMs': overlapMs,
      if (index < trackIds.length - 1) 'fadeOutMs': overlapMs,
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
    // Fixture models the generator invariant: fades equal the overlap.
    expect(parsed.mixPlan?.clips.first.fadeOutMs, 10000);
    expect(parsed.mixPlan?.clips.last.fadeInMs, 10000);

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
    // Server reports Blend (beat-aligned), but the engine-honest badge (F-4)
    // renders Fade until filter automation ships.
    expect(find.text('Fade'), findsNWidgets(2));
    // Overlap label: 10000 ms -> "10s · 8 bars" (consistent fixture).
    expect(find.text('10s · 8 bars'), findsNWidgets(2));

    // BPM + Camelot badges render for analyzed tracks.
    expect(find.text('124 BPM'), findsOneWidget);
    expect(find.text('10B'), findsOneWidget);

    // Smart Reorder lives in the mix toolbar and is only offered while the
    // blended view is on, where it can regenerate the plan with the order.
    expect(
      find.byKey(const ValueKey('mix_reorder_button')),
      findsOneWidget,
    );
  });

  testWidgets('a seam the plan does not describe stays Fade, not Cut',
      (tester) async {
    // A null transition means the pair is absent from the plan (a
    // reorder-failure reload, say), not a zero-overlap seam. Reading the
    // missing overlap as a Cut would contradict the sub-label and the
    // semantic label, which both still describe a fade.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MixSeamConnector(
            transition: null,
            collapsed: false,
            onTap: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fade'), findsOneWidget);
    expect(find.text('Cut'), findsNothing);
    expect(find.text('Simple fade between tracks'), findsOneWidget);

    final connector =
        tester.widget<MixSeamConnector>(find.byType(MixSeamConnector));
    expect(connector.preset, 'Fade');
    expect(
      connector.semanticLabel,
      'Simple fade transition into next track, Fade preset',
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

    List<MixPlanClip>? savedClips;
    await _pumpDetail(
      tester,
      service,
      onSaveMixPlan: (plan, clips) async {
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
    // Fades and placement move together to preserve the generator invariant
    // fadeOut(i) == fadeIn(i+1) == placement overlap. The fixture is now
    // internally consistent (transition overlap == clip fades == 10000), so
    // an untouched save is a byte-for-byte no-op: the editor seeds from the
    // persisted fades, placementDelta is zero, and nothing moves.
    expect(savedClips?.first.fadeOutMs, 10000);
    expect(savedClips?.last.fadeInMs, 10000);
    final outgoing = savedClips!.first;
    final incoming = savedClips!.last;
    // Timeline overlap: outgoing end minus incoming start.
    final audibleOverlap =
        (outgoing.timelineStartMs + outgoing.selectedDurationMs) -
            incoming.timelineStartMs;
    expect(audibleOverlap, 10000);
    // Untouched-save no-op: geometry identical to the original fixture.
    expect(incoming.timelineStartMs, 200000 - 10000);
  });

  testWidgets('editing one seam of a three-track plan preserves every seam',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Matches _mixPlanJson's overlap for a generator-shaped plan.
    const originalOverlapMs = 10000;
    List<MixPlanClip>? savedClips;

    final service = _StubPlaylistService(
      tracks: [_track(1), _track(2), _track(3)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [
          _transitionJson(1, 2),
          _transitionJson(2, 3),
        ],
        'mixPlan': _mixPlanJson([1, 2, 3]),
      },
    );

    await _pumpDetail(
      tester,
      service,
      onSaveMixPlan: (plan, clips) async {
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

    void assertInvariant(List<MixPlanClip> clips) {
      for (var i = 0; i + 1 < clips.length; i++) {
        final placementOverlap =
            (clips[i].timelineStartMs + clips[i].selectedDurationMs) -
                clips[i + 1].timelineStartMs;
        expect(clips[i].fadeOutMs, placementOverlap, reason: 'seam $i fadeOut');
        expect(clips[i + 1].fadeInMs, placementOverlap,
            reason: 'seam $i fadeIn');
      }
    }

    // Open seam 1_2 and grow it to double length.
    await tester.drag(
        find.text('Blended 2 transitions. Tap any seam to adjust.'),
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

    // Use the + stepper four times: deterministic +2000 ms total without
    // depending on canvas width for drag scaling.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
    }
    await tester.tap(find.text('Save transition'));
    await tester.pumpAndSettle();

    expect(find.text('Transition saved'), findsOneWidget);
    final clips = savedClips!;
    expect(clips, hasLength(3));
    // The edited seam grew by 4 x 500 ms; downstream tail shifted with it.
    const newSeam0Overlap = originalOverlapMs + 2000;
    expect(clips[0].fadeOutMs, newSeam0Overlap);
    expect(clips[1].fadeInMs, newSeam0Overlap);
    expect(
      (clips[0].timelineStartMs + clips[0].selectedDurationMs) -
          clips[1].timelineStartMs,
      newSeam0Overlap,
    );
    // Seam 1 keeps its exact original geometry.
    expect(clips[1].fadeOutMs, originalOverlapMs);
    expect(clips[2].fadeInMs, originalOverlapMs);
    expect(
      (clips[1].timelineStartMs + clips[1].selectedDurationMs) -
          clips[2].timelineStartMs,
      originalOverlapMs,
    );
    assertInvariant(clips);
  });

  testWidgets('shortening one seam of a three-track plan preserves every seam',
      (tester) async {
    tester.view.physicalSize = const Size(600, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const originalOverlapMs = 10000;
    List<MixPlanClip>? savedClips;

    final service = _StubPlaylistService(
      tracks: [_track(1), _track(2), _track(3)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [
          _transitionJson(1, 2),
          _transitionJson(2, 3),
        ],
        'mixPlan': _mixPlanJson([1, 2, 3]),
      },
    );

    await _pumpDetail(
      tester,
      service,
      onSaveMixPlan: (plan, clips) async {
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

    void assertInvariant(List<MixPlanClip> clips) {
      for (var i = 0; i + 1 < clips.length; i++) {
        final placementOverlap =
            (clips[i].timelineStartMs + clips[i].selectedDurationMs) -
                clips[i + 1].timelineStartMs;
        expect(clips[i].fadeOutMs, placementOverlap, reason: 'seam $i fadeOut');
        expect(clips[i + 1].fadeInMs, placementOverlap,
            reason: 'seam $i fadeIn');
      }
    }

    await tester.drag(
        find.text('Blended 2 transitions. Tap any seam to adjust.'),
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

    // Shorten by four stepper steps (-2000 ms total), the mirror of the
    // lengthen case above.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byIcon(Icons.remove));
      await tester.pump();
    }
    await tester.tap(find.text('Save transition'));
    await tester.pumpAndSettle();

    expect(find.text('Transition saved'), findsOneWidget);
    final clips = savedClips!;
    const newSeam0Overlap = originalOverlapMs - 2000;
    expect(clips[0].fadeOutMs, newSeam0Overlap);
    expect(clips[1].fadeInMs, newSeam0Overlap);
    expect(
      (clips[0].timelineStartMs + clips[0].selectedDurationMs) -
          clips[1].timelineStartMs,
      newSeam0Overlap,
    );
    expect(clips[1].fadeOutMs, originalOverlapMs);
    expect(clips[2].fadeInMs, originalOverlapMs);
    expect(
      (clips[1].timelineStartMs + clips[1].selectedDurationMs) -
          clips[2].timelineStartMs,
      originalOverlapMs,
    );
    assertInvariant(clips);
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
