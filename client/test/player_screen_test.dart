import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/features/player/player_screen.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('mobile Sound Q player keeps its controls usable at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final scale in [1.0, 2.0, 3.0]) {
      final playback = _FakePlaybackState();
      await tester.pumpWidget(
        ListenableProvider<PlaybackState>.value(
          value: playback,
          child: MaterialApp(
            theme: AppTheme.lightTheme,
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: const PlayerScreen(),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(const ValueKey('player_art_placeholder')), findsOne);
      expect(find.byKey(const ValueKey('player_graphic_progress')), findsOne);
      expect(find.byKey(const ValueKey('player_play_pause_surface')), findsOne);
      expect(find.byIcon(Icons.shuffle), findsOneWidget);
      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
      expect(find.byIcon(Icons.repeat), findsOneWidget);
      expect(find.byTooltip('Song info'), findsOneWidget);
      final title = find.byKey(const ValueKey('player_track_title'));
      final titleElement = tester.element(title);
      expect(Theme.of(titleElement).brightness, Brightness.dark);
      final background = _scaffoldBackground(tester);
      expect(background, AppTheme.background);
      expect(
        _contrastRatio(_effectiveTextColor(tester, title), background),
        greaterThanOrEqualTo(4.5),
      );
      expect(tester.takeException(), isNull, reason: 'text scale $scale');
    }
  });

  testWidgets('desktop player inherits readable light theme colors', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: _FakePlaybackState(),
        child: MaterialApp(
          theme: AppTheme.lightTheme,
          home: const PlayerScreen(),
        ),
      ),
    );
    await tester.pump();

    final title = find.byKey(const ValueKey('player_track_title'));
    final artist = find.byKey(const ValueKey('player_track_artist'));
    final songInfo = find.byTooltip('Song info');
    final background = _scaffoldBackground(tester);

    expect(Theme.of(tester.element(title)).brightness, Brightness.light);
    expect(background, AppTheme.lightBackground);
    for (final finder in [title, artist]) {
      expect(
        _contrastRatio(_effectiveTextColor(tester, finder), background),
        greaterThanOrEqualTo(4.5),
      );
    }
    expect(
      _contrastRatio(_effectiveIconColor(tester, songInfo), background),
      greaterThanOrEqualTo(4.5),
    );
  });

  testWidgets('player renders immutable source quality from track metadata', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const item = MediaItem(
      id: '1',
      title: 'Truthful Track',
      artist: 'Artist',
      extras: {
        'codec': 'mp3',
        'bitrateKbps': 137,
        'sampleRateHz': 44100,
        'sizeBytes': 3355443,
      },
    );

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: _FakePlaybackState(currentItem: item),
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('player_source_quality')), findsOneWidget);
    expect(find.text('MP3 · 137 kbps · 44.1 kHz · 3.2 MB'), findsOneWidget);
  });

  testWidgets('progress slider previews scrub and commits once', (
    tester,
  ) async {
    final playback = _FakePlaybackState();
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: playback,
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart?.call(0.1);
    slider.onChanged?.call(0.4);
    slider.onChanged?.call(0.6);
    slider.onChangeEnd?.call(0.6);
    await tester.pump();

    expect(playback.seekCalls, 0);
    expect(playback.scrubEvents, [
      'begin',
      'update:24000',
      'update:36000',
      'end:36000',
    ]);
  });

  testWidgets('queue time mode displays context and scrubs global timeline', (
    tester,
  ) async {
    final playback = _FakePlaybackState(
      playbackContext: const PlaybackContext(
        kind: PlaybackContextKind.playlist,
        label: 'Road Mix',
      ),
      queue: const [
        _FakePlaybackState.testItem,
        MediaItem(id: '2', title: 'Next Track', duration: Duration(minutes: 2)),
      ],
      snapshot: const PlaybackSnapshot(
        sessionId: 'session_test',
        cues: [],
        currentCueId: 'cue_1',
        currentQueueIndex: 0,
        currentMediaItem: _FakePlaybackState.testItem,
        localPosition: Duration(seconds: 10),
        localDuration: Duration(minutes: 1),
        globalPosition: Duration(seconds: 30),
        globalDuration: Duration(minutes: 3),
        playing: false,
        processingState: ProcessingState.ready,
        activeVoiceCount: 1,
      ),
    );
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: playback,
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );

    await tester.tap(find.text('Queue'));
    await tester.pumpAndSettle();

    expect(find.text('Road Mix'), findsWidgets);
    expect(find.text('Playlist · 2 tracks'), findsOneWidget);

    final slider = tester.widget<Slider>(find.byType(Slider));
    slider.onChangeStart?.call(0.1);
    slider.onChanged?.call(0.5);
    slider.onChangeEnd?.call(0.5);
    await tester.pump();

    expect(playback.scrubEvents, [
      'timeline-begin',
      'timeline-update:90000',
      'timeline-end:90000',
    ]);
  });

  testWidgets('shows pitch lock fallback warning when snapshot reports it', (
    tester,
  ) async {
    final playback = _FakePlaybackState(
      snapshot: const PlaybackSnapshot(
        sessionId: 'session_test',
        cues: [],
        currentCueId: 'cue_1',
        currentQueueIndex: 0,
        currentMediaItem: _FakePlaybackState.testItem,
        localPosition: Duration(seconds: 10),
        localDuration: Duration(seconds: 60),
        globalPosition: Duration(seconds: 10),
        globalDuration: Duration(seconds: 60),
        playing: false,
        processingState: ProcessingState.ready,
        activeVoiceCount: 1,
        playbackSpeed: 1.25,
        pitchPreservationFallback: true,
      ),
    );
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ListenableProvider<PlaybackState>.value(
        value: playback,
        child: const MaterialApp(home: PlayerScreen()),
      ),
    );

    expect(
      find.text('Pitch lock unavailable. Tempo match may alter pitch.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'secondary controls have no enabled no-op actions and favorite is wired',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final playback = _FakePlaybackState(
        currentItem: const MediaItem(
          id: '1',
          title: 'Honest Track',
          extras: {'isLiked': false},
        ),
      );
      final library = _RecordingLibraryService();
      final write = Completer<void>();
      library.likeResult = write.future;
      final liked = LikedTracksState(library)..seedValue(1, false);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ListenableProvider<PlaybackState>.value(value: playback),
            ChangeNotifierProvider<LikedTracksState>.value(value: liked),
          ],
          child: const MaterialApp(home: PlayerScreen()),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.devices), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('player_share_action')),
            )
            .onPressed,
        isNull,
      );
      expect(find.byTooltip('Source link unavailable'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('player_favorite_action')),
            )
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.byKey(const ValueKey('player_favorite_action')));
      await tester.pump();

      expect(liked.isLiked(1), isTrue);
      expect(library.likedIds, [1]);
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('player_favorite_action')),
            )
            .onPressed,
        isNull,
      );

      write.complete();
      await tester.pump();
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('player_favorite_action')),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('favorite is disabled honestly for unknown and local-only ids', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final library = _RecordingLibraryService();
    final liked = LikedTracksState(library, accountId: 'user-b');

    for (final item in const [
      MediaItem(
        id: '1',
        title: 'Previous account',
        extras: {'isLiked': true, 'likedAccountId': 'user-a'},
      ),
      MediaItem(id: 'local-file', title: 'Local only'),
    ]) {
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ListenableProvider<PlaybackState>.value(
              value: _FakePlaybackState(currentItem: item),
            ),
            ChangeNotifierProvider<LikedTracksState>.value(value: liked),
          ],
          child: MaterialApp(
            key: ValueKey(item.id),
            home: const PlayerScreen(),
          ),
        ),
      );
      await tester.pump();

      final favorite = tester.widget<IconButton>(
        find.byKey(const ValueKey('player_favorite_action')),
      );
      expect(favorite.onPressed, isNull);
      expect(
        find.byTooltip(
          item.id == '1'
              ? 'Liked status not loaded yet'
              : 'Liked status unavailable for local-only track',
        ),
        findsOneWidget,
      );
    }
    expect(liked.isLiked(1), isNull);
  });

  testWidgets(
    'player surfaces resolve semantic contrast and preserve scrub and sheet wiring',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final theme in [AppTheme.lightTheme, AppTheme.darkTheme]) {
        final playback = _FakePlaybackState(
          currentItem: const MediaItem(
            id: 'placeholder',
            title: 'Theme Track',
            artist: 'Theme Artist',
            duration: Duration(minutes: 1),
          ),
          snapshot: const PlaybackSnapshot(
            sessionId: 'session_theme',
            cues: [],
            currentCueId: 'cue_1',
            currentQueueIndex: 0,
            currentMediaItem: _FakePlaybackState.testItem,
            localPosition: Duration(seconds: 10),
            localDuration: Duration(minutes: 1),
            globalPosition: Duration(seconds: 10),
            globalDuration: Duration(minutes: 1),
            playing: false,
            processingState: ProcessingState.ready,
            activeVoiceCount: 1,
            pitchPreservationFallback: true,
          ),
        );

        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ListenableProvider<PlaybackState>.value(value: playback),
              Provider<ApiClient>(
                create: (_) => ApiClient(
                  httpClient: MockClient((_) async => http.Response('{}', 404)),
                ),
              ),
            ],
            child: MaterialApp(
              key: ValueKey(theme.brightness),
              theme: theme,
              home: const PlayerScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final surface = theme.colorScheme.surface;
        final title = tester.widget<Text>(
          find.byKey(const ValueKey('player_track_title')),
        );
        final artist = tester.widget<Text>(
          find.byKey(const ValueKey('player_track_artist')),
        );
        expect(_contrastRatio(title.style!.color!, surface), atLeast(4.5));
        expect(_contrastRatio(artist.style!.color!, surface), atLeast(4.5));

        final placeholder = tester.widget<Container>(
          find.byKey(const ValueKey('player_art_placeholder')),
        );
        final placeholderIcon = tester.widget<Icon>(
          find.descendant(
            of: find.byKey(const ValueKey('player_art_placeholder')),
            matching: find.byIcon(Icons.music_note),
          ),
        );
        expect(
          _contrastRatio(placeholderIcon.color!, placeholder.color!),
          atLeast(3),
        );

        final warningText = tester.widget<Text>(
          find.text('Pitch lock unavailable. Tempo match may alter pitch.'),
        );
        expect(
          _contrastRatio(warningText.style!.color!, surface),
          atLeast(4.5),
        );

        final secondary = tester.widget<Icon>(
          find.byIcon(Icons.favorite_border),
        );
        expect(_contrastRatio(secondary.color!, surface), atLeast(3));

        final slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChangeStart?.call(0.1);
        slider.onChanged?.call(0.5);
        slider.onChangeEnd?.call(0.5);
        await tester.pump();
        expect(playback.scrubEvents, ['begin', 'update:30000', 'end:30000']);

        await tester.tap(find.byTooltip('Song info'));
        await tester.pumpAndSettle();

        final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
        final sheetTitle = tester.widget<Text>(
          find.byKey(const ValueKey('song_info_sheet_title')),
        );
        expect(
          _contrastRatio(sheetTitle.style!.color!, sheet.backgroundColor!),
          atLeast(4.5),
        );
        expect(
          find.text('Analysis unavailable for this track.'),
          findsOneWidget,
        );
      }
    },
  );
}

Color _effectiveTextColor(WidgetTester tester, Finder finder) {
  final element = tester.element(finder);
  final text = tester.widget<Text>(finder);
  return text.style?.color ?? DefaultTextStyle.of(element).style.color!;
}

Color _effectiveIconColor(WidgetTester tester, Finder finder) =>
    IconTheme.of(tester.element(finder)).color!;

Color _scaffoldBackground(WidgetTester tester) =>
    tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor!;

class _FakePlaybackState extends Fake implements PlaybackState {
  _FakePlaybackState({
    PlaybackContext? playbackContext,
    List<MediaItem>? queue,
    PlaybackSnapshot? snapshot,
    MediaItem? currentItem,
  }) : _playbackContext = playbackContext,
       _queue = queue ?? const [testItem],
       _currentItem = currentItem ?? testItem,
       _snapshot =
           snapshot ??
           const PlaybackSnapshot(
             sessionId: 'session_test',
             cues: [],
             currentCueId: 'cue_1',
             currentQueueIndex: 0,
             currentMediaItem: testItem,
             localPosition: Duration(seconds: 10),
             localDuration: Duration(seconds: 60),
             globalPosition: Duration(seconds: 10),
             globalDuration: Duration(seconds: 60),
             playing: false,
             processingState: ProcessingState.ready,
             activeVoiceCount: 1,
           );

  static const testItem = MediaItem(
    id: '1',
    title: 'Test Track',
    artist: 'Test Artist',
    duration: Duration(seconds: 60),
  );

  final scrubEvents = <String>[];
  final PlaybackContext? _playbackContext;
  final List<MediaItem> _queue;
  final MediaItem _currentItem;
  final PlaybackSnapshot _snapshot;
  int seekCalls = 0;

  @override
  MediaItem? get currentItem => _currentItem;

  @override
  List<MediaItem> get queue => _queue;

  @override
  PlaybackSnapshot get snapshot => _snapshot;

  @override
  Duration get position => const Duration(seconds: 10);

  @override
  Duration get duration => const Duration(seconds: 60);

  @override
  bool get isPlaying => false;

  @override
  bool get shuffleEnabled => false;

  @override
  LoopMode get loopMode => LoopMode.off;

  @override
  PlaybackContext? get playbackContext => _playbackContext;

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
  }

  @override
  void beginLocalScrub() => scrubEvents.add('begin');

  @override
  void updateLocalScrub(Duration position) {
    scrubEvents.add('update:${position.inMilliseconds}');
  }

  @override
  Future<void> endLocalScrub(Duration position) async {
    scrubEvents.add('end:${position.inMilliseconds}');
  }

  @override
  void beginTimelineScrub() => scrubEvents.add('timeline-begin');

  @override
  void updateTimelineScrub(int globalMs) {
    scrubEvents.add('timeline-update:$globalMs');
  }

  @override
  Future<void> endTimelineScrub(int globalMs) async {
    scrubEvents.add('timeline-end:$globalMs');
  }

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  Future<void> toggleShuffle() async {}

  @override
  Future<void> previous() async {}

  @override
  Future<void> togglePlayPause() async {}

  @override
  Future<void> skipToNext() async {}

  @override
  Future<void> cycleLoopMode() async {}
}

class _RecordingLibraryService extends LibraryService {
  _RecordingLibraryService() : super(ApiClient());

  final likedIds = <int>[];
  Future<void> likeResult = Future.value();

  @override
  Future<void> like(int trackId) {
    likedIds.add(trackId);
    return likeResult;
  }
}

Matcher atLeast(num value) => greaterThanOrEqualTo(value);

double _contrastRatio(Color first, Color second) {
  final firstLuminance = first.computeLuminance();
  final secondLuminance = second.computeLuminance();
  final lighter = firstLuminance > secondLuminance
      ? firstLuminance
      : secondLuminance;
  final darker = firstLuminance > secondLuminance
      ? secondLuminance
      : firstLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
