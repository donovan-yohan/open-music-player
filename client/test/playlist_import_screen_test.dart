import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/models/playlist_import.dart';
import 'package:open_music_player/core/services/playlist_import_service.dart';
import 'package:open_music_player/features/playlists/playlist_import_screen.dart';

void main() {
  testWidgets(
      'malformed playlist URLs show validation error instead of throwing',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: PlaylistImportScreen()),
    );

    await tester.enterText(
      find.byType(TextField).first,
      'https://www.youtube.com/playlist?list=%E0%A4%A',
    );
    await tester.tap(find.text('Import playlist'));
    await tester.pump();

    expect(
      find.text(
        'Use a YouTube or YouTube Music URL with a playlist list= parameter.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('restored import jobs keep polling until terminal',
      (tester) async {
    final service = _FakePlaylistImportService();
    await tester.pumpWidget(
      MaterialApp(
        home: PlaylistImportScreen(
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
