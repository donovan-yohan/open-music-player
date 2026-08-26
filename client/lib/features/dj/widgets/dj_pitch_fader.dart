import 'package:flutter/material.dart';

/// Fader height at or above which the nudge zones keep the 48dp touch target.
const double kDjPitchFaderFullNudgeHeight = 144;

/// Fader height at or above which the nudge zones are 40dp.
const double kDjPitchFaderMediumNudgeHeight = 96;

/// Fader height at or above which the nudge zones are 24dp; below it the nudge
/// zones are omitted and only the slider remains.
const double kDjPitchFaderCompactNudgeHeight = 64;

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

  /// Deterministic ladder on the fader's own height. The slider stays
  /// `Expanded`, so `nudge * 2 <= maxHeight` always holds and the column cannot
  /// overflow.
  ///
  /// Sub-48dp nudge targets are a deliberate degraded state *below* the
  /// reference viewport: at and above it the control field is >= 144dp and the
  /// spec's 48dp touch-target rule holds. Below the compact threshold the nudge
  /// zones disappear rather than shrink into unhittable slivers.
  static double nudgeExtentFor(double maxHeight) {
    if (maxHeight >= kDjPitchFaderFullNudgeHeight) return 48;
    if (maxHeight >= kDjPitchFaderMediumNudgeHeight) return 40;
    if (maxHeight >= kDjPitchFaderCompactNudgeHeight) return 24;
    return 0;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final nudge = nudgeExtentFor(constraints.maxHeight);
          return Column(
            children: [
              if (nudge > 0)
                _NudgeZone(
                  zoneKey: const ValueKey('dj_pitch_nudge_up'),
                  extent: nudge,
                  icon: Icons.keyboard_arrow_up,
                  onStart: () => onNudgeStart?.call(-2),
                  onEnd: () => onNudgeEnd?.call(),
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
              if (nudge > 0)
                _NudgeZone(
                  zoneKey: const ValueKey('dj_pitch_nudge_down'),
                  extent: nudge,
                  icon: Icons.keyboard_arrow_down,
                  onStart: () => onNudgeStart?.call(2),
                  onEnd: () => onNudgeEnd?.call(),
                ),
            ],
          );
        },
      );
}

class _NudgeZone extends StatelessWidget {
  const _NudgeZone({
    required this.zoneKey,
    required this.extent,
    required this.icon,
    required this.onStart,
    required this.onEnd,
  });

  final Key zoneKey;
  final double extent;
  final IconData icon;
  final VoidCallback onStart;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) => SizedBox(
        key: zoneKey,
        height: extent,
        width: 48,
        child: Listener(
          onPointerDown: (_) => onStart(),
          onPointerUp: (_) => onEnd(),
          onPointerCancel: (_) => onEnd(),
          child: Center(
            child: Icon(icon, size: extent < 40 ? 18 : 24),
          ),
        ),
      );
}
