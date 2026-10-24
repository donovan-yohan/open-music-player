import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/features/desktop/desktop_listening_shell.dart';
import 'package:open_music_player/features/desktop/desktop_transport.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/services/home_service.dart';
import 'package:open_music_player/features/home/home_screen.dart';
import 'package:open_music_player/shared/models/models.dart';

import 'desktop_listening_transport_test.dart'
    show DesktopPlayback, pumpListeningApp;

/// Optional human-readable render receipts. Default-font layout regressions
/// live separately in desktop_listening_transport_test.dart.
void main() {
  final output = Platform.environment['SOUNDQ_SHELL_CAPTURE_DIR'];
  testWidgets('capture desktop listening shell with real fonts',
      (tester) async {
    for (final font in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('Ahem', 'Roboto-Regular.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf')
    ]) {
      await tester.runAsync(() async {
        final loader = FontLoader(font.$1)
          ..addFont(
            File('${Platform.environment['SOUNDQ_FLUTTER_FONTS']}/${font.$2}')
                .readAsBytes()
                .then(ByteData.sublistView),
          );
        await loader.load();
      });
    }
    for (final size in [
      const Size(1024, 768),
      const Size(1440, 900),
      const Size(2560, 1440)
    ]) {
      await pumpListeningApp(
          tester, DesktopPlayback(title: 'Midnight City', artist: 'M83'),
          size: size, content: HomeScreen(homeService: _CaptureHome()),
          shellBuilder: (child) {
        final theme = AppTheme.darkTheme;
        return Theme(
            data: theme.copyWith(
              textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
              navigationRailTheme: theme.navigationRailTheme.copyWith(
                selectedLabelTextStyle: theme
                    .navigationRailTheme.selectedLabelTextStyle
                    ?.copyWith(fontFamily: 'Roboto'),
                unselectedLabelTextStyle: theme
                    .navigationRailTheme.unselectedLabelTextStyle
                    ?.copyWith(fontFamily: 'Roboto'),
              ),
            ),
            child: DesktopListeningShell(
              compact: size.width < 1200,
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              miniPlayer: const DesktopTransport(),
              child: child,
            ));
      });
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byType(RepaintBoundary).first);
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$output/listening-${size.width.toInt()}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  },
      skip: output == null ||
          Platform.environment['SOUNDQ_FLUTTER_FONTS'] == null);
}

class _CaptureHome extends HomeService {
  _CaptureHome() : super(ApiClient());
  final tracks = [
    for (final (index, title, artist) in [
      (1, 'Midnight City', 'M83'),
      (2, 'Open Eye Signal', 'Jon Hopkins'),
      (3, 'Kerala', 'Bonobo'),
      (4, 'Two Thousand and Seventeen', 'Four Tet'),
      (5, 'A Walk', 'Tycho'),
      (6, 'Cirrus', 'Bonobo')
    ])
      Track.fromJson({'id': index, 'title': title, 'artist': artist}),
  ];
  @override
  Future<List<Track>> recentlyPlayed({int limit = 20}) async =>
      tracks.take(3).toList();
  @override
  Future<List<Track>> topTracks({int days = 30, int limit = 20}) async =>
      tracks.skip(3).toList();
  @override
  Future<List<Playlist>> playlists({int limit = 20, int offset = 0}) async =>
      [];
}
