import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/shared/widgets/track_artwork.dart';
import 'package:open_music_player/shared/widgets/now_playing_row.dart';
import 'package:open_music_player/shared/models/models.dart';

import 'flight_theme_typography_test.dart' show loadFlightFonts;

void main() {
  testWidgets(
      'desktop names genuine source regions and distinguishes collections',
      (tester) async {
    await _pumpHome(tester, playlists: [
      Playlist.fromJson({'id': 39, 'name': 'Night shift', 'trackCount': 8}),
    ]);
    expect(find.text('Recently played'), findsOneWidget);
    expect(find.text('Your top tracks'), findsOneWidget);
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('Your rotation'), findsNothing);
    expect(find.byIcon(Icons.library_music_outlined), findsOneWidget);
    expect(find.text('8 tracks'), findsOneWidget);
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byType(SliverGrid), findsNothing);
  });

  testWidgets('desktop collections use their own glyph and readable count',
      (tester) async {
    await _pumpHome(tester, recent: [], top: [], playlists: [
      Playlist.fromJson({'id': 39, 'name': 'Night shift', 'trackCount': 8}),
    ]);
    final playlistRow = find
        .ancestor(of: find.text('Night shift'), matching: find.byType(InkWell))
        .first;
    expect(
        find.descendant(
            of: playlistRow,
            matching: find.byIcon(Icons.library_music_outlined)),
        findsOneWidget,
        reason: 'a collection must not be disguised as a music-note track');
    expect(find.text('8 tracks'), findsOneWidget);
    expect(find.byIcon(Icons.add_to_queue), findsNothing);
    expect(find.byTooltip('Open Night shift'), findsOneWidget);
  });

  testWidgets('desktop playback stays in the clicked original source section',
      (tester) async {
    final playback = _RecordingPlayback();
    await _pumpHome(tester,
        playback: playback,
        recent: [_track(8, inLibrary: false), _track(1), _track(2)],
        top: [_track(2), _track(9, inLibrary: false), _track(3), _track(3)]);
    await tester.tap(find.text('Track 3').last);
    await tester.pumpAndSettle();
    expect(playback.playedIds, [2, 3, 3],
        reason: 'filter within top tracks, retain its order and multiplicity');
    expect(playback.startIndex, 1,
        reason: 'preserve the existing filtered identity selection');
    await tester.tap(find.text('Track 1'));
    await tester.pumpAndSettle();
    expect(playback.playedIds, [1, 2]);
    expect(playback.startIndex, 0);
  });

  for (final width in [960.0, 1440.0, 2560.0]) {
    testWidgets('compact horizontal Home tiles at ${width.toInt()}px',
        (tester) async {
      await _pumpHome(tester, width: width);

      final firstTile = find
          .ancestor(
            of: find.text('Track 1'),
            matching: find.byType(InkWell),
          )
          .first;
      final rect = tester.getRect(firstTile);
      expect(rect.height, lessThanOrEqualTo(80),
          reason: 'Home must show music rows, not oversized artwork posters');
      expect(rect.width, greaterThan(rect.height * 2));
      final next = find
          .ancestor(of: find.text('Track 2'), matching: find.byType(InkWell))
          .first;
      expect(tester.getRect(next).top, rect.bottom,
          reason: 'track rows meet at one shared rule, not separate cards');
      expect(rect.height, greaterThanOrEqualTo(56));
      expect(find.byType(SliverGrid), findsNothing);
      final artwork =
          tester.widget<TrackArtwork>(find.byType(TrackArtwork).first);
      expect(artwork.width, 40);
      expect(artwork.height, 40);
      expect(artwork.borderRadius, BorderRadius.zero);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('2x text grows rows and respects a narrow content slot',
      (tester) async {
    const longTitle =
        'A very long track title that still needs a useful second '
        'line without hiding its artist or controls';
    await _pumpHome(tester, recent: [_track(1, title: longTitle)]);
    final tile = find
        .ancestor(
          of: find.text(longTitle),
          matching: find.byType(InkWell),
        )
        .first;
    final ordinaryHeight = tester.getSize(tile).height;
    await _pumpHome(tester, scale: 2, recent: [_track(1, title: longTitle)]);
    expect(tester.getSize(tile).height, greaterThan(ordinaryHeight));
    expect(tester.getRect(find.text('Artist 1')).bottom,
        lessThanOrEqualTo(tester.getRect(tile).bottom));
    expect(tester.takeException(), isNull);

    await _pumpHome(tester, width: 960, slotWidth: 350, scale: 2);
    expect(find.byKey(const ValueKey('home_main_secondary')), findsNothing,
        reason: 'narrow child slots stack the same source hierarchy');
    expect(tester.getSize(tile).width, 350);
    expect(tester.takeException(), isNull);
  });

  testWidgets('contiguous rows have neutral metadata and native pointer/focus',
      (tester) async {
    await _pumpHome(tester);
    final title = find.text('Track 1');
    final tile = find.ancestor(of: title, matching: find.byType(InkWell)).first;
    final materialFinder =
        find.ancestor(of: title, matching: find.byType(Material)).first;
    final material = tester.widget<Material>(materialFinder);
    expect(material.shape, isA<OutlinedBorder>());
    final border = material.shape! as OutlinedBorder;
    expect(border.side.color, Colors.transparent,
        reason: 'resting rows have shared rules, not separate outlines');
    expect(
        border
            .getOuterPath(const Rect.fromLTWH(0, 0, 100, 56))
            .contains(const Offset(0.1, 0.1)),
        isTrue,
        reason: 'no rounded card corners');
    expect(tester.widget<Text>(find.text('Artist 1')).style?.color,
        AppTheme.darkTheme.colorScheme.onSurfaceVariant);
    expect(find.byTooltip('Play Track 1'), findsOneWidget);
    expect(find.byTooltip('Add Track 1 to queue'), findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(title));
    await tester.pumpAndSettle();
    final ink = tester.widget<InkWell>(tile);
    expect(ink.statesController?.value, contains(WidgetState.hovered));
    final hoverColor = ink.overlayColor?.resolve({WidgetState.hovered});
    expect(hoverColor, Colors.transparent);
    expect(tester.widget<Material>(materialFinder).color, AppTheme.outline);
    await mouse.moveTo(Offset.zero);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(ink.statesController!.value, isNot(contains(WidgetState.hovered)));

    final strategy = FocusManager.instance.highlightStrategy;
    addTearDown(() => FocusManager.instance.highlightStrategy = strategy);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    for (var i = 0; i < 10; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      if (ink.statesController!.value.contains(WidgetState.focused)) break;
    }
    expect(ink.statesController!.value, contains(WidgetState.focused));
    final focusedMaterial = tester.widget<Material>(materialFinder);
    expect(
        (focusedMaterial.shape! as OutlinedBorder).side.color, AppTheme.accent);
    expect(
        ink.overlayColor!.resolve({WidgetState.focused}), Colors.transparent);
    expect((focusedMaterial.shape! as OutlinedBorder).side.width, 2);
  });

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.space]) {
    testWidgets('native ${key.keyLabel} plays the focused track by identity',
        (tester) async {
      final playback = _RecordingPlayback();
      await _pumpHome(tester,
          playback: playback,
          recent: [_track(8, inLibrary: false), _track(1)],
          top: [_track(3)]);
      final tile = find
          .ancestor(of: find.text('Track 3'), matching: find.byType(InkWell))
          .first;
      final ink = tester.widget<InkWell>(tile);
      for (var i = 0; i < 20; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        if (ink.statesController!.value.contains(WidgetState.focused)) break;
      }
      expect(ink.statesController!.value, contains(WidgetState.focused));
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
      expect(playback.playedIds, [3]);
      expect(playback.startIndex, 0);
    });
  }

  testWidgets('queue action enqueues only its track without starting playback',
      (tester) async {
    final playback = _RecordingPlayback();
    await _pumpHome(tester,
        playback: playback, recent: [_track(8, inLibrary: false), _track(1)]);
    await tester.tap(find.byTooltip('Add Track 1 to queue'));
    await tester.pumpAndSettle();
    expect(playback.enqueuedIds, [1]);
    expect(playback.playedIds, isNull);
    expect(playback.insertMode, QueueInsertMode.addToQueue);
    final disabled = tester.widget<IconButton>(find.byWidgetPredicate(
      (widget) =>
          widget is IconButton && widget.tooltip == homeNotInLibraryMessage,
    ));
    expect(disabled.onPressed, isNull);
  });

  testWidgets('playlist keyboard activation opens the original playlist route',
      (tester) async {
    final playlist =
        Playlist.fromJson({'id': 39, 'name': 'Night shift', 'trackCount': 8});
    final router = GoRouter(initialLocation: '/home', routes: [
      GoRoute(
          path: '/home',
          builder: (_, __) =>
              HomeScreen(homeService: _FeedService([], [], [playlist]))),
      GoRoute(
          path: '/playlists/:id',
          builder: (_, state) =>
              Text('Playlist ${state.pathParameters['id']}')),
    ]);
    addTearDown(router.dispose);
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        MaterialApp.router(theme: AppTheme.darkTheme, routerConfig: router));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open Night shift'));
    await tester.pumpAndSettle();
    expect(find.text('Playlist 39'), findsOneWidget);
    router.go('/home');
    await tester.pumpAndSettle();
    final ink = tester.widget<InkWell>(find
        .ancestor(of: find.text('Night shift'), matching: find.byType(InkWell))
        .first);
    for (var i = 0; i < 10; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      if (ink.statesController!.value.contains(WidgetState.focused)) break;
    }
    expect(ink.statesController!.value, contains(WidgetState.focused));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Playlist 39'), findsOneWidget);
  });

  for (final width in [960.0, 1440.0, 2560.0]) {
    testWidgets('last tile reachable at ${width.toInt()}px with 2x text',
        (tester) async {
      final playback = _RecordingPlayback();
      await _pumpHome(tester,
          width: width,
          scale: 2,
          playback: playback,
          recent: List.generate(120, (i) => _track(i + 1)),
          top: []);
      expect(find.text('Track 120'), findsNothing,
          reason: 'source regions must remain lazy');
      final scrollable = find
          .descendant(
              of: find.byKey(const ValueKey('soundq_desktop_home')),
              matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(find.text('Track 120'), 600,
          scrollable: scrollable, maxScrolls: 50);
      await tester.pumpAndSettle();
      final scrollState = tester.state<ScrollableState>(scrollable);
      scrollState.position.jumpTo(scrollState.position.maxScrollExtent);
      await tester.pumpAndSettle();
      final tile = find
          .ancestor(of: find.text('Track 120'), matching: find.byType(InkWell))
          .first;
      expect(tester.getRect(tile).bottom,
          lessThanOrEqualTo(tester.getRect(scrollable).bottom));
      expect(tester.getRect(scrollable).bottom - tester.getRect(tile).bottom,
          lessThanOrEqualTo(16),
          reason: 'no redundant transport spacer');
      await tester.tap(find.text('Track 120'));
      await tester.pumpAndSettle();
      expect(playback.playedIds?.last, 120);
      expect(playback.startIndex, 119);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'queue button uses cyan pointer/focus without waking disabled actions',
      (tester) async {
    await _pumpHome(tester, recent: [_track(8, inLibrary: false), _track(1)]);
    final enabled = tester.widget<IconButton>(find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Add Track 1 to queue'));
    final disabled = tester.widget<IconButton>(find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == homeNotInLibraryMessage));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse
        .moveTo(tester.getCenter(find.byTooltip('Add Track 1 to queue')));
    await tester.pumpAndSettle();
    expect(enabled.style, isNull,
        reason: 'caller must not override the shared native state palette');
    expect(disabled.style, isNull);
    final material = find.descendant(
        of: find.byWidgetPredicate(
            (w) => w is IconButton && w.tooltip == 'Add Track 1 to queue'),
        matching: find.byType(Material));
    expect(tester.widget<Material>(material).color, AppTheme.accent);
    expect(disabled.onPressed, isNull);
    await mouse.removePointer();
  });

  testWidgets('current track emphasis stays owned by NowPlayingRow',
      (tester) async {
    final playback = _RecordingPlayback(selectedId: '1');
    await _pumpHome(tester, playback: playback);
    final title = find.text('Track 1');
    expect(find.ancestor(of: title, matching: find.byType(NowPlayingRow)),
        findsOneWidget);
    expect(tester.widget<Text>(title).style?.color, AppTheme.orange);
    expect(find.byKey(const ValueKey('song_row_current')), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(title));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(title).style?.color, AppTheme.orange,
        reason: 'hover cyan must not replace canonical current-track orange');
    await mouse.removePointer();
  });

  testWidgets('unowned ellipsized desktop history recovers its title on hover',
      (tester) async {
    const longTitle =
        'An extremely long unowned historical recording title that cannot fit '
        'in one compact tile';
    final playback = _RecordingPlayback();
    final router = GoRouter(initialLocation: '/home', routes: [
      ShellRoute(
          builder: (_, __, child) => ScaffoldWithNavBar(
              miniPlayer: const SizedBox.shrink(), child: child),
          routes: [
            GoRoute(
                path: '/home',
                builder: (_, __) => HomeScreen(
                    homeService: _FeedService(
                        [_track(8, title: longTitle, inLibrary: false)],
                        [],
                        []))),
          ]),
    ]);
    addTearDown(router.dispose);
    tester.view
      ..physicalSize = const Size(1200, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ListenableProvider<PlaybackState>.value(
        value: playback,
        child: MaterialApp.router(
            theme: AppTheme.darkTheme,
            routerConfig: router,
            builder: (_, child) => SoundQDesktopTheme(child: child!))));
    await tester.pumpAndSettle();

    final title = find.text(longTitle);
    final titleWidget = tester.widget<Text>(title);
    expect(titleWidget.maxLines, 1);
    expect(titleWidget.overflow, TextOverflow.ellipsis);
    expect(
        tester.renderObject<RenderParagraph>(title).didExceedMaxLines, isTrue,
        reason:
            'the full title must actually be clipped in the composed shell');
    final row = find.ancestor(of: title, matching: find.byType(InkWell)).first;
    final disabledQueue = find.descendant(
        of: row,
        matching: find.byWidgetPredicate((widget) =>
            widget is IconButton && widget.tooltip == homeNotInLibraryMessage));
    expect(disabledQueue, findsOneWidget);
    expect(tester.widget<IconButton>(disabledQueue).onPressed, isNull);

    final hoverMessage = find.byWidgetPredicate((widget) =>
        widget is Text &&
        widget.textSpan != null &&
        widget.textSpan!.toPlainText().contains(homeNotInLibraryMessage));
    expect(hoverMessage, findsNothing,
        reason: 'the tooltip must not be visible before pointer hover');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(title));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(hoverMessage, findsOneWidget,
        reason: 'real mouse hover must show the native membership tooltip');
    final message = tester.widget<Text>(hoverMessage).textSpan!.toPlainText();
    expect(message, contains(longTitle),
        reason: 'hover must recover the full intentionally ellipsized title');
    expect(message, contains(homeNotInLibraryMessage));
    final fade = tester.widget<FadeTransition>(find
        .ancestor(of: hoverMessage, matching: find.byType(FadeTransition))
        .first);
    expect(fade.opacity.value, 1);
    final tooltipParagraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: hoverMessage, matching: find.byType(RichText)));
    expect(tooltipParagraph.didExceedMaxLines, isFalse);
    expect(tester.getRect(hoverMessage).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(hoverMessage).right, lessThanOrEqualTo(1200));
    expect(playback.playedIds, isNull);
    expect(playback.enqueuedIds, isEmpty);

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    await tester.tap(disabledQueue);
    await tester.pumpAndSettle();
    expect(playback.playedIds, isNull);
    expect(playback.enqueuedIds, isEmpty);
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(find.text(homeNotInLibraryMessage), findsOneWidget);
    expect(playback.playedIds, isNull);
    expect(playback.enqueuedIds, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unowned desktop history explains itself without playing',
      (tester) async {
    final playback = _RecordingPlayback();
    await _pumpHome(tester,
        playback: playback, recent: [_track(8, inLibrary: false)]);
    expect(find.text('Not in your library'), findsOneWidget);
    await tester.tap(find.text('Track 8'));
    await tester.pumpAndSettle();
    expect(playback.playedIds, isNull);
    expect(playback.enqueuedIds, isEmpty);
    expect(find.text(homeNotInLibraryMessage), findsOneWidget);
  });

  testWidgets('queue tooltip names the configured play-next action',
      (tester) async {
    final playback = _RecordingPlayback(queueMode: QueueInsertMode.playNext);
    await _pumpHome(tester, playback: playback);
    expect(find.byTooltip('Play next: Track 1'), findsOneWidget);
    await tester.tap(find.byTooltip('Play next: Track 1'));
    await tester.pumpAndSettle();
    expect(playback.enqueuedIds, [1]);
    expect(playback.insertMode, QueueInsertMode.playNext);
  });

  testWidgets('routed Home regions fill the post-sidebar slot', (tester) async {
    final router = GoRouter(initialLocation: '/home', routes: [
      ShellRoute(
          builder: (_, __, child) => ScaffoldWithNavBar(
              miniPlayer: const SizedBox.shrink(), child: child),
          routes: [
            GoRoute(
                path: '/home',
                builder: (_, __) =>
                    HomeScreen(homeService: _FeedService([_track(1)], [], []))),
          ]),
    ]);
    addTearDown(router.dispose);
    tester.view
      ..physicalSize = const Size(960, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ListenableProvider<PlaybackState>.value(
        value: _RecordingPlayback(),
        child: MaterialApp.router(
            theme: AppTheme.darkTheme, routerConfig: router)));
    for (final width in [960.0, 1199.0, 1200.0, 1439.0, 1440.0, 2560.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      final slot = tester
          .getSize(find.byKey(const ValueKey('soundq_desktop_home')))
          .width;
      final row = find
          .ancestor(of: find.text('Track 1'), matching: find.byType(InkWell))
          .first;
      expect(tester.getSize(row).width, slot, reason: '${width.toInt()}px');
      expect(find.text('Recently played'), findsOneWidget);
      expect(find.text('Your top tracks'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
      'wide split stays lazy with unequal source lengths and one viewport',
      (tester) async {
    final playback = _RecordingPlayback();
    await _pumpHome(tester,
        playback: playback,
        scale: 2,
        recent: List.generate(120, (i) => _track(i + 1)),
        top: [],
        playlists: List.generate(
            150,
            (i) => Playlist.fromJson({
                  'id': i + 1,
                  'name': 'Collection ${i + 1}',
                  'trackCount': i + 2,
                })));
    expect(find.byKey(const ValueKey('home_main_secondary')), findsOneWidget);
    expect(find.byType(Scrollable), findsOneWidget);
    expect(find.byType(TrackArtwork).evaluate().length, lessThan(30));
    expect(find.text('Track 120'), findsNothing);
    expect(find.text('Collection 150'), findsNothing);
    final scrollable = find.byType(Scrollable);
    await tester.scrollUntilVisible(find.text('Track 120'), 600,
        scrollable: scrollable, maxScrolls: 60);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Track 120'));
    await tester.pumpAndSettle();
    expect(playback.playedIds, List.generate(120, (i) => i + 1));
    expect(playback.startIndex, 119);
    await tester.scrollUntilVisible(find.text('Collection 150'), 600,
        scrollable: scrollable, maxScrolls: 60);
    await tester.pumpAndSettle();
    expect(find.text('151 tracks'), findsOneWidget);
    expect(find.byType(TrackArtwork).evaluate().length, lessThan(30));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sparse top-only and collection-only feeds omit absent regions',
      (tester) async {
    await _pumpHome(tester, recent: [], top: [_track(3)]);
    expect(find.text('Recently played'), findsNothing);
    expect(find.text('Your top tracks'), findsOneWidget);
    expect(find.text('Playlists'), findsNothing);
    // HomeService is captured at initState: mount a fresh route for a new feed.
    await tester.pumpWidget(const SizedBox());
    await _pumpHome(tester, recent: [], top: [], playlists: [
      Playlist.fromJson({'id': 3, 'name': 'Only collection', 'trackCount': 1}),
    ]);
    expect(find.text('Recently played'), findsNothing);
    expect(find.text('Your top tracks'), findsNothing);
    expect(find.text('Playlists'), findsOneWidget);
    expect(find.text('1 track'), findsOneWidget);
    expect(find.byKey(const ValueKey('home_main_secondary')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard queue action never activates its parent track',
      (tester) async {
    final playback = _RecordingPlayback(queueMode: QueueInsertMode.playNext);
    await _pumpHome(tester, playback: playback);
    final button = find.byTooltip('Play next: Track 1');
    final ink = tester.widget<InkWell>(
        find.descendant(of: button, matching: find.byType(InkWell)));
    for (var i = 0; i < 20; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      if (ink.statesController!.value.contains(WidgetState.focused)) break;
    }
    expect(ink.statesController!.value, contains(WidgetState.focused));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(playback.playedIds, isNull);
    expect(playback.enqueuedIds, [1]);
    expect(playback.insertMode, QueueInsertMode.playNext);
  });

  testWidgets('real-font narrow child slot grows without losing queue controls',
      (tester) async {
    await loadFlightFonts(tester);
    for (final scale in [1.0, 2.0]) {
      await _pumpHome(tester, width: 960, slotWidth: 350, scale: scale);
      final row = find
          .ancestor(of: find.text('Track 1'), matching: find.byType(InkWell))
          .first;
      final title = tester.widget<Text>(find.text('Track 1'));
      expect(title.style!.fontSize, 18);
      expect(title.style!.fontWeight, FontWeight.w600);
      expect(title.style!.fontFamily, 'Space Grotesk');
      expect(tester.getSize(row).width, 350);
      final queue = tester.getRect(find.byTooltip('Add Track 1 to queue'));
      expect(queue.right, lessThanOrEqualTo(tester.getRect(row).right));
      expect(queue.bottom, lessThanOrEqualTo(tester.getRect(row).bottom));
      expect(tester.getRect(find.text('Artist 1')).bottom,
          lessThanOrEqualTo(tester.getRect(row).bottom));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('959px retains the mobile feed', (tester) async {
    await _pumpHome(tester, width: 959);
    expect(find.byType(SliverGrid), findsNothing);
    expect(find.text('Recently played'), findsOneWidget);
    expect(find.text('Your top tracks'), findsOneWidget);
    expect(find.byKey(const ValueKey('home_queue_Recently played_1_0')),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpHome(
  WidgetTester tester, {
  double width = 1440,
  double scale = 1,
  double? slotWidth,
  List<Track>? recent,
  List<Track>? top,
  List<Playlist> playlists = const [],
  _RecordingPlayback? playback,
}) async {
  tester.view
    ..physicalSize = Size(width, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ListenableProvider<PlaybackState>.value(
      value: playback ?? _RecordingPlayback(),
      child: MaterialApp(
        theme: AppTheme.darkTheme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
          ),
          child: SoundQDesktopTheme(child: child!),
        ),
        home: Row(
          children: [
            if (width >= 960)
              SizedBox(
                  width: slotWidth == null
                      ? (width >= 1200 ? 224 : 80)
                      : width - slotWidth),
            Expanded(
              child: HomeScreen(
                homeService: _FeedService(
                  recent ?? [_track(1), _track(2)],
                  top ?? [_track(3)],
                  playlists,
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Track _track(int id, {String? title, bool? inLibrary = true}) => Track(
      id: id,
      identityHash: 'density-$id',
      title: title ?? 'Track $id',
      artist: 'Artist $id',
      durationMs: 180000,
      artworkKind: TrackArtworkKind.none,
      inLibrary: inLibrary,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

class _RecordingPlayback extends Fake implements PlaybackState {
  _RecordingPlayback(
      {this.selectedId, this.queueMode = QueueInsertMode.addToQueue});
  final String? selectedId;
  final QueueInsertMode queueMode;
  List<int>? playedIds;
  int? startIndex;
  final enqueuedIds = <int>[];
  QueueInsertMode? insertMode;

  @override
  QueueInsertMode get swipeQueueMode => queueMode;

  @override
  Future<void> queueTrack(Map<String, dynamic> track,
      {required QueueInsertMode mode}) async {
    enqueuedIds.add(track['id'] as int);
    insertMode = mode;
  }

  @override
  PlaybackSnapshot get snapshot => selectedId == null
      ? PlaybackSnapshot.empty()
      : PlaybackSnapshot(
          sessionId: 'home-density',
          cues: const [],
          currentCueId: null,
          currentQueueIndex: 0,
          currentMediaItem: MediaItem(id: selectedId!, title: 'Selected'),
          localPosition: Duration.zero,
          localDuration: Duration.zero,
          globalPosition: Duration.zero,
          globalDuration: Duration.zero,
          playing: false,
          processingState: ProcessingState.loading,
          activeVoiceCount: 0,
        );

  @override
  Future<void> playQueue(List<Map<String, dynamic>> tracks,
      {int startIndex = 0, PlaybackContext? context}) async {
    playedIds = [for (final track in tracks) track['id'] as int];
    this.startIndex = startIndex;
  }

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}
}

class _FeedService extends HomeService {
  _FeedService(this.recent, this.top, this.lists) : super(_UnusedApi());
  final List<Track> recent;
  final List<Track> top;
  final List<Playlist> lists;

  @override
  Future<List<Track>> recentlyPlayed({int limit = 20}) async => recent;

  @override
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) async => top;

  @override
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) async =>
      lists;
}

class _UnusedApi extends ApiClient {
  @override
  Future<Response<T>> get<T>(String path,
      {Map<String, dynamic>? queryParameters,
      Map<String, dynamic>? headers,
      Duration? receiveTimeout}) async {
    throw StateError('No network in Home density tests: $path');
  }
}
