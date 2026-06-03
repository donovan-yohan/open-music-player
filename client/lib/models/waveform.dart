import 'dart:math' as math;

/// Deterministic mock waveform peaks for a track.
///
/// Real peak extraction (decoding audio / backend persistence) is out of scope
/// for the web slice, so we synthesise a stable set of bar heights from the
/// track id. Same id always yields the same shape — no randomness, safe in
/// tests and across rebuilds.
///
/// Returns [barCount] normalised heights in the range [0.08, 1.0].
List<double> mockWaveformPeaks(String trackId, {int barCount = 48}) {
  // Seed two independent waves from the id so different tracks look distinct.
  var seedA = 0;
  var seedB = 0;
  for (var i = 0; i < trackId.length; i++) {
    final c = trackId.codeUnitAt(i);
    seedA = (seedA + c * (i + 1)) % 997;
    seedB = (seedB + c * c) % 1009;
  }
  final phaseA = seedA / 997 * math.pi * 2;
  final phaseB = seedB / 1009 * math.pi * 2;
  final freqA = 0.6 + (seedA % 5) * 0.35;
  final freqB = 1.3 + (seedB % 7) * 0.4;

  return List<double>.generate(barCount, (i) {
    final t = i / barCount;
    final a = math.sin(phaseA + t * math.pi * 2 * freqA);
    final b = math.sin(phaseB + t * math.pi * 2 * freqB);
    // Combine, fold to [0,1], then lift off the floor so bars stay visible.
    final mixed = (a * 0.6 + b * 0.4);
    final norm = 0.08 + (mixed.abs()) * 0.92;
    return norm.clamp(0.08, 1.0).toDouble();
  });
}
