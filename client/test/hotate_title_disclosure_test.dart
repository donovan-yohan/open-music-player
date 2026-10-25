import 'package:audio_service/audio_service.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/shared/models/playlist.dart';
import 'package:open_music_player/shared/widgets/playlist_card.dart';

import 'desktop_listening_transport_test.dart'
    show DesktopPlayback, pumpListeningApp;
import 'flight_controls_geometry_test.dart' show loadFlightFonts;

const _title =
    'An unabridged recording from the northern observatory — evening session';
const _artist =
    'The very long named ensemble with guests from the southern observatory';
const _identityKey = ValueKey('soundq_desktop_track_title');

class _FallbackPlayback extends DesktopPlayback {
  @override
  MediaItem get item =>
      const MediaItem(id: 'fallback', title: '夜の音楽 — Répétition');
}

class _CancelFailurePlayback extends DesktopPlayback {
  @override
  Future<void> pause() async {
    calls.add('pause');
    throw StateError('controlled cancellation failure');
  }
}

const _playlistName =
    'Recordings for a very long journey through the northern and southern observatories';

Future<void> _pumpPlaylist(WidgetTester tester,
    {required bool card,
    VoidCallback? onTap,
    Widget? trailing,
    double width = 960,
    double scale = 1}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final playlist = Playlist(
      id: 1,
      name: _playlistName,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026));
  await tester.pumpWidget(MaterialApp(
    theme: SoundQDesktopTheme.apply(AppTheme.darkTheme),
    builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!),
    home: Scaffold(
        body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
                width: 220,
                height: card ? 280 : null,
                child: card
                    ? PlaylistCard(playlist: playlist, onTap: onTap)
                    : PlaylistListTile(
                        playlist: playlist,
                        onTap: onTap,
                        trailing: trailing)))),
  ));
  await tester.pumpAndSettle();
}

Iterable<SemanticsNode> _semanticNodes(WidgetTester tester) sync* {
  SemanticsNode? root;
  tester.binding.rootPipelineOwner.visitChildren((owner) {
    root ??= owner.semanticsOwner?.rootSemanticsNode;
  });
  if (root == null) return;
  final nodes = <SemanticsNode>[root!];
  while (nodes.isNotEmpty) {
    final node = nodes.removeLast();
    yield node;
    node.visitChildren((child) {
      nodes.add(child);
      return true;
    });
  }
}

void _expectFullAccessibleName(WidgetTester tester, String name) {
  expect(_semanticNodes(tester).where((n) => n.label.contains(name)),
      hasLength(1));
  expect(
      _semanticNodes(tester)
          .where((n) => n.getSemanticsData().tooltip.contains(name)),
      isEmpty,
      reason: 'Do not announce existing full text twice');
}

Rect _expectFullTooltip(WidgetTester tester, Finder finder, double width) {
  expect(finder, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  expect(paragraph.didExceedMaxLines, isFalse);
  expect(paragraph.maxLines, isNull);
  expect(paragraph.overflow, isNot(TextOverflow.ellipsis));
  final full = TextPainter(
      text: paragraph.text,
      textDirection: TextDirection.ltr,
      textScaler: paragraph.textScaler)
    ..layout(maxWidth: paragraph.size.width);
  expect(paragraph.size.height, closeTo(full.height, .1));
  full.dispose();
  final glyphs = paragraph.getBoxesForSelection(TextSelection(
      baseOffset: 0, extentOffset: paragraph.text.toPlainText().length));
  expect(glyphs, isNotEmpty);
  for (final box in glyphs) {
    expect(box.right, lessThanOrEqualTo(paragraph.size.width + .1));
    expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + .1));
  }
  final bounds = tester.getRect(finder);
  expect(bounds.left, greaterThanOrEqualTo(0));
  expect(bounds.right, lessThanOrEqualTo(width));
  expect(bounds.top, greaterThanOrEqualTo(0));
  expect(bounds.bottom, lessThanOrEqualTo(900));
  final box = find
      .ancestor(
          of: finder,
          matching: find.byWidgetPredicate((w) =>
              w is DecoratedBox &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).border != null))
      .first;
  final decoration =
      tester.widget<DecoratedBox>(box).decoration as BoxDecoration;
  final painted = tester.getRect(box);
  expect(painted.width, lessThanOrEqualTo(480));
  expect(painted.left, greaterThanOrEqualTo(0));
  expect(painted.right, lessThanOrEqualTo(width));
  expect(painted.top, greaterThanOrEqualTo(0));
  expect(painted.bottom, lessThanOrEqualTo(900));
  expect(decoration.boxShadow ?? [], isEmpty);
  final foreground = paragraph.text.style!.color!;
  final background = decoration.color!;
  final a = foreground.computeLuminance();
  final b = background.computeLuminance();
  final ratio = a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05);
  expect(ratio, greaterThanOrEqualTo(4.5));
  return painted;
}

Finder _playlistDisclosure() => find.descendant(
    of: find.byWidgetPredicate(
        (w) => w is Text && w.textSpan?.toPlainText() == _playlistName),
    matching: find.byType(RichText));

Finder _disclosure(String text) => find.byWidgetPredicate(
    (w) => w is RichText && w.text.toPlainText().contains(text));

Future<void> _tabToIdentity(WidgetTester tester) async {
  // Enter the dock's focus region, then traverse back from its native neighbor.
  Focus.of(tester.element(find.byKey(_identityKey))).requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
  expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<InkWell>(),
      tester.widget(find
          .ancestor(
              of: find.byKey(_identityKey), matching: find.byType(InkWell))
          .first));
}

void main() {
  testWidgets('short playlist names need no redundant floating label',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(960, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 240,
                height: 240,
                child: PlaylistCard(
                    onTap: () {},
                    playlist:
                        Playlist.fromJson({'id': 3, 'name': 'Rotation'}))))));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(find.text('Rotation'), findsOneWidget);
  });

  testWidgets('pending, ended and fallback disclosure mirrors canonical labels',
      (tester) async {
    await loadFlightFonts(tester);
    final playback = DesktopPlayback(title: _title, artist: _artist)
      ..pending = true;
    await pumpListeningApp(tester, playback, size: const Size(960, 900));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Starting playback…')));
    await tester.pumpAndSettle();
    expect(_disclosure('Starting playback…'), findsNWidgets(2));
    expect(_disclosure(_title), findsNothing);
    expect(find.byTooltip('Cancel playback'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancel playback'));
    await tester.pump();
    expect(playback.calls, ['pause']);
    playback.pending = false;
    playback.playing = false;
    playback.continuation = ContinuationDisposition.completed;
    playback.changed();
    await tester.pumpAndSettle();
    await _tabToIdentity(tester);
    await tester.pumpAndSettle();
    expect(_disclosure('Queue ended\n$_title\n$_artist'), findsOneWidget);
    expect(find.byTooltip('Replay'), findsOneWidget);
    await mouse.removePointer();
  });

  testWidgets('missing artist retains full title and Unknown Artist fallback',
      (tester) async {
    await loadFlightFonts(tester);
    final playback = _FallbackPlayback();
    await pumpListeningApp(tester, playback, size: const Size(960, 900));
    await _tabToIdentity(tester);
    await tester.pumpAndSettle();
    expect(
        _disclosure('${playback.item.title}\nUnknown Artist'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel failure keeps the existing accurate error message',
      (tester) async {
    final playback = _CancelFailurePlayback()..pending = true;
    await pumpListeningApp(tester, playback, size: const Size(960, 900));
    await tester.tap(find.byTooltip('Cancel playback'));
    await tester.pumpAndSettle();
    expect(playback.calls, ['pause']);
    expect(find.text('Could not pause playback. Please try again.'),
        findsOneWidget);
    expect(find.text('Starting playback…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final card in [true, false]) {
    testWidgets(
        'mobile ${card ? 'card' : 'row'} adds no disclosure or Tab stop',
        (tester) async {
      await _pumpPlaylist(tester, card: card, width: 959, onTap: () {});
      expect(find.byType(Tooltip), findsNothing);
      expect(find.byType(ListTile), card ? findsNothing : findsOneWidget);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text(_playlistName)));
      await tester.pumpAndSettle();
      expect(_playlistDisclosure(), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_playlistDisclosure(), findsNothing);
      await mouse.removePointer();
    });

    testWidgets(
        'unavailable ${card ? 'card' : 'row'} name remains readable by pointer',
        (tester) async {
      await _pumpPlaylist(tester, card: card);
      final ink = tester.widget<InkWell>(find.byType(InkWell));
      expect(ink.onTap, isNull);
      final before =
          tester.getRect(find.byType(card ? PlaylistCard : PlaylistListTile));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text(_playlistName)));
      await tester.pumpAndSettle();
      expect(_playlistDisclosure(), findsOneWidget);
      expect(
          tester.getRect(find.byType(card ? PlaylistCard : PlaylistListTile)),
          before);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_playlistDisclosure(), findsNothing);
    });
  }

  testWidgets('playlist disclosure retires before keyboard context menu opens',
      (tester) async {
    await loadFlightFonts(tester);
    await _pumpPlaylist(tester,
        card: false,
        onTap: () {},
        trailing: PopupMenuButton<String>(
            tooltip: 'Playlist actions',
            itemBuilder: (_) =>
                [const PopupMenuItem(value: 'rename', child: Text('Rename'))]));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_playlistDisclosure(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_playlistDisclosure(), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
    expect(_playlistDisclosure(), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  for (final width in [960.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('full metadata reflows with real fonts $width ${scale}x',
          (tester) async {
        await loadFlightFonts(tester);
        final semantics = tester.ensureSemantics();
        await pumpListeningApp(
            tester, DesktopPlayback(title: _title, artist: _artist),
            size: Size(width, 900), textScale: scale);
        final title = tester.renderObject<RenderParagraph>(find.descendant(
            of: find.byKey(_identityKey), matching: find.byType(RichText)));
        expect(title.text.style?.fontFamily, 'Space Grotesk');
        final before = tester.getRect(find.byTooltip('Open now playing'));
        final bank = tester
            .getRect(find.byKey(const ValueKey('soundq_desktop_command_row')));
        _expectFullAccessibleName(tester, _title);
        _expectFullAccessibleName(tester, _artist);
        await _tabToIdentity(tester);
        await tester.pumpAndSettle();
        final disclosure = _disclosure('$_title\n$_artist');
        final tooltipRect = _expectFullTooltip(tester, disclosure, width);
        expect(
            tooltipRect.bottom,
            lessThan(tester
                .getRect(find.byKey(const ValueKey('soundq_desktop_transport')))
                .top));
        expect(tester.getRect(find.byTooltip('Open now playing')), before);
        expect(
            tester.getRect(
                find.byKey(const ValueKey('soundq_desktop_command_row'))),
            bank);
        expect(bank.center.dx, closeTo(width / 2, .01));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(find.text('page_player'), findsOneWidget);
        expect(disclosure, findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      });

      for (final card in [true, false]) {
        testWidgets(
            'full playlist ${card ? 'card' : 'row'} reflows $width ${scale}x',
            (tester) async {
          await loadFlightFonts(tester);
          final semantics = tester.ensureSemantics();
          await _pumpPlaylist(tester,
              card: card, width: width, scale: scale, onTap: () {});
          _expectFullAccessibleName(tester, _playlistName);
          final before = tester
              .getRect(find.byType(card ? PlaylistCard : PlaylistListTile));
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          _expectFullTooltip(tester, _playlistDisclosure(), width);
          expect(
              tester
                  .getRect(find.byType(card ? PlaylistCard : PlaylistListTile)),
              before);
          final mouse =
              await tester.createGesture(kind: PointerDeviceKind.mouse);
          await mouse.addPointer(location: const Offset(800, 400));
          await mouse.moveTo(tester.getCenter(find
              .byWidgetPredicate((w) => w is Text && w.data == _playlistName)));
          await tester.pumpAndSettle();
          await mouse.moveTo(const Offset(800, 400));
          await tester.pumpAndSettle();
          expect(_playlistDisclosure(), findsOneWidget,
              reason: 'Pointer exit must not hide the keyboard disclosure');
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          expect(_playlistDisclosure(), findsNothing);
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
          expect(_playlistDisclosure(), findsNothing);
          await mouse.removePointer();
          expect(tester.takeException(), isNull);
          semantics.dispose();
        });
      }
    }
  }

  for (final card in [true, false]) {
    testWidgets(
        'playlist ${card ? 'card' : 'row'} recovers full name on hover and Tab',
        (tester) async {
      await loadFlightFonts(tester);
      var opens = 0;
      await _pumpPlaylist(tester, card: card, onTap: () => opens++);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text(_playlistName)));
      await tester.pumpAndSettle();
      expect(_playlistDisclosure(), findsOneWidget);
      await mouse.moveTo(const Offset(800, 400));
      await tester.pumpAndSettle();
      expect(_playlistDisclosure(), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(_playlistDisclosure(), findsOneWidget);
      expect(opens, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opens, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(opens, 2);
      await mouse.removePointer();
    });
  }

  testWidgets('transport hover discloses complete title and artist above dock',
      (tester) async {
    await loadFlightFonts(tester);
    await pumpListeningApp(
        tester, DesktopPlayback(title: _title, artist: _artist),
        size: const Size(960, 900));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(_identityKey)));
    await tester.pumpAndSettle();
    final disclosure = _disclosure('$_title\n$_artist');
    expect(disclosure, findsOneWidget,
        reason: 'A generic Open now playing tooltip cannot recover metadata');
    final bounds = tester.getRect(disclosure);
    final dock =
        tester.getRect(find.byKey(const ValueKey('soundq_desktop_transport')));
    expect(bounds.bottom, lessThan(dock.top));
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(960));
    expect(tester.takeException(), isNull);
    await mouse.removePointer();
  });

  testWidgets('Tab discloses metadata without routing or extra focus targets',
      (tester) async {
    await loadFlightFonts(tester);
    final playback = DesktopPlayback(title: _title, artist: _artist);
    final router =
        await pumpListeningApp(tester, playback, size: const Size(960, 900));
    await _tabToIdentity(tester);
    await tester.pumpAndSettle();
    expect(_disclosure('$_title\n$_artist'), findsOneWidget);
    expect(router.routeInformationProvider.value.uri.path, '/home');
    expect(playback.calls, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_disclosure('$_title\n$_artist'), findsNothing);
    expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<IconButton>()
            ?.tooltip,
        'Toggle shuffle');
    expect(tester.takeException(), isNull);
  });

  testWidgets('focused metadata survives pointer exit from text to artwork',
      (tester) async {
    await loadFlightFonts(tester);
    await pumpListeningApp(
        tester, DesktopPlayback(title: _title, artist: _artist),
        size: const Size(960, 900));
    await _tabToIdentity(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(_identityKey)));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.descendant(
        of: find.byTooltip('Open now playing'),
        matching: find.byType(ClipRRect))));
    await tester.pumpAndSettle();
    expect(_disclosure('$_title\n$_artist'), findsOneWidget);
    await mouse.removePointer();
  });
}
