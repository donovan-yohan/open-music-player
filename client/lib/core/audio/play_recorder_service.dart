import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../api/api_client.dart';
import 'play_record_decider.dart';
import 'playback_session.dart';
import 'playback_state.dart';

/// Sink for a decided play event. Kept as a thin interface so the recorder can
/// be driven by a fake in tests and by the real backend in the app.
abstract class PlayEventSink {
  /// Records exactly one play. [contextType] is one of the backend-allowed
  /// values (playlist/album/artist/library/queue/search) or null when the
  /// queue was started without a context.
  Future<void> recordPlay({
    required int trackId,
    String? contextType,
    String? contextId,
  });
}

/// [PlayEventSink] that POSTs to `/me/plays` via the app [ApiClient].
class ApiPlayEventSink implements PlayEventSink {
  ApiPlayEventSink(this._api);

  final ApiClient _api;

  @override
  Future<void> recordPlay({
    required int trackId,
    String? contextType,
    String? contextId,
  }) async {
    final body = <String, dynamic>{'trackId': trackId};
    if (contextType != null && contextType.isNotEmpty) {
      body['contextType'] = contextType;
    }
    if (contextId != null && contextId.isNotEmpty) {
      body['contextId'] = contextId;
    }
    await _api.post<dynamic>('/me/plays', data: body);
  }
}

/// Wires a [PlayRecordDecider] to [PlaybackState.snapshotStream] and records
/// exactly one play per continuous listen once it crosses the threshold or the
/// track completes. Reading the atomic snapshot keeps completion events tied to
/// the item that completed, even if playback immediately advances to the next
/// item. Posting is retried on failure, and [reset] clears pending state on
/// logout / account switch.
class PlayRecorderService {
  PlayRecorderService(
    this._playback,
    this._sink, {
    PlayRecordDecider? decider,
    int maxRetries = 3,
    Duration retryBackoff = const Duration(seconds: 2),
  })  : _decider = decider ?? PlayRecordDecider(),
        _maxRetries = maxRetries,
        _retryBackoff = retryBackoff;

  final PlaybackState _playback;
  final PlayEventSink _sink;
  final PlayRecordDecider _decider;
  final int _maxRetries;
  final Duration _retryBackoff;

  final List<StreamSubscription<dynamic>> _subscriptions = [];
  bool _started = false;

  /// Begins observing playback. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    _subscriptions.addAll([
      _playback.snapshotStream.listen(_handleSnapshot),
    ]);
  }

  /// Clears pending/armed state so a play from one session is never attributed
  /// to the next. Call on logout or account switch.
  void reset() => _decider.reset();

  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _started = false;
  }

  void _handleSnapshot(PlaybackSnapshot snapshot) {
    _decider.onTrackChanged(snapshot.currentMediaItem?.id);
    _emit(_decider.onPosition(
      snapshot.localPosition,
      snapshot.localDuration,
    ));
    if (snapshot.processingState == ProcessingState.completed) {
      _emit(_decider.onCompleted());
    }
  }

  void _emit(String? trackId) {
    if (trackId == null) return;
    final id = int.tryParse(trackId);
    if (id == null || id <= 0) return;

    final context = _playback.playbackContext;
    // Fire-and-forget: playback must never block on the analytics POST.
    unawaited(_postWithRetry(
      trackId: id,
      contextType: context?.kind.name,
      contextId: context?.id,
    ));
  }

  Future<void> _postWithRetry({
    required int trackId,
    String? contextType,
    String? contextId,
  }) async {
    for (var attempt = 0; attempt <= _maxRetries; attempt++) {
      try {
        await _sink.recordPlay(
          trackId: trackId,
          contextType: contextType,
          contextId: contextId,
        );
        return;
      } catch (error) {
        if (attempt == _maxRetries) {
          if (kDebugMode) {
            debugPrint('Failed to record play for track $trackId: $error');
          }
          return;
        }
        await Future<void>.delayed(_retryBackoff * (attempt + 1));
      }
    }
  }
}
