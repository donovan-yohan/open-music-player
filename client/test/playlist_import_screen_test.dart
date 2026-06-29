import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/playlists/playlist_import_screen.dart';

void main() {
  testWidgets('malformed playlist URLs show validation error instead of throwing',
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
}
