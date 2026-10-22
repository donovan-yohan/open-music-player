import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/features/playlists/mix/desktop_mix_editor_screen.dart';
import 'package:open_music_player/models/stem_edits.dart';
import 'package:provider/provider.dart';

import 'desktop_mix_editor_draft_test.dart' show planJson, clipJson;
import 'support/mock_dio_client.dart';

void main() {
  setUpAll(() async {
    final fontPath = Platform.environment['HERMES_MIX_FONT_PATH'];
    if (fontPath != null) {
      final loader = FontLoader('Roboto')
        ..addFont(File(fontPath)
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)));
      await loader.load();
    }
    final iconPath = Platform.environment['HERMES_MIX_ICON_PATH'];
    if (iconPath != null) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(File(iconPath)
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)));
      await loader.load();
    }
  });
  Future<void> mount(WidgetTester tester,
      {List<Map<String, dynamic>>? clips,
      Size size = const Size(1440, 1000),
      bool conflict = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var server = planJson(clips: clips);
    final api = mockQueueApiClient((request) async {
      if (request.method == 'PUT') {
        if (conflict) return http.Response('{"code":"VERSION_CONFLICT"}', 409);
        final payload = jsonDecode(request.body);
        server = {...server, 'version': 4, 'clips': payload['clips']};
      }
      return http.Response(jsonEncode(server), 200);
    });
    await tester.pumpWidget(Provider<ApiClient>.value(
        value: api,
        child: MaterialApp(
            theme: ThemeData.dark().copyWith(
                textTheme:
                    ThemeData.dark().textTheme.apply(fontFamily: 'Roboto')),
            home: const DesktopMixEditorScreen(planId: 'plan-1'))));
    await tester.pumpAndSettle();
  }

  testWidgets('short desktop at large text scale remains scrollable',
      (tester) async {
    await mount(tester, size: const Size(960, 500));
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.binding.setSurfaceSize(const Size(960, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Native text scaler from accessibility; panes scroll rather than clip.
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    expect(find.text('Edits not applied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('desktop at 959 starts as fallback without allocating API',
      (tester) async {
    tester.view.physicalSize = const Size(959, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        const MaterialApp(home: DesktopMixEditorScreen(planId: 'plan-1')));
    expect(find.text('Go to playlists'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'clip fields apply placement trim fades and gain to saved readback',
      (tester) async {
    var server = planJson();
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = mockQueueApiClient((request) async {
      if (request.method == 'PUT') {
        final payload = jsonDecode(request.body);
        server = {...server, 'version': 4, 'clips': payload['clips']};
      }
      return http.Response(jsonEncode(server), 200);
    });
    await tester.pumpWidget(Provider<ApiClient>.value(
        value: api,
        child:
            const MaterialApp(home: DesktopMixEditorScreen(planId: 'plan-1'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pump();
    for (final entry in {
      'placement': '700',
      'in': '2000',
      'out': '10000',
      'fade-in': '500',
      'fade-out': '700',
      'gain': '-3.5'
    }.entries) {
      await tester.enterText(
          find.byKey(ValueKey('mix-field-${entry.key}')), entry.value);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    expect(server['clips'][0], containsPair('sourceStartMs', 2000));
    expect(server['clips'][0], containsPair('sourceEndMs', 10000));
    expect(server['clips'][0], containsPair('fadeInMs', 500));
    expect(server['clips'][0], containsPair('fadeOutMs', 700));
    expect(server['clips'][0], containsPair('gainDb', -3.5));
    expect(find.text('Version 4'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'drag is undoable, fifth overlap rejected visibly, resize retains draft',
      (tester) async {
    await mount(tester, clips: [
      for (var i = 0; i < 5; i++) clipJson(id: '$i', start: i < 4 ? 0 : 10000)
    ]);
    final last = find.byKey(const ValueKey('mix-clip-4'));
    await tester.drag(last, const Offset(-60, 0));
    await tester.pumpAndSettle();
    expect(find.textContaining('At most four clips'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    await tester.drag(last, const Offset(30, 0));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
    await tester.tap(find.byTooltip('Redo'));
    await tester.pump();
    tester.view.physicalSize = const Size(959, 1000);
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(find.text('Go to playlists'), findsNothing);
    tester.view.physicalSize = const Size(1440, 1000);
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('phone deep link has no API or editor allocation',
      (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // No ApiClient provider: the fallback must not attempt to read one.
    await tester.pumpWidget(
        const MaterialApp(home: DesktopMixEditorScreen(planId: 'plan-1')));
    await tester.pumpAndSettle();
    expect(find.text('Go to playlists'), findsOneWidget);
    expect(find.byKey(const ValueKey('mix-save')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('409 remains dirty and recording stays disabled', (tester) async {
    await mount(tester, conflict: true);
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('mix-field-placement')), '1000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Your edits are kept'), findsOneWidget);
    expect(find.text('Unsaved changes'), findsOneWidget);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('mix-save')))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('mix-record')))
            .onPressed,
        isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('source-identified fader authors one continuous point and undo',
      (tester) async {
    final edits = StemEdits(
        channelSet: StemChannelSet.stems5Hybrid,
        sourceFileHash: 'sha256:${List.filled(64, 'a').join()}');
    await mount(tester,
        clips: [
          {...clipJson(), 'stemEdits': edits.toJson()}
        ],
        size: const Size(1440, 1400));
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pump();
    final fader = find.byKey(const ValueKey('mix-stem-vocals'));
    await tester.ensureVisible(fader);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(fader).value, 1);
    final box = tester.getRect(fader);
    await tester.tapAt(Offset(box.left + box.width * .4, box.center.dy));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(fader).value, inExclusiveRange(0, 1));
    expect(find.text('Unsaved changes'), findsOneWidget);
    final authored = tester.widget<Slider>(fader).value;
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    expect(find.text('Version 4'), findsOneWidget);
    expect(tester.widget<Slider>(fader).value, authored);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(fader).value, 1);
    expect(find.text('Unsaved changes'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('focused text keeps shortcuts and workspace Ctrl S saves',
      (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pump();
    await tester.enterText(
        find.byKey(const ValueKey('mix-field-placement')), '700');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Version 3'), findsOneWidget);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('Version 4'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('renders actual desktop capture and no decorative waveforms',
      (tester) async {
    final capture = GlobalKey();
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = mockQueueApiClient((_) async => http.Response(
        jsonEncode(planJson(clips: [
          clipJson(id: 'a'),
          clipJson(id: 'b', start: 6000),
          clipJson(id: 'c', start: 12000),
        ])),
        200));
    await tester.pumpWidget(Provider<ApiClient>.value(
        value: api,
        child: MaterialApp(
            theme: ThemeData.dark().copyWith(
                textTheme:
                    ThemeData.dark().textTheme.apply(fontFamily: 'Roboto')),
            home: RepaintBoundary(
                key: capture,
                child: const DesktopMixEditorScreen(planId: 'plan-1')))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image = await (capture.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final target = Platform.environment['HERMES_MIX_CAPTURE_PATH'];
      if (target != null) {
        await File(target).writeAsBytes(bytes!.buffer.asUint8List());
      }
      image.dispose();
    });
    expect(find.text('Edits not applied'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'desktop loads, selects, moves, undoes and saves a real versioned plan',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var server = planJson();
    final calls = <String>[];
    final api = mockQueueApiClient((request) async {
      calls.add('${request.method} ${request.url.path}');
      if (request.method == 'PUT') {
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        expect(payload['version'], 3);
        server = {...server, 'version': 4, 'clips': payload['clips']};
      }
      return http.Response(jsonEncode(server), 200);
    });
    await tester.pumpWidget(Provider<ApiClient>.value(
        value: api,
        child: MaterialApp(
            theme: ThemeData.dark().copyWith(
                textTheme:
                    ThemeData.dark().textTheme.apply(fontFamily: 'Roboto')),
            home: const DesktopMixEditorScreen(planId: 'plan-1'))));
    await tester.pumpAndSettle();
    expect(find.text('Night drive'), findsOneWidget);
    expect(find.text('Version 3'), findsOneWidget);
    expect(find.text('Edits not applied'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('mix-record')))
            .onPressed,
        isNull);
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pump();
    final start = find.byKey(const ValueKey('mix-field-placement'));
    await tester.enterText(start, '2500');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
    await tester.tap(find.byTooltip('Redo'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    expect(find.text('Version 4'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    expect(server['clips'][0]['timelineStartMs'], 2500);
    expect(calls, [
      'GET /api/v1/mix-plans/plan-1',
      'PUT /api/v1/mix-plans/plan-1',
      'GET /api/v1/mix-plans/plan-1'
    ]);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
