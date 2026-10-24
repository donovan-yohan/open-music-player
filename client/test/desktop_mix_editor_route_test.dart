import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/commands/app_command.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/commands/command_widgets.dart';
import 'package:provider/provider.dart';

import 'desktop_mix_editor_draft_test.dart' show planJson;
import 'support/mock_dio_client.dart';

void main() {
  testWidgets(
      'real root route lists and opens without shell or audio; every go exit is guarded',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final calls = <String>[];
    var server = planJson();
    final api = mockQueueApiClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.method == 'PUT') {
        final payload = jsonDecode(request.body);
        server = {...server, 'version': 4, 'clips': payload['clips']};
      }
      return http.Response(
          jsonEncode(request.url.path.endsWith('/mix-plans')
              ? {
                  'data': [server]
                }
              : server),
          200);
    });
    final router = createRouter(_Auth());
    addTearDown(router.dispose);
    router.go('/mixes');
    final playback = _Playback();
    final commands = CommandRegistry(
        playbackState: playback, platform: TargetPlatform.macOS);
    addTearDown(commands.dispose);
    await tester.pumpWidget(Provider<ApiClient>.value(
        value: api,
        child: MaterialApp.router(
            routerConfig: router,
            builder: (context, child) => CommandHost(
                registry: commands,
                contextFor: (_) => CommandContext(playbackState: playback),
                child: child!))));
    await tester.pumpAndSettle();
    expect(find.text('Saved mixes'), findsOneWidget);
    await tester.tap(find.text('Night drive'));
    await tester.pumpAndSettle();
    expect(find.byType(ScaffoldWithNavBar), findsNothing);
    expect(find.text('Version 3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('mix-field-placement')), '500');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    router.go('/mixes');
    await tester.pumpAndSettle();
    expect(find.text('Save mix changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mix-clip-a')), findsOneWidget);
    expect(find.text('Unsaved changes'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();
    expect(find.text('Save mix changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mix-clip-a')), findsOneWidget);
    router.go('/mixes/another-plan');
    await tester.pumpAndSettle();
    expect(find.text('Save mix changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mix-clip-a')), findsOneWidget);
    expect(calls.any((call) => call.endsWith('/another-plan')), isFalse);
    router.go('/mixes');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save').last);
    await tester.pumpAndSettle();
    expect(find.text('Saved mixes'), findsOneWidget);
    expect(server['clips'][0]['timelineStartMs'], 500);
    expect(calls.where((r) => !r.startsWith('GET') && !r.startsWith('PUT')),
        isEmpty);
    expect(playback.transportCalls, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  test('saved mixes are authenticated root routes, independent of DJ gate', () {
    final router = createRouter(_Auth());
    addTearDown(router.dispose);
    final routes = router.configuration.routes.whereType<GoRoute>();
    expect(routes.where((route) => route.path == '/mixes'), hasLength(1));
    final editor = routes.singleWhere((route) => route.path == '/mixes/:id');
    expect(editor.redirect, isNull);
    expect(editor.onExit, isNotNull);
  });
}

class _Auth extends Fake implements AuthState {
  @override
  bool get hasLocalSession => true;
  @override
  bool get isBiometricLocked => false;
  @override
  bool get isAuthenticated => true;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}

class _Playback extends Fake implements PlaybackState {
  int transportCalls = 0;
  @override
  int? get currentIndex => null;
  @override
  bool get hasTrack => false;
  @override
  bool get isPlaying => false;
  @override
  Duration get duration => Duration.zero;
  @override
  LoopMode get loopMode => LoopMode.off;
  @override
  bool get canSkipNext => false;
  @override
  bool get hasPreviousInPlayOrder => false;
  @override
  Future<void> togglePlayPause() async {
    transportCalls++;
  }

  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}
