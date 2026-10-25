import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../audio/audio_file_extension.dart';
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
/// The store indexes the current version by track id; leased older versions
/// retain their distinct paths in the manager's retirement registry. Legacy
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

/// One independent pin on verified cache-owned bytes. Release only after the
/// decoder/transport has stopped using the path. Release is idempotent.
class PlaybackCacheLease {
  final String localPath;
  final int sizeBytes;
  final Future<void> Function() _onRelease;
  Future<void>? _released;

  PlaybackCacheLease._(this.localPath, this.sizeBytes, this._onRelease);

  Future<void> release() => _released ??= _onRelease();
}

/// Snapshot of clear completion. Pinned files are retired, not deleted, until
/// their last owner releases. Failed deletions are reported, never called done.
class PlaybackCacheClearResult {
  final int deferredFiles;
  final int deferredBytes;
  final int failedFiles;
  final int pendingTransfers;

  const PlaybackCacheClearResult({
    required this.deferredFiles,
    required this.deferredBytes,
    this.failedFiles = 0,
    this.pendingTransfers = 0,
  });

  bool get isComplete =>
      deferredFiles == 0 && failedFiles == 0 && pendingTransfers == 0;
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

  /// Transfers share only an identical immutable identity, never just a track.
  final Map<String, Future<void>> _warming = {};
  final Map<int, Future<void>> _trackTails = {};
  final Map<String, CancelToken> _transfers = {};
  int _epoch = 0;
  final Map<int, int> _incoming = {};

  /// Reserves incoming bytes across warm -> verification -> pin acquisition.
  /// Null means unavailable (including insufficient room beside active leases).
  Future<PlaybackCacheLease?> warmAndAcquire(
    int trackId,
    SignedAudioDescriptor descriptor, {
    CancelToken? cancelToken,
  }) async {
    if (trackId != descriptor.trackId || cancelToken?.isCancelled == true) {
      return null;
    }
    final epoch = _epoch;
    _incoming[trackId] = (_incoming[trackId] ?? 0) + 1;
    try {
      final warming = warm(trackId, descriptor);
      if (cancelToken == null) {
        await warming;
      } else {
        await Future.any<void>([
          warming,
          cancelToken.whenCancel.then<void>((_) {}),
        ]);
      }
      return await _commit(() async {
        if (epoch != _epoch || cancelToken?.isCancelled == true) return null;
        return _acquire(trackId, descriptor);
      });
    } finally {
      final remaining = (_incoming[trackId] ?? 1) - 1;
      if (remaining == 0) {
        _incoming.remove(trackId);
      } else {
        _incoming[trackId] = remaining;
      }
    }
  }

  /// Waits for transfers already scheduled for this track; starts no download.
  /// Useful to keep bounded worker slots occupied after subscriber cancellation.
  Future<void> waitForPendingWarm(int trackId) =>
      _trackTails[trackId] ?? Future<void>.value();

  /// Serializes commit/eviction critical sections (see [_commit]).
  Future<void> _commitChain = Future<void>.value();

  final Map<String, int> _pins = {};
  // The SQLite surface intentionally retains one current row per track. Older
  // leased versions live here until release; process death also ends all leases.
  final Map<String, PlaybackCacheEntry> _retired = {};
  int _nextFileId = DateTime.now().microsecondsSinceEpoch;

  Future<PlaybackCacheLease?> acquire(
    int trackId,
    SignedAudioDescriptor descriptor,
  ) =>
      _commit(() => _acquire(trackId, descriptor));

  Future<PlaybackCacheLease?> _acquire(
    int trackId,
    SignedAudioDescriptor descriptor,
  ) async {
    if (trackId != descriptor.trackId) return null;
    final path = await _get(trackId, descriptor);
    if (path == null) return null;
    final entry = (await _store.getEntry(trackId))!;
    return _pin(entry);
  }

  /// Pins an already-resolved path only if it exactly names a verified current
  /// cache row. No basename/track-id inference and no external-file ownership.
  /// Failed verification leaves both the row and bytes untouched.
  Future<PlaybackCacheLease?> acquirePath(String path) => _commit(() async {
        try {
          final entries = await _store.getAllEntries();
          for (final entry in entries) {
            if (entry.localPath != path) continue;
            final file = File(path);
            if (!await file.exists()) return null;
            final size = await file.length();
            if (size <= 0 ||
                size != entry.fileSizeBytes ||
                (entry.expectedSizeBytes != null &&
                    entry.expectedSizeBytes! > 0 &&
                    size != entry.expectedSizeBytes)) {
              return null;
            }
            await _store.touchEntry(entry.trackId, _clock().toUtc());
            return _pin(entry);
          }
        } catch (_) {
          // Like descriptor acquisition, store/IO failure cannot claim a pin.
        }
        return null;
      });

  PlaybackCacheLease _pin(PlaybackCacheEntry entry) {
    final path = entry.localPath;
    _pins[path] = (_pins[path] ?? 0) + 1;
    return PlaybackCacheLease._(
        path,
        entry.fileSizeBytes,
        () => _commit(() async {
              final remaining = (_pins[path] ?? 1) - 1;
              if (remaining > 0) {
                _pins[path] = remaining;
              } else {
                _pins.remove(path);
                final retired = _retired[path];
                if (retired != null) await _deleteRetired(retired);
              }
            }));
  }

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
  /// recency so it survives eviction longer. This legacy lookup does NOT pin
  /// the file; transports must use [acquire] or [warmAndAcquire] instead.
  Future<String?> get(int trackId, SignedAudioDescriptor descriptor) =>
      _commit(() => _get(trackId, descriptor));

  Future<String?> _get(int trackId, SignedAudioDescriptor descriptor) async {
    try {
      if (trackId != descriptor.trackId) return null;
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
      final actualSize = await file.length();
      if (actualSize <= 0 ||
          actualSize != entry.fileSizeBytes ||
          (descriptor.sizeBytes != null &&
              descriptor.sizeBytes! > 0 &&
              actualSize != descriptor.sizeBytes)) {
        await _invalidate(entry);
        return null;
      }

      // Upgrade only verified legacy rows. Never rename bytes beneath a native
      // decoder's exact-path lease: fall back to HTTP until the last release.
      final extension = audioFileExtension(descriptor);
      if (p.extension(entry.localPath) == '.audio' && extension != 'audio') {
        if (_pins.containsKey(entry.localPath)) return null;
        return await _migrateLegacy(entry, extension);
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

  // Runs inside _get's commit lane. Rename costs no extra cache bytes and is
  // reversible if publication fails. Preserve sparse legacy identity exactly;
  // a newer descriptor does not retroactively authenticate missing metadata.
  Future<String?> _migrateLegacy(
      PlaybackCacheEntry entry, String extension) async {
    final dir = await _cacheDirectoryProvider();
    if (!p.equals(p.absolute(p.dirname(entry.localPath)), p.absolute(dir))) {
      return null;
    }
    final target = p.join(dir, '${entry.trackId}-${_nextFileId++}.$extension');
    if (await File(target).exists()) return null;
    final file = await File(entry.localPath).rename(target);
    try {
      await _store.upsertEntry(PlaybackCacheEntry(
        trackId: entry.trackId,
        localPath: target,
        fileSizeBytes: entry.fileSizeBytes,
        etag: entry.etag,
        storageKeyVersion: entry.storageKeyVersion,
        expectedSizeBytes: entry.expectedSizeBytes,
        urlIdentity: entry.urlIdentity,
        lastAccessedAt: _clock().toUtc(),
      ));
    } catch (_) {
      await file.rename(entry.localPath);
      rethrow;
    }
    return target;
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
    if (trackId != descriptor.trackId) return Future<void>.value();
    final epoch = _epoch;
    final key =
        '$epoch:${playbackCacheKey(descriptor)}:${descriptor.sizeBytes}';
    final existing = _warming[key];
    if (existing != null) return existing;
    final token = CancelToken();
    _transfers[key] = token;
    // Order replacements of the same track while other tracks transfer in
    // parallel. A later version cannot finish before and be replaced by an old one.
    final prior = _trackTails[trackId] ?? Future<void>.value();
    late final Future<void> future;
    future = prior
        .then((_) => _warm(trackId, descriptor, protect, epoch, token))
        .whenComplete(() {
      _warming.remove(key);
      _transfers.remove(key);
      if (identical(_trackTails[trackId], future)) _trackTails.remove(trackId);
    });
    _warming[key] = future;
    _trackTails[trackId] = future;
    return future;
  }

  Future<void> _warm(
    int trackId,
    SignedAudioDescriptor descriptor,
    Set<int> protect,
    int epoch,
    CancelToken token,
  ) async {
    String? partPath;
    try {
      if (epoch != _epoch || token.isCancelled) return;
      // Explicit download wins: never duplicate user-owned bytes into the cache.
      if (await _explicitDownloads?.localAudioPath(trackId) != null) return;
      // Already cached and still valid? `get` revalidates and, if stale, evicts
      // the old entry so the fresh transfer below replaces it.
      if (await get(trackId, descriptor) != null) return;
      // A retained row could not be migrated safely (for example it is pinned).
      // Re-downloading those same bytes cannot fix that; keep ownership intact.
      if (await _commit(() => _store.getEntry(trackId)) != null) return;

      final dir = await _cacheDirectoryProvider();
      await Directory(dir).create(recursive: true);
      final extension = audioFileExtension(descriptor);
      final localPath = p.join(dir, '$trackId.$extension');
      partPath = '$localPath-${_nextFileId++}.part';

      // Stage into `.part` so an aborted transfer never lands at the final path
      // where `get` could mistake it for a complete artifact.
      await deleteFileQuietly(partPath);
      await _downloader(descriptor.url, partPath, cancelToken: token);
      if (epoch != _epoch || token.isCancelled) {
        await deleteFileQuietly(partPath);
        return;
      }

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

      // A retired/leased version must never be overwritten by replacement.
      // Keep the historical initial filename when safe for existing consumers.
      final finalPath =
          _pins.containsKey(localPath) || _retired.containsKey(localPath)
              ? p.join(dir, '$trackId-${_nextFileId++}.$extension')
              : localPath;

      final entry = PlaybackCacheEntry(
        trackId: trackId,
        localPath: finalPath,
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
        if (epoch != _epoch || token.isCancelled) {
          await deleteFileQuietly(partPath!);
          return;
        }
        // Reject admission rather than evicting active/incoming bytes or
        // silently exceeding the cap. Retired leased versions count too.
        final entries = await _store.getAllEntries();
        var fixedBytes =
            _retired.values.fold<int>(0, (sum, e) => sum + e.fileSizeBytes);
        for (final e in entries) {
          if (_pins.containsKey(e.localPath) ||
              _incoming.containsKey(e.trackId) ||
              protect.contains(e.trackId)) {
            fixedBytes += e.fileSizeBytes;
          }
        }
        if (fixedBytes + actualSize > maxBytes) {
          await deleteFileQuietly(partPath!);
          return;
        }
        await deleteFileQuietly(finalPath);
        await partFile.rename(finalPath);
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
    var total = await _store.totalSizeBytes() +
        _retired.values.fold<int>(0, (sum, e) => sum + e.fileSizeBytes);
    if (total <= maxBytes) return;

    final entries = await _store.getAllEntries()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));

    for (final entry in entries) {
      if (total <= maxBytes) break;
      if (protect.contains(entry.trackId) ||
          _pins.containsKey(entry.localPath) ||
          _incoming.containsKey(entry.trackId)) {
        continue;
      }
      await _invalidate(entry);
      if (!_retired.containsKey(entry.localPath)) total -= entry.fileSizeBytes;
    }
  }

  /// Retires current rows, fences/cancels pending warms, and sweeps unpinned
  /// cache files including orphan parts. Pinned versions survive until final
  /// release. Reports deferred bytes, pending transfers and deletion failures;
  /// callers must inspect [PlaybackCacheClearResult.isComplete]. Explicit
  /// downloads live outside this cache and are never deleted here.
  Future<PlaybackCacheClearResult> clear() {
    _epoch++;
    for (final token in _transfers.values) {
      token.cancel('cache cleared');
    }
    return _commit(() async {
      for (final entry in await _store.getAllEntries()) {
        await _invalidate(entry);
      }
      for (final entry in _retired.values.toList()) {
        if (!_pins.containsKey(entry.localPath)) await _deleteRetired(entry);
      }
      var failedFiles =
          _retired.keys.where((path) => !_pins.containsKey(path)).length;
      try {
        final directory = Directory(await _cacheDirectoryProvider());
        if (await directory.exists()) {
          await for (final entity in directory.list(followLinks: false)) {
            if (entity is File &&
                !_pins.containsKey(entity.path) &&
                !_retired.containsKey(entity.path)) {
              try {
                await entity.delete();
              } catch (_) {
                failedFiles++;
              }
            }
          }
        }
      } catch (_) {
        failedFiles++;
      }
      final deferred =
          _retired.values.where((e) => _pins.containsKey(e.localPath));
      return PlaybackCacheClearResult(
        deferredFiles: deferred.length,
        deferredBytes: deferred.fold(0, (sum, e) => sum + e.fileSizeBytes),
        failedFiles: failedFiles,
        pendingTransfers: _transfers.length,
      );
    });
  }

  Future<int> currentSizeBytes() => _commit(() async =>
      await _store.totalSizeBytes() +
      _retired.values.fold<int>(0, (sum, e) => sum + e.fileSizeBytes));

  Future<void> _invalidate(PlaybackCacheEntry entry) async {
    await _store.deleteEntry(entry.trackId);
    _retired[entry.localPath] = entry;
    if (!_pins.containsKey(entry.localPath)) await _deleteRetired(entry);
  }

  Future<void> _deleteRetired(PlaybackCacheEntry entry) async {
    try {
      final file = File(entry.localPath);
      if (await file.exists()) await file.delete();
      _retired.remove(entry.localPath);
    } catch (_) {/* Retain the bytes in accounting; clear can retry. */}
  }

  /// Serializes store-mutating critical sections (warm commit, clear) so their
  /// read-modify-write cycles never interleave. Errors are isolated so one
  /// failed action does not wedge the chain.
  Future<T> _commit<T>(Future<T> Function() action) {
    final next = _commitChain.then((_) => action());
    _commitChain = next.then((_) {}, onError: (_) {});
    return next;
  }
}
