import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/api/api_client.dart' as dio_api;
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/services/api_client.dart' as parser_api;
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/features/library/local_browse_screens.dart';
import 'package:open_music_player/features/playlists/playlist_detail_screen.dart';
import 'package:open_music_player/shared/models/playlist.dart';
import 'package:open_music_player/shared/models/track.dart';

Track _analyzedTrack() => Track.fromJson({
      'id': 42,
      'title': 'Metadata Song',
      'artist': 'Analyzer',
      'durationMs': 180000,
      'analysisStatus': 'analyzed',
      'analysisSummary': {
        'bpm': {'value': 128},
        'key': {'value': 'Am'},
        'camelot': {'value': '8A'},
      },
    });

void _expectMetadata() {
  expect(find.text('128 BPM'), findsOneWidget);
  expect(find.text('8A'), findsOneWidget);
}

void main() {
  testWidgets('Home song rows render shared metadata chips', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(homeService: _HomeService(_analyzedTrack())),
      ),
    );
    await tester.pumpAndSettle();

    _expectMetadata();
  });

  testWidgets('Library browse rows render shared metadata chips', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: LocalBrowseView(
          title: 'Library artist',
          subtitle: 'Artist',
          loader: () async => [_analyzedTrack()],
        ),
      ),
    );
    await tester.pumpAndSettle();

    _expectMetadata();
  });

  testWidgets('Playlist rows render shared metadata chips', (tester) async {
    final now = DateTime.utc(2026);
    final playlist = Playlist(
      id: 9,
      name: 'Analyzed playlist',
      createdAt: now,
      updatedAt: now,
      tracks: [_analyzedTrack()],
    );

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: _FakePlaybackState(),
        child: MaterialApp(
          home: PlaylistDetailScreen(
            playlistId: playlist.id,
            playlistService: _PlaylistService(playlist),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    _expectMetadata();
  });
}

class _HomeService extends HomeService {
  _HomeService(this.track) : super(parser_api.ApiClient());

  final Track track;

  @override
  Future<List<Track>> recentlyPlayed({int limit = 20}) async => [track];

  @override
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) async => [];

  @override
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) async =>
      [];
}

class _PlaylistService extends PlaylistService {
  _PlaylistService(this.playlist) : super(api: dio_api.ApiClient());

  final Playlist playlist;

  @override
  Future<Playlist> getPlaylist(int id) async => playlist;
}

class _FakePlaybackState extends Fake implements PlaybackState {
  @override
  PlaybackContext? get playbackContext => null;

  @override
  MediaItem? get currentItem => null;

  @override
  bool get isPlaying => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}
