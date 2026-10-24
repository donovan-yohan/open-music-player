import 'package:provider/provider.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'song_row_presentation_test.dart' show FakePlayback, makeSnapshot;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/shared/models/playlist.dart';
import 'package:open_music_player/shared/widgets/playlist_card.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/widgets/song_metadata_chips.dart';
import 'package:open_music_player/shared/widgets/song_list_item.dart';
import 'package:open_music_player/shared/widgets/track_artwork.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';

final _theme = ThemeData.dark(useMaterial3: true).copyWith(
  colorScheme: const ColorScheme.dark(
    primary: Color(0xFFFF5A00),
    secondary: Color(0xFF39C6B6),
  ),
);

Future<void> _pump(WidgetTester tester, Widget child,
    {double width = 1440, double scale = 1, double? slotWidth}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: _theme,
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 1100),
          textScaler: TextScaler.linear(scale),
        ),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: slotWidth, child: child),
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets(
      'desktop action focus and held pointer survive canonical selection changes',
      (tester) async {
    final playback = FakePlayback()..set(makeSnapshot(id: null));
    addTearDown(playback.dispose);
    var activated = 0;
    await _pump(
        tester,
        ChangeNotifierProvider<PlaybackState>.value(
          value: playback,
          child: TrackTile(
            trackId: 'A',
            title: 'Track A',
            duration: '3:00',
            onTap: () {},
            action: IconButton(
                key: const ValueKey('stable_action'),
                icon: const Icon(Icons.favorite),
                onPressed: () => activated++),
          ),
        ));
    final action = find.byKey(const ValueKey('stable_action'));
    final element = tester.element(action);
    final node = Focus.of(tester.element(
        find.descendant(of: action, matching: find.byIcon(Icons.favorite))));
    node.requestFocus();
    await tester.pump();
    for (final id in ['A', 'B', null]) {
      playback.set(makeSnapshot(id: id));
      await tester.pump();
      expect(tester.element(action), same(element));
      expect(node.hasFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
    }
    expect(activated, 3);
    final press = await tester.startGesture(tester.getCenter(action));
    for (final id in ['A', 'B', null]) {
      playback.set(makeSnapshot(id: id));
      await tester.pump();
    }
    await press.up();
    await tester.pump();
    expect(activated, 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop default artwork paints square corners with Ink',
      (tester) async {
    await _pump(tester, const TrackTile(title: 'No artwork', duration: '3:00'));
    final art = find.byType(TrackArtwork);
    final backing = find.ancestor(of: art, matching: find.byType(Ink));
    expect(backing, findsOneWidget);
    expect(tester.widget<Ink>(backing).decoration, isA<BoxDecoration>());
    expect((tester.widget<Ink>(backing).decoration! as BoxDecoration).color,
        _theme.colorScheme.surfaceContainerHighest);
  });

  testWidgets('desktop metadata is square without changing Camelot meaning',
      (tester) async {
    final analysis = TrackAnalysis.fromJson(status: 'analyzed', summary: {
      'bpm': {'value': 128},
      'camelot': {'value': '8A'},
    });
    BoxDecoration decorationFor(String label) => tester
        .widget<Container>(
          find
              .ancestor(of: find.text(label), matching: find.byType(Container))
              .first,
        )
        .decoration! as BoxDecoration;
    await _pump(tester, SongMetadataChips(analysis: analysis), width: 959);
    final mobileKey = decorationFor('8A').color;
    expect(decorationFor('128 BPM').borderRadius, BorderRadius.circular(4));
    await _pump(tester, SongMetadataChips(analysis: analysis));
    expect(decorationFor('8A').color, mobileKey);
    expect(decorationFor('128 BPM').borderRadius, BorderRadius.zero);
  });

  testWidgets('desktop PlaylistCard uses square outlined cyan interactive ink',
      (tester) async {
    var taps = 0;
    await _pump(
        tester,
        SizedBox(
            width: 200,
            height: 220,
            child: PlaylistCard(
                playlist: Playlist(
                    id: 1,
                    name: 'Set',
                    createdAt: DateTime.utc(2026),
                    updatedAt: DateTime.utc(2026)),
                onTap: () => taps++)));
    final card = tester.widget<Card>(find.byType(Card));
    expect(card.shape, isA<RoundedRectangleBorder>());
    final shape = card.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.zero);
    expect(shape.side.width, 1);
    expect(tester.widget<Icon>(find.byIcon(Icons.queue_music)).color,
        _theme.colorScheme.secondary);
    expect(find.byType(Ink), findsWidgets);
    final ink = tester.widget<InkWell>(find.byType(InkWell));
    expect(
        ink.overlayColor!.resolve({WidgetState.hovered}), Colors.transparent);
    expect(
        ink.overlayColor!.resolve({WidgetState.focused}), Colors.transparent);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop row pointer and keyboard focus paint cyan outline',
      (tester) async {
    var taps = 0;
    await _pump(
      tester,
      TrackTile(
        title: 'Focusable track',
        duration: '3:00',
        onTap: () => taps++,
      ),
    );
    final surface = find.byKey(const ValueKey('song_list_item_outline'));
    expect(surface, findsOneWidget);
    BoxDecoration decoration() =>
        tester.widget<Ink>(surface).decoration! as BoxDecoration;
    expect(decoration().border!.bottom.width, 1);
    expect(decoration().color, isNull);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1200, 900));
    await mouse.moveTo(tester.getCenter(find.text('Focusable track')));
    await tester.pumpAndSettle();
    expect(decoration().border!.top.color, _theme.colorScheme.secondary);
    expect(decoration().color, _theme.colorScheme.outline);
    await mouse.removePointer();
    await tester.pumpAndSettle();
    expect(decoration().color, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(decoration().border!.top.color, _theme.colorScheme.secondary);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('non-actionable desktop row has no hover or focus feedback',
      (tester) async {
    await _pump(tester, const TrackTile(title: 'Read only', duration: '3:00'));
    final surface = find.byKey(const ValueKey('song_list_item_outline'));
    final before = tester.widget<Ink>(surface).decoration;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(1200, 900));
    await mouse.moveTo(tester.getCenter(find.text('Read only')));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(tester.widget<Ink>(surface).decoration, before);
    await mouse.removePointer();
  });

  for (final width in [959.0, 960.0, 1440.0, 2560.0]) {
    testWidgets('enlarged canonical metadata and actions remain whole $width',
        (tester) async {
      await _pump(
          tester,
          TrackTile(
            title: 'Track title',
            artist: 'Artist',
            duration: '3:00',
            onTap: () {},
            onMorePressed: () {},
            action: IconButton(
                tooltip: 'Like',
                icon: const Icon(Icons.favorite_border),
                onPressed: () {}),
            analysis: TrackAnalysis.fromJson(status: 'analyzed', summary: {
              'bpm': {'value': 128},
              'camelot': {'value': '8A'},
            }),
          ),
          width: width,
          scale: 2,
          slotWidth: 420);
      expect(tester.getSize(find.byType(SongListItem)).height,
          greaterThan(width >= 960 ? 56 : 72));
      expect(find.text('128 BPM'), findsOneWidget);
      expect(find.text('8A'), findsOneWidget);
      expect(find.text('3:00'), findsOneWidget);
      expect(find.byTooltip('Like'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets('canonical TrackTile geometry at window $width',
        (tester) async {
      await _pump(
        tester,
        TrackTile(
          title: 'Track title',
          artist: 'Artist',
          duration: '3:00',
          onTap: () {},
          onMorePressed: () {},
        ),
        width: width,
        // A narrow desktop pane must not select the mobile density.
        slotWidth: 420,
      );
      final desktop = width >= 960;
      final row = find.byType(SongListItem);
      expect(tester.getSize(row).height, desktop ? 56 : 72);
      final art = tester.widget<TrackArtwork>(find.byType(TrackArtwork));
      expect(art.width, desktop ? 40 : 48);
      expect(art.height, desktop ? 40 : 48);
      expect(art.borderRadius,
          desktop ? BorderRadius.zero : BorderRadius.circular(4));
      expect(tester.getTopLeft(find.byType(TrackArtwork)).dx, desktop ? 8 : 16);
      expect(tester.getTopLeft(find.text('Track title')).dx, desktop ? 56 : 76);
      expect(tester.takeException(), isNull);
    });
  }
}
