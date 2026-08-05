import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/features/library/library_screen.dart';
import 'package:open_music_player/shared/models/track.dart';

typedef _OverrideCall = ({
  int trackId,
  String? title,
  String? artist,
  String? album,
});

/// Records the metadata-override writes a surface makes.
///
/// Only [updateTrackMetadataOverride] is stubbed: `resetTrackMetadataOverride`
/// delegates to it in the real service, so a reset is recorded here as the
/// all-null write the backend contract expects.
class _StubLibraryService extends LibraryService {
  _StubLibraryService() : super(ApiClient());

  final calls = <_OverrideCall>[];
  Object? failure;

  @override
  Future<TrackMetadataOverrideResult> updateTrackMetadataOverride({
    required int trackId,
    String? title,
    String? artist,
    String? album,
  }) async {
    calls.add((trackId: trackId, title: title, artist: artist, album: album));
    final error = failure;
    if (error != null) throw error;
    return TrackMetadataOverrideResult(
      trackId: trackId,
      hasMetadataOverride: title != null || artist != null || album != null,
      title: title,
      artist: artist,
      album: album,
    );
  }
}

class _FakePlaybackState extends Fake implements PlaybackState {
  @override
  MediaItem? get currentItem => null;

  @override
  List<MediaItem> get queue => const [];

  @override
  int? get currentIndex => null;

  @override
  bool get hasTrack => false;

  @override
  bool get isPlaying => false;

  @override
  Duration get duration => Duration.zero;

  @override
  Duration get position => Duration.zero;

  @override
  bool get canSkipNext => false;

  @override
  bool get canSkipPrevious => false;

  @override
  bool get hasPreviousInPlayOrder => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _FakeDownloadState extends Fake implements DownloadState {
  @override
  DownloadProgress? getProgress(int trackId) => null;

  @override
  Future<bool> isDownloaded(int trackId) async => false;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

Track _track({bool hasMetadataOverride = false}) => Track(
      id: 42,
      identityHash: 'track-42',
      title: 'Original Title',
      artist: 'Original Artist',
      album: 'Original Album',
      durationMs: 180000,
      hasMetadataOverride: hasMetadataOverride,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

/// Stands in for the Library screen's full-reload refresh: a successful write
/// swaps in the row the backend would return on the next `_loadTracks`.
class _LibraryRowHost extends StatefulWidget {
  const _LibraryRowHost({
    required this.initialTrack,
    required this.libraryService,
    this.refreshedTrack,
  });

  final Track initialTrack;
  final LibraryService libraryService;
  final Track? refreshedTrack;

  @override
  State<_LibraryRowHost> createState() => _LibraryRowHostState();
}

class _LibraryRowHostState extends State<_LibraryRowHost> {
  late Track _track = widget.initialTrack;
  int reloads = 0;

  @override
  Widget build(BuildContext context) {
    return LibraryTrackListTile(
      track: _track,
      libraryService: widget.libraryService,
      detailApiClient: ApiClient(),
      onTrackUpdated: () {
        reloads++;
        final refreshed = widget.refreshedTrack;
        if (refreshed != null) setState(() => _track = refreshed);
      },
    );
  }
}

/// Desktop-ish width so the row keeps its full affordances (the "Edited" badge
/// is gated on the non-compact layout), but below the 960 breakpoint that
/// switches the editor to a dialog.
void _useWideViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<_LibraryRowHostState> _pumpRow(
  WidgetTester tester, {
  required Track track,
  required _StubLibraryService library,
  Track? refreshedTrack,
}) async {
  final playback = _FakePlaybackState();
  final registry = CommandRegistry(playbackState: playback);
  addTearDown(registry.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ListenableProvider<PlaybackState>.value(value: playback),
        ListenableProvider<DownloadState>.value(value: _FakeDownloadState()),
        ChangeNotifierProvider<LikedTracksState>.value(
          value: LikedTracksState(library),
        ),
        Provider<CommandRegistry>.value(value: registry),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: _LibraryRowHost(
            initialTrack: track,
            libraryService: library,
            refreshedTrack: refreshedTrack,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return tester.state<_LibraryRowHostState>(find.byType(_LibraryRowHost));
}

Future<void> _openMetadataEditor(WidgetTester tester) async {
  await tester.tap(find.byTooltip('More actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('command_sheet_editMetadata')));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('saving the editor writes trimmed values and nulls blank fields',
      (tester) async {
    _useWideViewport(tester);
    final library = _StubLibraryService();
    final host = await _pumpRow(tester, track: _track(), library: library);

    await _openMetadataEditor(tester);

    // Nothing is overridden yet, so reset has nothing to restore.
    expect(find.byKey(const ValueKey('track_metadata_reset')), findsNothing);
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('track_metadata_title_field')),
          )
          .controller
          ?.text,
      'Original Title',
    );

    await tester.enterText(
      find.byKey(const ValueKey('track_metadata_title_field')),
      '  Edited Title  ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('track_metadata_artist_field')),
      '   ',
    );
    await tester.enterText(
      find.byKey(const ValueKey('track_metadata_album_field')),
      '  Edited Album  ',
    );
    await tester.tap(find.byKey(const ValueKey('track_metadata_save')));
    await tester.pumpAndSettle();

    expect(library.calls, [
      (
        trackId: 42,
        title: 'Edited Title',
        artist: null,
        album: 'Edited Album',
      ),
    ]);
    expect(host.reloads, 1);
    expect(find.text('Updated metadata'), findsOneWidget);
    expect(find.byKey(const ValueKey('track_metadata_save')), findsNothing);
  });

  testWidgets('an empty title is rejected before any write', (tester) async {
    _useWideViewport(tester);
    final library = _StubLibraryService();
    await _pumpRow(tester, track: _track(), library: library);

    await _openMetadataEditor(tester);
    await tester.enterText(
      find.byKey(const ValueKey('track_metadata_title_field')),
      '   ',
    );
    await tester.tap(find.byKey(const ValueKey('track_metadata_save')));
    await tester.pumpAndSettle();

    expect(library.calls, isEmpty);
    expect(find.text('Please enter a title'), findsOneWidget);
    expect(find.byKey(const ValueKey('track_metadata_save')), findsOneWidget);
  });

  testWidgets('an overridden row shows the edited badge', (tester) async {
    _useWideViewport(tester);

    await _pumpRow(
      tester,
      track: _track(hasMetadataOverride: true),
      library: _StubLibraryService(),
    );

    expect(
      find.byKey(const ValueKey('track_metadata_edited_badge_42')),
      findsOneWidget,
    );
    expect(find.text('Edited'), findsOneWidget);
    expect(find.byTooltip('Metadata edited by you'), findsOneWidget);
  });

  testWidgets('an untouched row shows no edited badge', (tester) async {
    _useWideViewport(tester);

    await _pumpRow(tester, track: _track(), library: _StubLibraryService());

    expect(
      find.byKey(const ValueKey('track_metadata_edited_badge_42')),
      findsNothing,
    );
    expect(find.text('Edited'), findsNothing);
  });

  testWidgets('reset issues an all-null write and clears the badge',
      (tester) async {
    _useWideViewport(tester);
    final library = _StubLibraryService();
    final host = await _pumpRow(
      tester,
      track: _track(hasMetadataOverride: true),
      library: library,
      refreshedTrack: _track(),
    );

    expect(
      find.byKey(const ValueKey('track_metadata_edited_badge_42')),
      findsOneWidget,
    );

    await _openMetadataEditor(tester);
    await tester.tap(find.byKey(const ValueKey('track_metadata_reset')));
    await tester.pumpAndSettle();

    expect(library.calls, [
      (trackId: 42, title: null, artist: null, album: null),
    ]);
    expect(host.reloads, 1);
    expect(find.text('Restored the original metadata'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('track_metadata_edited_badge_42')),
      findsNothing,
    );
  });

  testWidgets('a rejected write keeps the editor open with the reason',
      (tester) async {
    _useWideViewport(tester);
    final library = _StubLibraryService()
      ..failure = ApiException(
        code: 'INVALID_REQUEST',
        message: 'Title is too long',
        statusCode: 400,
      );
    final host = await _pumpRow(tester, track: _track(), library: library);

    await _openMetadataEditor(tester);
    await tester.enterText(
      find.byKey(const ValueKey('track_metadata_title_field')),
      'Way too long',
    );
    await tester.tap(find.byKey(const ValueKey('track_metadata_save')));
    await tester.pumpAndSettle();

    expect(library.calls, hasLength(1));
    expect(host.reloads, 0);
    expect(find.byKey(const ValueKey('track_metadata_error')), findsOneWidget);
    expect(find.text('Title is too long'), findsOneWidget);
    expect(find.byKey(const ValueKey('track_metadata_save')), findsOneWidget);
  });
}
