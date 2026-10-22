import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_session.dart';
import 'package:open_music_player/core/engine/gain_envelope.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';

void main() {
  test('projection exactly matches the old pair oracle for random arrangements',
      () {
    final random = math.Random(287401);
    for (var trial = 0; trial < 80; trial++) {
      final cues = <PlaybackCue>[];
      for (var group = 0; group < 8; group++) {
        final start = group * 50000;
        final count = 1 + random.nextInt(4);
        for (var voice = 0; voice < count; voice++) {
          final index = cues.length;
          final sourceStart = random.nextInt(1000);
          cues.add(_cue(
            index,
            // Small discrete offsets deliberately create start ties.
            startUs: (start + random.nextInt(3) * 1000) * 1000 +
                random.nextInt(3) * 100,
            durationUs: (1000 + random.nextInt(19000)) * 1000,
            sourceStartUs: sourceStart * 1000,
            queueIndex: random.nextInt(4),
            gainDb: random.nextInt(31) - 24.0,
            fadeInMs: _randomFade(random),
            fadeOutMs: _randomFade(random),
            playbackRate: [0.5, 0.75, 1.0, 1.25, 2.0][random.nextInt(5)],
            tempo: ClipTempoMetadata(
              nativeBpm: 100 + random.nextInt(5) * 10.0,
              bpmConfidence: random.nextBool() ? 1 : 0.2,
            ),
          ));
        }
        cues.add(_cue(cues.length,
            startUs: start * 1000, durationUs: 0, queueIndex: -1));
      }
      cues.shuffle(random);
      _expectOracle(cues, reason: 'random trial $trial');
    }
  });

  test(
      'contained spans, exact start ties and equal queue indices keep direction',
      () {
    final cues = [
      _cue(0, startUs: 0, durationUs: 20000000, queueIndex: 9),
      _cue(1, startUs: 2000000, durationUs: 3000000, queueIndex: 5),
      _cue(2, startUs: 2000000, durationUs: 7000000, queueIndex: 5),
      _cue(3, startUs: 2000000, durationUs: 9000000, queueIndex: 1),
    ];
    _expectOracle(cues.reversed.toList());
    final model = CueTimeline(cues: cues).toTimelineModel();
    final envelopes = {for (final clip in model.clips) clip.id: clip.envelope};
    expect(envelopes['cue_0']!.fadeOutMs, 9000);
    expect(envelopes['cue_1']!.fadeInMs, 3000);
    expect(envelopes['cue_1']!.fadeOutMs, 3000);
    expect(envelopes['cue_2']!.fadeInMs, 7000);
    expect(envelopes['cue_2']!.fadeOutMs, 3000);
    expect(envelopes['cue_3']!.fadeInMs, 9000);
    expect(envelopes['cue_3']!.fadeOutMs, 7000);
  });

  test(
      'explicit zero and authored fades override derived fades without gain loss',
      () {
    final cues = [
      _cue(0,
          startUs: 0,
          durationUs: 10000000,
          fadeInMs: 19000,
          fadeOutMs: 0,
          gainDb: -8),
      _cue(1,
          startUs: 5000000,
          durationUs: 10000000,
          fadeInMs: 0,
          fadeOutMs: 17000,
          gainDb: 3),
    ];
    _expectOracle(cues);
    final clips = CueTimeline(cues: cues).toTimelineModel().clips;
    expect(clips[0].envelope,
        const GainEnvelope(baseGainDb: -8, fadeInMs: 19000, fadeOutMs: 0));
    expect(clips[1].envelope,
        const GainEnvelope(baseGainDb: 3, fadeInMs: 0, fadeOutMs: 17000));
  });

  test(
      'unknown duration cues remain empty at four-way overlaps and butt joints',
      () {
    final cues = [
      for (var i = 0; i < 4; i++) _cue(i, startUs: 0, durationUs: 1000000),
      for (var i = 4; i < 12; i++) _cue(i, startUs: 0, durationUs: 0),
      _cue(12, startUs: 1000000, durationUs: 1000000),
    ];
    _expectOracle(cues);
    final model = CueTimeline(cues: cues).toTimelineModel();
    expect(model.clips.length, cues.length);
    expect(model.overlapDepthAt(0), 4);
    expect(model.overlapDepthAt(1000), 1);
    for (final clip
        in model.clips.where((clip) => clip.selectedDurationMs == 0)) {
      expect(clip.envelope, const GainEnvelope.flat());
    }
    expect(CueTimeline.empty.toTimelineModel().clips, isEmpty);
  });

  test('raw cue overlaps may exceed four when rate-adjusted voices do not', () {
    final cues = <PlaybackCue>[];
    var startMs = 0;
    var durationMs = 65536;
    for (var i = 0; i < 7; i++) {
      cues.add(_cue(i,
          startUs: startMs * 1000,
          durationUs: durationMs * 1000,
          playbackRate: 2));
      startMs += durationMs ~/ 2;
      durationMs ~/= 2;
    }
    _expectOracle(cues);
    final model = CueTimeline(cues: cues).toTimelineModel();
    expect(model.overlapDepthAt(64000), 1);
    expect(
        cues.where((cue) => cue.timelineEnd.inMilliseconds > 64000).length, 7);
  });

  test('sub-millisecond starts retain Duration ordering before ms overlap math',
      () {
    final cues = [
      _cue(0, startUs: 100, durationUs: 2000900, queueIndex: 9),
      _cue(1, startUs: 900, durationUs: 1000100, queueIndex: 0),
      _cue(2, startUs: 2001000, durationUs: 1000000),
      _cue(3, startUs: 2000500, durationUs: 500),
    ];
    _expectOracle(cues.reversed.toList());
  });

  test('long contained arrangement and empty cues use bounded cue reads', () {
    const count = 8192;
    final reads = _CueReads(limit: count * 80);
    final cues = <PlaybackCue>[
      _cue(count, startUs: 0, durationUs: count * 20000000),
      for (var i = count - 1; i >= 0; i--)
        _CountedCue(i, reads,
            startMs: i * 20000 + 1, durationMs: i.isEven ? 10000 : 0),
    ];
    final model = CueTimeline(cues: cues).toTimelineModel();
    expect(model.clips.length, count + 1);
    final enclosing = model.clips.first;
    expect(enclosing.id, 'cue_$count');
    expect(enclosing.envelope.fadeOutMs, 10000);
    for (final clip in model.clips.skip(1)) {
      expect(clip.envelope.fadeInMs, clip.selectedDurationMs == 0 ? 0 : 10000);
      expect(clip.envelope.fadeOutMs, 0);
    }
    expect(reads.count, lessThanOrEqualTo(reads.limit));
    print('CUE_READS contained_and_empty=$count reads=${reads.count} '
        'budget=${reads.limit}');
  });

  test(
      'long four-way arrangement retains every envelope within cue-read budget',
      () {
    const count = 4096;
    final reads = _CueReads(limit: count * 80);
    final timeline = CueTimeline(cues: [
      for (var i = count - 1; i >= 0; i--)
        _CountedCue(i, reads, startMs: (i ~/ 4) * 20000),
    ]);
    final model = timeline.toTimelineModel();
    expect(model.clips.length, count);
    for (final clip in model.clips) {
      final index = int.parse(clip.id.substring('cue_'.length));
      expect(clip.envelope.fadeInMs, index % 4 == 0 ? 0 : 10000);
      expect(clip.envelope.fadeOutMs, index % 4 == 3 ? 0 : 10000);
    }
    expect(reads.count, lessThanOrEqualTo(reads.limit));
    print(
        'CUE_READS four_way=$count reads=${reads.count} budget=${reads.limit}');
  });

  test('over-depth arrangements reject before envelope pair work', () {
    const count = 2048;
    final reads = _CueReads(limit: count * 8);
    final timeline = CueTimeline(cues: [
      for (var i = 0; i < count; i++) _CountedCue(i, reads, startMs: 0),
    ]);
    expect(
        timeline.toTimelineModel,
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('exceed 4 concurrent voices'))));
    expect(reads.count, lessThanOrEqualTo(reads.limit));
  });

  test('duplicate IDs reject before envelope pair work', () {
    const count = 2048;
    final reads = _CueReads(limit: count * 8);
    final timeline = CueTimeline(cues: [
      for (var i = 0; i < count; i++)
        _CountedCue(i == count - 1 ? 0 : i, reads, startMs: i * 10000),
    ]);
    expect(
        timeline.toTimelineModel,
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('duplicate timeline clip ID: cue_0'))));
    expect(reads.count, lessThanOrEqualTo(reads.limit));
  });

  test('benchmark projection versus frozen old envelope logic', () {
    for (final size in [256, 1024, 4096]) {
      final cues = [
        for (var i = size - 1; i >= 0; i--)
          _cue(i, startUs: i * 8000000, durationUs: 10000000),
      ];
      final timeline = CueTimeline(cues: cues);
      // Warm both paths, then alternate their measurement order.
      timeline.toTimelineModel();
      _oldProjection(cues);
      final currentUs = <int>[];
      final oldUs = <int>[];
      for (var sample = 0; sample < 5; sample++) {
        void current() => currentUs.add(_measure(timeline.toTimelineModel));
        void old() => oldUs.add(_measure(() => _oldProjection(cues)));
        if (sample.isEven) {
          current();
          old();
        } else {
          old();
          current();
        }
      }
      // Timing is evidence, not a flaky wall-clock CI assertion.
      print('CUE_BENCH size=$size current_us=$currentUs old_us=$oldUs');
    }
  }, skip: !const bool.fromEnvironment('CUE_ENVELOPE_BENCHMARK'));

  test('long arrangement projection stays within a cue-read budget', () {
    const count = 1024;
    final reads = _CueReads(limit: count * 80);
    final timeline = CueTimeline(cues: [
      for (var i = count - 1; i >= 0; i--)
        _CountedCue(i, reads, startMs: i * 10000),
    ]);

    final model = timeline.toTimelineModel();

    expect(model.clips.length, count);
    expect(model.clips.first.timelineStartMs, 0);
    expect(model.clips.last.timelineEndMs, count * 10000);
    expect(model.clips.every((clip) => clip.envelope.fadeInMs == 0), isTrue);
    expect(model.clips.every((clip) => clip.envelope.fadeOutMs == 0), isTrue);
    expect(reads.count, lessThanOrEqualTo(reads.limit));
    print(
        'CUE_READS sequential=$count reads=${reads.count} budget=${reads.limit}');
  });
}

int _measure(TimelineModel Function() project) {
  final watch = Stopwatch()..start();
  final model = project();
  watch.stop();
  expect(model.clips, isNotEmpty);
  return watch.elapsedMicroseconds;
}

int? _randomFade(math.Random random) => switch (random.nextInt(4)) {
      0 || 1 => null,
      2 => 0,
      _ => random.nextInt(25000),
    };

PlaybackCue _cue(
  int index, {
  required int startUs,
  required int durationUs,
  int sourceStartUs = 0,
  int? queueIndex,
  double gainDb = 0,
  int? fadeInMs,
  int? fadeOutMs,
  double playbackRate = 1,
  ClipTempoMetadata tempo = ClipTempoMetadata.empty,
}) =>
    PlaybackCue(
      cueId: 'cue_$index',
      queueItemId: 'queue_$index',
      queueIndex: queueIndex ?? index,
      trackId: 'track_${index % 3}',
      mediaItem: MediaItem(id: 'track_${index % 3}', title: 'Track $index'),
      audioUri: Uri.parse('https://example.test/$index.mp3'),
      sourceDuration: Duration(microseconds: sourceStartUs + durationUs),
      sourceStart: Duration(microseconds: sourceStartUs),
      sourceEnd: Duration(microseconds: sourceStartUs + durationUs),
      timelineStart: Duration(microseconds: startUs),
      gainDb: gainDb,
      fadeInMs: fadeInMs,
      fadeOutMs: fadeOutMs,
      playbackRate: playbackRate,
      pitchMode: index.isEven ? pitchModePreserve : pitchModeFollowTempo,
      tempo: tempo,
    );

void _expectOracle(List<PlaybackCue> cues, {String? reason}) {
  final expected = _oldProjection(cues);
  final actual = CueTimeline(cues: cues).toTimelineModel();
  expect(actual.clips, expected.clips, reason: reason);
  expect(actual.durationMs, expected.durationMs, reason: reason);
  for (var i = 0; i < expected.clips.length; i++) {
    final before = expected.clips[i];
    final after = actual.clips[i];
    expect(after.envelope, before.envelope, reason: reason);
    expect(after.rateAutomation, before.rateAutomation, reason: reason);
    expect(after.timelineEndMs, before.timelineEndMs, reason: reason);
  }
}

// Frozen old projection: deliberately quadratic, only for small oracle fixtures.
TimelineModel _oldProjection(List<PlaybackCue> cues) => TimelineModel(clips: [
      for (final cue in cues) cue.toMixClip(envelope: _oldEnvelope(cue, cues)),
    ]);

GainEnvelope _oldEnvelope(PlaybackCue cue, List<PlaybackCue> cues) {
  var fadeInMs = 0;
  var fadeOutMs = 0;
  for (final other in cues) {
    if (identical(other, cue)) continue;
    final overlapStart = math.max(
        cue.timelineStart.inMilliseconds, other.timelineStart.inMilliseconds);
    final overlapEnd = math.min(
        cue.timelineEnd.inMilliseconds, other.timelineEnd.inMilliseconds);
    if (overlapEnd <= overlapStart) continue;
    final overlapMs = overlapEnd - overlapStart;
    if (other.timelineStart < cue.timelineStart) {
      fadeInMs = math.max(fadeInMs, overlapMs);
    } else if (other.timelineStart > cue.timelineStart) {
      fadeOutMs = math.max(fadeOutMs, overlapMs);
    } else if (other.queueIndex < cue.queueIndex) {
      fadeInMs = math.max(fadeInMs, overlapMs);
    } else {
      fadeOutMs = math.max(fadeOutMs, overlapMs);
    }
  }
  return GainEnvelope(
      baseGainDb: cue.gainDb,
      fadeInMs: cue.fadeInMs ?? fadeInMs,
      fadeOutMs: cue.fadeOutMs ?? fadeOutMs);
}

class _CueReads {
  _CueReads({required this.limit});

  final int limit;
  int count = 0;

  void read() {
    count++;
    if (count > limit) {
      throw StateError('cue-read budget exceeded: $count > $limit');
    }
  }
}

// Observes actual public cue reads without a production instrumentation API.
class _CountedCue extends PlaybackCue {
  _CountedCue(int index, this.reads,
      {required int startMs, int durationMs = 10000})
      : super(
          cueId: 'cue_$index',
          queueItemId: 'queue_$index',
          queueIndex: index,
          trackId: 'track_$index',
          mediaItem: MediaItem(id: 'track_$index', title: 'Track $index'),
          audioUri: Uri.parse('https://example.test/$index.mp3'),
          sourceDuration: Duration(milliseconds: durationMs),
          sourceStart: Duration.zero,
          sourceEnd: Duration(milliseconds: durationMs),
          timelineStart: Duration(milliseconds: startMs),
        );

  final _CueReads reads;

  @override
  Duration get timelineStart {
    reads.read();
    return super.timelineStart;
  }

  @override
  Duration get timelineEnd {
    reads.read();
    return super.timelineEnd;
  }
}
