import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/models/playlist_import.dart';
import 'package:open_music_player/features/playlists/playlist_creation_dialog.dart';
import 'package:open_music_player/shared/models/playlist.dart';

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
