import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/core/engine/voice_pool.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'support/fake_voice.dart';

const deadline = Duration(seconds: 2);

class Gate {
  final entered = Completer<void>();
  final done = Completer<void>();
  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await done.future;
  }

  void open() {
    if (!done.isCompleted) done.complete();
  }
}

class ProbeVoice extends FakeVoice {
  ProbeVoice(super.debugId);
  Gate? loadGate, releaseGate, gainGate, disposeGate;
  Object? gainError;
  int plays = 0, disposals = 0;
  Object? loadError, releaseError;
  int releases = 0;
  final gains = <double>[];
  @override
  Future<void> setVolume(double gain) async {
    gains.add(gain);
    final gate = gain > 0 ? gainGate : null;
    if (gate != null) {
      gainGate = null;
      await gate.wait();
    }
    final error = gain > 0 ? gainError : null;
    if (error != null) {
      gainError = null;
      throw error;
    }
  }

  @override
  Future<void> play() async {
    plays++;
    await super.play();
  }

  final bus = StreamController<VoiceEvent>.broadcast();
  @override
  Stream<VoiceEvent> get events => bus.stream;
  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    final gate = loadGate;
    loadGate = null;
    if (gate != null) await gate.wait();
    final error = loadError;
    loadError = null;
    if (error != null) {
      bus.add(VoiceEvent(VoiceEventKind.error, error: error));
      throw error;
    }
    await super.load(source, initialLocalPositionMs: initialLocalPositionMs);
    bus.add(const VoiceEvent(VoiceEventKind.ready));
  }

  @override
  Future<void> release() async {
    releases++;
    final gate = releaseGate;
    releaseGate = null;
    if (gate != null) await gate.wait();
    if (releaseError != null) throw releaseError!;
    await super.release();
  }

  @override
  Future<void> dispose() async {
    disposals++;
    final gate = disposeGate;
    disposeGate = null;
    if (gate != null) await gate.wait();
    await bus.close();
    await super.dispose();
  }
}

class ProbeResolver implements EngineAudioSourceResolver {
  int acquired = 0, released = 0;
  Gate? nextGate;
  String? nextRef;
  @override
  Future<ResolvedAudioSource> resolve(MixClip clip) async {
    final gate = nextGate;
    nextGate = null;
    if (gate != null) await gate.wait();
    acquired++;
    final ref = nextRef ?? clip.audioSourceRef;
    nextRef = null;
    return ResolvedAudioSource.local(Uri.file('/$ref.wav'),
        onRelease: () async {
      released++;
    });
  }

  @override
  Future<void> warm(String ref, {required Set<String> protect}) async {}
}

MixClip clip(String id) => MixClip(
    audioSourceRef: id,
    placement: TimelineClip.clamped(
        id: id,
        trackId: id,
        sourceDurationMs: 10000,
        sourceStartMs: 0,
        sourceEndMs: 10000,
        timelineStartMs: 0));

class Fixture {
  final clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026), uiTickInterval: const Duration(hours: 1));
  final resolver = ProbeResolver();
  final voices = <ProbeVoice>[];
  final gates = <Gate>[];
  late final VoicePool pool;
  Fixture({int maxVoices = 1, int spares = 0}) {
    pool = VoicePool(
        clock: clock,
        resolver: resolver,
        maxVoices: maxVoices,
        warmSpareVoices: spares,
        prepareTimeout: const Duration(milliseconds: 10),
        driftCheckInterval: const Duration(hours: 1),
        gainUpdateInterval: const Duration(hours: 1),
        voiceFactory: () {
          final v = ProbeVoice('v${voices.length}');
          voices.add(v);
          return v;
        });
    addTearDown(() async {
      for (final g in gates) {
        g.open();
      }
      await pool.dispose();
      await clock.dispose();
    });
  }
  Gate gate() {
    final g = Gate();
    gates.add(g);
    return g;
  }
}

void main() {
  supplementalReconciliationCases();
  gainRetirementSiblingCases();
  gainReuseSiblingCases();
  test('identity lookup finishing after stop cannot release replacement',
      () async {
    final f = Fixture();
    await f.pool.start();
    final model = TimelineModel(clips: [clip('a')]);
    await f.pool.loadMix(model);
    final voice = f.pool.activeVoices['a'];
    final identity = f.gate();
    f.resolver.nextGate = identity;
    f.resolver.nextRef = 'changed';
    final checking = f.pool.loadMix(model);
    await identity.entered.future.timeout(deadline);
    await f.pool.stop().timeout(deadline);
    final replacing = f.pool.loadMix(TimelineModel(clips: [clip('new')]));
    final starting = f.pool.start();
    identity.open();
    await Future.wait([checking, replacing, starting]).timeout(deadline);
    expect(f.pool.activeVoices['new'], same(voice));
    expect(f.voices.single.loads, [Uri.file('/a.wav'), Uri.file('/new.wav')]);
    expect(f.voices.single.releases, 1);
    await f.pool.stop();
    expect(f.resolver.released, f.resolver.acquired);
  });
  test('capacity fallback interrupted by stop does not prepare stale source',
      () async {
    final f = Fixture(maxVoices: 2, spares: 1);
    await f.pool.start();
    await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    final a = f.pool.activeVoices['a']! as ProbeVoice;
    final unloading = f.gate();
    a.releaseGate = unloading;
    f.voices[1].loadError = const VoiceCapacityException('synthetic capacity');
    final adding = f.pool.loadMix(TimelineModel(clips: [clip('a'), clip('b')]));
    await unloading.entered.future.timeout(deadline);
    await f.pool.stop().timeout(deadline);
    unloading.open();
    await adding.timeout(deadline);
    expect(f.pool.activeVoices, isEmpty);
    expect(f.voices.expand((v) => v.loads), [Uri.file('/a.wav')]);
    await f.pool.loadMix(TimelineModel(clips: [clip('new')]));
    await f.pool.start();
    expect(f.pool.activeVoiceCount, 1);
    await f.pool.stop();
    expect(f.resolver.released, f.resolver.acquired);
  });
  test('current decoder error superseded during cleanup does not resurface',
      () async {
    final f = Fixture();
    await f.pool.start();
    final unloading = f.gate();
    f.voices.single.loadError = StateError('current decoder');
    f.voices.single.releaseGate = unloading;
    final loading = f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    await unloading.entered.future.timeout(deadline);
    await f.pool.stop().timeout(deadline);
    final replacing = f.pool.loadMix(TimelineModel(clips: [clip('new')]));
    final starting = f.pool.start();
    unloading.open();
    await Future.wait([loading, replacing, starting]).timeout(deadline);
    expect(f.pool.activeVoices['new']?.isReady, isTrue);
    await f.pool.stop();
    expect(f.resolver.released, f.resolver.acquired);
  });
  test(
      'failed entering layer restores healthy peers after forced synchronization',
      () async {
    final f = Fixture(maxVoices: 2, spares: 1);
    await f.pool.start();
    await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    await f.clock.play();
    await f.pool.syncAt(0, forceSeek: true);
    final a = f.pool.activeVoices['a']! as ProbeVoice;
    expect(a.isPlaying, isTrue);
    expect(a.gains.last, 1);
    final failure = StateError('entering decoder rejected');
    f.voices[1].loadError = failure;
    Object? returnedError;
    try {
      await f.pool.loadMix(TimelineModel(clips: [clip('a'), clip('b')]));
    } catch (error) {
      returnedError = error;
    }
    expect(returnedError, same(failure));
    expect(f.pool.activeVoices['a'], same(a));
    expect({'gain': a.gains.last, 'playing': a.isPlaying},
        {'gain': 1.0, 'playing': true},
        reason:
            'failed peer must not strand healthy assigned audio muted and paused');
  });
  test('successful model replacement retires previous terminal status',
      () async {
    final f = Fixture();
    await f.pool.start();
    var latest = <String, VoiceEventKind>{};
    final statuses = f.pool.voiceStatusStream.listen((s) {
      latest = s;
    });
    addTearDown(statuses.cancel);
    f.voices.single.loadError = StateError('decoder rejected');
    Object? returnedError;
    try {
      await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    } catch (error) {
      returnedError = error;
    }
    expect(returnedError, isA<StateError>());
    await f.pool.loadMix(TimelineModel(clips: [clip('new')]),
        preserveActivePlayback: true);
    expect(f.pool.activeVoices['new']?.isReady, isTrue);
    expect(latest.keys, ['new'],
        reason: 'terminal errors must not outlive their owning model');
  });
  test(
      'timed-out cleanup failure remains terminal and releases starvation hold',
      () async {
    final f = Fixture();
    await f.pool.start();
    final loading = f.gate(), unloading = f.gate();
    f.voices.single.loadGate = loading;
    f.voices.single.releaseGate = unloading;
    f.voices.single.loadError = StateError('decoder rejected');
    f.voices.single.releaseError = StateError('unload rejected');
    var latest = <String, VoiceEventKind>{};
    final statuses = f.pool.voiceStatusStream.listen((s) {
      latest = s;
    });
    addTearDown(statuses.cancel);
    await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    expect(f.clock.isBufferingHeld, isTrue);
    loading.open();
    await unloading.entered.future.timeout(deadline);
    // The native unload is positively entered; let its failed tail settle.
    unloading.open();
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(f.voices.single.releases, 1);
    expect(f.resolver.acquired, 1);
    expect(f.resolver.released, 0);
    expect(latest['a'], VoiceEventKind.error,
        reason: 'a current cleanup failure must not erase the terminal error');
    expect(f.clock.isBufferingHeld, isFalse,
        reason:
            'terminal failure cannot leave the canonical clock buffering forever');
    final disposing = f.gate();
    f.voices.single.disposeGate = disposing;
    final disposed = f.pool.dispose();
    await disposing.entered.future.timeout(deadline);
    expect(f.resolver.released, 0,
        reason: 'failed unload owns bytes until native dispose completes');
    disposing.open();
    await disposed.timeout(deadline);
    expect(f.voices.single.disposals, 1);
    expect(f.resolver.released, 1);
  });

  for (final replace in [false, true]) {
    test(
        'failed entering reconciliation cannot revive peer after ${replace ? 'replacement' : 'stop'}',
        () async {
      final f = Fixture(maxVoices: 2, spares: 1);
      await f.pool.start();
      await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
      await f.clock.play();
      await f.pool.syncAt(0, forceSeek: true);
      final a = f.pool.activeVoices['a']! as ProbeVoice;
      expect(a.isPlaying, isTrue);
      expect(a.gains.last, 1);
      final reconciling = f.gate();
      a.gainGate = reconciling;
      final failure = StateError('entering decoder');
      f.voices[1].loadError = failure;
      final loading =
          f.pool.loadMix(TimelineModel(clips: [clip('a'), clip('b')]));
      final result = expectLater(loading, throwsA(same(failure)));
      await reconciling.entered.future.timeout(deadline);
      final plays = a.plays;
      Future<void>? replacing;
      if (replace) {
        replacing = f.pool.loadMix(TimelineModel(clips: [clip('new')]));
      } else {
        await f.pool.stop().timeout(deadline);
      }
      reconciling.open();
      await result.timeout(deadline);
      if (replacing != null) await replacing.timeout(deadline);
      expect(a.plays, plays,
          reason: 'superseded reconciliation must not request play');
      expect(a.isPlaying, isFalse);
      expect(f.pool.activeVoices.keys, replace ? ['new'] : isEmpty);
    });
  }
  test('reconciliation failure cannot replace original preparation error',
      () async {
    final f = Fixture(maxVoices: 2, spares: 1);
    await f.pool.start();
    await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    final a = f.pool.activeVoices['a']! as ProbeVoice;
    final failure = StateError('primary decoder');
    f.voices[1].loadError = failure;
    final reconciling = f.gate();
    a.gainGate = reconciling;
    a.gainError = StateError('secondary gain');
    final result = expectLater(
        f.pool.loadMix(TimelineModel(clips: [clip('a'), clip('b')])),
        throwsA(same(failure)));
    await reconciling.entered.future.timeout(deadline);
    reconciling.open();
    await result;
  });
  test('terminal status follows owning clip through metadata and removal reuse',
      () async {
    final f = Fixture(maxVoices: 2, spares: 1);
    await f.pool.start();
    var latest = <String, VoiceEventKind>{};
    final subscription = f.pool.voiceStatusStream.listen((s) {
      latest = s;
    });
    addTearDown(subscription.cancel);
    final a = clip('a');
    final failure = StateError('terminal');
    f.voices.first.loadError = failure;
    await expectLater(
        f.pool.loadMix(TimelineModel(clips: [a])), throwsA(same(failure)));
    await Future<void>.delayed(Duration.zero);
    expect(latest['a'], VoiceEventKind.error);
    f.pool.replaceMixMetadata(TimelineModel(clips: [a, clip('future')]));
    await Future<void>.delayed(Duration.zero);
    expect(latest['a'], VoiceEventKind.error,
        reason: 'unrelated metadata must not erase current failure');
    f.pool.replaceMixMetadata(TimelineModel(clips: [clip('future')]));
    await Future<void>.delayed(Duration.zero);
    expect(latest.containsKey('a'), isFalse,
        reason: 'retired clip no longer owns a status');
    await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    expect(f.pool.activeVoices['a']?.isReady, isTrue);
    expect(latest, {'a': VoiceEventKind.ready});
  });
  test(
      'native cleanup failure preserves primary decoder error and terminal ownership',
      () async {
    final f = Fixture();
    await f.pool.start();
    var latest = <String, VoiceEventKind>{};
    final subscription = f.pool.voiceStatusStream.listen((s) {
      latest = s;
    });
    addTearDown(subscription.cancel);
    final failure = StateError('primary decoder');
    f.voices.single.loadError = failure;
    f.voices.single.releaseError = StateError('secondary unload');
    await expectLater(f.pool.loadMix(TimelineModel(clips: [clip('a')])),
        throwsA(same(failure)));
    await Future<void>.delayed(Duration.zero);
    expect(latest, {'a': VoiceEventKind.error});
    expect(f.clock.isBufferingHeld, isFalse);
    expect(f.resolver.released, 0);
    await f.pool.dispose();
    expect(f.resolver.released, 1);
  });
  test('late cleanup cannot publish an error into a replacing model', () async {
    final f = Fixture(maxVoices: 2, spares: 1);
    await f.pool.start();
    var latest = <String, VoiceEventKind>{};
    final subscription = f.pool.voiceStatusStream.listen((s) {
      latest = s;
    });
    addTearDown(subscription.cancel);
    final unloading = f.gate();
    f.voices.first.loadError = StateError('retired decoder');
    f.voices.first.releaseGate = unloading;
    final loading = f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    await unloading.entered.future.timeout(deadline);
    final replacement = f.pool.loadMix(TimelineModel(clips: [clip('new')]));
    unloading.open();
    await Future.wait([loading, replacement]).timeout(deadline);
    expect(f.pool.activeVoices['new']?.isReady, isTrue);
    expect(latest, {'new': VoiceEventKind.ready});
  });
  test('same ID with a new source retires only its old terminal status',
      () async {
    final f = Fixture(maxVoices: 2, spares: 1);
    await f.pool.start();
    var latest = <String, VoiceEventKind>{};
    final subscription = f.pool.voiceStatusStream.listen((s) {
      latest = s;
    });
    addTearDown(subscription.cancel);
    final a = clip('a'), b = clip('b');
    final failure = StateError('decoder');
    f.voices.first.loadError = failure;
    await expectLater(
        f.pool.loadMix(TimelineModel(clips: [a, b])), throwsA(same(failure)));
    expect(latest, {'b': VoiceEventKind.ready, 'a': VoiceEventKind.error});
    final changed = MixClip(placement: a.placement, audioSourceRef: 'changed');
    // Metadata-only API requires unchanged placements/source for live voices;
    // A is terminal with no active voice, while B remains byte-identical.
    f.pool.replaceMixMetadata(TimelineModel(clips: [changed, b]));
    await Future<void>.delayed(Duration.zero);
    expect(latest, {'b': VoiceEventKind.ready});
    await f.pool.loadMix(TimelineModel(clips: [changed, b]),
        preserveActivePlayback: true);
    expect(f.pool.activeVoices['a']?.isReady, isTrue);
    expect(latest, {'b': VoiceEventKind.ready, 'a': VoiceEventKind.ready});
  });
  test(
      'failed capacity cleanup does not evict healthy peer or reuse retained bytes',
      () async {
    final f = Fixture(maxVoices: 2, spares: 1);
    await f.pool.start();
    await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    final a = f.pool.activeVoices['a']! as ProbeVoice;
    const failure = VoiceCapacityException('capacity');
    f.voices[1].loadError = failure;
    f.voices[1].releaseError = StateError('unload');
    await expectLater(
        f.pool.loadMix(TimelineModel(clips: [clip('a'), clip('b')])),
        throwsA(same(failure)));
    expect(f.pool.activeVoices['a'], same(a));
    expect(a.releases, 0);
    expect(f.voices[1].releases, 1);
    expect(f.resolver.acquired - f.resolver.released, 2);
    await f.pool.dispose();
    expect(f.resolver.released, f.resolver.acquired);
  });
}

class AppliedGainVoice extends ProbeVoice {
  AppliedGainVoice(super.debugId);
  double appliedGain = 0;
  final gainsApplied = <double>[];
  final loadEntryGains = <double>[];
  final initialPositions = <int>[];
  final playPositions = <int?>[];
  @override
  Future<void> play() async {
    playPositions.add(currentLocalPositionMs);
    await super.play();
  }

  @override
  Future<void> setVolume(double gain) async {
    await super.setVolume(gain);
    appliedGain = gain;
    gainsApplied.add(gain);
  }

  @override
  Future<void> load(Uri source, {int initialLocalPositionMs = 0}) async {
    loadEntryGains.add(appliedGain);
    initialPositions.add(initialLocalPositionMs);
    await super.load(source, initialLocalPositionMs: initialLocalPositionMs);
  }
}

void supplementalReconciliationCases() {
  test(
      'secondary control failure must not strand an independent healthy survivor',
      () async {
    final f = Fixture(maxVoices: 3, spares: 1);
    await f.pool.start();
    final aClip = clip('a'), cClip = clip('c');
    await f.pool.loadMix(TimelineModel(clips: [aClip, cClip]));
    await f.clock.play();
    await f.pool.syncAt(0, forceSeek: true);
    final a = f.pool.activeVoices['a']! as ProbeVoice;
    final c = f.pool.activeVoices['c']! as ProbeVoice;
    expect(c.isPlaying, isTrue);
    expect(c.gains.last, 1);
    final primary = StateError('primary entering decoder');
    a.gainError = StateError('secondary gain rejected');
    f.voices[2].loadError = primary;
    await expectLater(
        f.pool.loadMix(TimelineModel(clips: [aClip, clip('b'), cClip])),
        throwsA(same(primary)));
    expect(f.pool.activeVoices['c'], same(c));
    expect(c.isReady, isTrue);
    expect(c.gains.last, 1);
    expect(c.isPlaying, isTrue,
        reason:
            'C had no preparation/control failure and must be restored independently of A');
  });

  test(
      'held reconciliation gain cannot land after stop and unmute recycled owner load',
      () async {
    final clock = DefaultTimelineClock(
        now: () => DateTime.utc(2026),
        uiTickInterval: const Duration(hours: 1));
    final resolver = ProbeResolver();
    final voices = <AppliedGainVoice>[];
    final gate = Gate();
    final pool = VoicePool(
        clock: clock,
        resolver: resolver,
        maxVoices: 2,
        warmSpareVoices: 0,
        driftCheckInterval: const Duration(hours: 1),
        gainUpdateInterval: const Duration(hours: 1),
        voiceFactory: () {
          final v = AppliedGainVoice('v${voices.length}');
          voices.add(v);
          return v;
        });
    addTearDown(() async {
      gate.open();
      await pool.dispose();
      await clock.dispose();
    });
    await pool.start();
    await pool.loadMix(TimelineModel(clips: [clip('a')]));
    await clock.play();
    await pool.syncAt(0, forceSeek: true);
    final a = pool.activeVoices['a']! as AppliedGainVoice;
    expect(a.appliedGain, 1);
    a.gainGate = gate;
    final primary = StateError('entering decoder');
    voices[1].loadError = primary;
    final loading = pool.loadMix(TimelineModel(clips: [clip('a'), clip('b')]));
    final result = expectLater(loading, throwsA(same(primary)));
    await gate.entered.future.timeout(deadline);
    await pool.stop().timeout(deadline);
    expect(a.appliedGain, 0);
    final marker = a.gainsApplied.length;
    gate.open();
    await result.timeout(deadline);
    final retiredGainAcks = a.gainsApplied.skip(marker).toList();
    final gainAfterStop = a.appliedGain;
    // All native loads are successful from here. Reuse both idle transports,
    // so one positively is the previously held A transport.
    final replacing =
        pool.loadMix(TimelineModel(clips: [clip('new1'), clip('new2')]));
    await pool.start();
    await replacing;
    expect(pool.activeVoices.values, contains(same(a)));
    expect(a.loadEntryGains.length, 2);
    print(
        'retired gain ACKs=$retiredGainAcks, gain-after-stop=$gainAfterStop, recycled-load-entry-gain=${a.loadEntryGains.last}');
    expect(a.loadEntryGains.last, 0,
        reason:
            'new source must be muted at native load entry, not inherit retired positive gain ACK');
  });

  test(
      'queued old-position synchronization cannot play a replacing model at retired position',
      () async {
    final clock = DefaultTimelineClock(
        now: () => DateTime.utc(2026),
        uiTickInterval: const Duration(hours: 1));
    final resolver = ProbeResolver();
    final voices = <AppliedGainVoice>[];
    final gate = Gate();
    final pool = VoicePool(
        clock: clock,
        resolver: resolver,
        maxVoices: 1,
        warmSpareVoices: 0,
        prepareTimeout: const Duration(seconds: 1),
        driftCheckInterval: const Duration(hours: 1),
        gainUpdateInterval: const Duration(hours: 1),
        voiceFactory: () {
          final v = AppliedGainVoice('v${voices.length}');
          voices.add(v);
          return v;
        });
    addTearDown(() async {
      gate.open();
      await pool.dispose();
      await clock.dispose();
    });
    await pool.start();
    await clock.play();
    await pool.syncAt(0);
    voices.single.loadGate = gate;
    final oldLoad = pool.loadMix(TimelineModel(clips: [clip('old')]));
    await gate.entered.future.timeout(deadline);
    final oldPosition = pool.syncAt(6000, forceSeek: true);
    final replacement = pool.loadMix(TimelineModel(clips: [clip('new')]));
    gate.open();
    await Future.wait([oldLoad, oldPosition, replacement]).timeout(deadline);
    print(
        'replacement load positions=${voices.single.initialPositions}, play positions=${voices.single.playPositions}');
    expect(pool.model.clips.single.id, 'new');
    expect(voices.single.loads, [Uri.file('/old.wav'), Uri.file('/new.wav')]);
    expect(voices.single.initialPositions, isNot(contains(6000)),
        reason: 'retired position must be rejected before native load too');
    expect(voices.single.playPositions, isNot(contains(6000)),
        reason:
            'queued synchronization belonged to old model intent, not replacement');
  });

  test(
      'equivalent metadata during reconciliation does not revoke valid restored peer',
      () async {
    final f = Fixture(maxVoices: 2, spares: 1);
    await f.pool.start();
    await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    await f.clock.play();
    await f.pool.syncAt(0, forceSeek: true);
    final a = f.pool.activeVoices['a']! as ProbeVoice;
    final gate = f.gate();
    a.gainGate = gate;
    final primary = StateError('entering decoder');
    f.voices[1].loadError = primary;
    final result = expectLater(
        f.pool.loadMix(TimelineModel(clips: [clip('a'), clip('b')])),
        throwsA(same(primary)));
    await gate.entered.future.timeout(deadline);
    f.pool.replaceMixMetadata(TimelineModel(clips: [clip('a'), clip('b')]));
    gate.open();
    await result.timeout(deadline);
    expect(f.pool.activeVoices['a'], same(a));
    expect(a.gains.last, 1);
    expect(a.isPlaying, isTrue);
  });

  test(
      'equivalent newly allocated metadata retains current terminal clip failure',
      () async {
    final f = Fixture();
    await f.pool.start();
    final first = clip('a');
    final equal = clip('a');
    expect(equal, first);
    expect(identical(equal, first), isFalse);
    final failure = StateError('decoder');
    f.voices.single.loadError = failure;
    var latest = <String, VoiceEventKind>{};
    final sub = f.pool.voiceStatusStream.listen((s) => latest = s);
    addTearDown(sub.cancel);
    await expectLater(
        f.pool.loadMix(TimelineModel(clips: [first])), throwsA(same(failure)));
    await Future<void>.delayed(Duration.zero);
    expect(latest['a'], VoiceEventKind.error);
    f.pool.replaceMixMetadata(TimelineModel(clips: [equal]));
    await Future<void>.delayed(Duration.zero);
    expect(latest['a'], VoiceEventKind.error);
  });
}

void gainRetirementSiblingCases() {
  test('rejected gain is retried instead of cached as applied', () async {
    final f = Fixture();
    await f.pool.start();
    await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    final a = f.voices.single;
    final failure = StateError('gain rejected');
    a.gainError = failure;
    await expectLater(
        f.pool.syncAt(0, forceSeek: true), throwsA(same(failure)));
    final attempts = a.gains.length;
    await f.pool.syncAt(0);
    expect(a.gains.length, attempts + 1);
    expect(a.gains.last, 1);
  });

  test('disposal drains held gain after stop has already completed', () async {
    final f = Fixture(maxVoices: 2);
    await f.pool.start();
    await f.pool.loadMix(TimelineModel(clips: [clip('a')]));
    await f.clock.play();
    await f.pool.syncAt(0, forceSeek: true);
    final a = f.pool.activeVoices['a']! as ProbeVoice;
    final gate = f.gate();
    a.gainGate = gate;
    final failure = StateError('entering decoder');
    f.voices[1].loadError = failure;
    final result = expectLater(
      f.pool.loadMix(TimelineModel(clips: [clip('a'), clip('b')])),
      throwsA(same(failure)),
    );
    await gate.entered.future.timeout(deadline);
    await f.pool.stop().timeout(deadline);
    var disposed = false;
    final disposal = f.pool.dispose().then((_) => disposed = true);
    // Drain independent async turns without releasing the acknowledged control.
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final disposedWhileHeld = disposed;
    final disposalsWhileHeld = a.disposals;
    gate.open();
    await result.timeout(deadline);
    await disposal.timeout(deadline);
    expect(disposedWhileHeld, isFalse);
    expect(disposalsWhileHeld, 0);
    expect(a.disposals, 1);
  });
}

class DriftGainVoice extends AppliedGainVoice {
  DriftGainVoice(super.debugId);
  bool drifted = false;
  @override
  int? driftMs(int expectedLocalPositionMs) => drifted ? 1000 : 0;
}

void gainReuseSiblingCases() {
  test('new load drains an old drift gain without blocking stop', () async {
    final clock = DefaultTimelineClock(
      now: () => DateTime.utc(2026),
      uiTickInterval: const Duration(hours: 1),
    );
    final resolver = ProbeResolver();
    final voice = DriftGainVoice('drift');
    final gate = Gate();
    final pool = VoicePool(
      clock: clock,
      resolver: resolver,
      maxVoices: 1,
      warmSpareVoices: 0,
      prepareTimeout: const Duration(seconds: 1),
      driftCheckInterval: const Duration(milliseconds: 10),
      gainUpdateInterval: const Duration(hours: 1),
      voiceFactory: () => voice,
    );
    addTearDown(() async {
      gate.open();
      await pool.dispose();
      await clock.dispose();
    });
    await pool.start();
    await pool.loadMix(TimelineModel(clips: [clip('a')]));
    await clock.play();
    await pool.syncAt(0, forceSeek: true);
    voice.gainGate = gate;
    voice.drifted = true;
    await gate.entered.future.timeout(deadline);
    voice.drifted = false;
    await pool.stop().timeout(deadline);
    expect(voice.appliedGain, 0);
    final preparing = pool.voiceStatusStream.firstWhere(
      (status) => status['new'] == VoiceEventKind.buffering,
    );
    final replacing = pool.loadMix(TimelineModel(clips: [clip('new')]));
    final starting = pool.start();
    await preparing.timeout(deadline);
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final loadsWhileHeld = voice.loads.toList();
    gate.open();
    await Future.wait([replacing, starting]).timeout(deadline);
    expect(loadsWhileHeld, [Uri.file('/a.wav')]);
    expect(pool.activeVoices['new'], same(voice));
    expect(voice.loads, [Uri.file('/a.wav'), Uri.file('/new.wav')]);
    expect(voice.loadEntryGains.last, 0);
  });
}
