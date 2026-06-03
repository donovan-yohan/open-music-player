class DiscoverySearchResponse {
  final String query;
  final List<DiscoveryCandidate> results;
  final List<DiscoveryProviderSummary> providers;

  const DiscoverySearchResponse({
    required this.query,
    required this.results,
    required this.providers,
  });

  factory DiscoverySearchResponse.fromJson(Map<String, dynamic> json) {
    return DiscoverySearchResponse(
      query: json['query'] as String? ?? '',
      results: (json['results'] as List<dynamic>? ?? const [])
          .map(
            (item) => DiscoveryCandidate.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      providers: (json['providers'] as List<dynamic>? ?? const [])
          .map(
            (item) =>
                DiscoveryProviderSummary.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

class DiscoveryCandidate {
  final String candidateId;
  final String provider;
  final String sourceId;
  final String sourceUrl;
  final String title;
  final String? artist;
  final String? uploader;
  final int? durationMs;
  final String? thumbnailUrl;
  final bool downloadable;
  final bool playable;

  const DiscoveryCandidate({
    required this.candidateId,
    required this.provider,
    required this.sourceId,
    required this.sourceUrl,
    required this.title,
    this.artist,
    this.uploader,
    this.durationMs,
    this.thumbnailUrl,
    required this.downloadable,
    required this.playable,
  });

  factory DiscoveryCandidate.fromJson(Map<String, dynamic> json) {
    return DiscoveryCandidate(
      candidateId: json['candidateId'] as String? ?? '',
      provider: json['provider'] as String? ?? 'unknown',
      sourceId: json['sourceId'] as String? ?? '',
      sourceUrl: json['sourceUrl'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled result',
      artist: _blankToNull(json['artist'] as String?),
      uploader: _blankToNull(json['uploader'] as String?),
      durationMs: json['durationMs'] as int?,
      thumbnailUrl: _blankToNull(json['thumbnailUrl'] as String?),
      downloadable: json['downloadable'] as bool? ?? false,
      playable: json['playable'] as bool? ?? false,
    );
  }

  String get displaySubtitle {
    final parts = [
      artist ?? uploader,
      provider,
      formattedDuration,
    ].where((part) => part != null && part.isNotEmpty).cast<String>();
    return parts.join(' • ');
  }

  String get sourceType {
    final normalized = provider.toLowerCase().trim();
    if (normalized.contains('soundcloud')) return 'soundcloud';
    return 'youtube';
  }

  int get durationSeconds => (durationMs ?? 0) ~/ 1000;

  String get formattedDuration {
    final value = durationMs;
    if (value == null || value <= 0) return '--:--';
    final totalSeconds = value ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class DiscoveryProviderSummary {
  final String provider;
  final String status;
  final int resultCount;
  final int elapsedMs;
  final String? errorMessage;

  const DiscoveryProviderSummary({
    required this.provider,
    required this.status,
    required this.resultCount,
    required this.elapsedMs,
    this.errorMessage,
  });

  factory DiscoveryProviderSummary.fromJson(Map<String, dynamic> json) {
    final error = json['error'];
    return DiscoveryProviderSummary(
      provider: json['provider'] as String? ?? 'unknown',
      status: json['status'] as String? ?? 'unknown',
      resultCount: json['resultCount'] as int? ?? 0,
      elapsedMs: json['elapsedMs'] as int? ?? 0,
      errorMessage:
          error is Map<String, dynamic> ? error['message'] as String? : null,
    );
  }
}

class DownloadJobSnapshot {
  final String jobId;
  final String status;
  final int progress;
  final String? error;
  final String url;
  final String sourceType;
  final int? trackId;

  const DownloadJobSnapshot({
    required this.jobId,
    required this.status,
    required this.progress,
    this.error,
    required this.url,
    required this.sourceType,
    this.trackId,
  });

  factory DownloadJobSnapshot.fromJson(Map<String, dynamic> json) {
    return DownloadJobSnapshot(
      jobId: json['job_id'] as String? ?? '',
      status: json['status'] as String? ?? 'queued',
      progress: json['progress'] as int? ?? 0,
      error: _blankToNull(json['error'] as String?),
      url: json['url'] as String? ?? '',
      sourceType: json['source_type'] as String? ?? '',
      trackId: json['track_id'] as int?,
    );
  }

  bool get isTerminal => isPlayable || isFailed;
  bool get isFailed => status.toLowerCase() == 'failed' || error != null;
  bool get isPlayable =>
      trackId != null &&
      const {
        'completed',
        'complete',
        'ready',
        'playable',
      }.contains(status.toLowerCase());
}

class DiscoveryQueueItem {
  final String localId;
  final DiscoveryCandidate candidate;
  final String? jobId;
  final String status;
  final int progress;
  final int? trackId;
  final String? error;

  const DiscoveryQueueItem({
    required this.localId,
    required this.candidate,
    this.jobId,
    this.status = 'pending',
    this.progress = 0,
    this.trackId,
    this.error,
  });

  DiscoveryQueueItem copyWith({
    String? jobId,
    String? status,
    int? progress,
    int? trackId,
    String? error,
    bool clearError = false,
  }) {
    return DiscoveryQueueItem(
      localId: localId,
      candidate: candidate,
      jobId: jobId ?? this.jobId,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      trackId: trackId ?? this.trackId,
      error: clearError ? null : error ?? this.error,
    );
  }

  DiscoveryQueueItem withSnapshot(DownloadJobSnapshot snapshot) {
    return copyWith(
      jobId: snapshot.jobId,
      status: snapshot.isPlayable ? 'playable' : snapshot.status,
      progress: snapshot.isPlayable ? 100 : snapshot.progress,
      trackId: snapshot.trackId,
      error: snapshot.error,
      clearError: snapshot.error == null,
    );
  }

  bool get isPending => status == 'pending' || status == 'queued';
  bool get isActive => !isFailed && !isPlayable;
  bool get isFailed => error != null || status.toLowerCase() == 'failed';
  bool get isPlayable =>
      trackId != null &&
      const {
        'playable',
        'completed',
        'complete',
        'ready',
      }.contains(status.toLowerCase());

  String get statusLabel {
    if (isPlayable) return 'playable';
    if (isFailed) return 'failed';
    switch (status.toLowerCase()) {
      case 'pending':
        return 'pending';
      case 'queued':
        return 'queued';
      case 'downloading':
        return 'downloading';
      case 'processing':
        return 'processing';
      case 'uploading':
        return 'uploading';
      default:
        return status;
    }
  }
}

String? _blankToNull(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value;
}
