import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_context.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice.dart';

/// Seam preview borrows the one playback session and must hand it back
/// untouched. These tests drive the real [PlaybackState] against the real
/// queue timeline controller so "no state leaks after dismissal" is asserted
/// against actual queue/transport state rather than a spy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('preview seeks the lead-in before the seam and plays the plan',
      () async {
    final playback = _playbackState();
    addTearDown(playback.dispose);

    await playback.previewMixSeam(
      [_track(1, seconds: 200), _track(2, seconds: 200)],
      _plan(overlapMs: 10000),
      seamIndex: 0,
      leadIn: const Duration(seconds: 6),
    );
    await Future<void>.delayed(Duration.zero);

    expect(playback.isPreviewingMixSeam, isTrue);
    expect(playback.queue.map((item) => item.id), ['1', '2']);
    expect(playback.currentIndex, 0);
    // Outgoing clip is 200 s; the overlap starts at 190 s, so a 6 s lead-in
    // starts at 184 s.
    expect(playback.position, const Duration(seconds: 184));
    expect(playback.isPlaying, isTrue);
  });

  test('dismissing the preview restores the queue, position, and transport',
      () async {
    final playback = _playbackState();
    addTearDown(playback.dispose);

    const listeningContext = PlaybackContext(
      kind: PlaybackContextKind.album,
      label: 'Some album',
      id: '42',
    );
    await playback.playQueue(
      [_track(7, seconds: 120), _track(8, seconds: 120), _track(9, seconds: 120)],
      startIndex: 1,
      context: listeningContext,
    );
    await Future<void>.delayed(Duration.zero);
    await playback.seek(const Duration(seconds: 33));
    await Future<void>.delayed(Duration.zero);

    expect(playback.isPlaying, isTrue);

    await playback.previewMixSeam(
      [_track(1, seconds: 200), _track(2, seconds: 200)],
      _plan(overlapMs: 10000),
      seamIndex: 0,
      context: const PlaybackContext(
        kind: PlaybackContextKind.playlist,
        label: 'Mix QA',
        id: '7',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(playback.queue.map((item) => item.id), ['1', '2']);
    expect(playback.playbackContext?.id, '7');

    await playback.endMixSeamPreview();
    await Future<void>.delayed(Duration.zero);

    expect(playback.isPreviewingMixSeam, isFalse);
    expect(playback.queue.map((item) => item.id), ['7', '8', '9']);
    expect(playback.currentIndex, 1);
    expect(playback.currentItem?.id, '8');
    expect(playback.position, const Duration(seconds: 33));
    expect(playback.isPlaying, isTrue);
    expect(playback.playbackContext?.id, '42');
    expect(playback.playbackContext?.label, 'Some album');
  });

  test('a preview started while paused hands back a paused queue', () async {
    final playback = _playbackState();
    addTearDown(playback.dispose);

    await playback.playQueue([_track(7, seconds: 120)]);
    await Future<void>.delayed(Duration.zero);
    await playback.pause();
    await Future<void>.delayed(Duration.zero);
    expect(playback.isPlaying, isFalse);

    await playback.previewMixSeam(
      [_track(1, seconds: 200), _track(2, seconds: 200)],
      _plan(overlapMs: 10000),
      seamIndex: 0,
    );
    await Future<void>.delayed(Duration.zero);
    expect(playback.isPlaying, isTrue);

    await playback.endMixSeamPreview();
    await Future<void>.delayed(Duration.zero);

    expect(playback.queue.map((item) => item.id), ['7']);
    expect(playback.isPlaying, isFalse);
  });

  test('a preview started with nothing playing leaves an empty queue behind',
      () async {
    final playback = _playbackState();
    addTearDown(playback.dispose);

    expect(playback.queue, isEmpty);

    await playback.previewMixSeam(
      [_track(1, seconds: 200), _track(2, seconds: 200)],
      _plan(overlapMs: 10000),
      seamIndex: 0,
    );
    await Future<void>.delayed(Duration.zero);
    expect(playback.queue, hasLength(2));

    await playback.endMixSeamPreview();
    await Future<void>.delayed(Duration.zero);

    expect(playback.queue, isEmpty);
    expect(playback.isPlaying, isFalse);
    expect(playback.isPreviewingMixSeam, isFalse);
  });

  test('re-targeting a preview keeps the original listening snapshot',
      () async {
    final playback = _playbackState();
    addTearDown(playback.dispose);

    await playback.playQueue([_track(7, seconds: 120), _track(8, seconds: 120)]);
    await Future<void>.delayed(Duration.zero);

    final tracks = [
      _track(1, seconds: 200),
      _track(2, seconds: 200),
      _track(3, seconds: 200),
    ];
    final plan = _plan(overlapMs: 10000, trackIds: const ['1', '2', '3']);

    await playback.previewMixSeam(tracks, plan, seamIndex: 0);
    await Future<void>.delayed(Duration.zero);
    await playback.previewMixSeam(tracks, plan, seamIndex: 1);
    await Future<void>.delayed(Duration.zero);

    expect(playback.currentIndex, 1);

    await playback.endMixSeamPreview();
    await Future<void>.delayed(Duration.zero);

    // The second preview must not have snapshotted the first preview's queue.
    expect(playback.queue.map((item) => item.id), ['7', '8']);
    expect(playback.currentIndex, 0);
  });

  test('ending a preview that never started is a no-op', () async {
    final playback = _playbackState();
    addTearDown(playback.dispose);

    await playback.playQueue([_track(7, seconds: 120)]);
    await Future<void>.delayed(Duration.zero);

    await playback.endMixSeamPreview();
    await Future<void>.delayed(Duration.zero);

    expect(playback.queue.map((item) => item.id), ['7']);
    expect(playback.isPreviewingMixSeam, isFalse);
  });

  test('an out-of-range seam is refused without touching playback', () async {
    final playback = _playbackState();
    addTearDown(playback.dispose);

    await playback.playQueue([_track(7, seconds: 120)]);
    await Future<void>.delayed(Duration.zero);

    await playback.previewMixSeam(
      [_track(1, seconds: 200), _track(2, seconds: 200)],
      _plan(overlapMs: 10000),
      seamIndex: 1,
    );
    await Future<void>.delayed(Duration.zero);

    expect(playback.isPreviewingMixSeam, isFalse);
    expect(playback.queue.map((item) => item.id), ['7']);
  });
}

const int _clipDurationMs = 200000;

/// A generator-shaped plan: fades equal the placement overlap at every seam.
MixPlan _plan({
  required int overlapMs,
  List<String> trackIds = const ['1', '2'],
}) {
  final clips = <MixPlanClip>[];
  var timelineStartMs = 0;
  for (var index = 0; index < trackIds.length; index++) {
    clips.add(
      MixPlanClip(
        clipId: 'clip-${index + 1}',
        queueItemId: 'queue-${index + 1}',
        trackId: trackIds[index],
        sourceStartMs: 0,
        sourceEndMs: _clipDurationMs,
        timelineStartMs: timelineStartMs,
        fadeInMs: index > 0 ? overlapMs : null,
        fadeOutMs: index < trackIds.length - 1 ? overlapMs : null,
      ),
    );
    timelineStartMs += _clipDurationMs - overlapMs;
  }
  final now = DateTime.utc(2026, 8, 24);
  return MixPlan(
    id: 'preview-plan',
    schemaVersion: 1,
    name: 'Preview mix',
    clips: clips,
    summary: MixPlanSummary(
      clipCount: clips.length,
      trackIds: trackIds,
      durationMs: timelineStartMs + overlapMs,
    ),
    version: 1,
    createdAt: now,
    updatedAt: now,
  );
}

Map<String, dynamic> _track(int id, {required int seconds}) => {
      'id': id,
      'title': 'Track $id',
      'artist': 'Artist $id',
      'duration': seconds,
    };

PlaybackState _playbackState() {
  final engine = PlaybackEngine.withClock(
    clock: DefaultTimelineClock(
      now: () => DateTime.utc(2026),
      uiTickInterval: const Duration(hours: 1),
    ),
    voiceFactory: () => FakeVoice('v'),
  );
  return PlaybackState(
    engine,
    signedAudioUrlService: SignedAudioUrlService.withRequester((body) async {
      final ids = (body['trackIds'] as List).cast<int>();
      return {
        'urls': [
          for (final id in ids)
            {
              'trackId': id,
              'url': 'https://example.com/$id.mp3',
              'expiresAt': DateTime.utc(2027, 1, 1).toIso8601String(),
            },
        ],
        'unavailable': <Map<String, dynamic>>[],
      };
    }),
    persistence: QueuePersistenceStore(),
    persistenceDebounce: Duration.zero,
  );
}
