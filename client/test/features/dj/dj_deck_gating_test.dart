
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/features/dj/dj_deck_copy.dart';
import 'package:open_music_player/features/dj/dj_screen.dart';
import 'package:open_music_player/features/dj/engine/deck_controller.dart';
import 'package:open_music_player/features/dj/models/dj_deck_state.dart';
import 'package:open_music_player/features/dj/models/dj_hot_cue.dart';
import 'package:open_music_player/features/dj/providers/dj_session_provider.dart';
import 'package:open_music_player/features/dj/widgets/dj_hot_cue_pads.dart';
import 'package:open_music_player/features/dj/widgets/dj_overview_strip.dart';
import 'package:open_music_player/features/dj/widgets/dj_transport.dart';
import 'package:open_music_player/models/track.dart';

import '../../support/dj_viewport_fixtures.dart';
import '../../support/fake_voice.dart';

/// #414 D3/D4/D12. On `origin/main` a deck holding no audio still presented a
/// fully coloured, fully armed CUE / PLAY / hot-cue row: PLAY latched
/// `playing == true` over silence, and a hot cue set on a zero-duration deck
/// divided by that duration in the overview strip. The sync glyph advertised
/// `sync engine: phase 2`.
void main() {
  group('DjTransport', () {
    /// [cue] records every press that reaches the cue contract.
    Future<void> pumpTransport(
      WidgetTester tester, {
      required double width,
      required bool enabled,
      String? disabledReason,
      List<String>? cue,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                height: 64, // the spec-pinned transport row height
                child: DjTransport(
                  playing: false,
                  enabled: enabled,
                  disabledReason: disabledReason,
                  onCuePress: () => cue?.add('press'),
                  onCueRelease: () => cue?.add('release'),
                  onPlayPause: () {},
                ),
              ),
            ),
          ),
        ),
      );
    }

    // 300dp is the labelled variant; 140dp is below kDjTransportCompactWidth,
    // so the gate cannot be lost in the icon-only branch.
    for (final width in <double>[300, 140]) {
      testWidgets('a deck with no audio arms nothing at ${width}dp',
          (tester) async {
        await pumpTransport(
          tester,
          width: width,
          enabled: false,
          disabledReason: djDeckDownloadRequired,
        );

        final cue = find.byKey(const ValueKey('dj_cue'));
        final play = find.byKey(const ValueKey('dj_play_pause'));

        if (width >= kDjTransportCompactWidth) {
          expect(tester.widget<FilledButton>(cue).onPressed, isNull);
        } else {
          expect(tester.widget<IconButton>(cue).onPressed, isNull);
        }
        expect(tester.widget<IconButton>(play).onPressed, isNull);

        for (final control in [cue, play]) {
          final tooltip = tester.widget<Tooltip>(
            find.ancestor(of: control, matching: find.byType(Tooltip)).first,
          );
          expect(tooltip.message, djDeckDownloadRequired);
        }

        // The pointer route is gated too: the cue contract is a Listener above
        // the button, so a disabled button alone would not stop a press.
        final gesture = await tester.startGesture(tester.getCenter(cue));
        await tester.pump();
        await gesture.up();
        await tester.pump();
        await tester.tap(cue, warnIfMissed: false);
        await tester.pump();
      });
    }

    // #414 review: `tooltip: enabled ? 'Cue' : null` stripped the only
    // accessible name these controls have — Tooltip maps to
    // SemanticsProperties.tooltip, not label, and the icons carry no
    // semanticLabel. The compact CUE and PLAY nodes came out byte-identical.
    for (final width in <double>[300, 140]) {
      testWidgets('a gated control keeps its name at ${width}dp',
          (tester) async {
        final handle = tester.ensureSemantics();
        await pumpTransport(
          tester,
          width: width,
          enabled: false,
          disabledReason: djDeckDownloadRequired,
        );

        final cue =
            tester.getSemantics(find.byKey(const ValueKey('dj_cue')));
        final play =
            tester.getSemantics(find.byKey(const ValueKey('dj_play_pause')));

        // Named: an icon-only control has to say which control it is.
        expect('${cue.label}${cue.tooltip}'.toLowerCase(), contains('cue'));
        expect('${play.label}${play.tooltip}'.toLowerCase(), contains('play'));
        // And the two are not interchangeable to a reader.
        expect(
          '${cue.label}|${cue.tooltip}',
          isNot('${play.label}|${play.tooltip}'),
        );
        // The reason still reaches the reader, on the node or its wrapper.
        expect(
          '${play.tooltip}${play.hint}',
          contains(djDeckDownloadRequired),
        );
        handle.dispose();
      });
    }

    testWidgets('a gated deck records no cue press or release',
        (tester) async {
      final cue = <String>[];
      await pumpTransport(
        tester,
        width: 300,
        enabled: false,
        disabledReason: djDeckDownloadRequired,
        cue: cue,
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('dj_cue'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('dj_cue')),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(cue, isEmpty);
    });

    testWidgets('a loaded deck still records the cue press/release pair',
        (tester) async {
      final cue = <String>[];
      await pumpTransport(tester, width: 300, enabled: true, cue: cue);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('dj_cue'))),
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(cue, ['press', 'release']);
    });

    testWidgets('a gated deck falls back to the generic reason',
        (tester) async {
      await pumpTransport(tester, width: 300, enabled: false);

      final tooltip = tester.widget<Tooltip>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('dj_play_pause')),
              matching: find.byType(Tooltip),
            )
            .first,
      );
      expect(tooltip.message, djDeckTransportDisabledReason);
    });

    testWidgets('a loaded deck is untouched', (tester) async {
      await pumpTransport(tester, width: 300, enabled: true);

      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('dj_cue')))
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('dj_play_pause')))
            .onPressed,
        isNotNull,
      );
    });

    testWidgets('an unwired sync glyph names the state it is actually in',
        (tester) async {
      // The glyph is live now (#413). A transport built without a session has
      // no partner deck to sync against, so its reason is that, not the old
      // roadmap line: `djDeckSyncUnavailable` no longer describes a real state
      // and has been removed from the copy contract.
      await pumpTransport(tester, width: 300, enabled: true);

      final tooltip = tester.widget<Tooltip>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('dj_sync')),
              matching: find.byType(Tooltip),
            )
            .first,
      );
      expect(tooltip.message, djDeckSyncOtherDeckUnavailable);
      expect(tooltip.message, isNot(contains('phase')));
      expect(find.byIcon(Icons.sync), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('dj_sync')))
            .onPressed,
        isNull,
      );
    });

    testWidgets('a wired sync glyph states each of its three live states',
        (tester) async {
      // Every state names the control before it describes itself, the same
      // 'Sync. <detail>' shape the gated glyph and `_name` already use: the
      // tooltip is the only text on this node, so a bare state phrase leaves a
      // screen-reader user unable to tell which control they are on.
      for (final state in <(bool, bool, String, String)>[
        (false, false, 'dj_sync_off_a', 'Sync. $djDeckSyncFollowAction'),
        (true, false, 'dj_sync_on_a', 'Sync. $djDeckSyncEngaged'),
        (false, true, 'dj_sync_master_a', 'Sync. $djDeckSyncMaster'),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 300,
                height: 64,
                child: DjTransport(
                  deck: DjDeckId.a,
                  playing: false,
                  onCuePress: () {},
                  onCueRelease: () {},
                  onPlayPause: () {},
                  onSync: () {},
                  syncEngaged: state.$1,
                  syncIsMaster: state.$2,
                ),
              ),
            ),
          ),
        );

        expect(find.byKey(ValueKey(state.$3)), findsOneWidget,
            reason: 'exactly one sync state marker is painted at a time');
        expect(find.byIcon(Icons.sync), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.byKey(const ValueKey('dj_sync')))
              .tooltip,
          state.$4,
        );
      }
    });
  });

  group('DjHotCuePads', () {
    testWidgets('a deck with no audio arms no pad', (tester) async {
      var triggers = 0;
      var sets = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 120,
              child: DjHotCuePads(
                cues: const {},
                enabled: false,
                onTrigger: (_) => triggers++,
                onSet: (_) => sets++,
              ),
            ),
          ),
        ),
      );

      for (var slot = 1; slot <= 4; slot++) {
        final pad = find.byKey(ValueKey('dj_hot_cue_$slot'));
        expect(tester.widget<FilledButton>(pad).onPressed, isNull);
        final detector = tester.widget<GestureDetector>(
          find.ancestor(of: pad, matching: find.byType(GestureDetector)).first,
        );
        expect(detector.onLongPress, isNull);
      }
      expect(triggers, 0);
      expect(sets, 0);
    });
  });

  group('DjOverviewStrip', () {
    testWidgets('a zero-duration deck cannot divide by it', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DjOverviewStrip(
              durationMs: 0,
              positionMs: 0,
              cues: const [DjHotCue(slot: 1, positionMs: 5000)],
              onSeek: (_) {},
            ),
          ),
        ),
      );

      final painter = tester
          .widget<CustomPaint>(
            find
                .descendant(
                  of: find.byKey(const ValueKey('dj_overview_strip')),
                  matching: find.byType(CustomPaint),
                )
                .first,
          )
          .painter! as DjOverviewPainter;

      expect(painter.cues, isEmpty);
      expect(painter.progress, 0);
      expect(painter.cues.any((cue) => cue.isNaN), isFalse);
      expect(tester.takeException(), isNull);
    });

    test('cue fractions are total over a zero duration', () {
      expect(
        djOverviewCueFractions(
          const [DjHotCue(slot: 1, positionMs: 5000)],
          0,
        ),
        isEmpty,
      );
      expect(
        djOverviewCueFractions(
          const [DjHotCue(slot: 1, positionMs: 5000)],
          10000,
        ),
        [0.5],
      );
    });
  });

  group('the deck screen', () {
    testWidgets('play reaches a loaded deck and never a refused one',
        (tester) async {
      landscapeReference.apply(tester);
      final session = DjSessionProvider(
        deckA: _deck(DjDeckId.a, const _RemoteResolver()),
        deckB: _deck(DjDeckId.b, const _LocalResolver()),
      );

      await tester.pumpWidget(
        MaterialApp(home: DjScreen(session: session)),
      );
      await tester.pump();
      await session.seed(current: _track('11'), next: _track('12'));
      await tester.pump();

      expect(session.deckA.isLoaded, isFalse);
      expect(session.deckB.isLoaded, isTrue);

      await tester.tap(
        find.byKey(const ValueKey('dj_play_pause')).first,
        warnIfMissed: false,
      );
      await tester.pump();
      expect(session.deckA.playing, isFalse,
          reason: 'a deck holding no audio must not latch playing');

      await tester.tap(find.byKey(const ValueKey('dj_play_pause')).last);
      await tester.pump();
      expect(session.deckB.playing, isTrue);

      // The pads are gated by dj_layout's `enabled: deck.isLoaded` wiring, not
      // by DjHotCuePads itself. Pumping the widget with a literal flag tests
      // the flag; this tests the wiring, so flipping it back to `true` fails
      // here instead of shipping four armed pads over silence (#414 review).
      // Deck A builds before deck B, and both decks default to DjPanel.cues.
      final padA = find.byKey(const ValueKey('dj_hot_cue_1')).first;
      final padB = find.byKey(const ValueKey('dj_hot_cue_1')).last;
      expect(tester.widget<FilledButton>(padA).onPressed, isNull,
          reason: 'a deck holding no audio must arm no pad');
      expect(tester.widget<FilledButton>(padB).onPressed, isNotNull);
      // onSet is the route that reached the zero-duration cue division.
      expect(
        tester
            .widget<GestureDetector>(
              find.ancestor(of: padA, matching: find.byType(GestureDetector))
                  .first,
            )
            .onLongPress,
        isNull,
      );
      expect(
        tester
            .widget<GestureDetector>(
              find.ancestor(of: padB, matching: find.byType(GestureDetector))
                  .first,
            )
            .onLongPress,
        isNotNull,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 20));
      session.dispose();
    });
  });
}

QueueTrack _track(String id) => QueueTrack(
      id: id,
      queueItemId: 'queue-item-$id',
      playbackTrackId: id,
      title: 'T$id',
      duration: 196,
      addedAt: DateTime.utc(2026, 8, 26),
    );

DeckController _deck(DjDeckId deckId, EngineAudioSourceResolver resolver) =>
    DeckController.empty(
      deckId: deckId,
      voice: FakeVoice('gating-${deckId.name}'),
      resolver: resolver,
      slew: const Duration(milliseconds: 1),
    );

class _LocalResolver implements EngineAudioSourceResolver {
  const _LocalResolver();
  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async =>
      ResolvedAudioSource.local(Uri.file('/tmp/local.mp3'));
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}

class _RemoteResolver implements EngineAudioSourceResolver {
  const _RemoteResolver();
  @override
  Future<ResolvedAudioSource> resolve(dynamic clip) async =>
      ResolvedAudioSource.remote(
          Uri(scheme: 'https', host: 'example.test'), null);
  @override
  Future<void> warm(String audioSourceRef,
      {required Set<String> protect}) async {}
}
