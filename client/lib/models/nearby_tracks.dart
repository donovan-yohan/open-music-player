/// Typed view of `GET /api/v1/tracks/nearby`.
///
/// Mirrors `backend/internal/api/track_nearby_handlers.go`:
/// `{ tracks: [{id,title,artist?,album?,duration_ms?,bpm,camelot}], bpm,
///    camelot, tolerance, order? }`. `artist`, `album` and `duration_ms` are
/// `omitempty` on the wire, and `order` is echoed only when `order=history`
/// was requested, so every field here parses tolerantly in the same style as
/// the mix-plan slices.
library;

/// A single harmonically compatible track from the caller's own library.
class NearbyTrack {
  /// Library track id. Rows without a usable id are dropped by
  /// [NearbyTracksResult.fromJson] because they can neither be queued nor
  /// added to a playlist.
  final int id;
  final String title;
  final String? artist;
  final String? album;

  /// Track length in milliseconds, or null when the server does not know it
  /// (`duration_ms` is `omitempty` on the wire).
  ///
  /// Queueing a match builds a playback item from this response, and a queue
  /// item of unknown length becomes a zero-length timeline clip that is never
  /// active — so callers must treat null as "cannot be queued", not as zero.
  final int? durationMs;

  /// Effective tempo, or null when the server sent no usable tempo.
  final double? bpm;

  /// Canonical Camelot label (e.g. `8A`), or null when it is absent or does
  /// not sit on the wheel.
  final String? camelot;

  const NearbyTrack({
    required this.id,
    required this.title,
    this.artist,
    this.album,
    this.durationMs,
    this.bpm,
    this.camelot,
  });

  factory NearbyTrack.fromJson(Map<String, dynamic> json) => NearbyTrack(
        id: json['id'] is num ? (json['id'] as num).toInt() : 0,
        title: _nonEmpty(json['title']) ?? '',
        artist: _nonEmpty(json['artist']),
        album: _nonEmpty(json['album']),
        durationMs: _positiveInt(json['duration_ms']),
        bpm: _positiveFinite(json['bpm']),
        camelot: normalizeCamelotLabel(json['camelot']),
      );

  /// True when this row can be acted on (queued, added to a playlist).
  bool get isUsable => id > 0 && title.isNotEmpty;
}

/// The full nearby-tracks response, including the echoed query it answered.
class NearbyTracksResult {
  final List<NearbyTrack> tracks;

  /// Anchor tempo the server matched against.
  final double bpm;

  /// Anchor Camelot label, canonicalized by the server.
  final String camelot;

  /// Absolute BPM window (±), not a percentage: the server filters
  /// `effective_bpm BETWEEN bpm-tolerance AND bpm+tolerance`.
  final double tolerance;

  /// True when the server re-ranked results by play-history affinity, i.e.
  /// `order=history` was requested and echoed back.
  final bool orderedByHistory;

  const NearbyTracksResult({
    required this.tracks,
    required this.bpm,
    required this.camelot,
    required this.tolerance,
    this.orderedByHistory = false,
  });

  /// Never throws on a partial or odd payload; a missing `tracks` key yields
  /// an empty list, and unusable rows are dropped.
  factory NearbyTracksResult.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['tracks'];
    final tracks = <NearbyTrack>[];
    if (rawTracks is List) {
      for (final entry in rawTracks) {
        if (entry is! Map) continue;
        final track = NearbyTrack.fromJson(Map<String, dynamic>.from(entry));
        if (track.isUsable) tracks.add(track);
      }
    }
    return NearbyTracksResult(
      tracks: tracks,
      bpm: _positiveFinite(json['bpm']) ?? 0,
      camelot: normalizeCamelotLabel(json['camelot']) ?? '',
      tolerance: _nonNegativeFinite(json['tolerance']) ?? 0,
      orderedByHistory: json['order'] == 'history',
    );
  }
}

final RegExp _camelotPattern = RegExp(r'^(?:[1-9]|1[0-2])[AB]$');

/// Canonicalizes a Camelot label, or returns null when it is not on the wheel.
///
/// Same rule the blended playlist row uses for its key chip
/// (`MixMetadataBadges.normalizeCamelot`), kept here so `lib/models` does not
/// have to depend on a widget library.
String? normalizeCamelotLabel(Object? value) {
  if (value is! String) return null;
  final text = value.trim().toUpperCase();
  return _camelotPattern.hasMatch(text) ? text : null;
}

String? _nonEmpty(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Whole milliseconds, or null when absent or not a real length. Zero and
/// negatives are "unknown", never a playable duration.
int? _positiveInt(Object? value) => _positiveFinite(value)?.toInt();

double? _positiveFinite(Object? value) {
  final number = _finite(value);
  return number != null && number > 0 ? number : null;
}

double? _nonNegativeFinite(Object? value) {
  final number = _finite(value);
  return number != null && number >= 0 ? number : null;
}

/// Accepts only real JSON numbers: a stringified or absent value is treated as
/// missing rather than throwing, so one odd row cannot fail the whole parse.
double? _finite(Object? value) {
  if (value is! num) return null;
  final number = value.toDouble();
  return number.isFinite ? number : null;
}
