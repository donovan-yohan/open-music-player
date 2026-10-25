import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/shared/widgets/song_list_item.dart';
import 'package:open_music_player/shared/widgets/now_playing_row.dart';
import 'package:open_music_player/shared/widgets/playlist_card.dart';

import 'flight_theme_typography_test.dart' show loadFlightFonts;
import 'song_row_presentation_test.dart' show FakePlayback, makeSnapshot;

final receipt = GlobalKey();
final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  testWidgets(
      'Home queue actual hovered foreground contrasts with its Material',
      (tester) async {
    await pumpHome(tester);
    final button = find.widgetWithIcon(IconButton, Icons.add_to_queue).first;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(button));
    await tester.pumpAndSettle();
    final icon =
        find.descendant(of: button, matching: find.byIcon(Icons.add_to_queue));
    final foreground = IconTheme.of(tester.element(icon)).color!;
    final material =
        find.descendant(of: button, matching: find.byType(Material));
    final fill = tester.widget<Material>(material).color!;
    final painted = await pixel(
        tester, tester.getRect(material).topLeft + const Offset(5, 5));
    expect(painted, fill,
        reason:
            'measure the actual painted control, not only a resolved token');
    expect(contrast(foreground, painted), greaterThanOrEqualTo(4.5));
    Focus.of(tester.element(icon)).requestFocus();
    await tester.pumpAndSettle();
    final ink = tester.widget<InkWell>(
        find.descendant(of: button, matching: find.byType(InkWell)));
    expect(ink.statesController!.value,
        containsAll([WidgetState.hovered, WidgetState.focused]));
    await mouse.down(tester.getCenter(button));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
        ink.statesController!.value,
        containsAll(
            [WidgetState.hovered, WidgetState.focused, WidgetState.pressed]));
    Future<void> sample() async {
      final fg = IconTheme.of(tester.element(icon)).color!;
      final background = await pixel(
          tester, tester.getRect(material).topLeft + const Offset(5, 5));
      expect(contrast(fg, background), greaterThanOrEqualTo(4.5));
    }

    for (final ms in [0, 50, 150, 300]) {
      await tester.pump(Duration(milliseconds: ms));
      await sample();
    }
    await save(tester, 'home-queue-focus-hover-held');
    await mouse.cancel();
    for (final ms in [0, 50, 150, 300]) {
      await tester.pump(Duration(milliseconds: ms));
      await sample();
    }
    await save(tester, 'home-queue-release');
  }, variant: macOS);
  testWidgets('Home entire tile has an opaque readable neutral hover step',
      (tester) async {
    await pumpHome(tester, selected: true);
    final tile = find
        .ancestor(of: find.text('Glasshouse'), matching: find.byType(InkWell))
        .first;
    final rect = tester.getRect(tile);
    final points = [
      Offset(rect.left + 70, rect.bottom - 5),
      Offset(rect.right - 65, rect.bottom - 5)
    ];
    final before = [for (final p in points) await pixel(tester, p)];
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Glasshouse')));
    await tester.pumpAndSettle();
    final material = tester.widget<Material>(
        find.ancestor(of: tile, matching: find.byType(Material)).first);
    final colors = Theme.of(tester.element(tile)).colorScheme;
    expect(material.color!.a, 1);
    for (var i = 0; i < points.length; i++) {
      final painted = await pixel(tester, points[i]);
      expect(contrast(before[i], painted), greaterThanOrEqualTo(1.2),
          reason: 'the entire tile must visibly step, not only its edge');
      expect(contrast(colors.primary, painted), greaterThanOrEqualTo(4.5));
      expect(contrast(colors.secondary, painted), greaterThanOrEqualTo(4.5));
    }
    expect(tester.widget<Text>(find.text('Glasshouse')).style!.color,
        colors.primary);
    expect(find.byKey(const ValueKey('song_row_current')), findsOneWidget);
  }, variant: macOS);
  testWidgets(
      'track row whole surface steps opaquely and preserves current orange',
      (tester) async {
    var taps = 0;
    await pumpFixture(
        tester,
        SongRowTreatment(
            presentation: SongRowPresentation.paused,
            child: SongListItem(
              title: const Text('Track row'),
              leading: const SizedBox(width: 40, height: 40),
              subtitle: const Text('Artist'),
              onTap: () => taps++,
            )));
    final row = find.byType(SongListItem);
    final rect = tester.getRect(row);
    final p = Offset(rect.right - 80, rect.bottom - 6);
    final before = await pixel(tester, p);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Track row')));
    await tester.pumpAndSettle();
    final fill = await pixel(tester, p);
    final colors = Theme.of(tester.element(row)).colorScheme;
    expect(contrast(before, fill), greaterThanOrEqualTo(1.2));
    expect(contrast(colors.primary, fill), greaterThanOrEqualTo(4.5));
    expect(contrast(colors.onSurfaceVariant, fill), greaterThanOrEqualTo(4.5));
    final decor = tester
        .widget<Ink>(find.byKey(const ValueKey('song_list_item_outline')))
        .decoration! as BoxDecoration;
    expect(decor.color!.a, 1);
    expect(find.byKey(const ValueKey('song_row_current')), findsOneWidget);
    expect(tester.getRect(row), rect);
    await tester.tap(find.text('Track row'));
    expect(taps, 1);
  }, variant: macOS);
  testWidgets(
      'playlist card feedback covers artwork and text with opaque surface',
      (tester) async {
    var taps = 0;
    await pumpFixture(
        tester,
        SizedBox(
            width: 240,
            height: 240,
            child: PlaylistCard(
                playlist: Playlist.fromJson(
                    {'id': 3, 'name': 'Rotation', 'trackCount': 8}),
                onTap: () => taps++)));
    final rect = tester.getRect(find.byType(PlaylistCard));
    final points = [
      rect.topLeft + const Offset(10, 10),
      rect.bottomRight - const Offset(10, 10)
    ];
    final before = [for (final p in points) await pixel(tester, p)];
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Rotation')));
    await tester.pumpAndSettle();
    final colors = Theme.of(tester.element(find.text('Rotation'))).colorScheme;
    for (var i = 0; i < points.length; i++) {
      final painted = await pixel(tester, points[i]);
      expect(contrast(before[i], painted), greaterThanOrEqualTo(1.2));
      expect(contrast(colors.onSurface, painted), greaterThanOrEqualTo(4.5));
      expect(contrast(colors.secondary, painted), greaterThanOrEqualTo(4.5));
    }
    final art = tester.widget<Ink>(find
        .descendant(of: find.byType(PlaylistCard), matching: find.byType(Ink))
        .first);
    expect((art.decoration! as BoxDecoration).color!.a, 1);
    expect(tester.getRect(find.byType(PlaylistCard)), rect);
    await tester.tap(find.text('Rotation'));
    expect(taps, 1);
  }, variant: macOS);
  testWidgets(
      'row native focus hover held release and child action stay independent',
      (tester) async {
    var plays = 0, actions = 0;
    await pumpFixture(
        tester,
        SongListItem(
            title: const Text('Row action'),
            subtitle: const Text('Artist'),
            leading: const SizedBox(width: 40, height: 40),
            onTap: () => plays++,
            trailing: IconButton(
                tooltip: 'Row menu',
                icon: const Icon(Icons.more_horiz),
                onPressed: () => actions++)));
    final row = find.byType(SongListItem);
    final inkFinder =
        find.descendant(of: row, matching: find.byType(InkWell)).first;
    final rect = tester.getRect(row);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Row action')));
    final node = Focus.of(tester.element(find.text('Row action')));
    node.requestFocus();
    await tester.pumpAndSettle();
    final ink = tester.widget<InkWell>(inkFinder);
    expect(ink.statesController!.value,
        containsAll([WidgetState.focused, WidgetState.hovered]));
    await mouse.down(tester.getCenter(find.text('Row action')));
    await tester.pump();
    expect(
        ink.statesController!.value,
        containsAll(
            [WidgetState.focused, WidgetState.hovered, WidgetState.pressed]));
    for (final ms in [0, 50, 150, 300]) {
      await tester.pump(Duration(milliseconds: ms));
      final fill =
          await pixel(tester, Offset(rect.right - 70, rect.bottom - 5));
      final colors = Theme.of(tester.element(row)).colorScheme;
      for (final fg in [
        colors.onSurface,
        colors.onSurfaceVariant,
        colors.secondary
      ]) {
        expect(contrast(fg, fill), greaterThanOrEqualTo(4.5));
      }
    }
    await save(tester, 'track-row-focus-hover-held');
    await mouse.up();
    await tester.pumpAndSettle();
    expect(plays, 1);
    await mouse.moveTo(tester.getCenter(find.byTooltip('Row menu')));
    await tester.pumpAndSettle();
    expect(ink.statesController!.value, contains(WidgetState.hovered));
    await tester.tap(find.byTooltip('Row menu'));
    expect(actions, 1);
    expect(plays, 1);
    node.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(plays, 2);
    expect(tester.getRect(row), rect);
    await tester.pumpAndSettle();
    await save(tester, 'track-row-child-hover');
  }, variant: macOS);

  testWidgets(
      'light desktop current row keeps orange and cyan readable during hover',
      (tester) async {
    await pumpFixture(
        tester,
        const SongRowTreatment(
            presentation: SongRowPresentation.paused,
            child: SongListItem(
                title: Text('Light current'),
                leading: SizedBox(width: 40, height: 40),
                onTap: _noop)),
        theme: AppTheme.lightTheme);
    final row = find.byType(SongListItem);
    final rect = tester.getRect(row);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Light current')));
    await tester.pumpAndSettle();
    final fill = await pixel(tester, Offset(rect.right - 80, rect.bottom - 5));
    final colors = Theme.of(tester.element(row)).colorScheme;
    expect(contrast(colors.primary, fill), greaterThanOrEqualTo(4.5));
    expect(contrast(colors.secondary, fill), greaterThanOrEqualTo(4.5));
  }, variant: macOS);

  testWidgets('playlist native focus hover held release and disabled geometry',
      (tester) async {
    var opens = 0;
    final playlist =
        Playlist.fromJson({'id': 3, 'name': 'Rotation', 'trackCount': 8});
    Widget card(bool enabled) => SizedBox(
        width: 240,
        height: 240,
        child: PlaylistCard(
            playlist: playlist, onTap: enabled ? () => opens++ : null));
    await pumpFixture(tester, card(true), scale: 2, width: 960);
    final finder = find.byType(PlaylistCard);
    final rect = tester.getRect(finder);
    final ink = tester.widget<InkWell>(
        find.descendant(of: finder, matching: find.byType(InkWell)));
    final node = Focus.of(tester.element(find.text('Rotation')));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Rotation')));
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(ink.statesController!.value,
        containsAll([WidgetState.hovered, WidgetState.focused]));
    await mouse.down(tester.getCenter(find.text('Rotation')));
    await tester.pump();
    expect(
        ink.statesController!.value,
        containsAll(
            [WidgetState.hovered, WidgetState.focused, WidgetState.pressed]));
    Future<void> sample() async {
      final colors = Theme.of(tester.element(finder)).colorScheme;
      for (final p in [
        rect.topLeft + const Offset(10, 10),
        rect.bottomRight - const Offset(10, 6)
      ]) {
        final fill = await pixel(tester, p);
        for (final fg in [
          colors.secondary,
          colors.onSurface,
          colors.onSurfaceVariant
        ]) {
          expect(contrast(fg, fill), greaterThanOrEqualTo(4.5));
        }
      }
      expect(tester.getRect(finder), rect);
    }

    for (final ms in [0, 50, 150, 300]) {
      await tester.pump(Duration(milliseconds: ms));
      await sample();
    }
    await save(tester, 'playlist-960-2x-focus-hover-held');
    await mouse.up();
    for (final ms in [0, 50, 150, 300]) {
      await tester.pump(Duration(milliseconds: ms));
      await sample();
    }
    expect(opens, 1);
    await save(tester, 'playlist-960-2x-release');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(opens, 2);
    await pumpFixture(tester, card(false), scale: 2, width: 960);
    await mouse.moveTo(rect.center);
    await tester.pumpAndSettle();
    final disabled = tester.widget<InkWell>(
        find.descendant(of: finder, matching: find.byType(InkWell)));
    expect(disabled.onTap, isNull);
    expect(tester.widget<Card>(find.byType(Card)).color,
        AppTheme.darkTheme.colorScheme.surface);
    expect(tester.getRect(finder), rect);
    await tester.tap(finder);
    expect(opens, 2);
  }, variant: macOS);

  testWidgets('held row can become unavailable without losing native lifecycle',
      (tester) async {
    var enabled = true;
    late StateSetter update;
    await pumpFixture(tester, StatefulBuilder(builder: (context, setState) {
      update = setState;
      return SongListItem(
          title: const Text('Availability'),
          leading: const SizedBox(width: 40, height: 40),
          onTap: enabled ? _noop : null);
    }));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Availability')));
    await mouse.down(tester.getCenter(find.text('Availability')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    update(() => enabled = false);
    await tester.pumpAndSettle();
    await mouse.up();
    await tester.pumpAndSettle();
    final ink = tester.widget<InkWell>(find.descendant(
        of: find.byType(SongListItem), matching: find.byType(InkWell)));
    expect(ink.onTap, isNull);
    expect(ink.statesController!.value, contains(WidgetState.disabled));
    expect(tester.takeException(), isNull);
  }, variant: macOS);

  for (final width in [959.0, 960.0, 1200.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Home state receipts $width ${scale}x', (tester) async {
        await pumpHome(tester, width: width, scale: scale, selected: true);
        final title = find.text('Glasshouse');
        final row =
            find.ancestor(of: title, matching: find.byType(InkWell)).first;
        final rect = tester.getRect(row);
        await save(tester, 'home-${width.toInt()}-${scale.toInt()}x-rest');
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(title));
        await tester.pumpAndSettle();
        if (width >= 960) {
          final ink = tester.widget<InkWell>(row);
          Focus.of(tester.element(
                  find.descendant(of: title, matching: find.byType(RichText))))
              .requestFocus();
          await tester.pumpAndSettle();
          // Tab reaches the real outer InkWell without replacing its action.
          if (!ink.statesController!.value.contains(WidgetState.focused)) {
            for (var i = 0; i < 12; i++) {
              await tester.sendKeyEvent(LogicalKeyboardKey.tab);
              await tester.pumpAndSettle();
              if (ink.statesController!.value.contains(WidgetState.focused)) {
                break;
              }
            }
          }
          expect(ink.statesController!.value,
              containsAll([WidgetState.focused, WidgetState.hovered]));
          await save(
              tester, 'home-${width.toInt()}-${scale.toInt()}x-focus-hover');
          await mouse.down(tester.getCenter(title));
          await tester.pump();
          expect(
              ink.statesController!.value,
              containsAll([
                WidgetState.focused,
                WidgetState.hovered,
                WidgetState.pressed
              ]));
          for (final ms in [0, 50, 150, 300]) {
            await tester.pump(Duration(milliseconds: ms));
            final fill =
                await pixel(tester, Offset(rect.right - 65, rect.bottom - 5));
            final colors = Theme.of(tester.element(row)).colorScheme;
            for (final fg in [
              colors.primary,
              colors.secondary,
              colors.onSurface,
              colors.onSurfaceVariant
            ]) {
              expect(contrast(fg, fill), greaterThanOrEqualTo(4.5));
            }
          }
          await save(tester, 'home-${width.toInt()}-${scale.toInt()}x-held');
          await mouse.cancel();
          await tester.pump(const Duration(milliseconds: 100));
          await save(tester, 'home-${width.toInt()}-${scale.toInt()}x-release');
          expect(tester.getRect(row), rect);
        } else {
          expect(find.byType(SliverGrid), findsNothing);
          expect(find.text('Recently played'), findsOneWidget);
        }
        expect(find.byKey(const ValueKey('song_row_current')), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: macOS);
    }
  }
}

void _noop() {}

Future<void> pumpFixture(WidgetTester tester, Widget child,
    {double width = 1200, double scale = 1, ThemeData? theme}) async {
  await loadFlightFonts(tester);
  tester.view
    ..physicalSize = Size(width, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
      theme: theme ?? AppTheme.darkTheme,
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: SoundQDesktopTheme(child: child!)),
      home: RepaintBoundary(
          key: receipt,
          child: Scaffold(
              body: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: 600, child: child))))));
  await tester.pumpAndSettle();
}

Future<void> pumpHome(WidgetTester tester,
    {double width = 1200, double scale = 1, bool selected = false}) async {
  expect(defaultTargetPlatform, TargetPlatform.macOS);
  await loadFlightFonts(tester);
  tester.view
    ..physicalSize = Size(width, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final playback = _Playback()..set(makeSnapshot(id: selected ? '1' : null));
  addTearDown(playback.dispose);
  final router = GoRouter(initialLocation: '/home', routes: [
    ShellRoute(
        builder: (_, __, child) => ScaffoldWithNavBar(
            miniPlayer: const SizedBox.shrink(), child: child),
        routes: [
          GoRoute(
              path: '/home',
              builder: (_, __) => HomeScreen(homeService: _Feed())),
        ]),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(ListenableProvider<PlaybackState>.value(
      value: playback,
      child: MaterialApp.router(
        theme: AppTheme.darkTheme,
        routerConfig: router,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: SoundQDesktopTheme(
                child: RepaintBoundary(key: receipt, child: child!))),
      )));
  await tester.pumpAndSettle();
}

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

Future<Color> pixel(WidgetTester tester, Offset global) async {
  return (await tester.runAsync(() async {
    final render =
        receipt.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final p = render.globalToLocal(global);
    final i = (p.dy.floor() * image.width + p.dx.floor()) * 4;
    final color = Color.fromARGB(bytes.getUint8(i + 3), bytes.getUint8(i),
        bytes.getUint8(i + 1), bytes.getUint8(i + 2));
    image.dispose();
    return color;
  }))!;
}

Future<void> save(WidgetTester tester, String name) async {
  const output = String.fromEnvironment('FLIGHT_CALLERS_CAPTURE_DIR');
  if (output.isEmpty) return;
  await tester.runAsync(() async {
    final render =
        receipt.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File('$output/$name.png').create(recursive: true);
    await File('$output/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

class _Playback extends FakePlayback {
  @override
  QueueInsertMode get swipeQueueMode => QueueInsertMode.addToQueue;
}

class _Feed extends HomeService {
  _Feed() : super(ApiClient());
  @override
  Future<List<Track>> recentlyPlayed({int limit = 20}) async => [
        Track.fromJson({
          'id': 1,
          'title': 'Glasshouse',
          'artist': 'Sora',
          'inLibrary': true
        }),
        Track.fromJson({
          'id': 2,
          'title': 'Historical recording',
          'artist': 'Night shift',
          'inLibrary': false
        }),
      ];
  @override
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) async => [];
  @override
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) async => [
        Playlist.fromJson({'id': 3, 'name': 'Rotation', 'trackCount': 8})
      ];
}
