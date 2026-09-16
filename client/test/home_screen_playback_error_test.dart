import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/features/home/home_screen.dart';

/// Regression for the field report: a Home "Recently played" row could be
/// tapped and do nothing at all.
///
/// That feed comes from the user's play *history*, which can contain tracks no
/// longer in their library. `/api/v1/playback/urls` correctly refuses those with
/// a deliberately opaque 404 (`TRACK_NOT_FOUND`, indistinguishable from a
/// missing track — pinned by the backend's
/// `TestPlaybackURLIssuanceHidesNonOwnedTrackExistence`), and `playQueue`
/// throws.
///
/// Home's handler was fire-and-forget, so the exception escaped unhandled: no
/// snackbar, no state change, an invisible failure. Every other list surface
/// (Library, Liked Songs, Listening History, local browse, queue) already
/// caught and reported it.
void main() {
  testWidgets(
      'tapping an unplayable Home row reports why instead of doing nothing',
      (tester) async {
    final playback = _ThrowingPlaybackState(
      error: 'This track is no longer available.',
    );

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: playback,
        child: MaterialApp(
          home: HomeScreen(
            homeService: HomeService(
              _HistoryApiClient({
                'tracks': [
                  {
                    'id': 47,
                    'title': 'Gone Track',
                    'artist': 'Artist',
                    'durationMs': 90000,
                  },
                ],
                'limit': 20,
                'offset': 0,
              }),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The row renders and looks playable — which is exactly the trap.
    expect(find.text('Gone Track'), findsOneWidget);

    await tester.tap(find.text('Gone Track'));
    await tester.pumpAndSettle();

    expect(
      find.text('This track is no longer available.'),
      findsOneWidget,
      reason: 'a failed start must be visible; silently doing nothing is what '
          'made this look like an intermittent app bug',
    );
  });
}

class _ThrowingPlaybackState extends Fake implements PlaybackState {
  _ThrowingPlaybackState({required this.error});

  final String error;

  @override
  Future<void> playQueue(
    List<Map<String, dynamic>> tracks, {
    int startIndex = 0,
    PlaybackContext? context,
  }) async {
    throw const SignedAudioUrlException(
      code: 'TRACK_NOT_FOUND',
      message: 'track not found',
    );
  }

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  String? get playbackError => error;
}

/// Returns a recent-play list containing one track: the history row that is no
/// longer in the library.
class _HistoryApiClient extends ApiClient {
  _HistoryApiClient(this.recentBody);

  final Map<String, dynamic> recentBody;

  @override
  Future<Response<T>> get<T>(
    String path, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? headers,
    Duration? receiveTimeout,
  }) async {
    final data = path.contains('/me/plays/recent')
        ? recentBody
        : const {'tracks': [], 'playlists': []};
    return Response<T>(
      requestOptions: RequestOptions(path: path),
      statusCode: 200,
      data: data as T,
    );
  }
}
