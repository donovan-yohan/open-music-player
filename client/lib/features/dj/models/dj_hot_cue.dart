class DjHotCue {
  const DjHotCue({required this.slot, required this.positionMs});

  final int slot;
  final int positionMs;
}

class DjLoop {
  const DjLoop({
    required this.startMs,
    required this.endMs,
    required this.beats,
  });

  final int startMs;
  final int endMs;
  final int beats;

  int get durationMs => endMs - startMs;
}
