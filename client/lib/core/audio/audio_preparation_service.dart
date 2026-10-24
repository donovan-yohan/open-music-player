import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../cache/playback_cache_manager.dart';
import 'prepared_audio_asset.dart';
import 'local_audio_artifact_resolver.dart';
import 'signed_audio_url_service.dart';

enum AudioPreparationPriority { active, incoming, horizon }

class AudioPreparationCandidate {
  final SignedAudioDescriptor descriptor;
  final Duration startsIn;
  const AudioPreparationCandidate(this.descriptor, {required this.startsIn});
}

class AudioPreparationException implements Exception {
  final String code;
  final String message;
  const AudioPreparationException(this.code, this.message);
  @override
  String toString() => 'AudioPreparationException($code): $message';
}

class _PreparationJob {
  final AudioPreparationRequest request;
  final SignedAudioDescriptor descriptor;
  final AudioPreparationPriority priority;
  final int sequence;
  const _PreparationJob(
      this.request, this.descriptor, this.priority, this.sequence);
}

class AudioPreparationRequest {
  final _result = Completer<PreparedAudioAsset>();
  bool _cancelled = false;
  final _cancelToken = CancelToken();
  void Function()? _onCancel;
  PreparedAudioAsset? _asset;
  Future<PreparedAudioAsset> get future => _result.future;

  /// Cancels this subscriber, not another subscriber's shared transfer/pin.
  /// If delivery already occurred, releases this request's asset.
  Future<void> cancel() async {
    _cancelled = true;
    _cancelToken.cancel('preparation cancelled');
    _onCancel?.call();
    if (!_result.isCompleted) {
      _result.completeError(const AudioPreparationException(
          'cancelled', 'Preparation cancelled.'));
    }
    await _asset?.release();
  }
}

/// Local original preparation over the existing cache/shared downloader. This
/// is an opt-in integration seam, not another playback/session controller.
class AudioPreparationService {
  final PlaybackCacheManager _cache;

  final LocalAudioArtifactResolver? _explicitDownloads;

  AudioPreparationService({
    required PlaybackCacheManager cache,
    LocalAudioArtifactResolver? explicitDownloads,
    this.maxConcurrent = 2,
    this.maxQueued = 16,
  })  : assert(maxConcurrent > 0),
        assert(maxQueued >= 0),
        _cache = cache,
        _explicitDownloads = explicitDownloads;

  final int maxConcurrent;
  final int maxQueued;
  final List<_PreparationJob> _queue = [];
  int _sequence = 0;

  final Set<Future<void>> _running = {};
  final Set<AudioPreparationRequest> _requests = {};
  bool _disposed = false;

  /// The caller derives candidates from the accepted timeline near the chosen
  /// position. This does not scan a playlist prefix or own playback truth.
  /// Unknown sizes are not speculated under a byte budget.
  List<AudioPreparationRequest> prepareHorizon(
    Iterable<AudioPreparationCandidate> candidates, {
    required Duration maxAhead,
    required int maxAssets,
    required int maxBytes,
  }) {
    if (maxAssets < 0 || maxBytes < 0 || maxAhead.isNegative) {
      throw ArgumentError('Horizon budgets must be non-negative.');
    }
    final eligible = candidates
        .where((candidate) =>
            !candidate.startsIn.isNegative && candidate.startsIn <= maxAhead)
        .toList()
      ..sort((a, b) => a.startsIn.compareTo(b.startsIn));
    final result = <AudioPreparationRequest>[];
    final seen = <AudioAssetIdentity>{};
    var bytes = 0;
    for (final candidate in eligible) {
      if (result.length >= maxAssets) break;
      final size = candidate.descriptor.sizeBytes;
      if (size == null ||
          size <= 0 ||
          bytes + size > maxBytes ||
          !seen.add(AudioAssetIdentity.original(candidate.descriptor))) {
        continue;
      }
      bytes += size;
      result.add(prepareOriginal(candidate.descriptor,
          priority: AudioPreparationPriority.horizon));
    }
    return List.unmodifiable(result);
  }

  AudioPreparationRequest prepareOriginal(
    SignedAudioDescriptor descriptor, {
    AudioPreparationPriority priority = AudioPreparationPriority.incoming,
  }) {
    final request = AudioPreparationRequest();
    if (_disposed) {
      request._result.completeError(const AudioPreparationException(
          'disposed', 'Preparation service disposed.'));
      return request;
    }
    if (_running.length >= maxConcurrent && _queue.length >= maxQueued) {
      request._result.completeError(const AudioPreparationException(
          'queue_full', 'Preparation queue is full.'));
      return request;
    }
    _requests.add(request);
    final job = _PreparationJob(request, descriptor, priority, _sequence++);
    request._onCancel = () {
      if (_queue.remove(job)) _requests.remove(request);
    };
    _queue.add(job);
    _queue.sort((a, b) {
      final priority = a.priority.index.compareTo(b.priority.index);
      return priority == 0 ? a.sequence.compareTo(b.sequence) : priority;
    });
    _pump();
    return request;
  }

  void _pump() {
    while (!_disposed && _running.length < maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeAt(0);
      late final Future<void> task;
      task = _run(job.request, job.descriptor).whenComplete(() {
        _running.remove(task);
        _requests.remove(job.request);
        _pump();
      });
      _running.add(task);
    }
  }

  Future<void> _run(
      AudioPreparationRequest request, SignedAudioDescriptor descriptor) async {
    try {
      final asset = await _prepare(descriptor, request._cancelToken);
      request._asset = asset;
      if (request._cancelled) {
        await asset.release();
      } else {
        request._result.complete(asset);
      }
    } catch (error, stack) {
      if (!request._result.isCompleted) {
        request._result.completeError(error, stack);
      }
    } finally {
      // Cancelling a subscriber releases its pin immediately, but a shared
      // network transfer may still be running. Do not free this worker and
      // thereby exceed maxConcurrent with abandoned transfers.
      if (request._cancelled) {
        await _cache.waitForPendingWarm(descriptor.trackId);
      }
    }
  }

  Future<PreparedAudioAsset> _prepare(
      SignedAudioDescriptor descriptor, CancelToken token) async {
    final downloadPath =
        await _explicitDownloads?.localAudioPath(descriptor.trackId);
    if (downloadPath != null) {
      final file = File(downloadPath);
      final size = await file.exists() ? await file.length() : 0;
      if (size <= 0 ||
          (descriptor.sizeBytes != null &&
              descriptor.sizeBytes! > 0 &&
              descriptor.sizeBytes != size)) {
        throw const AudioPreparationException('invalid_download',
            'Explicit download failed local size verification.');
      }
      return PreparedAudioAsset(
        identity: AudioAssetIdentity.original(descriptor),
        localPath: downloadPath,
        sizeBytes: size,
        ownership: PreparedAudioOwnership.borrowedDownload,
        onRelease: () async {},
      );
    }
    final lease = await _cache.warmAndAcquire(descriptor.trackId, descriptor,
        cancelToken: token);
    if (lease == null) {
      throw const AudioPreparationException('local_unavailable',
          'Original audio could not fit or could not be verified locally.');
    }
    return PreparedAudioAsset(
      identity: AudioAssetIdentity.original(descriptor),
      localPath: lease.localPath,
      sizeBytes: lease.sizeBytes,
      ownership: PreparedAudioOwnership.playbackCache,
      onRelease: lease.release,
    );
  }

  Future<void> dispose() async {
    _disposed = true;
    await Future.wait(_requests.toList().map((request) => request.cancel()));
    await Future.wait(_running.toList());
  }
}
