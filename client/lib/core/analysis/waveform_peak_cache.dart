import 'dart:collection';

import '../../models/track.dart';
import '../../models/waveform.dart';

/// LRU cache of rendered timeline waveforms, keyed by track revision and the
/// sample bucket the caller asked for.
///
/// Extracted from `QueueProvider` in step 5 of the ADR 0012 reconciliation
/// (`docs/adr/0012-import-queue-is-not-the-playback-queue.md`). Behavior is
/// unchanged: same buckets, same source-shared keys, same frame and byte
/// budgets. Import-queue code owns when a prune is due; this class owns the
/// budget and the key derivation.
class WaveformPeakCache {
  static const int maxCachedFrames = 196608;
  static const int maxCachedBytes = 12 * 1024 * 1024;

  final LinkedHashMap<_TimelineWaveformCacheKey, _CachedTimelineWaveform>
      _waveforms = LinkedHashMap();

  final int _maxFrames;
  final int _maxBytes;

  WaveformPeakCache({
    int maxFrames = maxCachedFrames,
    int maxBytes = maxCachedBytes,
  })  : _maxFrames = maxFrames,
        _maxBytes = maxBytes;

  int get entryCount => _waveforms.length;

  int get frameCount => _waveforms.values.fold<int>(
        0,
        (total, entry) => total + entry.waveform.frames.length,
      );

  int get byteCount => _waveforms.values.fold<int>(
        0,
        (total, entry) => total + entry.estimatedByteSize,
      );

  /// Deterministic mock waveform peaks for a track until backend peak data is
  /// available.
  List<double> peaksFor(QueueTrack track) {
    final entry = _entryFor(track, 64);
    final peaks = entry.peaks;
    trim();
    return peaks;
  }

  TimelineWaveformData waveformFor(QueueTrack track, int targetSampleCount) =>
      _entryFor(track, targetSampleCount).waveform;

  _CachedTimelineWaveform _entryFor(QueueTrack track, int targetSampleCount) {
    final bucket = _waveformSampleBucket(targetSampleCount);
    final cacheKey = _TimelineWaveformCacheKey(
      trackRevision: _trackWaveformKey(track),
      bucket: bucket,
    );
    final cached = _waveforms.remove(cacheKey);
    if (cached != null) {
      _waveforms[cacheKey] = cached;
      return cached;
    }
    final waveform = richWaveformForTrack(track, sampleCount: bucket);
    final entry = _CachedTimelineWaveform(waveform);
    _waveforms[cacheKey] = entry;
    trim();
    return entry;
  }

  /// Drops every cached waveform derived from [trackId]'s analysis.
  ///
  /// The analysis store calls this whenever a track's hydrated payload changes,
  /// so a rebuilt timeline cannot paint frames from the previous revision.
  void invalidateTrack(String trackId) {
    _waveforms.removeWhere(
      (cacheKey, _) =>
          cacheKey.trackRevision.startsWith('track:$trackId|') ||
          cacheKey.trackRevision.contains('|track:$trackId|'),
    );
  }

  /// Drops waveforms whose source is no longer in [tracks].
  void pruneForQueue(Iterable<QueueTrack> tracks) {
    final retained = tracks.toList(growable: false);
    if (retained.isEmpty) {
      _waveforms.clear();
      return;
    }
    final waveformSourceKeys = retained.map(_trackWaveformSourceKey).toSet();
    _waveforms.removeWhere(
      (cacheKey, _) => waveformSourceKeys.every(
        (sourceKey) => !cacheKey.trackRevision.startsWith('$sourceKey|'),
      ),
    );
  }

  void trim() {
    var retainedFrames = frameCount;
    var retainedBytes = byteCount;
    while (_waveforms.isNotEmpty &&
        (retainedFrames > _maxFrames || retainedBytes > _maxBytes)) {
      final removed = _waveforms.remove(_waveforms.keys.first)!;
      retainedFrames -= removed.waveform.frames.length;
      retainedBytes -= removed.estimatedByteSize;
    }
  }

  String _trackWaveformKey(QueueTrack track) {
    final analysis = track.analysis;
    final waveform = analysis?.summary?.waveform;
    final peaks = waveform?.peaks ?? const <double>[];
    final analysisKey = analysis == null
        ? 'analysis:none'
        : [
            'analysis:${analysis.status.name}',
            'updated:${analysis.updatedAt?.microsecondsSinceEpoch ?? 'none'}',
            'bpm:${analysis.summary?.bpm?.numericValue ?? 'none'}',
            'beats:${analysis.summary?.beatGrid?.beatsMs.length ?? 0}',
            'downbeats:${analysis.summary?.downbeats?.positionsMs.length ?? 0}',
            'key:${analysis.summary?.key?.textValue ?? ''}',
            'camelot:${analysis.summary?.camelot?.textValue ?? ''}',
            'overrides:${analysis.overrides?.toJson()}',
            'waveform:${peaks.length}',
            'first:${peaks.isEmpty ? 'none' : peaks.first}',
            'last:${peaks.isEmpty ? 'none' : peaks.last}',
            'bands:${analysis.summary?.waveform?.spectralBands.length ?? 0}',
          ].join('|');
    return '${_trackWaveformSourceKey(track)}|$analysisKey';
  }

  String _trackWaveformSourceKey(QueueTrack track) {
    final analysisTrackId = _analysisTrackId(track);
    if (analysisTrackId != null) return 'track:$analysisTrackId';
    final playbackTrackId = track.playbackTrackId;
    if (playbackTrackId != null && playbackTrackId.isNotEmpty) {
      return 'playback:$playbackTrackId';
    }
    final candidateId = track.sourceCandidateId;
    if (candidateId != null && candidateId.isNotEmpty) {
      return 'candidate:$candidateId';
    }
    final sourceUrl = track.sourceUrl;
    if (sourceUrl != null && sourceUrl.isNotEmpty) {
      return 'source:$sourceUrl';
    }
    return 'id:${track.id}';
  }

  int _waveformSampleBucket(int targetSampleCount) {
    final target = targetSampleCount.clamp(8, 65536).toInt();
    var bucket = 8;
    while (bucket < target && bucket < 65536) {
      bucket *= 2;
    }
    return bucket.clamp(8, 65536).toInt();
  }
}

/// The numeric backend analysis id a track resolves to, if any.
int? _analysisTrackId(QueueTrack track) {
  for (final candidate in [track.playbackTrackId, track.id]) {
    if (candidate == null) continue;
    final parsed = int.tryParse(candidate);
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
}

class _TimelineWaveformCacheKey {
  final String trackRevision;
  final int bucket;

  const _TimelineWaveformCacheKey({
    required this.trackRevision,
    required this.bucket,
  });

  @override
  bool operator ==(Object other) =>
      other is _TimelineWaveformCacheKey &&
      other.trackRevision == trackRevision &&
      other.bucket == bucket;

  @override
  int get hashCode => Object.hash(trackRevision, bucket);
}

class _CachedTimelineWaveform {
  final TimelineWaveformData waveform;
  List<double>? _peaks;

  _CachedTimelineWaveform(this.waveform);

  List<double> get peaks => _peaks ??= waveform.peaks;

  int get estimatedByteSize =>
      waveform.estimatedByteSize + (_peaks?.length ?? 0) * 8 + 128;
}
