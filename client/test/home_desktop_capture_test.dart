// Actual routed widgets and shipped typography, not an HTML/mock rendering.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/shared/models/models.dart';

import 'flight_theme_typography_test.dart' show loadFlightFonts;
import 'song_row_presentation_test.dart' show FakePlayback, makeSnapshot;

void main() {
  const output = String.fromEnvironment('HOME_CAPTURE_DIR');
  const japaneseFont = String.fromEnvironment('HOME_CAPTURE_JP_FONT');
  for (final width in [960.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final sparse in [false, true]) {
        final name =
            'home-${width.toInt()}-${scale.toInt()}x-${sparse ? 'sparse' : 'heterogeneous'}';
        testWidgets(name, (tester) async {
          await loadFlightFonts(tester);
          if (japaneseFont.isNotEmpty) {
            await tester.runAsync(() async {
              final loader = FontLoader('Noto Sans CJK JP');
              loader.addFont(Future.value(ByteData.sublistView(
                  await File(japaneseFont).readAsBytes())));
              await loader.load();
            });
          }
          tester.view
            ..physicalSize = Size(width, 900)
            ..devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final playback = _Playback()..set(makeSnapshot(id: '1'));
          addTearDown(playback.dispose);
          final service = _CaptureFeed(sparse);
          final router = GoRouter(initialLocation: '/home', routes: [
            ShellRoute(
                builder: (_, __, child) => ScaffoldWithNavBar(
                    miniPlayer: const SizedBox.shrink(), child: child),
                routes: [
                  GoRoute(
                      path: '/home',
                      builder: (_, __) => HomeScreen(homeService: service)),
                ]),
          ]);
          addTearDown(router.dispose);
          final receipt = GlobalKey();
          await tester.pumpWidget(ListenableProvider<PlaybackState>.value(
              value: playback,
              child: MaterialApp.router(
                  theme: AppTheme.darkTheme,
                  routerConfig: router,
                  builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: SoundQDesktopTheme(
                          child:
                              RepaintBoundary(key: receipt, child: child!))))));
          await tester.pumpAndSettle();
          expect(find.text('Recently played'), findsOneWidget);
          expect(find.byType(CustomScrollView), findsOneWidget);
          expect(find.byType(SliverGrid), findsNothing);
          final title = tester.widget<Text>(find.text('Glasshouse'));
          expect(title.style!.fontFamily, 'Space Grotesk');
          expect(title.style!.fontSize, 18);
          final row = find
              .ancestor(
                  of: find.text('Glasshouse'), matching: find.byType(InkWell))
              .first;
          expect(tester.getSize(row).height, greaterThanOrEqualTo(56));
          final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(
                  of: find.text('Glasshouse'),
                  matching: find.byType(RichText)));
          expect(paragraph.didExceedMaxLines, isFalse);
          if (sparse) {
            expect(find.text('Your top tracks'), findsNothing);
            expect(find.byKey(const ValueKey('home_header_Playlists')),
                findsNothing);
          } else if (width == 1440) {
            expect(find.byKey(const ValueKey('home_main_secondary')),
                findsOneWidget);
            final recentHeader = tester.getRect(
                find.byKey(const ValueKey('home_header_Recently played')));
            final playlistHeader = tester
                .getRect(find.byKey(const ValueKey('home_header_Playlists')));
            expect(recentHeader.right, playlistHeader.left);
            expect(recentHeader.bottom, playlistHeader.bottom);
            final colors =
                Theme.of(tester.element(find.byType(HomeScreen))).colorScheme;
            await _expectRulePixels(
                tester,
                receipt,
                [
                  Offset(recentHeader.left + 4, recentHeader.bottom - .5),
                  Offset(recentHeader.right - .5, recentHeader.bottom - .5),
                  Offset(playlistHeader.left + 4, playlistHeader.bottom - .5),
                  Offset(recentHeader.right - .5, recentHeader.bottom + 10),
                ],
                colors.outline);
            expect(
                find.descendant(
                    of: find.byType(HomeScreen),
                    matching: find.byIcon(Icons.library_music_outlined)),
                findsNWidgets(2));
          }
          expect(tester.takeException(), isNull);
          if (output.isNotEmpty) {
            expect(japaneseFont, isNotEmpty,
                reason: 'capture receipts must load a real Japanese fallback');
            await _save(tester, receipt, '$output/$name.png');
          }
          if (!sparse) {
            final scrollable = find
                .descendant(
                    of: find.byKey(const ValueKey('soundq_desktop_home')),
                    matching: find.byType(Scrollable))
                .first;
            await tester.scrollUntilVisible(find.text('Long drives'), 400,
                scrollable: scrollable);
            await tester.pumpAndSettle();
            expect(find.text('32 tracks'), findsOneWidget);
            expect(tester.getRect(find.text('Long drives')).bottom,
                lessThanOrEqualTo(tester.getRect(scrollable).bottom));
            if (output.isNotEmpty) {
              await _save(tester, receipt, '$output/$name-collections.png');
            }
          }
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
      }
    }
  }
}

Future<void> _expectRulePixels(WidgetTester tester, GlobalKey key,
    List<Offset> globalPoints, Color expected) async {
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    for (final point in globalPoints) {
      final local = boundary.globalToLocal(point);
      final offset = (local.dy.floor() * image.width + local.dx.floor()) * 4;
      final painted = Color.fromARGB(
          bytes.getUint8(offset + 3),
          bytes.getUint8(offset),
          bytes.getUint8(offset + 1),
          bytes.getUint8(offset + 2));
      expect(painted, expected,
          reason: 'actual header/divider junction pixel at $point');
    }
    image.dispose();
  });
}

Future<void> _save(WidgetTester tester, GlobalKey key, String path) async {
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

class _Playback extends FakePlayback {
  @override
  QueueInsertMode get swipeQueueMode => QueueInsertMode.addToQueue;
}

class _CaptureFeed extends HomeService {
  _CaptureFeed(this.sparse) : super(ApiClient());
  final bool sparse;
  static final _tracks = [
    for (final (index, entry) in [
      ('Glasshouse', 'Sora'),
      ('夜明けの散歩 — 東京の小さな録音室から', '青葉と風'),
      (
        'A deliberately long recording title from the night shift sessions',
        'The night shift ensemble'
      ),
      ('Subway rhythm', 'Analog people'),
      ('Signal / noise', 'Isla'),
      ('After hours', 'Nadia Reid'),
      ('Northbound', 'Sam Gendel'),
      ('Low tide', 'Ichiko Aoba'),
      ('Slow motion', 'The Necks'),
      ('Static bloom', 'Kaitlyn Aurelia Smith'),
    ].indexed)
      Track.fromJson({
        'id': index + 1,
        'title': entry.$1,
        'artist': entry.$2,
        'inLibrary': index != 2,
      }),
  ];
  @override
  Future<List<Track>> recentlyPlayed({int limit = 20}) async =>
      sparse ? [_tracks.first] : _tracks.take(6).toList();
  @override
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) async =>
      sparse ? [] : _tracks.skip(6).toList();
  @override
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) async =>
      sparse
          ? []
          : [
              Playlist.fromJson({
                'id': 39,
                'name': 'Night shift — recordings for the long way home',
                'trackCount': 18
              }),
              Playlist.fromJson(
                  {'id': 40, 'name': 'Long drives', 'trackCount': 32}),
            ];
}
