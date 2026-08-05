import 'package:flutter/material.dart';

class DjTransport extends StatelessWidget {
  const DjTransport({
    super.key,
    required this.playing,
    required this.onCuePress,
    required this.onCueRelease,
    required this.onPlayPause,
  });
  final bool playing;
  final VoidCallback onCuePress;
  final VoidCallback onCueRelease;
  final VoidCallback onPlayPause;
  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          Listener(
            onPointerDown: (_) => onCuePress(),
            onPointerUp: (_) => onCueRelease(),
            onPointerCancel: (_) => onCueRelease(),
            child: FilledButton(
              key: const ValueKey('dj_cue'),
              onPressed: () {},
              child: const Text('CUE'),
            ),
          ),
          IconButton.filled(
            key: const ValueKey('dj_play_pause'),
            tooltip: playing ? 'Pause' : 'Play',
            iconSize: 28,
            onPressed: onPlayPause,
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
          ),
          const Tooltip(
            message: 'sync engine: phase 2',
            child: IconButton(onPressed: null, icon: Icon(Icons.sync)),
          ),
        ],
      );
}
