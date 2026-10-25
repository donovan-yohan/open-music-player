import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:open_music_player/features/playlists/add_tracks_sheet.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/features/playlists/playlist_detail_screen.dart';

import 'flight_theme_typography_test.dart' show loadFlightFonts;
import 'song_row_presentation_test.dart' show FakePlayback;

final _capture = GlobalKey();
final _macOS = TargetPlatformVariant.only(TargetPlatform.macOS);
const _longName =
    'Night ferry — quiet recordings for the long journey home across the harbour';

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() => HttpOverrides.global = null);

  testWidgets(
      'desktop detail replaces decorative hero with a flat ruled header',
      (tester) async {
    await _pump(tester);
    final detail = find.byType(PlaylistDetailScreen);
    expect(find.descendant(of: detail, matching: find.byType(FlexibleSpaceBar)),
        findsNothing);
    expect(
        tester.widget<SliverAppBar>(find.byType(SliverAppBar)).pinned, isTrue);
    final gradients = tester
        .widgetList<DecoratedBox>(
            find.descendant(of: detail, matching: find.byType(DecoratedBox)))
        .where((box) =>
            box.decoration is BoxDecoration &&
            (box.decoration as BoxDecoration).gradient != null);
    expect(gradients, isEmpty);
    final title = _paragraph(tester, find.text('Night ferry'));
    expect(title.text.style?.shadows, isNull);
    final rule = find.byKey(const ValueKey('playlist_detail_header'));
    expect(rule, findsOneWidget);
    final decoration =
        tester.widget<DecoratedBox>(rule).decoration as BoxDecoration;
    expect(decoration.borderRadius, isNull);
    expect((decoration.border! as Border).bottom.width, 1);
    expect(tester.getRect(rule).left,
        tester.getRect(find.byType(CustomScrollView)).left);
    expect(tester.getRect(rule).right,
        tester.getRect(find.byType(CustomScrollView)).right);
    expect(tester.getRect(find.byType(AppBar)).height, lessThan(100));
    expect(tester.takeException(), isNull);
  }, variant: _macOS);

  for (final width in [960.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final empty in [true, false]) {
        testWidgets(
            'routed detail intrinsic title and actions $width ${scale}x empty=$empty',
            (tester) async {
          await _pump(tester,
              width: width, scale: scale, empty: empty, name: _longName);
          expect(find.text(_longName), findsOneWidget);
          final semantics = tester.ensureSemantics();
          try {
            await tester.pump();
            expect(find.bySemanticsLabel(_longName), findsOneWidget);
          } finally {
            semantics.dispose();
          }
          _expectTextFits(tester, find.text(_longName));
          final title = _paragraph(tester, find.text(_longName));
          expect(title.textScaler.scale(20), scale * 20);
          expect(title.maxLines, isNull);
          final header = find.byKey(const ValueKey('playlist_detail_header'));
          final bounds = tester.getRect(header);
          expect(
              bounds.left, tester.getRect(find.byType(CustomScrollView)).left);
          expect(bounds.right, width);
          expect(tester.getRect(find.text(_longName)).left, bounds.left + 16);
          expect(find.text(empty ? '0 tracks • 0m' : '2 tracks • 6m'),
              findsOneWidget);
          final play = find.widgetWithText(FilledButton, 'Play');
          final shuffle = find.widgetWithText(OutlinedButton, 'Shuffle');
          expect(tester.widget<FilledButton>(play).onPressed,
              empty ? isNull : isNotNull);
          expect(tester.widget<OutlinedButton>(shuffle).onPressed,
              empty ? isNull : isNotNull);
          for (final control in [
            play,
            shuffle,
            find.byKey(const ValueKey('playlist_add_tracks_action')),
            find.byTooltip('Edit mode'),
            find.byType(PopupMenuButton<String>),
            if (!empty) find.byKey(const ValueKey('playlist_download_all')),
          ]) {
            final rect = tester.getRect(_surface(control));
            expect(rect.height, greaterThanOrEqualTo(40));
            expect(rect.left, greaterThanOrEqualTo(bounds.left));
            expect(rect.right, lessThanOrEqualTo(width));
            expect(rect.bottom, lessThanOrEqualTo(932));
          }
          _expectTextFits(tester, find.text('Play'));
          _expectTextFits(tester, find.text('Shuffle'));
          if (!empty) _expectTextFits(tester, find.text('Download all'));
          await _expectRulePixels(tester, bounds);
          await _save(tester,
              'detail-${width.toInt()}-${scale.toInt()}x-${empty ? 'empty' : 'populated'}');
          expect(tester.takeException(), isNull);
        }, variant: _macOS);
      }
    }
  }

  testWidgets(
      'desktop playback actions reflow inside a narrow routed pane at 2x',
      (tester) async {
    await _pump(tester, scale: 2, empty: false, childWidth: 280);
    expect(tester.takeException(), isNull);
    for (final label in ['Play', 'Shuffle', 'Download all']) {
      _expectTextFits(tester, find.text(label));
    }
    final play =
        tester.getRect(_surface(find.widgetWithText(FilledButton, 'Play')));
    final shuffle = tester
        .getRect(_surface(find.widgetWithText(OutlinedButton, 'Shuffle')));
    expect(shuffle.top, greaterThan(play.bottom));
  }, variant: _macOS);

  for (final width in [960.0, 1440.0]) {
    testWidgets('native menu edit save and library add requests $width at 2x',
        (tester) async {
      final http = await _pump(tester, width: width, scale: 2);
      final more = find.byType(PopupMenuButton<String>);
      await _tabTo(tester, more);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      for (final label in ['Select tracks', 'Edit details', 'Delete']) {
        expect(find.text(label), findsOneWidget);
        _expectTextFits(tester, find.text(label));
      }
      await tester.tap(find.text('Edit details'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Playlist'), findsOneWidget);
      await tester.enterText(
          find.widgetWithText(TextFormField, 'Name'), 'Harbour lights');
      final save = find.widgetWithText(FilledButton, 'Save');
      await _tabTo(tester, save);
      expect(save.hitTestable(), findsOneWidget);
      _expectTextFits(tester, find.text('Save'));
      expect(tester.getRect(save).bottom, lessThan(932));
      await _save(tester, 'detail-edit-${width.toInt()}-2x');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final put = http.requests.singleWhere((call) => call.method == 'PUT');
      expect(put.uri.path, '/api/v1/playlists/7');
      expect(jsonDecode(put.body), {
        'name': 'Harbour lights',
        'description': 'Field recordings and late-night sessions',
        'coverUrl': '',
        'isPublic': false,
      });
      expect(find.text('Harbour lights'), findsOneWidget);
      await tester
          .tap(find.byKey(const ValueKey('playlist_add_tracks_action')));
      await tester.pumpAndSettle();
      expect(find.byKey(addTracksSheetKey), findsOneWidget);
      final library = http.requests
          .singleWhere((call) => call.uri.path == '/api/v1/library');
      expect(library.method, 'GET');
      expect(library.uri.queryParameters, containsPair('limit', '20'));
      await tester.tap(find.byKey(addTracksRowKey(103)));
      await tester.pumpAndSettle();
      final add = find.byKey(addTracksConfirmKey);
      await _tabTo(tester, add);
      expect(add.hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final post = http.requests.singleWhere((call) => call.method == 'POST');
      expect(post.uri.path, '/api/v1/playlists/7/tracks');
      expect(jsonDecode(post.body), {
        'trackIds': [103]
      });
      expect(
          http.requests.where((call) =>
              call.uri.path == '/api/v1/playlists/7' && call.method == 'GET'),
          hasLength(2));
      expect(find.text('1 track • 3m'), findsOneWidget);
      expect(find.text('Harbour recording 103'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: _macOS);
  }

  testWidgets(
      'desktop play shuffle downloads edit selection and pinned scroll retain owners',
      (tester) async {
    final http = await _pump(tester, scale: 2, empty: false);
    final context = tester.element(find.byType(PlaylistDetailScreen));
    final playback = context.read<PlaybackState>() as _Playback;
    final downloads = context.read<DownloadState>() as _Downloads;
    await tester.tap(find.widgetWithText(FilledButton, 'Play'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Shuffle'));
    await tester.pumpAndSettle();
    expect(playback.requests.first, ['101', '102']);
    expect(playback.requests.last, unorderedEquals(['101', '102']));
    expect(
        playback.contexts.every((c) =>
            c?.id == '7' &&
            c?.label == 'Night ferry' &&
            c?.kind == PlaybackContextKind.playlist),
        isTrue);
    await tester.tap(find.byKey(const ValueKey('playlist_download_all')));
    await tester.pumpAndSettle();
    expect(downloads.requests, [
      [101, 102]
    ]);
    await tester.tap(find.byKey(const ValueKey('mix_toggle')));
    await tester.pumpAndSettle();
    expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Shuffle'))
            .onPressed,
        isNull);
    final mixPost = http.requests.last;
    expect('${mixPost.method} ${mixPost.uri.path}',
        'POST /api/v1/playlists/7/auto-mix');
    expect(jsonDecode(mixPost.body), <String, dynamic>{});
    final reorder = find.byKey(const ValueKey('mix_reorder_button'));
    expect(tester.getRect(_surface(reorder)).height, greaterThanOrEqualTo(40));
    await tester.tap(reorder);
    await tester.pumpAndSettle();
    expect(http.requests.last.uri.path, '/api/v1/playlists/7/smart-reorder');
    expect(jsonDecode(http.requests.last.body), {'regeneratePlan': true});
    // An order-only response retires the held blended plan, as before.
    expect(find.byKey(const ValueKey('mix_reorder_button')), findsNothing);
    expect(
        find.byKey(const ValueKey('harmonic_discovery_action')).hitTestable(),
        findsOneWidget);
    await tester.tap(find.byTooltip('Edit mode'));
    await tester.pumpAndSettle();
    expect(find.byType(SliverReorderableList), findsOneWidget);
    await tester.tap(find.byTooltip('Done editing'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Select tracks'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Cancel selection'), findsOneWidget);
    expect(find.byType(Checkbox), findsNWidgets(2));
    await tester.tap(find.byTooltip('Cancel selection'));
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(find
        .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable))
        .first);
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('playlist_add_tracks_action')).hitTestable(),
        findsOneWidget);
    expect(
        tester.widget<SliverAppBar>(find.byType(SliverAppBar)).pinned, isTrue);
    expect(http.requests, hasLength(3),
        reason: 'only load, blend and smart reorder dispatch HTTP');
    expect(tester.takeException(), isNull);
  }, variant: _macOS);

  testWidgets('959 preserves literal mobile flexible hero layout',
      (tester) async {
    await _pump(tester, width: 959);
    final appBar = tester.widget<SliverAppBar>(find.byType(SliverAppBar));
    expect(appBar.expandedHeight, 200);
    expect(appBar.pinned, isTrue);
    expect(find.byType(FlexibleSpaceBar), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist_detail_header')), findsNothing);
    final title = _paragraph(tester, find.text('Night ferry'));
    expect(title.text.style!.shadows!.single.blurRadius, 4);
    final wash = tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((box) => box.decoration)
        .whereType<BoxDecoration>()
        .where((decoration) => decoration.gradient != null)
        .single;
    final gradient = wash.gradient! as LinearGradient;
    expect(gradient.colors.first,
        AppTheme.darkTheme.colorScheme.primary.withValues(alpha: .6));
    expect(find.byIcon(Icons.queue_music), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: _macOS);
}

Future<void> _tabTo(WidgetTester tester, Finder target) async {
  bool focused() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    return target.evaluate().any((element) {
      var found = identical(context, element);
      context.visitAncestorElements((ancestor) {
        if (identical(ancestor, element)) found = true;
        return !found;
      });
      return found;
    });
  }

  for (var i = 0; i < 60 && !focused(); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
  }
  expect(focused(), isTrue,
      reason: 'native keyboard focus reaches the actual action');
}

Finder _surface(Finder control) {
  final inside = find.descendant(of: control, matching: find.byType(Material));
  return inside.evaluate().isNotEmpty
      ? inside.first
      : find.ancestor(of: control, matching: find.byType(Material)).first;
}

void _expectTextFits(WidgetTester tester, Finder text) {
  final paragraph = _paragraph(tester, text);
  expect(paragraph.didExceedMaxLines, isFalse);
  final painter = TextPainter(
      text: paragraph.text,
      textDirection: paragraph.textDirection,
      textScaler: paragraph.textScaler,
      maxLines: paragraph.maxLines)
    ..layout(maxWidth: paragraph.size.width);
  expect(paragraph.size.height + .01, greaterThanOrEqualTo(painter.height));
  final boxes = paragraph.getBoxesForSelection(TextSelection(
      baseOffset: 0, extentOffset: paragraph.text.toPlainText().length));
  for (final box in boxes) {
    expect(box.left, greaterThanOrEqualTo(-.01));
    expect(box.right, lessThanOrEqualTo(paragraph.size.width + .01));
    expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + .01));
  }
  painter.dispose();
}

Future<void> _expectRulePixels(WidgetTester tester, Rect rect) async {
  final colors =
      Theme.of(tester.element(find.byType(PlaylistDetailScreen))).colorScheme;
  await tester.runAsync(() async {
    final render =
        _capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    Color pixel(double x, double y) {
      final i = (y.floor() * image.width + x.floor()) * 4;
      return Color.fromARGB(bytes.getUint8(i + 3), bytes.getUint8(i),
          bytes.getUint8(i + 1), bytes.getUint8(i + 2));
    }

    for (final x in [
      rect.left,
      rect.left + 16,
      rect.center.dx,
      rect.right - 1
    ]) {
      expect(pixel(x, rect.bottom - 1), colors.outline);
      if (x > rect.left && x < rect.right - 1) {
        expect(pixel(x, rect.bottom - 2), colors.surface);
      }
    }
    image.dispose();
  });
}

RenderParagraph _paragraph(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)));

Future<_FixtureHttp> _pump(WidgetTester tester,
    {double width = 960,
    double scale = 1,
    bool empty = true,
    String name = 'Night ferry',
    double? childWidth}) async {
  expect(defaultTargetPlatform, TargetPlatform.macOS);
  await loadFlightFonts(tester);
  tester.view
    ..physicalSize = Size(width, 932)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final http = _FixtureHttp(empty: empty, name: name);
  HttpOverrides.global = http;
  final playback = _Playback();
  final downloads = _Downloads();
  addTearDown(playback.dispose);
  addTearDown(downloads.dispose);
  SharedPreferences.setMockInitialValues({
    'app_settings': jsonEncode({'djModeEnabled': true}),
  });
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(initialLocation: '/playlists/7', routes: [
    ShellRoute(
      builder: (_, __, child) => ScaffoldWithNavBar(
          miniPlayer: const SizedBox.shrink(),
          child: childWidth == null
              ? child
              : Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(width: childWidth, child: child))),
      routes: [
        GoRoute(path: '/playlists', builder: (_, __) => const Scaffold()),
        GoRoute(
            path: '/playlists/:id',
            builder: (_, state) => PlaylistDetailScreen(
                playlistId: int.parse(state.pathParameters['id']!))),
      ],
    ),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(riverpod.ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MultiProvider(
        providers: [
          ListenableProvider<PlaybackState>.value(value: playback),
          ChangeNotifierProvider<DownloadState>.value(value: downloads),
        ],
        child: MaterialApp.router(
          theme: AppTheme.darkTheme,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: SoundQDesktopTheme(
                child: RepaintBoundary(key: _capture, child: child!)),
          ),
        ),
      )));
  await tester.pumpAndSettle();
  expect(router.routeInformationProvider.value.uri.path, '/playlists/7');
  expect(http.requests.map((c) => '${c.method} ${c.uri.path}'),
      ['GET /api/v1/playlists/7']);
  return http;
}

Future<void> _save(WidgetTester tester, String name) async {
  const output = String.fromEnvironment('HOTATE_DETAIL_CAPTURE_DIR');
  if (output.isEmpty) return;
  await tester.runAsync(() async {
    final render =
        _capture.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await render.toImage();
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    await File('$output/$name.png').create(recursive: true);
    await File('$output/$name.png').writeAsBytes(bytes.buffer.asUint8List());
    image.dispose();
  });
}

class _Playback extends FakePlayback {
  final requests = <List<String>>[];
  final contexts = <PlaybackContext?>[];
  @override
  Future<void> playQueue(List<Map<String, dynamic>> tracks,
      {int startIndex = 0, PlaybackContext? context}) async {
    requests.add([for (final track in tracks) track['id'].toString()]);
    contexts.add(context);
  }
}

class _Downloads extends ChangeNotifier implements DownloadState {
  final requests = <List<int>>[];
  @override
  Set<int> get downloadedTrackIds => {};
  @override
  List<DownloadedTrack> get downloads => [];
  @override
  bool isDownloading(int id) => false;
  @override
  Future<void> downloadTracks(Iterable<Track> tracks) async {
    requests.add(tracks.map((track) => track.id).toList());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Call {
  _Call(this.method, this.uri);
  final String method;
  final Uri uri;
  String body = '';
}

// Controlled transport only: actual route, PlaylistService, ApiClient and JSON
// decoder are production. This is widget evidence, not backend/native proof.
class _FixtureHttp extends HttpOverrides {
  _FixtureHttp({required this.empty, required this.name});
  final bool empty;
  String name;
  final requests = <_Call>[];
  final ids = <int>[];
  Map<String, Object> get playlist => {
        'id': 7,
        'name': name,
        'description': 'Field recordings and late-night sessions',
        'track_count': ids.length,
        'tracks': [for (final id in ids) track(id)],
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      };
  Map<String, Object> track(int id) => {
        'id': id,
        'identity_hash': 'fixture-$id',
        'title': 'Harbour recording $id',
        'artist': 'Field ensemble',
        'duration_ms': 200000,
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
      };
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    if (!empty && ids.isEmpty) ids.addAll([101, 102]);
    return _Http(this);
  }

  Object respond(_Call call) {
    if (call.method == 'GET' && call.uri.path == '/api/v1/playlists/7') {
      return playlist;
    }
    if (call.method == 'PUT' && call.uri.path == '/api/v1/playlists/7') {
      name = (jsonDecode(call.body) as Map<String, dynamic>)['name'] as String;
      return playlist;
    }
    if (call.method == 'GET' && call.uri.path == '/api/v1/library') {
      return {
        'tracks': [track(103)],
        'total': 1,
        'limit': 20,
        'offset': 0
      };
    }
    if (call.method == 'POST' &&
        call.uri.path == '/api/v1/playlists/7/tracks') {
      final added = List<int>.from(jsonDecode(call.body)['trackIds'] as List);
      ids.addAll(added);
      return {'added': added, 'skipped': <int>[], 'playlist': playlist};
    }
    if (call.method == 'POST' &&
        call.uri.path == '/api/v1/playlists/7/auto-mix') {
      return {'transitions': <Object>[]};
    }
    if (call.method == 'POST' &&
        call.uri.path == '/api/v1/playlists/7/smart-reorder') {
      return {
        'order': ids.reversed.toList(),
        'editedSeamsKept': 0,
        'seamsRegenerated': 0
      };
    }
    throw StateError('Unexpected ${call.method} ${call.uri}');
  }
}

class _Http extends Fake implements HttpClient {
  _Http(this.fixture);
  final _FixtureHttp fixture;
  @override
  set idleTimeout(Duration value) {}
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final call = _Call(method, url);
    fixture.requests.add(call);
    return _Request(call, () => fixture.respond(call));
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
  String get reasonPhrase => 'Controlled detail fixture';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
