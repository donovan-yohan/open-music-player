import 'package:flutter/material.dart';

import '../models/stem_channel_source.dart';

class DjStemPanel extends StatelessWidget {
  const DjStemPanel({super.key, required this.source});
  final StemChannelSource source;

  @override
  Widget build(BuildContext context) {
    if (!source.isAvailable) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final stem in source.channels)
          SizedBox(
            width: 54,
            child: Column(
              children: [
                Expanded(
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Slider(
                      value: stem.gain.clamp(0, 1),
                      onChanged: stem.muted
                          ? null
                          : (value) => source.setGain(stem.id, value),
                    ),
                  ),
                ),
                Text(stem.label, overflow: TextOverflow.ellipsis),
                IconButton(
                  tooltip: stem.muted
                      ? 'Unmute ${stem.label}'
                      : 'Mute ${stem.label}',
                  onPressed: () => source.setMute(stem.id, !stem.muted),
                  icon: Icon(stem.muted ? Icons.volume_off : Icons.volume_up),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
