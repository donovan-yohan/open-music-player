import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/models/playlist_import.dart';
import 'package:open_music_player/core/services/playlist_import_service.dart';
import 'package:open_music_player/features/playlists/playlist_import_progress_screen.dart';

void main() {
  testWidgets(
      'arriving without an import job points at Create Playlist instead of '
      'offering a second way to start one', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: PlaylistImportProgressScreen()),
    );
    await tester.pump();

    expect(find.text('No import in progress'), findsOneWidget);
    // Starting an import is owned by the shared creation dialog. URL validation
    // and the start form are covered by playlist_creation_dialog_test.dart;
    // this screen must not re-introduce a competing entry point.
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('Import playlist'), findsNothing);
  });

  testWidgets(
      'a failed status fetch does not also claim there is no import in progress',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistImportProgressScreen(
          importJobId: 'job-1',
          importService: _FailingImportService(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // The error card owns this state and offers retry. We could not read the
    // job, which says nothing about whether it exists, so a "No import in
    // progress" card alongside the error would be a second, contradictory
    // answer to the same question.
    expect(find.text('import is temporarily unavailable'), findsOneWidget);
    expect(find.text('No import in progress'), findsNothing);
  });

  testWidgets('restored import jobs keep polling until terminal',
      (tester) async {
    final service = _FakePlaylistImportService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistImportProgressScreen(
          importJobId: 'job-1',
          importService: service,
          pollInterval: const Duration(milliseconds: 10),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 25));

    expect(service.getImportCalls, greaterThanOrEqualTo(2));
    expect(find.text('Import complete. Imported or reused 0 tracks.'),
        findsOneWidget);
  });
}

class _FailingImportService extends PlaylistImportService {
  _FailingImportService() : super(api: ApiClient());

  @override
  Future<PlaylistImportStatus> getImport(String importJobId) async {
    final options = RequestOptions(path: '/playlists/import/$importJobId');
    throw DioException(
      requestOptions: options,
      response: Response<Map<String, dynamic>>(
        requestOptions: options,
        statusCode: 503,
        data: const {'message': 'import is temporarily unavailable'},
      ),
      type: DioExceptionType.badResponse,
    );
  }
}

class _FakePlaylistImportService extends PlaylistImportService {
  _FakePlaylistImportService() : super(api: ApiClient());

  int getImportCalls = 0;

  @override
  Future<PlaylistImportStatus> getImport(String importJobId) async {
    getImportCalls++;
    return PlaylistImportStatus(
      id: importJobId,
      playlistId: 1,
      sourceUrl: 'https://music.youtube.com/playlist?list=PLfixture',
      sourceTitle: 'Fixture playlist',
      status: getImportCalls == 1
          ? PlaylistImportStatus.resolving
          : PlaylistImportStatus.complete,
      totalItems: 0,
      importedItems: 0,
      queuedItems: 0,
      failedItems: 0,
      skippedItems: 0,
      maxItems: 500,
      items: const [],
    );
  }
}
