const transientSpikePeaks = <double>[
  0.08,
  0.10,
  0.98,
  0.09,
  0.42,
  0.55,
  0.31,
  0.07,
];

const alternateTransientSpikePeaks = <double>[
  0.14,
  0.72,
  0.11,
  0.06,
  0.12,
  0.96,
  0.08,
  0.38,
];

List<double> waveformPeaksFixture(
  String fixtureName, {
  int barCount = 48,
}) {
  if (barCount <= 0) return const [];
  final source =
      fixtureName == 't2' ? alternateTransientSpikePeaks : transientSpikePeaks;
  return List<double>.generate(
    barCount,
    (index) => source[index % source.length],
    growable: false,
  );
}
