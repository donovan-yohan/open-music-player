import 'dart:math' as math;

/// Deterministic mock waveform peaks for a track.
///
/// Real peak extraction (decoding audio / backend persistence) is out of scope
/// for the web slice, so we synthesise a stable set of bar heights from the
/// track id. Same id always yields the same shape — no randomness, safe in
/// tests and across rebuilds.
///
/// Unlike a plain sine, this fixture deliberately carves near-silence passages
/// and injects isolated transient spikes (kick / snare style hits whose
/// neighbours stay quiet). That structure is the point of the stacked-waveform
/// prototype: a uniform averaged strip would erase the transients and read as a
/// flat block, so the mock data makes that failure visible.
///
/// Returns [barCount] normalised heights in the range [0.06, 1.0].
List<double> mockWaveformPeaks(String trackId, {int barCount = 48}) {
  final seed = _seedFromId(trackId);
  final rng = _Lcg(seed);

  final phaseA = (seed % 997) / 997 * math.pi * 2;
  final phaseB = (seed % 1009) / 1009 * math.pi * 2;
  final freqA = 0.6 + (seed % 5) * 0.35;
  final freqB = 1.3 + (seed % 7) * 0.4;

  // Musical body: two folded sines lifted off the floor.
  final peaks = List<double>.generate(barCount, (i) {
    final t = i / barCount;
    final a = math.sin(phaseA + t * math.pi * 2 * freqA);
    final b = math.sin(phaseB + t * math.pi * 2 * freqB);
    final body = (a * 0.6 + b * 0.4).abs();
    return (0.18 + body * 0.5).clamp(0.06, 1.0).toDouble();
  });

  // Carve 1-2 near-silence windows (breakdowns / quiet passages).
  final silenceWindows = 1 + (seed % 2);
  for (var s = 0; s < silenceWindows; s++) {
    final start = (rng.next() * (barCount - 6)).floor().clamp(0, barCount - 1);
    final len = 3 + (rng.next() * 4).floor();
    for (var i = start; i < start + len && i < barCount; i++) {
      peaks[i] = 0.06;
    }
  }

  // Inject isolated transient spikes whose neighbours are forced quiet, so an
  // averaging mip that smears them is obviously wrong.
  final spikes = 3 + (seed % 3);
  for (var s = 0; s < spikes; s++) {
    final idx =
        (1 + (rng.next() * (barCount - 2)).floor()).clamp(1, barCount - 2);
    peaks[idx - 1] = math.min(peaks[idx - 1], 0.12);
    peaks[idx] = 0.98;
    peaks[idx + 1] = math.min(peaks[idx + 1], 0.12);
  }

  return peaks;
}

/// FNV-1a-ish stable hash of the id, kept positive and non-zero.
int _seedFromId(String id) {
  var h = 2166136261;
  for (var i = 0; i < id.length; i++) {
    h = ((h ^ id.codeUnitAt(i)) * 16777619) & 0x7fffffff;
  }
  return h == 0 ? 1 : h;
}

/// Tiny deterministic LCG so fixtures vary per track without `Random`.
class _Lcg {
  int _state;
  _Lcg(this._state);

  double next() {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state / 0x7fffffff;
  }
}
