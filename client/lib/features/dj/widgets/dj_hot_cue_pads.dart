import 'package:flutter/material.dart';

import '../models/dj_hot_cue.dart';

class DjHotCuePads extends StatelessWidget {
  const DjHotCuePads({
    super.key,
    required this.cues,
    required this.onTrigger,
    required this.onSet,
    this.enabled = true,
  });
  final Map<int, DjHotCue> cues;
  final ValueChanged<int> onTrigger;
  final ValueChanged<int> onSet;

  /// Whether this deck holds audio. Pads on an empty deck used to be fully
  /// coloured and fully armed, and setting a cue on a zero-duration deck is
  /// what produced the divide-by-zero in the overview strip (#414).
  final bool enabled;

  @override
  Widget build(BuildContext context) => GridView.count(
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1.35,
        children: [
          for (var slot = 1; slot <= 4; slot++)
            GestureDetector(
              onLongPress: enabled ? () => onSet(slot) : null,
              child: FilledButton(
                key: ValueKey('dj_hot_cue_$slot'),
                onPressed: enabled ? () => onTrigger(slot) : null,
                child: Text(cues.containsKey(slot) ? 'C$slot' : '$slot'),
              ),
            ),
        ],
      );
}
