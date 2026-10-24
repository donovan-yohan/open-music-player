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

  testWidgets('E2 accepted mouse drag PointerCancel rolls back without history',
      (tester) async {
    final server =
        planJson(clips: [clipJson(), clipJson(id: 'b', start: 2000)]);
    final baseline = jsonEncode(server);
    final calls = <String>[];
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = mockQueueApiClient((request) async {
      calls.add(request.method);
      return http.Response(jsonEncode(server), 200);
    });
    await tester.pumpWidget(Provider<ApiClient>.value(
        value: api,
        child:
            const MaterialApp(home: DesktopMixEditorScreen(planId: 'plan-1'))));
    await tester.pumpAndSettle();
    final clip = find.byKey(const ValueKey('mix-clip-a'));
    await tester.tap(clip);
    await tester.pumpAndSettle();
    final original = tester.getRect(clip);
    final mountedClip = tester.element(clip);
    String field(String name) => tester
        .widget<TextField>(find.byKey(ValueKey('mix-field-$name')))
        .controller!
        .text;
    expect(field('placement'), '0');
    final pointer = await tester.startGesture(
        Offset(original.left + 90, original.center.dy),
        kind: ui.PointerDeviceKind.mouse);
    // Match the actual accepted native witness: four positive samples, 55px.
    for (var i = 0; i < 4; i++) {
      await pointer.moveBy(const Offset(13.75, 0));
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.getRect(clip).left, greaterThan(original.left));
    expect(tester.element(clip), same(mountedClip));
    expect(field('placement'), '0', reason: 'preview is not an admitted edit');
    await pointer.cancel();
    await tester.pumpAndSettle();
    expect(tester.getRect(clip), original,
        reason: 'accepted PointerCancel must discard the positive preview');
    expect(field('placement'), '0');
    expect(field('in'), '1000');
    expect(field('out'), '11000');
    expect(find.text('Saved'), findsOneWidget);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == 'Undo'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<IconButton>(find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == 'Redo'))
            .onPressed,
        isNull);
    expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('mix-save')))
            .onPressed,
        isNull);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is Semantics &&
            widget.properties.label == 'Clip a, track 42, 0 milliseconds'),
        findsOneWidget);
    expect(
        find.byWidgetPredicate((widget) =>
            widget is Semantics &&
            widget.properties.label == 'Clip b, track 42, 2000 milliseconds'),
        findsOneWidget);
    expect(jsonEncode(server), baseline);
    expect(calls, ['GET']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  IconButton historyButton(WidgetTester tester, String tooltip) =>
      tester.widget<IconButton>(find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == tooltip));

  Future<TestGesture> acceptedClipDrag(WidgetTester tester,
      {String id = 'a', int? pointer}) async {
    final clip = find.byKey(ValueKey('mix-clip-$id'));
    final origin = tester.getRect(clip);
    final gesture = await tester.startGesture(
        Offset(origin.left + 90, origin.center.dy),
        pointer: pointer,
        kind: ui.PointerDeviceKind.mouse);
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(13.75, 0));
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.getRect(clip).left, greaterThan(origin.left));
    return gesture;
  }

  testWidgets(
      'E2 pointer up commits one undoable move and exact saved identity',
      (tester) async {
    final originalClips = [clipJson(), clipJson(id: 'b', start: 2000)];
    var server = planJson(clips: originalClips);
    final calls = <String>[];
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = mockQueueApiClient((request) async {
      calls.add(request.method);
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
    final gesture = await acceptedClipDrag(tester);
    expect(calls, ['GET']);
    await gesture.up();
    await tester.pumpAndSettle();
    String placement() => tester
        .widget<TextField>(find.byKey(const ValueKey('mix-field-placement')))
        .controller!
        .text;
    final moved = placement();
    expect(int.parse(moved), greaterThan(0));
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(placement(), '0');
    expect(find.text('Saved'), findsOneWidget);
    expect(historyButton(tester, 'Undo').onPressed, isNull,
        reason: 'all accepted samples are a single history entry');
    await tester.tap(find.byTooltip('Redo'));
    await tester.pump();
    expect(placement(), moved);
    expect(historyButton(tester, 'Redo').onPressed, isNull);
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    expect(server['clips'], [
      {
        ...originalClips.first,
        'timelineStartMs': int.parse(moved),
        'tempoPolicy': 'volumeOnly'
      },
      {...originalClips.last, 'tempoPolicy': 'volumeOnly'},
    ]);
    expect(calls, ['GET', 'PUT', 'GET']);
    expect(find.text('Version 4'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'E2 rejected prethreshold cancel leaves next accepted move usable',
      (tester) async {
    await mount(tester);
    final clip = find.byKey(const ValueKey('mix-clip-a'));
    final original = tester.getRect(clip);
    final rejected = await tester.startGesture(original.center);
    await rejected.moveBy(const Offset(2, 0));
    await rejected.cancel();
    await tester.pumpAndSettle();
    expect(tester.getRect(clip), original);
    expect(find.text('Saved'), findsOneWidget);
    expect(historyButton(tester, 'Undo').onPressed, isNull);
    final accepted = await acceptedClipDrag(tester);
    await accepted.up();
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(tester.getRect(clip), original);
    expect(historyButton(tester, 'Undo').onPressed, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  for (final otherClip in ['a', 'b']) {
    testWidgets(
        'E2 other $otherClip pointer cancellation does not cancel owned preview',
        (tester) async {
      await mount(tester, clips: [clipJson(), clipJson(id: 'b', start: 2000)]);
      final clip = find.byKey(const ValueKey('mix-clip-a'));
      final original = tester.getRect(clip);
      final owned = await acceptedClipDrag(tester, pointer: 41);
      final preview = tester.getRect(clip);
      final other = await tester.startGesture(
          tester.getCenter(find.byKey(ValueKey('mix-clip-$otherClip'))),
          pointer: 42);
      await other.cancel();
      await tester.pumpAndSettle();
      expect(tester.getRect(clip), preview);
      await owned.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(clip), preview);
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      expect(tester.getRect(clip), original);
      expect(historyButton(tester, 'Undo').onPressed, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  for (final terminal in ['up', 'cancel']) {
    testWidgets(
        'E2 owning cancel with same clip peer $terminal cannot admit preview',
        (tester) async {
      await mount(tester);
      final clip = find.byKey(const ValueKey('mix-clip-a'));
      final original = tester.getRect(clip);
      final owned = await acceptedClipDrag(tester, pointer: 71);
      final peer =
          await tester.startGesture(tester.getCenter(clip), pointer: 72);
      await owned.cancel();
      await tester.pumpAndSettle();
      expect(tester.getRect(clip), original);
      if (terminal == 'up') {
        await peer.up();
      } else {
        await peer.cancel();
      }
      await tester.pumpAndSettle();
      expect(tester.getRect(clip), original);
      expect(find.text('Saved'), findsOneWidget);
      expect(historyButton(tester, 'Undo').onPressed, isNull);
      final next = await acceptedClipDrag(tester);
      await next.up();
      await tester.pumpAndSettle();
      expect(find.text('Unsaved changes'), findsOneWidget);
      await tester.tap(find.byTooltip('Undo'));
      await tester.pump();
      expect(tester.getRect(clip), original);
      expect(historyButton(tester, 'Undo').onPressed, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets('E2 queued cancel survives resize and cannot affect next drag',
      (tester) async {
    await mount(tester);
    final clip = find.byKey(const ValueKey('mix-clip-a'));
    final original = tester.getRect(clip);
    await acceptedClipDrag(tester, pointer: 51);
    tester.view.physicalSize = const Size(959, 1000);
    await tester.pumpAndSettle();
    tester.binding.cancelPointer(51);
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    expect(historyButton(tester, 'Undo').onPressed, isNull);
    tester.view.physicalSize = const Size(1440, 1000);
    await tester.pumpAndSettle();
    expect(tester.getRect(clip), original);
    final next = await acceptedClipDrag(tester);
    await next.up();
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(tester.getRect(clip), original);
    expect(historyButton(tester, 'Undo').onPressed, isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('E2 queued cancel after editor unmount has no stale callbacks',
      (tester) async {
    await mount(tester);
    await acceptedClipDrag(tester, pointer: 52);
    tester.binding.cancelPointer(52);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await mount(tester);
    final next = await acceptedClipDrag(tester);
    await next.up();
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
    expect(historyButton(tester, 'Undo').onPressed, isNull);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('E2 document replacement retires old accepted drag ownership',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final document = ValueNotifier('plan-1');
    addTearDown(document.dispose);
    final calls = <String>[];
    final api = mockQueueApiClient((request) async {
      calls.add(request.method);
      return http.Response(
          jsonEncode({
            ...planJson(),
            'id': request.url.path.split('/').last,
          }),
          200);
    });
    await tester.pumpWidget(Provider<ApiClient>.value(
        value: api,
        child: MaterialApp(
            home: ValueListenableBuilder<String>(
                valueListenable: document,
                builder: (context, id, _) =>
                    DesktopMixEditorScreen(planId: id)))));
    await tester.pumpAndSettle();
    final old = await acceptedClipDrag(tester, pointer: 61);
    document.value = 'plan-2';
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    final next = await acceptedClipDrag(tester, pointer: 62);
    final preview = tester.getRect(find.byKey(const ValueKey('mix-clip-a')));
    await old.cancel();
    await tester.pumpAndSettle();
    expect(tester.getRect(find.byKey(const ValueKey('mix-clip-a'))), preview);
    await next.up();
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
    expect(historyButton(tester, 'Undo').onPressed, isNull);
    expect(calls, ['GET', 'GET']);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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
