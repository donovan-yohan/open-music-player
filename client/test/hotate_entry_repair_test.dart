import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/features/search/search_screen.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/screens/queue_screen.dart';

import 'desktop_listening_transport_test.dart' show DesktopPlayback;
import 'flight_theme_typography_test.dart' show loadFlightFonts;

final _macOS = TargetPlatformVariant.only(TargetPlatform.macOS);
final _receipt = GlobalKey();

void main() {
  test(
      'accepted playback header/FC2/list/timeline and Home content bytes stay frozen',
      () {
    final queue = File('lib/screens/queue_screen.dart').readAsStringSync();
    expect(
        sha256
            .convert(utf8.encode(queue
                .substring(queue.indexOf('  Widget _buildPlaybackQueueView('))))
            .toString(),
        'f174be8ad15ee7191be07448edb8915f993acf2bf8f37cfae19eb4cd6803fe88');
    final home = File('lib/features/home/home_screen.dart').readAsStringSync();
    final unchangedHome = home.substring(
            0, home.indexOf('/// The single, terminal empty state')) +
        home.substring(home.indexOf('class _HomeContent'));
    expect(sha256.convert(utf8.encode(unchangedHome)).toString(),
        'eb1ebb31d2ad6eceeb4ab363968d2c15a78bea7cb388ef97f12e04b074f7491f');
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() => HttpOverrides.global = null);

  for (final fonts in [false, true]) {
    for (final width in [960.0, 1440.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
            'Imports empty heading and source entry $width ${scale}x plex=$fonts',
            (tester) async {
          final app =
              await _pump(tester, width: width, scale: scale, fonts: fonts);
          final screen = find.byType(QueueScreen);
          expect(find.descendant(of: screen, matching: find.text('Imports')),
              findsOneWidget);
          expect(find.text('No imports pending'), findsOneWidget);
          expect(find.text('Your queue is empty'), findsNothing);
          expect(find.text('Add songs to start playing'), findsNothing);
          expect(find.byKey(const ValueKey('queue_header_menu')), findsNothing);
          expect(app.queue.isEmpty, isTrue);
          expect(app.playback.queue, isNotEmpty);
          expect(find.text(app.playback.title), findsOneWidget,
              reason:
                  'actual persistent dock retains canonical track identity');
          expect(find.byKey(const ValueKey('soundq_desktop_transport')),
              findsOneWidget);
          final header = find.byKey(const ValueKey('import_queue_header'));
          final rect = tester.getRect(header);
          final body = tester.getRect(screen);
          expect(rect.left, body.left);
          expect(rect.right, body.right);
          final container = tester.widget<Container>(header);
          final decoration = container.decoration! as BoxDecoration;
          expect(decoration.border!.bottom.style, BorderStyle.solid);
          expect(decoration.borderRadius, isNull);
          expect(decoration.boxShadow, isNull);
          _expectFullText(tester,
              find.descendant(of: screen, matching: find.text('Imports')));
          final action = find.widgetWithText(FilledButton, 'Find a source');
          expect(action.hitTestable(), findsOneWidget);
          _expectFullText(tester, find.text('Find a source'));
          await _save(
              tester, 'imports-${width.toInt()}-${scale.toInt()}x', fonts);
          final routes = <String>[];
          app.router.routeInformationProvider.addListener(() =>
              routes.add(app.router.routeInformationProvider.value.uri.path));
          if (scale == 2) {
            await _focus(tester, action);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          } else {
            await tester.tap(action);
          }
          await tester.pumpAndSettle();
          expect(app.router.routeInformationProvider.value.uri.path, '/search');
          expect(routes.where((p) => p == '/search'), hasLength(1));
          expect(find.byType(SearchScreen), findsOneWidget);
          expect(find.byType(TextField), findsOneWidget);
          expect(app.playback.calls, isEmpty);
          expect(app.http.calls.where((c) => c.method != 'GET'), isEmpty);
          expect(tester.takeException(), isNull);
          await _unmount(tester);
        }, variant: _macOS);
      }
    }
  }

  for (final fonts in [false, true]) {
    for (final width in [960.0, 1440.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
            'empty Home useful Discover action $width ${scale}x plex=$fonts',
            (tester) async {
          final app = await _pump(tester,
              width: width, scale: scale, fonts: fonts, route: '/home');
          final action = find.widgetWithText(FilledButton, 'Discover music');
          expect(action.hitTestable(), findsOneWidget);
          expect(
              find.descendant(
                  of: find.byType(HomeScreen),
                  matching: find.byType(FilledButton)),
              findsOneWidget);
          expect(
              find.text('Find music to add to your library'), findsOneWidget);
          _expectFullText(tester, find.text('Discover music'));
          await _save(
              tester, 'home-empty-${width.toInt()}-${scale.toInt()}x', fonts);
          final routes = <String>[];
          app.router.routeInformationProvider.addListener(() =>
              routes.add(app.router.routeInformationProvider.value.uri.path));
          if (scale == 2) {
            await _focus(tester, action);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          } else {
            await tester.tap(action);
          }
          await tester.pumpAndSettle();
          expect(app.router.routeInformationProvider.value.uri.path, '/search');
          expect(routes.where((p) => p == '/search'), hasLength(1));
          expect(find.byType(SearchScreen), findsOneWidget);
          await tester.enterText(find.byType(TextField), 'fixture source');
          await tester.testTextInput.receiveAction(TextInputAction.search);
          await tester.pumpAndSettle();
          expect(find.text('Fixture source recording'), findsOneWidget);
          final request = app.http.calls
              .singleWhere((c) => c.uri.path == '/api/v1/discovery/search');
          expect(request.uri.queryParameters['q'], 'fixture source');
          expect(request.uri.queryParameters['providers'],
              'youtube,soundcloud,musicbrainz');
          final add = find.descendant(
              of: find.byType(SearchScreen),
              matching: find.widgetWithText(FilledButton, 'Add'));
          expect(add.hitTestable(), findsOneWidget,
              reason:
                  'downloadable external source has the existing import action, not empty-library search');
          expect(tester.widget<FilledButton>(add).onPressed, isNotNull);
          expect(app.playback.calls, isEmpty);
          expect(app.http.calls.where((c) => c.method != 'GET'), isEmpty);
          await _save(tester,
              'home-discover-result-${width.toInt()}-${scale.toInt()}x', fonts);
          expect(tester.takeException(), isNull);
          await _unmount(tester);
        }, variant: _macOS);
      }
    }
  }

  for (final populated in [false, true]) {
    testWidgets(
        'Home sparse/populated keeps accepted sections populated=$populated',
        (tester) async {
      final http = _FixtureHttp()
        ..sparse = true
        ..populated = populated;
      await _pump(tester, route: '/home', http: http);
      expect(find.text('Quiet rotation'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Discover music'), findsNothing);
      expect(find.text('Find music to add to your library'), findsNothing);
      expect(find.text('Recently played'),
          populated ? findsOneWidget : findsNothing);
      expect(find.byKey(const ValueKey('soundq_desktop_home')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    }, variant: _macOS);
  }

  for (final width in [390.0, 959.0]) {
    testWidgets(
        'mobile Imports truthful copy preserves original orange header $width',
        (tester) async {
      final app = await _pump(tester, width: width);
      final header = tester
          .widget<Container>(find.byKey(const ValueKey('import_queue_header')));
      expect(header.color, AppTheme.orange);
      expect(header.decoration, isNull);
      expect(find.text('No imports pending'), findsOneWidget);
      expect(find.text('Imports'), findsOneWidget);
      expect(find.byKey(const ValueKey('queue_header_menu')), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Find a source'));
      await tester.pumpAndSettle();
      expect(app.router.routeInformationProvider.value.uri.path, '/search');
      expect(find.byType(SearchScreen), findsOneWidget);
      expect(app.playback.calls, isEmpty);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    }, variant: _macOS);
  }

  testWidgets(
      'Imports header survives real provider loading error and single Retry',
      (tester) async {
    final http = _FixtureHttp()
      ..queueGate = Completer<void>()
      ..queueError = true;
    final app = await _pump(tester, http: http, settle: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(app.queue.isLoading, isTrue);
    expect(find.byKey(const ValueKey('import_queue_header')), findsOneWidget);
    expect(find.text('Loading imports'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue_header_menu')), findsNothing);
    expect(http.queueReads, 1);
    http.queueGate!.complete();
    await tester.pumpAndSettle();
    expect(app.queue.error, isNotNull);
    expect(find.byKey(const ValueKey('import_queue_header')), findsOneWidget);
    expect(find.text('Could not load imports'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue_header_menu')), findsNothing);
    http.queueError = false;
    http.queueGate = Completer<void>();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Retry'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(app.queue.isLoading, isTrue);
    expect(http.queueReads, 2);
    expect(find.text('Loading imports'), findsOneWidget);
    http.queueGate!.complete();
    await tester.pumpAndSettle();
    expect(app.queue.error, isNull);
    expect(find.text('No imports pending'), findsOneWidget);
    expect(http.queueReads, 2);
    expect(app.playback.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  }, variant: _macOS);

  testWidgets('Imports job status and real clear menu remain import-owned',
      (tester) async {
    final http = _FixtureHttp()..jobs = true;
    final app = await _pump(tester, http: http);
    expect(
        find.descendant(
            of: find.byType(QueueScreen), matching: find.text('Imports')),
        findsOneWidget);
    expect(find.text('Fixture source recording'), findsOneWidget);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.byKey(const ValueKey('queue_view_switch')), findsNothing);
    expect(find.text('No imports pending'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('queue_header_menu')));
    await tester.pumpAndSettle();
    expect(find.text('Clear queue'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(http.calls.where((c) => c.method != 'GET'), isEmpty);
    expect(app.playback.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  }, variant: _macOS);
}

void _expectFullText(WidgetTester tester, Finder text) {
  final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(of: text, matching: find.byType(RichText)));
  final full = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler)
    ..layout();
  expect(paragraph.size.width + .01, greaterThanOrEqualTo(full.width));
  expect(paragraph.size.height + .01, greaterThanOrEqualTo(full.height));
  full.dispose();
}

Future<void> _focus(WidgetTester tester, Finder button) async {
  for (var i = 0; i < 40; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final ink = tester.widget<InkWell>(
        find.descendant(of: button, matching: find.byType(InkWell)));
    if (ink.statesController!.value.contains(WidgetState.focused)) return;
  }
  fail('Native Tab traversal did not reach action');
}

Future<void> _save(WidgetTester tester, String name, bool fonts) async {
  const directory = String.fromEnvironment('HOTATE_ENTRY_CAPTURE_DIR');
  if (directory.isEmpty || !fonts) return;
  await tester.runAsync(() async {
    final boundary =
        _receipt.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$directory/$name.png').create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

class _App {
  _App(this.router, this.queue, this.playback, this.http);
  final GoRouter router;
  final QueueProvider queue;
  final _Playback playback;
  final _FixtureHttp http;
}

Future<_App> _pump(WidgetTester tester,
    {double width = 960,
    double scale = 1,
    bool fonts = false,
    String route = '/queue/imports',
    _FixtureHttp? http,
    bool settle = true}) async {
  if (fonts) await loadFlightFonts(tester);
  expect(defaultTargetPlatform, TargetPlatform.macOS);
  tester.view
    ..physicalSize = Size(width, 932)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  http ??= _FixtureHttp();
  HttpOverrides.global = http;
  final api = ApiClient();
  final queue = QueueProvider(api);
  final playback = _Playback(empty: route == '/home' && !http.populated);
  final commands = CommandRegistry(playbackState: playback);
  final auth = _Auth();
  tester.binding.platformDispatcher.defaultRouteNameTestValue = route;
  addTearDown(
      () => tester.binding.platformDispatcher.defaultRouteNameTestValue = '/');
  final router = createRouter(auth);
  expect(router.routeInformationProvider.value.uri.path, route);
  addTearDown(router.dispose);
  addTearDown(queue.dispose);
  addTearDown(playback.disposeFake);
  addTearDown(commands.dispose);
  await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ListenableProvider<AuthState>.value(value: auth),
        ChangeNotifierProvider<QueueProvider>.value(value: queue),
        ListenableProvider<PlaybackState>.value(value: playback),
        Provider<CommandRegistry>.value(value: commands),
      ],
      child: MaterialApp.router(
          theme: AppTheme.darkTheme,
          routerConfig: router,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: RepaintBoundary(key: _receipt, child: child!)))));
  if (settle) await tester.pumpAndSettle();
  return _App(router, queue, playback, http);
}

class _Auth extends Fake implements AuthState {
  @override
  int get sessionRevision => 0;
  @override
  bool get isLoading => false;
  @override
  bool get hasLocalSession => true;
  @override
  bool get isAuthenticated => true;
  @override
  bool get isBiometricLocked => false;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _Playback extends DesktopPlayback {
  _Playback({this.empty = false})
      : super(title: 'Night Ferry', artist: 'Fixture ensemble');
  final bool empty;
  @override
  PlaybackSnapshot get snapshot =>
      empty ? PlaybackSnapshot.empty() : super.snapshot;
  @override
  bool get hasTrack => !empty;
  @override
  List<MediaItem> get queue => empty ? [] : super.queue;
  @override
  final timelineModel = TimelineModel();
  @override
  int get timelinePositionMs => cursor.inMilliseconds;
  @override
  BeatSnapMode get transitionSnapMode => BeatSnapMode.downbeat;
  @override
  QueueInsertMode get swipeQueueMode => QueueInsertMode.addToQueue;
}

class _Call {
  _Call(this.method, this.uri);
  final String method;
  final Uri uri;
}

// Real ApiClient/JSON/service/provider/production router composition; synthetic
// responses only, no real accounts, sockets, download worker or audio service.
class _FixtureHttp extends HttpOverrides {
  final calls = <_Call>[];
  bool queueError = false;
  bool jobs = false;
  bool sparse = false;
  bool populated = false;
  Completer<void>? queueGate;
  int get queueReads =>
      calls.where((c) => c.uri.path == '/api/v1/queue').length;
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Http(this);
  Object response(Uri uri) {
    if (uri.path == '/api/v1/queue') {
      return {
        'items': jobs
            ? [
                {
                  'queueItemId': 'source-job-1',
                  'kind': 'source',
                  'playbackState': 'queued',
                  'sourceCandidate': _candidate,
                  'downloadJobId': 'job-1',
                  'canPlay': false,
                  'canRetry': false,
                }
              ]
            : []
      };
    }
    if (uri.path == '/api/v1/me/plays/recent' ||
        uri.path == '/api/v1/me/plays/top') {
      return {
        'tracks': populated
            ? [
                {'id': 39, 'title': 'Night Ferry', 'artist': 'Fixture ensemble'}
              ]
            : []
      };
    }
    if (uri.path == '/api/v1/playlists') {
      return {
        'playlists': sparse
            ? [
                {'id': 1, 'name': 'Quiet rotation', 'trackCount': 0}
              ]
            : []
      };
    }
    if (uri.path == '/api/v1/discovery/search') {
      return {
        'query': uri.queryParameters['q'],
        'results': [_candidate],
        'selectionSessionId': '11111111-1111-1111-1111-111111111111',
        'selectionExpiresAt': '2099-01-01T00:00:00Z',
        'providers': [
          {'provider': 'youtube', 'status': 'ok', 'resultCount': 1}
        ]
      };
    }
    throw StateError('Unexpected fixture path $uri');
  }
}

const _candidate = {
  'candidateId': 'youtube:fixture',
  'provider': 'youtube',
  'sourceId': 'fixture',
  'sourceUrl': 'https://youtube.test/watch?v=fixture',
  'title': 'Fixture source recording',
  'uploader': 'Fixture artist',
  'durationMs': 120000,
  'downloadable': true,
  'playable': false
};

class _Http extends Fake implements HttpClient {
  _Http(this.fixture);
  final _FixtureHttp fixture;
  @override
  set idleTimeout(Duration value) {}
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) async {
    fixture.calls.add(_Call(method, uri));
    return _Request(fixture, uri);
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
  _Request(this.fixture, this.uri);
  final _FixtureHttp fixture;
  @override
  final Uri uri;
  @override
  final headers = _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  set maxRedirects(int value) {}
  @override
  set persistentConnection(bool value) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async =>
      stream.drain<void>();
  @override
  Future<HttpClientResponse> close() async {
    if (uri.path == '/api/v1/queue') await fixture.queueGate?.future;
    final error = uri.path == '/api/v1/queue' && fixture.queueError;
    return _Response(
        error ? {'message': 'Synthetic queue failure'} : fixture.response(uri),
        error ? 500 : 200);
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(Object body, this.statusCode)
      : bytes = utf8.encode(jsonEncode(body));
  final List<int> bytes;
  @override
  final int statusCode;
  @override
  StreamSubscription<List<int>> listen(void Function(List<int>)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      Stream.value(bytes).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  HttpHeaders get headers => _Headers();
  @override
  bool get isRedirect => false;
  @override
  List<RedirectInfo> get redirects => [];
  @override
  String get reasonPhrase => 'Controlled entry fixture';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
