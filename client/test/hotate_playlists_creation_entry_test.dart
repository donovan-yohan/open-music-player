import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/features/playlists/playlists_screen.dart';
import 'package:open_music_player/shared/widgets/playlist_card.dart';

import 'flight_theme_typography_test.dart' show loadFlightFonts;
import 'song_row_presentation_test.dart' show FakePlayback;

final _receipt = GlobalKey();
final _macOS = TargetPlatformVariant.only(TargetPlatform.macOS);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => HttpOverrides.global = null);

  testWidgets(
      'desktop has one labeled native creation entry opening real dialog',
      (tester) async {
    await _pump(tester);
    expect(find.byType(FloatingActionButton), findsNothing,
        reason: 'desktop must not compete with a floating creation plus');
    expect(find.byTooltip('Create playlist'), findsNothing);
    final create = find.widgetWithText(FilledButton, 'New playlist');
    expect(create, findsOneWidget);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('playlist_creation_dialog')), findsOneWidget);
    expect(find.text('Blank playlist'), findsOneWidget);
    expect(find.text('Import from YouTube'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('playlist_creation_dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: _macOS);

  for (final width in [960.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final empty in [false, true]) {
        testWidgets('single toolbar geometry $width ${scale}x empty=$empty',
            (tester) async {
          await _pump(tester, width: width, scale: scale, empty: empty);
          final create = find.widgetWithText(FilledButton, 'New playlist');
          expect(create, findsOneWidget);
          expect(find.byType(FloatingActionButton), findsNothing);
          expect(find.text('Create Playlist'), findsNothing);
          final createRect = tester.getRect(_surface(create));
          expect(createRect.height, greaterThanOrEqualTo(40));
          for (final tooltip in [
            'Edit saved mixes',
            'List view',
            'Sort playlists'
          ]) {
            final button = find
                .ancestor(
                    of: find.byTooltip(tooltip),
                    matching: find.byType(IconButton))
                .first;
            expect(button, findsOneWidget);
            expect(tester.getRect(_surface(button)).height,
                closeTo(createRect.height, .01));
            final icon =
                find.descendant(of: button, matching: find.byType(Icon)).first;
            expect(IconTheme.of(tester.element(icon)).size, 20);
          }
          final material = tester.widget<Material>(_surface(create));
          expect(material.elevation, 0);
          expect((material.shape! as RoundedRectangleBorder).borderRadius,
              BorderRadius.zero);
          final label = tester.renderObject<RenderParagraph>(find.descendant(
              of: find.text('New playlist'), matching: find.byType(RichText)));
          final painter = TextPainter(
              text: label.text,
              textDirection: TextDirection.ltr,
              textScaler: label.textScaler)
            ..layout();
          expect(label.size.width + .01, greaterThanOrEqualTo(painter.width));
          expect(label.size.height + .01, greaterThanOrEqualTo(painter.height));
          painter.dispose();
          final field = tester.widget<TextField>(find.byType(TextField));
          expect(tester.getSize(find.byType(TextField)).height,
              closeTo(createRect.height, .01),
              reason:
                  'search and native actions share one painted toolbar cell');
          expect((field.decoration!.border! as OutlineInputBorder).borderRadius,
              BorderRadius.zero);
          await _save(tester,
              'toolbar-${width.toInt()}-${scale.toInt()}x-${empty ? 'empty' : 'populated'}');
          expect(tester.takeException(), isNull);
        }, variant: _macOS);
      }
    }
  }

  testWidgets('toolbar reflows in a narrow desktop child at 2x',
      (tester) async {
    await _pump(tester, width: 960, scale: 2, childWidth: 360);
    final create = find.widgetWithText(FilledButton, 'New playlist');
    expect(create.hitTestable(), findsOneWidget);
    final button = tester.getRect(_surface(create));
    final search = tester.getRect(find.byType(TextField));
    expect(search.top, greaterThan(button.bottom));
    expect(button.right, lessThanOrEqualTo(search.right + 48));
    await _save(tester, 'toolbar-narrow-child-2x');
    expect(tester.takeException(), isNull);
  }, variant: _macOS);

  for (final empty in [false, true]) {
    testWidgets('mobile 959 preserves header FAB and empty action empty=$empty',
        (tester) async {
      await _pump(tester, width: 959, empty: empty);
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byTooltip('Create playlist'), findsOneWidget);
      expect(find.text('New playlist'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Create Playlist'),
          empty ? findsOneWidget : findsNothing);
      if (!empty) {
        final field = tester.widget<TextField>(find.byType(TextField));
        expect((field.decoration!.border! as OutlineInputBorder).borderRadius,
            BorderRadius.circular(12));
        final menu = tester.widget<PopupMenuButton<String>>(
            find.byType(PopupMenuButton<String>));
        expect(menu.style, isNull, reason: 'literal mobile native default');
      }
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('Blank playlist'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: _macOS);
  }

  for (final tooltip in ['New playlist', 'Sort playlists']) {
    testWidgets('toolbar native $tooltip focus hover held release contrast',
        (tester) async {
      await _pump(tester);
      final button = tooltip == 'New playlist'
          ? find.widgetWithText(FilledButton, tooltip)
          : find
              .ancestor(
                  of: find.byTooltip(tooltip),
                  matching: find.byType(IconButton))
              .first;
      final material = _surface(button);
      final rect = tester.getRect(material);
      final glyph = tooltip == 'New playlist'
          ? find.descendant(
              of: find.text(tooltip), matching: find.byType(RichText))
          : find.descendant(of: button, matching: find.byIcon(Icons.sort));
      final inkFinder =
          find.descendant(of: button, matching: find.byType(InkWell));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      Future<void> sample() async {
        final fg = tooltip == 'New playlist'
            ? tester.widget<RichText>(glyph).text.style!.color!
            : IconTheme.of(tester.element(glyph)).color!;
        final background =
            await _pixel(tester, rect.topLeft + const Offset(5, 5));
        expect(_contrast(fg, background), greaterThanOrEqualTo(4.5));
        expect(tester.getRect(material), rect);
      }

      await sample();
      await mouse.moveTo(rect.center);
      for (var i = 0; i < 32; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        if (tester
            .widget<InkWell>(inkFinder)
            .statesController!
            .value
            .contains(WidgetState.focused)) {
          break;
        }
      }
      await tester.pumpAndSettle();
      final ink = tester.widget<InkWell>(inkFinder);
      expect(ink.statesController!.value,
          containsAll([WidgetState.focused, WidgetState.hovered]));
      await sample();
      await mouse.down(rect.center);
      await tester.pump();
      expect(ink.statesController!.value, contains(WidgetState.pressed));
      for (final ms in [0, 50, 150, 300]) {
        await tester.pump(Duration(milliseconds: ms));
        await sample();
      }
      await _save(tester,
          '${tooltip == 'New playlist' ? 'new-playlist' : 'sort'}-focus-hover-held');
      await mouse.cancel();
      for (final ms in [0, 50, 150, 300]) {
        await tester.pump(Duration(milliseconds: ms));
        await sample();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
          find.text(
              tooltip == 'New playlist' ? 'Blank playlist' : 'Track count'),
          findsOneWidget);
      if (tooltip == 'New playlist') {
        await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      }
      await tester.pumpAndSettle();
      expect(tester.getRect(material), rect);
      expect(tester.takeException(), isNull);
    }, variant: _macOS);
  }

  testWidgets(
      'creation action inherited disabled presentation retains geometry',
      (tester) async {
    await _pump(tester);
    final original = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'New playlist'));
    final theme = Theme.of(
        tester.element(find.widgetWithText(FilledButton, 'New playlist')));
    final rect = tester
        .getRect(_surface(find.widgetWithText(FilledButton, 'New playlist')));
    // New playlist is always available in production. Probe the exact mounted
    // action style disabled, without inventing an unavailable screen state.
    await tester.pumpWidget(MaterialApp(
        theme: theme,
        home: Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: FilledButton.icon(
                    style: original.style,
                    onPressed: null,
                    icon: const Icon(Icons.add),
                    label: const Text('New playlist'))))));
    await tester.pumpAndSettle();
    final disabled = find.widgetWithText(FilledButton, 'New playlist');
    expect(tester.getSize(_surface(disabled)), rect.size);
    expect(tester.widget<FilledButton>(disabled).onPressed, isNull);
    final surface = tester.widget<Material>(_surface(disabled));
    expect(surface.color, theme.colorScheme.surface);
    expect((surface.shape! as RoundedRectangleBorder).side.color,
        theme.disabledColor);
    expect(tester.takeException(), isNull);
  }, variant: _macOS);

  for (final width in [960.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'real service search sort list grid and detail return paths $width ${scale}x',
          (tester) async {
        final http = await _pump(tester, width: width, scale: scale);
        await tester.enterText(find.byType(TextField), 'Night');
        await tester.pumpAndSettle();
        expect(http.requests.last.uri.queryParameters['q'], 'Night');
        expect(find.text('Glasshouse'), findsNothing);
        await tester.tap(find.byTooltip('Sort playlists'));
        await tester.pumpAndSettle();
        await _save(tester, 'sort-menu-${width.toInt()}-${scale.toInt()}x');
        await tester.tap(find.text('Track count'));
        await tester.pumpAndSettle();
        expect(http.requests.last.uri.queryParameters,
            containsPair('sort', 'track_count'));
        expect(http.requests.last.uri.queryParameters['order'], 'asc');
        expect(http.requests.last.uri.queryParameters['q'], 'Night');
        await tester.tap(find.byTooltip('Sort playlists'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Track count'));
        await tester.pumpAndSettle();
        expect(http.requests.last.uri.queryParameters['order'], 'desc');
        await tester.tap(find.byTooltip('List view'));
        await tester.pumpAndSettle();
        expect(find.byType(PlaylistListTile), findsOneWidget);
        await _save(tester, 'search-list-${width.toInt()}-${scale.toInt()}x');
        await tester.tap(find.byTooltip('Clear playlist search'));
        await tester.pumpAndSettle();
        expect(
            http.requests.last.uri.queryParameters.containsKey('q'), isFalse);
        expect(find.byType(PlaylistListTile), findsNWidgets(3));
        await tester.tap(find.byTooltip('Grid view'));
        await tester.pumpAndSettle();
        expect(find.byType(PlaylistCard), findsNWidgets(3));
        await tester.enterText(find.byType(TextField), 'missing');
        await tester.pumpAndSettle();
        expect(
            find.widgetWithText(FilledButton, 'New playlist'), findsOneWidget);
        expect(find.byType(FloatingActionButton), findsNothing);
        await tester.tap(find.byTooltip('Clear playlist search'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Night drive'));
        await tester.pumpAndSettle();
        expect(find.text('Playlist detail fixture'), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Night drive'), findsOneWidget);
        expect(
            find.widgetWithText(FilledButton, 'New playlist'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }, variant: _macOS);
    }
  }

  for (final width in [960.0, 1440.0]) {
    testWidgets('real creation validation save and import choice $width',
        (tester) async {
      final http = await _pump(tester, width: width, empty: true);
      await tester.tap(find.widgetWithText(FilledButton, 'New playlist'));
      await tester.pumpAndSettle();
      await _save(tester, 'create-${width.toInt()}-initial');
      await tester.tap(find.byKey(const ValueKey('playlist_creation_blank')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextFormField, 'Playlist name'));
      await tester.pumpAndSettle();
      await _save(tester, 'create-${width.toInt()}-focused');
      await tester.tap(find.byKey(const ValueKey('playlist_creation_submit')));
      await tester.pumpAndSettle();
      expect(find.text('Please enter a name'), findsOneWidget);
      expect(http.requests.where((c) => c.method == 'POST'), isEmpty);
      await _save(tester, 'create-${width.toInt()}-validation');
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Playlist name'), 'New rotation');
      await tester.tap(find.byKey(const ValueKey('playlist_creation_submit')));
      await tester.pumpAndSettle();
      final post = http.requests.singleWhere((c) => c.method == 'POST');
      expect(
          jsonDecode(post.body), {'name': 'New rotation', 'isPublic': false});
      expect(
          find.byKey(const ValueKey('playlist_creation_dialog')), findsNothing);
      expect(find.text('New rotation'), findsOneWidget);
      expect(find.text('Created playlist "New rotation"'), findsOneWidget);
      await _save(tester, 'create-${width.toInt()}-success');
      await tester.tap(find.widgetWithText(FilledButton, 'New playlist'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('playlist_creation_youtube')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextFormField, 'YouTube playlist URL'),
          findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'Max items'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('playlist_creation_submit')));
      await tester.pumpAndSettle();
      expect(find.text('Paste a YouTube playlist URL first.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: _macOS);
  }
}

Finder _surface(Finder button) {
  final inside = find.descendant(of: button, matching: find.byType(Material));
  return inside.evaluate().isNotEmpty
      ? inside.first
      : find.ancestor(of: button, matching: find.byType(Material)).first;
}

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x > y ? y : x) + .05);
}

Future<Color> _pixel(WidgetTester tester, Offset global) async {
  return (await tester.runAsync(() async {
    final render =
        _receipt.currentContext!.findRenderObject()! as RenderRepaintBoundary;
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

Future<void> _save(WidgetTester tester, String name) async {
  const output = String.fromEnvironment('HOTATE_PLAYLISTS_CAPTURE_DIR');
  if (output.isEmpty) return;
  await tester.runAsync(() async {
    final render =
        _receipt.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File('$output/$name.png').create(recursive: true);
    await File('$output/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

Future<_FixtureHttp> _pump(WidgetTester tester,
    {double width = 1440,
    double scale = 1,
    bool empty = false,
    double? childWidth}) async {
  expect(defaultTargetPlatform, TargetPlatform.macOS);
  await loadFlightFonts(tester);
  tester.view
    ..physicalSize = Size(width, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final http = _FixtureHttp(empty: empty);
  HttpOverrides.global = http;
  final playback = FakePlayback();
  addTearDown(playback.dispose);
  final router = GoRouter(initialLocation: '/playlists', routes: [
    ShellRoute(
      builder: (_, __, child) => ScaffoldWithNavBar(
          miniPlayer: const SizedBox.shrink(),
          child: childWidth == null
              ? child
              : Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: childWidth, child: child))),
      routes: [
        GoRoute(
            path: '/playlists', builder: (_, __) => const PlaylistsScreen()),
        GoRoute(
            path: '/playlists/:id',
            builder: (context, state) => Scaffold(
                appBar: AppBar(title: const Text('Playlist detail fixture')),
                body: Text('Playlist ${state.pathParameters['id']}'))),
        GoRoute(
            path: '/mixes',
            builder: (_, __) =>
                const Scaffold(body: Text('Saved mixes fixture'))),
      ],
    ),
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
            child: RepaintBoundary(key: _receipt, child: child!)),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  expect(http.requests.single.method, 'GET');
  expect(find.text(empty ? 'No playlists yet' : 'Night drive'), findsOneWidget);
  return http;
}

class _Call {
  _Call(this.method, this.uri);
  final String method;
  final Uri uri;
  String body = '';
}

// The registered HttpOverrides seam used by desktop_playlist_density_test:
// real ApiClient, PlaylistService, JSON decoding and dialog, no real sockets.
class _FixtureHttp extends HttpOverrides {
  _FixtureHttp({this.empty = false});
  final bool empty;
  final requests = <_Call>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Http(this);
}

Map<String, Object> _playlist(int id, String name, int tracks) => {
      'id': id,
      'name': name,
      'track_count': tracks,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    };

class _Http extends Fake implements HttpClient {
  _Http(this.fixture);
  final _FixtureHttp fixture;
  @override
  set idleTimeout(Duration value) {}
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    if (url.path != '/api/v1/playlists') {
      throw StateError('Unexpected $method $url');
    }
    final call = _Call(method, url);
    fixture.requests.add(call);
    return _Request(call, () {
      if (method == 'POST') {
        final body = jsonDecode(call.body) as Map<String, dynamic>;
        return _playlist(33, body['name'] as String, 0);
      }
      final playlists = fixture.empty
          ? <Map<String, Object>>[]
          : [
              _playlist(1, 'Night drive', 12),
              _playlist(
                  2,
                  'Quiet afternoon — live recordings and long-form sessions',
                  4),
              _playlist(3, 'Glasshouse', 28),
            ];
      final q = url.queryParameters['q']?.toLowerCase() ?? '';
      final visible = playlists
          .where((p) => (p['name'] as String).toLowerCase().contains(q))
          .toList();
      return {
        'playlists': visible,
        'total': visible.length,
        'limit': 50,
        'offset': 0
      };
    });
  }

  @override
  void close({bool force = false}) {}
}

class _Headers extends Fake implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  void forEach(void Function(String, List<String>) action) =>
      action('content-type', ['application/json']);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this.call, this.response);
  final _Call call;
  final Object Function() response;
  @override
  final headers = _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  set maxRedirects(int value) {}
  @override
  set persistentConnection(bool value) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    call.body = utf8.decode(await stream.expand((bytes) => bytes).toList());
  }

  @override
  Future<HttpClientResponse> close() async => _Response(response());
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(Object body) : bytes = utf8.encode(jsonEncode(body));
  final List<int> bytes;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream.value(bytes).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  HttpHeaders get headers => _Headers();
  @override
  int get statusCode => 200;
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => [];
  @override
  String get reasonPhrase => 'Controlled playlist fixture';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
