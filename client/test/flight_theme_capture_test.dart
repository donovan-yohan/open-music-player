import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';

import 'flight_theme_typography_test.dart' show loadFlightFonts;

void main() {
  const output = String.fromEnvironment('FLIGHT_THEME_CAPTURE_DIR');
  testWidgets('real font themed control matrix receipts', (tester) async {
    expect(defaultTargetPlatform, TargetPlatform.macOS);
    await loadFlightFonts(tester);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final states = WidgetStatesController();
    addTearDown(states.dispose);
    Future<void> save(String name) async {
      await tester.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        await File('$output/$name.png').create(recursive: true);
        await File('$output/$name.png')
            .writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    }

    for (final width in [960.0, 1200.0, 1440.0, 2560.0]) {
      for (final scale in [1.0, 2.0]) {
        tester.view.physicalSize = Size(width, 900);
        await tester.pumpWidget(MaterialApp(
            theme: AppTheme.darkTheme,
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!),
            home: SoundQDesktopTheme(
                child: RepaintBoundary(
                    key: boundary,
                    child: Scaffold(
                        body: Padding(
                            padding: const EdgeInsets.all(24),
                            child: ListView(children: [
                              Text('Sound Q',
                                  style: SoundQDesktopTheme.apply(
                                          AppTheme.darkTheme)
                                      .textTheme
                                      .headlineLarge),
                              const Divider(),
                              const Text('Library / Recently played'),
                              const SizedBox(height: 24),
                              Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    FilledButton(
                                        onPressed: () {},
                                        child: const Text('Play now')),
                                    OutlinedButton(
                                        focusNode: focus,
                                        statesController: states,
                                        onPressed: () {},
                                        child: const Text('Add to playlist')),
                                    TextButton(
                                        onPressed: () {},
                                        child: const Text('Clear')),
                                    const OutlinedButton(
                                        onPressed: null,
                                        child: Text('Unavailable')),
                                    IconButton(
                                        onPressed: () {},
                                        tooltip: 'More actions',
                                        icon: const Icon(Icons.more_horiz)),
                                    IconButton(
                                        visualDensity: VisualDensity.compact,
                                        onPressed: () {},
                                        tooltip: 'Like',
                                        icon:
                                            const Icon(Icons.favorite_border)),
                                    const IconButton(
                                        onPressed: null,
                                        tooltip: 'Unavailable icon',
                                        icon: Icon(Icons.skip_next)),
                                  ]),
                              const SizedBox(height: 24),
                              Wrap(
                                  spacing: 16,
                                  runSpacing: 8,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    SegmentedButton<int>(
                                        segments: const [
                                          ButtonSegment(
                                              value: 0,
                                              icon: Icon(
                                                  Icons.format_list_bulleted),
                                              label: Text('List')),
                                          ButtonSegment(
                                              value: 1,
                                              icon: Icon(Icons.timeline),
                                              label: Text('Timeline')),
                                        ],
                                        selected: const {
                                          0
                                        },
                                        showSelectedIcon: false,
                                        onSelectionChanged: (_) {}),
                                    FilterChip(
                                        selected: true,
                                        label: const Text('Downloaded'),
                                        onSelected: (_) {}),
                                    FilterChip(
                                        label: const Text('Verified'),
                                        onSelected: (_) {}),
                                  ]),
                              const SizedBox(height: 24),
                              const TextField(
                                  decoration: InputDecoration(
                                      labelText: 'Search library',
                                      hintText: 'Title, artist or album')),
                              const SizedBox(height: 24),
                              const Text('01:24 / 05:32    124.00 BPM',
                                  style: TextStyle(
                                      fontFamily: 'IBM Plex Mono',
                                      fontSize: 14,
                                      fontFeatures: [
                                        ui.FontFeature.tabularFigures()
                                      ])),
                              const Divider(),
                              const Text('Glasshouse — The night shift'),
                            ])))))));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await save('matrix-${width.toInt()}-${scale.toInt()}x-rest');
      }
    }
    // Real native pointer + focus + held press; no synthetic action/controller.
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpAndSettle();
    final button = find.widgetWithText(OutlinedButton, 'Add to playlist');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(button));
    await tester.pumpAndSettle();
    expect(states.value, contains(WidgetState.hovered));
    await save('matrix-hover');
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(
        states.value, containsAll([WidgetState.hovered, WidgetState.focused]));
    await save('matrix-focus-hover');
    await mouse.down(tester.getCenter(button));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(
        states.value,
        containsAll(
            [WidgetState.hovered, WidgetState.focused, WidgetState.pressed]));
    await save('matrix-focus-hover-held');
    await mouse.up();
    await tester.pumpAndSettle();
    await save('matrix-release');
  },
      skip: output.isEmpty,
      variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
