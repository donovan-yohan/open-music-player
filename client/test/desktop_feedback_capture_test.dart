// Controlled render receipts: no account, backend, audio device or live app.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/errors/app_error.dart';
import 'package:open_music_player/core/errors/error_handler.dart';
import 'package:open_music_player/features/desktop/desktop_listening_shell.dart';
import 'package:open_music_player/features/desktop/desktop_transport.dart';

import 'desktop_listening_transport_test.dart'
    show DesktopPlayback, pumpListeningApp;

void main() {
  final output = Platform.environment['SOUNDQ_FEEDBACK_CAPTURE_DIR'];
  final fonts = Platform.environment['SOUNDQ_FLUTTER_FONTS'];
  testWidgets('capture corner feedback above real desktop transport',
      (tester) async {
    await tester.runAsync(() async {
      for (final font in [
        ('Roboto', 'Roboto-Regular.ttf'),
        ('Ahem', 'Roboto-Regular.ttf'),
        ('MaterialIcons', 'MaterialIcons-Regular.otf'),
      ]) {
        await (FontLoader(font.$1)
              ..addFont(File('$fonts/${font.$2}')
                  .readAsBytes()
                  .then(ByteData.sublistView)))
            .load();
      }
    });
    for (final size in [const Size(960, 640), const Size(1440, 900)]) {
      final playback = _FailingPausePlayback()..pending = true;
      await pumpListeningApp(tester, playback,
          size: size,
          content: const Scaffold(body: Center(child: Text('Library'))),
          shellBuilder: (child) => Theme(
                data: AppTheme.darkTheme,
                child: DesktopListeningShell(
                  compact: size.width < 1200,
                  selectedIndex: 2,
                  onDestinationSelected: (_) {},
                  miniPlayer: const DesktopTransport(),
                  child: child,
                ),
              ));
      await tester.tap(find.byTooltip('Cancel playback'));
      await tester.pumpAndSettle();
      expect(find.text('Could not pause playback. Please try again.'),
          findsOneWidget);
      final notification = tester.getRect(find
          .descendant(
              of: find.byType(SnackBar), matching: find.byType(Material))
          .first);
      final transport = tester
          .getRect(find.byKey(const ValueKey('soundq_desktop_transport')));
      expect(notification.width, 400);
      expect(notification.bottom, lessThan(transport.top));
      expect(find.byTooltip('Open queue').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Close').hitTestable(), findsOneWidget);
      await _capture(
          tester, '$output/player-failure-${size.width.toInt()}.png');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('Library').last);
      context.showError(AppError.timeout(), onRetry: () {});
      await tester.pumpAndSettle();
      expect(find.text('Retry').hitTestable(), findsOneWidget);
      await _capture(tester, '$output/retry-${size.width.toInt()}.png');
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  }, skip: output == null || fonts == null);
}

class _FailingPausePlayback extends DesktopPlayback {
  _FailingPausePlayback() : super(title: 'Midnight City', artist: 'M83');
  @override
  Future<void> pause() async => throw StateError('injected pause failure');
}

Future<void> _capture(WidgetTester tester, String path) async {
  final boundary = tester
      .renderObject<RenderRepaintBoundary>(find.byType(RepaintBoundary).first);
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}
