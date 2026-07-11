import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/features/settings/listening_history_screen.dart';

void main() {
  testWidgets('renders raw listening history and plays a tapped entry',
      (tester) async {
    final playback = _FakePlaybackState();
    final service = HomeService(_HistoryApiClient({
      'plays': [
        {
          'id': 2,
          'playedAt': DateTime.now()
              .subtract(const Duration(minutes: 5))
              .toIso8601String(),
          'track': {
            'id': 7,
            'title': 'Repeat Song',
            'artist': 'Artist',
            'analysisStatus': 'analyzed',
            'analysisSummary': {
              'bpm': {'value': 126},
              'key': {'value': 'Am'},
              'camelot': {'value': '8A'},
            },
          },
        },
        {
          'id': 1,
          'playedAt': DateTime.now()
              .subtract(const Duration(hours: 1))
              .toIso8601String(),
          'track': {
            'id': 7,
            'title': 'Repeat Song',
            'artist': 'Artist',
            'analysisStatus': 'analyzed',
            'analysisSummary': {
              'bpm': {'value': 126},
              'key': {'value': 'Am'},
              'camelot': {'value': '8A'},
            },
          },
        },
      ],
    }));

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: playback,
        child: MaterialApp(
          home: ListeningHistoryScreen(service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Listening History'), findsOneWidget);
    expect(find.text('Repeat Song'), findsNWidgets(2));
    expect(find.text('5m ago'), findsOneWidget);
    expect(find.text('126 BPM'), findsNWidgets(2));
    expect(find.text('8A'), findsNWidgets(2));

    await tester.tap(find.text('Repeat Song').first);
    await tester.pumpAndSettle();

    expect(playback.playQueueCalls, hasLength(1));
    expect(playback.playQueueCalls.single.tracks.single['id'], 7);
    expect(playback.playQueueCalls.single.context?.label, 'Listening History');
  });
}

class _HistoryApiClient extends ApiClient {
  _HistoryApiClient(this.body);

  final Map<String, dynamic> body;

  @override
  Future<T> get<T>(
    String endpoint, {
    T Function(Map<String, dynamic>)? parser,
    T Function(List<dynamic>)? listParser,
    Map<String, String>? queryParams,
    bool requiresAuth = true,
  }) async {
    return parser!(body);
  }
}

class _FakePlaybackState extends Fake implements PlaybackState {
  final List<
      ({
        List<Map<String, dynamic>> tracks,
        PlaybackContext? context,
      })> playQueueCalls = [];

  @override
  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    playQueueCalls.add((tracks: tracks, context: context));
  }

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  String? get playbackError => null;
}
