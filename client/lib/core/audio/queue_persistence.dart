import 'dart:convert';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  return {
    'id': parsedId ?? item.id,
    'title': item.title,
    if (item.artist != null) 'artist': item.artist,
    if (item.album != null) 'album': item.album,
    'duration': item.duration?.inSeconds ?? 0,
    if (item.artUri != null) 'artwork_url': item.artUri.toString(),
    if (item.extras?['isLiked'] is bool) 'isLiked': item.extras?['isLiked'],
    if (item.extras?['likedAccountId'] is String)
      'likedAccountId': item.extras?['likedAccountId'],
    if (item.extras?['sourceUrl'] is String &&
        (item.extras?['sourceUrl'] as String).trim().isNotEmpty)
      'sourceUrl': (item.extras?['sourceUrl'] as String).trim(),
    if (item.extras?['analysisStatus'] != null)
      'analysisStatus': item.extras?['analysisStatus'],
    if (item.extras?['analysisSummary'] != null)
      'analysisSummary': item.extras?['analysisSummary'],
    if (item.extras?['analysisOverrides'] != null)
      'analysisOverrides': item.extras?['analysisOverrides'],
    if (item.extras?['analysisUpdatedAt'] != null)
      'analysisUpdatedAt': item.extras?['analysisUpdatedAt'],
  };
}

/// Persists and restores the [QueueSnapshot] via [SharedPreferences].
///
/// Saving an empty snapshot clears the stored value, so a stopped/cleared queue
/// does not resurrect on the next launch.
class QueuePersistenceStore {
  static const String storageKey = 'playback.queue.snapshot.v1';

  final Future<SharedPreferences> _prefs;
  final Future<String?> Function()? _accountIdProvider;

  QueuePersistenceStore({
    Future<SharedPreferences>? prefs,
    Future<String?> Function()? accountIdProvider,
  })  : _prefs = prefs ?? SharedPreferences.getInstance(),
        _accountIdProvider = accountIdProvider;

  Future<void> save(QueueSnapshot snapshot) async {
    final prefs = await _prefs;
    if (snapshot.isEmpty) {
      await prefs.remove(storageKey);
      return;
    }
    final accountId = await _accountIdProvider?.call();
    final scopedSnapshot = snapshot.scopedTo(accountId);
    await prefs.setString(
      storageKey,
      scopedSnapshot.withAccountId(accountId).encode(),
    );
  }

  Future<QueueSnapshot> load() async {
    final prefs = await _prefs;
    final snapshot = QueueSnapshot.decode(prefs.getString(storageKey));
    final accountId = await _accountIdProvider?.call();
    return snapshot.scopedTo(accountId);
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
