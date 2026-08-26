import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/core/providers/settings_provider.dart';
import 'package:open_music_player/features/dj/dj_deck_copy.dart';
import 'package:open_music_player/features/dj/dj_entry_hint.dart';
import 'package:open_music_player/features/settings/settings_screen.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart' as legacy_provider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/dj_viewport_fixtures.dart';
import '../../support/mock_dio_client.dart';

/// #414 proposed-scope item 4, answered: the deck's requirement is advertised
/// at the player action, at the settings toggle and in the deck's own lane
/// state, rather than by adding a second entry point.
void main() {
  group('djDeckEntryHint', () {
    test('exactly one of the eight combinations advertises anything', () {
      final advertised = <String>[];
      for (final djModeEnabled in <bool>[true, false]) {
        for (final hasCurrentTrack in <bool>[true, false]) {
          for (final currentTrackDownloaded in <bool>[true, false]) {
            final hint = djDeckEntryHint(
              djModeEnabled: djModeEnabled,
              hasCurrentTrack: hasCurrentTrack,
              currentTrackDownloaded: currentTrackDownloaded,
            );
            if (hint != null) {
              advertised.add(
                '$djModeEnabled/$hasCurrentTrack/$currentTrackDownloaded',
              );
              expect(hint, djDeckEntryDownloadHint);
            }
          }
        }
      }
      expect(advertised, ['true/true/false']);
    });
  });

  group('DjEntryHintBadge', () {
    testWidgets('badges the child only when there is something to say',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                DjEntryHintBadge(
                  hint: djDeckEntryDownloadHint,
                  child: Icon(Icons.graphic_eq),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('dj_entry_hint')), findsOneWidget);
      expect(find.byType(Badge), findsOneWidget);
      // Material's default badge colour is colorScheme.error. An advisory hint
      // painted alert-red re-creates the "the deck is broken" reading #414
      // exists to remove (#414 review).
      final scheme = Theme.of(
        tester.element(find.byKey(const ValueKey('dj_entry_hint'))),
      ).colorScheme;
      final badge = tester.widget<Badge>(find.byType(Badge));
      expect(badge.backgroundColor, isNotNull);
      expect(badge.backgroundColor, isNot(scheme.error));
      expect(badge.backgroundColor, scheme.secondary);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                DjEntryHintBadge(hint: null, child: Icon(Icons.graphic_eq)),
              ],
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('dj_entry_hint')), findsNothing);
      expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
    });
  });

  group('djDeckEntryHintFor', () {
    Future<String?> readHint(
      WidgetTester tester, {
      QueueProvider? queue,
      DownloadState? downloads,
    }) async {
      String? hint;
      Widget probe = Builder(
        builder: (context) {
          hint = djDeckEntryHintFor(context, djModeEnabled: true);
          return const SizedBox.shrink();
        },
      );
      if (downloads != null) {
        probe = legacy_provider.ChangeNotifierProvider<DownloadState>.value(
          value: downloads,
          child: probe,
        );
      }
      if (queue != null) {
        probe = legacy_provider.ChangeNotifierProvider<QueueProvider>.value(
          value: queue,
          child: probe,
        );
      }
      await tester.pumpWidget(MaterialApp(home: probe));
      return hint;
    }

    testWidgets('a narrow harness with neither provider gets null',
        (tester) async {
      expect(await readHint(tester), isNull);
    });

    testWidgets('a non-downloaded current track advertises the requirement',
        (tester) async {
      final queue = QueueProvider(
        _QueueApiClient(
          QueueState(tracks: [djLoadedQueueTrack(id: '4242')], currentIndex: 0),
        ),
      );
      addTearDown(queue.dispose);
      await queue.loadQueue();
      final downloads = _FakeDownloadState(const <int>{});
      addTearDown(downloads.dispose);

      final hint = await readHint(tester, queue: queue, downloads: downloads);
      expect(hint, djDeckEntryDownloadHint);
      // The deck also accepts playback-cache-backed sources, and no
      // synchronous cached-id fact exists to consult here, so the copy hedges
      // rather than instructing a download the deck may not need (#414 review;
      // follow-up recorded in docs/dj-deck-spec.md section 1).
      expect(hint, isNot(startsWith('Download this track')));
      expect(hint, contains('may need'));
    });

    // #414 review: a row with no numeric track id cannot be downloaded at all
    // (the pipeline keys on that id) and the deck refuses it for a different
    // reason, so the entry point must not advertise an impossible action.
    testWidgets('a row that cannot be downloaded advertises nothing',
        (tester) async {
      final queue = QueueProvider(
        _QueueApiClient(
          QueueState(
            tracks: [
              QueueTrack(
                id: 'queue-item-uuid',
                queueItemId: 'queue-item-uuid',
                title: 'Source-backed row',
                duration: 100,
                addedAt: DateTime.utc(2026, 8, 26),
              ),
            ],
            currentIndex: 0,
          ),
        ),
      );
      addTearDown(queue.dispose);
      await queue.loadQueue();
      final downloads = _FakeDownloadState(const <int>{});
      addTearDown(downloads.dispose);

      expect(
        await readHint(tester, queue: queue, downloads: downloads),
        isNull,
      );
    });

    testWidgets('a downloaded current track advertises nothing extra',
        (tester) async {
      final queue = QueueProvider(
        _QueueApiClient(
          QueueState(tracks: [djLoadedQueueTrack(id: '4242')], currentIndex: 0),
        ),
      );
      addTearDown(queue.dispose);
      await queue.loadQueue();
      final downloads = _FakeDownloadState(const <int>{4242});
      addTearDown(downloads.dispose);

      expect(
        await readHint(tester, queue: queue, downloads: downloads),
        isNull,
      );
    });
  });

  group('the settings toggle', () {
    testWidgets('advertises the deck requirement in its subtitle',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: SettingsPlaybackSection()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final subtitle = tester.widget<SwitchListTile>(
        find.byKey(const ValueKey('settings_dj_mode_toggle')),
      );
      expect((subtitle.subtitle! as Text).data, contains('landscape only'));
      expect(
        (subtitle.subtitle! as Text).data,
        contains(djDeckSettingsRequirement),
      );
      expect(find.textContaining('landscape only'), findsOneWidget);
    });
  });
}

class _QueueApiClient extends EmptyQueueApiClient {
  _QueueApiClient(this.state);
  final QueueState state;

  @override
  Future<QueueState> getQueue() async => state;
}

class _FakeDownloadState extends ChangeNotifier implements DownloadState {
  _FakeDownloadState(this._ids);
  final Set<int> _ids;

  @override
  Set<int> get downloadedTrackIds => _ids;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}
