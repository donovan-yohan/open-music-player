import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/audio/debug_mix_audio_handler.dart';
import '../../core/engine/gain_envelope.dart';
import '../../core/engine/timeline_clock.dart';
import '../../core/engine/voice.dart';
import '../../core/engine/voice_pool.dart';

class DebugMixEngineScreen extends StatefulWidget {
  const DebugMixEngineScreen({super.key});

  @override
  State<DebugMixEngineScreen> createState() => _DebugMixEngineScreenState();
}

class _DebugMixEngineScreenState extends State<DebugMixEngineScreen> {
  static const _defaultA =
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3';
  static const _defaultB =
      'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3';

  late final DefaultTimelineClock _clock;
  late final VoicePool _pool;
  final _trackAController = TextEditingController(text: _defaultA);
  final _trackBController = TextEditingController(text: _defaultB);
  final _durationController = TextEditingController(text: '30');
  final _fadeController = TextEditingController(text: '6');
  final List<StreamSubscription> _subscriptions = [];

  DebugMixAudioHandler? _handler;
  int _positionMs = 0;
  int _durationMs = 30000;
  bool _isPlaying = false;
  bool _isBufferingHeld = false;
  String _status = 'not loaded';
  Map<String, VoiceEventKind> _voiceStatus = const {};

  @override
  void initState() {
    super.initState();
    _clock = DefaultTimelineClock(
      uiTickInterval: const Duration(milliseconds: 100),
    );
    _pool = VoicePool(clock: _clock, voiceFactory: _makeVoice, maxVoices: 2);
    _subscriptions
      ..add(
        _clock.positionMsStream.listen((positionMs) {
          if (!mounted) return;
          setState(() => _positionMs = positionMs);
        }),
      )
      ..add(
        _clock.isPlayingStream.listen((playing) {
          if (!mounted) return;
          setState(() => _isPlaying = playing);
        }),
      )
      ..add(
        _clock.isBufferingHeldStream.listen((held) {
          if (!mounted) return;
          setState(() => _isBufferingHeld = held);
        }),
      )
      ..add(
        _pool.voiceStatusStream.listen((status) {
          if (!mounted) return;
          setState(() => _voiceStatus = status);
        }),
      );
    unawaited(_pool.start());
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
    unawaited(_handler?.stop());
    unawaited(_pool.dispose());
    unawaited(_clock.dispose());
    _trackAController.dispose();
    _trackBController.dispose();
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
            'Phase 0 debug-only proof: two just_audio voices, track B starts at A midpoint, both use equal-power fades, and this one clock slider scrubs both voices.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _trackAController,
            decoration: const InputDecoration(
              labelText: 'Track A URL',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _trackBController,
            decoration: const InputDecoration(
              labelText: 'Track B URL',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _durationController,
                  decoration: const InputDecoration(
                    labelText: 'Proof duration (seconds)',
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
            label: const Text('Load 2-track overlap'),
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
                      setState(() => _positionMs = value.round());
                    },
                    onChangeStart: (_) => _clock.beginScrub(),
                    onChangeEnd: (value) =>
                        unawaited(_clock.endScrub(value.round())),
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
                                _isPlaying ? _clock.pause() : _clock.play(),
                              ),
                        icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                        label: Text(_isPlaying ? 'Pause' : 'Play'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => unawaited(_clock.seek(0)),
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
            child: ListTile(
              leading: Icon(
                _isBufferingHeld
                    ? Icons.hourglass_top
                    : Icons.check_circle_outline,
              ),
              title: Text(_status),
              subtitle: Text(
                'A: ${_voiceStatus['a']?.name ?? 'idle'} · B: ${_voiceStatus['b']?.name ?? 'idle'}',
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Manual acceptance: run this on a physical device, load, press play, confirm two audible streams during the overlap, independent fade/gain movement, slider scrub moves both voices, then background the app and confirm playback continues.',
          ),
        ],
      ),
    );
  }

  Future<void> _initBackgroundHandler() async {
    if (kIsWeb) {
      setState(
        () =>
            _status = 'loaded without audio_service background handler on web',
      );
      return;
    }
    try {
      _handler = await audio_service.AudioService.init<DebugMixAudioHandler>(
        builder: () => DebugMixAudioHandler(clock: _clock),
        config: const audio_service.AudioServiceConfig(
          androidNotificationChannelId: 'open_music_player.debug_mix_engine',
          androidNotificationChannelName: 'Debug mix engine',
          androidNotificationOngoing: true,
        ),
      );
      if (!mounted) return;
      setState(() => _status = 'background handler ready; load the overlap');
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = 'background handler unavailable: $error');
    }
  }

  Future<void> _loadProof() async {
    final uriA = Uri.tryParse(_trackAController.text.trim());
    final uriB = Uri.tryParse(_trackBController.text.trim());
    if (uriA == null || uriB == null || !uriA.hasScheme || !uriB.hasScheme) {
      _showSnack('enter two playable http/file URLs');
      return;
    }

    final durationSeconds = int.tryParse(_durationController.text.trim()) ?? 30;
    final fadeSeconds = int.tryParse(_fadeController.text.trim()) ?? 6;
    final durationMs = math.max(2000, durationSeconds * 1000);
    final fadeMs = math.max(0, fadeSeconds * 1000);
    final midpointMs = durationMs ~/ 2;
    final clipDurationMs = midpointMs + fadeMs;

    await _clock.pause();
    await _pool.loadClips([
      MixVoiceClip(
        id: 'a',
        source: uriA,
        timelineStartMs: 0,
        durationMs: durationMs,
        envelope: GainEnvelope(fadeOutMs: fadeMs),
      ),
      MixVoiceClip(
        id: 'b',
        source: uriB,
        timelineStartMs: midpointMs,
        durationMs: clipDurationMs,
        envelope: GainEnvelope(fadeInMs: fadeMs),
      ),
    ]);
    _handler?.updateDuration();
    if (!mounted) return;
    setState(() {
      _durationMs = _clock.durationMs;
      _positionMs = _clock.positionMs;
      _status =
          'loaded: B starts at ${_formatMs(midpointMs)}, ${fadeSeconds}s equal-power fade';
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _formatMs(int ms) {
    final duration = Duration(milliseconds: ms);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}
