import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/shared/widgets/track_tile.dart';
import 'package:open_music_player/shared/widgets/song_metadata_chips.dart';

void expectReadableMetadata(WidgetTester tester, Finder row, double scale) {
  final metadata =
      find.descendant(of: row, matching: find.byType(SongMetadataChips));
  final labels = find.descendant(of: metadata, matching: find.byType(RichText));
  expect(labels, findsWidgets);
  for (final element in labels.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    final transform = paragraph.getTransformTo(null);
    expect(transform.entry(0, 0), closeTo(1, .001));
    expect(transform.entry(1, 1), closeTo(1, .001));
    expect(paragraph.text.style!.fontSize, greaterThanOrEqualTo(12));
    expect(paragraph.textScaler.scale(12), closeTo(12 * scale, .001));
    expect(paragraph.didExceedMaxLines, isFalse);
    expect(paragraph.size.width, greaterThan(0));
  }
}

void main() {
  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      for (final variant in [
        'duration',
        'heart',
        'more',
        'heart-more',
        'queue'
      ]) {
        testWidgets('readable metadata $width $scale $variant', (tester) async {
          tester.view.physicalSize = Size(width, 1400);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final semantics = tester.ensureSemantics();

          await tester.pumpWidget(MaterialApp(
              home: Scaffold(
                  body: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: TrackTile(
              title: 'A long readable title',
              artist: 'Artist',
              duration: '3:38',
              queueItemId: variant == 'queue' ? 'occurrence_0' : null,
              action: ['heart', 'heart-more', 'queue'].contains(variant)
                  ? IconButton(
                      iconSize: 20,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.favorite),
                      onPressed: () {})
                  : null,
              onMorePressed: variant.contains('more') ? () {} : null,
              analysis: TrackAnalysis.fromJson(status: 'analyzed', summary: {
                'bpm': {'value': 128},
                'camelot': {'value': '8A'},
              }),
            ),
          ))));
          expectReadableMetadata(tester, find.byType(TrackTile), scale);
          expect(
              find.bySemanticsLabel('Tempo 128 BPM, Key 8A'), findsOneWidget);
          if (scale == 1) {
            expect(tester.getSize(find.byType(TrackTile)).height, 72);
            expect(tester.getSize(find.text('A long readable title')).width,
                greaterThanOrEqualTo(64));
            final actions = find.descendant(
                of: find.byType(TrackTile), matching: find.byType(IconButton));
            for (final button in actions.evaluate()) {
              final rect = tester.getRect(find.byWidget(button.widget));
              expect(rect.height, greaterThanOrEqualTo(40));
              expect(rect.width, greaterThanOrEqualTo(40));
              expect(rect.center.dy, 36);
            }
            if (width == 320 && variant == 'heart-more') {
              expect(find.text('3:38'), findsNothing);
              expect(find.bySemanticsLabel('3:38'), findsOneWidget);
            }
            if (width == 390 && variant != 'heart-more') {
              expect(find.text('128'), findsOneWidget);
              expect(find.text('8A'), findsOneWidget);
            }
          }
          expect(tester.takeException(), isNull);
          semantics.dispose();
        });
      }
    }
  }
}
