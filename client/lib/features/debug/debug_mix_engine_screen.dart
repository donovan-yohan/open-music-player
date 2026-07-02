import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/audio/audio_focus_coordinator.dart';
import '../../core/audio/mix_audio_handler.dart';
import '../../core/engine/gain_envelope.dart';
import '../../core/engine/playback_engine.dart';
import '../../core/engine/timeline_clock.dart';
import '../../core/engine/timeline_model.dart';
import '../../core/engine/voice.dart';
import '../../core/engine/voice_pool.dart';
import '../../models/timeline_clip.dart';

class DebugMixEngineScreen extends StatefulWidget {
  const DebugMixEngineScreen({super.key});

  @override
  State<DebugMixEngineScreen> createState() => _DebugMixEngineScreenState();
}

class _DebugMixEngineScreenState extends State<DebugMixEngineScreen> {
  static const _productionBackgroundEnabled = bool.fromEnvironment(
    'OMP_ENABLE_JUST_AUDIO_BACKGROUND',
    defaultValue: true,
  );

  static const _defaults = [
    String.fromEnvironment(
      'OMP_MIX_PROOF_TRACK_1_URL',
      defaultValue:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3',
    ),
    String.fromEnvironment(
      'OMP_MIX_PROOF_TRACK_2_URL',
      defaultValue:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3',
    ),
    String.fromEnvironment(
      'OMP_MIX_PROOF_TRACK_3_URL',
      defaultValue:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3',
    ),
    String.fromEnvironment(
      'OMP_MIX_PROOF_TRACK_4_URL',
      defaultValue:
          'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-4.mp3',
    ),
  ];

  late final DefaultTimelineClock _clock;
  late final PlaybackEngine _engine;
  final _trackControllers = [
    for (final url in _defaults) TextEditingController(text: url),
  ];
  final _durationController = TextEditingController(text: '36');
  final _fadeController = TextEditingController(text: '5');
  final List<StreamSubscription> _subscriptions = [];

  MixAudioHandler? _handler;
  AudioFocusCoordinator? _focusCoordinator;
  int _positionMs = 0;
  int _durationMs = 36000;
  bool _isPlaying = false;
  String _status = 'not loaded';
  Map<String, VoiceEventKind> _voiceStatus = const {};
  MixNowPlayingInfo? _nowPlaying;

  @override
  void initState() {
    super.initState();
    _clock =
        DefaultTimelineClock(uiTickInterval: const Duration(milliseconds: 100));
    _engine = PlaybackEngine(
      clock: _clock,
      // The physical proof should wait a little longer for all four voices at
      // scrub commits and avoid tiny corrective seeks that sound like jitter.
      voicePool: VoicePool(
        clock: _clock,
        voiceFactory: _makeVoice,
        prepareTimeout: const Duration(milliseconds: 2500),
        driftCheckInterval: const Duration(seconds: 3),
        driftCorrectionThreshold: const Duration(milliseconds: 1200),
        driftCorrectionCooldown: const Duration(seconds: 12),
      ),
    );
    _subscriptions
      ..add(_engine.positionMsStream.listen((positionMs) {
        if (!mounted) return;
        setState(() => _positionMs = positionMs);
      }))
      ..add(_engine.isPlayingStream.listen((playing) {
        if (!mounted) return;
        setState(() => _isPlaying = playing);
      }))
      ..add(_engine.pool.voiceStatusStream.listen((status) {
        if (!mounted) return;
        setState(() => _voiceStatus = status);
      }))
      ..add(_engine.nowPlayingStream.listen((info) {
        if (!mounted) return;
        setState(() => _nowPlaying = info);
      }));
    unawaited(_engine.start());
    unawaited(_initBackgroundHandler());
  }

  Voice _makeVoice() => JustAudioVoice(
        debugId: 'debug-voice-${DateTime.now().microsecondsSinceEpoch}',
      );

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    unawaited(_focusCoordinator?.dispose());
    unawaited(_handler?.stop());
    unawaited(_engine.dispose());
    for (final controller in _trackControllers) {
      controller.dispose();
    }
    _durationController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final duration = math.max(_durationMs, 1);
    return Scaffold(
      appBar: AppBar(title: const Text('Mix engine proof')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Phase 2 debug proof: four independent just_audio voices, one TimelineClock, coordinated scrub commit, focus-aware pause/resume, and debug notification transport. Physical Android proof still required.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < _trackControllers.length; i++) ...[
            TextField(
              controller: _trackControllers[i],
              decoration: InputDecoration(
                labelText: 'Track ${i + 1} URL',
                border: const OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
          ],
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _durationController,
                  decoration: const InputDecoration(
                    labelText: 'Track duration (seconds)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _fadeController,
                  decoration: const InputDecoration(
                    labelText: 'Fade (seconds)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loadProof,
            icon: const Icon(Icons.multitrack_audio),
            label: const Text('Load 4-track overlap'),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Transport', style: theme.textTheme.titleMedium),
                  Slider(
                    value: _positionMs.clamp(0, duration).toDouble(),
                    max: duration.toDouble(),
                    label: _formatMs(_positionMs),
                    onChanged: (value) {
                      _engine.updateScrub(value.round());
                      setState(() => _positionMs = value.round());
                    },
                    onChangeStart: (_) => _engine.beginScrub(),
                    onChangeEnd: (value) =>
                        unawaited(_engine.endScrub(value.round())),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_formatMs(_positionMs)),
                      Text(_formatMs(_durationMs)),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _durationMs == 0
                            ? null
                            : () => unawaited(
                                _isPlaying ? _engine.pause() : _engine.play()),
                        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                        label: Text(_isPlaying ? 'Pause' : 'Play'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => unawaited(_engine.seek(0)),
                        icon: const Icon(Icons.replay),
                        label: const Text('Restart'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.equalizer),
                    title: Text(_status),
                    subtitle: Text(
                      'dominant: ${_nowPlaying?.clipId ?? 'none'} · active voices: ${_nowPlaying?.activeVoiceCount ?? 0}',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final id in ['a', 'b', 'c', 'd'])
                        Chip(
                            label: Text(
                                '$id: ${_voiceStatus[id]?.name ?? 'idle'}')),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Manual Android checklist: load four distinct tracks, confirm all four overlap audibly, scrub around each entry and verify ready layers commit together, cross a tight boundary, background/foreground, use notification controls, and trigger transient focus loss. Do not count emulator/VM as hardware acceptance.',
          ),
        ],
      ),
    );
  }

  Future<void> _initBackgroundHandler() async {
    if (kIsWeb) {
      setState(() => _status = 'web: background handler/focus session skipped');
      return;
    }
    if (_productionBackgroundEnabled) {
      setState(
        () => _status =
            'mix proof disabled: rebuild with OMP_ENABLE_JUST_AUDIO_BACKGROUND=false',
      );
      return;
    }
    try {
      _handler = await audio_service.AudioService.init<MixAudioHandler>(
        builder: () => MixAudioHandler(engine: _engine),
        config: const audio_service.AudioServiceConfig(
          androidNotificationChannelId: 'open_music_player.mix_engine_phase_2',
          androidNotificationChannelName: 'Mix engine proof',
          androidNotificationOngoing: true,
        ),
      );
      _focusCoordinator = AudioFocusCoordinator(engine: _engine);
      await _focusCoordinator!.start();
      if (!mounted) return;
      setState(
          () => _status = 'background handler/focus ready; load the overlap');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'background handler unavailable: $error');
    }
  }

  Future<void> _loadProof() async {
    if (!kIsWeb && _productionBackgroundEnabled) {
      _showSnack(
        'Phase 2 mix proof requires OMP_ENABLE_JUST_AUDIO_BACKGROUND=false',
      );
      return;
    }

    final uris = _trackControllers
        .map((controller) => Uri.tryParse(controller.text.trim()))
        .toList();
    if (uris.any((uri) => uri == null || !uri.hasScheme)) {
      _showSnack('enter four playable http/file URLs');
      return;
    }

    final durationSeconds = int.tryParse(_durationController.text.trim()) ?? 36;
    final fadeSeconds = int.tryParse(_fadeController.text.trim()) ?? 5;
    final durationMs = math.max(4000, durationSeconds * 1000);
    final fadeMs = math.max(0, fadeSeconds * 1000);
    final staggerMs = math.max(1000, durationMs ~/ 5);

    await _engine.pause();
    await _engine.loadMix(
      TimelineModel(
        clips: [
          for (var i = 0; i < uris.length; i++)
            MixClip(
              placement: TimelineClip.clamped(
                id: String.fromCharCode('a'.codeUnitAt(0) + i),
                trackId: 'debug-${i + 1}',
                sourceDurationMs: durationMs,
                sourceStartMs: 0,
                sourceEndMs: durationMs,
                timelineStartMs: i * staggerMs,
              ),
              audioSourceRef: uris[i].toString(),
              envelope: GainEnvelope(
                fadeInMs: i == 0 ? 0 : fadeMs,
                fadeOutMs: fadeMs,
              ),
            ),
        ],
      ),
    );
    _handler?.updateDuration();
    if (!mounted) return;
    setState(() {
      _durationMs = _engine.durationMs;
      _positionMs = _engine.positionMs;
      _status =
          'loaded: four tracks stagger every ${_formatMs(staggerMs)}, ${fadeSeconds}s fades';
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatMs(int ms) {
    final duration = Duration(milliseconds: ms);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
