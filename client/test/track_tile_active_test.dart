import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';

TrackAnalysis _analysis() => TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: {
        'bpm': {'value': 128},
        'key': {'value': 'Am'},
        'camelot': {'value': '8A'},
      },
    );

void main() {
  testWidgets('active track tile surfaces a now-playing badge', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: TrackTile(
            title: 'Get Your Wish',
            artist: 'Porter Robinson',
            album: 'Nurture',
            duration: '3:38',
            isCurrent: true,
            activeLabel: 'Now playing',
          ),
        ),
      ),
    );

    expect(find.text('Get Your Wish'), findsOneWidget);
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.byIcon(Icons.equalizer), findsOneWidget);
  });

  testWidgets('keeps metadata as a compact trailing group on narrow rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackTile(
            title: 'A deliberately long song title for a narrow phone',
            artist: 'An artist with a deliberately long name',
            duration: '3:38',
            analysis: _analysis(),
          ),
        ),
      ),
    );

    final metadata = find.byKey(const ValueKey('song_metadata_chips'));
    final metadataRect = tester.getRect(metadata);
    final titleRect = tester.getRect(
      find.text('A deliberately long song title for a narrow phone'),
    );
    final artistRect = tester.getRect(
      find.text('An artist with a deliberately long name'),
    );
    final durationRect = tester.getRect(find.text('3:38'));

    expect(metadataRect.left, greaterThan(titleRect.left));
    expect(titleRect.right, lessThanOrEqualTo(metadataRect.left));
    expect(artistRect.right, lessThanOrEqualTo(metadataRect.left));
    expect(metadataRect.right, lessThan(durationRect.left));
    expect(
      tester
          .getSize(
            find.descendant(
              of: find.byKey(const ValueKey('song_metadata_bpm_chip')),
              matching: find.byType(Container),
            ),
          )
          .height,
      18,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('normal narrow tile preserves metadata with now-playing badge', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const title = 'Current track with metadata and a real badge';
    const artist = 'Current artist with a readable subtitle';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TrackTile(
            title: title,
            artist: artist,
            duration: '3:38',
            analysis: _analysis(),
            isCurrent: true,
            activeLabel: 'Now playing',
          ),
        ),
      ),
    );

    final metadata = tester.getRect(
      find.byKey(const ValueKey('song_metadata_chips')),
    );
    final titleRect = tester.getRect(find.text(title));
    final artistRect = tester.getRect(find.text(artist));
    final bpmChip = find.byKey(const ValueKey('song_metadata_bpm_chip'));

    expect(find.text('128 BPM'), findsOneWidget);
    expect(find.text('8A'), findsOneWidget);
    expect(find.text('Now playing'), findsOneWidget);
    expect(find.text('3:38'), findsOneWidget);
    expect(titleRect.width, greaterThanOrEqualTo(160));
    expect(artistRect.width, greaterThanOrEqualTo(160));
    expect(artistRect.bottom, lessThanOrEqualTo(metadata.top));
    expect(tester.getSize(bpmChip).height, 18);
    expect(
        tester.getSize(find.text('128 BPM')).height, greaterThanOrEqualTo(10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('enlarged text stays inside solid pills on a generic song row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: TrackTile(
              title: 'Accessible metadata row',
              artist: 'Scaled artist',
              duration: '3:38',
              analysis: _analysis(),
            ),
          ),
        ),
      ),
    );

    for (final entry in <(Key, String)>[
      (const ValueKey('song_metadata_bpm_chip'), '128 BPM'),
      (const ValueKey('song_metadata_key_chip'), '8A'),
    ]) {
      final chip = find.byKey(entry.$1);
      final fill = find.descendant(of: chip, matching: find.byType(Container));
      final fillRect = tester.getRect(fill);
      final textRect = tester.getRect(find.text(entry.$2));
      final decoration =
          tester.widget<Container>(fill).decoration! as BoxDecoration;

      expect(fillRect.height, greaterThan(18));
      expect(textRect.left, greaterThanOrEqualTo(fillRect.left));
      expect(textRect.top, greaterThanOrEqualTo(fillRect.top));
      expect(textRect.right, lessThanOrEqualTo(fillRect.right));
      expect(textRect.bottom, lessThanOrEqualTo(fillRect.bottom));
      expect(decoration.color, isNotNull);
      expect(decoration.border, isNull);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow TrackTile constrains metadata at 2x and 3x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const title = 'A long title that must retain usable row width';
    const artist = 'A long artist that must retain usable row width';
    for (final scale in [2.0, 3.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: TrackTile(
                title: title,
                artist: artist,
                duration: '3:38',
                analysis: _analysis(),
                isCurrent: true,
                activeLabel: 'Now playing',
              ),
            ),
          ),
        ),
      );

      final trailing = tester.getRect(
        find.byKey(const ValueKey('track_tile_trailing')),
      );
      final metadata = tester.getRect(
        find.byKey(const ValueKey('song_metadata_chips')),
      );
      final titleRect = tester.getRect(find.text(title));
      final artistRect = tester.getRect(find.text(artist));
      final actionsRect = tester.getRect(
        find.byKey(const ValueKey('track_tile_actions')),
      );
      final badgeRect = tester.getRect(
        find.byKey(const ValueKey('track_tile_now_playing_badge')),
      );
      final durationRect = tester.getRect(find.text('3:38'));

      expect(find.text('128 BPM'), findsOneWidget);
      expect(find.text('8A'), findsOneWidget);
      expect(find.text('Now playing'), findsOneWidget);
      expect(find.text('3:38'), findsOneWidget);
      expect(trailing.width, lessThanOrEqualTo(320 * 0.55 + 0.01));
      expect(metadata.right, closeTo(trailing.right, 0.01));
      expect(titleRect.width, greaterThanOrEqualTo(160));
      expect(artistRect.width, greaterThanOrEqualTo(160));
      expect(titleRect.bottom, lessThanOrEqualTo(metadata.top));
      expect(artistRect.bottom, lessThanOrEqualTo(metadata.top));
      expect(actionsRect.right, closeTo(320 - 16, 0.01));
      expect(badgeRect.right, lessThanOrEqualTo(actionsRect.right));
      expect(durationRect.right, lessThanOrEqualTo(actionsRect.right));
      for (final key in const [
        ValueKey('song_metadata_bpm_chip'),
        ValueKey('song_metadata_key_chip'),
      ]) {
        expect(tester.getSize(find.byKey(key)).width, lessThan(320 * 0.55));
      }
      expect(
        badgeRect.width,
        lessThan(320 - 80),
      );
      if (scale == 3) {
        expect(durationRect.top, greaterThanOrEqualTo(badgeRect.bottom));
      }
      expect(tester.takeException(), isNull, reason: 'text scale $scale');
    }
  });

  testWidgets('combined metadata badge layout stays coherent when wide', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const title = 'Wide current track keeps a useful title region';
    const artist = 'Wide current artist keeps a useful subtitle region';
    for (final width in [480.0, 800.0]) {
      for (final scale in [1.0, 3.0]) {
        tester.view.physicalSize = Size(width, 1200);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: TrackTile(
                  title: title,
                  artist: artist,
                  duration: '3:38',
                  analysis: _analysis(),
                  isCurrent: true,
                  activeLabel: 'Now playing',
                ),
              ),
            ),
          ),
        );

        final trailing = tester.getRect(
          find.byKey(const ValueKey('track_tile_trailing')),
        );
        final metadata = tester.getRect(
          find.byKey(const ValueKey('song_metadata_chips')),
        );
        final actions = tester.getRect(
          find.byKey(const ValueKey('track_tile_actions')),
        );
        final titleRect = tester.getRect(find.text(title));
        final artistRect = tester.getRect(find.text(artist));

        expect(find.text('128 BPM'), findsOneWidget);
        expect(find.text('8A'), findsOneWidget);
        expect(find.text('Now playing'), findsOneWidget);
        expect(find.text('3:38'), findsOneWidget);
        expect(trailing.width, lessThanOrEqualTo(220.01));
        expect(metadata.right, closeTo(trailing.right, 0.01));
        expect(actions.right, closeTo(width - 16, 0.01));
        expect(titleRect.width, greaterThanOrEqualTo(width * 0.65));
        expect(artistRect.width, greaterThanOrEqualTo(width * 0.65));
        expect(artistRect.bottom, lessThanOrEqualTo(metadata.top));

        for (final entry in <(Key, String)>[
          (const ValueKey('song_metadata_bpm_chip'), '128 BPM'),
          (const ValueKey('song_metadata_key_chip'), '8A'),
        ]) {
          final chip = find.byKey(entry.$1);
          final fill = find.descendant(
            of: chip,
            matching: find.byType(Container),
          );
          final fillRect = tester.getRect(fill);
          final textRect = tester.getRect(find.text(entry.$2));

          expect(fillRect.width, lessThan(220));
          expect(fillRect.height, scale == 1 ? 18 : greaterThan(18));
          expect(textRect.left, greaterThanOrEqualTo(fillRect.left));
          expect(textRect.top, greaterThanOrEqualTo(fillRect.top));
          expect(textRect.right, lessThanOrEqualTo(fillRect.right));
          expect(textRect.bottom, lessThanOrEqualTo(fillRect.bottom));
        }
        expect(
          tester.takeException(),
          isNull,
          reason: 'width $width at text scale $scale',
        );
      }
    }
  });
}
