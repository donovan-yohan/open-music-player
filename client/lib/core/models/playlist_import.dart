class PlaylistImportStatus {
  static const resolving = 'resolving';
  static const importing = 'importing';
  static const complete = 'complete';
  static const partialFailure = 'partial_failure';
  static const failed = 'failed';
  static const cancelled = 'cancelled';

  final String id;
  final int playlistId;
  final String sourceUrl;
  final String? sourceTitle;
  final String status;
  final int totalItems;
  final int importedItems;
  final int queuedItems;
  final int failedItems;
  final int skippedItems;
  final int maxItems;
  final String? error;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<PlaylistImportItem> items;

  const PlaylistImportStatus({
    required this.id,
    required this.playlistId,
    required this.sourceUrl,
    required this.status,
    required this.totalItems,
    required this.importedItems,
    required this.queuedItems,
    required this.failedItems,
    required this.skippedItems,
    required this.maxItems,
    required this.items,
    this.sourceTitle,
    this.error,
    this.createdAt,
    this.updatedAt,
  });

  factory PlaylistImportStatus.fromJson(Map<String, dynamic> json) {
    return PlaylistImportStatus(
      id: json['id'] as String? ?? '',
      playlistId: _intValue(json['playlistId']),
      sourceUrl: json['sourceUrl'] as String? ?? '',
      sourceTitle: _optionalString(json['sourceTitle']),
      status: json['status'] as String? ?? resolving,
      totalItems: _intValue(json['totalItems']),
      importedItems: _intValue(json['importedItems']),
      queuedItems: _intValue(json['queuedItems']),
      failedItems: _intValue(json['failedItems']),
      skippedItems: _intValue(json['skippedItems']),
      maxItems: _intValue(json['maxItems']),
      error: _optionalString(json['error']),
      createdAt: _dateTimeValue(json['createdAt']),
      updatedAt: _dateTimeValue(json['updatedAt']),
      items: (json['items'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PlaylistImportItem.fromJson)
          .toList(),
    );
  }

  bool get isTerminal =>
      status == complete ||
      status == partialFailure ||
      status == failed ||
      status == cancelled;

  bool get hasFailures => failedItems > 0 || status == failed;

  bool get isSuccessful => status == complete || status == partialFailure;

  int get finishedItems => importedItems + failedItems + skippedItems;

  int get reusedItems => skippedItems;

  int get successfulOrReusedItems => importedItems + skippedItems;

  double? get progressFraction {
    if (totalItems <= 0) return null;
    final fraction = finishedItems / totalItems;
    return fraction.clamp(0, 1).toDouble();
  }
}

class PlaylistImportItem {
  static const pending = 'pending';
  static const queued = 'queued';
  static const imported = 'imported';
  static const failed = 'failed';
  static const skippedDuplicate = 'skipped_duplicate';

  final int id;
  final int sourceIndex;
  final int playlistPosition;
  final String? sourceId;
  final String? sourceUrl;
  final String? title;
  final String? artist;
  final String? album;
  final String? uploader;
  final int? durationMs;
  final String? thumbnailUrl;
  final String status;
  final String? error;
  final int? trackId;
  final String? downloadJobId;

  const PlaylistImportItem({
    required this.id,
    required this.sourceIndex,
    required this.playlistPosition,
    required this.status,
    this.sourceId,
    this.sourceUrl,
    this.title,
    this.artist,
    this.album,
    this.uploader,
    this.durationMs,
    this.thumbnailUrl,
    this.error,
    this.trackId,
    this.downloadJobId,
  });

  factory PlaylistImportItem.fromJson(Map<String, dynamic> json) {
    return PlaylistImportItem(
      id: _intValue(json['id']),
      sourceIndex: _intValue(json['sourceIndex']),
      playlistPosition: _intValue(json['playlistPosition']),
      sourceId: _optionalString(json['sourceId']),
      sourceUrl: _optionalString(json['sourceUrl']),
      title: _optionalString(json['title']),
      artist: _optionalString(json['artist']),
      album: _optionalString(json['album']),
      uploader: _optionalString(json['uploader']),
      durationMs: _optionalInt(json['durationMs']),
      thumbnailUrl: _optionalString(json['thumbnailUrl']),
      status: json['status'] as String? ?? pending,
      error: _optionalString(json['error']),
      trackId: _optionalInt(json['trackId']),
      downloadJobId: _optionalString(json['downloadJobId']),
    );
  }

  bool get isFailed => status == failed;

  bool get isDuplicateReuse => status == skippedDuplicate;

  bool get isImported => status == imported || isDuplicateReuse;

  String get displayTitle {
    final value = title?.trim();
    if (value != null && value.isNotEmpty) return value;
    final id = sourceId?.trim();
    if (id != null && id.isNotEmpty) return id;
    return 'Playlist item #${sourceIndex + 1}';
  }

  String get statusLabel {
    switch (status) {
      case pending:
        return 'Pending';
      case queued:
        return 'Queued';
      case imported:
        return 'Imported';
      case failed:
        return 'Failed';
      case skippedDuplicate:
        return 'Reused';
      default:
        return status.replaceAll('_', ' ');
    }
  }
}

String? _optionalString(dynamic value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

int _intValue(dynamic value) => _optionalInt(value) ?? 0;

int? _optionalInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

DateTime? _dateTimeValue(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  return DateTime.tryParse(value);
}
