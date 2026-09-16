import 'dart:async';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/download/download_state.dart';
import 'package:open_music_player/models/track.dart' show QueueTrack;
import 'package:open_music_player/models/track_analysis.dart'
    show analysisPlaybackFields;
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:provider/provider.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_voice.dart';

/// Playback-truth fixtures for the DJ surfaces (ADR 0012 step 3).
///
/// The deck reads "what is playing" from the playback queue, so its tests need
/// playback truth rather than an import-queue snapshot. Two shapes live here:
///
/// * [testPlaybackState] — the real production object graph over [FakeVoice]s,
///   for plain `test()`s where real async is available.
/// * [TestPlaybackState] — a [PlaybackState] whose *state* is injected and
///   whose *projection methods are the real ones*. Widget tests need this:
///   the deck's post-frame callback awaits `PlaybackState.pause()`, and the
///   engine's transport chain cannot drain inside a widget test's fake-async
///   zone, so a real engine would stall the seed before it ran.

/// The playback-json payload for a library track, shaped like the resolver's
/// input (numeric id, whole-second duration).
Map<String, dynamic> playbackTrackPayload(
  int id, {
  String? title,
  String artist = 'Fixture artist',
  int seconds = 245,
}) =>
    {
      'id': id,
      'title': title ?? 'Track $id',
      'artist': artist,
      'album': 'Fixture album',
      'duration': seconds,
    };

/// The media item the source resolver produces for [id]: numeric string id,
/// whole-second duration, and a local artifact path.
///
/// `localPath` matters: `CueTimeline.fromSession` needs a resolvable audio
/// source for every cue, and a bare remote item would throw at cue-build time.
/// The deck plays local/cache-backed sources only anyway
/// (docs/dj-deck-spec.md, Phase 0 item 3), so this is the shape the deck
/// actually receives.
MediaItem playbackMediaItem(
  int id, {
  String? title,
  String artist = 'Fixture artist',
  int seconds = 245,
}) =>
    MediaItem(
      id: '$id',
      title: title ?? 'Track $id',
      artist: artist,
      album: 'Fixture album',
      duration: Duration(seconds: seconds),
      extras: {'localPath': '/tmp/dj-fixture-$id.mp3'},
    );

/// A real [PlaybackState] over [FakeVoice]s with a deterministic clock.
///
/// The clock's periodic UI tick is parked an hour out, so tests drive position
/// by hand or not at all. Use in plain `test()`s; see the library doc for why
/// widget tests want [TestPlaybackState] instead.
///
/// The engine only disposes a clock it created itself, so this fixture keeps
/// the clock alongside the state it hands back and retires both together —
/// otherwise the clock's periodic tick survives the test as a pending timer.
PlaybackState testPlaybackState({PlaybackEngine? engine}) {
  SharedPreferences.setMockInitialValues({});
  final clock = engine == null
      ? DefaultTimelineClock(
          now: () => DateTime.utc(2026),
          uiTickInterval: const Duration(hours: 1),
        )
      : null;
  final playback = PlaybackState(
    engine ??
        PlaybackEngine.withClock(
          clock: clock!,
          voiceFactory: () => FakeVoice('playback'),
        ),
    signedAudioUrlService: SignedAudioUrlService.withRequester((body) async {
      final ids = (body['trackIds'] as List).cast<int>();
      return {
        'urls': [
          for (final id in ids)
            {
              'trackId': id,
              'url': 'https://example.com/$id.mp3',
              'expiresAt': DateTime.utc(2027).toIso8601String(),
            },
        ],
        'unavailable': <Map<String, dynamic>>[],
      };
    }),
    persistence: QueuePersistenceStore(),
    persistenceDebounce: Duration.zero,
  );
  if (clock != null) testOwnedClocks[playback] = clock;
  return playback;
}

/// The clocks owned by [testPlaybackState], keyed by the state they drive.
final Map<PlaybackState, DefaultTimelineClock> testOwnedClocks =
    <PlaybackState, DefaultTimelineClock>{};

/// Disposes [playback] and the clock this library injected into its engine.
///
/// Use instead of `playback.dispose()` in widget tests: the binding asserts no
/// timers are pending after the tree is torn down, and the engine deliberately
/// leaves an injected clock alone.
///
/// Pass [tester] from a widget test. `PlaybackState.dispose()` starts the
/// controller's teardown with `unawaited(...)`, and the voice pool's periodic
/// timers are only cancelled partway down that chain — so without pumping here
/// the binding's pending-timer check fires on timers that are already on their
/// way out.
Future<void> disposeTestPlaybackState(
  PlaybackState playback, {
  WidgetTester? tester,
}) async {
  playback.dispose();
  if (tester != null) {
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }
  final clock = testOwnedClocks.remove(playback);
  if (clock != null) await clock.dispose();
}

/// Plays [ids] as a collection — the "play an album" path, which populates the
/// listening queue while leaving any import queue untouched.
///
/// Plain-`test()` only: it awaits the engine's transport chain.
Future<void> playAlbum(
  PlaybackState playback,
  List<int> ids, {
  int startIndex = 0,
}) async {
  await playback.playQueue(
    [for (final id in ids) playbackTrackPayload(id)],
    startIndex: startIndex,
  );
}

/// Builds the snapshot a real controller would publish for [queue] at
/// [currentIndex], using the real cue builder so cue ids, queue item ids and
/// play order are production-shaped rather than hand-written.
///
/// An empty [queue] yields the empty snapshot the controller publishes before
/// anything is restored (`main.dart:122` is `unawaited(restore())`).
PlaybackSnapshot playbackSnapshotFor({
  required List<MediaItem> queue,
  required int currentIndex,
  List<int>? playOrder,
  String sessionId = 'session_fixture',
}) {
  if (queue.isEmpty) {
    return PlaybackSnapshot.empty(sessionId: sessionId);
  }
  final order = playOrder ?? [for (var i = 0; i < queue.length; i++) i];
  final session = MixSession.fromQueue(sessionId: sessionId, queue: queue);
  final timeline = CueTimeline.fromSession(
    session: session,
    queue: queue,
    playOrder: order,
  );
  final cue = timeline.cues.firstWhere(
    (candidate) => candidate.queueIndex == currentIndex,
    orElse: () => timeline.cues.first,
  );
  return PlaybackSnapshot(
    sessionId: sessionId,
    cues: timeline.cues,
    currentCueId: cue.cueId,
    currentQueueIndex: currentIndex,
    currentMediaItem: cue.mediaItem,
    localPosition: Duration.zero,
    localDuration: cue.selectedDuration,
    globalPosition: Duration.zero,
    globalDuration: timeline.duration,
    playing: false,
    processingState: ProcessingState.ready,
    activeVoiceCount: 1,
  );
}

/// A [PlaybackState] with injected queue state whose projection methods are the
/// production ones.
///
/// Only state reads are overridden — [snapshot], [snapshotStream], [queue] and
/// the play order that backs [nextQueueIndexInPlayOrder]. Everything the DJ
/// deck asks for (`djPlaybackSignalFor`, `currentPlaybackTrack`,
/// `nextPlaybackTrack`, `playbackQueueTailTrackId`) runs the real projection
/// code over that injected state, which is what makes deck tests about the
/// production adapter rather than about a second fake of it.
///
/// Transport is inert: the deck's post-frame `pause()` completes immediately.
/// A widget test's fake-async zone cannot drain the engine's transport chain,
/// so awaiting the real one would stall the seed before it ran.
class TestPlaybackState extends PlaybackState {
  TestPlaybackState({
    required List<MediaItem> queue,
    required int currentIndex,
    List<int>? playOrder,
    String sessionId = 'session_fixture',
  })  : _queue = List.unmodifiable(queue),
        _playOrder = List.unmodifiable(
          playOrder ?? [for (var i = 0; i < queue.length; i++) i],
        ),
        super(
          PlaybackEngine.withClock(
            clock: DefaultTimelineClock(
              now: () => DateTime.utc(2026),
              uiTickInterval: const Duration(hours: 1),
            ),
            voiceFactory: () => FakeVoice('fake-playback'),
          ),
          signedAudioUrlService: SignedAudioUrlService.withRequester(
            (body) async => {
              'urls': <Map<String, dynamic>>[],
              'unavailable': <Map<String, dynamic>>[],
            },
          ),
        ) {
    _subject.add(
      playbackSnapshotFor(
        queue: _queue,
        currentIndex: currentIndex,
        playOrder: _playOrder,
        sessionId: sessionId,
      ),
    );
  }

  List<MediaItem> _queue;
  List<int> _playOrder;
  final BehaviorSubject<PlaybackSnapshot> _subject =
      BehaviorSubject<PlaybackSnapshot>();

  @override
  ValueStream<PlaybackSnapshot> get snapshotStream => _subject.stream;

  @override
  PlaybackSnapshot get snapshot => _subject.value;

  @override
  List<MediaItem> get queue => _queue;

  @override
  int? get currentIndex => _subject.value.currentQueueIndex;

  /// The queue index that plays after [queueIndex] in the injected play order.
  @override
  int? nextQueueIndexInPlayOrder(int queueIndex) {
    final position = _playOrder.indexOf(queueIndex);
    if (position == -1 || position + 1 >= _playOrder.length) return null;
    return _playOrder[position + 1];
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  /// Moves playback to [currentIndex] and republishes, so a test can prove the
  /// deck follows a live track change rather than only its first frame.
  ///
  /// [playOrder] replaces the play order, which is how a shuffle arrives.
  void emitTrackChange({required int currentIndex, List<int>? playOrder}) {
    _subject.add(
      playbackSnapshotFor(
        queue: _queue,
        currentIndex: currentIndex,
        playOrder: playOrder ?? _playOrder,
      ),
    );
  }

  /// Installs [items] as the playback queue and republishes at index 0.
  ///
  /// This is the shape of `PlaybackState.restore()` completing after the deck
  /// mounted: the queue was empty at first frame and lands later (#409).
  void replaceQueueForTest(List<MediaItem> items) {
    _queue = List.unmodifiable(items);
    // The play order is a function of queue length, so it has to be rebuilt
    // here — a stale order would make every "next" lookup return null.
    _playOrder = [for (var i = 0; i < _queue.length; i++) i];
    _subject.add(
      playbackSnapshotFor(
        queue: _queue,
        currentIndex: 0,
        playOrder: _playOrder,
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_subject.close());
    super.dispose();
  }
}

/// A [TestPlaybackState] built from queue rows a DJ test already has.
///
/// The deck seeds from playback truth now, so a DJ widget test needs playback
/// state rather than a `QueueProvider` snapshot. This adapts rows — which carry
/// the analysis, title, artist and duration the deck lanes assert on — into the
/// media items a real controller would hold, preserving the numeric id the
/// resolver and the download pipeline key on.
///
/// Analysis is carried into the item's extras the same way
/// `PlaybackSourceResolver._mediaItem` does it, because
/// `playbackTrackForMediaItem` reads it back from there. Dropping it would
/// strand the deck header on `-- BPM` while the deck itself looked healthy.
///
/// [rows] order becomes the queue order; [currentIndex] picks the playing row.
TestPlaybackState testPlaybackStateForRows(
  List<QueueTrack> rows, {
  int currentIndex = 0,
  List<int>? playOrder,
}) {
  final items = <MediaItem>[];
  for (final row in rows) {
    final item = playbackMediaItem(
      int.tryParse(row.playbackTrackId ?? row.id) ?? 0,
      title: row.title,
      artist: row.artist ?? '',
      // QueueTrack.duration is whole seconds; the fixture helper takes seconds.
      seconds: row.duration,
    );
    final analysisFields = analysisPlaybackFields(row.analysis);
    items.add(
      analysisFields.isEmpty
          ? item
          : item.copyWith(extras: {...?item.extras, ...analysisFields}),
    );
  }
  return TestPlaybackState(
    queue: items,
    currentIndex: currentIndex,
    playOrder: playOrder,
  );
}

/// Installs [playback] and, optionally, [importQueue] / [downloads] above
/// [child].
///
/// The two queues stay separate on purpose: playback truth answers "what is
/// playing", and the import queue answers "which analysis has hydrated". A deck
/// test that needs waveform peaks passes both.
Widget djPlaybackProviders({
  required TestPlaybackState playback,
  QueueProvider? importQueue,
  DownloadState? downloads,
  required Widget child,
}) {
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<PlaybackState>.value(value: playback),
      if (importQueue != null)
        ChangeNotifierProvider<QueueProvider>.value(value: importQueue),
      if (downloads != null)
        ChangeNotifierProvider<DownloadState>.value(value: downloads),
    ],
    child: child,
  );
}
