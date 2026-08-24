import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/models/mix_plan.dart';

void main() {
  group('MixPlanClip.copyWith', () {
    MixPlanClip clip() => MixPlanClip(
          clipId: 'clip-1',
          queueItemId: 'queue-1',
          trackId: '7',
          sourceStartMs: 0,
          sourceEndMs: 200000,
          timelineStartMs: 0,
          gainDb: -1.5,
          fadeInMs: 4000,
          fadeOutMs: 8000,
        );

    test('updates only provided fields', () {
      final edited = clip().copyWith(fadeOutMs: 12000, gainDb: -3);

      expect(edited.clipId, 'clip-1');
      expect(edited.trackId, '7');
      expect(edited.fadeInMs, 4000);
      expect(edited.fadeOutMs, 12000);
      expect(edited.gainDb, -3);
    });

    test('clearFadeIn and clearFadeOut drop fades explicitly', () {
      final noFades = clip().copyWith(clearFadeIn: true, clearFadeOut: true);

      expect(noFades.fadeInMs, isNull);
      expect(noFades.fadeOutMs, isNull);
    });
  });
}
