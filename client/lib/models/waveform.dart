import 'dart:math' as math;

import 'track.dart';
import 'track_analysis.dart';

class WaveformFrame {
  final double peak;
  final double? minPeak;
  final double? maxPeak;
  final double rms;
  final double low;
  final double mid;
  final double high;
  final Map<String, double> channels;

  const WaveformFrame({
    required this.peak,
    this.minPeak,
    this.maxPeak,
    required this.rms,
    required this.low,
    required this.mid,
    required this.high,
    this.channels = const {},
  });

  double get resolvedMinPeak => minPeak ?? -peak;
  double get resolvedMaxPeak => maxPeak ?? peak;

  Map<String, double> get resolvedChannels => channels.isNotEmpty
      ? channels
      : {
          if (low > 0) 'low': low,
          if (mid > 0) 'mid': mid,
          if (high > 0) 'high': high,
        };
}

class WaveformTimeRange {
  final int startMs;
  final int endMs;

  const WaveformTimeRange({required this.startMs, required this.endMs});
}

class TimelineWaveformData {
  static const double maxUsefulFrameSpacingPx = 5;
  static const int _estimatedFrameBytes = 48;
  static const int _estimatedMarkerBytes = 4;

  final List<WaveformFrame> frames;
  final int durationMs;
  final List<int> beatsMs;
  final List<int> downbeatsMs;
  final List<int> transientsMs;
  final List<WaveformTimeRange> silenceRanges;
  final bool analyzed;
  final String resolutionLabel;
  final int sourceStartMs;
  final int? _coveredSourceFrameCount;

  const TimelineWaveformData({
    required this.frames,
    required this.durationMs,
    this.beatsMs = const [],
    this.downbeatsMs = const [],
    this.transientsMs = const [],
    this.silenceRanges = const [],
    this.analyzed = false,
    this.resolutionLabel = 'pending',
    this.sourceStartMs = 0,
    int? coveredSourceFrameCount,
  }) : _coveredSourceFrameCount = coveredSourceFrameCount;

  int get coveredSourceFrameCount => _coveredSourceFrameCount ?? frames.length;

  List<double> get peaks =>
      frames.map((frame) => frame.peak).toList(growable: false);

  bool get hasMusicalMarkers =>
      beatsMs.isNotEmpty ||
      downbeatsMs.isNotEmpty ||
      transientsMs.isNotEmpty ||
      silenceRanges.isNotEmpty;

  int get estimatedByteSize =>
      frames.length * _estimatedFrameBytes +
      (beatsMs.length + downbeatsMs.length + transientsMs.length) *
          _estimatedMarkerBytes +
      silenceRanges.length * _estimatedMarkerBytes * 2 +
      256;

  TimelineWaveformData sliced({
    required int sourceStartMs,
    required int sourceEndMs,
    required int targetSampleCount,
  }) {
    final safeDuration = math.max(1, durationMs);
    final localRequestedStart = sourceStartMs - this.sourceStartMs;
    final localRequestedEnd = sourceEndMs - this.sourceStartMs;
    final safeStart =
        localRequestedStart.clamp(0, math.max(0, safeDuration - 1)).toInt();
    final safeEnd =
        localRequestedEnd.clamp(safeStart + 1, safeDuration).toInt();
    final startFraction = safeStart / safeDuration;
    final endFraction = safeEnd / safeDuration;
    final selectedFrames = _coveredFrames(
      frames,
      startFraction: startFraction,
      endFraction: endFraction,
    );
    final safeTarget = targetSampleCount.clamp(1, 131072).toInt();
    final slicedFrames = selectedFrames.length <= safeTarget
        ? List<WaveformFrame>.unmodifiable(selectedFrames)
        : _aggregateFramesPeakPreserving(selectedFrames, safeTarget);
    final localDurationMs = safeEnd - safeStart;
    final absoluteStartMs = this.sourceStartMs + safeStart;
    final absoluteEndMs = this.sourceStartMs + safeEnd;
    final coveredStart = (startFraction * coveredSourceFrameCount).floor();
    final coveredEnd = (endFraction * coveredSourceFrameCount).ceil();

    return TimelineWaveformData(
      frames: slicedFrames,
      durationMs: localDurationMs,
      beatsMs: _localMarkersWithGuards(
        beatsMs,
        currentSourceStartMs: this.sourceStartMs,
        sliceStartMs: absoluteStartMs,
        sliceEndMs: absoluteEndMs,
      ),
      downbeatsMs: _localMarkersWithGuards(
        downbeatsMs,
        currentSourceStartMs: this.sourceStartMs,
        sliceStartMs: absoluteStartMs,
        sliceEndMs: absoluteEndMs,
      ),
      transientsMs: _localMarkersWithGuards(
        transientsMs,
        currentSourceStartMs: this.sourceStartMs,
        sliceStartMs: absoluteStartMs,
        sliceEndMs: absoluteEndMs,
      ),
      silenceRanges: _localRanges(silenceRanges, safeStart, safeEnd),
      analyzed: analyzed,
      resolutionLabel: resolutionLabel,
      sourceStartMs: absoluteStartMs,
      coveredSourceFrameCount: math.max(0, coveredEnd - coveredStart),
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
    if (peaks.isEmpty) {
      return TimelineWaveformData(
        frames: const [],
        durationMs: safeDuration,
        beatsMs: beatsMs,
        downbeatsMs: downbeatsMs,
        analyzed: analyzed,
        resolutionLabel: analyzed ? resolutionLabel : 'pending',
      );
    }
    final safeTarget = targetSampleCount.clamp(1, 131072).toInt();
    final resampledPeaks = _aggregateDoublesPeakPreserving(
      peaks,
      math.min(peaks.length, safeTarget),
    );
    final frames = <WaveformFrame>[];
    for (var i = 0; i < resampledPeaks.length; i++) {
      final peak = resampledPeaks[i].clamp(0.0, 1.0).toDouble();
      frames.add(
        WaveformFrame(
          peak: peak,
          minPeak: -peak,
          maxPeak: peak,
          rms: 0,
          low: 0,
          mid: 0,
          high: 0,
        ),
      );
    }
    return TimelineWaveformData(
      frames: frames,
      durationMs: safeDuration,
      beatsMs: beatsMs,
      downbeatsMs: downbeatsMs,
      analyzed: analyzed,
      resolutionLabel: analyzed ? resolutionLabel : 'peaks',
    );
  }
}

TimelineWaveformData richWaveformForTrack(
  QueueTrack track, {
  int sampleCount = 128,
}) {
  final summary = track.analysis?.summary;
  final waveform = summary?.waveform;
  final tier = _selectWaveformTier(waveform, sampleCount);
  final analyzedPeaks = tier?.peaks ?? const <double>[];
  final availableAnalyzedSamples = tier?.sourceCount;
  final safeSampleCount = availableAnalyzedSamples == null
      ? sampleCount.clamp(256, 131072).toInt()
      : math.min(
          sampleCount.clamp(1, 131072).toInt(),
          availableAnalyzedSamples,
        );
  final frames = tier != null && tier.sourceCount > 0
      ? _buildAnalyzedFrames(
          peaks: analyzedPeaks,
          minPeaks: tier.minPeaks,
          maxPeaks: tier.maxPeaks,
          rms: tier.rms,
          channels: tier.channels,
          targetCount: safeSampleCount,
        )
      : const <WaveformFrame>[];
  final analyzed = frames.isNotEmpty;

  return TimelineWaveformData(
    frames: frames,
    durationMs: math.max(1, track.durationMs),
    beatsMs: _analysisBeats(track),
    downbeatsMs: summary?.downbeats?.positionsMs ?? const [],
    transientsMs: summary?.transients?.strongestMs ?? const [],
    silenceRanges: _silenceRanges(summary?.silence),
    analyzed: analyzed,
    resolutionLabel: analyzed ? tier?.name ?? 'analysis' : 'pending',
    coveredSourceFrameCount: analyzed ? tier!.sourceCount : 0,
  );
}

/// The timeline may decimate these frames for display, but must never invent
/// higher-detail analyzed frames by interpolation.
int? waveformAvailableSampleCountForTrack(QueueTrack track) {
  final waveform = track.analysis?.summary?.waveform;
  final available = _availableWaveformSampleCount(waveform);
  return available > 0 ? available : null;
}

int? waveformCoveredSampleCountForTrack(
  QueueTrack track, {
  required int sourceStartMs,
  required int sourceEndMs,
}) {
  final available = waveformAvailableSampleCountForTrack(track);
  if (available == null || available <= 0 || track.durationMs <= 0) return null;
  final start = sourceStartMs.clamp(0, track.durationMs);
  final end = sourceEndMs.clamp(start, track.durationMs);
  final firstBin = (start * available / track.durationMs).floor();
  final lastBin = (end * available / track.durationMs).ceil();
  return math.max(0, lastBin - firstBin);
}

double waveformMaxUsefulPixelsPerSecond({
  required int realFrameCount,
  required int timelineDurationMs,
}) {
  if (realFrameCount <= 0 || timelineDurationMs <= 0) return 0;
  return realFrameCount *
      TimelineWaveformData.maxUsefulFrameSpacingPx /
      (timelineDurationMs / 1000);
}

class _WaveformTierData {
  final String name;
  final List<double> peaks;
  final List<double> minPeaks;
  final List<double> maxPeaks;
  final List<double> rms;
  final Map<String, SpectralBandSummary> channels;

  const _WaveformTierData({
    required this.name,
    required this.peaks,
    required this.minPeaks,
    required this.maxPeaks,
    required this.rms,
    required this.channels,
  });

  int get sourceCount => [
        peaks.length,
        minPeaks.length,
        maxPeaks.length,
        rms.length,
        ...channels.values.map((channel) => channel.values.length),
      ].fold<int>(0, math.max);
}

_WaveformTierData? _selectWaveformTier(
  WaveformSummary? waveform,
  int targetSampleCount,
) {
  if (waveform == null) return null;
  final tiers = <_WaveformTierData>[
    for (final resolution in waveform.resolutions)
      _WaveformTierData(
        name: resolution.name ?? 'analysis',
        peaks: resolution.peaks,
        minPeaks: resolution.minPeaks,
        maxPeaks: resolution.maxPeaks,
        rms: resolution.rms,
        channels: resolution.channels.isNotEmpty
            ? resolution.channels
            : resolution.spectralBands,
      ),
  ]..removeWhere((tier) => tier.sourceCount <= 0);
  if (tiers.isEmpty) {
    final channels = waveform.channels?.values;
    final fallback = _WaveformTierData(
      name: 'analysis',
      peaks: waveform.peaks,
      minPeaks: waveform.minPeaks,
      maxPeaks: waveform.maxPeaks,
      rms: waveform.rms,
      channels: channels != null && channels.isNotEmpty
          ? channels
          : waveform.spectralBands,
    );
    return fallback.sourceCount > 0 ? fallback : null;
  }
  tiers.sort((a, b) => a.sourceCount.compareTo(b.sourceCount));
  final target = targetSampleCount.clamp(1, 131072);
  return tiers.firstWhere(
    (tier) => tier.sourceCount >= target,
    orElse: () => tiers.last,
  );
}

int _availableWaveformSampleCount(WaveformSummary? waveform) {
  if (waveform == null) return 0;
  var available = 0;
  for (final resolution in waveform.resolutions) {
    available = math.max(
      available,
      [
        resolution.peaks.length,
        resolution.minPeaks.length,
        resolution.maxPeaks.length,
      ].fold<int>(0, math.max),
    );
  }
  return [
    available,
    waveform.peaks.length,
    waveform.minPeaks.length,
    waveform.maxPeaks.length,
  ].fold<int>(0, math.max);
}

List<WaveformFrame> _buildAnalyzedFrames({
  required List<double> peaks,
  required List<double> minPeaks,
  required List<double> maxPeaks,
  required List<double> rms,
  required Map<String, SpectralBandSummary> channels,
  required int targetCount,
}) {
  final sourceCount = [
    peaks.length,
    minPeaks.length,
    maxPeaks.length,
    ...channels.values.map((channel) => channel.values.length),
  ].fold<int>(0, math.max);
  if (sourceCount <= 0 || targetCount <= 0) return const [];
  final safeTarget = math.min(sourceCount, targetCount);
  return List<WaveformFrame>.generate(safeTarget, (index) {
    final start = (index * sourceCount / safeTarget).floor();
    final end = math.max(
      start + 1,
      ((index + 1) * sourceCount / safeTarget).ceil(),
    );
    final positivePeak = _maxProportional(
      maxPeaks.isNotEmpty ? maxPeaks : peaks,
      sourceStart: start,
      sourceEnd: end,
      sourceCount: sourceCount,
      fallback: 0,
    );
    final negativePeak = minPeaks.isNotEmpty
        ? _minProportional(
            minPeaks,
            sourceStart: start,
            sourceEnd: end,
            sourceCount: sourceCount,
            fallback: 0,
          )
        : -positivePeak;
    final peak = math.max(positivePeak.abs(), negativePeak.abs());
    final frameChannels = <String, double>{
      for (final entry in channels.entries)
        if (entry.value.values.isNotEmpty)
          entry.key: _maxProportional(
            entry.value.values,
            sourceStart: start,
            sourceEnd: end,
            sourceCount: sourceCount,
            fallback: 0,
          ),
    };
    return WaveformFrame(
      peak: peak,
      minPeak: negativePeak.clamp(-1.0, 0.0).toDouble(),
      maxPeak: positivePeak.clamp(0.0, 1.0).toDouble(),
      rms: _maxProportional(
        rms,
        sourceStart: start,
        sourceEnd: end,
        sourceCount: sourceCount,
        fallback: 0,
      ),
      low: frameChannels['low'] ?? 0,
      mid: frameChannels['mid'] ?? 0,
      high: frameChannels['high'] ?? 0,
      channels: Map<String, double>.unmodifiable(frameChannels),
    );
  }, growable: false);
}

double _maxProportional(
  List<double> values, {
  required int sourceStart,
  required int sourceEnd,
  required int sourceCount,
  required double fallback,
}) {
  if (values.isEmpty || sourceCount <= 0) {
    return fallback.clamp(0.0, 1.0).toDouble();
  }
  final start = (sourceStart * values.length / sourceCount)
      .floor()
      .clamp(0, values.length - 1);
  final end = math
      .max(start + 1, (sourceEnd * values.length / sourceCount).ceil())
      .clamp(start + 1, values.length);
  return _maxNormalized(values, start, end, fallback: fallback);
}

double _minProportional(
  List<double> values, {
  required int sourceStart,
  required int sourceEnd,
  required int sourceCount,
  required double fallback,
}) {
  if (values.isEmpty || sourceCount <= 0) {
    return fallback.clamp(-1.0, 0.0).toDouble();
  }
  final start = (sourceStart * values.length / sourceCount)
      .floor()
      .clamp(0, values.length - 1);
  final end = math
      .max(start + 1, (sourceEnd * values.length / sourceCount).ceil())
      .clamp(start + 1, values.length);
  var minimum = fallback;
  for (var index = start; index < math.min(end, values.length); index++) {
    minimum = math.min(minimum, values[index]);
  }
  return minimum.clamp(-1.0, 0.0).toDouble();
}

double _maxNormalized(
  List<double> values,
  int start,
  int end, {
  required double fallback,
}) {
  if (values.isEmpty || start >= values.length || end <= start) {
    return fallback.clamp(0.0, 1.0).toDouble();
  }
  var maximum = fallback;
  for (var index = start; index < math.min(end, values.length); index++) {
    maximum = math.max(maximum, values[index]);
  }
  return maximum.clamp(0.0, 1.0).toDouble();
}

List<int> _analysisBeats(QueueTrack track) {
  return track.analysis?.summary?.beatGrid?.beatsMs ?? const <int>[];
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

List<int> _localMarkersWithGuards(
  List<int> markers, {
  required int currentSourceStartMs,
  required int sliceStartMs,
  required int sliceEndMs,
}) {
  if (markers.isEmpty) return const [];
  final absolute = markers
      .map((marker) => marker + currentSourceStartMs)
      .toSet()
      .toList()
    ..sort();
  var first = 0;
  while (first < absolute.length && absolute[first] < sliceStartMs) {
    first++;
  }
  var end = first;
  while (end < absolute.length && absolute[end] <= sliceEndMs) {
    end++;
  }
  final guardedStart = math.max(0, first - 1);
  final guardedEnd = math.min(absolute.length, end + 1);
  return [
    for (var index = guardedStart; index < guardedEnd; index++)
      absolute[index] - sliceStartMs,
  ];
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

List<WaveformFrame> _coveredFrames(
  List<WaveformFrame> frames, {
  required double startFraction,
  required double endFraction,
}) {
  if (frames.isEmpty) return const [];
  final start = (startFraction.clamp(0.0, 1.0) * frames.length)
      .floor()
      .clamp(0, frames.length - 1);
  final end = (endFraction.clamp(0.0, 1.0) * frames.length)
      .ceil()
      .clamp(start + 1, frames.length);
  return frames.sublist(start, end);
}

List<WaveformFrame> _aggregateFramesPeakPreserving(
  List<WaveformFrame> frames,
  int targetCount,
) {
  if (frames.isEmpty || targetCount <= 0) return const [];
  final safeTarget = math.min(frames.length, targetCount);
  return List<WaveformFrame>.generate(safeTarget, (index) {
    final start = (index * frames.length / safeTarget).floor();
    final end = math.max(
      start + 1,
      ((index + 1) * frames.length / safeTarget).ceil(),
    );
    var peak = 0.0;
    var minPeak = 0.0;
    var maxPeak = 0.0;
    var rms = 0.0;
    final channels = <String, double>{};
    for (var source = start; source < math.min(end, frames.length); source++) {
      final frame = frames[source];
      peak = math.max(peak, frame.peak);
      minPeak = math.min(minPeak, frame.resolvedMinPeak);
      maxPeak = math.max(maxPeak, frame.resolvedMaxPeak);
      rms = math.max(rms, frame.rms);
      for (final entry in frame.resolvedChannels.entries) {
        channels[entry.key] = math.max(channels[entry.key] ?? 0, entry.value);
      }
    }
    return WaveformFrame(
      peak: peak,
      minPeak: minPeak,
      maxPeak: maxPeak,
      rms: rms,
      low: channels['low'] ?? 0,
      mid: channels['mid'] ?? 0,
      high: channels['high'] ?? 0,
      channels: Map<String, double>.unmodifiable(channels),
    );
  }, growable: false);
}

List<double> _aggregateDoublesPeakPreserving(
  List<double> values,
  int targetCount,
) {
  if (values.isEmpty || targetCount <= 0) return const [];
  final safeTarget = math.min(values.length, targetCount);
  return List<double>.generate(safeTarget, (index) {
    final start = (index * values.length / safeTarget).floor();
    final end = math.max(
      start + 1,
      ((index + 1) * values.length / safeTarget).ceil(),
    );
    var peak = 0.0;
    for (var source = start; source < math.min(end, values.length); source++) {
      peak = math.max(peak, values[source]);
    }
    return peak.clamp(0.0, 1.0).toDouble();
  }, growable: false);
}
