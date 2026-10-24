// Controlled production-widget render receipts. No account, network or audio.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/features/desktop/desktop_listening_shell.dart';
import 'package:open_music_player/features/desktop/desktop_transport.dart';

import 'desktop_listening_transport_test.dart'
    show DesktopPlayback, pumpListeningApp;

void main() {
  final output = Platform.environment['SOUNDQ_TRANSPORT_CAPTURE_DIR'];
  final fonts = Platform.environment['SOUNDQ_FLUTTER_FONTS'];
  testWidgets('capture compact transport with real fonts and measured geometry',
      (tester) async {
    await tester.runAsync(() async {
      for (final family in ['Roboto', '.SF Pro Text', '.SF Pro Display']) {
        await (FontLoader(family)
              ..addFont(File('$fonts/Roboto-Regular.ttf')
                  .readAsBytes()
                  .then(ByteData.sublistView)))
            .load();
      }
      await (FontLoader('MaterialIcons')
            ..addFont(File('$fonts/MaterialIcons-Regular.otf')
                .readAsBytes()
                .then(ByteData.sublistView)))
          .load();
    });
    final receipts = <Map<String, Object?>>[];
    for (final width in [960.0, 1024.0, 1440.0, 2560.0]) {
      for (final scale in [1.0, 2.0]) {
        final name = 'transport-${width.toInt()}-${scale.toInt()}x';
        const rootKey = ValueKey('transport-density-capture');
        await pumpListeningApp(
            tester,
            DesktopPlayback(
                title: 'Midnight Walk — a long controlled fixture track title',
                artist: 'Fixture Ensemble with a long artist name'),
            size: Size(width, 600),
            textScale: scale,
            content: const Center(
                child: Text('Controlled fixture · no account or audio')),
            shellBuilder: (child) {
          final theme = AppTheme.darkTheme;
          return RepaintBoundary(
            key: rootKey,
            child: Theme(
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
                compact: width < 1200,
                selectedIndex: 0,
                onDestinationSelected: (_) {},
                miniPlayer: const DesktopTransport(),
                child: child,
              ),
            ),
          );
        });
        final transport =
            find.byKey(const ValueKey('soundq_desktop_transport'));
        final seek = find.byKey(const ValueKey('soundq_desktop_seek'));
        final play = find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == 'Pause');
        final boundary =
            tester.renderObject<RenderRepaintBoundary>(find.byKey(rootKey));
        final rect = tester.getRect(transport);
        expect(tester.getCenter(play).dx, closeTo(width / 2, .5));
        expect(tester.getCenter(seek).dx, closeTo(width / 2, .5));
        expect(tester.getSize(seek).height, greaterThanOrEqualTo(40));
        if (scale == 1) expect(rect.height, inInclusiveRange(88, 100));
        receipts.add({
          'fixture': true,
          'capture': '$name.png',
          'width': width,
          'textScale': scale,
          'transportHeight': rect.height,
          'playCenterX': tester.getCenter(play).dx,
          'seekCenterX': tester.getCenter(seek).dx,
          'seekSize': '${tester.getSize(seek)}',
          'identityWidth':
              tester.getSize(find.byTooltip('Open now playing')).width,
        });
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$output/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          // A transport-only crop keeps the layout receipt easy to inspect.
          final recorder = ui.PictureRecorder();
          final canvas = Canvas(recorder);
          canvas.drawImageRect(image, rect,
              Rect.fromLTWH(0, 0, rect.width, rect.height), Paint());
          final picture = recorder.endRecording();
          final cropped =
              await picture.toImage(rect.width.toInt(), rect.height.ceil());
          final cropBytes =
              await cropped.toByteData(format: ui.ImageByteFormat.png);
          await File('$output/$name-bar.png')
              .writeAsBytes(cropBytes!.buffer.asUint8List());
          cropped.dispose();
          picture.dispose();
          image.dispose();
          await File('$output/geometry.json').writeAsString(
              const JsonEncoder.withIndent('  ').convert(receipts));
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
    }
  }, skip: output == null || fonts == null);
}
