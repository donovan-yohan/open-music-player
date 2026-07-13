import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/shared/widgets/soundq_status_chip.dart';

void main() {
  testWidgets('Sound Q player vocabulary resolves distinct status roles', (
    tester,
  ) async {
    for (final theme in [AppTheme.darkTheme, AppTheme.lightTheme]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: Column(
              children: [
                SoundQStatusChip(
                  label: 'Pending',
                  status: SoundQStatus.pending,
                  icon: Icons.hourglass_top,
                ),
                SoundQStatusChip(
                  label: 'Downloading',
                  status: SoundQStatus.downloading,
                  icon: Icons.downloading,
                ),
                SoundQStatusChip(
                  label: 'Playable',
                  status: SoundQStatus.playable,
                  icon: Icons.check_circle,
                ),
                SoundQStatusChip(
                  label: 'Failed',
                  status: SoundQStatus.failed,
                  icon: Icons.error_outline,
                ),
              ],
            ),
          ),
        ),
      );

      final context = tester.element(find.byType(SoundQStatusChip).first);
      final vocabulary = SoundQPlayerTheme.of(context);
      expect(vocabulary.queuePending, isNot(vocabulary.queueDownloading));
      expect(vocabulary.queueDownloading, isNot(vocabulary.queuePlayable));
      expect(vocabulary.queuePlayable, isNot(vocabulary.queueFailed));
      expect(vocabulary.playhead, isNot(vocabulary.timelineGrid));
      expect(
        tester.widget<Icon>(find.byIcon(Icons.hourglass_top)).color,
        vocabulary.queuePending,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.downloading)).color,
        vocabulary.queueDownloading,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.check_circle)).color,
        vocabulary.queuePlayable,
      );
      expect(
        tester.widget<Icon>(find.byIcon(Icons.error_outline)).color,
        vocabulary.queueFailed,
      );
      expect(find.text('Playable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('Sound Q surface state preserves loading and retry treatment', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: SoundQSurfaceState(
            type: SoundQSurfaceStateType.error,
            title: 'Error loading queue',
            message: 'boom',
            action:
                ElevatedButton(onPressed: () {}, child: const Text('Retry')),
          ),
        ),
      ),
    );

    expect(find.byType(SoundQSurfaceState), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
