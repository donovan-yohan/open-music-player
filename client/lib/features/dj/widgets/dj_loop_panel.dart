import 'package:flutter/material.dart';

class DjLoopPanel extends StatelessWidget {
  const DjLoopPanel({
    super.key,
    required this.onLoop,
    required this.onExit,
    this.onIn,
    this.onOut,
  });
  final ValueChanged<int> onLoop;
  final VoidCallback onExit;
  final VoidCallback? onIn;
  final VoidCallback? onOut;
  @override
  Widget build(BuildContext context) => Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final beats in const [1, 2, 4, 8, 16])
            OutlinedButton(
              key: ValueKey('dj_loop_$beats'),
              onPressed: () => onLoop(beats),
              child: Text('$beats'),
            ),
          OutlinedButton(onPressed: onIn, child: const Text('IN')),
          OutlinedButton(onPressed: onOut, child: const Text('OUT')),
          OutlinedButton(onPressed: onExit, child: const Text('EXIT')),
        ],
      );
}
