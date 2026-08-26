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

  @override
  Future<Playlist> getPlaylist(int id) async => Playlist(
        id: id,
        name: 'Late Night',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        tracks: [_track(1, bpm: 124, camelot: '10B'), _track(2, bpm: 126)],
      );
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

Widget _detail() => provider.ListenableProvider<PlaybackState>.value(
      value: _FakePlayback(),
      child: MaterialApp(
        home: PlaylistDetailScreen(
          playlistId: 7,
          playlistService: _StubPlaylistService(),
        ),
      ),
    );

Future<void> _pumpWithSettings(
  WidgetTester tester,
  Map<String, Object> initialPrefs,
) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: _detail(),
    ),
  );
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
}
