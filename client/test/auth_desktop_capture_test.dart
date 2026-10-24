import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/features/auth/screens/login_screen.dart';
import 'package:open_music_player/features/auth/screens/register_screen.dart';

import 'auth_desktop_presentation_test.dart' show pumpAuth;

/// Real production auth widgets, fonts and assets; never contacts a server.
/// Default-font geometry is tested separately in auth_desktop_presentation_test.
void main() {
  final output = Platform.environment['SOUNDQ_AUTH_CAPTURE_DIR'];
  final fonts = Platform.environment['SOUNDQ_FLUTTER_FONTS'];
  testWidgets('capture production auth surfaces with real fonts',
      (tester) async {
    for (final font in [
      ('Roboto', 'Roboto-Regular.ttf'),
      ('Ahem', 'Roboto-Regular.ttf'),
      ('MaterialIcons', 'MaterialIcons-Regular.otf'),
    ]) {
      await tester.runAsync(() async {
        final loader = FontLoader(font.$1)
          ..addFont(File('$fonts/${font.$2}')
              .readAsBytes()
              .then(ByteData.sublistView));
        await loader.load();
      });
    }
    for (final capture in [
      (
        'login-desktop',
        const LoginScreen(),
        const Size(1440, 900),
        1.0,
        false,
        false
      ),
      (
        'register-desktop',
        const RegisterScreen(),
        const Size(1440, 900),
        1.0,
        false,
        false
      ),
      (
        'login-error-desktop',
        const LoginScreen(),
        const Size(1440, 900),
        1.0,
        true,
        false
      ),
      (
        'register-error-desktop',
        const RegisterScreen(),
        const Size(1440, 900),
        1.0,
        true,
        false
      ),
      (
        'login-light-desktop',
        const LoginScreen(),
        const Size(1440, 900),
        1.0,
        false,
        true
      ),
      (
        'register-light-desktop',
        const RegisterScreen(),
        const Size(1440, 900),
        1.0,
        false,
        true
      ),
      (
        'login-mobile-2x',
        const LoginScreen(),
        const Size(390, 844),
        2.0,
        true,
        false
      ),
      (
        'register-mobile-2x',
        const RegisterScreen(),
        const Size(390, 844),
        2.0,
        true,
        false
      ),
    ]) {
      final theme = capture.$6 ? AppTheme.lightTheme : AppTheme.darkTheme;
      await pumpAuth(
          tester,
          RepaintBoundary(
            key: const ValueKey('auth-capture'),
            child: Theme(
                data: theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
                  filledButtonTheme: FilledButtonThemeData(
                      style: theme.filledButtonTheme.style?.copyWith(
                    textStyle: WidgetStatePropertyAll(theme
                        .filledButtonTheme.style?.textStyle
                        ?.resolve({})?.copyWith(fontFamily: 'Roboto')),
                  )),
                  textButtonTheme: TextButtonThemeData(
                      style: theme.textButtonTheme.style?.copyWith(
                    textStyle: WidgetStatePropertyAll(theme
                        .textButtonTheme.style?.textStyle
                        ?.resolve({})?.copyWith(fontFamily: 'Roboto')),
                  )),
                ),
                child: capture.$2),
          ),
          size: capture.$3,
          scale: capture.$4);
      await tester.runAsync(() => precacheImage(
          const AssetImage('assets/brand/soundq-logo.png'),
          tester.element(find.byType(Image).first)));
      await tester.pumpAndSettle();
      if (capture.$5) {
        await tester.ensureVisible(find.byType(FilledButton));
        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        if (capture.$4 == 2) {
          // Validation expands the form; explicitly capture its reachable end.
          final scrollable =
              tester.state<ScrollableState>(find.byType(Scrollable).first);
          scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
          await tester.pumpAndSettle();
        }
      }
      Future<void> save(String name) async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const ValueKey('auth-capture')));
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$output/$name.png');
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await save(capture.$1);
      if (capture.$4 == 2) {
        await tester.drag(
            find.byType(SingleChildScrollView), const Offset(0, 2000));
        await tester.pumpAndSettle();
        await save('${capture.$1}-top');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }
  }, skip: output == null || fonts == null);
}
