import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/desktop_theme.dart';
import 'package:open_music_player/app/theme.dart';

Future<void> loadFlightFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (final entry in {
      'Space Grotesk': [
        'spacegrotesk/SpaceGrotesk-Regular.ttf',
        'spacegrotesk/SpaceGrotesk-Medium.ttf',
        'spacegrotesk/SpaceGrotesk-SemiBold.ttf',
        'spacegrotesk/SpaceGrotesk-Bold.ttf',
      ],
      'IBM Plex Mono': [
        'ibmplexmono/IBMPlexMono-Regular.ttf',
        'ibmplexmono/IBMPlexMono-Medium.ttf',
      ],
      'MaterialIcons': ['../fonts/MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final file in entry.value) {
        loader.addFont(rootBundle.load(
            file.startsWith('../') ? file.substring(3) : 'assets/fonts/$file'));
      }
      await loader.load();
    }
  });
}

void main() {
  testWidgets('packaged Space Grotesk renders four distinct real weight glyphs',
      (tester) async {
    await loadFlightFonts(tester);
    final hashes = <String>{};
    var previousInk = 0;
    for (final weight in [
      FontWeight.w400,
      FontWeight.w500,
      FontWeight.w600,
      FontWeight.w700,
    ]) {
      final painter = TextPainter(
          text: TextSpan(
              text: 'Hamburgefonts 0123456789',
              style: TextStyle(
                  fontFamily: 'Space Grotesk',
                  fontWeight: weight,
                  fontSize: 32,
                  color: Colors.white)),
          textDirection: TextDirection.ltr)
        ..layout();
      final recorder = ui.PictureRecorder();
      painter.paint(Canvas(recorder), Offset.zero);
      final picture = recorder.endRecording();
      final result = await tester.runAsync(() async {
        final image = await picture.toImage(600, 64);
        final data =
            (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
        final bytes = data.buffer.asUint8List();
        var ink = 0;
        for (var i = 3; i < bytes.length; i += 4) {
          ink += bytes[i];
        }
        image.dispose();
        return (ink, sha256.convert(bytes).toString());
      });
      expect(result, isNotNull);
      expect(result!.$1, greaterThan(previousInk));
      expect(hashes.add(result.$2), isTrue);
      debugPrint('SPACE_GROTESK_WEIGHT ${weight.value} '
          'ink=${result.$1} sha256=${result.$2} width=${painter.width}');
      previousInk = result.$1;
      picture.dispose();
      painter.dispose();
    }
    expect(hashes, hasLength(4));
  });
  testWidgets('square desktop candidate preserves the complete mobile theme',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final width in [959.0, 960.0]) {
      tester.view.physicalSize = Size(width, 800);
      late ThemeData inherited;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: Builder(builder: (context) {
          inherited = Theme.of(context);
          return const SoundQDesktopTheme(
              child: Scaffold(body: Text('Candidate')));
        }),
      ));
      final mounted = Theme.of(tester.element(find.text('Candidate')));
      if (width < 960) {
        expect(mounted, same(inherited));
      } else {
        expect(mounted.textTheme.bodyMedium!.fontFamily, 'Space Grotesk');
        expect(mounted.textTheme.bodyMedium!.fontFamilyFallback,
            inherited.textTheme.bodyMedium!.fontFamilyFallback);
      }
    }
  });
  testWidgets('font OFL entries register once across nested desktop adapters',
      (tester) async {
    SoundQDesktopTheme.apply(AppTheme.darkTheme);
    SoundQDesktopTheme.apply(AppTheme.darkTheme);
    final entries = await tester.runAsync(() async => LicenseRegistry.licenses
        .where((entry) => entry.packages
            .any((name) => name == 'Space Grotesk' || name == 'IBM Plex Mono'))
        .toList());
    expect(entries, hasLength(2));
    for (final entry in entries!) {
      expect(entry.paragraphs.map((p) => p.text).join('\n'),
          contains('SIL OPEN FONT LICENSE'));
    }
  });
  testWidgets('desktop uses bundled glyphs and explicit font roles only at 960',
      (tester) async {
    expect(defaultTargetPlatform, TargetPlatform.macOS);
    await loadFlightFonts(tester);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final width in [959.0, 960.0]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: SoundQDesktopTheme(
            child: Scaffold(
                body: Column(children: [
          const Text('Flight console'),
          FilledButton(onPressed: () {}, child: const Text('Primary')),
          const TextField(),
        ]))),
      ));
      await tester.pumpAndSettle();
      final theme = Theme.of(tester.element(find.byType(TextField)));
      if (width < 960) {
        expect(theme.textTheme.bodyMedium!.fontSize,
            AppTheme.darkTheme.textTheme.bodyMedium!.fontSize);
        expect(theme.textTheme.bodyMedium!.fontFamily, isNot('Space Grotesk'));
        continue;
      }
      expect(theme.textTheme.bodyMedium!.fontFamily, 'Space Grotesk');
      expect(theme.textTheme.bodyMedium!.fontFamilyFallback,
          contains('Noto Sans CJK JP'));
      for (final style in [
        theme.filledButtonTheme.style!.textStyle!.resolve({}),
        theme.elevatedButtonTheme.style!.textStyle!.resolve({}),
        theme.textButtonTheme.style!.textStyle!.resolve({}),
        theme.outlinedButtonTheme.style!.textStyle!.resolve({}),
        theme.segmentedButtonTheme.style!.textStyle!.resolve({}),
        theme.menuButtonTheme.style!.textStyle!.resolve({}),
        theme.inputDecorationTheme.labelStyle,
        theme.navigationRailTheme.selectedLabelTextStyle,
        theme.appBarTheme.titleTextStyle,
      ]) {
        expect(style!.fontFamily, 'Space Grotesk');
        expect(style.fontWeight!.value, lessThanOrEqualTo(700));
      }
      double widthOf(String text, TextStyle style) {
        final p = TextPainter(
            text: TextSpan(text: text, style: style),
            textDirection: TextDirection.ltr)
          ..layout();
        final result = p.width;
        p.dispose();
        return result;
      }

      final body = theme.textTheme.bodyMedium!;
      expect(widthOf('iiii', body), lessThan(widthOf('WWWW', body)));
      expect(widthOf('Timeline', body), inExclusiveRange(35, 65));
      const mono = TextStyle(fontFamily: 'IBM Plex Mono', fontSize: 14);
      expect(widthOf('1111', mono), closeTo(widthOf('8888', mono), .01));
      expect(widthOf('1111', mono), inExclusiveRange(30, 40));
      expect(tester.takeException(), isNull);
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
