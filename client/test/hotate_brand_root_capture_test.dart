// Production app + createRouter, no sockets/accounts/audio. Synthetic sparse Home.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/app.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/auth/auth_service.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_app_composition_test.dart' show NoSharedIntent;
import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'desktop_listening_transport_test.dart' show DesktopPlayback;
import 'device_presence_service_test.dart' show flush;
import 'flight_shell_capture_test.dart' show loadFlightFonts;

const _output = String.fromEnvironment('HOTATE_BRAND_CAPTURE_DIR');

class _Playback extends DesktopPlayback {
  _Playback() : super(title: 'Northbound', artist: 'The night shift');
  late final source = BehaviorSubject<PlaybackSnapshot>.seeded(snapshot);
  @override
  ValueStream<PlaybackSnapshot> get snapshotStream => source;
  @override
  int get sessionGeneration => 1;
  @override
  Future<void> applyAudioDefaults(AudioPlaybackDefaults defaults) async {}
  @override
  void setEndOfQueueMode(dynamic mode) {}
  @override
  void setSwipeQueueMode(dynamic mode) {}
  @override
  void setPreserveManualQueue(bool value) {}
}

void main() {
  for (final size in [
    const Size(960, 900),
    const Size(1440, 900),
    const Size(960, 440),
    const Size(959, 900)
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('actual root masthead ${size.width}x${size.height} ${scale}x',
          (tester) async {
        await tester.runAsync(loadFlightFonts);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final previousHttp = HttpOverrides.current;
        HttpOverrides.global = _OfflineHttp();
        addTearDown(() => HttpOverrides.global = previousHttp);
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(
                    'plugins.it_nomads.com/flutter_secure_storage'),
                null));
        SharedPreferences.setMockInitialValues({
          'app_settings': jsonEncode({'themeMode': 2})
        });
        final preferences = await SharedPreferences.getInstance();
        final storage = SecureStorage(tokenStorage: support.MemoryTokens());
        final wire = support.Wire((o) {
          if (o.path == '/auth/login') {
            return support
                .reply({'accessToken': 'fixture', 'refreshToken': 'fixture-r'});
          }
          if (o.path.startsWith('/me/devices')) {
            return support.reply({
              'device': {
                ...deviceJson(),
                'deviceId':
                    (o.data as Map?)?['deviceId'] ?? deviceJson()['deviceId']
              }
            }, o.method == 'POST' ? 201 : 200);
          }
          throw StateError('Unexpected injected API request: ${o.path}');
        });
        final api = support.client(storage, wire);
        final auth = AuthState(
            authService: AuthService(
                api: api,
                storage: storage,
                biometricUnlockService: support.NoBiometrics()));
        final login = auth.login(
            email: 'brand@example.test', password: 'controlled-fixture');
        await flush(tester);
        expect(await login, isTrue);
        final playback = _Playback();
        final app = OpenMusicPlayerApp(
            apiClient: api,
            authState: auth,
            playbackState: playback,
            sharedIntentReceiver: NoSharedIntent());
        app.router.go('/home');
        final boundary = GlobalKey();
        await tester.pumpWidget(ProviderScope(overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences)
        ], child: RepaintBoundary(key: boundary, child: app)));
        await flush(tester, const Duration(milliseconds: 500));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await flush(tester);
        expect(app.router.routeInformationProvider.value.uri.path, '/home');
        final rail =
            find.byKey(const ValueKey('soundq_desktop_rail_container'));
        if (size.width >= 960) {
          await tester.runAsync(() => precacheImage(
              const AssetImage('assets/brand/soundq-logo.png'),
              tester.element(rail)));
          await flush(tester);
          final masthead =
              find.byKey(const ValueKey('soundq_desktop_masthead'));
          final rect = tester.getRect(masthead);
          expect(rect.height,
              scale == 1 || size.width < 1200 ? 64 : greaterThan(64));
          expect(
              tester.getSize(rail).width,
              size.width < 1200
                  ? 80
                  : scale == 1
                      ? 224
                      : greaterThan(224));
          final first =
              find.byKey(const ValueKey('soundq_desktop_nav_focus_0'));
          expect(tester.getRect(first).top, rect.bottom);
          expect(tester.getRect(first).height,
              scale == 1 ? 48 : greaterThanOrEqualTo(48));
          final image =
              find.descendant(of: masthead, matching: find.byType(Image));
          expect(tester.getRect(image).height, 40);
          if (size.width >= 1200) {
            final text =
                find.descendant(of: masthead, matching: find.text('SoundQ'));
            expect(text, findsOneWidget);
            final paragraph = tester.renderObject<RenderParagraph>(text);
            final painter = TextPainter(
                text: paragraph.text,
                textDirection: paragraph.textDirection,
                textScaler: paragraph.textScaler)
              ..layout();
            expect(tester.getSize(text).width,
                greaterThanOrEqualTo(painter.width - .1));
            expect(tester.getRect(text).right,
                lessThanOrEqualTo(tester.getRect(rail).right - 16));
            painter.dispose();
          }
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await flush(tester);
          expect(FocusManager.instance.primaryFocus?.debugLabel,
              'Sound Q destination 0');
          if (size.width < 1200) expect(find.text('Home'), findsNWidgets(2));
        } else {
          expect(rail, findsNothing);
          expect(find.byType(NavigationBar), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        final emblem = size.width >= 960
            ? tester.getRect(find.descendant(
                of: find.byKey(const ValueKey('soundq_desktop_masthead')),
                matching: find.byType(Image)))
            : Rect.zero;
        await tester.runAsync(() async {
          final image = await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
          final bytes =
              await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          if (size.width >= 960) {
            // Orange/ivory identity has to be in the raster, not only in DOM.
            var orange = 0, ivory = 0;
            for (var y = emblem.top.ceil(); y < emblem.bottom.floor(); y++) {
              for (var x = emblem.left.ceil(); x < emblem.right.floor(); x++) {
                final i = (y * image.width + x) * 4;
                final r = bytes!.getUint8(i),
                    g = bytes.getUint8(i + 1),
                    b = bytes.getUint8(i + 2);
                if (r > 180 && g < 150 && b < 80) orange++;
                if (r > 180 && g > 180 && b > 150) ivory++;
              }
            }
            expect(orange, greaterThan(100));
            expect(ivory, greaterThan(35));
          }
          if (_output.isNotEmpty) {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File(
                '$_output/root-${size.width.toInt()}-${size.height.toInt()}-${scale.toInt()}x.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(png!.buffer.asUint8List());
          }
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        await flush(tester);
        app.router.dispose();
        auth.dispose();
        await playback.source.close();
        playback.disposeFake();
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }
  }
}

class _OfflineHttp extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Http();
}

class _Http extends Fake implements HttpClient {
  @override
  set idleTimeout(Duration value) {}
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final path = url.path.replaceFirst('/api/v1', '');
    if (path == '/me/plays/recent' || path == '/me/plays/top') {
      return _Request({'tracks': []});
    }
    if (path == '/playlists') return _Request({'playlists': []});
    throw StateError('Blocked unexpected network: $method $url');
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
  _Request(this.body);
  final Object body;
  @override
  final headers = _Headers();
  @override
  set followRedirects(bool value) {}
  @override
  set maxRedirects(int value) {}
  @override
  set persistentConnection(bool value) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  Future<HttpClientResponse> close() async => _Response(body);
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
  String get reasonPhrase => 'Controlled fixture';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
