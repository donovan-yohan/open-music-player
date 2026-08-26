import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart' as core_api;
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/playlists/harmonic_discovery_sheet.dart';
import 'package:open_music_player/features/playlists/playlist_detail_screen.dart';
import 'package:open_music_player/models/nearby_tracks.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:provider/provider.dart' as provider;
import 'package:shared_preferences/shared_preferences.dart';

/// Harmonic discovery is a DJ-facing surface, so it hides behind the same
/// user-controlled `djModeEnabled` switch as the rest of them. Unlike `/dj` it
/// allocates no audio voices and has no URL-reachable state, so the gate lives
/// on the entry point rather than on a route redirect — which makes the entry
/// point itself the thing that has to be tested.
const _actionKey = ValueKey('harmonic_discovery_action');

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

Track _track(int id, {double? bpm, String? camelot}) => Track(
      id: id,
      identityHash: 'h$id',
      title: 'Track $id',
      artist: 'Artist',
      durationMs: 200000,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      analysis: _analysis(bpm: bpm, camelot: camelot),
    );

class _StubPlaylistService extends PlaylistService {
  _StubPlaylistService()
      : super(api: core_api.ApiClient(storage: SecureStorage()));

  final List<({int playlistId, List<int> trackIds})> addedTracks = [];

  @override
  Future<Playlist> getPlaylist(int id) async => Playlist(
        id: id,
        name: 'Late Night',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        tracks: [_track(1, bpm: 124, camelot: '10B'), _track(2, bpm: 126)],
      );

  @override
  Future<AddTracksResult> addTracks(int playlistId, List<int> trackIds) async {
    addedTracks.add((playlistId: playlistId, trackIds: trackIds));
    return AddTracksResult(added: trackIds, skipped: const []);
  }
}

class _FakePlayback extends Fake implements PlaybackState {
  final List<Map<String, dynamic>> enqueued = [];

  @override
  Future<void> enqueue(Map<String, dynamic> track) async {
    enqueued.add(track);
  }

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

Widget _detail({
  _FakePlayback? playback,
  _StubPlaylistService? playlistService,
  HarmonicSearch? harmonicSearch,
}) =>
    provider.ListenableProvider<PlaybackState>.value(
      value: playback ?? _FakePlayback(),
      child: MaterialApp(
        home: PlaylistDetailScreen(
          playlistId: 7,
          playlistService: playlistService ?? _StubPlaylistService(),
          harmonicSearch: harmonicSearch,
        ),
      ),
    );

Future<void> _pumpWithSettings(
  WidgetTester tester,
  Map<String, Object> initialPrefs, {
  _FakePlayback? playback,
  _StubPlaylistService? playlistService,
  HarmonicSearch? harmonicSearch,
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: _detail(
        playback: playback,
        playlistService: playlistService,
        harmonicSearch: harmonicSearch,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Library matches the open playlist does not contain — the ordinary case,
/// since `/tracks/nearby` searches the whole library and the anchor is excluded.
const _libraryMatch = NearbyTrack(
  id: 99,
  title: 'Library Neighbour',
  artist: 'Neighbour Artist',
  durationMs: 214000,
  bpm: 126,
  camelot: '10B',
);
const _unknownLengthMatch = NearbyTrack(
  id: 98,
  title: 'Unmeasured Neighbour',
  bpm: 125,
  camelot: '10B',
);

typedef _Query = ({
  double bpm,
  String camelot,
  double tolerance,
  bool orderByHistory,
});

HarmonicSearch _recordingSearch(
  List<_Query> log, {
  List<NearbyTrack> tracks = const [],
}) {
  return ({
    required double bpm,
    required String camelot,
    required double tolerance,
    required bool orderByHistory,
  }) async {
    log.add((
      bpm: bpm,
      camelot: camelot,
      tolerance: tolerance,
      orderByHistory: orderByHistory,
    ));
    return NearbyTracksResult(
      tracks: tracks,
      bpm: bpm,
      camelot: camelot,
      tolerance: tolerance,
      orderedByHistory: orderByHistory,
    );
  };
}

/// Opens discovery from the app-bar entry point and taps one result's action.
Future<void> _actOnMatch(
  WidgetTester tester,
  NearbyTrack match,
  String actionKey,
) async {
  await tester.tap(find.byKey(ValueKey('harmonic_result_${match.id}')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(actionKey)));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('the harmonic discovery entry point is offered by default',
      (tester) async {
    await _pumpWithSettings(tester, <String, Object>{});

    expect(find.byKey(_actionKey), findsOneWidget);
  });

  testWidgets('turning DJ mode off hides the entry point', (tester) async {
    await _pumpWithSettings(tester, <String, Object>{
      'app_settings': '{"djModeEnabled":false}',
    });

    expect(find.byKey(_actionKey), findsNothing);
  });

  testWidgets('no ProviderScope means no recorded opt-in, so no entry point',
      (tester) async {
    // Exactly how the existing playlist-detail widget tests mount the screen.
    // With no settings to consult the gate must fail closed rather than
    // turning itself on, and the screen must still build.
    await tester.pumpWidget(_detail());
    await tester.pumpAndSettle();

    expect(find.byKey(_actionKey), findsNothing);
    expect(find.text('Late Night'), findsWidgets);
  });

  group('harmonicSeedFromTracks', () {
    test('prefers the first track with both a tempo and an on-wheel key', () {
      final seed = harmonicSeedFromTracks([
        _track(1),
        _track(2, bpm: 126),
        _track(3, bpm: 124, camelot: '8a'),
        _track(4, bpm: 128, camelot: '9A'),
      ]);

      expect(seed.trackId, 3);
      expect(seed.bpm, 124);
      expect(seed.camelot, '8A');
    });

    test('falls back to a tempo alone when no key is usable', () {
      final seed = harmonicSeedFromTracks([
        _track(1),
        _track(2, bpm: 126, camelot: '13Z'),
        _track(3, bpm: 128),
      ]);

      expect(seed.trackId, 2);
      expect(seed.bpm, 126);
      expect(seed.camelot, isNull);
    });

    test('returns nothing when no track has a usable tempo', () {
      final seed = harmonicSeedFromTracks([
        _track(1),
        _track(2, bpm: 0, camelot: '8A'),
        _track(3, camelot: '9A'),
      ]);

      expect(seed.trackId, isNull);
      expect(seed.bpm, isNull);
      expect(seed.camelot, isNull);
    });
  });

  group('the entry point drives the real screen wiring', () {
    testWidgets('opening discovery seeds the query and excludes the anchor',
        (tester) async {
      final log = <_Query>[];
      await _pumpWithSettings(
        tester,
        <String, Object>{},
        harmonicSearch: _recordingSearch(
          log,
          tracks: [
            // The anchor itself comes back from the library-wide query.
            const NearbyTrack(
                id: 1, title: 'Track 1', bpm: 124, camelot: '10B'),
            _libraryMatch,
          ],
        ),
      );

      await tester.tap(find.byKey(_actionKey));
      await tester.pumpAndSettle();

      expect(log, hasLength(1), reason: 'an analyzed anchor searches on open');
      expect(log.single.bpm, 124);
      expect(log.single.camelot, '10B');
      expect(log.single.tolerance, 5);
      expect(log.single.orderByHistory, isTrue);
      expect(
        find.byKey(const ValueKey('harmonic_result_1')),
        findsNothing,
        reason: 'the anchor is its own best match, so it is excluded',
      );
      expect(find.byKey(const ValueKey('harmonic_result_99')), findsOneWidget);
    });

    testWidgets('queueing a library match carries its real length',
        (tester) async {
      final playback = _FakePlayback();
      await _pumpWithSettings(
        tester,
        <String, Object>{},
        playback: playback,
        harmonicSearch: _recordingSearch(<_Query>[], tracks: [
          _libraryMatch,
        ]),
      );

      await tester.tap(find.byKey(_actionKey));
      await tester.pumpAndSettle();
      await _actOnMatch(
        tester,
        _libraryMatch,
        'harmonic_action_add_to_queue',
      );

      expect(playback.enqueued, hasLength(1));
      expect(playback.enqueued.single['id'], 99);
      expect(playback.enqueued.single['title'], 'Library Neighbour');
      expect(
        playback.enqueued.single['duration'],
        214,
        reason: 'a zero-length queue item is never active in the timeline',
      );
      expect(
        find.byType(HarmonicDiscoverySheet),
        findsNothing,
        reason: 'discovery closes so its host screen SnackBar is visible',
      );
      expect(find.text('Added "Library Neighbour" to queue'), findsOneWidget);
    });

    testWidgets('a match with no known length is refused, not queued',
        (tester) async {
      final playback = _FakePlayback();
      await _pumpWithSettings(
        tester,
        <String, Object>{},
        playback: playback,
        harmonicSearch: _recordingSearch(<_Query>[], tracks: [
          _unknownLengthMatch,
        ]),
      );

      await tester.tap(find.byKey(_actionKey));
      await tester.pumpAndSettle();
      await _actOnMatch(
        tester,
        _unknownLengthMatch,
        'harmonic_action_add_to_queue',
      );

      expect(playback.enqueued, isEmpty);
      expect(
        find.text(
          'Could not add "Unmeasured Neighbour" to queue: its length is unknown.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a match already in this playlist reuses its own payload',
        (tester) async {
      final playback = _FakePlayback();
      await _pumpWithSettings(
        tester,
        <String, Object>{},
        playback: playback,
        harmonicSearch: _recordingSearch(<_Query>[], tracks: [
          // Track 2 is on screen: full duration/artwork/analysis are known.
          const NearbyTrack(id: 2, title: 'Track 2', bpm: 126, camelot: '10B'),
        ]),
      );

      await tester.tap(find.byKey(_actionKey));
      await tester.pumpAndSettle();
      await _actOnMatch(
        tester,
        const NearbyTrack(id: 2, title: 'Track 2'),
        'harmonic_action_add_to_queue',
      );

      expect(playback.enqueued, hasLength(1));
      expect(playback.enqueued.single['id'], 2);
      expect(playback.enqueued.single['duration'], 200);
    });

    testWidgets('adding a match to this playlist reports the outcome',
        (tester) async {
      final playlistService = _StubPlaylistService();
      await _pumpWithSettings(
        tester,
        <String, Object>{},
        playlistService: playlistService,
        harmonicSearch: _recordingSearch(<_Query>[], tracks: [
          _libraryMatch,
        ]),
      );

      await tester.tap(find.byKey(_actionKey));
      await tester.pumpAndSettle();
      await _actOnMatch(
        tester,
        _libraryMatch,
        'harmonic_action_add_to_playlist',
      );

      expect(playlistService.addedTracks, hasLength(1));
      expect(playlistService.addedTracks.single.playlistId, 7);
      expect(playlistService.addedTracks.single.trackIds, [99]);
      expect(find.byType(HarmonicDiscoverySheet), findsNothing);
      expect(find.text('Added to "Late Night"'), findsOneWidget);
    });
  });
}
