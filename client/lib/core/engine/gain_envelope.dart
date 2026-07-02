import 'dart:math' as math;

/// Shape of a per-clip fade ramp.
enum FadeCurve { linear, equalPower }

/// Trapezoid gain envelope for one clip.
///
/// [equalPower] is the Phase 0 default so the midpoint of a two-track
/// crossfade does not dip in perceived loudness. [gainAt] always clamps to
/// [0.0, 1.0] before callers hand the value to an audio player.
class GainEnvelope {
  final double baseGainDb;
  final int fadeInMs;
  final int fadeOutMs;
  final FadeCurve curve;

  const GainEnvelope({
    this.baseGainDb = 0,
    this.fadeInMs = 0,
    this.fadeOutMs = 0,
    this.curve = FadeCurve.equalPower,
  });

  const GainEnvelope.flat() : this();

  double gainAt(int localOffsetMs, int clipDurationMs) {
    if (clipDurationMs <= 0 ||
        localOffsetMs < 0 ||
        localOffsetMs >= clipDurationMs) {
      return 0;
    }

    final baseGain = math.pow(10, baseGainDb / 20).toDouble().clamp(0.0, 1.0);
    final fades = _effectiveFades(clipDurationMs);
    var shaped = 1.0;

    if (fades.fadeInMs > 0 && localOffsetMs < fades.fadeInMs) {
      shaped = _shape(localOffsetMs / fades.fadeInMs);
    }

    final fadeOutStart = clipDurationMs - fades.fadeOutMs;
    if (fades.fadeOutMs > 0 && localOffsetMs >= fadeOutStart) {
      final remaining = (clipDurationMs - localOffsetMs).clamp(
        0,
        fades.fadeOutMs,
      );
      shaped = math.min(shaped, _shape(remaining / fades.fadeOutMs));
    }

    return (baseGain * shaped).clamp(0.0, 1.0);
  }

  GainEnvelope withBaseGainDb(double db) => GainEnvelope(
    baseGainDb: db,
    fadeInMs: fadeInMs,
    fadeOutMs: fadeOutMs,
    curve: curve,
  );

  GainEnvelope withFadeInMs(int ms) => GainEnvelope(
    baseGainDb: baseGainDb,
    fadeInMs: math.max(0, ms),
    fadeOutMs: fadeOutMs,
    curve: curve,
  );

  GainEnvelope withFadeOutMs(int ms) => GainEnvelope(
    baseGainDb: baseGainDb,
    fadeInMs: fadeInMs,
    fadeOutMs: math.max(0, ms),
    curve: curve,
  );

  GainEnvelope withCurve(FadeCurve curve) => GainEnvelope(
    baseGainDb: baseGainDb,
    fadeInMs: fadeInMs,
    fadeOutMs: fadeOutMs,
    curve: curve,
  );

  _EffectiveFades _effectiveFades(int clipDurationMs) {
    final requestedIn = math.max(0, fadeInMs);
    final requestedOut = math.max(0, fadeOutMs);
    final total = requestedIn + requestedOut;
    if (total <= clipDurationMs || total == 0) {
      return _EffectiveFades(requestedIn, requestedOut);
    }

    return _EffectiveFades(
      (requestedIn * clipDurationMs / total).round(),
      (requestedOut * clipDurationMs / total).round(),
    );
  }

  double _shape(double progress) {
    final t = progress.clamp(0.0, 1.0);
    switch (curve) {
      case FadeCurve.linear:
        return t;
      case FadeCurve.equalPower:
        return math.sin(t * math.pi / 2);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GainEnvelope &&
      other.baseGainDb == baseGainDb &&
      other.fadeInMs == fadeInMs &&
      other.fadeOutMs == fadeOutMs &&
      other.curve == curve;

  @override
  int get hashCode => Object.hash(baseGainDb, fadeInMs, fadeOutMs, curve);
}

class _EffectiveFades {
  final int fadeInMs;
  final int fadeOutMs;

  const _EffectiveFades(this.fadeInMs, this.fadeOutMs);
}
