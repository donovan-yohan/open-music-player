import 'package:flutter/material.dart';

import '../models/dj_hot_cue.dart';

class DjHotCuePads extends StatelessWidget {
  const DjHotCuePads({
    super.key,
    required this.cues,
    required this.onTrigger,
    required this.onSet,
  });
  final Map<int, DjHotCue> cues;
  final ValueChanged<int> onTrigger;
  final ValueChanged<int> onSet;

  @override
  Widget build(BuildContext context) => GridView.count(
        crossAxisCount: 4,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
        childAspectRatio: 1.35,
        children: [
          for (var slot = 1; slot <= 4; slot++)
            GestureDetector(
              onLongPress: () => onSet(slot),
              child: FilledButton(
                key: ValueKey('dj_hot_cue_$slot'),
                onPressed: () => onTrigger(slot),
                child: Text(cues.containsKey(slot) ? 'C$slot' : '$slot'),
              ),
            ),
        ],
      );
}
