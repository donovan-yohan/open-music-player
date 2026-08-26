import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/features/dj/widgets/dj_waveform_lane.dart';
import 'package:open_music_player/features/dj_session/dj_session_screen.dart';
import 'package:open_music_player/features/dj_session/dj_session_service.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';

import '../../support/dj_viewport_fixtures.dart';
import '../../support/mock_dio_client.dart';

/// #415: the playhead was a hardcoded `Colors.white` at ~1.02:1 against a light
/// deck surface, and neither DJ route set a `SystemUiOverlayStyle`, so the
/// status-bar clock measured zero dark pixels on both.
double _contrastRatio(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  final lighter = math.max(first, second);
  final darker = math.min(first, second);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  final deck = useLoadedDjSession();

  test('the DJ features contain no palette literals', () {
    final sources = [
      ...Directory('lib/features/dj').listSync(recursive: true),
      ...Directory('lib/features/dj_session').listSync(recursive: true),
    ]
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();

    expect(sources, isNotEmpty);

    final white = <String>[];
    final palette = <String>[];
    for (final file in sources) {
      final source = file.readAsStringSync();
      if (RegExp(r'\bColors\.white\b').hasMatch(source)) {
        white.add(file.path);
      }
      // Colors.transparent is a role, not a palette entry: it is the only
      // permitted Colors. reference on these routes.
      if (RegExp(r'\bColors\.(?!transparent)').hasMatch(source)) {
        palette.add(file.path);
      }
    }

    expect(white, isEmpty,
        reason: 'the playhead must resolve from a design token');
    expect(palette, isEmpty,
        reason: 'deck lane colours and chrome must resolve from design tokens');
  });

  for (final entry in <String, ThemeData>{
    'light': AppTheme.lightTheme,
    'dark': AppTheme.darkTheme,
  }.entries) {
    testWidgets('the ${entry.key} playhead resolves from waveformPlayhead',
        (tester) async {
      final theme = entry.value;
      await pumpDjScreen(
        tester,
        session: deck.session,
        viewport: landscapeReference,
        theme: theme,
      );

      final tokens = theme.extension<SoundQPlayerTheme>()!;
      final expected = tokens.waveformPlayhead;
      for (final id in const ['a', 'b']) {
        final playhead = tester.widget<ColoredBox>(
          find.byKey(ValueKey('dj_waveform_playhead_$id')),
        );
        expect(playhead.color, expected);
        expect(playhead.color, isNot(theme.colorScheme.outlineVariant));
        expect(playhead.color, isNot(theme.colorScheme.surface));
        expect(
          _contrastRatio(playhead.color, theme.colorScheme.surface),
          greaterThanOrEqualTo(3.0),
        );

        // Contrast against the *surface* is the easy case: once a track is
        // loaded the pixels the bar crosses are peaks painted in the deck lane
        // colour, and the dark playhead token is one hue step from deck B
        // (1.12:1). The hairline is what has to read against the lane.
        final hairlineKey = ValueKey('dj_waveform_playhead_hairline_$id');
        final hairline = tester.widget<ColoredBox>(find.byKey(hairlineKey));
        for (final lane in <Color>[
          tokens.waveformDeckA,
          tokens.waveformDeckB,
          playhead.color,
        ]) {
          expect(_contrastRatio(hairline.color, lane),
              greaterThanOrEqualTo(3.0));
        }
        final hairlineRect = tester.getRect(find.byKey(hairlineKey));
        final playheadRect =
            tester.getRect(find.byKey(ValueKey('dj_waveform_playhead_$id')));
        expect(playheadRect.width, 2.0);
        expect(hairlineRect.width, 4.0,
            reason: 'a 1dp hairline on each side of the 2dp playhead');
        expect(hairlineRect.left, lessThan(playheadRect.left));
        expect(hairlineRect.right, greaterThan(playheadRect.right));
      }
    });

    testWidgets('the ${entry.key} deck lanes carry the two deck tokens',
        (tester) async {
      final theme = entry.value;
      await pumpDjScreen(
        tester,
        session: deck.session,
        viewport: landscapeReference,
        theme: theme,
      );

      final tokens = theme.extension<SoundQPlayerTheme>()!;
      final lanes = tester
          .widgetList<DjWaveformLane>(find.byType(DjWaveformLane))
          .toList();
      expect(lanes, hasLength(2));
      expect(lanes[0].color, tokens.waveformDeckA);
      expect(lanes[1].color, tokens.waveformDeckB);
      expect(tokens.waveformDeckA, isNot(tokens.waveformDeckB));
    });

    testWidgets('/dj annotates a ${entry.key} status-bar style',
        (tester) async {
      final theme = entry.value;
      await pumpDjScreen(
        tester,
        session: deck.session,
        viewport: landscapeReference,
        theme: theme,
      );

      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      );
      expect(
        region.value.statusBarIconBrightness,
        entry.key == 'dark' ? Brightness.light : Brightness.dark,
      );
      expect(region.value.statusBarColor, Colors.transparent);

      // The region goes away with the route: restoration is AnnotatedRegion's
      // own semantics, not a manual restore in dispose().
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 20));
      expect(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        findsNothing,
      );
    });

    testWidgets('/dj-session annotates a ${entry.key} status-bar style',
        (tester) async {
      final theme = entry.value;
      final apiClient =
          mockQueueApiClient((request) async => http.Response('{}', 200));
      final queueProvider = QueueProvider(apiClient);
      addTearDown(queueProvider.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<QueueProvider>.value(
          value: queueProvider,
          child: MaterialApp(
            theme: theme,
            home: DjSessionScreen(
              service: DjSessionService(apiClient),
              randomSeed: () => 77,
            ),
          ),
        ),
      );
      await tester.pump();

      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      );
      expect(
        region.value.statusBarIconBrightness,
        entry.key == 'dark' ? Brightness.light : Brightness.dark,
      );
      await tester.pumpAndSettle();
    });
  }

  testWidgets('the light and dark playheads are different colours',
      (tester) async {
    expect(
      SoundQPlayerTheme.light.waveformPlayhead,
      isNot(SoundQPlayerTheme.dark.waveformPlayhead),
    );
    expect(
      SoundQPlayerTheme.light.waveformDeckA,
      isNot(SoundQPlayerTheme.dark.waveformDeckA),
    );
    expect(
      SoundQPlayerTheme.light.waveformDeckB,
      isNot(SoundQPlayerTheme.dark.waveformDeckB),
    );
  });
}
