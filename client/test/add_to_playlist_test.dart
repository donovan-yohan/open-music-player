import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/services/playlist_service.dart';
import 'package:open_music_player/features/playlists/add_to_playlist.dart';
import 'package:open_music_player/shared/models/playlist.dart';

void main() {
  testWidgets('adds the tracks to the playlist the user picked',
      (tester) async {
    final service = _FakePlaylistService(
      playlists: [_playlist(5, 'Late night'), _playlist(6, 'Road trip')],
    );

    await _pumpHost(tester, service, const [11, 22]);
    await _openSheet(tester);

    expect(find.byKey(addToPlaylistSheetKey), findsOneWidget);
    expect(find.text('Add to playlist'), findsOneWidget);

    await tester.tap(find.text('Road trip'));
    await tester.pumpAndSettle();

    expect(service.addedTo, [6]);
    expect(service.addedTrackIds, [
      [11, 22]
    ]);
    expect(find.byKey(addToPlaylistSuccessKey), findsOneWidget);
    expect(find.text('Added 2 tracks to "Road trip"'), findsOneWidget);
  });

  testWidgets('creates a playlist then adds the tracks to it', (tester) async {
    final service = _FakePlaylistService(playlists: const []);

    await _pumpHost(tester, service, const [11]);
    await _openSheet(tester);

    await tester.tap(find.byKey(addToPlaylistNewPlaylistKey));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Tonight');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(service.createdNames, ['Tonight']);
    expect(service.addedTo, [77]);
    expect(service.addedTrackIds, [
      [11]
    ]);
    expect(find.text('Added to "Tonight"'), findsOneWidget);
  });

  testWidgets('dismissing the sheet adds nothing', (tester) async {
    final service = _FakePlaylistService(
      playlists: [_playlist(5, 'Late night')],
    );

    await _pumpHost(tester, service, const [11]);
    await _openSheet(tester);

    // Tapping the barrier is the ordinary way out of a modal sheet.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.byKey(addToPlaylistSheetKey), findsNothing);
    expect(service.addedTo, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('a failed add surfaces the caller-named failure', (tester) async {
    final service = _FakePlaylistService(
      playlists: [_playlist(5, 'Late night')],
      addFailure: StateError('offline'),
    );

    await _pumpHost(
      tester,
      service,
      const [11],
      addFailureMessage: 'Failed to save queue as playlist',
    );
    await _openSheet(tester);
    await tester.tap(find.text('Late night'));
    await tester.pumpAndSettle();

    expect(find.byKey(addToPlaylistFailureKey), findsOneWidget);
    expect(find.text('Failed to save queue as playlist'), findsOneWidget);
  });

  testWidgets('a failed playlist load never opens the sheet', (tester) async {
    final service = _FakePlaylistService(
      playlists: const [],
      listFailure: StateError('offline'),
    );

    await _pumpHost(tester, service, const [11]);
    await _openSheet(tester);

    expect(find.byKey(addToPlaylistSheetKey), findsNothing);
    expect(find.text('Failed to load playlists'), findsOneWidget);
  });

  testWidgets('a failed create reports itself and adds nothing',
      (tester) async {
    final service = _FakePlaylistService(
      playlists: const [],
      createFailure: StateError('offline'),
    );

    await _pumpHost(tester, service, const [11]);
    await _openSheet(tester);
    await tester.tap(find.byKey(addToPlaylistNewPlaylistKey));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Tonight');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Failed to create playlist'), findsOneWidget);
    expect(service.addedTo, isEmpty);
  });

  testWidgets('the backend duplicate report is what the user is told',
      (tester) async {
    final service = _FakePlaylistService(
      playlists: [_playlist(5, 'Late night')],
      addResult: const AddTracksResult(added: [], skipped: [11]),
    );

    await _pumpHost(tester, service, const [11]);
    await _openSheet(tester);
    await tester.tap(find.text('Late night'));
    await tester.pumpAndSettle();

    expect(find.text('Already in this playlist'), findsOneWidget);
  });
}

Future<void> _pumpHost(
  WidgetTester tester,
  PlaylistService service,
  List<int> trackIds, {
  String addFailureMessage = 'Failed to add to playlist',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const ValueKey('open_add_to_playlist'),
              onPressed: () => showAddToPlaylistSheet(
                context,
                playlistService: service,
                trackIds: trackIds,
                addFailureMessage: addFailureMessage,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open_add_to_playlist')));
  await tester.pumpAndSettle();
}

Playlist _playlist(int id, String name) => Playlist(
      id: id,
      name: name,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      trackCount: 4,
    );

class _FakePlaylistService extends PlaylistService {
  _FakePlaylistService({
    required this.playlists,
    this.addResult,
    this.addFailure,
    this.createFailure,
    this.listFailure,
  }) : super(api: ApiClient());

  final List<Playlist> playlists;
  final AddTracksResult? addResult;
  final Object? addFailure;
  final Object? createFailure;
  final Object? listFailure;

  final List<String> createdNames = [];
  final List<int> addedTo = [];
  final List<List<int>> addedTrackIds = [];

  @override
  Future<PlaylistsResponse> getPlaylists({
    int limit = 50,
    int offset = 0,
    String? q,
    String? sort,
    String? order,
  }) async {
    if (listFailure != null) throw listFailure!;
    return PlaylistsResponse(
      playlists: playlists,
      total: playlists.length,
      offset: 0,
      limit: limit,
    );
  }

  @override
  Future<Playlist> createPlaylist({
    required String name,
    String? description,
    String? coverUrl,
    bool? isPublic,
  }) async {
    if (createFailure != null) throw createFailure!;
    createdNames.add(name);
    return _playlist(77, name);
  }

  @override
  Future<AddTracksResult> addTracks(int playlistId, List<int> trackIds) async {
    if (addFailure != null) throw addFailure!;
    addedTo.add(playlistId);
    addedTrackIds.add(trackIds);
    return addResult ??
        AddTracksResult(added: trackIds, skipped: const <int>[]);
  }
}
