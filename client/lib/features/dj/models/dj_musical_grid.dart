/// Snaps to the closest analyzed marker. A missing grid preserves the request.
int snapDjPositionToNearestBeat(int positionMs, List<int> beatsMs) {
  if (beatsMs.isEmpty) return positionMs < 0 ? 0 : positionMs;
  var candidate = beatsMs.first;
  var bestDistance = (candidate - positionMs).abs();
  for (final beat in beatsMs.skip(1)) {
    final distance = (beat - positionMs).abs();
    if (distance < bestDistance) {
      candidate = beat;
      bestDistance = distance;
    }
  }
  return candidate;
}

/// Chooses an analyzed span of [beats] beginning at / after [positionMs].
DjBeatSpan? djLoopSpanAt({
  required int positionMs,
  required int beats,
  required List<int> beatsMs,
}) {
  if (beats <= 0 || beatsMs.length < 2) return null;
  var startIndex = beatsMs.indexWhere((marker) => marker >= positionMs);
  if (startIndex < 0) startIndex = beatsMs.length - 1;
  final endIndex = startIndex + beats;
  if (endIndex >= beatsMs.length) return null;
  return DjBeatSpan(beatsMs[startIndex], beatsMs[endIndex]);
}

class DjBeatSpan {
  const DjBeatSpan(this.startMs, this.endMs);
  final int startMs;
  final int endMs;
}
