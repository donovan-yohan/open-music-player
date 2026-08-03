import 'package:flutter/material.dart';

class DjPitchFader extends StatelessWidget {
  const DjPitchFader({
    super.key,
    required this.percent,
    required this.onChanged,
    this.onNudgeStart,
    this.onNudgeEnd,
  });

  final double percent;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onNudgeStart;
  final VoidCallback? onNudgeEnd;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          SizedBox(
            height: 48,
            width: 48,
            child: Listener(
              onPointerDown: (_) => onNudgeStart?.call(-2),
              onPointerUp: (_) => onNudgeEnd?.call(),
              onPointerCancel: (_) => onNudgeEnd?.call(),
              child: const Center(child: Icon(Icons.keyboard_arrow_up)),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onDoubleTap: () => onChanged(0),
              child: RotatedBox(
                quarterTurns: 3,
                child: Slider(
                  key: const ValueKey('dj_pitch_fader'),
                  value: percent.clamp(-25.0, 25.0),
                  min: -25,
                  max: 25,
                  divisions: 100,
                  label: '${percent.toStringAsFixed(1)}%',
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 48,
            width: 48,
            child: Listener(
              onPointerDown: (_) => onNudgeStart?.call(2),
              onPointerUp: (_) => onNudgeEnd?.call(),
              onPointerCancel: (_) => onNudgeEnd?.call(),
              child: const Center(child: Icon(Icons.keyboard_arrow_down)),
            ),
          ),
        ],
      );
}
