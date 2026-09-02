import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/app/theme.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/features/playlists/harmonic_discovery_sheet.dart';
import 'package:open_music_player/models/nearby_tracks.dart';

typedef _Query = ({
  double bpm,
  String camelot,
  double tolerance,
  bool orderByHistory,
});

const _fullMatch = NearbyTrack(
  id: 11,
  title: 'Anchor Neighbour',
  artist: 'Neighbour Artist',
  bpm: 126,
  camelot: '9A',
);

/// The row the em-dash rule exists for: in the library, harmonically returned,
/// but with nothing analyzed to show.
const _unanalyzedMatch = NearbyTrack(id: 12, title: 'Unanalyzed Neighbour');

NearbyTracksResult _result(
  List<NearbyTrack> tracks, {
  bool orderedByHistory = true,
}) =>
    NearbyTracksResult(
      tracks: tracks,
      bpm: 124,
      camelot: '8A',
      tolerance: 5,
      orderedByHistory: orderedByHistory,
    );

Future<NearbyTracksResult> _results() async => _result([
      _fullMatch,
      _unanalyzedMatch,
    ]);

Future<NearbyTracksResult> _empty() async => _result(const []);

Future<NearbyTracksResult> _disabled() async =>
    throw ApiException('Failed to load nearby tracks', 404);

/// A [HarmonicSearch] that records every query and answers from [responses]
/// in order (the last entry repeats). A `Future<NearbyTracksResult>` that
/// throws models a transport failure.
HarmonicSearch _recordingSearch(
  List<_Query> log,
  List<Future<NearbyTracksResult> Function()> responses,
) {
  return ({
    required double bpm,
    required String camelot,
    required double tolerance,
    required bool orderByHistory,
  }) {
    log.add((
      bpm: bpm,
      camelot: camelot,
      tolerance: tolerance,
      orderByHistory: orderByHistory,
    ));
    final index = log.length - 1;
    return responses[index < responses.length ? index : responses.length - 1]();
  };
}

Future<List<NearbyTrack>> _pumpSheet(
  WidgetTester tester, {
  required HarmonicSearch search,
  double? seedBpm,
  String? seedCamelot,
  int? excludeTrackId,
  List<NearbyTrack>? queued,
  List<NearbyTrack>? added,
  ThemeData? theme,
}) async {
  final queuedMatches = queued ?? <NearbyTrack>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Scaffold(
        body: HarmonicDiscoverySheet(
          search: search,
          playlistName: 'Late Night',
          seedBpm: seedBpm,
          seedCamelot: seedCamelot,
          excludeTrackId: excludeTrackId,
          onAddToQueue: (match) async => queuedMatches.add(match),
          onAddToPlaylist: (match) async => added?.add(match),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return queuedMatches;
}

Future<void> _enterQuery(
  WidgetTester tester, {
  String bpm = '124',
  String camelot = '8A',
  String tolerance = '5',
}) async {
  await tester.enterText(find.byKey(const ValueKey('harmonic_bpm_field')), bpm);
  await tester.enterText(
    find.byKey(const ValueKey('harmonic_camelot_field')),
    camelot,
  );
  await tester.enterText(
    find.byKey(const ValueKey('harmonic_tolerance_field')),
    tolerance,
  );
  await tester.pump();
}

/// Opens the sheet through its real `show()` modal path, so the bottom-sheet
/// chrome and height constraints are part of what the test measures — the bare
/// harness above cannot see them.
Future<void> _showSheet(
  WidgetTester tester, {
  required HarmonicSearch search,
  double? seedBpm,
  String? seedCamelot,
  ThemeData? theme,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => HarmonicDiscoverySheet.show(
                context,
                search: search,
                playlistName: 'Late Night',
                seedBpm: seedBpm,
                seedCamelot: seedCamelot,
                onAddToQueue: (_) async {},
                onAddToPlaylist: (_) async {},
              ),
              child: const Text('open discovery'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open discovery'));
  await tester.pumpAndSettle();
}

/// Pins a logical viewport and soft-keyboard inset for one test. The default
/// 800x600 test surface hides every phone-sized layout failure.
void _useViewport(
  WidgetTester tester,
  Size logicalSize, {
  double keyboard = 0,
}) {
  const ratio = 3.0;
  tester.view.devicePixelRatio = ratio;
  tester.view.physicalSize = logicalSize * ratio;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard * ratio);
  addTearDown(tester.view.reset);
}

VoidCallback? _searchButtonCallback(WidgetTester tester) => tester
    .widget<FilledButton>(
      find.byKey(const ValueKey('harmonic_search_button')),
    )
    .onPressed;

VoidCallback? _retryButtonCallback(WidgetTester tester) => tester
    .widget<FilledButton>(
      find.byKey(const ValueKey('harmonic_discovery_retry')),
    )
    .onPressed;

void main() {
  group('seeding and the query', () {
    testWidgets('an analyzed anchor searches once, ordered by history',
        (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [
          () async => _result([_fullMatch])
        ]),
        seedBpm: 124,
        seedCamelot: '8A',
      );

      expect(log, hasLength(1));
      expect(log.single.bpm, 124.0);
      expect(log.single.camelot, '8A');
      expect(log.single.tolerance, 5.0);
      expect(log.single.orderByHistory, isTrue);
      expect(
        find.byKey(const ValueKey('harmonic_discovery_history_caption')),
        findsOneWidget,
      );
    });

    testWidgets('turning the history toggle off re-queries without it',
        (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [
          () async => _result([_fullMatch]),
          () async => _result([_fullMatch], orderedByHistory: false),
        ]),
        seedBpm: 124,
        seedCamelot: '8A',
      );

      await tester.tap(
        find.byKey(const ValueKey('harmonic_history_order_toggle')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('harmonic_search_button')));
      await tester.pumpAndSettle();

      expect(log, hasLength(2));
      expect(log.last.orderByHistory, isFalse);
      expect(
        find.byKey(const ValueKey('harmonic_discovery_history_caption')),
        findsNothing,
      );
    });

    testWidgets('an unseeded sheet stays idle until the user searches',
        (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [
          () async => _result([_fullMatch])
        ]),
      );

      expect(log, isEmpty);
      expect(
        find.byKey(const ValueKey('harmonic_discovery_idle')),
        findsOneWidget,
      );

      await _enterQuery(tester);
      await tester.tap(find.byKey(const ValueKey('harmonic_search_button')));
      await tester.pumpAndSettle();

      expect(log, hasLength(1));
      expect(
        find.byKey(const ValueKey('harmonic_result_11')),
        findsOneWidget,
      );
    });

    testWidgets('an off-wheel key cannot be submitted at all', (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [
          () async => _result([_fullMatch])
        ]),
      );

      await _enterQuery(tester, camelot: '13Z');

      expect(_searchButtonCallback(tester), isNull);
      expect(
        find.text('Enter a tempo in BPM and a Camelot key like 8A.'),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('harmonic_search_button')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(log, isEmpty);
    });

    testWidgets('the anchor track is filtered out of its own results',
        (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(
          log,
          [
            () async => _result([_fullMatch, _unanalyzedMatch])
          ],
        ),
        seedBpm: 124,
        seedCamelot: '8A',
        excludeTrackId: _fullMatch.id,
      );

      expect(find.byKey(const ValueKey('harmonic_result_11')), findsNothing);
      expect(find.byKey(const ValueKey('harmonic_result_12')), findsOneWidget);
    });
  });

  group('states', () {
    testWidgets(
        'results render chips, with an em-dash fallback for a row '
        'with no analysis', (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(
          log,
          [
            () async => _result([_fullMatch, _unanalyzedMatch])
          ],
        ),
        seedBpm: 124,
        seedCamelot: '8A',
      );

      expect(find.text('Anchor Neighbour'), findsOneWidget);
      expect(find.text('Neighbour Artist'), findsOneWidget);
      expect(find.text('126 BPM'), findsOneWidget);
      expect(find.text('9A'), findsOneWidget);

      final unanalyzedRow = find.byKey(const ValueKey('harmonic_result_12'));
      expect(unanalyzedRow, findsOneWidget);
      expect(
        find.descendant(
            of: unanalyzedRow, matching: find.text('Unknown artist')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: unanalyzedRow, matching: find.text('—')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: unanalyzedRow,
          matching: find.textContaining('BPM'),
        ),
        findsNothing,
      );
    });

    testWidgets('an empty library match set has its own copy', (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [() async => _result(const [])]),
        seedBpm: 124,
        seedCamelot: '8A',
      );

      expect(
        find.byKey(const ValueKey('harmonic_discovery_empty')),
        findsOneWidget,
      );
      expect(
        find.text('No harmonic matches in your library yet.'),
        findsOneWidget,
      );
      expect(
        find.text('Try a wider tempo range, or analyze more tracks.'),
        findsOneWidget,
      );
    });

    testWidgets('a request in flight shows the loading state', (tester) async {
      final log = <_Query>[];
      final gate = Completer<NearbyTracksResult>();
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [() => gate.future]),
      );

      await _enterQuery(tester);
      await tester.tap(find.byKey(const ValueKey('harmonic_search_button')));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('harmonic_discovery_loading')),
        findsOneWidget,
      );
      expect(_searchButtonCallback(tester), isNull);

      gate.complete(_result([_fullMatch]));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('harmonic_discovery_loading')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('harmonic_result_11')), findsOneWidget);
    });

    testWidgets('a disabled server route says so, and Retry recovers',
        (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [
          () async => throw ApiException('Failed to load nearby tracks', 404),
          () async => _result([_fullMatch]),
        ]),
        seedBpm: 124,
        seedCamelot: '8A',
      );

      expect(
        find.byKey(const ValueKey('harmonic_discovery_error')),
        findsOneWidget,
      );
      expect(
        find.text('Harmonic matching is turned off on this server.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('harmonic_discovery_retry')));
      await tester.pumpAndSettle();

      expect(log, hasLength(2));
      expect(log.last.bpm, 124.0, reason: 'Retry re-issues the same query');
      expect(
        find.byKey(const ValueKey('harmonic_discovery_error')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('harmonic_result_11')), findsOneWidget);
    });

    testWidgets('any other failure gets the generic retryable copy',
        (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [
          () async => throw ApiException('Failed to load nearby tracks', 500),
        ]),
        seedBpm: 124,
        seedCamelot: '8A',
      );

      expect(
        find.text('Could not load harmonic matches. Try again.'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('harmonic_discovery_retry')),
        findsOneWidget,
      );
    });
  });

  group('result actions', () {
    testWidgets('a result offers queue and playlist actions', (tester) async {
      final log = <_Query>[];
      final queued = <NearbyTrack>[];
      final added = <NearbyTrack>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(
          log,
          [
            () async => _result([_fullMatch, _unanalyzedMatch])
          ],
        ),
        seedBpm: 124,
        seedCamelot: '8A',
        queued: queued,
        added: added,
      );

      await tester.tap(find.byKey(const ValueKey('harmonic_result_11')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('harmonic_action_add_to_queue')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('harmonic_action_add_to_playlist')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('harmonic_action_add_to_queue')),
      );
      await tester.pumpAndSettle();

      expect(queued, hasLength(1));
      expect(queued.single.id, _fullMatch.id);
      expect(added, isEmpty);
      expect(
        find.byKey(const ValueKey('harmonic_action_add_to_queue')),
        findsNothing,
        reason: 'the actions sheet closes behind the action',
      );

      await tester.tap(find.byKey(const ValueKey('harmonic_result_12')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('harmonic_action_add_to_playlist')),
      );
      await tester.pumpAndSettle();

      expect(added, hasLength(1));
      expect(added.single.id, _unanalyzedMatch.id);
      expect(queued, hasLength(1));
      expect(
        find.byKey(const ValueKey('harmonic_action_add_to_playlist')),
        findsNothing,
      );
    });
  });

  group('input bounds', () {
    /// The client is the only ceiling in the stack: `ApiClient` forwards the
    /// tolerance verbatim and the handler rejects only NaN/Inf/negatives.
    testWidgets('out-of-range tempo and tolerance cannot be submitted',
        (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [
          () async => _result([_fullMatch])
        ]),
      );

      for (final bpm in const ['0', '301', 'abc', '']) {
        await _enterQuery(tester, bpm: bpm);
        expect(_searchButtonCallback(tester), isNull, reason: 'bpm "$bpm"');
      }
      for (final tolerance in const ['-1', '51', 'abc', '']) {
        await _enterQuery(tester, tolerance: tolerance);
        expect(
          _searchButtonCallback(tester),
          isNull,
          reason: 'tolerance "$tolerance"',
        );
      }

      await tester.pumpAndSettle();
      expect(log, isEmpty);
    });

    testWidgets('the bounds are inclusive at both ceilings', (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [
          () async => _result([_fullMatch])
        ]),
      );

      await _enterQuery(tester, bpm: '300', tolerance: '50');
      expect(_searchButtonCallback(tester), isNotNull);

      await tester.tap(find.byKey(const ValueKey('harmonic_search_button')));
      await tester.pumpAndSettle();

      expect(log, hasLength(1));
      expect(log.single.bpm, 300.0);
      expect(log.single.tolerance, 50.0);
    });

    testWidgets('Retry disables with the query it would re-issue',
        (tester) async {
      final log = <_Query>[];
      await _pumpSheet(
        tester,
        search: _recordingSearch(log, [
          () async => throw ApiException('Failed to load nearby tracks', 500),
        ]),
        seedBpm: 124,
        seedCamelot: '8A',
      );

      expect(_retryButtonCallback(tester), isNotNull);

      await tester.enterText(
        find.byKey(const ValueKey('harmonic_bpm_field')),
        '',
      );
      await tester.pump();

      expect(
        _retryButtonCallback(tester),
        isNull,
        reason: 'an enabled Retry that silently does nothing reads as broken',
      );

      await tester.tap(
        find.byKey(const ValueKey('harmonic_discovery_retry')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(log, hasLength(1), reason: 'no second request was issued');
    });
  });

  group('layout and tokens', () {
    for (final viewport in const <({String name, Size size, double keyboard})>[
      (
        name: '360x640 with an ordinary soft keyboard',
        size: Size(360, 640),
        keyboard: 216
      ),
      (
        name: '360x640 with a tall soft keyboard',
        size: Size(360, 640),
        keyboard: 290
      ),
      (
        name: '375x667 with a soft keyboard',
        size: Size(375, 667),
        keyboard: 260
      ),
      (
        name: '320x568 with a soft keyboard',
        size: Size(320, 568),
        keyboard: 216
      ),
      (name: '640x360 landscape', size: Size(640, 360), keyboard: 0),
    ]) {
      testWidgets('the modal sheet does not overflow at ${viewport.name}',
          (tester) async {
        _useViewport(tester, viewport.size, keyboard: viewport.keyboard);
        final log = <_Query>[];

        // Unseeded is the case that forces typing, and so the case that opens
        // the keyboard: the validation hint is showing and nothing has
        // collapsed the results region yet.
        await _showSheet(
          tester,
          search: _recordingSearch(log, [
            () async => _result([_fullMatch])
          ]),
        );
        expect(tester.takeException(), isNull);

        await _enterQuery(tester);
        // Reachable by scrolling is the whole point: on a short viewport the
        // primary action sits under the keyboard until the sheet scrolls.
        await tester.ensureVisible(
          find.byKey(const ValueKey('harmonic_search_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('harmonic_search_button')));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(
            find.byKey(const ValueKey('harmonic_result_11')), findsOneWidget);
      });
    }

    for (final theme in <({String name, ThemeData data})>[
      (name: 'light', data: AppTheme.lightTheme),
      (name: 'dark', data: AppTheme.darkTheme),
    ]) {
      for (final state in <({
        String name,
        Future<NearbyTracksResult> Function() answer,
      })>[
        (name: 'results', answer: _results),
        (name: 'empty', answer: _empty),
        (name: 'error', answer: _disabled),
      ]) {
        testWidgets(
            'the ${state.name} state meets AA contrast and tap targets in '
            '${theme.name} theme', (tester) async {
          final handle = tester.ensureSemantics();
          final log = <_Query>[];
          await _pumpSheet(
            tester,
            search: _recordingSearch(log, [state.answer]),
            seedBpm: 124,
            seedCamelot: '8A',
            theme: theme.data,
          );

          await expectLater(tester, meetsGuideline(textContrastGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          handle.dispose();
        });
      }
    }
  });
}
