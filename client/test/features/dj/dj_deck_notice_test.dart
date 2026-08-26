import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/dj/dj_deck_actions.dart';
import 'package:open_music_player/features/dj/dj_deck_copy.dart';
import 'package:open_music_player/features/dj/models/dj_deck_load_failure.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/widgets/dj_deck_notice.dart';
import 'package:open_music_player/models/track.dart';

import '../../support/dj_viewport_fixtures.dart';

/// #414 D1: the deck lane is the one surface that explains a deck holding no
/// audio, and it now carries the action that fixes it. The render is a pure
/// function of `(deck, DjDeckActions?)`, so a lane pumped with no ancestor
/// still renders copy only — which is what keeps every pre-#414 lane test
/// honest rather than merely green.
void main() {
  DjDeckState refused(
    DjDeckLoadFailureKind kind, {
    DjDeckId deckId = DjDeckId.a,
    String? title,
  }) =>
      DjDeckState(
        deckId: deckId,
        title: title,
        loadFailure: DjDeckLoadFailure(kind: kind, title: title),
      );

  Future<void> pumpNotice(
    WidgetTester tester, {
    required DjDeckState deck,
    DjViewport viewport = landscapeReference,
    double width = 380,
    double height = 56,
    bool withActions = true,
    bool queueHasTracks = false,
    Future<void> Function(DjDeckId deck)? onPickLocalFile,
    Future<void> Function(DjDeckId deck)? onDownload,
    DjDeckDownload Function(DjDeckId deck)? downloadFor,
  }) async {
    viewport.apply(tester);
    final notice = DjDeckNotice(deck: deck);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(viewport.textScale),
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              height: height,
              child: withActions
                  ? DjDeckActions(
                      queueHasTracks: queueHasTracks,
                      onPickLocalFile: onPickLocalFile,
                      onDownload: onDownload,
                      downloadFor: downloadFor ?? (_) => DjDeckDownload.idle,
                      child: notice,
                    )
                  : notice,
            ),
          ),
        ),
      ),
    );
  }

  String copyOf(WidgetTester tester, [DjDeckId deck = DjDeckId.a]) => tester
      .widget<Text>(
        find.byKey(ValueKey('dj_deck_unavailable_${deck.name}')),
      )
      .data!;

  testWidgets('an offline refusal offers the download action', (tester) async {
    await pumpNotice(
      tester,
      deck: refused(DjDeckLoadFailureKind.unavailableOffline),
      onDownload: (_) async {},
      onPickLocalFile: (_) async {},
    );

    expect(copyOf(tester), djDeckDownloadRequired);
    expect(find.byKey(const ValueKey('dj_deck_download_a')), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_deck_load_file_a')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a non-local pick offers the load-a-file action', (tester) async {
    await pumpNotice(
      tester,
      deck: refused(DjDeckLoadFailureKind.pickerNotLocal),
      onDownload: (_) async {},
      onPickLocalFile: (_) async {},
    );

    expect(copyOf(tester), djDeckPickLocalFile);
    expect(find.byKey(const ValueKey('dj_deck_load_file_a')), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_deck_download_a')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unavailable source offers nothing to press', (tester) async {
    await pumpNotice(
      tester,
      deck: refused(DjDeckLoadFailureKind.sourceUnavailable),
      onDownload: (_) async {},
      onPickLocalFile: (_) async {},
    );

    expect(copyOf(tester), djDeckSourceUnavailable);
    expect(find.byKey(const ValueKey('dj_deck_download_a')), findsNothing);
    expect(find.byKey(const ValueKey('dj_deck_load_file_a')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a deck that was never seeded offers the inline load affordance',
      (tester) async {
    await pumpNotice(
      tester,
      deck: const DjDeckState(deckId: DjDeckId.a),
      onDownload: (_) async {},
      onPickLocalFile: (_) async {},
    );

    expect(copyOf(tester), djDeckEmpty);
    expect(find.byKey(const ValueKey('dj_deck_load_file_a')), findsOneWidget);
    expect(find.byKey(const ValueKey('dj_deck_download_a')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the download action fires once, for its own deck',
      (tester) async {
    final downloads = <DjDeckId>[];
    await pumpNotice(
      tester,
      deck: refused(DjDeckLoadFailureKind.unavailableOffline),
      onDownload: (deck) async => downloads.add(deck),
    );

    await tester.tap(find.byKey(const ValueKey('dj_deck_download_a')));
    await tester.pump();

    expect(downloads, [DjDeckId.a]);
  });

  testWidgets('a running transfer disables the action and shows its progress',
      (tester) async {
    await pumpNotice(
      tester,
      deck: refused(DjDeckLoadFailureKind.unavailableOffline),
      onDownload: (_) async {},
      downloadFor: (_) => DjDeckDownload.running(0.4),
    );

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('dj_deck_download_a')),
    );
    expect(button.onPressed, isNull);
    expect(find.text(djDeckDownloadRunningAction), findsOneWidget);
    expect(
      tester
          .widget<CircularProgressIndicator>(
            find.byType(CircularProgressIndicator),
          )
          .value,
      0.4,
    );
  });

  testWidgets('a failed transfer says so and offers a retry', (tester) async {
    await pumpNotice(
      tester,
      deck: refused(DjDeckLoadFailureKind.unavailableOffline),
      onDownload: (_) async {},
      downloadFor: (_) => DjDeckDownload.failed,
    );

    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('dj_deck_download_a')),
    );
    expect(button.onPressed, isNotNull);
    expect(find.text(djDeckDownloadRetryAction), findsOneWidget);
    expect(
      find.byKey(const ValueKey('dj_deck_download_error_a')),
      findsOneWidget,
    );
  });

  testWidgets('a deck with nothing downloadable renders copy only',
      (tester) async {
    await pumpNotice(
      tester,
      deck: refused(DjDeckLoadFailureKind.unavailableOffline),
      onDownload: (_) async {},
      downloadFor: (_) => DjDeckDownload.unavailable,
    );

    expect(copyOf(tester), djDeckDownloadRequired);
    expect(find.byKey(const ValueKey('dj_deck_download_a')), findsNothing);
  });

  testWidgets('with no DjDeckActions ancestor the lane renders copy only',
      (tester) async {
    await pumpNotice(
      tester,
      deck: refused(DjDeckLoadFailureKind.unavailableOffline),
      withActions: false,
    );

    expect(copyOf(tester), djDeckDownloadRequired);
    expect(find.byKey(const ValueKey('dj_deck_download_a')), findsNothing);
    expect(find.byKey(const ValueKey('dj_deck_load_file_a')), findsNothing);
    expect(find.bySemanticsLabel('Deck A waveform'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // The notice replaces an empty lane, so it must not paint an overflow banner
  // itself: copy plus an action exceeds the 64dp waveform-stack floor at an
  // accessibility font scale.
  for (final probe in <(String, DjViewport, double, double)>[
    ('a 300x120 freeform window', landscapeTinyWindow, 260, 28),
    ('the reference lane at textScale 1.6',
        landscapeReference.withTextScale(1.6), 380, 56),
  ]) {
    testWidgets('the notice and its action fit ${probe.$1}', (tester) async {
      final errors = DjErrorCollector()..install();
      addTearDown(errors.restore);

      await pumpNotice(
        tester,
        deck: refused(DjDeckLoadFailureKind.unavailableOffline),
        viewport: probe.$2,
        width: probe.$3,
        height: probe.$4,
        onDownload: (_) async {},
        downloadFor: (_) => DjDeckDownload.failed,
      );

      expect(errors.overflows, isEmpty,
          reason: 'the notice overflowed: ${errors.overflows}');
      expect(tester.takeException(), isNull);
    });
  }


  testWidgets("the load affordance carries its own deck's id", (tester) async {
    final picks = <DjDeckId>[];
    await pumpNotice(
      tester,
      deck: const DjDeckState(deckId: DjDeckId.b),
      onPickLocalFile: (deck) async => picks.add(deck),
    );

    await tester.tap(find.byKey(const ValueKey('dj_deck_load_file_b')));
    await tester.pump();

    // A deck-less callback here is what loaded deck A from deck B's button.
    expect(picks, [DjDeckId.b]);
  });

  testWidgets('an unseeded deck beside a full queue does not blame the queue',
      (tester) async {
    await pumpNotice(
      tester,
      deck: const DjDeckState(deckId: DjDeckId.b),
      queueHasTracks: true,
      onPickLocalFile: (_) async {},
    );

    expect(copyOf(tester, DjDeckId.b), djDeckNotSeeded);
    expect(find.text(djDeckEmpty), findsNothing);
    expect(find.byKey(const ValueKey('dj_deck_load_file_b')), findsOneWidget);
  });

  testWidgets('an unseeded deck beside an empty queue says how to fill it',
      (tester) async {
    await pumpNotice(
      tester,
      deck: const DjDeckState(deckId: DjDeckId.b),
      onPickLocalFile: (_) async {},
    );

    expect(copyOf(tester, DjDeckId.b), djDeckEmpty);
  });

  // docs/dj-deck-spec.md, geometry budget: 48dp targets everywhere at and above
  // the reference viewport, where each lane is 56dp tall.
  for (final probe in <(String, ValueKey<String>, DjDeckState)>[
    (
      'download',
      const ValueKey('dj_deck_download_a'),
      const DjDeckState(
        deckId: DjDeckId.a,
        loadFailure: DjDeckLoadFailure(
          kind: DjDeckLoadFailureKind.unavailableOffline,
        ),
      ),
    ),
    (
      'load-a-file',
      const ValueKey('dj_deck_load_file_a'),
      const DjDeckState(deckId: DjDeckId.a),
    ),
  ]) {
    testWidgets('the ${probe.$1} action keeps a 48dp target at the reference '
        'lane', (tester) async {
      await pumpNotice(
        tester,
        deck: probe.$3,
        onDownload: (_) async {},
        onPickLocalFile: (_) async {},
      );

      expect(
        tester.getSize(find.byKey(probe.$2)).height,
        greaterThanOrEqualTo(48.0),
      );
      expect(tester.takeException(), isNull);
    });
  }

  group('djDownloadTrackFor', () {
    test('synthesises the library row the download pipeline keys on', () {
      final queueTrack = djLoadedQueueTrack(id: '4242');
      final track = djDownloadTrackFor(queueTrack)!;

      expect(track.id, 4242);
      expect(track.identityHash, 'library-4242');
      expect(track.title, queueTrack.title);
      expect(track.artist, queueTrack.artist);
      expect(track.album, queueTrack.album);
      // QueueTrack.duration is whole seconds; the pipeline wants milliseconds.
      expect(track.durationMs, queueTrack.duration * 1000);
      expect(track.durationMs, queueTrack.durationMs);
    });

    test('refuses to fabricate an id for a row that has none', () {
      final sourceOnly = QueueTrack(
        id: 'queue-item-uuid',
        queueItemId: 'queue-item-uuid',
        title: 'Source-backed row',
        duration: 100,
        addedAt: DateTime.utc(2026, 8, 26),
      );

      expect(djDownloadTrackFor(sourceOnly), isNull);
    });
  });
}
