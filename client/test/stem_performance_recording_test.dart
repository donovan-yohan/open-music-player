import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/features/playlists/mix/stem_performance_recording.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/stem_edits.dart';

final sourceHash = 'sha256:${List.filled(64, 'a').join()}';
const channelSet = StemChannelSet.stems5Hybrid;

StemEdits edits({List<StemGainEvent> events = const []}) => StemEdits(
      channelSet: channelSet,
      sourceFileHash: sourceHash,
      events: events,
    );

StemPerformanceRecording recording(
        {StemEdits? document, int maxEvents = 2048}) =>
    StemPerformanceRecording(
      clipId: 'clip-a',
      sourceFileHash: sourceHash,
      stemModelVersion: channelSet.stemModelVersion,
      edits: document ?? edits(),
      maxEvents: maxEvents,
    );

StemPerformanceSample sample(
  StemPerformanceRecording state, {
  String channel = 'vocals',
  int sourceMs = 1000,
  double gain = 0.375,
  int rampMs = 8,
  String gestureId = 'gesture-a',
}) =>
    state.stage(
      clipId: 'clip-a',
      sourceFileHash: sourceHash,
      stemModelVersion: channelSet.stemModelVersion,
      channel: channel,
      capturedSourceMs: sourceMs,
      gain: gain,
      rampMs: rampMs,
      gestureId: gestureId,
    );

void main() {
  test('failed external acceptance leaves live and persisted state untouched',
      () async {
    final base = recording(
        document: edits(events: [
      StemGainEvent(channel: 'vocals', atMs: 1200, gain: 0.2),
    ])).withRecordingArmed(true);
    final state = base.recordAccepted(sample(base, sourceMs: 1000, gain: 0.8));
    final before = state.edits.toJson();
    final staged = sample(state, sourceMs: 1400, gain: 0.3);
    final accepted = await Future<bool>.value(false);
    final after = accepted ? state.recordAccepted(staged) : state;
    expect(identical(after, state), isTrue);
    expect(after.edits.toJson(), before);
    expect(after.liveOverrides, {'vocals': 0.8});
    expect(after.edits.eventsFor('vocals').map((e) => e.atMs), [1000, 1200]);
  });

  test(
      'a full budget can punch known points but never drops unrelated channels',
      () {
    var state = recording(
        maxEvents: 3,
        document: edits(events: [
          StemGainEvent(channel: 'vocals', atMs: 1000, gain: 0.8),
          StemGainEvent(channel: 'vocals', atMs: 1200, gain: 0.6),
          StemGainEvent(channel: 'bass', atMs: 1100, gain: 0.3),
        ])).withRecordingArmed(true);
    state = state.recordAccepted(sample(state, sourceMs: 1000, gain: 0.7));
    state = state.recordAccepted(sample(state, sourceMs: 1400, gain: 0.2));
    expect(state.edits.events.length, 3);
    expect(state.edits.eventsFor('vocals').map((e) => e.atMs), [1000, 1400]);
    expect(state.edits.eventsFor('bass').single.gain, 0.3);
  });

  test('a two-minute continuous fade is a bounded series of v1 points', () {
    var state = recording().withRecordingArmed(true);
    for (var i = 0; i <= 1200; i++) {
      state = state.recordAccepted(
          sample(state, sourceMs: 1000 + i * 100, gain: 1 - i / 1200));
    }
    final points = state.edits.eventsFor('vocals');
    expect(points.length, 1201);
    expect(points.every((point) => point.rampMs == 8), isTrue);
    expect(points.first.atMs, 1000);
    expect(points.last.atMs, 121000);
    expect(points.last.gain, 0);
    expect(state.replayGainAt(channel: 'vocals', sourceMs: 61008), 0.5);
    expect(state.replayGainAt(channel: 'vocals', sourceMs: 121008), 0);
    final shared =
        recording(document: StemEdits.fromJson(state.edits.toJson()));
    expect(shared.replayGainAt(channel: 'vocals', sourceMs: 61008), 0.5);
    expect(shared.edits.toJson(), state.edits.toJson());
  });

  test('clip trim, move, share and seek do not rebase source-time ramps', () {
    final document = edits(events: [
      StemGainEvent(channel: 'vocals', atMs: 1000, gain: 0, rampMs: 100),
    ]);
    final original = MixPlanClip(
      clipId: 'clip-a',
      queueItemId: 'queue-a',
      trackId: '12',
      sourceStartMs: 0,
      sourceEndMs: 5000,
      timelineStartMs: 4000,
      stemEdits: document,
    );
    final moved = original
        .withTimelineStartMs(20000)
        .withSourceRange(sourceStartMs: 1040, sourceEndMs: 3000);
    expect(identical(moved.stemEdits, document), isTrue);
    final shared = MixPlanClip.fromJson(moved.toJson());
    final state = recording(document: shared.stemEdits);
    expect(
        state.replayGainAt(channel: 'vocals', sourceMs: shared.sourceStartMs),
        closeTo(0.6, 1e-12));
    expect(state.replayGainAt(channel: 'vocals', sourceMs: 1100), 0);
    expect(state.replayGainAt(channel: 'vocals', sourceMs: 1020), 0.8);
    expect(state.edits.events.single.atMs, 1000);
    expect(state.edits.toJson(), original.stemEdits!.toJson());
  });

  test('unsafe existing event coordinates are rejected without rewriting them',
      () {
    for (final event in [
      StemGainEvent(channel: 'hihat', atMs: 0, gain: 0),
      StemGainEvent(channel: 'vocals', atMs: 9007199254740992, gain: 0),
      StemGainEvent(channel: 'vocals', atMs: 0, gain: 0, beatIndex: -1),
      StemGainEvent(
          channel: 'vocals', atMs: 0, gain: 0, beatIndex: 9007199254740992),
    ]) {
      expect(() => recording(document: edits(events: [event])),
          throwsArgumentError);
    }
  });

  test('live overrides can clear without changing recorded metadata', () {
    final armed = recording().withRecordingArmed(true);
    final recorded = armed.recordAccepted(sample(armed, gain: 0.2));
    final off = recorded.withRecordingArmed(false);
    final live = off.recordAccepted(sample(off, gain: 0.8));
    expect(live.replayGainAt(channel: 'vocals', sourceMs: 2000), 0.2);
    expect(live.liveOverrides, {'vocals': 0.8});
    final cleared = live.withLiveOverridesCleared();
    expect(cleared.liveOverrides, isEmpty);
    expect(identical(cleared.edits, live.edits), isTrue);
    expect(cleared.recordingArmed, isFalse);
  });

  test('punch preflight refuses to erase unknown interior event semantics', () {
    final original = edits(events: [
      StemGainEvent(channel: 'vocals', atMs: 1200, gain: 0.2, unknownKeys: {
        'futureEnvelope': {'shape': 'curve'}
      }),
    ]);
    final base = recording(document: original).withRecordingArmed(true);
    final first = base.recordAccepted(sample(base, sourceMs: 1000));
    expect(() => sample(first, sourceMs: 1400), throwsStateError);
    expect(first.edits.eventsFor('vocals').map((e) => e.atMs), [1000, 1200]);
    expect(first.edits.events.last.unknownKeys,
        original.events.single.unknownKeys);
  });

  test('seek boundaries do not punch gaps and loop timestamps replace in place',
      () {
    var state = recording(
        document: edits(events: [
      for (final ms in [1000, 2000, 3000, 4000])
        StemGainEvent(channel: 'vocals', atMs: ms, gain: 0.1),
    ])).withRecordingArmed(true);
    state = state.recordAccepted(sample(state, sourceMs: 1000, gain: 0.8));
    state = state.withSourceDiscontinuity();
    state = state.recordAccepted(sample(state, sourceMs: 4000, gain: 0.7));
    expect(state.edits.eventsFor('vocals').map((e) => e.atMs),
        [1000, 2000, 3000, 4000]);
    // Backward time automatically starts a new pass on the touched channel.
    state = state.recordAccepted(sample(state, sourceMs: 1000, gain: 0.6));
    state = state.recordAccepted(sample(state, sourceMs: 3000, gain: 0.5));
    expect(
        state.edits.eventsFor('vocals').map((e) => e.atMs), [1000, 3000, 4000]);
    state = state.recordAccepted(sample(state, sourceMs: 3000, gain: 0.4));
    expect(state.edits.eventsFor('vocals').map((e) => e.gain), [0.6, 0.4, 0.7]);
    // A new gesture is not connected to the previous gesture's range.
    state = state.recordAccepted(
        sample(state, sourceMs: 5000, gain: 0.3, gestureId: 'next'));
    expect(state.edits.eventsFor('vocals').map((e) => e.atMs),
        [1000, 3000, 4000, 5000]);
  });

  test('replacing a point preserves v1 provenance and unknown keys', () {
    final original = edits(events: [
      StemGainEvent(
        channel: 'vocals',
        atMs: 1000,
        gain: 0.5,
        beatIndex: 12,
        unknownKeys: {
          'futureEvent': {'keep': true}
        },
      ),
      StemGainEvent(
          channel: 'bass',
          atMs: 1000,
          gain: 0.7,
          unknownKeys: {'futureBass': 'keep'}),
    ]);
    final seeded = StemEdits(
      channelSet: original.channelSet,
      sourceFileHash: original.sourceFileHash,
      events: original.events,
      beatGridRef: StemBeatGridRef(
          analysisRef: 'grid',
          analysisVersion: 'one',
          unknownKeys: {'futureGrid': 42}),
      unknownKeys: {
        'futureDocument': [1, 2, 3]
      },
    );
    final state = recording(document: seeded).withRecordingArmed(true);
    final changed = state.recordAccepted(sample(state, gain: 0.25));
    final replaced = changed.edits.eventsFor('vocals').single;
    expect(replaced.unknownKeys, seeded.eventsFor('vocals').single.unknownKeys);
    expect(replaced.beatIndex, 12);
    expect(changed.edits.unknownKeys, seeded.unknownKeys);
    expect(changed.edits.beatGridRef, seeded.beatGridRef);
    expect(changed.edits.eventsFor('bass'), seeded.eventsFor('bass'));
    final shared = StemEdits.fromJson(changed.edits.toJson());
    expect(shared.toJson(), changed.edits.toJson());
    expect(shared.schemaVersion, 1);
  });

  test('event budget preflights before apply and timestamp writes coalesce',
      () {
    var state = recording(maxEvents: 2).withRecordingArmed(true);
    for (var i = 0; i < 100; i++) {
      state = state.recordAccepted(sample(state, gain: i / 100));
    }
    expect(state.edits.events.length, 1);
    expect(state.edits.events.single.gain, 0.99);
    state = state.recordAccepted(sample(state, channel: 'bass'));
    expect(state.edits.events.map((e) => e.channel), ['bass', 'vocals']);
    expect(() => sample(state, channel: 'kick'), throwsStateError);
    expect(state.edits.events.length, 2);
    final off = state.withRecordingArmed(false);
    expect(off.recordAccepted(sample(off, channel: 'kick')).edits, state.edits);
    expect(() => recording(maxEvents: 0), throwsArgumentError);
    expect(() => recording(maxEvents: 2049), throwsArgumentError);
    expect(() => recording(maxEvents: 1, document: state.edits),
        throwsArgumentError);
    final full = recording(
        document: edits(events: [
      for (var i = 0; i < 2048; i++)
        StemGainEvent(channel: 'vocals', atMs: i * 10, gain: 0.5),
    ])).withRecordingArmed(true);
    expect(() => sample(full, channel: 'bass'), throwsStateError);
    expect(full.edits.events.length, 2048);
  });

  test('offline replay evaluates interrupted linear ramps in source time', () {
    final state = recording(
        document: edits(events: [
      StemGainEvent(channel: 'vocals', atMs: 1000, gain: 0, rampMs: 100),
      StemGainEvent(channel: 'vocals', atMs: 1050, gain: 1, rampMs: 100),
      StemGainEvent(channel: 'bass', atMs: 1100, gain: 0),
    ]));
    for (final point in <int, double>{
      999: 1,
      1000: 1,
      1025: 0.75,
      1050: 0.5,
      1100: 0.75,
      1150: 1,
      9000: 1,
    }.entries) {
      expect(state.replayGainAt(channel: 'vocals', sourceMs: point.key),
          closeTo(point.value, 1e-12));
    }
    // Reverse seeks do not depend on the last evaluated cursor.
    expect(state.replayGainAt(channel: 'vocals', sourceMs: 1025), 0.75);
    expect(state.replayGainAt(channel: 'bass', sourceMs: 1108), 0);
    expect(state.replayGainAt(channel: 'kick', sourceMs: 9000), 1);
    expect(() => state.replayGainAt(channel: 'hihat', sourceMs: 0),
        throwsArgumentError);
    expect(() => state.replayGainAt(channel: 'vocals', sourceMs: -1),
        throwsArgumentError);
    expect(
        () => state.replayGainAt(channel: 'vocals', sourceMs: 9007199254740992),
        throwsArgumentError);
    // The old step evaluator and wire contract are deliberately unchanged.
    expect(state.edits.gainAt('vocals', 1025), 0);
  });

  test('same-channel forward gestures punch only their touched source range',
      () {
    final base = recording(
        document: edits(events: [
      for (final ms in [500, 1000, 1200, 1600, 2000])
        StemGainEvent(channel: 'vocals', atMs: ms, gain: 0.1),
      StemGainEvent(channel: 'bass', atMs: 1200, gain: 0.2),
    ])).withRecordingArmed(true);
    var state = base.recordAccepted(sample(base, sourceMs: 1000, gain: 0.8));
    state = state.recordAccepted(sample(state, sourceMs: 1600, gain: 0.4));
    expect(state.edits.eventsFor('vocals').map((e) => e.atMs),
        [500, 1000, 1600, 2000]);
    expect(state.edits.eventsFor('bass'), base.edits.eventsFor('bass'));
    expect(base.edits.eventsFor('vocals').map((e) => e.atMs),
        [500, 1000, 1200, 1600, 2000]);
  });

  test('source, clip and model identities are exact and never inferred', () {
    final base = recording();
    final valid = {
      'clipId': 'clip-a',
      'sourceFileHash': sourceHash,
      'stemModelVersion': channelSet.stemModelVersion,
    };
    for (final key in valid.keys) {
      final wrong = {...valid, key: 'different'};
      expect(
        () => base.stage(
          clipId: wrong['clipId']!,
          sourceFileHash: wrong['sourceFileHash']!,
          stemModelVersion: wrong['stemModelVersion']!,
          channel: 'vocals',
          capturedSourceMs: 0,
          gain: 0,
          gestureId: 'one',
        ),
        throwsArgumentError,
      );
    }
    for (final hash in [
      '',
      'sha256:abc',
      ' $sourceHash',
      sourceHash.toUpperCase()
    ]) {
      expect(
        () => StemPerformanceRecording(
          clipId: 'clip-a',
          sourceFileHash: hash,
          stemModelVersion: channelSet.stemModelVersion,
          edits: edits(),
        ),
        throwsArgumentError,
      );
    }
    expect(
        () => recording(
                document: StemEdits(
              channelSet: channelSet,
              sourceFileHash: 'sha256:${List.filled(64, 'b').join()}',
            )),
        throwsArgumentError);
    expect(
        () => recording(
                document: StemEdits(
              channelSet: channelSet,
              sourceFileHash: sourceHash,
              stemModelVersion: 'legacy-model',
            )),
        throwsArgumentError);
    expect(
        () => StemPerformanceRecording(
              clipId: '',
              sourceFileHash: sourceHash,
              stemModelVersion: channelSet.stemModelVersion,
              edits: edits(),
            ),
        throwsArgumentError);
  });

  test('invalid slider samples reject before legacy clamping can erase errors',
      () {
    final base = recording().withRecordingArmed(true);
    for (final gain in [
      double.nan,
      double.infinity,
      -double.infinity,
      -0.01,
      1.01
    ]) {
      expect(() => sample(base, gain: gain), throwsArgumentError);
    }
    for (final ms in [-1, 9007199254740992]) {
      expect(() => sample(base, sourceMs: ms), throwsArgumentError);
    }
    for (final ramp in [0, 251]) {
      expect(() => sample(base, rampMs: ramp), throwsArgumentError);
    }
    expect(() => sample(base, channel: 'hihat'), throwsArgumentError);
    expect(() => sample(base, gestureId: ''), throwsArgumentError);
    expect(base.edits.events, isEmpty);
    for (final gain in [0.0, 0.123456789, 1.0]) {
      expect(sample(base, gain: gain).event.gain, gain);
    }
    expect(sample(base, rampMs: 1).event.rampMs, 1);
    expect(sample(base, rampMs: 250).event.rampMs, 250);
  });

  test('record-off acceptance is live only and stale acknowledgements fail',
      () {
    final base = recording();
    final staged = sample(base, gain: 0);
    final live = base.recordAccepted(staged);
    expect(identical(live.edits, base.edits), isTrue);
    expect(live.liveOverrides, {'vocals': 0});
    expect(() => live.liveOverrides['bass'] = 0.2, throwsUnsupportedError);
    expect(() => live.recordAccepted(staged), throwsStateError);
    expect(() => recording().recordAccepted(staged), throwsStateError);
    expect(() => base.withRecordingArmed(true).recordAccepted(staged),
        throwsStateError);
  });

  test('only accepted samples write armed source-time automation', () {
    final base = recording();
    final armed = base.withRecordingArmed(true);
    final staged = sample(armed);
    expect(armed.edits.events, isEmpty);
    final accepted = armed.recordAccepted(staged);
    expect(accepted.edits.events.single.toJson(), {
      'channel': 'vocals',
      'atMs': 1000,
      'gain': 0.375,
      'rampMs': 8,
    });
    expect(accepted.liveOverrides, {'vocals': 0.375});
    expect(armed.edits.events, isEmpty);
    expect(base.recordingArmed, isFalse);
  });
}
