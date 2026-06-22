import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio/local_audio_artifact_resolver.dart';
import '../audio/signed_audio_url_service.dart';
import '../download/download_service.dart'
    show AudioArtifactDownloader, defaultAudioArtifactDownloader;
import '../utils/file_utils.dart';
import 'playback_cache_entry.dart';
import 'playback_cache_store.dart';

// The byte-fetch contract is part of this manager's public constructor surface,
// so callers (and tests) can name it without importing the download package.
export '../download/download_service.dart' show AudioArtifactDownloader;

/// Resolves the on-device directory the playback cache stores artifacts in.
/// Injected so tests can target a temp directory instead of `path_provider`.
typedef PlaybackCacheDirectoryProvider = Future<String> Function();

/// Default cap for the playback cache. Small enough to keep a dogfood device
/// honest and to make eviction observable in tests when overridden lower.
const int defaultPlaybackCacheMaxBytes = 512 * 1024 * 1024;

/// The composite cache identity for a signed audio descriptor: the descriptor
/// metadata that survives signed-URL re-issuance (track id, storage key version,
/// ETag, object location) joined into one string. Stable across many short-lived
/// signed URLs for the same object; different after a backend object
/// replacement.
///
/// Entries are physically keyed by track id (one cached artifact per track);
/// staleness at play time is decided field-by-field via
/// [PlaybackCacheEntry.isStaleAgainstDescriptor] (so an omitted field is no
/// signal, not a key mismatch). This composite is the canonical human/equality
/// view of that identity.
String playbackCacheKey(SignedAudioDescriptor descriptor) {
  final parts = <String>['track:${descriptor.trackId}'];
  final skv = descriptor.storageKeyVersion;
  if (skv != null && skv.isNotEmpty) parts.add('skv:$skv');
  final etag = descriptor.etag;
  if (etag != null && etag.isNotEmpty) parts.add('etag:$etag');
  final obj = audioObjectIdentity(descriptor.url);
  if (obj != null) parts.add('obj:$obj');
  return parts.join('|');
}

/// The stable object location of a (signed) audio URL: scheme, host, and path
/// with the volatile query (signature, expiry) and fragment dropped. Returns
/// null when [url] has no usable location.
String? audioObjectIdentity(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return null;
  if (uri.authority.isEmpty && uri.path.isEmpty) return null;
  final scheme = uri.scheme.isEmpty ? '' : '${uri.scheme}://';
  return '$scheme${uri.authority}${uri.path}';
}

/// Bounded, evictable cache of recently/near-future playback artifacts.
///
/// Separate from explicit offline downloads in every dimension — own store, own
/// directory, own model — so eviction and [clear] can never delete a user's
/// downloads. A valid explicit download always wins: [warm] refuses to cache a
/// track that already has one (no duplication), and the resolver consults this
/// cache only for tracks without a download.
///
/// All disk work is best-effort: a cache failure (warm error, missing dir, IO
/// error) must never break playback — it degrades to a normal signed-URL fetch.
class PlaybackCacheManager {
  final PlaybackCacheStore _store;
  final AudioArtifactDownloader _downloader;
  final PlaybackCacheDirectoryProvider _cacheDirectoryProvider;

  /// Explicit-download resolver, consulted so cache warming never duplicates a
  /// user-owned download. Optional: when absent, the resolver's download-first
  /// ordering is the only guard.
  final LocalAudioArtifactResolver? _explicitDownloads;

  /// Hard upper bound on total cached bytes. Eviction runs after each warm.
  final int maxBytes;

  final DateTime Function() _clock;

  /// In-flight warms, keyed by track id, so concurrent plays of the same track
  /// share one download instead of racing to write the same file.
  final Map<int, Future<void>> _warming = {};

  /// Serializes commit/eviction critical sections (see [_commit]).
  Future<void> _commitChain = Future<void>.value();

  PlaybackCacheManager({
    required PlaybackCacheStore store,
    this.maxBytes = defaultPlaybackCacheMaxBytes,
    AudioArtifactDownloader? downloader,
    PlaybackCacheDirectoryProvider? cacheDirectoryProvider,
    LocalAudioArtifactResolver? explicitDownloads,
    DateTime Function()? clock,
  })  : _store = store,
        _downloader = downloader ?? defaultAudioArtifactDownloader(),
        _cacheDirectoryProvider =
            cacheDirectoryProvider ?? _defaultCacheDirectoryProvider,
        _explicitDownloads = explicitDownloads,
        _clock = clock ?? DateTime.now;

  static Future<String> _defaultCacheDirectoryProvider() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'playback_cache'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// Returns the path to valid cached bytes for [trackId] when they still match
  /// [descriptor], else null. A metadata mismatch, a missing file, or a
  /// size mismatch invalidates (removes) the entry so the caller falls back to
  /// the signed URL instead of playing stale bytes. A hit bumps the entry's
  /// recency so it survives eviction longer.
  Future<String?> get(int trackId, SignedAudioDescriptor descriptor) async {
    try {
      final entry = await _store.getEntry(trackId);
      if (entry == null) return null;

      if (entry.isStaleAgainstDescriptor(
        etag: descriptor.etag,
        storageKeyVersion: descriptor.storageKeyVersion,
        sizeBytes: descriptor.sizeBytes,
        urlIdentity: audioObjectIdentity(descriptor.url),
      )) {
        await _invalidate(entry);
        return null;
      }

      final file = File(entry.localPath);
      if (!await file.exists()) {
        await _invalidate(entry);
        return null;
      }
      if (entry.fileSizeBytes > 0) {
        final actualSize = await file.length();
        if (actualSize != entry.fileSizeBytes) {
          await _invalidate(entry);
          return null;
        }
      }

      await _store.touchEntry(trackId, _clock().toUtc());
      return entry.localPath;
    } catch (error) {
      // Cache hits are an optimization. If disk or store access fails, degrade
      // to normal signed-URL playback rather than crashing resolution.
      if (kDebugMode) {
        debugPrint('Playback cache get failed for track $trackId: $error');
      }
      return null;
    }
  }

  /// Populates the cache for [trackId] from [descriptor] for a future play.
  /// Best-effort and deduplicated: concurrent calls share one transfer, an
  /// already-valid entry is skipped, and a track with a valid explicit download
  /// is never cached (it already wins playback). Enforces the size cap after a
  /// successful warm. Never throws.
  ///
  /// [protect] is the set of track ids currently in use (served from cache this
  /// resolve) that cap enforcement must not evict — so speculatively warming
  /// later tracks can never delete the artifact a track is playing right now.
  Future<void> warm(
    int trackId,
    SignedAudioDescriptor descriptor, {
    Set<int> protect = const {},
  }) {
    final existing = _warming[trackId];
    if (existing != null) return existing;
    final future = _warm(trackId, descriptor, protect);
    _warming[trackId] = future;
    return future.whenComplete(() => _warming.remove(trackId));
  }

  Future<void> _warm(
    int trackId,
    SignedAudioDescriptor descriptor,
    Set<int> protect,
  ) async {
    String? partPath;
    try {
      // Explicit download wins: never duplicate user-owned bytes into the cache.
      if (await _explicitDownloads?.localAudioPath(trackId) != null) return;
      // Already cached and still valid? `get` revalidates and, if stale, evicts
      // the old entry so the fresh transfer below replaces it.
      if (await get(trackId, descriptor) != null) return;

      final dir = await _cacheDirectoryProvider();
      await Directory(dir).create(recursive: true);
      final localPath = p.join(dir, '$trackId.audio');
      partPath = '$localPath.part';

      // Stage into `.part` so an aborted transfer never lands at the final path
      // where `get` could mistake it for a complete artifact.
      await deleteFileQuietly(partPath);
      await _downloader(descriptor.url, partPath);

      final partFile = File(partPath);
      final actualSize = await partFile.exists() ? await partFile.length() : 0;
      if (actualSize <= 0) {
        await deleteFileQuietly(partPath);
        return;
      }
      // A truncated transfer must not be cached: it would only ever serve short
      // bytes. Drop it and let the next play re-fetch.
      final expected = descriptor.sizeBytes;
      if (expected != null && expected > 0 && actualSize != expected) {
        await deleteFileQuietly(partPath);
        return;
      }
      // A single artifact larger than the whole cap can never fit; caching it
      // would evict everything else and still overflow. Skip it.
      if (actualSize > maxBytes) {
        await deleteFileQuietly(partPath);
        return;
      }

      await deleteFileQuietly(localPath);
      await partFile.rename(localPath);

      final entry = PlaybackCacheEntry(
        trackId: trackId,
        localPath: localPath,
        fileSizeBytes: actualSize,
        etag: descriptor.etag,
        storageKeyVersion: descriptor.storageKeyVersion,
        expectedSizeBytes: descriptor.sizeBytes,
        urlIdentity: audioObjectIdentity(descriptor.url),
        lastAccessedAt: _clock().toUtc(),
      );

      // Commit + cap enforcement run as one serialized critical section so
      // concurrent warms can't read each other's half-applied totals and
      // over-evict. The just-warmed entry is MRU, so it survives unless it
      // genuinely cannot fit alongside the in-use [protect] set.
      await _commit(() async {
        await _store.upsertEntry(entry);
        await _enforceCap(protect: protect);
      });
    } catch (error) {
      if (partPath != null) {
        await deleteFileQuietly(partPath);
      }
      // Cache warming must never break playback.
      if (kDebugMode) {
        debugPrint('Playback cache warm failed for track $trackId: $error');
      }
    }
  }

  /// Evicts least-recently-used cache entries until total bytes are within
  /// [maxBytes]. Track ids in [protect] (in-use this resolve) are never evicted.
  /// Only ever touches cache-owned rows/files; explicit downloads live in a
  /// different store/directory and are structurally unreachable here.
  Future<void> _enforceCap({Set<int> protect = const {}}) async {
    var total = await _store.totalSizeBytes();
    if (total <= maxBytes) return;

    final entries = await _store.getAllEntries()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));

    for (final entry in entries) {
      if (total <= maxBytes) break;
      if (protect.contains(entry.trackId)) continue;
      await _invalidate(entry);
      total -= entry.fileSizeBytes;
    }
  }

  /// Removes every cache artifact and row. The cache owns its directory
  /// outright, so sweeping it clears every artifact (including an orphan `.part`
  /// from an interrupted warm). Touches only the cache directory and store, so
  /// explicit offline downloads are untouched by design. Runs in the same
  /// serialized section as warms (so it can't race a half-applied commit) and
  /// clears the table even if directory resolution fails.
  Future<void> clear() {
    return _commit(() async {
      try {
        await sweepDirectoryFiles(await _cacheDirectoryProvider());
      } catch (_) {
        // Best-effort sweep; still clear the table below.
      }
      await _store.deleteAll();
    });
  }

  Future<int> currentSizeBytes() => _store.totalSizeBytes();

  Future<void> _invalidate(PlaybackCacheEntry entry) async {
    await deleteFileQuietly(entry.localPath);
    await deleteFileQuietly('${entry.localPath}.part');
    await _store.deleteEntry(entry.trackId);
  }

  /// Serializes store-mutating critical sections (warm commit, clear) so their
  /// read-modify-write cycles never interleave. Errors are isolated so one
  /// failed action does not wedge the chain.
  Future<void> _commit(Future<void> Function() action) {
    final next = _commitChain.then((_) => action());
    _commitChain = next.then((_) {}, onError: (_) {});
    return next;
  }
}
