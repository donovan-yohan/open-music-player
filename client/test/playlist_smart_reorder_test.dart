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
import 'package:open_music_player/features/playlists/playlist_detail_screen.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:provider/provider.dart';

const int _trackDurationMs = 200000;
const int _overlapMs = 10000;

Track _track(int id, {double? bpm, String? camelot}) => Track(
      id: id,
      identityHash: 'h$id',
      title: 'Track $id',
      artist: 'Artist',
      durationMs: _trackDurationMs,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      analysis: bpm == null && camelot == null
          ? null
          : TrackAnalysis(
              status: TrackAnalysisStatus.analyzed,
              summary: TrackAnalysisSummary(
                bpm: bpm == null ? null : AnalysisValue(value: bpm),
                camelot: camelot == null ? null : AnalysisValue(value: camelot),
              ),
            ),
    );

Map<String, dynamic> _transitionJson(int outgoing, int incoming) => {
      'index': 0,
      'outgoingTrackId': outgoing,
      'incomingTrackId': incoming,
      'preset': 'Blend',
      'bars': 8,
      'overlapMs': _overlapMs,
      'confidence': {
        'keyMatch': true,
        'tempoMatched': true,
        'tempoShift': false,
        'simpleFade': false,
      },
    };

Map<String, dynamic> _mixPlanJson(List<int> trackIds, {int version = 1}) {
  var cursorMs = 0;
  final clips = <Map<String, dynamic>>[];
  for (var index = 0; index < trackIds.length; index++) {
    final startMs = index == 0 ? 0 : cursorMs - _overlapMs;
    clips.add({
      'clipId': 'clip-${index + 1}',
      'queueItemId': 'queue-${index + 1}',
      'trackId': trackIds[index],
      'sourceStartMs': 0,
      'sourceEndMs': _trackDurationMs,
      'timelineStartMs': startMs,
      'gainDb': 0,
      if (index > 0) 'fadeInMs': _overlapMs,
      if (index < trackIds.length - 1) 'fadeOutMs': _overlapMs,
    });
    cursorMs = startMs + _trackDurationMs;
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
    'version': version,
    'createdAt': '2026-08-24T00:00:00Z',
    'updatedAt': '2026-08-24T00:00:00Z',
  };
}

class _StubPlaylistService extends PlaylistService {
  _StubPlaylistService({
    required this.tracks,
    required this.autoMixResult,
    this.smartReorderResult,
    this.failSmartReorder = false,
    this.smartReorderError,
    this.failReload = false,
  }) : super(api: core_api.ApiClient(storage: SecureStorage()));

  final List<Track> tracks;
  final Map<String, dynamic> autoMixResult;
  final Map<String, dynamic>? smartReorderResult;
  final bool failSmartReorder;

  /// A specific failure to throw instead of the generic one, so the screen's
  /// handling of a deliberate server rejection can be driven.
  final Object? smartReorderError;

  /// When true every [getPlaylist] after the screen's initial load throws, so
  /// the failure-recovery reload can be made to fail too.
  final bool failReload;

  int getPlaylistCalls = 0;
  int smartReorderCalls = 0;
  String? lastMixPlanId;
  bool? lastRegeneratePlan;

  @override
  Future<Playlist> getPlaylist(int id) async {
    getPlaylistCalls++;
    if (failReload && getPlaylistCalls > 1) {
      throw Exception('playlist reload unavailable');
    }
    return Playlist(
      id: id,
      name: 'Mix',
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      tracks: tracks,
    );
  }

  @override
  Future<AutoMixResult> autoMix(int playlistId) async =>
      AutoMixResult.fromJson(autoMixResult);

  @override
  Future<SmartReorderResult> smartReorder(
    int playlistId, {
    String? mixPlanId,
    bool regeneratePlan = true,
  }) async {
    smartReorderCalls++;
    lastMixPlanId = mixPlanId;
    lastRegeneratePlan = regeneratePlan;
    final error = smartReorderError;
    if (error != null) throw error;
    if (failSmartReorder) throw Exception('smart reorder unavailable');
    return SmartReorderResult.fromJson(smartReorderResult!);
  }
}

class _FakePlayback extends Fake implements PlaybackState {
  final List<({List<Map<String, dynamic>> tracks, MixPlan plan, int startIndex})>
      mixPlanCalls = [];
  final List<({MixPlan plan, int seamIndex})> previewCalls = [];
  int endPreviewCalls = 0;

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
    mixPlanCalls.add((tracks: tracks, plan: plan, startIndex: startIndex));
  }

  @override
  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {}

  @override
  Future<void> previewMixSeam(
    List<Map<String, dynamic>> tracks,
    MixPlan plan, {
    required int seamIndex,
    Duration leadIn = const Duration(seconds: 6),
    PlaybackContext? context,
  }) async {
    previewCalls.add((plan: plan, seamIndex: seamIndex));
  }

  @override
  Future<void> endMixSeamPreview() async {
    endPreviewCalls++;
  }
}

Future<_FakePlayback> _pumpMixed(
  WidgetTester tester,
  PlaylistService service, {
  Future<MixPlan> Function(MixPlan plan, List<MixPlanClip> clips)?
      onSaveMixPlan,
}) async {
  tester.view.physicalSize = const Size(700, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final playback = _FakePlayback();
  await tester.pumpWidget(
    ListenableProvider<PlaybackState>.value(
      value: playback,
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
  await tester.tap(find.byKey(const ValueKey('mix_toggle')));
  await tester.pumpAndSettle();
  return playback;
}

Future<void> _dismissToasts(WidgetTester tester) async {
  final messenger = tester.state<ScaffoldMessengerState>(
    find.byType(ScaffoldMessenger),
  );
  messenger.removeCurrentSnackBar();
  await tester.pumpAndSettle();
}

Future<void> _openFirstSeam(WidgetTester tester, String seamKey) async {
  await tester.tap(
    find
        .descendant(
          of: find.byKey(Key(seamKey)),
          matching: find.byType(InkWell),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('smart reorder persists the order the list shows and plays',
      (tester) async {
    final service = _StubPlaylistService(
      tracks: [
        _track(1, bpm: 120, camelot: '8A'),
        _track(2, bpm: 160, camelot: '2B'),
        _track(3, bpm: 121, camelot: '8B'),
      ],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2), _transitionJson(2, 3)],
        'mixPlan': _mixPlanJson([1, 2, 3]),
      },
      smartReorderResult: {
        'playlistId': 7,
        'order': [1, 3, 2],
        'planVersion': 2,
        'editedSeamsKept': 1,
        'seamsRegenerated': 1,
        'transitions': [_transitionJson(1, 3), _transitionJson(3, 2)],
        'mixPlan': _mixPlanJson([1, 3, 2], version: 2),
      },
    );

    final playback = await _pumpMixed(tester, service);
    expect(find.byKey(const Key('mix_seam_1_2')), findsOneWidget);
    await _dismissToasts(tester);

    await tester.tap(find.byKey(const ValueKey('mix_reorder_button')));
    await tester.pumpAndSettle();

    expect(service.smartReorderCalls, 1);
    // The active plan is named so the server can keep it coherent with the
    // order it just persisted.
    expect(service.lastMixPlanId, 'plan-1');
    expect(service.lastRegeneratePlan, isTrue);

    // Displayed order follows the persisted order.
    expect(find.byKey(const Key('mix_seam_1_3')), findsOneWidget);
    expect(find.byKey(const Key('mix_seam_3_2')), findsOneWidget);
    expect(find.byKey(const Key('mix_seam_1_2')), findsNothing);
    expect(
      find.text('Reordered by tempo and key — reblended 1, kept 1 edited.'),
      findsOneWidget,
    );
    await _dismissToasts(tester);

    // Played order is the same order, through the regenerated plan.
    await tester.tap(
      find.descendant(
        of: find.byKey(const Key('mixed_track_3')),
        matching: find.text('Track 3'),
      ),
    );
    await tester.pumpAndSettle();

    expect(playback.mixPlanCalls, hasLength(1));
    final call = playback.mixPlanCalls.single;
    expect(call.tracks.map((track) => track['id']), [1, 3, 2]);
    expect(call.plan.clips.map((clip) => clip.trackId), ['1', '3', '2']);
    expect(call.plan.version, 2);
    // Tapping the second row starts there.
    expect(call.startIndex, 1);
  });

  testWidgets('an order-only reorder drops a plan it no longer describes',
      (tester) async {
    final service = _StubPlaylistService(
      tracks: [_track(1, bpm: 120), _track(2, bpm: 160)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
        'mixPlan': _mixPlanJson([1, 2]),
      },
      smartReorderResult: {
        'playlistId': 7,
        'order': [2, 1],
        'editedSeamsKept': 0,
        'seamsRegenerated': 0,
      },
    );

    await _pumpMixed(tester, service);
    await _dismissToasts(tester);

    await tester.tap(find.byKey(const ValueKey('mix_reorder_button')));
    await tester.pumpAndSettle();

    // No plan came back, so the blended view is torn down rather than left
    // showing seams for an order the plan no longer matches.
    expect(find.byKey(const Key('mix_seam_2_1')), findsNothing);
    expect(find.byKey(const Key('mixed_track_1')), findsNothing);
    expect(find.text('Reordered by tempo and key.'), findsOneWidget);
  });

  testWidgets('smart reorder failure keeps the current order and warns',
      (tester) async {
    final service = _StubPlaylistService(
      tracks: [_track(1, bpm: 120), _track(2, bpm: 160)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
        'mixPlan': _mixPlanJson([1, 2]),
      },
      failSmartReorder: true,
    );

    await _pumpMixed(tester, service);
    await _dismissToasts(tester);

    await tester.tap(find.byKey(const ValueKey('mix_reorder_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('mix_seam_1_2')), findsOneWidget);
    expect(
      find.text('Could not reorder this playlist. Try again.'),
      findsOneWidget,
    );
  });

  testWidgets('a server rejection is shown verbatim, not as a generic retry',
      (tester) async {
    // F-6 rejects a plan that is not linked to this playlist, and the message
    // is the only thing that tells the user how to recover. Swallowing it
    // under "Try again" makes the reorder button look broken forever.
    const serverMessage =
        'mix plan is not linked to this playlist; reblend from the playlist first';
    final service = _StubPlaylistService(
      tracks: [_track(1, bpm: 120), _track(2, bpm: 160)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
        'mixPlan': _mixPlanJson([1, 2]),
      },
      smartReorderError: core_api.ApiException(
        serverMessage,
        400,
        errorCode: 'VALIDATION_ERROR',
      ),
    );

    await _pumpMixed(tester, service);
    await _dismissToasts(tester);

    await tester.tap(find.byKey(const ValueKey('mix_reorder_button')));
    await tester.pumpAndSettle();

    expect(find.text(serverMessage), findsOneWidget);
    expect(
      find.text('Could not reorder this playlist. Try again.'),
      findsNothing,
    );
    // The recovery path still runs: the order we hold is reloaded, not left
    // in whatever state the failed call implied.
    expect(find.byKey(const Key('mix_seam_1_2')), findsOneWidget);
  });

  testWidgets('a failed recovery reload still reports the server message',
      (tester) async {
    // The outage that rejects the reorder usually takes the reload with it.
    // If the reload throws unguarded the message never reaches the user and
    // the reorder button looks silently broken.
    const serverMessage =
        'mix plan is not linked to this playlist; reblend from the playlist first';
    final service = _StubPlaylistService(
      tracks: [_track(1, bpm: 120), _track(2, bpm: 160)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
        'mixPlan': _mixPlanJson([1, 2]),
      },
      smartReorderError: core_api.ApiException(
        serverMessage,
        400,
        errorCode: 'VALIDATION_ERROR',
      ),
      failReload: true,
    );

    final playback = await _pumpMixed(tester, service);
    await _dismissToasts(tester);

    await tester.tap(find.byKey(const ValueKey('mix_reorder_button')));
    await tester.pumpAndSettle();

    // The reload was attempted and threw, and the message survived it.
    expect(service.getPlaylistCalls, greaterThan(1));
    expect(find.text(serverMessage), findsOneWidget);
    // The blended view is kept on the order we already hold rather than torn
    // down by the reload failure.
    expect(find.byKey(const Key('mix_seam_1_2')), findsOneWidget);
    expect(playback.mixPlanCalls, isEmpty);
  });

  testWidgets('the Cut preset saves zero fades and butt-joins the clips',
      (tester) async {
    List<MixPlanClip>? savedClips;
    final service = _StubPlaylistService(
      tracks: [_track(1, bpm: 120), _track(2, bpm: 121), _track(3, bpm: 122)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2), _transitionJson(2, 3)],
        'mixPlan': _mixPlanJson([1, 2, 3]),
      },
      smartReorderResult: const {},
    );

    await _pumpMixed(
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
    await _dismissToasts(tester);
    await _openFirstSeam(tester, 'mix_seam_1_2');

    // Only presets the engine can render are offered.
    expect(find.byKey(const ValueKey('mix_preset_fade')), findsOneWidget);
    expect(find.byKey(const ValueKey('mix_preset_cut')), findsOneWidget);
    expect(find.text('Rise'), findsNothing);
    expect(find.text('Slam'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mix_preset_cut')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save transition'));
    await tester.pumpAndSettle();

    final clips = savedClips!;
    expect(clips, hasLength(3));
    expect(clips[0].fadeOutMs, 0);
    expect(clips[1].fadeInMs, 0);
    // Butt-joined: the incoming clip starts exactly where the outgoing ends.
    expect(clips[1].timelineStartMs, clips[0].timelineEndMs);
    // The untouched downstream seam keeps its exact geometry.
    expect(clips[1].fadeOutMs, _overlapMs);
    expect(clips[2].fadeInMs, _overlapMs);
    expect(
      clips[1].timelineEndMs - clips[2].timelineStartMs,
      _overlapMs,
    );

    // The seam now reads as a cut in the blended list.
    expect(find.text('Cut'), findsWidgets);
    expect(find.text('No overlap'), findsOneWidget);
  });

  testWidgets('preview auditions the draft and is released on dismissal',
      (tester) async {
    final service = _StubPlaylistService(
      tracks: [_track(1, bpm: 120), _track(2, bpm: 121)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
        'mixPlan': _mixPlanJson([1, 2]),
      },
      smartReorderResult: const {},
    );

    final playback = await _pumpMixed(tester, service);
    await _dismissToasts(tester);
    await _openFirstSeam(tester, 'mix_seam_1_2');

    // Lengthen the seam, then audition the draft — not the persisted plan.
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byIcon(Icons.add));
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('mix_preview_button')));
    await tester.pumpAndSettle();

    expect(playback.previewCalls, hasLength(1));
    final preview = playback.previewCalls.single;
    expect(preview.seamIndex, 0);
    expect(preview.plan.clips[0].fadeOutMs, _overlapMs + 2000);
    expect(preview.plan.clips[1].fadeInMs, _overlapMs + 2000);
    expect(find.text('Stop'), findsOneWidget);
    // Nothing has been persisted by previewing.
    expect(playback.endPreviewCalls, 0);

    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();

    // The borrowed queue is handed back exactly once on dismissal.
    expect(playback.endPreviewCalls, 1);
  });

  testWidgets('preview is released when the sheet closes without a decision',
      (tester) async {
    final service = _StubPlaylistService(
      tracks: [_track(1, bpm: 120), _track(2, bpm: 121)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
        'mixPlan': _mixPlanJson([1, 2]),
      },
      smartReorderResult: const {},
    );

    final playback = await _pumpMixed(tester, service);
    await _dismissToasts(tester);
    await _openFirstSeam(tester, 'mix_seam_1_2');

    await tester.tap(find.byKey(const ValueKey('mix_preview_button')));
    await tester.pumpAndSettle();
    expect(playback.previewCalls, hasLength(1));

    // Route torn down without Save or Discard, e.g. a system back gesture.
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.pop();
    await tester.pumpAndSettle();

    expect(playback.endPreviewCalls, 1);
  });

  testWidgets('switching preset stops a running preview', (tester) async {
    final service = _StubPlaylistService(
      tracks: [_track(1, bpm: 120), _track(2, bpm: 121)],
      autoMixResult: {
        'playlistId': 7,
        'transitions': [_transitionJson(1, 2)],
        'mixPlan': _mixPlanJson([1, 2]),
      },
      smartReorderResult: const {},
    );

    final playback = await _pumpMixed(tester, service);
    await _dismissToasts(tester);
    await _openFirstSeam(tester, 'mix_seam_1_2');

    await tester.tap(find.byKey(const ValueKey('mix_preview_button')));
    await tester.pumpAndSettle();
    expect(find.text('Stop'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mix_preset_cut')));
    await tester.pumpAndSettle();

    // The running preview no longer matches what would be saved, so it ends.
    expect(playback.endPreviewCalls, 1);
    expect(find.text('Preview'), findsOneWidget);
  });
}
