import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../download/download_service.dart';
import 'prepared_stem_manifest.dart';

/// Scoped owner of encoded stem sets only. It neither indexes nor evicts
/// original-track cache/download files. No renderer/decoder is constructed here.
/// Use one instance per prepared-stem budget; release every returned lease.
class PreparedStemAssets {
  PreparedStemAssets({
    required Directory rootDirectory,
    AudioArtifactDownloader? downloader,
    DateTime Function()? now,
    this.maxBytes = 256 * 1024 * 1024,
    this.maxConcurrentAcquisitions = 2,
  })  : _root = rootDirectory,
        _downloader = downloader ?? defaultAudioArtifactDownloader(),
        _now = now ?? DateTime.now {
    if (maxBytes <= 0 ||
        maxBytes > 9007199254740991 ||
        maxConcurrentAcquisitions <= 0) {
      throw ArgumentError('invalid prepared stem resource limits');
    }
  }

  final int maxBytes;
  final int maxConcurrentAcquisitions;
  int _reservedBytes = 0;
  int _active = 0;

  final Directory _root;
  final AudioArtifactDownloader _downloader;
  final DateTime Function() _now;

  Future<PreparedStemLease> acquire(PreparedStemManifest manifest,
      {CancelToken? cancelToken}) async {
    if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
    final bytes = manifest.totalBytes;
    if (_active >= maxConcurrentAcquisitions) {
      throw StateError('prepared stem acquisition capacity');
    }
    if (bytes > maxBytes - _reservedBytes) {
      throw StateError('prepared stem byte budget');
    }
    // Reserve synchronously before any await: concurrent acquisitions and held
    // leases share the same budget. Busy callers retry, no unbounded job queue.
    _active++;
    _reservedBytes += bytes;
    Directory? owned;
    var transferred = false;
    final transferToken = CancelToken();
    if (cancelToken != null) {
      // Keep the slot until an uncooperative downloader really settles.
      unawaited(cancelToken.whenCancel.then((error) {
        if (!transferToken.isCancelled) transferToken.cancel(error);
      }));
    }
    try {
      await _root.create(recursive: true);
      final digest =
          crypto.sha256.convert(utf8.encode(manifest.identity)).toString();
      owned = await _root.createTemp('.staging-$digest-');
      for (final member in manifest.members.values) {
        if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
        if (!member.expiresAt.isAfter(_now())) {
          throw const FormatException('expired stem download URL');
        }
        final path = p.join(owned.path, '${member.channel}.opus');
        FormatException? overflow;
        try {
          await _downloader(member.url.toString(), path,
              cancelToken: transferToken, onProgress: (received, total) {
            if (received > member.bytes || total > member.bytes) {
              overflow =
                  const FormatException('stem download exceeds declared bytes');
              transferToken.cancel('stem byte limit');
            }
          });
        } catch (_) {
          if (overflow != null) throw overflow!;
          rethrow;
        }
        if (overflow != null) throw overflow!;
        if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
        final file = File(path);
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.file) {
          throw const FormatException(
              'stem member must be an owned regular file');
        }
        if (await file.length() != member.bytes ||
            (await crypto.sha256.bind(file.openRead()).first).toString() !=
                member.sha256) {
          throw const FormatException('stem member integrity failure');
        }
      }
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      owned = await owned.rename(p.join(_root.path,
          p.basename(owned.path).replaceFirst('.staging-', 'ready-')));
      if (cancelToken?.isCancelled == true) throw cancelToken!.cancelError!;
      final ownership =
          _StemSetOwnership(owned, manifest, () => _reservedBytes -= bytes);
      transferred = true;
      return PreparedStemLease._(ownership);
    } catch (_) {
      if (owned != null && await owned.exists()) {
        await owned.delete(recursive: true);
      }
      rethrow;
    } finally {
      _active--;
      if (!transferred) _reservedBytes -= bytes;
    }
  }
}

/// Local byte readiness, not decoder/sample-clock readiness. A retained handle
/// owns this immutable version path until its own idempotent release completes.
class PreparedStemLease {
  PreparedStemLease._(this._owner);
  final _StemSetOwnership _owner;
  bool _released = false;
  Future<void>? _release;
  PreparedStemManifest get manifest => _owner.manifest;
  Directory get directory => _owner.directory;

  /// Every verified member, including the hybrid drums reference.
  Map<String, Uri> get files => _owner.files;

  /// Disjoint render buses only. Hybrid intentionally excludes retained drums.
  Map<String, Uri> get channelFiles => Map.unmodifiable({
        for (final channel in manifest.channels) channel: files[channel]!,
      });
  PreparedStemLease retain() {
    if (_released) throw StateError('released prepared stem lease');
    _owner.references++;
    return PreparedStemLease._(_owner);
  }

  Future<void> release() {
    if (_release != null) return _release!;
    _released = true;
    return _release = _owner.release();
  }
}

class _StemSetOwnership {
  _StemSetOwnership(this.directory, this.manifest, this.onDeleted)
      : files = Map.unmodifiable({
          for (final channel in manifest.members.keys)
            channel: File(p.join(directory.path, '$channel.opus')).uri,
        });
  final Directory directory;
  final PreparedStemManifest manifest;
  final Map<String, Uri> files;
  final void Function() onDeleted;
  int references = 1;
  Future<void> release() async {
    if (--references == 0) {
      await directory.delete(recursive: true);
      onDeleted();
    }
  }
}
