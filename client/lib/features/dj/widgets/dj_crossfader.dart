import 'package:flutter/material.dart';
import '../../../core/engine/gain_envelope.dart';

/// DJ naming adapter over the engine's single equal-power implementation.
({double a, double b}) equalPowerCrossfaderGains(double position) {
  final gains = equalPowerCrossfadeGains(position);
  return (a: gains.left, b: gains.right);
}

class DjCrossfader extends StatelessWidget {
  const DjCrossfader({super.key, required this.value, required this.onChanged});

  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        // Bottom gesture navigation cannot be excluded. Keep both the control
        // and its drag start away from the edge instead.
        padding: const EdgeInsets.only(bottom: 12, left: 12, right: 12),
        child: Slider(
          key: const ValueKey('dj_crossfader'),
          value: value.clamp(0.0, 1.0),
          onChanged: onChanged,
          semanticFormatterCallback: (v) => 'crossfader ${(v * 100).round()}%',
        ),
      );
}
