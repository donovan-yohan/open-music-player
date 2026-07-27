import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shared/models/track.dart'
    show
        TrackArtworkKind,
        resolveTrackArtworkDescriptor,
        trackArtworkKindFromPayload;
import '../../models/track_analysis.dart';
import 'playback_session.dart';

/// Pure, testable decisions and (de)serialization for resumable playback:
///   * [QueueSnapshot] — the persisted listening queue (track playback-json
///     list + current index + last position), with round-trip encode/decode.
///   * [shufflePermutation] — a play order that keeps the current item in place
///     and reorders the rest into a non-linear (for >2 tracks) upcoming order.
///   * [previousAction] — the 3s previous-button rule (restart vs skip).
///
/// These are kept free of platform audio so they can be unit-tested without a
/// real player, and reused by [PlaybackState] for persistence/resume.

/// What the previous button should do given the elapsed [positionMs] in the
/// current track.
enum PreviousAction { restart, skip }

/// Above this many milliseconds into the current track the previous button
/// restarts it; at or below it, previous skips to the prior track.
const int previousRestartThresholdMs = 3000;

/// The previous button restarts the current track when more than 3s in, else it
/// skips to the previous track. Exactly 3s (and anything less) skips.
PreviousAction previousAction(int positionMs) =>
    positionMs > previousRestartThresholdMs
        ? PreviousAction.restart
        : PreviousAction.skip;

/// A serializable snapshot of the active listening queue.
///
/// [tracks] holds the track playback-json maps (the same shape
/// `PlaybackState.playQueue` consumes) so a restore re-resolves signed URLs
/// from scratch instead of persisting soon-to-expire object URLs. An empty
/// [tracks] represents "nothing to resume" and round-trips to the same empty
/// snapshot, which drives a no-op restore.
class QueueSnapshot {
  final List<Map<String, dynamic>> tracks;
  final int currentIndex;
  final int positionMs;
  final MixSession? session;
  final String? accountId;

  const QueueSnapshot({
    this.tracks = const [],
    this.currentIndex = 0,
    this.positionMs = 0,
    this.session,
    this.accountId,
  });

  bool get isEmpty => tracks.isEmpty;

  Map<String, dynamic> toJson() => {
        'tracks': tracks,
        'currentIndex': currentIndex,
        'positionMs': positionMs,
        if (session != null) 'session': session!.toJson(),
        if (accountId != null) 'accountId': accountId,
      };

  factory QueueSnapshot.fromJson(Map<String, dynamic> json) {
    final rawTracks = json['tracks'];
    final tracks = <Map<String, dynamic>>[];
    if (rawTracks is List) {
      for (final entry in rawTracks) {
        if (entry is Map) {
          tracks.add(Map<String, dynamic>.from(entry));
        }
      }
    }

    final rawIndex = (json['currentIndex'] as num?)?.toInt() ?? 0;
    final currentIndex =
        tracks.isEmpty ? 0 : rawIndex.clamp(0, tracks.length - 1);

    final rawPosition = (json['positionMs'] as num?)?.toInt() ?? 0;
    final positionMs = rawPosition < 0 ? 0 : rawPosition;

    MixSession? session;
    final rawSession = json['session'];
    if (rawSession is Map) {
      session = MixSession.fromJson(Map<String, dynamic>.from(rawSession));
    }

    return QueueSnapshot(
      tracks: tracks,
      currentIndex: currentIndex,
      positionMs: positionMs,
      session: session,
      accountId: json['accountId'] as String?,
    );
  }

  QueueSnapshot scopedTo(String? currentAccountId) {
    final snapshotOwnedByCurrent = accountId != null &&
        currentAccountId != null &&
        accountId == currentAccountId;
    return QueueSnapshot(
      tracks: [
        for (final track in tracks)
          _scopePlaybackTrack(
            track,
            currentAccountId: currentAccountId,
            snapshotOwnedByCurrent: snapshotOwnedByCurrent,
          ),
      ],
      currentIndex: currentIndex,
      positionMs: positionMs,
      session: session,
      accountId: currentAccountId,
    );
  }

  QueueSnapshot withAccountId(String? value) => QueueSnapshot(
        tracks: tracks,
        currentIndex: currentIndex,
        positionMs: positionMs,
        session: session,
        accountId: value,
      );

  /// JSON string form for storage.
  String encode() => jsonEncode(toJson());

  /// Rebuilds a snapshot from stored JSON. A null, empty, or malformed value
  /// yields an empty snapshot (no-op restore) rather than throwing.
  static QueueSnapshot decode(String? raw) {
    if (raw == null || raw.isEmpty) return const QueueSnapshot();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return QueueSnapshot.fromJson(decoded);
      }
    } catch (_) {
      // Corrupt payload — fall through to an empty (no-op) snapshot.
    }
    return const QueueSnapshot();
  }
}

/// Builds a play order over the indices `0..length-1` that keeps the item at
/// [currentIndex] first (it is playing now) and randomly permutes the rest.
///
/// The result is always a permutation of every index. For [length] > 2 the
/// upcoming portion is guaranteed to differ from the natural ascending order,
/// so enabling shuffle visibly changes what plays next. Turning shuffle OFF is
/// the caller's job (it restores the natural `0..length-1` order relative to
/// the current item).
List<int> shufflePermutation(
  int length,
  int currentIndex, {
  Random? random,
}) {
  if (length <= 0) return const [];
  final rng = random ?? Random();
  final current =
      (currentIndex < 0 || currentIndex >= length) ? 0 : currentIndex;

  final natural = [
    for (var i = 0; i < length; i++)
      if (i != current) i
  ];
  final others = List<int>.of(natural);

  // Fisher-Yates shuffle of the non-current indices.
  for (var i = others.length - 1; i > 0; i--) {
    final j = rng.nextInt(i + 1);
    final tmp = others[i];
    others[i] = others[j];
    others[j] = tmp;
  }

  // Guarantee a non-linear upcoming order for >2 tracks: if the shuffle happened
  // to reproduce the natural ascending order, swap the first two upcoming items.
  if (length > 2 && _sameOrder(others, natural)) {
    final tmp = others[0];
    others[0] = others[1];
    others[1] = tmp;
  }

  return [current, ...others];
}

bool _sameOrder(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Converts a queued [MediaItem] back into the track playback-json shape so the
/// queue can be persisted and later re-resolved by the source resolver. Only
/// stable, re-resolvable fields are kept — never the signed `url`/`expiresAt`.
Map<String, dynamic> mediaItemToPlaybackJson(MediaItem item) {
  final parsedId = int.tryParse(item.id);
  final artwork = _persistedArtwork(item);
  final analysisSummary = compactAnalysisSummary(
    item.extras?['analysisSummary'] ?? item.extras?['analysis_summary'],
  );
  final analysisOverrides = compactAnalysisOverrides(
    item.extras?['analysisOverrides'] ?? item.extras?['analysis_overrides'],
  );
  return {
    'id': parsedId ?? item.id,
    'title': item.title,
    if (item.artist != null) 'artist': item.artist,
    if (item.album != null) 'album': item.album,
    'duration': item.duration?.inSeconds ?? 0,
    if (artwork.url != null) 'artwork_url': artwork.url,
    'artwork_kind': artwork.kind.wireValue,
    if (item.extras?['isLiked'] is bool) 'isLiked': item.extras?['isLiked'],
    if (item.extras?['likedAccountId'] is String)
      'likedAccountId': item.extras?['likedAccountId'],
    if (item.extras?['sourceUrl'] is String &&
        (item.extras?['sourceUrl'] as String).trim().isNotEmpty)
      'sourceUrl': (item.extras?['sourceUrl'] as String).trim(),
    if (item.extras?['analysisStatus'] != null)
      'analysisStatus': item.extras?['analysisStatus'],
    if (analysisSummary != null) 'analysisSummary': analysisSummary,
    if (analysisOverrides != null) 'analysisOverrides': analysisOverrides,
    if (item.extras?['analysisUpdatedAt'] != null)
      'analysisUpdatedAt': item.extras?['analysisUpdatedAt'],
    if (item.extras?['analysisOverrideRevision'] != null)
      'analysisOverrideRevision': item.extras?['analysisOverrideRevision'],
    if (item.extras?['analysisOverrideUpdatedAt'] != null)
      'analysisOverrideUpdatedAt': item.extras?['analysisOverrideUpdatedAt'],
  };
}

({String? url, TrackArtworkKind kind}) _persistedArtwork(MediaItem item) {
  final extras = item.extras;
  final artworkKind = trackArtworkKindFromPayload(extras);
  return resolveTrackArtworkDescriptor(
    artworkUrl: item.artUri?.toString(),
    artworkKind: artworkKind,
    metadata: null,
    mbReleaseId: null,
  );
}

const int maxPersistedBeatPositions = 128;
const int maxPersistedDownbeatPositions = 64;

/// Keeps only the tempo facts needed by playback placement and automation.
///
/// Older snapshots and API payloads may contain detailed waveform/analysis
/// arrays. They remain readable, but never enter MediaItem extras or a newly
/// persisted queue snapshot.
Map<String, dynamic>? compactAnalysisSummary(Object? value) =>
    _compactTempoMetadata(value, preserveEmpty: false);

/// Preserves an explicitly-present empty override object while bounding any
/// override beat grids to the same compact playback contract.
Map<String, dynamic>? compactAnalysisOverrides(Object? value) =>
    _compactTempoMetadata(value, preserveEmpty: true);

Map<String, dynamic>? _compactTempoMetadata(
  Object? value, {
  required bool preserveEmpty,
}) {
  if (value is! Map) return null;
  final source = Map<String, dynamic>.from(value);
  final compact = <String, dynamic>{};

  final summaryContract = trackAnalysisSummaryContract(source);
  if (summaryContract != null) {
    compact[trackAnalysisSummaryContractKey] = summaryContract;
  }

  final bpm = _compactAnalysisValue(source['bpm']);
  if (bpm != null) compact['bpm'] = bpm;
  for (final key in ['key', 'camelot']) {
    final analysisValue = _compactAnalysisValue(source[key]);
    if (analysisValue != null) compact[key] = analysisValue;
  }

  final beatGridValue = source['beat_grid'] ?? source['beatGrid'];
  if (beatGridValue is Map) {
    final beatGrid = Map<String, dynamic>.from(beatGridValue);
    final compactBeatGrid = <String, dynamic>{};
    for (final key in ['bpm', 'confidence', 'provenance']) {
      if (beatGrid[key] != null) compactBeatGrid[key] = beatGrid[key];
    }
    final offset = beatGrid['offset_ms'] ?? beatGrid['offsetMs'];
    if (offset != null) compactBeatGrid['offset_ms'] = offset;
    final beats = beatGrid['beats_ms'] ?? beatGrid['beatsMs'];
    final compactBeats = _boundedIntList(beats, maxPersistedBeatPositions);
    if (compactBeats.isNotEmpty ||
        (preserveEmpty && beats is List && beats.isEmpty)) {
      compactBeatGrid['beats_ms'] = compactBeats;
    }
    if (compactBeatGrid.isNotEmpty) compact['beat_grid'] = compactBeatGrid;
  }

  final downbeatsValue = source['downbeats'];
  final compactDownbeats = <String, dynamic>{};
  Object? positions;
  if (downbeatsValue is Map) {
    final downbeats = Map<String, dynamic>.from(downbeatsValue);
    positions = downbeats['positions_ms'] ?? downbeats['positionsMs'];
    for (final key in ['confidence', 'provenance']) {
      if (downbeats[key] != null) compactDownbeats[key] = downbeats[key];
    }
  } else {
    positions = downbeatsValue;
  }
  final boundedDownbeats = _boundedIntList(
    positions,
    maxPersistedDownbeatPositions,
  );
  if (boundedDownbeats.isNotEmpty ||
      (preserveEmpty && positions is List && positions.isEmpty)) {
    compactDownbeats['positions_ms'] = boundedDownbeats;
  }
  if (compactDownbeats.isNotEmpty) compact['downbeats'] = compactDownbeats;

  final manualTiming = _compactManualTimingOverride(
    source['manual_timing_override'] ?? source['manualTimingOverride'],
  );
  if (manualTiming != null) compact['manual_timing_override'] = manualTiming;

  if (source['provenance'] != null) {
    compact['provenance'] = source['provenance'];
  }
  if (compact.isEmpty && !preserveEmpty) return null;
  return compact;
}

/// The normalized manual timing record is already compact: it identifies a
/// spacing/anchor/meter/phase correction without carrying a second generated
/// marker array. Keep only its schema fields when a queue snapshot or media
/// item crosses a persistence boundary.
Map<String, dynamic>? _compactManualTimingOverride(Object? value) {
  if (value is! Map) return null;
  final source = Map<String, dynamic>.from(value);
  final compact = <String, dynamic>{};
  const fields = <String, String>{
    'bpm': 'bpm',
    'beat_anchor_ms': 'beatAnchorMs',
    'beats_per_bar': 'beatsPerBar',
    'downbeat_phase_index': 'downbeatPhaseIndex',
    'phrase_length_bars': 'phraseLengthBars',
    'confidence': 'confidence',
    'provenance': 'provenance',
    'revision': 'revision',
    'updated_at': 'updatedAt',
  };
  for (final entry in fields.entries) {
    final field = source[entry.key] ?? source[entry.value];
    if (field != null) compact[entry.key] = field;
  }
  return compact.isEmpty ? null : compact;
}

Object? _compactAnalysisValue(Object? value) {
  if (value is! Map) return value;
  final source = Map<String, dynamic>.from(value);
  if (source['value'] == null) return null;
  return {
    'value': source['value'],
    if (source['confidence'] != null) 'confidence': source['confidence'],
    if (source['provenance'] != null) 'provenance': source['provenance'],
  };
}

List<int> _boundedIntList(Object? value, int limit) {
  if (value is! List) return const [];
  final positions =
      value.whereType<num>().map((entry) => entry.toInt()).toList();
  if (positions.length <= limit) return List<int>.unmodifiable(positions);
  final headLength = limit ~/ 2;
  return List<int>.unmodifiable([
    ...positions.take(headLength),
    ...positions.skip(positions.length - (limit - headLength)),
  ]);
}

/// Persists and restores the [QueueSnapshot] via [SharedPreferences].
///
/// Saving an empty snapshot clears the stored value, so a stopped/cleared queue
/// does not resurrect on the next launch.
class QueuePersistenceStore {
  static const String storageKey = 'playback.queue.snapshot.v1';

  final Future<SharedPreferences> _prefs;
  final Future<String?> Function()? _accountIdProvider;
  bool _hasCachedAccountId = false;
  String? _cachedAccountId;
  Future<String?>? _accountIdLookup;
  int _accountIdGeneration = 0;
  Future<void> _saveChain = Future<void>.value();

  QueuePersistenceStore({
    Future<SharedPreferences>? prefs,
    Future<String?> Function()? accountIdProvider,
  })  : _prefs = prefs ?? SharedPreferences.getInstance(),
        _accountIdProvider = accountIdProvider;

  Future<void> save(QueueSnapshot snapshot) {
    final save = _saveChain.then((_) => _save(snapshot));
    _saveChain = save.catchError((Object _, StackTrace __) {});
    return save;
  }

  Future<void> _save(QueueSnapshot snapshot) async {
    final prefs = await _prefs;
    if (snapshot.isEmpty) {
      await prefs.remove(storageKey);
      return;
    }
    final accountId = await _accountId();
    final scopedSnapshot = snapshot.scopedTo(accountId);
    await prefs.setString(
      storageKey,
      scopedSnapshot.withAccountId(accountId).encode(),
    );
  }

  Future<QueueSnapshot> load() async {
    final prefs = await _prefs;
    final snapshot = QueueSnapshot.decode(prefs.getString(storageKey));
    final accountId = await _accountId();
    return snapshot.scopedTo(accountId);
  }

  /// Drops the session-scoped account cache after any authentication change.
  ///
  /// The generation guard prevents an in-flight lookup from repopulating the
  /// cache with credentials from the previous session.
  void invalidateAccountId() {
    _accountIdGeneration++;
    _hasCachedAccountId = false;
    _cachedAccountId = null;
    _accountIdLookup = null;
  }

  Future<String?> _accountId() {
    if (_hasCachedAccountId) return Future.value(_cachedAccountId);
    final pending = _accountIdLookup;
    if (pending != null) return pending;
    final lookup = _loadAccountId(_accountIdGeneration);
    _accountIdLookup = lookup;
    return lookup;
  }

  Future<String?> _loadAccountId(int generation) async {
    final accountId = await _accountIdProvider?.call();
    if (generation != _accountIdGeneration) {
      return _accountId();
    }
    _cachedAccountId = accountId;
    _hasCachedAccountId = true;
    _accountIdLookup = null;
    return accountId;
  }

  Future<void> clear() async {
    final prefs = await _prefs;
    await prefs.remove(storageKey);
  }
}

Map<String, dynamic> _scopePlaybackTrack(
  Map<String, dynamic> track, {
  required String? currentAccountId,
  required bool snapshotOwnedByCurrent,
}) {
  final scoped = Map<String, dynamic>.from(track);
  final metadataAccountId = scoped['likedAccountId'];
  final metadataOwnedByCurrent = currentAccountId != null &&
      (metadataAccountId == currentAccountId ||
          (metadataAccountId == null && snapshotOwnedByCurrent));
  if (!metadataOwnedByCurrent) {
    scoped
      ..remove('isLiked')
      ..remove('is_liked')
      ..remove('sourceUrl')
      ..remove('source_url')
      ..remove('likedAccountId');
  }
  return scoped;
}

/// Reads the stable backend user id from an OMP access token for local
/// account-scoping only. Authentication still belongs to the backend.
String? accountIdFromAccessToken(String? token) {
  if (token == null) return null;
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
    );
    if (payload is! Map) return null;
    final accountId = payload['user_id'];
    return accountId is String && accountId.isNotEmpty ? accountId : null;
  } catch (_) {
    return null;
  }
}
