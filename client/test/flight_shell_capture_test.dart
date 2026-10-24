// Real-widget, synthetic-feed receipts. Not native-window/backend evidence.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/features/desktop/desktop_listening_shell.dart';
import 'package:open_music_player/features/desktop/desktop_transport.dart';
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/shared/models/models.dart';

import 'desktop_listening_transport_test.dart'
    show DesktopPlayback, pumpListeningApp;

Future<void> loadFlightFonts() async {
  for (final family in ['Space Grotesk', 'IBM Plex Mono']) {
    final directory =
        family == 'IBM Plex Mono' ? 'ibmplexmono' : 'spacegrotesk';
    final prefix = family.replaceAll(' ', '');
    final loader = FontLoader(family);
    final weights = family == 'IBM Plex Mono'
        ? ['Regular', 'Medium']
        : ['Regular', 'Medium', 'SemiBold', 'Bold'];
    for (final weight in weights) {
      loader.addFont(Future.value(ByteData.sublistView(
          await File('assets/fonts/$directory/$prefix-$weight.ttf')
              .readAsBytes())));
    }
    await loader.load();
  }
  final icons = FontLoader('MaterialIcons');
  icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

ThemeData flightFontTheme() {
  final base = SoundQDesktopTheme.apply(AppTheme.darkTheme);
  const family = 'Space Grotesk';
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: family),
    navigationRailTheme: base.navigationRailTheme.copyWith(
      selectedLabelTextStyle: base.navigationRailTheme.selectedLabelTextStyle!
          .copyWith(fontFamily: family),
      unselectedLabelTextStyle: base
          .navigationRailTheme.unselectedLabelTextStyle!
          .copyWith(fontFamily: family),
    ),
    textButtonTheme: TextButtonThemeData(
        style: base.textButtonTheme.style!.copyWith(
            textStyle: WidgetStatePropertyAll(
                base.textTheme.labelLarge!.copyWith(fontFamily: family)))),
  );
}

void main() {
  testWidgets(
      'real Plex shell geometry, glyphs and optional full-shell receipts',
      (tester) async {
    await tester.runAsync(loadFlightFonts);
    final boundaryKey = GlobalKey();
    const output = String.fromEnvironment('FLIGHT_SHELL_CAPTURE_DIR');
    final receipts = <Map<String, Object>>[];
    for (final size in [
      const Size(960, 900),
      const Size(1200, 900),
      const Size(1440, 900),
      const Size(2560, 1440),
      const Size(1200, 440)
    ]) {
      for (final scale in [1.0, 2.0]) {
        await pumpListeningApp(
          tester,
          _FlightPlayback(),
          size: size,
          textScale: scale,
          content: HomeScreen(homeService: _FlightFeed()),
          shellBuilder: (child) => Theme(
              data: flightFontTheme(),
              child: RepaintBoundary(
                  key: boundaryKey,
                  child: DesktopListeningShell(
                      compact: size.width < 1200,
                      selectedIndex: 0,
                      onDestinationSelected: (_) {},
                      miniPlayer: const DesktopTransport(),
                      child: child))),
        );
        final rail = tester.getRect(
            find.byKey(const ValueKey('soundq_desktop_rail_container')));
        final panel = tester.getRect(
            find.byKey(const ValueKey('soundq_desktop_content_panel')));
        final dock = tester
            .getRect(find.byKey(const ValueKey('soundq_desktop_transport')));
        expect(
            rail.width,
            size.width < 1200
                ? 80
                : scale == 1
                    ? 224
                    : greaterThan(224));
        expect(panel, Rect.fromLTRB(rail.right, 0, size.width, dock.top));
        final firstRow = tester
            .getRect(find.byKey(const ValueKey('soundq_desktop_nav_focus_0')));
        final firstIcon = find.descendant(
            of: find.byKey(const ValueKey('soundq_desktop_nav_focus_0')),
            matching: find.byType(Icon));
        expect(tester.getSize(firstIcon), const Size(20, 20));
        expect(tester.getCenter(firstIcon).dy, firstRow.center.dy);
        if (size.width >= 1200) {
          for (final label in ['Home', 'Connected devices']) {
            final labelFinder = find.descendant(
                of: find.byKey(const ValueKey('soundq_desktop_rail_container')),
                matching: find.text(label));
            final paragraph = tester.renderObject<RenderParagraph>(labelFinder);
            expect(paragraph.didExceedMaxLines, isFalse);
            final textRect = tester.getRect(labelFinder);
            expect(textRect.right, lessThanOrEqualTo(rail.right - 16));
          }
        }
        expect(tester.takeException(), isNull);
        final receipt = <String, Object>{
          'width': size.width,
          'height': size.height,
          'scale': scale,
          'railWidth': rail.width,
          'rowHeight': firstRow.height,
          'panel': [panel.left, panel.top, panel.right, panel.bottom],
          'font': 'Space Grotesk',
          'fixture': 'real widgets / synthetic feed+playback'
        };
        if (output.isNotEmpty) {
          final path =
              '$output/shell-${size.width.toInt()}-${size.height.toInt()}-${scale.toInt()}x.png';
          await saveFlightCapture(tester, boundaryKey, path);
          receipt['png'] = path;
        }
        receipts.add(receipt);
        if (size == const Size(1440, 900) && scale == 1 && output.isNotEmpty) {
          final mouse =
              await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
          await mouse.addPointer(location: const Offset(500, 10));
          for (var i = 0; i < 2; i++) {
            final row = find.byKey(ValueKey('soundq_desktop_nav_focus_$i'));
            await mouse.moveTo(tester.getCenter(row));
            await tester.pumpAndSettle();
            await saveFlightCapture(
                tester, boundaryKey, '$output/shell-hover-$i.png');
            await tester.sendKeyEvent(LogicalKeyboardKey.tab);
            await tester.pumpAndSettle();
            await mouse.down(tester.getCenter(row));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 250));
            await saveFlightCapture(
                tester, boundaryKey, '$output/shell-focus-hover-press-$i.png');
            await mouse.up();
            await tester.pumpAndSettle();
          }
          await mouse.removePointer();
        }
        // Last destination remains reachable through native scrolling at 2x.
        final last = find.byKey(const ValueKey('soundq_desktop_nav_focus_10'));
        await tester.ensureVisible(last);
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    }
    for (final receipt in receipts) {
      debugPrint('flight-shell-receipt $receipt');
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}

Future<void> saveFlightCapture(
    WidgetTester tester, GlobalKey key, String path) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(path).create(recursive: true);
    await File(path).writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

class _FlightPlayback extends DesktopPlayback {
  @override
  QueueInsertMode get swipeQueueMode => QueueInsertMode.addToQueue;
}

class _FlightFeed extends HomeService {
  _FlightFeed() : super(ApiClient());
  final tracks = List.generate(
      12,
      (index) => Track.fromJson({
            'id': index + 1,
            'title': [
              'Glasshouse',
              'Northbound',
              'Signal / noise',
              'After hours'
            ][index % 4],
            'artist': 'The night shift',
          }));
  @override
  Future<List<Track>> recentlyPlayed({int limit = 20}) async =>
      tracks.take(6).toList();
  @override
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) async =>
      tracks.skip(6).toList();
  @override
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) async => [
        Playlist.fromJson(
            {'id': 39, 'name': 'Night shift rotation', 'trackCount': 18}),
      ];
}
