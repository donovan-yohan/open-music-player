import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/models/playlist_import.dart';
import 'package:open_music_player/core/services/playlist_import_service.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/features/playlists/playlist_creation_dialog.dart';
import 'package:open_music_player/shared/models/playlist.dart';

import 'support/mock_dio_client.dart';

final _testPlaylist = Playlist(
  id: 1,
  name: 'Test playlist',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

const _testImportStatus = PlaylistImportStatus(
  id: 'import-1',
  playlistId: 1,
  sourceUrl: 'https://music.youtube.com/playlist?list=PLfixture',
  status: PlaylistImportStatus.resolving,
  totalItems: 0,
  importedItems: 0,
  queuedItems: 0,
  failedItems: 0,
  skippedItems: 0,
  maxItems: 500,
  items: [],
);

void main() {
  testWidgets('shared create surface offers supported sources', (tester) async {
    await tester.pumpWidget(
      _Host(
        onSubmit: (_) async => PlaylistCreatedOutcome(_testPlaylist),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open_create_playlist')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('playlist_creation_source_choices')),
        findsOneWidget);
    expect(find.text('Blank playlist'), findsOneWidget);
    expect(find.text('Import from YouTube'), findsOneWidget);
    expect(find.text('Spotify'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('playlist_creation_blank')));
    await tester.pumpAndSettle();
    expect(find.text('Create blank playlist'), findsOneWidget);
    expect(find.text('Cover image URL (optional)'), findsOneWidget);
  });

  testWidgets('blank creation keeps all fields in the typed intent',
      (tester) async {
    final submitted = <PlaylistCreationIntent>[];
    await tester.pumpWidget(
      _Host(
        onSubmit: (intent) async {
          submitted.add(intent);
          return PlaylistCreatedOutcome(_testPlaylist);
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open_create_playlist')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlist_creation_blank')));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), '  Road trip  ');
    await tester.enterText(fields.at(1), '  Sunset set  ');
    await tester.enterText(fields.at(2), 'https://example.test/cover.jpg');
    await tester.tap(find.text('Public'));
    await tester.tap(find.byKey(const ValueKey('playlist_creation_submit')));
    await tester.pumpAndSettle();

    expect(submitted, hasLength(1));
    final intent = submitted.single;
    expect(intent, isA<BlankPlaylistCreationIntent>());
    final blank = intent as BlankPlaylistCreationIntent;
    expect(blank.name, 'Road trip');
    expect(blank.description, 'Sunset set');
    expect(blank.coverUrl, 'https://example.test/cover.jpg');
    expect(blank.isPublic, isTrue);
  });

  testWidgets('import validates URL and allows an omitted custom name',
      (tester) async {
    final submitted = <PlaylistCreationIntent>[];
    await tester.pumpWidget(
      _Host(
        onSubmit: (intent) async {
          submitted.add(intent);
          return const PlaylistImportedOutcome(_testImportStatus);
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open_create_playlist')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlist_creation_youtube')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlist_creation_submit')));
    await tester.pump();
    expect(find.text('Paste a YouTube playlist URL first.'), findsOneWidget);

    await tester.enterText(
      find.byType(TextFormField).first,
      'https://music.youtube.com/playlist?list=PLfixture',
    );
    await tester.tap(find.byKey(const ValueKey('playlist_creation_submit')));
    await tester.pumpAndSettle();

    expect(submitted, hasLength(1));
    final intent = submitted.single;
    expect(intent, isA<YouTubePlaylistCreationIntent>());
    final youtube = intent as YouTubePlaylistCreationIntent;
    expect(
        youtube.sourceUrl, 'https://music.youtube.com/playlist?list=PLfixture');
    expect(youtube.name, isNull);
  });

  // Regression: dismissing the create modal during an in-flight submit used to
  // silently discard the outcome while the server-side create/import already
  // succeeded, so the playlist or import job was left unreachable. The
  // production-path test below asserts the real barrier/PopScope contract; the
  // scrim tap itself is not used because a coordinate tap outside the dialog
  // does not reliably reach the barrier in a widget test.
  testWidgets('system back cannot dismiss the modal during an in-flight submit',
      (tester) async {
    final complete = Completer<PlaylistCreationOutcome>();

    await tester.pumpWidget(
      _Host(onSubmit: (_) => complete.future),
    );
    await tester.tap(find.byKey(const ValueKey('open_create_playlist')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlist_creation_blank')));
    await tester.pumpAndSettle();

    // Idle: back must still be allowed so the user can leave the modal.
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, isTrue);

    await tester.enterText(find.byType(TextFormField).first, 'Road trip');
    await tester.tap(find.byKey(const ValueKey('playlist_creation_submit')));
    await tester.pump();

    // Android back / predictive back. The spinner is animating, so use a fixed
    // pump and assert the PopScope contract that actually guards the route.
    expect(
      tester.widget<PopScope>(find.byType(PopScope)).canPop,
      isFalse,
      reason: 'back mid-submit must not drop the pending creation outcome',
    );
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.byKey(const ValueKey('playlist_creation_dialog')),
      findsOneWidget,
      reason: 'back mid-submit must not drop the pending creation outcome',
    );

    complete.complete(PlaylistCreatedOutcome(_testPlaylist));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'submit failure surfaces the backend message, not Dio boilerplate',
      (tester) async {
    final requestOptions = RequestOptions(path: '/playlists');
    await tester.pumpWidget(
      _Host(
        onSubmit: (_) async => throw DioException(
          requestOptions: requestOptions,
          response: Response<Map<String, dynamic>>(
            requestOptions: requestOptions,
            statusCode: 400,
            data: const {'message': 'Playlist name is already taken'},
          ),
          type: DioExceptionType.badResponse,
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open_create_playlist')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlist_creation_blank')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Road trip');
    await tester.tap(find.byKey(const ValueKey('playlist_creation_submit')));
    await tester.pumpAndSettle();

    expect(find.text('Playlist name is already taken'), findsOneWidget);
    expect(find.textContaining('DioException'), findsNothing);
  });

  // Exercises the production entry point (showPlaylistCreationDialog) rather
  // than a bare PlaylistCreationDialog, so it covers the barrier wiring that
  // actually shipped. Drives the real transport with a deferred response and
  // advances the clock with fixed pumps: the submit spinner never settles, so
  // awaiting inside the fake-async zone would deadlock.
  //
  // The scrim tap is dispatched through the modal barrier directly rather than
  // by tapping viewport coordinates, so the test fails if the barrier is
  // dismissible instead of silently missing it.
  testWidgets('production dialog blocks scrim dismissal mid-submit',
      (tester) async {
    final release = Completer<void>();
    var sawSubmitting = false;

    final api = mockQueueApiClient((request) async {
      sawSubmitting = true;
      await release.future;
      return http.Response(
        jsonEncode({'id': 7, 'name': 'Road trip'}),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await tester.pumpWidget(_ProductionHost(api: api));
    await tester.tap(find.byKey(const ValueKey('open_create_playlist')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('playlist_creation_blank')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Road trip');
    await tester.tap(find.byKey(const ValueKey('playlist_creation_submit')));
    for (var i = 0; i < 10 && !sawSubmitting; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(sawSubmitting, isTrue, reason: 'submit must have reached transport');

    // Tap the modal barrier itself: with barrierDismissible the barrier pops
    // the route, which is exactly the mid-submit dismissal under test.
    final barrier = tester.widget<ModalBarrier>(
      find.byType(ModalBarrier).last,
    );
    expect(barrier.dismissible, isFalse,
        reason: 'a dismissible barrier drops a playlist the server created');
    barrier.onDismiss?.call();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('playlist_creation_dialog')),
      findsOneWidget,
      reason: 'scrim tap mid-submit must not drop the created playlist',
    );

    release.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('playlist_creation_dialog')),
      findsNothing,
      reason: 'a completed submit still closes the modal',
    );
  });
}

class _ProductionHost extends StatelessWidget {
  final ApiClient api;

  const _ProductionHost({required this.api});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open_create_playlist'),
            onPressed: () => showPlaylistCreationDialog(
              context,
              playlistService: PlaylistService(api: api),
              playlistImportService: PlaylistImportService(api: api),
            ),
            child: const Text('Create'),
          ),
        ),
      ),
    );
  }
}

class _Host extends StatelessWidget {
  final Future<PlaylistCreationOutcome> Function(PlaylistCreationIntent)
      onSubmit;

  const _Host({required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: const ValueKey('open_create_playlist'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => PlaylistCreationDialog(onSubmit: onSubmit),
            ),
            child: const Text('Create'),
          ),
        ),
      ),
    );
  }
}
