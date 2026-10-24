import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/shared/models/playlist.dart';
import 'package:open_music_player/shared/widgets/playlist_card.dart';
import 'desktop_listening_transport_test.dart'
    show DesktopPlayback, pumpListeningApp;
import 'flight_controls_geometry_test.dart' show loadFlightFonts;

const name = 'Recordings for a long journey through the observatory';
Finder disclosure(String value) => find.byWidgetPredicate((w) =>
    w is RichText && w.text.toPlainText() == value && w.maxLines == null);

class UpdatingPlayback extends DesktopPlayback {
  String revisedTitle =
      'Original metadata with the existing playback occurrence';
  @override
  MediaItem get item => MediaItem(
      id: '39',
      title: revisedTitle,
      artist: 'Artist',
      duration: const Duration(minutes: 4));
}

void main() {
  testWidgets('same-occurrence metadata updates retain focused disclosure',
      (tester) async {
    await loadFlightFonts(tester);
    final playback = UpdatingPlayback();
    await pumpListeningApp(tester, playback, size: const Size(1440, 900));
    final focus = Focus.of(tester
        .element(find.byKey(const ValueKey('soundq_desktop_track_title'))));
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(disclosure('${playback.revisedTitle}\nArtist'), findsOneWidget);
    playback.revisedTitle =
        'Updated full recording metadata from the same occurrence';
    playback.changed();
    await tester.pumpAndSettle();
    expect(focus.hasPrimaryFocus, isTrue);
    expect(disclosure('${playback.revisedTitle}\nArtist'), findsOneWidget);
    expect(
        disclosure(
            'Original metadata with the existing playback occurrence\nArtist'),
        findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final card in [true, false]) {
    testWidgets(
        'focused ${card ? 'card' : 'row'} discloses after genuine truncation threshold resize',
        (tester) async {
      await loadFlightFonts(tester);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final width = ValueNotifier(220.0);
      addTearDown(width.dispose);
      var opens = 0;
      final playlist = Playlist.fromJson({'id': 1, 'name': name});
      await tester.pumpWidget(MaterialApp(
        theme: SoundQDesktopTheme.apply(AppTheme.darkTheme),
        home: Scaffold(
            body: Align(
          alignment: Alignment.topLeft,
          child: ValueListenableBuilder<double>(
              valueListenable: width,
              builder: (_, value, __) => SizedBox(
                    width: value,
                    height: card ? 280 : null,
                    child: card
                        ? PlaylistCard(playlist: playlist, onTap: () => opens++)
                        : PlaylistListTile(
                            playlist: playlist, onTap: () => opens++),
                  )),
        )),
      ));
      await tester.pumpAndSettle();
      final text = find.byWidgetPredicate((w) => w is Text && w.data == name);
      RenderParagraph paragraph() => tester.renderObject<RenderParagraph>(
          find.descendant(of: text, matching: find.byType(RichText)));
      expect(paragraph().didExceedMaxLines, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final focus = Focus.of(tester.element(text));
      expect(focus.hasPrimaryFocus, isTrue);
      expect(disclosure(name), findsOneWidget);
      width.value = 700;
      await tester.pumpAndSettle();
      expect(paragraph().didExceedMaxLines, isFalse);
      expect(focus.hasPrimaryFocus, isTrue);
      expect(disclosure(name), findsNothing);
      width.value = 220;
      await tester.pumpAndSettle();
      expect(paragraph().didExceedMaxLines, isTrue);
      expect(identical(Focus.of(tester.element(text)), focus), isTrue);
      expect(focus.hasPrimaryFocus, isTrue);
      expect(opens, 0);
      expect(tester.takeException(), isNull);
      expect(disclosure(name), findsOneWidget,
          reason:
              'The retained existing action remains focused; narrowing it must recover its now-truncated name without a new focus event.');
    });
  }
}
