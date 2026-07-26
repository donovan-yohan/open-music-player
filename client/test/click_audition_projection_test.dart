import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/click_audition_projection.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/models/timeline_clip.dart';

void main() {
  test('projects source markers through rate-aware queue item placement', () {
    final model = _model(
      rateAutomation: const PlaybackRateAutomation(baseRate: 2),
      timelineStartMs: 2000,
      sourceStartMs: 1000,
      sourceEndMs: 5000,
    );

    final projected = projectClickAudition(
      model: model,
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: const [1000, 2000, 3000, 4000, 5000],
        sourceDownbeatsMs: const [1000, 3000, 5000],
      ),
    )!;

    expect(
      projected.markers.map((marker) => marker.sourcePositionMs),
      [1000, 2000, 3000, 4000],
    );
    expect(
      projected.markers.map((marker) => marker.timelinePositionMs),
      [2000, 2500, 3000, 3500],
    );
    expect(
      projected.markers.map((marker) => marker.isAccent),
      [true, false, true, false],
    );
  });

  test('phase rotation changes accents without moving beat timestamps', () {
    final model = _model();
    final phaseZero = projectClickAudition(
      model: model,
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: const [0, 500, 1000, 1500],
        sourceDownbeatsMs: const [0, 1000],
      ),
    )!;
    final phaseOne = projectClickAudition(
      model: model,
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: const [0, 500, 1000, 1500],
        sourceDownbeatsMs: const [500, 1500],
      ),
    )!;

    expect(
      phaseOne.markers.map((marker) => marker.timelinePositionMs),
      phaseZero.markers.map((marker) => marker.timelinePositionMs),
    );
    expect(
      phaseZero.markers.map((marker) => marker.isAccent),
      [true, false, true, false],
    );
    expect(
      phaseOne.markers.map((marker) => marker.isAccent),
      [false, true, false, true],
    );
  });

  test('unknown downbeats remain unaccented', () {
    final projected = projectClickAudition(
      model: _model(),
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: const [0, 500, 1000],
        sourceDownbeatsMs: const [],
        downbeatAccentsEnabled: true,
      ),
    )!;

    expect(projected.markers, hasLength(3));
    expect(projected.markers.every((marker) => !marker.isAccent), isTrue);
  });

  test('beat and downbeat toggles remain independent', () {
    final model = _model();
    final accentOnly = projectClickAudition(
      model: model,
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: const [0, 500, 1000, 1500],
        sourceDownbeatsMs: const [0, 1000],
        beatClicksEnabled: false,
      ),
    )!;
    final beatsOnly = projectClickAudition(
      model: model,
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: const [0, 500, 1000, 1500],
        sourceDownbeatsMs: const [0, 1000],
        downbeatAccentsEnabled: false,
      ),
    )!;
    final disabled = projectClickAudition(
      model: model,
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: const [0, 500],
        sourceDownbeatsMs: const [0],
        beatClicksEnabled: false,
        downbeatAccentsEnabled: false,
      ),
    )!;

    expect(
      accentOnly.markers.map((marker) => marker.sourcePositionMs),
      [0, 1000],
    );
    expect(accentOnly.markers.every((marker) => marker.isAccent), isTrue);
    expect(beatsOnly.markers, hasLength(4));
    expect(beatsOnly.markers.every((marker) => !marker.isAccent), isTrue);
    expect(disabled.markers, isEmpty);
  });

  test('signed output calibration moves output only after projection', () {
    final model = _model(timelineStartMs: 1000);
    final baseline = projectClickAudition(
      model: model,
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: const [500, 1000],
        sourceDownbeatsMs: const [],
      ),
    )!;
    final earlier = projectClickAudition(
      model: model,
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: const [500, 1000],
        sourceDownbeatsMs: const [],
        outputOffsetMs: -120,
      ),
    )!;
    final later = projectClickAudition(
      model: model,
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: const [500, 1000],
        sourceDownbeatsMs: const [],
        outputOffsetMs: 85,
      ),
    )!;

    expect(
      earlier.markers.map((marker) => marker.sourcePositionMs),
      baseline.markers.map((marker) => marker.sourcePositionMs),
    );
    expect(
      earlier.markers.map((marker) => marker.timelinePositionMs),
      baseline.markers.map((marker) => marker.timelinePositionMs),
    );
    expect(
      earlier.markers.map((marker) => marker.outputPositionMs),
      baseline.markers.map((marker) => marker.outputPositionMs - 120),
    );
    expect(
      later.markers.map((marker) => marker.timelinePositionMs),
      baseline.markers.map((marker) => marker.timelinePositionMs),
    );
    expect(
      later.markers.map((marker) => marker.outputPositionMs),
      baseline.markers.map((marker) => marker.outputPositionMs + 85),
    );
  });

  test('requires one unambiguous queue item identity', () {
    final missing = projectClickAudition(
      model: _model(),
      request: ClickAuditionRequest(
        queueItemId: 'another-queue-item',
        sourceBeatsMs: const [0],
        sourceDownbeatsMs: const [],
      ),
    );
    final duplicateModel = TimelineModel(
      clips: [
        _clip(id: 'one', queueItemId: 'duplicate', timelineStartMs: 0),
        _clip(id: 'two', queueItemId: 'duplicate', timelineStartMs: 5000),
      ],
    );
    final duplicate = projectClickAudition(
      model: duplicateModel,
      request: ClickAuditionRequest(
        queueItemId: 'duplicate',
        sourceBeatsMs: const [0],
        sourceDownbeatsMs: const [],
      ),
    );

    expect(missing, isNull);
    expect(duplicate, isNull);
  });

  test('phase and signed offset invariants hold across common meters', () {
    final model = _model();
    final beats = List<int>.generate(8, (index) => 500 + index * 400);
    final baseline = projectClickAudition(
      model: model,
      request: ClickAuditionRequest(
        queueItemId: 'queue-target',
        sourceBeatsMs: beats,
        sourceDownbeatsMs: const [],
      ),
    )!;
    final baselineSources =
        baseline.markers.map((marker) => marker.sourcePositionMs).toList();
    final baselineTimeline =
        baseline.markers.map((marker) => marker.timelinePositionMs).toList();

    for (var meter = 2; meter <= 8; meter++) {
      for (var phase = 0; phase < meter; phase++) {
        final downbeats = [
          for (var index = phase; index < beats.length; index += meter)
            beats[index],
        ];
        for (final offsetMs in const [-200, -1, 0, 1, 200]) {
          final projected = projectClickAudition(
            model: model,
            request: ClickAuditionRequest(
              queueItemId: 'queue-target',
              sourceBeatsMs: beats,
              sourceDownbeatsMs: downbeats,
              outputOffsetMs: offsetMs,
            ),
          )!;

          expect(
            projected.markers.map((marker) => marker.sourcePositionMs).toList(),
            baselineSources,
            reason: 'meter=$meter phase=$phase offset=$offsetMs',
          );
          expect(
            projected.markers
                .map((marker) => marker.timelinePositionMs)
                .toList(),
            baselineTimeline,
            reason: 'meter=$meter phase=$phase offset=$offsetMs',
          );
          expect(
            projected.markers.map((marker) => marker.outputPositionMs).toList(),
            baselineTimeline
                .map((timelineMs) => timelineMs + offsetMs)
                .toList(),
            reason: 'meter=$meter phase=$phase offset=$offsetMs',
          );
          expect(
            projected.markers
                .asMap()
                .entries
                .where((entry) => entry.value.isAccent)
                .map((entry) => entry.key)
                .toList(),
            [
              for (var index = phase; index < beats.length; index += meter)
                index,
            ],
            reason: 'meter=$meter phase=$phase offset=$offsetMs',
          );
        }
      }
    }
  });
}

TimelineModel _model({
  int timelineStartMs = 0,
  int sourceStartMs = 0,
  int sourceEndMs = 5000,
  PlaybackRateAutomation rateAutomation =
      const PlaybackRateAutomation(baseRate: 1),
}) {
  return TimelineModel(
    clips: [
      _clip(
        id: 'target',
        queueItemId: 'queue-target',
        timelineStartMs: timelineStartMs,
        sourceStartMs: sourceStartMs,
        sourceEndMs: sourceEndMs,
        rateAutomation: rateAutomation,
      ),
      _clip(
        id: 'same-track-other-occurrence',
        queueItemId: 'queue-other',
        timelineStartMs: 10000,
      ),
    ],
  );
}

MixClip _clip({
  required String id,
  required String queueItemId,
  required int timelineStartMs,
  int sourceStartMs = 0,
  int sourceEndMs = 5000,
  PlaybackRateAutomation rateAutomation =
      const PlaybackRateAutomation(baseRate: 1),
}) {
  return MixClip(
    placement: TimelineClip.clamped(
      id: id,
      trackId: 'same-track',
      sourceDurationMs: 10000,
      sourceStartMs: sourceStartMs,
      sourceEndMs: sourceEndMs,
      timelineStartMs: timelineStartMs,
    ),
    queueItemId: queueItemId,
    rateAutomation: rateAutomation,
  );
}
