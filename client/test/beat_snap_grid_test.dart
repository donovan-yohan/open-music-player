import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';

void main() {
  for (final meter in [2, 3, 4, 5]) {
    test('literal 4/16 beats use anchored beats in $meter meter', () {
      final tempo = _tempo(meter: meter);
      expect(beatMarkersForSnapMode(tempo, BeatSnapMode.beat4),
          [for (var n = 0; n < 65; n += 4) 250 + n * 500]);
      expect(beatMarkersForSnapMode(tempo, BeatSnapMode.beat16),
          [250, 8250, 16250, 24250, 32250]);
      expect(beatMarkersForSnapMode(tempo, BeatSnapMode.downbeat),
          tempo.downbeatsMs);
    });
  }
  test('absolute anchor survives dropped prefix and trim', () {
    final full = _tempo();
    final prefix = _tempo(drop: 3);
    expect(
        beatMarkersForSnapMode(prefix, BeatSnapMode.beat4),
        beatMarkersForSnapMode(full, BeatSnapMode.beat4)
            .where((n) => n >= 1750));
    final outgoing = _clip('a', full, 0, 1750);
    final incoming = _clip('b', prefix, 3975, 1750);
    expect(
        beatAlignmentCorrectionMs(
            outgoing: outgoing,
            incoming: incoming,
            snapMode: BeatSnapMode.beat4),
        25);
  });
  test('unknown group phase permits beat1 but abstains from 4/16', () {
    final tempo = ClipTempoMetadata(
        nativeBpm: 120,
        beatsMs: [for (var n = 0; n < 40; n++) 250 + n * 500],
        generatedTimingUnknown: true,
        phraseLengthBars: 4);
    expect(beatMarkersForSnapMode(tempo, BeatSnapMode.beat1), isNotEmpty);
    expect(beatMarkersForSnapMode(tempo, BeatSnapMode.beat4), isEmpty);
    expect(beatMarkersForSnapMode(tempo, BeatSnapMode.beat16), isEmpty);
    expect(beatMarkersForSnapMode(ClipTempoMetadata.empty, BeatSnapMode.beat4),
        isEmpty);
  });
  test('half/double group counts stay anchored after prefix change', () {
    for (final scale in [0.5, 1.0, 2.0]) {
      final full = beatMarkersForSnapMode(_tempo(), BeatSnapMode.beat4,
          tempoScale: scale);
      final prefix = beatMarkersForSnapMode(_tempo(drop: 3), BeatSnapMode.beat4,
          tempoScale: scale);
      expect(prefix, full.where((n) => n >= 1750));
      expect(full[1] - full[0], (2000 / scale).round());
    }
  });
  test('variable grid needs actual anchor event, not extrapolated phase', () {
    final beats = [250, 750, 1260, 1780, 2310, 2850, 3400, 3960, 4530];
    ClipTempoMetadata tempo(List<int> values) =>
        ClipTempoMetadata(nativeBpm: 120, beatAnchorMs: 250, beatsMs: values);
    expect(beatMarkersForSnapMode(tempo(beats), BeatSnapMode.beat4),
        [250, 2310, 4530]);
    expect(beatMarkersForSnapMode(tempo(beats.sublist(1)), BeatSnapMode.beat4),
        isEmpty);
  });
}

ClipTempoMetadata _tempo({int meter = 4, int drop = 0}) => ClipTempoMetadata(
    nativeBpm: 120,
    beatAnchorMs: 250,
    beatsMs: [for (var n = drop; n < 65; n++) 250 + n * 500],
    downbeatsMs: [for (var n = 0; n < 65; n += meter) 250 + n * 500]);
MixClip _clip(String id, ClipTempoMetadata tempo, int start, int trim) =>
    MixClip(
        placement: TimelineClip.clamped(
            id: id,
            trackId: id,
            sourceDurationMs: 40000,
            sourceStartMs: trim,
            sourceEndMs: 40000,
            timelineStartMs: start),
        tempo: tempo);
