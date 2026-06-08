import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/providers/queue_provider.dart';
import 'package:open_music_player/services/api_client.dart';

Track _track({
  String id = '7',
  String queueItemId = 'queue-7',
  String? playbackTrackId = '7',
  int duration = 240,
}) =>
    Track(
      id: id,
      queueItemId: queueItemId,
      playbackTrackId: playbackTrackId,
      title: 'Track $id',
      artist: 'Artist $id',
      duration: duration,
      addedAt: DateTime.utc(2026, 1, 1),
    );

void main() {
  test('mix plan clips feed timeline placement and trim state when available',
      () {
    final provider = QueueProvider(ApiClient());
    final track = _track();
    final fallback = TimelineClip.clamped(
      id: 'clip_${track.id}',
      trackId: track.id,
      sourceDurationMs: track.durationMs,
      sourceStartMs: 0,
      sourceEndMs: track.durationMs,
      timelineStartMs: 0,
    );

    provider.applyMixPlanClips([
      MixPlanClip(
        clipId: 'clip-7',
        queueItemId: track.queueItemId,
        trackId: track.playbackTrackId!,
        sourceStartMs: 12000,
        sourceEndMs: 180000,
        timelineStartMs: 42000,
      ),
    ]);

    expect(provider.trimRangeFor(track).startOffsetMs, 12000);
    expect(provider.trimRangeFor(track).endOffsetMs, 180000);
    expect(provider.timelineClipFor(track, fallback).timelineStartMs, 42000);
    expect(provider.timelineClipFor(track, fallback).sourceStartMs, 12000);
  });

  test(
      'timeline edit gestures update mix plan contract fields without local-only trim regression',
      () {
    final provider = QueueProvider(ApiClient());
    final track = _track();
    provider.applyMixPlanClips([
      MixPlanClip(
        clipId: 'clip-7',
        queueItemId: track.queueItemId,
        trackId: track.playbackTrackId!,
        sourceStartMs: 0,
        sourceEndMs: track.durationMs,
        timelineStartMs: 10000,
      ),
    ]);

    provider.setTimelineStartMs(track, 25000);
    provider.setStartOffsetMs(track, 30000);
    provider.setEndOffsetMs(track, 190000);

    final fallback = TimelineClip.clamped(
      id: 'clip_${track.id}',
      trackId: track.id,
      sourceDurationMs: track.durationMs,
      sourceStartMs: 0,
      sourceEndMs: track.durationMs,
      timelineStartMs: 0,
    );
    final edited = provider.timelineClipFor(track, fallback);

    expect(edited.timelineStartMs, 25000);
    expect(edited.sourceStartMs, 30000);
    expect(edited.sourceEndMs, 190000);
    expect(provider.trimRangeFor(track).startOffsetMs, 30000);
    expect(provider.trimRangeFor(track).endOffsetMs, 190000);
  });
}
