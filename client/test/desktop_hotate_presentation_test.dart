// Routed production presentation with bundled fonts. No native/device claim.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart' show LoopMode;

import 'package:open_music_player/app/app.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/auth/auth_state.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/models/settings_model.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';

import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/network/connectivity_service.dart';
import 'package:open_music_player/core/services/library_service.dart';
import 'package:open_music_player/core/services/liked_tracks_state.dart';
import 'package:open_music_player/core/storage/offline_database.dart';
import 'package:open_music_player/features/library/library_screen.dart';

import 'package:open_music_player/shared/models/track.dart';
import 'package:open_music_player/shared/models/verification_filter.dart';
import 'package:open_music_player/shared/widgets/app_snack_bar.dart';
import 'package:open_music_player/shared/widgets/adaptive_desktop_app_bar.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_mix_editor_draft_test.dart' show planJson, clipJson;
import 'flight_theme_typography_test.dart' show loadFlightFonts;
import 'song_row_presentation_test.dart' show FakePlayback;
import 'support/mock_dio_client.dart';
import 'connect_app_composition_test.dart' show NoSharedIntent;

RenderParagraph _paragraph(WidgetTester tester, Finder text) =>
    tester.renderObject<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)).first);

void _completeGlyphs(RenderParagraph paragraph) {
  final painter = TextPainter(
      text: paragraph.text,
      textScaler: paragraph.textScaler,
      textDirection: paragraph.textDirection,
      maxLines: 1)
    ..layout();
  expect(paragraph.size.width + .01, greaterThanOrEqualTo(painter.width));
  expect(paragraph.size.height + .01, greaterThanOrEqualTo(painter.height));
  for (final box in paragraph.getBoxesForSelection(TextSelection(
      baseOffset: 0, extentOffset: paragraph.text.toPlainText().length))) {
    expect(box.left, greaterThanOrEqualTo(-.01));
    expect(box.right, lessThanOrEqualTo(paragraph.size.width + .01));
    expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + .01));
  }
  painter.dispose();
}

Finder _paint(Finder control) {
  final owner = find.ancestor(of: control, matching: find.byType(IconButton));
  return find
      .descendant(
          of: owner.evaluate().isEmpty ? control : owner.first,
          matching: find.byType(Material))
      .first;
}

Future<GoRouter> _mount(WidgetTester tester,
    {required double width,
    required double scale,
    bool library = false,
    String name = 'Night drive',
    _Playback? playback,
    List<Map<String, dynamic>>? clips,
    bool picker = false,
    void Function(Map<String, dynamic>)? saved}) async {
  await loadFlightFonts(tester);
  SharedPreferences.setMockInitialValues({
    'app_settings': jsonEncode({'themeMode': 2})
  });
  tester.view
    ..physicalSize = Size(width, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  var server = {...planJson(clips: clips), 'name': name};
  final api = mockQueueApiClient((request) async {
    if (request.method == 'PUT') {
      server = {
        ...server,
        'version': 4,
        'clips': jsonDecode(request.body)['clips']
      };
      saved?.call(server);
    }
    return http.Response(
        jsonEncode(request.url.path.endsWith('/mix-plans')
            ? {
                'data': [server]
              }
            : server),
        200);
  });
  final player = playback ?? _Playback();
  final liked = LikedTracksState(LibraryService(api));
  addTearDown(liked.dispose);
  addTearDown(player.dispose);
  final app = OpenMusicPlayerApp(
      apiClient: api,
      authState: _Auth(),
      playbackState: player,
      sharedIntentReceiver: NoSharedIntent());
  final router = app.router;
  router.go(library
      ? '/library'
      : picker
          ? '/mixes'
          : '/mixes/plan-1');
  addTearDown(router.dispose);
  await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        Provider<OfflineDatabase>.value(value: _Database()),
        ChangeNotifierProvider<ConnectivityService>(create: (_) => _Offline()),
        ChangeNotifierProvider<PlaybackState>.value(value: player),
        ChangeNotifierProvider<LikedTracksState>.value(value: liked),
        ChangeNotifierProvider<DownloadState>(create: (_) => _Downloads()),
      ],
      child: riverpod.ProviderScope(
          overrides: [
            sharedPreferencesProvider
                .overrideWithValue(await SharedPreferences.getInstance()),
          ],
          child: RepaintBoundary(
              key: const ValueKey('hotate-capture'), child: app))));
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
  });
  return router;
}

Future<void> _capture(WidgetTester tester, String name) async {
  final output = Platform.environment['SOUNDQ_HOTATE_CAPTURE_DIR'];
  if (output == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('hotate-capture')));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$output/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _paintedContrast(
    WidgetTester tester, Finder label, Color surface, Color foreground) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('hotate-capture')));
  final rect = tester.getRect(label);
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var backgroundPixels = 0, foregroundPixels = 0;
    for (var y = (rect.top * 2).ceil(); y < (rect.bottom * 2).floor(); y++) {
      for (var x = (rect.left * 2).ceil(); x < (rect.right * 2).floor(); x++) {
        final i = (y * image.width + x) * 4;
        final color = Color.fromARGB(bytes.getUint8(i + 3), bytes.getUint8(i),
            bytes.getUint8(i + 1), bytes.getUint8(i + 2));
        if (color == surface) backgroundPixels++;
        if (color == foreground) foregroundPixels++;
      }
    }
    expect(backgroundPixels, greaterThan(20),
        reason: 'Actual error surface pixels under label');
    expect(foregroundPixels, greaterThan(10),
        reason: 'Actual full-coverage foreground glyph pixels');
    image.dispose();
  });
}

Future<void> _tabTo(WidgetTester tester, Finder control) async {
  for (var i = 0; i < 80; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) continue;
    var inside = control.evaluate().any((e) => identical(e, focused));
    focused.visitAncestorElements((e) {
      if (control.evaluate().any((c) => identical(c, e))) inside = true;
      return !inside;
    });
    if (inside) return;
    final enclosing =
        find.ancestor(of: control, matching: find.byType(Focus)).first;
    if (enclosing.evaluate().any((e) => identical(e, focused))) return;
  }
  fail('Native Tab did not reach $control');
}

void main() {
  testWidgets('D1-L1 focused long title retains disclosure after pointer exit',
      (tester) async {
    final name = List.filled(3, 'Long saved mix name').join(' ');
    await _mount(tester, width: 960, scale: 2, name: name);
    final title = find
        .descendant(of: find.byType(AppBar), matching: find.text(name))
        .first;
    final tooltip = find.ancestor(of: title, matching: find.byType(Tooltip));
    final paragraph = _paragraph(tester, title);
    final natural = TextPainter(
        text: paragraph.text,
        textScaler: paragraph.textScaler,
        textDirection: paragraph.textDirection,
        maxLines: 1)
      ..layout();
    expect(natural.width, greaterThan(paragraph.size.width));
    expect(paragraph.textScaler.scale(20), 40);
    natural.dispose();
    expect(tester.widget<Tooltip>(tooltip).message, name);
    await _tabTo(tester, tooltip);
    await tester.pumpAndSettle();
    final originalFocus = FocusManager.instance.primaryFocus!;
    expect(originalFocus.hasPrimaryFocus, isTrue);
    expect(find.text(name), findsNWidgets(2));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(title));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(name), findsNWidgets(2));
    await mouse.moveTo(const Offset(0, 899));
    await tester.pumpAndSettle();
    await mouse.removePointer();
    await tester.pump(const Duration(seconds: 1));
    expect(FocusManager.instance.primaryFocus, same(originalFocus));
    expect(originalFocus.hasPrimaryFocus, isTrue);
    expect(tester.widget<Tooltip>(tooltip).message, name);
    expect(find.text(name), findsNWidgets(2),
        reason: 'Pointer exit must not retire keyboard full-name disclosure');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(originalFocus.hasPrimaryFocus, isFalse);
    expect(find.text(name), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(name), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(find.text(name), findsNothing);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'D1-L1 title layout changes and queued exits respect current owner',
      (tester) async {
    await loadFlightFonts(tester);
    tester.view
      ..physicalSize = const Size(960, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // Stay genuinely truncated at both 1x and 2x; fitting is tested below.
    final name = ValueNotifier(List.filled(6, 'Long saved mix name').join(' '));
    final scale = ValueNotifier(2.0);
    addTearDown(name.dispose);
    addTearDown(scale.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: SoundQDesktopTheme.apply(AppTheme.darkTheme),
        home: ValueListenableBuilder<String>(
            valueListenable: name,
            builder: (context, value, _) => ValueListenableBuilder<double>(
                valueListenable: scale,
                builder: (context, factor, _) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(factor)),
                    child: Builder(
                        builder: (context) => Scaffold(
                                appBar: adaptiveDesktopAppBar(context,
                                    title: value,
                                    actions: [
                                  TextButton(
                                      onPressed: () {},
                                      child: const Text('Next action'))
                                ]))))))));
    await tester.pumpAndSettle();
    Finder title() => find
        .descendant(of: find.byType(AppBar), matching: find.text(name.value))
        .first;
    Finder tooltip() =>
        find.ancestor(of: title(), matching: find.byType(Tooltip));
    await _tabTo(tester, tooltip());
    await tester.pumpAndSettle();
    final originalFocus = FocusManager.instance.primaryFocus!;
    expect(find.text(name.value), findsNWidgets(2));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    Future<void> queueExit() async {
      await mouse.moveTo(tester.getCenter(title()));
      await tester.pumpAndSettle();
      expect(find.text(name.value), findsNWidgets(2));
      await mouse.moveTo(const Offset(0, 899));
    }

    await queueExit();
    final oldName = name.value;
    name.value = '$oldName replacement';
    tester.view.physicalSize = const Size(1000, 900);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(originalFocus));
    expect(originalFocus.hasPrimaryFocus, isTrue);
    expect(find.text(oldName), findsNothing);
    expect(find.text(name.value), findsNWidgets(2));
    scale.value = 1;
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(originalFocus));
    expect(_paragraph(tester, title()).textScaler.scale(20), 20);
    expect(find.text(name.value), findsNWidgets(2));
    scale.value = 2;
    await tester.pumpAndSettle();
    expect(_paragraph(tester, title()).textScaler.scale(20), 40);
    expect(find.text(name.value), findsNWidgets(2));
    final paragraph = _paragraph(tester, title());
    final natural = TextPainter(
        text: paragraph.text,
        textScaler: paragraph.textScaler,
        textDirection: paragraph.textDirection)
      ..layout();
    final fittingWidth = 1000 + natural.width - paragraph.size.width + 100;
    natural.dispose();
    await queueExit();
    tester.view.physicalSize = Size(fittingWidth, 900);
    await tester.pumpAndSettle();
    expect(tester.widget<Tooltip>(tooltip()).message, '');
    expect(find.text(name.value), findsOneWidget);
    _completeGlyphs(_paragraph(tester, title()));
    tester.view.physicalSize = const Size(960, 900);
    await tester.pumpAndSettle();
    expect(tester.widget<Tooltip>(tooltip()).message, name.value);
    await _tabTo(tester, tooltip());
    await tester.pumpAndSettle();
    expect(find.text(name.value), findsNWidgets(2));
    await queueExit();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(originalFocus.hasPrimaryFocus, isFalse);
    expect(find.text(name.value), findsOneWidget);
    await _tabTo(tester, tooltip());
    await tester.pumpAndSettle();
    expect(find.text(name.value), findsNWidgets(2));
    final transient = tester.binding.transientCallbackCount;
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.binding.transientCallbackCount, transient);
    }
    await queueExit();
    await mouse.removePointer();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(find.text(name.value), findsNothing);
    expect(originalFocus.hasPrimaryFocus, isFalse);
    expect(tester.binding.transientCallbackCount, 0);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'D1 enlarged Save paints the same track as adjacent icons independently of title scaler',
      (tester) async {
    await _mount(tester, width: 960, scale: 2);
    final save = tester.getRect(_paint(find.byKey(const ValueKey('mix-save'))));
    final undo = tester.getRect(_paint(find.byTooltip('Undo')));
    expect(save.height, closeTo(undo.height, .01));
    expect(save.center.dy, closeTo(undo.center.dy, .01));
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets('D2 editor clip paints square independently of label allocation',
      (tester) async {
    await _mount(tester, width: 960, scale: 2);
    final clip = find.byKey(const ValueKey('mix-clip-a'));
    final material = tester.widget<Material>(
        find.ancestor(of: clip, matching: find.byType(Material)).first);
    expect((material.shape! as RoundedRectangleBorder).borderRadius,
        BorderRadius.zero);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets(
      'D3 legacy red error action close maintain native states queue and timers',
      (tester) async {
    await _mount(tester, width: 1440, scale: 2, library: true);
    final messenger =
        ScaffoldMessenger.of(tester.element(find.byType(LibraryScreen)));
    var retries = 0;
    final first = messenger.showSnackBar(AppSnackBar(
      content: const Text('Legacy error'),
      backgroundColor: Colors.red,
      action: SnackBarAction(label: 'Retry', onPressed: () => retries++),
    ));
    final next = messenger.showSnackBar(const AppSnackBar(
        content: Text('Next event'), duration: Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('Next event'), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    for (final control in [
      find.widgetWithText(TextButton, 'Retry'),
      find.byWidgetPredicate((w) => w is IconButton && w.tooltip == 'Close')
    ]) {
      await _tabTo(tester, control);
      await mouse.moveTo(tester.getCenter(control));
      await tester.pumpAndSettle();
      Future<void> check() async {
        final surface = tester.widget<Material>(_paint(control)).color!;
        final label =
            find.descendant(of: control, matching: find.text('Retry'));
        final foreground = label.evaluate().isNotEmpty
            ? (_paragraph(tester, label).text as TextSpan).style!.color!
            : IconTheme.of(tester.element(
                    find.descendant(of: control, matching: find.byType(Icon))))
                .color!;
        final a = surface.computeLuminance(), b = foreground.computeLuminance();
        final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: 'Actual focused hovered/held/release error control');
      }

      await check();
      final held = await tester.startGesture(tester.getCenter(control));
      await tester.pump(const Duration(milliseconds: 120));
      await check();
      await held.moveTo(const Offset(0, 899));
      await held.up();
      await tester.pump(const Duration(milliseconds: 50));
      await check();
    }
    await mouse.removePointer();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(await first.closed, SnackBarClosedReason.action);
    expect(find.text('Next event'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(await next.closed, SnackBarClosedReason.timeout);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets(
      'D2 four lanes remain aligned, short clips stay time sized and move cancel undo survive',
      (tester) async {
    Map<String, dynamic>? saved;
    await _mount(tester, width: 960, scale: 2, saved: (v) => saved = v, clips: [
      for (var i = 0; i < 4; i++)
        {...clipJson(id: '$i'), if (i == 3) 'sourceEndMs': 1200},
      clipJson(id: 'later', start: 20000),
    ]);
    final rects = [
      for (var i = 0; i < 4; i++)
        tester.getRect(find.byKey(ValueKey('mix-clip-$i')))
    ];
    expect(rects[3].width, closeTo(7, .01));
    for (var i = 1; i < 4; i++) {
      expect(
          rects[i].top - rects[i - 1].top, closeTo(rects[0].height + 16, .01));
    }
    final short = find.byKey(const ValueKey('mix-clip-3'));
    await tester.ensureVisible(short);
    await tester.pumpAndSettle();
    await tester.tap(short);
    await tester.pump();
    expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('mix-field-out')))
            .controller!
            .text,
        '1200');
    final clip = find.byKey(const ValueKey('mix-clip-0'));
    await tester.ensureVisible(clip);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(clip));
    await gesture.moveBy(const Offset(2, 0));
    await tester.pump();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(find.text('Saved'), findsOneWidget);
    final move = await tester.startGesture(tester.getCenter(clip));
    await move.moveBy(const Offset(20, 0)); // Native recognizer's touch slop.
    await tester.pump();
    await move.moveBy(const Offset(35, 0));
    await tester.pump();
    await move.moveBy(const Offset(35, 0));
    await move.up();
    await tester.pumpAndSettle();
    expect(find.text('Unsaved changes'), findsOneWidget);
    await tester.tap(find.byTooltip('Undo'));
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
    await tester.tap(find.byTooltip('Redo'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('mix-save')));
    await tester.pumpAndSettle();
    expect(saved!['clips'][0]['timelineStartMs'], 2000);
    expect(saved!['clips'][0]['queueItemId'], 'q-0');
    final horizontal = find
        .byWidgetPredicate((w) =>
            w is Scrollable &&
            w.axisDirection == AxisDirection.right &&
            w.restorationId != 'editable')
        .first;
    await tester.drag(horizontal, const Offset(-500, 0));
    await tester.pumpAndSettle();
    final later = find.byKey(const ValueKey('mix-clip-later'));
    await tester.ensureVisible(later);
    await tester.pumpAndSettle();
    await tester.tap(later);
    await tester.pump();
    expect(
        tester
            .widget<TextField>(
                find.byKey(const ValueKey('mix-field-placement')))
            .controller!
            .text,
        '20000');
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  testWidgets('D1 sibling saved mix picker preserves requested title scaling',
      (tester) async {
    await _mount(tester, width: 960, scale: 2, picker: true);
    final p = _paragraph(tester, find.text('Saved mixes'));
    expect(p.textScaler.scale(20), 40);
    _completeGlyphs(p);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets(
      'D1 long name native pointer and keyboard disclosure then compact keyboard Save',
      (tester) async {
    final name = List.filled(6, 'Long saved mix name').join(' ');
    Map<String, dynamic>? saved;
    await _mount(tester,
        width: 960, scale: 2, name: name, saved: (value) => saved = value);
    final title =
        find.descendant(of: find.byType(AppBar), matching: find.text(name));
    expect(_paragraph(tester, title).textScaler.scale(20), 40);
    final tooltip = find.ancestor(of: title, matching: find.byType(Tooltip));
    expect(tester.widget<Tooltip>(tooltip).message, name);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(title));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(name), findsNWidgets(2));
    await mouse.moveTo(const Offset(0, 899));
    await tester.pumpAndSettle();
    await mouse.removePointer();
    await _tabTo(tester, tooltip);
    await tester.pumpAndSettle();
    expect(find.text(name), findsNWidgets(2));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.text(name), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mix-clip-a')));
    await tester.pump();
    await tester.enterText(find.byKey(const ValueKey('mix-field-in')), '2000');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    final save = find.byKey(const ValueKey('mix-save'));
    await _tabTo(tester, save);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(saved!['clips'][0]['sourceStartMs'], 2000);
    expect(saved!['clips'][0]['queueItemId'], 'q-a');
    expect(find.text('Version 4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('mobile 959 retains native title clamp and mix fallback',
      (tester) async {
    final router = await _mount(tester, width: 959, scale: 2, library: true);
    final title = find.descendant(
        of: find.byType(AppBar), matching: find.text('Library'));
    expect(_paragraph(tester, title).textScaler.scale(20), 26.8);
    expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, isNull);
    router.go('/mixes/plan-1');
    await tester.pumpAndSettle();
    expect(find.text('Go to playlists'), findsOneWidget);
    expect(find.byKey(const ValueKey('mix-save')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  for (final scale in [1.0, 2.0]) {
    testWidgets('D3 actual library playback failure contrast and retry $scale',
        (tester) async {
      final playback = _Playback()..fail = true;
      await _mount(tester,
          width: 1440, scale: scale, library: true, playback: playback);
      await tester.tap(find.text('Library track'));
      await tester.pumpAndSettle();
      expect(playback.plays, 1);
      final message = find.text('Could not play this track.');
      expect(message, findsOneWidget);
      final paragraph = _paragraph(tester, message);
      final foreground = (paragraph.text as TextSpan).style!.color!;
      final surface = tester
          .widget<Material>(find
              .descendant(
                  of: find.byType(SnackBar), matching: find.byType(Material))
              .first)
          .color!;
      double contrast(Color a, Color b) {
        final x = a.computeLuminance(), y = b.computeLuminance();
        return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
      }

      expect(contrast(foreground, surface), greaterThanOrEqualTo(4.5),
          reason: 'Mounted caller foreground/background, not theme tokens');
      await _paintedContrast(tester, message, surface, foreground);
      final close = find.byTooltip('Close');
      final icon = find.descendant(of: close, matching: find.byType(Icon));
      final iconColor = IconTheme.of(tester.element(icon)).color!;
      final closeSurface = tester.widget<Material>(_paint(close)).color!;
      expect(contrast(iconColor, closeSurface), greaterThanOrEqualTo(4.5),
          reason:
              'Close glyph against its own painted Material, not notification');
      await _paintedContrast(tester, icon, closeSurface, iconColor);
      await _capture(tester, 'D3-library-error-$scale');
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(message, findsNothing);
      playback.fail = false;
      await tester.tap(find.text('Library track'));
      await tester.pumpAndSettle();
      expect(playback.plays, 2);
      expect(message, findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }
  for (final width in [960.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
          'D2 scaled clip labels square and time faithful $width $scale',
          (tester) async {
        await _mount(tester, width: width, scale: scale);
        final clip = find.byKey(const ValueKey('mix-clip-a'));
        final rect = tester.getRect(clip);
        expect(rect.width, closeTo(350, .01),
            reason: '10000ms at .035px/ms, never widen to fit text');
        final title =
            find.descendant(of: clip, matching: find.text('Track 42'));
        final range =
            find.descendant(of: clip, matching: find.text('1000–11000 ms'));
        for (final text in [title, range]) {
          final p = _paragraph(tester, text);
          expect(p.textScaler.scale(20), 20 * scale);
          _completeGlyphs(p);
          final glyphRect = tester.getRect(text);
          expect(glyphRect.top, greaterThanOrEqualTo(rect.top + 8));
          expect(glyphRect.bottom, lessThanOrEqualTo(rect.bottom - 8 + .01),
              reason:
                  'Two basic lines must paint inside clip without micro-scroll');
        }
        expect(find.descendant(of: clip, matching: find.byType(Scrollable)),
            findsNothing);
        final material = tester.widget<Material>(
            find.ancestor(of: clip, matching: find.byType(Material)).first);
        expect((material.shape! as RoundedRectangleBorder).borderRadius,
            BorderRadius.zero);
        await tester.tap(clip);
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('mix-field-in')), findsOneWidget);
        await _capture(tester, 'D2-editor-$width-$scale');
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }
  }
  for (final width in [960.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final library in [false, true]) {
        testWidgets(
            'D1 full routed title and painted action tracks $library $width $scale',
            (tester) async {
          await _mount(tester, width: width, scale: scale, library: library);
          final title = find.descendant(
              of: find.byType(AppBar),
              matching: find.text(library ? 'Library' : 'Night drive'));
          final p = _paragraph(tester, title);
          expect(p.textScaler.scale(20), 20 * scale,
              reason: 'Actual AppBar paragraph, not outer MediaQuery');
          expect((p.text as TextSpan).style!.fontFamily, 'Space Grotesk');
          _completeGlyphs(p);
          final controls = library
              ? [
                  find.byTooltip('Liked Songs'),
                  find.byTooltip('Create playlist')
                ]
              : [
                  find.byType(BackButton),
                  find.byTooltip('Mix import and export'),
                  find.byTooltip('Undo'),
                  find.byTooltip('Redo'),
                  find.byTooltip('Reload saved mix'),
                  find.byKey(const ValueKey('mix-save'))
                ];
          final rects = controls.map((c) => tester.getRect(_paint(c))).toList();
          if (!library) {
            _completeGlyphs(_paragraph(tester, find.text('Save')));
            for (final control in controls) {
              final icon = find
                  .descendant(of: control, matching: find.byType(Icon))
                  .first;
              expect(tester.getCenter(icon).dy,
                  closeTo(rects.first.center.dy, .01));
            }
          }
          for (final r in rects) {
            expect(r.height, closeTo(rects.first.height, .01),
                reason: 'Painted Material, not padded hit region');
            expect(r.center.dy, closeTo(rects.first.center.dy, .01));
            expect(r.overlaps(tester.getRect(title)), isFalse);
            expect(r.right, lessThanOrEqualTo(width));
          }
          await _capture(
              tester, 'D1-${library ? 'library' : 'editor'}-$width-$scale');
          expect(tester.takeException(), isNull);
        }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
      }
    }
  }
}

class _Offline extends ChangeNotifier implements ConnectivityService {
  @override
  bool get isOnline => false;
  @override
  bool get isOffline => true;
  @override
  bool get isWifi => false;
  @override
  Future<bool> checkConnectivity() async => false;
}

class _Database extends Fake implements OfflineDatabase {
  @override
  Future<({List<Track> tracks, int total})> getLibraryTracksWithCount(
          {bool downloadedOnly = false,
          VerificationFilter verificationFilter = VerificationFilter.all,
          int limit = 20,
          int offset = 0}) async =>
      (
        tracks: [
          Track.fromJson(
              {'id': 42, 'title': 'Library track', 'artist': 'Fixture'})
        ],
        total: 1
      );
  @override
  Future<Map<VerificationFilter, int>> getLibraryTrackCounts() async =>
      {VerificationFilter.all: 1};
}

class _Downloads extends ChangeNotifier implements DownloadState {
  @override
  Future<bool> isDownloaded(int trackId) async => false;
  @override
  DownloadProgress? getProgress(int trackId) => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Playback extends FakePlayback {
  @override
  get currentItem => null;
  @override
  PlaybackContext? get playbackContext => null;
  @override
  bool get shuffleEnabled => false;
  @override
  int? get currentIndex => null;
  @override
  Duration get duration => Duration.zero;
  @override
  LoopMode get loopMode => LoopMode.off;
  @override
  bool get canSkipNext => false;
  @override
  bool get hasPreviousInPlayOrder => false;
  @override
  PlaybackSnapshot get snapshot => PlaybackSnapshot.empty();
  @override
  bool get isResolvingSignedUrl => false;
  @override
  Future<void> applyAudioDefaults(AudioPlaybackDefaults defaults) async {}
  @override
  void setEndOfQueueMode(EndOfQueueMode mode) {}
  @override
  void setSwipeQueueMode(QueueInsertMode mode) {}
  @override
  void setPreserveManualQueue(bool preserve) {}
  bool fail = false;
  int plays = 0;
  @override
  String? get playbackError => null;
  @override
  Future<void> playQueue(List<Map<String, dynamic>> tracks,
      {int startIndex = 0, PlaybackContext? context}) async {
    plays++;
    if (fail) throw StateError('synthetic playback refusal');
  }

  @override
  bool get hasTrack => false;
  @override
  bool get isPlaying => false;
}

class _Auth extends Fake implements AuthState {
  @override
  int get sessionRevision => 0;
  @override
  bool get hasLocalSession => true;
  @override
  bool get isBiometricLocked => false;
  // Offline local session keeps the real root/router without a presence lease.
  @override
  bool get isAuthenticated => false;
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
}
