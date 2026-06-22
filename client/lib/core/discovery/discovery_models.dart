class DiscoverySearchResponse {
  final String query;
  final List<DiscoveryCandidate> results;
  final List<DiscoverySearchSection> sections;
  final List<DiscoveryProviderSummary> providers;

  const DiscoverySearchResponse({
    required this.query,
    required this.results,
    required this.sections,
    required this.providers,
  });

  factory DiscoverySearchResponse.fromJson(Map<String, dynamic> json) {
    final results = (json['results'] as List<dynamic>? ?? const [])
        .map(
          (item) => DiscoveryCandidate.fromJson(item as Map<String, dynamic>),
        )
        .toList();
    final sections = (json['sections'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              DiscoverySearchSection.fromJson(item as Map<String, dynamic>),
        )
        .where((section) => section.items.isNotEmpty)
        .toList();
    final parsedSections = [...sections];
    if (results.isNotEmpty &&
        !parsedSections.any((section) => section.isSources)) {
      parsedSections.add(
        DiscoverySearchSection(
          kind: 'sources',
          title: 'Sources',
          items: results
              .map((candidate) => DiscoverySearchItem.fromCandidate(candidate))
              .toList(),
        ),
      );
    }
    return DiscoverySearchResponse(
      query: json['query'] as String? ?? '',
      results: results,
      sections: parsedSections,
      providers: (json['providers'] as List<dynamic>? ?? const [])
          .map(
            (item) =>
                DiscoveryProviderSummary.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
  }
}

class DiscoverySearchSection {
  final String kind;
  final String title;
  final List<DiscoverySearchItem> items;

  const DiscoverySearchSection({
    required this.kind,
    required this.title,
    required this.items,
  });

  factory DiscoverySearchSection.fromJson(Map<String, dynamic> json) {
    return DiscoverySearchSection(
      kind: json['kind'] as String? ?? 'unknown',
      title: json['title'] as String? ?? 'Results',
      items: (json['items'] as List<dynamic>? ?? const [])
          .map(
            (item) =>
                DiscoverySearchItem.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
  }

  bool get isSources => kind == 'sources';
}

class DiscoverySearchItem {
  final String kind;
  final String id;
  final String title;
  final String? subtitle;
  final String? artist;
  final String? album;
  final int? durationMs;
  final int? score;
  final DiscoveryCandidate? candidate;

  const DiscoverySearchItem({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle,
    this.artist,
    this.album,
    this.durationMs,
    this.score,
    this.candidate,
  });

  factory DiscoverySearchItem.fromJson(Map<String, dynamic> json) {
    final candidateJson = json['candidate'];
    return DiscoverySearchItem(
      kind: json['kind'] as String? ?? 'unknown',
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? 'Untitled result',
      subtitle: _blankToNull(json['subtitle'] as String?),
      artist: _blankToNull(json['artist'] as String?),
      album: _blankToNull(json['album'] as String?),
      durationMs: _readInt(json['durationMs']) ?? _readInt(json['duration_ms']),
      score: _readInt(json['score']),
      candidate: candidateJson is Map<String, dynamic>
          ? DiscoveryCandidate.fromJson(candidateJson)
          : null,
    );
  }

  factory DiscoverySearchItem.fromCandidate(DiscoveryCandidate candidate) {
    return DiscoverySearchItem(
      kind: 'source',
      id: candidate.candidateId,
      title: candidate.title,
      subtitle: candidate.displaySubtitle,
      artist: candidate.artist,
      album: candidate.album,
      durationMs: candidate.durationMs,
      candidate: candidate,
    );
  }

  String get displaySubtitle {
    final value = subtitle;
    if (value != null && value.isNotEmpty) return value;
    final parts = [
      artist,
      album,
      formattedDuration,
    ].where((part) => part != null && part.isNotEmpty).cast<String>();
    return parts.join(' • ');
  }

  String get formattedDuration {
    final value = durationMs;
    if (value == null || value <= 0) return '';
    final totalSeconds = value ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}

class DiscoveryCandidate {
  final String candidateId;
  final String provider;
  final String sourceId;
  final String sourceUrl;
  final String title;
  final String? artist;
  final String? album;
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
    this.album,
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
      album: _blankToNull(json['album'] as String?),
      uploader: _blankToNull(json['uploader'] as String?),
      durationMs: _readInt(json['durationMs']) ?? _readInt(json['duration_ms']),
      thumbnailUrl: _blankToNull(
        json['thumbnailUrl'] as String? ?? json['thumbnail_url'] as String?,
      ),
      downloadable: json['downloadable'] as bool? ?? false,
      playable: json['playable'] as bool? ?? false,
    );
  }

  factory DiscoveryCandidate.fromQueueItemJson(Map<String, dynamic> json) {
    return DiscoveryCandidate(
      candidateId: json['candidateId'] as String? ?? '',
      provider: json['provider'] as String? ?? 'library',
      sourceId: json['sourceId'] as String? ?? '',
      sourceUrl: json['sourceUrl'] as String? ?? '',
      title: json['title'] as String? ?? 'Queued track',
      artist: _blankToNull(json['artist'] as String?),
      album: _blankToNull(json['album'] as String?),
      uploader: _blankToNull(json['uploader'] as String?),
      durationMs: _readInt(json['durationMs']) ?? _readInt(json['duration_ms']),
      thumbnailUrl: _blankToNull(
        json['thumbnailUrl'] as String? ?? json['thumbnail_url'] as String?,
      ),
      downloadable: false,
      playable: true,
    );
  }

  Map<String, dynamic> toQueueJson() {
    return {
      'candidateId': candidateId,
      'provider': provider,
      if (sourceId.isNotEmpty) 'sourceId': sourceId,
      'sourceUrl': sourceUrl,
      'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (uploader != null) 'uploader': uploader,
      if (durationMs != null) 'durationMs': durationMs,
      if (thumbnailUrl != null) 'thumbnailUrl': thumbnailUrl,
      'downloadable': downloadable,
    };
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

/// Grounded AI-assist envelope returned by `POST /api/v1/discovery/assist`.
///
/// The backend returns HTTP 200 for every orchestrated outcome and encodes the
/// real state in [status] (`ok` / `disabled` / `clarification` / `error`), so a
/// disabled model or an upstream failure is first-class data the UI branches on
/// rather than a transport error. [candidates] holds only resolver-grounded
/// direct-URL candidates; provider-backed results live in [search]. No field
/// ever carries a model-fabricated URL — the backend scrubs free text — so the
/// UI can render every string and candidate as-is without re-validating.
class DiscoveryAssistResponse {
  final String status;
  final String assistantText;
  final DiscoveryAssistIntent? intent;
  final DiscoveryAssistClarification? clarification;
  final DiscoverySearchResponse? search;
  final List<DiscoveryCandidate> candidates;
  final List<String> caveats;
  final DiscoveryAssistError? error;

  const DiscoveryAssistResponse({
    required this.status,
    this.assistantText = '',
    this.intent,
    this.clarification,
    this.search,
    this.candidates = const [],
    this.caveats = const [],
    this.error,
  });

  factory DiscoveryAssistResponse.fromJson(Map<String, dynamic> json) {
    final searchJson = json['search'];
    final intentJson = json['intent'];
    final clarificationJson = json['clarification'];
    final errorJson = json['error'];
    final rawStatus = (json['status'] as String? ?? '').trim();
    final status = const {
      'ok',
      'disabled',
      'clarification',
      'error',
    }.contains(rawStatus)
        ? rawStatus
        : 'error';
    return DiscoveryAssistResponse(
      // A missing/blank status is treated as an error so the UI never silently
      // renders an unlabelled/unknown envelope as a success or empty screen.
      status: status,
      assistantText: json['assistantText'] as String? ?? '',
      intent: intentJson is Map<String, dynamic>
          ? DiscoveryAssistIntent.fromJson(intentJson)
          : null,
      clarification: clarificationJson is Map<String, dynamic>
          ? DiscoveryAssistClarification.fromJson(clarificationJson)
          : null,
      search: searchJson is Map<String, dynamic>
          ? DiscoverySearchResponse.fromJson(searchJson)
          : null,
      candidates: (json['candidates'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(DiscoveryCandidate.fromJson)
          .toList(),
      caveats: (json['caveats'] as List<dynamic>? ?? const [])
          .map((value) => value?.toString().trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(),
      error: errorJson is Map<String, dynamic>
          ? DiscoveryAssistError.fromJson(errorJson)
          : null,
    );
  }

  bool get isOk => status == 'ok';
  bool get isDisabled => status == 'disabled';
  bool get isClarification => status == 'clarification';
  bool get isError => status == 'error';

  bool get hasCandidates => candidates.isNotEmpty;
  bool get hasSearchResults => search?.sections.isNotEmpty ?? false;

  /// Whether anything queueable/searchable was grounded. Drives the
  /// "no results" empty state independently of the disabled/error banners.
  bool get hasGroundedResults => hasCandidates || hasSearchResults;
}

/// Grounded echo of how OMP interpreted the request. [detectedUrl] is only ever
/// a URL the user pasted that the resolver accepted, never a model-emitted one.
class DiscoveryAssistIntent {
  final String kind;
  final String? searchQuery;
  final List<String> providers;
  final String? detectedUrl;

  const DiscoveryAssistIntent({
    required this.kind,
    this.searchQuery,
    this.providers = const [],
    this.detectedUrl,
  });

  factory DiscoveryAssistIntent.fromJson(Map<String, dynamic> json) {
    return DiscoveryAssistIntent(
      kind: json['kind'] as String? ?? 'unknown',
      searchQuery: _blankToNull(json['searchQuery'] as String?),
      providers: (json['providers'] as List<dynamic>? ?? const [])
          .map((value) => value?.toString().trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(),
      detectedUrl: _blankToNull(json['detectedUrl'] as String?),
    );
  }

  bool get isDirectUrl => kind == 'direct_url';
}

/// A follow-up question the assistant surfaced when the request was ambiguous.
class DiscoveryAssistClarification {
  final String question;
  final List<String> options;

  const DiscoveryAssistClarification({
    required this.question,
    this.options = const [],
  });

  factory DiscoveryAssistClarification.fromJson(Map<String, dynamic> json) {
    return DiscoveryAssistClarification(
      question: json['question'] as String? ?? '',
      options: (json['options'] as List<dynamic>? ?? const [])
          .map((value) => value?.toString().trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(),
    );
  }
}

/// Stable error descriptor for disabled/upstream/timeout assist outcomes.
class DiscoveryAssistError {
  final String code;
  final String message;

  const DiscoveryAssistError({required this.code, required this.message});

  factory DiscoveryAssistError.fromJson(Map<String, dynamic> json) {
    return DiscoveryAssistError(
      code: json['code'] as String? ?? '',
      message: json['message'] as String? ?? '',
    );
  }
}

class DiscoveryQueueState {
  final List<DiscoveryQueueItem> items;
  final int currentPosition;
  final DateTime? updatedAt;

  const DiscoveryQueueState({
    required this.items,
    required this.currentPosition,
    this.updatedAt,
  });

  factory DiscoveryQueueState.empty() {
    return const DiscoveryQueueState(items: [], currentPosition: 0);
  }

  factory DiscoveryQueueState.fromJson(Map<String, dynamic> json) {
    return DiscoveryQueueState(
      items: (json['items'] as List<dynamic>? ?? const [])
          .map(
            (item) => DiscoveryQueueItem.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      currentPosition: _readInt(json['currentPosition']) ??
          _readInt(json['current_position']) ??
          0,
      updatedAt: _readDate(json['updatedAt']) ?? _readDate(json['updated_at']),
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
      jobId: _stringFromJson(json, const [
            'jobId',
            'job_id',
            'downloadJobId',
            'download_job_id',
          ]) ??
          '',
      status: json['status'] as String? ?? 'queued',
      progress: _readInt(json['progress']) ?? 0,
      error: _blankToNull(json['error'] as String?),
      url:
          _stringFromJson(json, const ['url', 'sourceUrl', 'source_url']) ?? '',
      sourceType:
          _stringFromJson(json, const ['sourceType', 'source_type']) ?? '',
      trackId: _readInt(json['trackId']) ?? _readInt(json['track_id']),
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
  final String? queueItemId;
  final int position;
  final String kind;
  final DiscoveryCandidate candidate;
  final String? downloadJobId;
  final String playbackState;
  final int progress;
  final int? trackId;
  final String? error;
  final bool canPlay;
  final bool canRetry;
  final bool canRemove;
  final DateTime? addedAt;
  final DateTime? updatedAt;

  const DiscoveryQueueItem({
    required this.localId,
    this.queueItemId,
    this.position = 0,
    this.kind = 'source',
    required this.candidate,
    this.downloadJobId,
    String? status,
    String? playbackState,
    this.progress = 0,
    this.trackId,
    this.error,
    bool? canPlay,
    bool? canRetry,
    bool? canRemove,
    this.addedAt,
    this.updatedAt,
  })  : playbackState = playbackState ?? status ?? 'queued',
        canPlay = canPlay ??
            ((playbackState ?? status ?? '') == 'playable' && trackId != null),
        canRetry = canRetry ?? ((playbackState ?? status ?? '') == 'failed'),
        canRemove = canRemove ?? true;

  factory DiscoveryQueueItem.fromJson(Map<String, dynamic> json) {
    final sourceJson = json['sourceCandidate'] ?? json['source_candidate'];
    final candidate = sourceJson is Map<String, dynamic>
        ? DiscoveryCandidate.fromJson(sourceJson)
        : DiscoveryCandidate.fromQueueItemJson(json);
    final queueItemId = json['queueItemId'] as String? ?? json['id'] as String?;
    final trackId = _readInt(json['trackId']) ?? _readInt(json['track_id']);
    final rawState = json['playbackState'] as String? ??
        json['playback_state'] as String? ??
        json['status'] as String? ??
        (trackId != null ? 'playable' : 'queued');
    final playbackState = _normalizePlaybackState(rawState);
    final progress = _readInt(json['progress']) ??
        (playbackState == 'playable'
            ? 100
            : playbackState == 'failed'
                ? 0
                : 0);
    final error = _blankToNull(json['error'] as String?);
    final downloadJobId =
        json['downloadJobId'] as String? ?? json['download_job_id'] as String?;

    return DiscoveryQueueItem(
      localId: queueItemId ??
          candidate.candidateId.ifNotEmpty ??
          downloadJobId ??
          candidate.sourceUrl,
      queueItemId: queueItemId,
      position: _readInt(json['position']) ?? 0,
      kind:
          json['kind'] as String? ?? (sourceJson == null ? 'track' : 'source'),
      candidate: candidate,
      downloadJobId: downloadJobId,
      playbackState: playbackState,
      progress: progress,
      trackId: trackId,
      error: error,
      canPlay: json['canPlay'] as bool? ??
          (playbackState == 'playable' && trackId != null),
      canRetry: json['canRetry'] as bool? ?? playbackState == 'failed',
      canRemove: json['canRemove'] as bool? ?? true,
      addedAt: _readDate(json['addedAt']) ?? _readDate(json['added_at']),
      updatedAt: _readDate(json['updatedAt']) ?? _readDate(json['updated_at']),
    );
  }

  DiscoveryQueueItem copyWith({
    String? queueItemId,
    int? position,
    String? kind,
    String? downloadJobId,
    String? status,
    String? playbackState,
    int? progress,
    int? trackId,
    String? error,
    bool? canPlay,
    bool? canRetry,
    bool? canRemove,
    bool clearError = false,
  }) {
    final nextState = _normalizePlaybackState(
      playbackState ?? status ?? this.playbackState,
    );
    final nextTrackId = trackId ?? this.trackId;
    return DiscoveryQueueItem(
      localId: localId,
      queueItemId: queueItemId ?? this.queueItemId,
      position: position ?? this.position,
      kind: kind ?? this.kind,
      candidate: candidate,
      downloadJobId: downloadJobId ?? this.downloadJobId,
      playbackState: nextState,
      progress: progress ?? this.progress,
      trackId: nextTrackId,
      error: clearError ? null : error ?? this.error,
      canPlay: canPlay ?? (nextState == 'playable' && nextTrackId != null),
      canRetry: canRetry ?? nextState == 'failed',
      canRemove: canRemove ?? this.canRemove,
      addedAt: addedAt,
      updatedAt: updatedAt,
    );
  }

  DiscoveryQueueItem withSnapshot(DownloadJobSnapshot snapshot) {
    final nextState = snapshot.isPlayable ? 'playable' : snapshot.status;
    return copyWith(
      downloadJobId: snapshot.jobId,
      playbackState: nextState,
      progress: snapshot.isPlayable ? 100 : snapshot.progress,
      trackId: snapshot.trackId,
      error: snapshot.error,
      clearError: snapshot.error == null,
    );
  }

  bool get isPending => playbackState == 'pending' || playbackState == 'queued';
  bool get isActive => !isFailed && !isPlayable;
  bool get isFailed => error != null || playbackState == 'failed';
  bool get isPlayable => canPlay && trackId != null;

  String get title => candidate.title;
  String? get artist => candidate.artist ?? candidate.uploader;
  String? get thumbnailUrl => candidate.thumbnailUrl;

  String get statusLabel {
    if (isPlayable) return 'playable';
    if (isFailed) return 'failed';
    switch (playbackState) {
      case 'pending':
      case 'queued':
        return 'queued';
      case 'downloading':
        return 'downloading';
      case 'processing':
        return 'processing';
      case 'uploading':
        return 'uploading';
      default:
        return playbackState;
    }
  }
}

extension _StringIfNotEmpty on String {
  String? get ifNotEmpty => isEmpty ? null : this;
}

String _normalizePlaybackState(String value) {
  switch (value.trim().toLowerCase()) {
    case 'pendingdownload':
    case 'pending_download':
    case 'pending':
    case 'queued':
      return 'queued';
    case 'complete':
    case 'completed':
    case 'ready':
    case 'playable':
      return 'playable';
    case 'downloading':
    case 'processing':
    case 'uploading':
    case 'failed':
      return value.trim().toLowerCase();
    default:
      return value.trim().isEmpty ? 'queued' : value.trim();
  }
}

int? _readInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

DateTime? _readDate(Object? value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value)?.toUtc();
}

String? _blankToNull(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  return value;
}

String? _stringFromJson(Map<String, dynamic> json, Iterable<String> keys) {
  for (final key in keys) {
    final value = json[key];
    if (value is String && value.trim().isNotEmpty) return value;
  }
  return null;
}
