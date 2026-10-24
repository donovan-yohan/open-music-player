import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/commands/command_registry.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/features/playlists/playlists_screen.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/screens/queue_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop_listening_shell_test.dart' show shellRouter;
import 'song_row_presentation_test.dart' show FakePlayback, makeSnapshot;

final _switch = find.byKey(const ValueKey('queue_view_switch'));
Finder _segment(String label) => find.descendant(
    of: _switch, matching: find.widgetWithText(TextButton, label));
Material _surface(WidgetTester tester, Finder control) =>
    tester.widget<Material>(
        find.descendant(of: control, matching: find.byType(Material)).last);

// Inner TextButton materials are always square, even for the broken pill.
// Inspect the native renderer's *painted outer border*, not those inner shapes.
OutlinedBorder _queueBorder(WidgetTester tester) {
  final renderer = find.descendant(
      of: _switch,
      matching: find.byWidgetPredicate((widget) => widget.runtimeType
          .toString()
          .startsWith('_SegmentedButtonRenderWidget')));
  final dynamic render = tester.renderObject(renderer);
  return render.enabledBorder as OutlinedBorder;
}

void _expectSquare(OutlinedBorder shape) {
  expect(shape, isA<RoundedRectangleBorder>());
  expect((shape as RoundedRectangleBorder).borderRadius, BorderRadius.zero);
  expect(shape.side.width, 1);
}

Future<void> _pumpScreen(WidgetTester tester, Widget screen, String path,
    {double width = 960, double scale = 1}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final playback = _Playback();
  final registry = CommandRegistry(playbackState: playback);
  final api = _QueueApi();
  final queue = QueueProvider(api);
  final router = shellRouter(content: screen)..go(path);
  addTearDown(playback.dispose);
  addTearDown(registry.dispose);
  addTearDown(queue.dispose);
  addTearDown(router.dispose);
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      Provider<CommandRegistry>.value(value: registry),
      ChangeNotifierProvider<PlaybackState>.value(value: playback),
      ChangeNotifierProvider<QueueProvider>.value(value: queue),
    ],
    child: MaterialApp.router(
      theme: AppTheme.darkTheme,
      routerConfig: router,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: SoundQDesktopTheme(child: child!),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  expect(router.routeInformationProvider.value.uri.path, path);
}

Future<void> _tabTo(WidgetTester tester, Finder target) async {
  bool isTarget() {
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

  for (var i = 0; i < 50 && !isTarget(); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(isTarget(), isTrue, reason: 'Native Tab must reach the real control');
}

void _nativeWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    expect(defaultTargetPlatform,
        isIn([TargetPlatform.android, TargetPlatform.macOS]));
    await callback(tester);
  },
      variant: const TargetPlatformVariant(
          {TargetPlatform.android, TargetPlatform.macOS}));
}

// Inspect the mounted Material's native ink features after real input. Hover,
// focus and splash layers can coexist; resolving one style token misses that.
Future<void> _expectSegmentContrast(
    WidgetTester tester, String label, String state) async {
  final control = _segment(label);
  final text =
      tester.element(find.descendant(of: control, matching: find.text(label)));
  final style = DefaultTextStyle.of(text).style;
  final states = tester.widget<TextButton>(control).statesController!.value;
  final ink = tester.widget<InkWell>(
      find.descendant(of: control, matching: find.byType(InkWell)));
  final inkContext = tester
      .element(find.descendant(of: control, matching: find.byType(InkWell)));
  final dynamic controller = Material.of(inkContext);
  final features = (controller.debugInkFeatures as List?)
          ?.whereType<InteractiveInkFeature>()
          .where((feature) => feature is! InkHighlight || feature.active)
          .toList() ??
      <InteractiveInkFeature>[];
  final scaffold = tester.widget<Scaffold>(
      find.ancestor(of: control, matching: find.byType(Scaffold)).first);
  final under =
      scaffold.backgroundColor ?? Theme.of(text).scaffoldBackgroundColor;
  final fill = Color.alphaBlend(_surface(tester, control).color!, under);
  final origin = tester.getTopLeft(control);
  final size = tester.getSize(control);
  final labelBounds = tester
      .getRect(find.descendant(of: control, matching: find.text(label)))
      .shift(-origin);
  // Rasterize the live features themselves, not their declared colors: a
  // pressed InkHighlight can have a transparent animation despite .color,
  // while the native splash and hover really do paint together.
  final background = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawPaint(Paint()..color = fill);
    for (final feature in features) {
      final offset = feature.referenceBox.localToGlobal(Offset.zero) - origin;
      // ignore: invalid_use_of_protected_member
      feature.paintFeature(
          canvas, Matrix4.translationValues(offset.dx, offset.dy, 0));
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var worst = fill;
    var minimum = double.infinity;
    final foreground = style.color!.computeLuminance();
    for (var y = labelBounds.top.ceil(); y < labelBounds.bottom.floor(); y++) {
      for (var x = labelBounds.left.ceil();
          x < labelBounds.right.floor();
          x++) {
        final index = (y * image.width + x) * 4;
        final pixel = Color.fromARGB(
            bytes.getUint8(index + 3),
            bytes.getUint8(index),
            bytes.getUint8(index + 1),
            bytes.getUint8(index + 2));
        final luminance = pixel.computeLuminance();
        final ratio =
            ((foreground > luminance ? foreground : luminance) + .05) /
                ((foreground > luminance ? luminance : foreground) + .05);
        if (ratio < minimum) {
          minimum = ratio;
          worst = pixel;
        }
      }
    }
    image.dispose();
    picture.dispose();
    return worst;
  });
  expect(background, isNotNull);
  double contrast(Color foreground) {
    final a = Color.alphaBlend(foreground, background!).computeLuminance();
    final b = background.computeLuminance();
    return ((a > b ? a : b) + .05) / ((a > b ? b : a) + .05);
  }

  expect(MediaQuery.textScalerOf(text).scale(14), 14);
  expect(style.fontSize, 14);
  expect(states.contains(WidgetState.selected), label == 'List');
  expect(states, isNot(contains(WidgetState.disabled)));
  if (state == 'resting') {
    expect(
        states.intersection(
            {WidgetState.hovered, WidgetState.focused, WidgetState.pressed}),
        isEmpty);
    expect(features, isEmpty);
  } else {
    final active = switch (state) {
      'hovered' => WidgetState.hovered,
      'focused' => WidgetState.focused,
      _ => WidgetState.pressed,
    };
    expect(states, contains(active));
    expect(features, isNotEmpty);
    // Native ink lifecycles still coexist; opaque Material state resolution
    // replaces the former low-alpha layers without weakening raster contrast.
    expect(features.every((feature) => feature.color.a == 0), isTrue);
    expect(ink.overlayColor!.resolve(states), Colors.transparent);
    expect(
        _surface(tester, control).color,
        states.contains(WidgetState.selected)
            ? Color.lerp(AppTheme.orange, AppTheme.textPrimary,
                states.contains(WidgetState.pressed) ? .55 : .3)
            : states.contains(WidgetState.pressed)
                ? AppTheme.textPrimary
                : AppTheme.accent);
    expect(_queueBorder(tester).side.color, AppTheme.accent);
  }
  final ratio = contrast(style.color!);
  debugPrint('SEGMENT_CONTRAST ${jsonEncode({
        'platform': defaultTargetPlatform.name,
        'scale': MediaQuery.textScalerOf(text).scale(1),
        'label': label,
        'state': state,
        'fontSize': style.fontSize,
        'fontWeight': style.fontWeight.toString(),
        'foreground': style.color!.toARGB32(),
        'fill': _surface(tester, control).color!.toARGB32(),
        'scaffold': under.toARGB32(),
        'ink': features
            .map((feature) => {
                  'type': feature.runtimeType.toString(),
                  'color': feature.color.toARGB32(),
                })
            .toList(),
        'background': background!.toARGB32(),
        'contrast': ratio,
        'onSurfaceContrast': contrast(Theme.of(text).colorScheme.onSurface),
        'onPrimaryContrast': contrast(Theme.of(text).colorScheme.onPrimary),
      })}');
  expect(ratio, greaterThanOrEqualTo(4.5),
      reason: '$label $state: normal-size native macOS segment label');
}

// Release retains fading highlights even after InkHighlight.active becomes
// false. Keep the independently validated held-state helper above unchanged;
// rasterize *all* still-mounted features here to cover the release animation.
Future<void> _expectReleasedSegmentContrast(
    WidgetTester tester, String label, String sample) async {
  final control = _segment(label);
  final labelFinder = find.descendant(of: control, matching: find.text(label));
  final text = tester.element(labelFinder);
  final style = DefaultTextStyle.of(text).style;
  final states = tester.widget<TextButton>(control).statesController!.value;
  expect(states, containsAll([WidgetState.focused, WidgetState.hovered]));
  expect(states, isNot(contains(WidgetState.pressed)));
  expect(style.fontSize, 14);
  expect(MediaQuery.textScalerOf(text).scale(14), 14);
  final dynamic controller = Material.of(tester
      .element(find.descendant(of: control, matching: find.byType(InkWell))));
  final features = (controller.debugInkFeatures as List)
      .whereType<InteractiveInkFeature>()
      .toList();
  final scaffold = tester.widget<Scaffold>(
      find.ancestor(of: control, matching: find.byType(Scaffold)).first);
  final under =
      scaffold.backgroundColor ?? Theme.of(text).scaffoldBackgroundColor;
  final fill = Color.alphaBlend(_surface(tester, control).color!, under);
  final origin = tester.getTopLeft(control);
  final size = tester.getSize(control);
  final labelBounds = tester.getRect(labelFinder).shift(-origin);
  final minimum = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..drawPaint(Paint()..color = fill);
    for (final feature in features) {
      final offset = feature.referenceBox.localToGlobal(Offset.zero) - origin;
      // ignore: invalid_use_of_protected_member
      feature.paintFeature(
          canvas, Matrix4.translationValues(offset.dx, offset.dy, 0));
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(size.width.ceil(), size.height.ceil());
    final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    var minimum = double.infinity;
    for (var y = labelBounds.top.ceil(); y < labelBounds.bottom.floor(); y++) {
      for (var x = labelBounds.left.ceil();
          x < labelBounds.right.floor();
          x++) {
        final index = (y * image.width + x) * 4;
        final pixel = Color.fromARGB(
            bytes.getUint8(index + 3),
            bytes.getUint8(index),
            bytes.getUint8(index + 1),
            bytes.getUint8(index + 2));
        final foreground =
            Color.alphaBlend(style.color!, pixel).computeLuminance();
        final background = pixel.computeLuminance();
        final ratio =
            ((foreground > background ? foreground : background) + .05) /
                ((foreground > background ? background : foreground) + .05);
        if (ratio < minimum) minimum = ratio;
      }
    }
    image.dispose();
    picture.dispose();
    return minimum;
  });
  debugPrint('SEGMENT_RELEASE_CONTRAST ${jsonEncode({
        'platform': defaultTargetPlatform.name,
        'label': label,
        'sample': sample,
        'selected': states.contains(WidgetState.selected),
        'ink': features
            .map((feature) => {
                  'type': feature.runtimeType.toString(),
                  'active': feature is InkHighlight ? feature.active : null,
                })
            .toList(),
        'contrast': minimum,
      })}');
  expect(minimum, greaterThanOrEqualTo(4.5), reason: '$label release $sample');
  expect(_queueBorder(tester).side.color, AppTheme.accent);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => HttpOverrides.global = null);

  for (final label in ['List', 'Timeline']) {
    testWidgets(
        'macOS normal-scale Queue $label combined focus hover press contrast',
        (tester) async {
      expect(defaultTargetPlatform, TargetPlatform.macOS);
      await _pumpScreen(tester, const QueueScreen(), '/queue');
      final original = tester.getRect(_switch);
      await _tabTo(tester, _segment(label));
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(_segment(label)));
      await tester.pumpAndSettle();
      await mouse.down(tester.getCenter(_segment(label)));
      await tester.pump();
      final inkContext = tester.element(
          find.descendant(of: _segment(label), matching: find.byType(InkWell)));
      final dynamic controller = Material.of(inkContext);
      final features = (controller.debugInkFeatures as List)
          .whereType<InteractiveInkFeature>()
          .toList();
      expect(features.map((feature) => feature.runtimeType.toString()),
          ['InkHighlight', 'InkHighlight', 'InkRipple', 'InkHighlight']);
      expect(
          features.whereType<InkHighlight>().every((feature) => feature.active),
          isTrue);
      var previous = 0;
      for (final elapsed in [0, 50, 150, 300]) {
        await tester.pump(Duration(milliseconds: elapsed - previous));
        previous = elapsed;
        expect(
            tester.widget<TextButton>(_segment(label)).statesController!.value,
            containsAll([
              WidgetState.focused,
              WidgetState.hovered,
              WidgetState.pressed
            ]));
        await _expectSegmentContrast(
            tester, label, 'combined-route-held-${elapsed}ms');
      }
      await tester.pumpAndSettle();
      expect(
          tester.widget<TextButton>(_segment(label)).statesController!.value,
          containsAll(
              [WidgetState.focused, WidgetState.hovered, WidgetState.pressed]));
      expect(
          features.whereType<InkHighlight>().every((feature) => feature.active),
          isTrue);
      await _expectSegmentContrast(tester, label, 'pressed');
      expect(tester.getRect(_switch), original);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  for (final label in ['List', 'Timeline']) {
    testWidgets(
        'macOS normal-scale Queue-family $label combined ink animation contrast',
        (tester) async {
      expect(defaultTargetPlatform, TargetPlatform.macOS);
      tester.view.physicalSize = const Size(960, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var callbacks = 0;
      // Queue's Timeline callback rebuilds its header and retires its ink.
      // Keep selection fixed in this native family fixture so the enabled
      // unselected segment's real release fade remains mounted and measurable.
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: SoundQDesktopTheme(
            child: Scaffold(
                body: Center(
                    child: SizedBox(
          width: 176,
          child: SegmentedButton<int>(
            key: const ValueKey('queue_view_switch'),
            segments: const [
              ButtonSegment(
                  value: 0,
                  icon: Icon(Icons.format_list_bulleted),
                  label: Text('List')),
              ButtonSegment(
                  value: 1,
                  icon: Icon(Icons.timeline),
                  label: Text('Timeline')),
            ],
            selected: const {0},
            showSelectedIcon: false,
            onSelectionChanged: (_) => callbacks++,
          ),
        )))),
      ));
      await tester.pumpAndSettle();
      final original = tester.getRect(_switch);
      await _tabTo(tester, _segment(label));
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(_segment(label)));
      await tester.pumpAndSettle();
      await mouse.down(tester.getCenter(_segment(label)));
      await tester.pump();
      final inkContext = tester.element(
          find.descendant(of: _segment(label), matching: find.byType(InkWell)));
      final dynamic controller = Material.of(inkContext);
      final features = (controller.debugInkFeatures as List)
          .whereType<InteractiveInkFeature>()
          .toList();
      expect(features.map((feature) => feature.runtimeType.toString()),
          ['InkHighlight', 'InkHighlight', 'InkRipple', 'InkHighlight']);
      expect(
          features.whereType<InkHighlight>().every((feature) => feature.active),
          isTrue);
      var previous = 0;
      for (final elapsed in [0, 50, 150, 300]) {
        await tester.pump(Duration(milliseconds: elapsed - previous));
        previous = elapsed;
        expect(
            tester.widget<TextButton>(_segment(label)).statesController!.value,
            containsAll([
              WidgetState.focused,
              WidgetState.hovered,
              WidgetState.pressed
            ]));
        await _expectSegmentContrast(
            tester, label, 'combined-held-${elapsed}ms');
      }
      await tester.pumpAndSettle();
      await _expectSegmentContrast(tester, label, 'combined-held-settled');
      await mouse.up();
      await tester.pump();
      previous = 0;
      for (final elapsed in [0, 50, 150, 300]) {
        await tester.pump(Duration(milliseconds: elapsed - previous));
        previous = elapsed;
        await _expectReleasedSegmentContrast(tester, label, '${elapsed}ms');
      }
      await tester.pumpAndSettle();
      await _expectReleasedSegmentContrast(tester, label, 'settled');
      expect(
          tester
              .widget<TextButton>(_segment(label))
              .statesController!
              .value
              .contains(WidgetState.selected),
          label == 'List');
      expect(callbacks, label == 'Timeline' ? 1 : 0);
      expect(tester.getRect(_switch), original);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  for (final label in ['List', 'Timeline']) {
    for (final state in ['resting', 'hovered', 'focused', 'pressed']) {
      testWidgets('macOS normal-scale Queue $label $state contrast',
          (tester) async {
        expect(defaultTargetPlatform, TargetPlatform.macOS);
        await _pumpScreen(tester, const QueueScreen(), '/queue');
        final original = tester.getRect(_switch);
        _expectSquare(_queueBorder(tester));
        if (state == 'focused') {
          await _tabTo(tester, _segment(label));
          await tester.pumpAndSettle();
        } else if (state != 'resting') {
          final mouse =
              await tester.createGesture(kind: PointerDeviceKind.mouse);
          await mouse.addPointer(location: Offset.zero);
          await mouse.moveTo(tester.getCenter(_segment(label)));
          await tester.pumpAndSettle();
          if (state == 'pressed') {
            await mouse.down(tester.getCenter(_segment(label)));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
          }
          addTearDown(mouse.removePointer);
        }
        await _expectSegmentContrast(tester, label, state);
        expect(tester.getRect(_switch), original);
        expect(tester.takeException(), isNull);
      }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
    }
  }

  _nativeWidgets('routed Queue paints square desktop segmented outer border',
      (tester) async {
    await _pumpScreen(tester, const QueueScreen(), '/queue');
    final border = _queueBorder(tester);
    debugPrint('queue outer border before assertion: $border');
    _expectSquare(border);
    expect(border.side.color, AppTheme.orange);
    expect(_surface(tester, _segment('List')).color, AppTheme.orange);
    expect(
        DefaultTextStyle.of(tester.element(find.text('Timeline'))).style.color,
        AppTheme.accent);
    expect(tester.takeException(), isNull);
  });

  _nativeWidgets('routed Playlists paints one square flat New playlist action',
      (tester) async {
    final http = _OfflineHttp();
    HttpOverrides.global = http;
    await _pumpScreen(tester, const PlaylistsScreen(), '/playlists');
    final create = find.widgetWithText(FilledButton, 'New playlist');
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(create, findsOneWidget);
    final material = _surface(tester, create);
    _expectSquare(material.shape! as OutlinedBorder);
    expect((material.shape! as OutlinedBorder).side.color, AppTheme.orange);
    expect(material.color, AppTheme.orange);
    expect(material.elevation, 0);
    expect(tester.getSize(create).height, greaterThanOrEqualTo(40));
    expect(create.hitTestable(), findsOneWidget);
    await tester.tap(create);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('playlist_creation_dialog')), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist_creation_source_choices')),
        findsOneWidget);
    expect(find.text('Blank playlist'), findsOneWidget);
    expect(http.paths, ['GET /api/v1/playlists']);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('playlist_creation_dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final width in [959.0, 960.0]) {
    _nativeWidgets('routed families preserve exact desktop boundary at $width',
        (tester) async {
      await _pumpScreen(tester, const QueueScreen(), '/queue', width: width);
      if (width < 960) {
        expect(_queueBorder(tester), isA<StadiumBorder>());
        expect(Theme.of(tester.element(_switch)).segmentedButtonTheme.style,
            AppTheme.darkTheme.segmentedButtonTheme.style);
      } else {
        _expectSquare(_queueBorder(tester));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      final http = _OfflineHttp();
      HttpOverrides.global = http;
      await _pumpScreen(tester, const PlaylistsScreen(), '/playlists',
          width: width);
      final fab = find.byType(FloatingActionButton);
      if (width < 960) {
        final shape = _surface(tester, fab).shape! as RoundedRectangleBorder;
        expect(shape.borderRadius, BorderRadius.circular(16));
        expect(shape.side, BorderSide.none);
        expect(Theme.of(tester.element(fab)).floatingActionButtonTheme,
            AppTheme.darkTheme.floatingActionButtonTheme);
      } else {
        expect(fab, findsNothing);
        final create = find.widgetWithText(FilledButton, 'New playlist');
        expect(create.hitTestable(), findsOneWidget);
        _expectSquare(_surface(tester, create).shape! as OutlinedBorder);
      }
      expect(tester.takeException(), isNull);
    });
  }

  _nativeWidgets(
      'compact routed Queue at 2x keeps native selection and targets',
      (tester) async {
    await _pumpScreen(tester, const QueueScreen(), '/queue', scale: 2);
    final original = tester.getRect(_switch);
    _expectSquare(_queueBorder(tester));
    for (final label in ['List', 'Timeline']) {
      final button = _segment(label);
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getSize(button).height, greaterThanOrEqualTo(40));
      expect(tester.getSize(button).width, greaterThanOrEqualTo(40));
      final text = tester.getRect(find.text(label));
      expect(text.left, greaterThanOrEqualTo(original.left));
      expect(text.right, lessThanOrEqualTo(original.right));
    }
    expect(find.byType(ReorderableListView), findsOneWidget);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(_segment('List')));
    await tester.pumpAndSettle();
    expect(_queueBorder(tester).side.color, AppTheme.accent);
    expect(_surface(tester, _segment('List')).color,
        Color.lerp(AppTheme.orange, AppTheme.textPrimary, .3));
    final listButton = tester.widget<TextButton>(_segment('List'));
    expect(listButton.statesController!.value,
        containsAll([WidgetState.selected, WidgetState.hovered]));
    final listInk = tester.widget<InkWell>(
        find.descendant(of: _segment('List'), matching: find.byType(InkWell)));
    expect(listInk.overlayColor!.resolve({WidgetState.hovered}),
        Colors.transparent);
    expect(tester.getRect(_switch), original);
    await tester.tap(_segment('Timeline'));
    await tester.pumpAndSettle();
    expect(find.text('Start playback to edit the timeline'), findsOneWidget);
    expect(find.byType(ReorderableListView), findsNothing);
    expect(
        tester.widget<TextButton>(_segment('Timeline')).statesController!.value,
        contains(WidgetState.selected));
    await mouse.removePointer();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await _tabTo(tester, _segment('List'));
    expect(_queueBorder(tester).side.color, AppTheme.accent);
    expect(tester.widget<TextButton>(_segment('List')).statesController!.value,
        contains(WidgetState.focused));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(ReorderableListView), findsOneWidget);
    expect(find.text('Start playback to edit the timeline'), findsNothing);
    expect(tester.getRect(_switch), original);
    await tester.tap(find.byTooltip('Queue actions'));
    await tester.pumpAndSettle();
    expect(find.text('Save queue as playlist').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  _nativeWidgets(
      'real New playlist retains native hover focus and keyboard action',
      (tester) async {
    HttpOverrides.global = _OfflineHttp();
    await _pumpScreen(tester, const PlaylistsScreen(), '/playlists', scale: 2);
    final create = find.widgetWithText(FilledButton, 'New playlist');
    final original = tester.getRect(create);
    InkWell ink() => tester.widget<InkWell>(
        find.descendant(of: create, matching: find.byType(InkWell)));
    expect(
        ink().overlayColor!.resolve({WidgetState.hovered}), Colors.transparent);
    Set<WidgetState> states() => ink().statesController!.value;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(create));
    await tester.pumpAndSettle();
    expect(states(), contains(WidgetState.hovered));
    expect(tester.getRect(create), original);
    _expectSquare(_surface(tester, create).shape! as OutlinedBorder);
    expect(_surface(tester, create).color, AppTheme.accent);
    expect(_surface(tester, create).elevation, 0);
    await mouse.removePointer();
    await _tabTo(tester, create);
    await tester.pumpAndSettle();
    expect(states(), contains(WidgetState.focused));
    expect(_surface(tester, create).elevation, 0);
    expect((_surface(tester, create).shape! as OutlinedBorder).side.width, 2);
    expect(tester.getRect(create), original);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('playlist_creation_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('playlist_creation_blank')));
    await tester.pumpAndSettle();
    expect(find.text('Create blank playlist'), findsOneWidget);
    expect(find.byKey(const ValueKey('playlist_creation_submit')).hitTestable(),
        findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  _nativeWidgets(
      'disabled native segments stay muted and cannot change selection',
      (tester) async {
    tester.view.physicalSize = const Size(960, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: SoundQDesktopTheme(
            child: Scaffold(
                body: Center(
                    child: SegmentedButton<int>(
                        key: const ValueKey('queue_view_switch'),
                        segments: const [
              ButtonSegment(value: 0, label: Text('List')),
              ButtonSegment(value: 1, label: Text('Timeline')),
            ],
                        selected: const {
              0
            }))))));
    await tester.pumpAndSettle();
    final disabled = Theme.of(tester.element(_switch)).disabledColor;
    expect(_queueBorder(tester).side.color, disabled);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(_segment('Timeline')));
    await tester.pumpAndSettle();
    await tester.tap(_segment('Timeline'));
    await tester.pumpAndSettle();
    expect(tester.widget<SegmentedButton<int>>(_switch).selected, {0});
    for (final label in ['List', 'Timeline']) {
      expect(tester.widget<TextButton>(_segment(label)).onPressed, isNull);
      expect(DefaultTextStyle.of(tester.element(find.text(label))).style.color,
          disabled);
      final ink = tester.widget<InkWell>(
          find.descendant(of: _segment(label), matching: find.byType(InkWell)));
      expect(
          ink.overlayColor!
              .resolve({WidgetState.disabled, WidgetState.hovered}),
          Colors.transparent);
    }
    expect(_queueBorder(tester).side.color, disabled);
    await mouse.removePointer();
    expect(tester.takeException(), isNull);
  });

  test('opaque state surfaces replace stacked native ink without alpha drift',
      () {
    final theme = SoundQDesktopTheme.apply(AppTheme.darkTheme);
    final segment = theme.segmentedButtonTheme.style!.overlayColor!;
    for (final selected in [false, true]) {
      final selection = {if (selected) WidgetState.selected};
      expect(segment.resolve(selection), Colors.transparent);
      for (final state in [WidgetState.hovered, WidgetState.focused]) {
        expect(segment.resolve({...selection, state}), Colors.transparent);
      }
      expect(segment.resolve({...selection, WidgetState.pressed}),
          Colors.transparent);
      expect(
          segment.resolve({
            ...selection,
            WidgetState.focused,
            WidgetState.hovered,
            WidgetState.pressed
          }),
          Colors.transparent);
      expect(
          segment.resolve({
            ...selection,
            WidgetState.disabled,
            WidgetState.focused,
            WidgetState.hovered,
            WidgetState.pressed
          }),
          Colors.transparent);
    }
    for (final style in [
      theme.outlinedButtonTheme.style!,
      theme.filledButtonTheme.style!,
      theme.elevatedButtonTheme.style!,
      theme.textButtonTheme.style!,
      theme.iconButtonTheme.style!,
      theme.menuButtonTheme.style!
    ]) {
      expect(style.overlayColor!.resolve({WidgetState.hovered}),
          Colors.transparent);
      expect(style.overlayColor!.resolve({WidgetState.pressed}),
          Colors.transparent);
      expect(style.backgroundColor!.resolve({WidgetState.hovered}),
          AppTheme.accent);
      expect(style.backgroundColor!.resolve({WidgetState.pressed}),
          AppTheme.textPrimary);
    }
    expect(theme.floatingActionButtonTheme.hoverColor, AppTheme.accent);
    expect(theme.floatingActionButtonTheme.focusColor, AppTheme.accent);
    expect(theme.floatingActionButtonTheme.splashColor, AppTheme.textPrimary);
  });

  test('family presentation preserves native and custom constraints', () {
    final base = AppTheme.darkTheme.copyWith(
        segmentedButtonTheme: const SegmentedButtonThemeData(
            style: ButtonStyle(
                padding: WidgetStatePropertyAll(EdgeInsets.all(13)),
                minimumSize: WidgetStatePropertyAll(Size(60, 52)),
                maximumSize: WidgetStatePropertyAll(Size(300, 70)),
                tapTargetSize: MaterialTapTargetSize.padded)),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
            sizeConstraints: BoxConstraints.tightFor(width: 64, height: 64),
            smallSizeConstraints:
                BoxConstraints.tightFor(width: 44, height: 44),
            extendedPadding: EdgeInsets.all(17),
            iconSize: 27));
    final adapted = SoundQDesktopTheme.apply(base);
    final segment = adapted.segmentedButtonTheme.style!;
    final original = base.segmentedButtonTheme.style!;
    expect(segment.padding, original.padding);
    expect(segment.minimumSize, original.minimumSize);
    expect(segment.maximumSize, original.maximumSize);
    expect(segment.tapTargetSize, original.tapTargetSize);
    expect(adapted.floatingActionButtonTheme.sizeConstraints,
        base.floatingActionButtonTheme.sizeConstraints);
    expect(adapted.floatingActionButtonTheme.smallSizeConstraints,
        base.floatingActionButtonTheme.smallSizeConstraints);
    expect(adapted.floatingActionButtonTheme.extendedPadding,
        base.floatingActionButtonTheme.extendedPadding);
    expect(adapted.floatingActionButtonTheme.iconSize, 27);
    final native = SoundQDesktopTheme.apply(AppTheme.darkTheme);
    expect(native.segmentedButtonTheme.style!.minimumSize, isNull);
    expect(native.segmentedButtonTheme.style!.padding, isNull);
    expect(native.floatingActionButtonTheme.sizeConstraints, isNull);
    expect(native.colorScheme, AppTheme.darkTheme.colorScheme);
    expect(native.textTheme.bodyMedium?.fontFamily, 'Space Grotesk');
    expect(native.textTheme.bodyMedium?.fontSize,
        AppTheme.darkTheme.textTheme.bodyMedium?.fontSize);
  });
}

class _QueueApi extends ApiClient {
  @override
  Future<QueueState> getQueue() async => QueueState.empty();
}

class _Playback extends FakePlayback {
  _Playback() {
    value = makeSnapshot(id: 'local:/fixture');
  }
  @override
  List<MediaItem> get queue => [snapshot.currentMediaItem!];
  @override
  int? get currentIndex => null;
  @override
  get playbackContext => null;
  @override
  final timelineModel = TimelineModel();
  @override
  BeatSnapMode get transitionSnapMode => BeatSnapMode.downbeat;
  @override
  int get timelinePositionMs => 0;
  @override
  Duration get position => Duration.zero;
  @override
  bool get isPlaying => false;
  @override
  bool get hasTrack => false;
  @override
  bool get canSkipNext => false;
  @override
  bool get hasPreviousInPlayOrder => false;
}

// Same socket-free transport seam as desktop_playlist_density_test. Real
// PlaylistsScreen still constructs its production API and playlist services.
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
    paths.add('$method ${url.path}');
    if (method != 'GET' || url.path != '/api/v1/playlists') {
      throw StateError('Unexpected $method $url');
    }
    return _Request({
      'playlists': [
        {
          'id': 1,
          'name': 'Control fixture',
          'track_count': 0,
          'created_at': '2026-01-01T00:00:00Z',
          'updated_at': '2026-01-01T00:00:00Z',
        }
      ],
      'total': 1,
      'limit': 50,
      'offset': 0,
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
  Future<void> addStream(Stream<List<int>> stream) async =>
      stream.drain<void>();
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
