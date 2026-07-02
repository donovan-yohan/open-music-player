import 'dart:async';
import 'dart:math' as math;

import 'gain_envelope.dart';
import 'timeline_clock.dart';
import 'voice.dart';

class MixVoiceClip {
  final String id;
  final Uri source;
  final int timelineStartMs;
  final int durationMs;
  final int sourceStartMs;
  final GainEnvelope envelope;

  const MixVoiceClip({
    required this.id,
    required this.source,
    required this.timelineStartMs,
    required this.durationMs,
    this.sourceStartMs = 0,
    this.envelope = const GainEnvelope.flat(),
  });

  int get timelineEndMs => timelineStartMs + durationMs;

  bool isActiveAt(int globalMs) =>
      globalMs >= timelineStartMs && globalMs < timelineEndMs;

  int localPositionAt(int globalMs) =>
      math.max(0, sourceStartMs + globalMs - timelineStartMs);

  double gainAt(int globalMs) =>
      envelope.gainAt(globalMs - timelineStartMs, durationMs);
}

class VoicePool {
  VoicePool({
    required TimelineClock clock,
    required VoiceFactory voiceFactory,
    int maxVoices = 2,
  })  : _clock = clock,
        _voiceFactory = voiceFactory,
        _maxVoices = maxVoices;

  final TimelineClock _clock;
  final VoiceFactory _voiceFactory;
  final int _maxVoices;

  final Map<String, Voice> _activeVoices = {};
  final Map<String, MixVoiceClip> _activeClips = {};
  final List<Voice> _idleVoices = [];
  final List<Voice> _allVoices = [];
  final _voiceStatusController =
      StreamController<Map<String, VoiceEventKind>>.broadcast();
  final Map<String, VoiceEventKind> _voiceStatus = {};

  List<MixVoiceClip> _clips = const [];
  final List<StreamSubscription> _subscriptions = [];
  int _generation = 0;
  bool _started = false;

  List<MixVoiceClip> get clips => List.unmodifiable(_clips);

  Map<String, Voice> get activeVoices => Map.unmodifiable(_activeVoices);

  int get generation => _generation;

  Stream<Map<String, VoiceEventKind>> get voiceStatusStream =>
      _voiceStatusController.stream;

  Future<void> start() async {
    if (_started) return;
    _started = true;
    for (var i = 0; i < _maxVoices; i++) {
      final voice = _voiceFactory();
      _allVoices.add(voice);
      _idleVoices.add(voice);
    }
    _subscriptions
      ..add(
        _clock.positionMsStream.listen((ms) {
          unawaited(syncAt(ms));
        }),
      )
      ..add(
        _clock.scrubCommittedStream.listen((ms) {
          unawaited(syncAt(ms, forceSeek: true));
        }),
      )
      ..add(
        _clock.isPlayingStream.listen((playing) {
          unawaited(_setActivePlayback(playing));
        }),
      );
    await syncAt(_clock.positionMs);
  }

  Future<void> loadClips(List<MixVoiceClip> clips) async {
    _clips = [...clips]
      ..sort((a, b) => a.timelineStartMs.compareTo(b.timelineStartMs));
    final totalDuration = _clips.fold<int>(
      0,
      (maxEnd, clip) => math.max(maxEnd, clip.timelineEndMs),
    );
    _clock.durationMs = totalDuration;
    await syncAt(_clock.positionMs, forceSeek: true);
  }

  Future<void> syncAt(int globalMs, {bool forceSeek = false}) async {
    if (!_started) return;
    final generation = ++_generation;
    final active = _clips
        .where((clip) => clip.isActiveAt(globalMs))
        .take(_maxVoices)
        .toList();
    final activeIds = active.map((clip) => clip.id).toSet();

    for (final entry in _activeVoices.entries.toList()) {
      if (activeIds.contains(entry.key)) continue;
      final voice = entry.value;
      _activeVoices.remove(entry.key);
      _activeClips.remove(entry.key);
      _voiceStatus.remove(entry.key);
      await voice.setVolume(0);
      await voice.release();
      _idleVoices.add(voice);
    }

    for (final clip in active) {
      final existing = _activeVoices[clip.id];
      if (existing != null) {
        if (forceSeek) {
          await existing.seekLocal(clip.localPositionAt(globalMs));
        }
        await existing.setVolume(clip.gainAt(globalMs));
        if (_clock.isPlaying && !existing.isPlaying) {
          await existing.play();
        }
        continue;
      }

      if (_idleVoices.isEmpty) break;
      final voice = _idleVoices.removeAt(0);
      _activeVoices[clip.id] = voice;
      _activeClips[clip.id] = clip;
      _voiceStatus[clip.id] = VoiceEventKind.buffering;
      _publishStatus();

      await voice.setVolume(0);
      await voice.load(
        clip.source,
        initialLocalPositionMs: clip.localPositionAt(globalMs),
      );
      if (generation != _generation) return;
      _voiceStatus[clip.id] = VoiceEventKind.ready;
      await voice.setVolume(clip.gainAt(globalMs));
      if (_clock.isPlaying) {
        await voice.play();
      }
      _publishStatus();
    }

    _updateBufferingHold(active);
  }

  Future<void> stop() async {
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    for (final voice in _activeVoices.values.toList()) {
      await voice.setVolume(0);
      await voice.release();
      _idleVoices.add(voice);
    }
    _activeVoices.clear();
    _activeClips.clear();
    _voiceStatus.clear();
    _started = false;
    _clock.releaseHold();
    _publishStatus();
  }

  Future<void> dispose() async {
    await stop();
    for (final voice in _allVoices) {
      await voice.dispose();
    }
    _allVoices.clear();
    _idleVoices.clear();
    await _voiceStatusController.close();
  }

  Future<void> _setActivePlayback(bool playing) async {
    for (final voice in _activeVoices.values.toList()) {
      if (playing) {
        await voice.play();
      } else {
        await voice.pause();
      }
    }
  }

  void _updateBufferingHold(List<MixVoiceClip> active) {
    if (active.isEmpty) {
      _clock.releaseHold();
      return;
    }

    final hasReadyVoice = active.any(
      (clip) => _activeVoices[clip.id]?.isReady ?? false,
    );
    if (hasReadyVoice) {
      _clock.releaseHold();
    } else {
      _clock.holdForBuffering();
    }
  }

  void _publishStatus() {
    if (!_voiceStatusController.isClosed) {
      _voiceStatusController.add(Map.unmodifiable(_voiceStatus));
    }
  }
}
