import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/router.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/screens/queue_screen.dart';
import 'package:open_music_player/shared/widgets/app_snack_bar.dart';
import 'package:provider/provider.dart';

import 'desktop_listening_transport_test.dart' show pumpListeningApp;
import 'flight_controls_geometry_test.dart'
    show
        FlightPlayback,
        FlightQueueApi,
        flightButton,
        flightPaint,
        loadFlightFonts;
import 'flight_core_independent_review_test.dart' show surface, tabTo;

class _SelectablePlayback extends FlightPlayback {
  _SelectablePlayback() {
    selectedShuffle = true;
  }

  var repeat = LoopMode.all;
  var trackAvailable = true;
  @override
  LoopMode get loopMode => repeat;
  @override
  bool get hasTrack => trackAvailable;
  @override
  Future<void> toggleShuffle() async {
    calls.add('shuffle');
    selectedShuffle = !selectedShuffle;
    changed();
  }

  @override
  Future<void> cycleLoopMode() async {
    calls.add('repeat');
    repeat = switch (repeat) {
      LoopMode.off => LoopMode.all,
      LoopMode.all => LoopMode.one,
      LoopMode.one => LoopMode.off,
    };
    changed();
  }
}

Future<void> _mount(WidgetTester tester, _SelectablePlayback playback,
    {double width = 1200}) async {
  await loadFlightFonts(tester);
  final queue = QueueProvider(FlightQueueApi());
  addTearDown(queue.dispose);
  await pumpListeningApp(tester, playback,
      size: Size(width, 900),
      content: const QueueScreen(),
      shellBuilder: (child) => ChangeNotifierProvider<QueueProvider>.value(
          value: queue,
          child: SoundQDesktopTheme(
              child:
                  AppFeedbackTheme(child: ScaffoldWithNavBar(child: child)))));
}

void _selectedIdentity(WidgetTester tester, Finder button) {
  final widget = tester.widget<IconButton>(button);
  expect(widget.color, isNull, reason: 'no widget-level static color pin');
  expect(widget.isSelected, isTrue,
      reason: 'native selection owns presentation');
  final ink = tester.widget<InkWell>(
      find.descendant(of: button, matching: find.byType(InkWell)).first);
  final states = ink.statesController!.value;
  expect(states, contains(WidgetState.selected));
  final theme = Theme.of(tester.element(button));
  final fill = surface(tester, button).color;
  expect(fill, theme.iconButtonTheme.style!.backgroundColor!.resolve(states));
  expect(
      fill,
      isNot(theme.iconButtonTheme.style!.backgroundColor!
          .resolve({...states}..remove(WidgetState.selected))),
      reason: 'selected surface stays distinct during the same interaction');
}

void main() {
  for (final (label, call) in [
    ('Toggle shuffle', 'shuffle'),
    ('Cycle repeat mode', 'repeat'),
  ]) {
    testWidgets('$label native selected identity persists through hold release',
        (tester) async {
      final playback = _SelectablePlayback();
      await _mount(tester, playback);
      final button = flightButton(label);
      final bounds = flightPaint(tester, button);
      final theme = Theme.of(tester.element(button));
      _selectedIdentity(tester, button);
      expect(surface(tester, button).color, theme.colorScheme.primary);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tabTo(tester, button);
      await mouse.moveTo(tester.getCenter(button));
      await tester.pumpAndSettle();
      _selectedIdentity(tester, button);
      final focusedShape = surface(tester, button).shape! as OutlinedBorder;
      expect(focusedShape.side.width, 2);
      expect(focusedShape.side.color, theme.colorScheme.secondary);
      await mouse.down(tester.getCenter(button));
      await tester.pump();
      for (final ms in [0, 50, 100, 150, 500]) {
        await tester.pump(Duration(milliseconds: ms));
        _selectedIdentity(tester, button);
        final ink = tester.widget<InkWell>(
            find.descendant(of: button, matching: find.byType(InkWell)).first);
        expect(
            ink.statesController!.value,
            containsAll([
              WidgetState.focused,
              WidgetState.hovered,
              WidgetState.pressed
            ]));
        expect(flightPaint(tester, button), bounds);
        expect(playback.calls, isEmpty);
      }
      await mouse.up();
      await tester.pump();
      // Repeat all -> one remains selected; shuffle's native action deselects.
      expect(playback.calls, [call]);
      expect(tester.widget<IconButton>(button).isSelected, call == 'repeat');
      if (call == 'repeat') _selectedIdentity(tester, button);
      await mouse.moveTo(Offset.zero);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      if (call == 'repeat') {
        expect(surface(tester, button).color, theme.colorScheme.primary);
        await tabTo(tester, button);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(playback.repeat, LoopMode.off);
      } else {
        await tabTo(tester, button);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(playback.selectedShuffle, isTrue);
      }
      expect(playback.calls, [call, call]);
      expect(flightPaint(tester, button), bounds);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('$label selected disabled keeps geometry and native guard',
        (tester) async {
      final playback = _SelectablePlayback();
      await _mount(tester, playback);
      final button = flightButton(label);
      final bounds = flightPaint(tester, button);
      playback.trackAvailable = false;
      playback.changed();
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(button).isSelected, isTrue);
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      expect(flightPaint(tester, button), bounds);
      expect(bounds.size, const Size(48, 48));
      final muted = surface(tester, button);
      final theme = Theme.of(tester.element(button));
      expect(muted.color, theme.colorScheme.surface);
      final border = (muted.shape! as OutlinedBorder).side;
      expect(border.width, 1);
      expect(border.color.a, greaterThan(0));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(button));
      await mouse.down(tester.getCenter(button));
      await tester.pumpAndSettle();
      expect(surface(tester, button).color, muted.color);
      await mouse.up();
      await tester.pumpAndSettle();
      expect(playback.calls, isEmpty);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets('Queue More native keyboard open Escape and mobile literal style',
      (tester) async {
    await _mount(tester, _SelectablePlayback());
    final menu = find.byKey(const ValueKey('playback_queue_menu'));
    final button = find.descendant(of: menu, matching: find.byType(IconButton));
    await tabTo(tester, button);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Save queue as playlist'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Save queue as playlist'), findsNothing);
    expect(button, findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets('Queue More below 960 retains original literal mobile style',
      (tester) async {
    await _mount(tester, _SelectablePlayback(), width: 959);
    final menu = tester.widget<PopupMenuButton<String>>(
        find.byKey(const ValueKey('playback_queue_menu')));
    final theme = Theme.of(
        tester.element(find.byKey(const ValueKey('playback_queue_menu'))));
    expect(menu.iconColor, theme.colorScheme.onPrimary);
    expect(menu.iconSize, isNull);
    expect(menu.style!.foregroundColor, isNull);
    expect(menu.style!.iconColor, isNull);
    expect(menu.style!.overlayColor, isNull);
    expect(menu.style!.minimumSize!.resolve({}), const Size(40, 40));
    expect(menu.style!.tapTargetSize, MaterialTapTargetSize.shrinkWrap);
    expect(
        find.byKey(const ValueKey('soundq_desktop_transport')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
