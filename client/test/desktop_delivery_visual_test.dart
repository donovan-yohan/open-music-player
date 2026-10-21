// Controlled visual fixtures only: no production backend/account or audio device.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
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

import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/core/storage/secure_storage.dart';
import 'package:open_music_player/features/connect/device_panel.dart';
import 'package:open_music_player/features/jam/jam_host_screen.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'connect_app_composition_test.dart' show NoSharedIntent;
import 'connect_auth_scope_test.dart' as support;
import 'connect_service_test.dart' show deviceJson;
import 'desktop_listening_transport_test.dart' show DesktopPlayback;
import 'device_presence_service_test.dart' show flush;
import 'jam_host_service_test.dart' show jamJson;

const _captureKey = ValueKey('delivery-root-capture');
final _output = Platform.environment['SOUNDQ_DELIVERY_CAPTURE_DIR'];
final _receipts = <Map<String, Object?>>[];
final _targetIssues = <Map<String, Object?>>[];
const _tracks = [
  {
    'id': 7,
    'title': 'Midnight Walk (controlled fixture)',
    'artist': 'Fixture Ensemble',
    'duration_ms': 240000
  },
  {
    'id': 8,
    'title': 'Open Horizon',
    'artist': 'Studio Fixture',
    'duration_ms': 198000
  },
  {
    'id': 9,
    'title': 'A Very Long Evening With An Equally Long Track Title',
    'artist': 'The Controlled Fixture Orchestra',
    'duration_ms': 301000
  },
  {
    'id': 10,
    'title': 'Glass Garden',
    'artist': 'Fixture Ensemble',
    'duration_ms': 180000
  },
  {
    'id': 11,
    'title': 'Quiet Motion',
    'artist': 'Studio Fixture',
    'duration_ms': 270000
  },
  {
    'id': 12,
    'title': 'Last Light',
    'artist': 'Fixture Ensemble',
    'duration_ms': 220000
  },
];

Future<void> _fonts(WidgetTester tester) async {
  final dir = Platform.environment['SOUNDQ_FLUTTER_FONTS']!;
  await tester.runAsync(() async {
    // Private visual SDK omits --use-test-fonts. Production theme is unchanged.
    for (final family in ['Roboto', '.SF Pro Text', '.SF Pro Display']) {
      final loader = FontLoader(family)
        ..addFont(File('$dir/Roboto-Regular.ttf')
            .readAsBytes()
            .then(ByteData.sublistView));
      await loader.load();
    }
    await (FontLoader('MaterialIcons')
          ..addFont(File('$dir/MaterialIcons-Regular.otf')
              .readAsBytes()
              .then(ByteData.sublistView)))
        .load();
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  // First frame installs route/overlay; second completes its transition.
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_captureKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$_output/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    _receipts.add(
        {'capture': file.path, 'width': image.width, 'height': image.height});
    image.dispose();
    await File('$_output/captures.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(_receipts));
  });
}

void _noErrors(WidgetTester tester) => expect(tester.takeException(), isNull);

Future<void> _target(WidgetTester tester, Finder finder) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 400));
  expect(finder.hitTestable(), findsOneWidget);
  final size = tester.getSize(finder);
  // Preserve the original QA target, but finish the route/capture matrix before
  // reporting its misses in the separate final audit assertion below.
  if (size.width < 44 || size.height < 40) {
    _targetIssues.add({
      'control': finder.toString(),
      'width': size.width,
      'height': size.height
    });
  }
  _receipts.add({
    'control': finder.toString(),
    'width': size.width,
    'height': size.height
  });
}

Future<void> _keyboardFocus(WidgetTester tester, Finder control) async {
  // Reach by actual Tab traversal; don't directly request the control's node.
  var reached = false;
  for (var i = 0; i < 60; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final nodeContext = FocusManager.instance.primaryFocus?.context;
    if (nodeContext == null) continue;
    var inside = control.evaluate().any((e) => identical(e, nodeContext));
    nodeContext.visitAncestorElements((e) {
      if (control.evaluate().any((c) => identical(c, e))) inside = true;
      return !inside;
    });
    if (inside) {
      reached = true;
      break;
    }
  }
  expect(reached, isTrue, reason: 'Tab must reach $control');
}

class _Playback extends DesktopPlayback {
  _Playback()
      : super(
            title: 'Midnight Walk (controlled fixture)',
            artist: 'Fixture Ensemble');
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
  @override
  bool get canSkipPrevious => true;
}

class _Scenario {
  String jamId = '11111111-1111-4111-8111-111111111111';
  bool failDevices = false;
  int hostBeats = 0;
  final paths = <String>[];
  Map<String, dynamic> jam({bool host = true}) =>
      {...jamJson(host: host), 'jamId': jamId};
  late final wire = support.Wire((o) {
    paths.add('${o.method} ${o.path}');
    if (o.path == '/auth/login') {
      return support.reply({
        'accessToken': 'controlled-fixture',
        'refreshToken': 'fixture-refresh'
      });
    }
    if (o.path == '/me/devices' && o.method == 'GET') {
      if (failDevices) {
        return support.reply({
          'error': {'code': 'UNAVAILABLE'}
        }, 503);
      }
      return support.reply({
        'devices': [
          {
            ...deviceJson(playback: {
              'sessionId': 'fixture-session',
              'queueItemId': 'fixture-occurrence',
              'track': {
                'trackId': 7,
                'title': _tracks[0]['title'],
                'artist': 'Fixture Ensemble'
              },
              'playing': true,
              'processingState': 'ready',
              'positionMs': 90000,
              'durationMs': 240000,
              'activeVoiceCount': 2,
            }),
            'label': 'Desktop · controlled fixture'
          },
          {
            ...deviceJson(),
            'deviceId': '44444444-4444-4444-8444-444444444444',
            'platform': 'android',
            'label': 'Phone · controlled fixture'
          },
        ],
        'serverTime': '2026-10-21T10:00:01Z'
      });
    }
    if (o.path.startsWith('/me/devices')) {
      return support.reply({
        'device': {
          ...deviceJson(),
          'deviceId': (o.data as Map?)?['deviceId'] ?? deviceJson()['deviceId'],
          'leaseExpiresAt': '2099-10-21T10:00:00Z'
        }
      }, o.method == 'POST' ? 201 : 200);
    }
    if (o.path == '/library') {
      return support.reply({'tracks': _tracks, 'total': _tracks.length});
    }
    if (o.path == '/jams') {
      jamId = o.data['jamId'] as String;
      return support.reply(jam(host: false), 201);
    }
    if (o.path.endsWith('/invites')) {
      return support.reply({
        'joinToken': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        'inviteExpiresAt': '2099-10-21T10:10:00Z'
      }, 201);
    }
    if (o.path.endsWith('/host')) {
      hostBeats++;
      return support.reply(jam(host: false));
    }
    if (o.path.startsWith('/jams/')) return support.reply(jam());
    throw StateError(
        'Unspecified controlled API fixture: ${o.method} ${o.path}');
  });
}

// Home currently constructs ApiClient directly, rather than reading app's
// injected client. Intercept its dart:io adapter so actual HomeService still
// parses literal JSON without any socket/backend/account/keychain access.
class _OfflineHttp extends HttpOverrides {
  final paths = <String>[];
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Http(paths);
}

class _Http extends Fake implements HttpClient {
  _Http(this.paths);
  final List<String> paths;
  @override
  set idleTimeout(Duration value) {}
  @override
  set connectionTimeout(Duration? value) {}
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    paths.add(url.path);
    final path = url.path.replaceFirst('/api/v1', '');
    final Object body;
    if (path == '/me/plays/recent') {
      body = {'tracks': _tracks.take(3).toList()};
    } else if (path == '/me/plays/top') {
      body = {'tracks': _tracks.skip(3).toList()};
    } else if (path == '/playlists') {
      body = {'playlists': []};
    } else {
      throw StateError('Blocked unexpected network: $method $url');
    }
    return _HttpRequest(body);
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

class _HttpRequest extends Fake implements HttpClientRequest {
  _HttpRequest(this.body);
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
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<HttpClientResponse> close() async => _HttpResponse(body);
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
}

class _HttpResponse extends Stream<List<int>> implements HttpClientResponse {
  _HttpResponse(Object body) : bytes = utf8.encode(jsonEncode(body));
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    TestWidgetsFlutterBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            (_) async => null);
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    HttpOverrides.global = null;
  });
  for (final size in [
    const Size(1024, 768),
    const Size(1024, 600),
    const Size(1440, 900),
    const Size(2560, 1440)
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'actual root routes ${size.width.toInt()}x${size.height.toInt()} ${scale}x real-font fixtures',
          (tester) async {
        await _fonts(tester);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final offline = _OfflineHttp();
        HttpOverrides.global = offline;
        SharedPreferences.setMockInitialValues({
          'app_settings': jsonEncode({'themeMode': 2})
        });
        final prefs = await SharedPreferences.getInstance();
        final scenario = _Scenario();
        final storage = SecureStorage(tokenStorage: support.MemoryTokens());
        final api = support.client(storage, scenario.wire);
        final auth = AuthState(
            authService: AuthService(
                api: api,
                storage: storage,
                biometricUnlockService: support.NoBiometrics()));
        final login = auth.login(
            email: 'fixture@example.test',
            password: 'dummy-visual-fixture-password');
        await flush(tester);
        expect(await login, isTrue);
        final playback = _Playback();
        final app = OpenMusicPlayerApp(
            apiClient: api,
            authState: auth,
            playbackState: playback,
            sharedIntentReceiver: NoSharedIntent());
        final suffix =
            '${size.width.toInt()}x${size.height.toInt()}-${scale.toInt()}x';
        app.router.go('/home');
        await tester.pumpWidget(ProviderScope(
            overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
            child: RepaintBoundary(key: _captureKey, child: app)));
        await flush(tester, const Duration(milliseconds: 500));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await flush(tester);
        expect(find.text('Your rotation'), findsOneWidget);
        expect(offline.paths, hasLength(3));
        if (size.width >= 1200 && scale == 2) {
          final paragraph = tester
              .renderObject<RenderParagraph>(find.text('Connected devices'));
          expect(paragraph.didExceedMaxLines, isFalse,
              reason: 'Wide navigation must retain enlarged labels');
        }
        for (final label in ['Pause', 'Next', 'Previous', 'Open queue']) {
          // Existing desktop transport uses 40px pointer controls; the new
          // Connect/Jam controls below retain the stricter target assertion.
          expect(find.byTooltip(label).hitTestable(), findsOneWidget);
        }
        await _capture(tester, 'home-$suffix');
        _noErrors(tester);
        // The 40px icon is not the rail's actual pointer activation box.
        final devices =
            find.byKey(const ValueKey('soundq_desktop_nav_focus_9'));
        final devicesHit = find
            .ancestor(
                of: devices,
                matching: find.byWidgetPredicate((w) => w is InkResponse))
            .first;
        await _target(tester, devicesHit);
        await tester.tap(devicesHit);
        await flush(tester, const Duration(milliseconds: 500));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)));
        await flush(tester);
        expect(find.byType(DevicePanel), findsOneWidget);
        expect(find.text('Desktop · controlled fixture'), findsOneWidget);
        await _capture(tester, 'devices-$suffix');
        await tester
            .ensureVisible(find.text('No listening metadata reported.'));
        await tester.pump();
        expect(find.text('No listening metadata reported.').hitTestable(),
            findsOneWidget);
        _noErrors(tester);
        app.router.pop();
        await flush(tester, const Duration(milliseconds: 500));
        expect(find.text('Your rotation'), findsOneWidget);
        final jam = find.byKey(const ValueKey('soundq_desktop_nav_focus_10'));
        await _target(
            tester,
            find
                .ancestor(
                    of: jam,
                    matching: find.byWidgetPredicate((w) => w is InkResponse))
                .first);
        await _keyboardFocus(
            tester,
            find
                .ancestor(
                    of: jam, matching: find.byType(FocusableActionDetector))
                .first);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await flush(tester, const Duration(milliseconds: 500));
        expect(find.byType(JamHostScreen), findsOneWidget);
        final choose = find
            .ancestor(
                of: find.text('Choose tracks'),
                matching: find.byWidgetPredicate((w) => w is OutlinedButton))
            .first;
        await _target(tester, choose);
        await _keyboardFocus(tester, choose);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await flush(tester, const Duration(milliseconds: 400));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await flush(tester);
        expect(find.byType(CheckboxListTile), findsWidgets);
        await _capture(tester, 'library-picker-$suffix');
        _noErrors(tester);
        final libraryScroll = find
            .descendant(
                of: find.descendant(
                    of: find.byType(AlertDialog),
                    matching: find.byType(ListView)),
                matching: find.byType(Scrollable))
            .first;
        await tester.scrollUntilVisible(find.text('Last Light'), 140,
            scrollable: libraryScroll);
        expect(find.text('Last Light').hitTestable(), findsOneWidget);
        tester.state<ScrollableState>(libraryScroll).position.jumpTo(0);
        await tester.pump();
        expect(
            find.byType(CheckboxListTile).first.hitTestable(), findsOneWidget);
        await tester.tap(find.byType(CheckboxListTile).first);
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, 'Use 1 track'));
        await flush(tester, const Duration(milliseconds: 400));
        final start = find.widgetWithText(FilledButton, 'Start Jam');
        await _target(tester, start);
        await tester.tap(start);
        await flush(tester);
        expect(find.text('Hosting Jam'), findsOneWidget);
        await _capture(tester, 'jam-pending-$suffix');
        _noErrors(tester);
        final origin = find.widgetWithText(TextButton, 'Set guest web origin');
        await _target(tester, origin);
        await tester.tap(origin);
        await flush(tester, const Duration(milliseconds: 400));
        final coveredPolls =
            scenario.paths.where((p) => p.startsWith('GET /jams/')).length;
        await flush(tester, const Duration(seconds: 4));
        expect(scenario.paths.where((p) => p.startsWith('GET /jams/')).length,
            coveredPolls,
            reason: 'actual origin dialog covers host panel polling');
        await tester.enterText(
            find.byType(TextField), 'https://guests.example');
        await _capture(tester, 'origin-dialog-$suffix');
        _noErrors(tester);
        await _target(tester, find.widgetWithText(FilledButton, 'Save'));
        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await flush(tester, const Duration(milliseconds: 400));
        final invite = find
            .ancestor(
                of: find.text('Create invitation'),
                matching: find.byWidgetPredicate((w) => w is FilledButton))
            .first;
        await _target(tester, invite);
        await tester.tap(invite);
        await flush(tester);
        expect(find.byType(QrImageView), findsOneWidget);
        await _capture(tester, 'jam-qr-$suffix');
        final qrData = tester
            .widget<JamHostScreen>(find.byType(JamHostScreen))
            .controller
            .invitationLink
            .toString();
        await tester.runAsync(
            () => File('$_output/jam-qr-$suffix.txt').writeAsString(qrData));
        await tester.runAsync(() async {
          final qr = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const ValueKey('jam-invitation-qr')));
          final image = await qr.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$_output/qr-only-$suffix.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        _noErrors(tester);
        final approve = find.widgetWithText(FilledButton, 'Approve');
        if (approve.evaluate().isEmpty) {
          await tester.scrollUntilVisible(approve, 180,
              scrollable: find
                  .descendant(
                      of: find
                          .descendant(
                              of: find.byType(JamHostScreen),
                              matching: find.byType(ListView))
                          .first,
                      matching: find.byType(Scrollable))
                  .first);
        }
        await _target(tester, approve);
        await _keyboardFocus(tester, approve);
        await _target(tester, find.widgetWithText(TextButton, 'Decline'));
        await _capture(tester, 'jam-requests-scrolled-$suffix');
        _noErrors(tester);
        // No approval invocation: fake hardware isn't canonical queue evidence.
        await tester.tap(find.widgetWithText(TextButton, 'End Jam'));
        await flush(tester, const Duration(milliseconds: 400));
        await _capture(tester, 'end-dialog-$suffix');
        _noErrors(tester);
        await _target(tester, find.widgetWithText(TextButton, 'Keep hosting'));
        await _target(tester, find.widgetWithText(FilledButton, 'End Jam'));
        await tester.tap(find.widgetWithText(TextButton, 'Keep hosting'));
        await flush(tester, const Duration(milliseconds: 400));
        final host =
            tester.widget<JamHostScreen>(find.byType(JamHostScreen)).controller;
        final beats = scenario.hostBeats;
        app.router.pop();
        await flush(tester, const Duration(seconds: 5));
        expect(host.isHosting, isTrue);
        expect(scenario.hostBeats, greaterThan(beats));
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        final minimized = scenario.hostBeats;
        await flush(tester, const Duration(seconds: 5));
        expect(host.isHosting, isTrue);
        expect(scenario.hostBeats, greaterThan(minimized));
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpWidget(const SizedBox());
        await flush(tester);
        app.router.dispose();
        auth.dispose();
        await playback.source.close();
        playback.disposeFake();
        debugDefaultTargetPlatformOverride = null;
        _noErrors(tester);
      },
          skip: _output == null ||
              Platform.environment['SOUNDQ_FLUTTER_FONTS'] == null);
    }
  }
  test('new desktop controls retain original 44x40 QA target audit', () async {
    if (_output == null) return;
    await File('$_output/target-issues.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(_targetIssues));
    expect(_targetIssues, isEmpty,
        reason:
            'Measured targets below the original QA baseline; route/capture checks still completed. See target-issues.json.');
  });
}
