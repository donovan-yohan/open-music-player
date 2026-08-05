import 'package:flutter/material.dart';

import '../models/dj_deck_state.dart';

class DjMixerPanel extends StatelessWidget {
  const DjMixerPanel({
    super.key,
    required this.deckA,
    required this.deckB,
    required this.onGainA,
    required this.onGainB,
  });
  final DjDeckState deckA;
  final DjDeckState deckB;
  final ValueChanged<double> onGainA;
  final ValueChanged<double> onGainB;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(
            child: _ChannelFader(
              label: 'A',
              gain: deckA.channelGain,
              onChanged: onGainA,
            ),
          ),
          Expanded(
            child: _ChannelFader(
              label: 'B',
              gain: deckB.channelGain,
              onChanged: onGainB,
            ),
          ),
        ],
      );
}

class _ChannelFader extends StatelessWidget {
  const _ChannelFader({
    required this.label,
    required this.gain,
    required this.onChanged,
  });
  final String label;
  final double gain;
  final ValueChanged<double> onChanged;
  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(label),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(value: gain.clamp(0, 1), onChanged: onChanged),
            ),
          ),
        ],
      );
}
