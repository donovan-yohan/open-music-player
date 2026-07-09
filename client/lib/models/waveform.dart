import 'dart:math' as math;

import 'track.dart';
import 'track_analysis.dart';

class WaveformFrame {
  final double peak;
  final double rms;
  final double low;
  final double mid;
  final double high;

  const WaveformFrame({
    required this.peak,
    required this.rms,
    required this.low,
    required this.mid,
    required this.high,
  });

  WaveformFrame lerp(WaveformFrame other, double t) {
    final clampedT = t.clamp(0.0, 1.0).toDouble();
    return WaveformFrame(
      peak: _lerp(peak, other.peak, clampedT),
      rms: _lerp(rms, other.rms, clampedT),
      low: _lerp(low, other.low, clampedT),
      mid: _lerp(mid, other.mid, clampedT),
      high: _lerp(high, other.high, clampedT),
    );
  }
}

class WaveformTimeRange {
  final int startMs;
  final int endMs;

  const WaveformTimeRange({required this.startMs, required this.endMs});
}

class TimelineWaveformData {
  final List<WaveformFrame> frames;
  final int durationMs;
  final List<int> beatsMs;
  final List<int> downbeatsMs;
  final List<int> transientsMs;
  final List<WaveformTimeRange> silenceRanges;
  final bool analyzed;
  final String resolutionLabel;

  const TimelineWaveformData({
    required this.frames,
    required this.durationMs,
    this.beatsMs = const [],
    this.downbeatsMs = const [],
    this.transientsMs = const [],
    this.silenceRanges = const [],
    this.analyzed = false,
    this.resolutionLabel = 'synthetic',
  });

  List<double> get peaks =>
      frames.map((frame) => frame.peak).toList(growable: false);

  bool get hasMusicalMarkers =>
      beatsMs.isNotEmpty ||
      downbeatsMs.isNotEmpty ||
      transientsMs.isNotEmpty ||
      silenceRanges.isNotEmpty;

  TimelineWaveformData sliced({
    required int sourceStartMs,
    required int sourceEndMs,
    required int targetSampleCount,
  }) {
    final safeDuration = math.max(1, durationMs);
    final safeStart = sourceStartMs.clamp(0, safeDuration).toInt();
    final safeEnd = sourceEndMs.clamp(safeStart + 1, safeDuration).toInt();
    final startFraction = safeStart / safeDuration;
    final endFraction = safeEnd / safeDuration;
    final slicedFrames = _resampleFrames(
      frames,
      targetSampleCount,
      startFraction: startFraction,
      endFraction: endFraction,
    );
    final localDurationMs = safeEnd - safeStart;

    return TimelineWaveformData(
      frames: slicedFrames,
      durationMs: localDurationMs,
      beatsMs: _localMarkers(beatsMs, safeStart, safeEnd),
      downbeatsMs: _localMarkers(downbeatsMs, safeStart, safeEnd),
      transientsMs: _localMarkers(transientsMs, safeStart, safeEnd),
      silenceRanges: _localRanges(silenceRanges, safeStart, safeEnd),
      analyzed: analyzed,
      resolutionLabel: resolutionLabel,
    );
  }

  static TimelineWaveformData fromPeaks(
    List<double> peaks, {
    required int durationMs,
    int targetSampleCount = 96,
    List<int> beatsMs = const [],
    List<int> downbeatsMs = const [],
    bool analyzed = false,
    String resolutionLabel = 'peaks',
  }) {
    final safeDuration = math.max(1, durationMs);
    final normalizedPeaks = peaks.isEmpty
        ? mockWaveformPeaks('empty', barCount: targetSampleCount)
        : peaks;
    final resampledPeaks = _resampleDoubles(normalizedPeaks, targetSampleCount);
    final frames = <WaveformFrame>[];
    for (var i = 0; i < resampledPeaks.length; i++) {
      final peak = resampledPeaks[i].clamp(0.02, 1.0).toDouble();
      final phase = i / math.max(1, resampledPeaks.length - 1);
      final low = (0.42 + math.sin(phase * math.pi * 8) * 0.18).clamp(0.08, 1);
      final mid = (0.50 + math.cos(phase * math.pi * 5) * 0.22).clamp(0.08, 1);
      final high = (0.28 + math.sin(phase * math.pi * 17) * 0.20).clamp(
        0.04,
        1,
      );
      frames.add(
        WaveformFrame(
          peak: peak,
          rms: (peak * 0.68).clamp(0.01, 1.0).toDouble(),
          low: low.toDouble(),
          mid: mid.toDouble(),
          high: high.toDouble(),
        ),
      );
    }
    return TimelineWaveformData(
      frames: frames,
      durationMs: safeDuration,
      beatsMs: beatsMs,
      downbeatsMs: downbeatsMs,
      analyzed: analyzed,
      resolutionLabel: resolutionLabel,
    );
  }
}

TimelineWaveformData richWaveformForTrack(
  Track track, {
  int sampleCount = 128,
}) {
  final safeSampleCount = sampleCount.clamp(256, 131072).toInt();
  final summary = track.analysis?.summary;
  final waveform = summary?.waveform;
  final analyzedPeaks = waveform?.peaks ?? const <double>[];
  final fallbackPeaks = mockWaveformPeaks(
    _waveformCacheKey(track),
    barCount: safeSampleCount,
  );
  final peaks = analyzedPeaks.isNotEmpty ? analyzedPeaks : fallbackPeaks;
  final rms = waveform?.rms ?? const <double>[];
  final lowBands = waveform?.spectralBands['low']?.values ?? const <double>[];
  final midBands = waveform?.spectralBands['mid']?.values ?? const <double>[];
  final highBands = waveform?.spectralBands['high']?.values ?? const <double>[];
  final seed = _seedFromId(_waveformCacheKey(track));
  final frames = _buildSpectralFrames(
    peaks: _resampleDoubles(peaks, safeSampleCount),
    rms: rms.isEmpty ? const [] : _resampleDoubles(rms, safeSampleCount),
    lowBands: lowBands.isEmpty
        ? const []
        : _resampleDoubles(lowBands, safeSampleCount),
    midBands: midBands.isEmpty
        ? const []
        : _resampleDoubles(midBands, safeSampleCount),
    highBands: highBands.isEmpty
        ? const []
        : _resampleDoubles(highBands, safeSampleCount),
    seed: seed,
    durationMs: track.durationMs,
    beatsMs: summary?.beatGrid?.beatsMs ?? const [],
    downbeatsMs: summary?.downbeats?.positionsMs ?? const [],
    analyzed: analyzedPeaks.isNotEmpty,
  );

  return TimelineWaveformData(
    frames: frames,
    durationMs: math.max(1, track.durationMs),
    beatsMs: _analysisBeats(track),
    downbeatsMs: summary?.downbeats?.positionsMs ?? const [],
    transientsMs: summary?.transients?.strongestMs ?? const [],
    silenceRanges: _silenceRanges(summary?.silence),
    analyzed: analyzedPeaks.isNotEmpty,
    resolutionLabel:
        analyzedPeaks.isNotEmpty ? _analysisResolutionLabel(waveform) : 'live',
  );
}

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
/// Returns max(0, [barCount]) normalised heights in the range [0.06, 1.0].
List<double> mockWaveformPeaks(String trackId, {int barCount = 48}) {
  final count = math.max(0, barCount);
  final seed = _seedFromId(trackId);
  final rng = _Lcg(seed);

  final phaseA = (seed % 997) / 997 * math.pi * 2;
  final phaseB = (seed % 1009) / 1009 * math.pi * 2;
  final freqA = 0.6 + (seed % 5) * 0.35;
  final freqB = 1.3 + (seed % 7) * 0.4;

  // Musical body: two folded sines lifted off the floor.
  final peaks = List<double>.generate(count, (i) {
    final t = i / count;
    final a = math.sin(phaseA + t * math.pi * 2 * freqA);
    final b = math.sin(phaseB + t * math.pi * 2 * freqB);
    final body = (a * 0.6 + b * 0.4).abs();
    return (0.18 + body * 0.5).clamp(0.06, 1.0).toDouble();
  });

  // Too few bars to carve silence windows or seat a transient (idx-1..idx+1)
  // without inverting the clamp bounds below; return the plain body.
  if (count < 3) {
    return peaks;
  }

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
    final idx = (1 + (rng.next() * (barCount - 2)).floor()).clamp(
      1,
      barCount - 2,
    );
    peaks[idx - 1] = math.min(peaks[idx - 1], 0.12);
    peaks[idx] = 0.98;
    peaks[idx + 1] = math.min(peaks[idx + 1], 0.12);
  }

  return peaks;
}

List<WaveformFrame> _buildSpectralFrames({
  required List<double> peaks,
  required List<double> rms,
  required List<double> lowBands,
  required List<double> midBands,
  required List<double> highBands,
  required int seed,
  required int durationMs,
  required List<int> beatsMs,
  required List<int> downbeatsMs,
  required bool analyzed,
}) {
  final frames = <WaveformFrame>[];
  final spectralSeed = (seed % 7919) / 7919;
  final sectionShift = seed % _eqSectionProfiles.length;
  final hasAnalyzedBands =
      lowBands.isNotEmpty || midBands.isNotEmpty || highBands.isNotEmpty;
  for (var i = 0; i < peaks.length; i++) {
    final t = peaks.length <= 1 ? 0.0 : i / (peaks.length - 1);
    final sourceMs = (t * math.max(1, durationMs)).round();
    final peak = peaks[i].clamp(0.02, 1.0).toDouble();
    final rmsValue = (rms.isEmpty ? peak * 0.66 : rms[i]).clamp(0.01, 1.0);
    final beatEnergy = _markerEnergy(sourceMs, beatsMs, 70);
    final downbeatEnergy = _markerEnergy(sourceMs, downbeatsMs, 110);
    final profile = _eqProfileAt(t, sectionShift);
    final flutter = _fineSpectralFlutter(t, spectralSeed, i);
    final body = (peak * 0.72 + rmsValue * 0.28).clamp(0.0, 1.0);

    final low = hasAnalyzedBands
        ? _bandAt(lowBands, i, fallback: profile.low)
        : (profile.low * (0.72 + body * 0.38) +
                beatEnergy * 0.22 +
                downbeatEnergy * 0.16 +
                flutter.low)
            .clamp(0.02, 1.0);
    final mid = hasAnalyzedBands
        ? _bandAt(midBands, i, fallback: profile.mid)
        : (profile.mid * (0.70 + body * 0.42) +
                peak * 0.08 +
                downbeatEnergy * 0.12 +
                flutter.mid)
            .clamp(0.02, 1.0);
    final high = hasAnalyzedBands
        ? _bandAt(highBands, i, fallback: profile.high)
        : (profile.high * (0.68 + (1 - rmsValue) * 0.22) +
                beatEnergy * 0.08 +
                downbeatEnergy * 0.16 +
                flutter.high)
            .clamp(0.02, 1.0);

    final transientLift = math.max(beatEnergy * 0.10, downbeatEnergy * 0.18);
    final eq = WaveformFrame(
      peak: peak,
      rms: rmsValue.toDouble(),
      low: (low + transientLift * 0.6).clamp(0.02, 1.0).toDouble(),
      mid: (mid + transientLift * 0.7).clamp(0.02, 1.0).toDouble(),
      high: (high + transientLift).clamp(0.02, 1.0).toDouble(),
    );

    frames.add(eq);
  }
  if (analyzed || frames.isEmpty) return frames;

  // Synthetic fallback should still reveal zoom detail and cue-like structure.
  for (final beatMs in beatsMs) {
    if (beatMs < 0 || beatMs > durationMs) continue;
    final index = ((beatMs / math.max(1, durationMs)) * frames.length).floor();
    if (index < 0 || index >= frames.length) continue;
    final frame = frames[index];
    frames[index] = WaveformFrame(
      peak: math.max(frame.peak, 0.82),
      rms: math.max(frame.rms, 0.52),
      low: math.max(frame.low, 0.92),
      mid: frame.mid,
      high: frame.high,
    );
  }
  return frames;
}

double _bandAt(List<double> values, int index, {required double fallback}) {
  if (values.isEmpty || index < 0 || index >= values.length) {
    return fallback.clamp(0.02, 1.0).toDouble();
  }
  return values[index].clamp(0.02, 1.0).toDouble();
}

const _eqSectionProfiles = <WaveformFrame>[
  WaveformFrame(
      peak: 1, rms: 1, low: 0.92, mid: 0.58, high: 0.16), // red/orange bass
  WaveformFrame(
      peak: 1, rms: 1, low: 0.70, mid: 0.82, high: 0.18), // yellow bassline
  WaveformFrame(
      peak: 1, rms: 1, low: 0.16, mid: 0.92, high: 0.26), // green vocal/mid
  WaveformFrame(
      peak: 1, rms: 1, low: 0.12, mid: 0.80, high: 0.76), // cyan vocal/high
  WaveformFrame(
      peak: 1, rms: 1, low: 0.14, mid: 0.24, high: 0.92), // blue buildup
  WaveformFrame(
      peak: 1, rms: 1, low: 0.76, mid: 0.24, high: 0.86), // violet beat
  WaveformFrame(
      peak: 1, rms: 1, low: 0.94, mid: 0.72, high: 0.90), // pink/white chorus
  WaveformFrame(
      peak: 1, rms: 1, low: 0.22, mid: 0.86, high: 0.44), // bridge/vocal
];

WaveformFrame _eqProfileAt(double t, int shift) {
  final scaled =
      (t * _eqSectionProfiles.length + shift) % _eqSectionProfiles.length;
  final left = scaled.floor();
  final right = (left + 1) % _eqSectionProfiles.length;
  final blend = _smoothStep(scaled - left);
  return _eqSectionProfiles[left].lerp(_eqSectionProfiles[right], blend);
}

WaveformFrame _fineSpectralFlutter(double t, double seed, int index) {
  final micro = math.sin((t * 1400 + seed * 31 + index * 0.017) * math.pi);
  final fast = math.sin((t * 520 + seed * 17 + index * 0.013) * math.pi);
  final medium = math.cos((t * 137 + seed * 11 + index * 0.021) * math.pi);
  final slow = math.sin((t * 29 + seed * 7) * math.pi);
  return WaveformFrame(
    peak: 1,
    rms: 1,
    low: (fast * 0.034 + slow * 0.026 - micro * 0.014),
    mid: (medium * 0.046 - fast * 0.020 + micro * 0.018),
    high: (-slow * 0.032 + fast * 0.052 + micro * 0.030),
  );
}

double _smoothStep(double t) {
  final x = t.clamp(0.0, 1.0).toDouble();
  return x * x * (3 - 2 * x);
}

List<int> _analysisBeats(Track track) {
  final summary = track.analysis?.summary;
  final explicit = summary?.beatGrid?.beatsMs ?? const <int>[];
  if (explicit.isNotEmpty) return explicit;

  final bpm = summary?.bpm?.numericValue?.toDouble() ??
      summary?.beatGrid?.bpm ??
      _fallbackBpm(track);
  final intervalMs = (60000 / bpm).round().clamp(250, 2000);
  final beats = <int>[];
  for (var ms = 0; ms <= track.durationMs; ms += intervalMs) {
    beats.add(ms);
  }
  return beats;
}

double _fallbackBpm(Track track) {
  final seed = _seedFromId(_waveformCacheKey(track));
  return 92 + (seed % 54);
}

List<WaveformTimeRange> _silenceRanges(SilenceSummary? silence) {
  if (silence == null) return const [];
  return silence.ranges
      .where((range) => range.startMs != null && range.endMs != null)
      .map(
        (range) =>
            WaveformTimeRange(startMs: range.startMs!, endMs: range.endMs!),
      )
      .toList(growable: false);
}

String _analysisResolutionLabel(WaveformSummary? waveform) {
  final resolutions = waveform?.resolutions ?? const [];
  if (resolutions.isEmpty) return 'analysis';
  final detail = resolutions.reduce((best, candidate) {
    final bestSamples = best.sampleCount ?? 0;
    final candidateSamples = candidate.sampleCount ?? 0;
    return candidateSamples > bestSamples ? candidate : best;
  });
  return detail.name ?? 'analysis';
}

List<int> _localMarkers(List<int> markers, int startMs, int endMs) {
  return markers
      .where((marker) => marker >= startMs && marker <= endMs)
      .map((marker) => marker - startMs)
      .toList(growable: false);
}

List<WaveformTimeRange> _localRanges(
  List<WaveformTimeRange> ranges,
  int startMs,
  int endMs,
) {
  final local = <WaveformTimeRange>[];
  for (final range in ranges) {
    final start = math.max(range.startMs, startMs);
    final end = math.min(range.endMs, endMs);
    if (end <= start) continue;
    local.add(
      WaveformTimeRange(startMs: start - startMs, endMs: end - startMs),
    );
  }
  return local;
}

List<WaveformFrame> _resampleFrames(
  List<WaveformFrame> frames,
  int targetCount, {
  double startFraction = 0.0,
  double endFraction = 1.0,
}) {
  final safeTarget = targetCount.clamp(1, 131072).toInt();
  if (frames.isEmpty) return const [];
  if (frames.length == 1) {
    return List<WaveformFrame>.filled(safeTarget, frames.single);
  }

  final safeStart = startFraction.clamp(0.0, 1.0).toDouble();
  final safeEnd = endFraction.clamp(safeStart, 1.0).toDouble();
  final span = math.max(0.0001, safeEnd - safeStart);
  return List<WaveformFrame>.generate(safeTarget, (i) {
    final t = safeTarget == 1 ? 0.0 : i / (safeTarget - 1);
    final source = (safeStart + span * t) * (frames.length - 1);
    final left = source.floor().clamp(0, frames.length - 1);
    final right = source.ceil().clamp(0, frames.length - 1);
    if (left == right) return frames[left];
    return frames[left].lerp(frames[right], source - left);
  }, growable: false);
}

List<double> _resampleDoubles(List<double> values, int targetCount) {
  final safeTarget = targetCount.clamp(1, 131072).toInt();
  if (values.isEmpty) return List<double>.filled(safeTarget, 0.08);
  if (values.length == 1) {
    return List<double>.filled(
      safeTarget,
      values.single.clamp(0.0, 1.0).toDouble(),
    );
  }
  return List<double>.generate(safeTarget, (i) {
    final t = safeTarget == 1 ? 0.0 : i / (safeTarget - 1);
    final source = t * (values.length - 1);
    final left = source.floor().clamp(0, values.length - 1);
    final right = source.ceil().clamp(0, values.length - 1);
    final l = values[left].clamp(0.0, 1.0).toDouble();
    final r = values[right].clamp(0.0, 1.0).toDouble();
    return _lerp(l, r, source - left);
  }, growable: false);
}

double _markerEnergy(int sourceMs, List<int> markersMs, int radiusMs) {
  if (markersMs.isEmpty) return 0;
  var best = 0.0;
  for (final marker in markersMs) {
    final distance = (sourceMs - marker).abs();
    if (distance > radiusMs) continue;
    best = math.max(best, 1 - (distance / radiusMs));
  }
  return best;
}

String _waveformCacheKey(Track track) {
  return [
    track.queueItemId,
    track.playbackTrackId ?? track.id,
    track.title,
    track.artist ?? '',
  ].join('|');
}

/// FNV-1a-ish stable hash of the id, kept positive and non-zero.
int _seedFromId(String id) {
  var h = 2166136261;
  for (var i = 0; i < id.length; i++) {
    h = ((h ^ id.codeUnitAt(i)) * 16777619) & 0x7fffffff;
  }
  return h == 0 ? 1 : h;
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Tiny deterministic LCG so fixtures vary per track without `Random`.
class _Lcg {
  int _state;
  _Lcg(this._state);

  double next() {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state / 0x7fffffff;
  }
}
