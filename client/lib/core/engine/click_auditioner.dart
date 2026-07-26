import 'dart:async';

import 'click_audition_projection.dart';
import 'procedural_click_audio_source.dart';
import 'timeline_clock.dart';
import 'timeline_model.dart';

enum ClickAuditionStatus {
  inactive,
  disabled,
  unavailable,
  loading,
  ready,
  error,
  disposed,
}

class ClickAuditionState {
  const ClickAuditionState(
    this.status, {
    this.queueItemId,
    this.error,
  });

  final ClickAuditionStatus status;
  final String? queueItemId;
  final Object? error;
}

/// Lease-scoped click audition attached to the canonical playback clock.
///
/// All native output mutations pass through one serial operation queue. Lease,
/// content, and reconcile generations are checked around every awaited
/// mutation, so an invalidated async load can never seek, unmute, or play.
class ClickAuditioner {
  ClickAuditioner({
    required TimelineClock clock,
    ClickAudioOutputFactory outputFactory = JustAudioClickOutput.new,
    int driftToleranceMs = 90,
    int driftObservationIntervalMs = 2000,
  })  : _clock = clock,
        _outputFactory = outputFactory,
        _driftToleranceMs = driftToleranceMs,
        _driftObservationIntervalMs = driftObservationIntervalMs {
    _subscriptions
      ..add(_clock.positionMsStream.listen(_onCanonicalPosition))
      ..add(_clock.isBufferingHeldStream.listen((_) => _scheduleReconcile(
            forceSeek: true,
          )));
  }

  final TimelineClock _clock;
  final ClickAudioOutputFactory _outputFactory;
  final int _driftToleranceMs;
  final int _driftObservationIntervalMs;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Set<Future<void>> _retirements = {};
  final StreamController<ClickAuditionState> _stateController =
      StreamController<ClickAuditionState>.broadcast();

  TimelineModel _model = TimelineModel();
  ClickAudioOutput? _output;
  ClickAuditionRequest? _request;
  ProjectedClickTrack? _projection;
  int _leaseGeneration = 0;
  int _contentGeneration = 0;
  int _projectedContentGeneration = -1;
  int _loadedContentGeneration = -1;
  int _failedContentGeneration = -1;
  int _reconcileGeneration = 0;
  int _modelReplacementGeneration = 0;
  int? _pendingModelReplacementGeneration;
  int? _lastObservedPositionMs;
  bool? _lastTargetActive;
  double? _loadedVolume;
  bool _disposed = false;
  Future<void> _operations = Future<void>.value();
  ClickAuditionState _state =
      const ClickAuditionState(ClickAuditionStatus.inactive);

  ClickAuditionState get state => _state;
  Stream<ClickAuditionState> get stateStream => _stateController.stream;

  ClickAuditionLease open(ClickAuditionRequest request) {
    if (_disposed) {
      throw StateError('ClickAuditioner is disposed.');
    }
    final leaseId = ++_leaseGeneration;
    _request = request;
    _invalidateContent();
    final lease = ClickAuditionLease._(this, leaseId);
    lease._settled = _scheduleReconcile(forceSeek: true);
    return lease;
  }

  /// Invalidates the old model and detaches its native output synchronously.
  ///
  /// The caller must finish loading the canonical mix before calling
  /// [completeModelReplacement]. While a replacement is pending, lease and
  /// transport updates remain fail-closed and cannot create auxiliary output.
  int beginModelReplacement(TimelineModel model) {
    if (_disposed) return -1;
    final replacementGeneration = ++_modelReplacementGeneration;
    _pendingModelReplacementGeneration = replacementGeneration;
    _model = model;
    _invalidateContent();
    return replacementGeneration;
  }

  Future<void> completeModelReplacement(int replacementGeneration) {
    if (_disposed ||
        replacementGeneration < 0 ||
        replacementGeneration != _pendingModelReplacementGeneration) {
      return Future<void>.value();
    }
    _pendingModelReplacementGeneration = null;
    return _scheduleReconcile(forceSeek: true);
  }

  /// Backward-compatible single-call replacement for metadata-only callers.
  Future<void> replaceModel(TimelineModel model) {
    final replacementGeneration = beginModelReplacement(model);
    return completeModelReplacement(replacementGeneration);
  }

  /// Reconciles an explicit engine transport transition.
  Future<void> transportChanged({bool forceSeek = false}) async {
    if (_disposed) return;
    // TimelineClock broadcasts are asynchronous. Yield once so the explicit
    // engine callback is the newest generation and its returned future covers
    // the final play/pause/seek reconciliation.
    await Future<void>.delayed(Duration.zero);
    if (_disposed) return;
    await _scheduleReconcile(forceSeek: forceSeek);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _leaseGeneration++;
    _request = null;
    _contentGeneration++;
    _reconcileGeneration++;
    _detachOutput();
    _emit(const ClickAuditionState(ClickAuditionStatus.disposed));
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await Future.wait(_retirements.toList(growable: false));
    await _stateController.close();
  }

  bool _isCurrentLease(int leaseId) =>
      !_disposed && leaseId == _leaseGeneration;

  Future<void> _updateLease(
    int leaseId,
    ClickAuditionRequest request,
  ) {
    if (!_isCurrentLease(leaseId)) return Future<void>.value();
    final previous = _request;
    _request = request;
    if (previous == null || !previous.hasSameAudioContentAs(request)) {
      _invalidateContent();
      return _scheduleReconcile(forceSeek: true);
    }
    return _scheduleReconcile();
  }

  Future<void> _releaseLease(int leaseId) {
    if (!_isCurrentLease(leaseId)) return Future<void>.value();
    _leaseGeneration++;
    _request = null;
    _invalidateContent();
    return _scheduleReconcile(forceSeek: true);
  }

  void _invalidateContent() {
    _contentGeneration++;
    _projection = null;
    _projectedContentGeneration = -1;
    _failedContentGeneration = -1;
    _lastObservedPositionMs = null;
    _lastTargetActive = null;
    _loadedVolume = null;
    _detachOutput();

    // A native setAudioSource call may still be unwinding on the retired
    // output. New content gets a fresh output and operation lane immediately;
    // stale work retains only its detached output and fails generation checks
    // before any post-load mutation.
    _operations = Future<void>.value();
  }

  Future<void> _scheduleReconcile({bool forceSeek = false}) {
    if (_disposed) return Future<void>.value();
    final reconcileGeneration = ++_reconcileGeneration;
    final contentGeneration = _contentGeneration;
    final leaseGeneration = _leaseGeneration;
    final next = _operations.then((_) => _reconcile(
          reconcileGeneration: reconcileGeneration,
          contentGeneration: contentGeneration,
          leaseGeneration: leaseGeneration,
          forceSeek: forceSeek,
        ));
    _operations = next.catchError((Object _) {
      // _reconcile turns native failures into state. This keeps the operation
      // queue live if a platform implementation still throws unexpectedly.
    });
    return next;
  }

  Future<void> _reconcile({
    required int reconcileGeneration,
    required int contentGeneration,
    required int leaseGeneration,
    required bool forceSeek,
  }) async {
    if (!_isCurrent(
      reconcileGeneration,
      contentGeneration,
      leaseGeneration,
    )) {
      return;
    }

    final request = _request;
    if (request == null) {
      _detachOutput();
      if (_isCurrent(
        reconcileGeneration,
        contentGeneration,
        leaseGeneration,
      )) {
        _emit(const ClickAuditionState(ClickAuditionStatus.inactive));
      }
      return;
    }
    if (!request.hasAudibleClicks) {
      _detachOutput();
      if (_isCurrent(
        reconcileGeneration,
        contentGeneration,
        leaseGeneration,
      )) {
        _emit(ClickAuditionState(
          ClickAuditionStatus.disabled,
          queueItemId: request.queueItemId,
        ));
      }
      return;
    }
    if (_pendingModelReplacementGeneration != null) {
      _detachOutput();
      if (_isCurrent(
        reconcileGeneration,
        contentGeneration,
        leaseGeneration,
      )) {
        _emit(ClickAuditionState(
          ClickAuditionStatus.loading,
          queueItemId: request.queueItemId,
        ));
      }
      return;
    }

    final projection = _projectionFor(contentGeneration, request);
    final positionMs = _clock.positionMs;
    if (projection == null ||
        positionMs < projection.timelineStartMs ||
        positionMs >= projection.timelineEndMs) {
      _detachOutput();
      _operations = Future<void>.value();
      _lastTargetActive = false;
      if (_isCurrent(
        reconcileGeneration,
        contentGeneration,
        leaseGeneration,
      )) {
        _emit(ClickAuditionState(
          ClickAuditionStatus.unavailable,
          queueItemId: request.queueItemId,
        ));
      }
      return;
    }
    _lastTargetActive = true;
    if (_failedContentGeneration == contentGeneration) return;

    final output = _output ??= _createOutput(
      contentGeneration,
      leaseGeneration,
    );
    final expectedPositionMs = positionMs - projection.timelineStartMs;
    try {
      final needsLoad =
          _loadedContentGeneration != contentGeneration || !output.isLoaded;
      if (needsLoad) {
        _emit(ClickAuditionState(
          ClickAuditionStatus.loading,
          queueItemId: request.queueItemId,
        ));
        await output.load(
          projection,
          initialPositionMs: expectedPositionMs,
        );
        if (!_isCurrentOutputContent(
          output,
          contentGeneration,
          leaseGeneration,
        )) {
          return;
        }
        _loadedContentGeneration = contentGeneration;
        if (!_isCurrent(
          reconcileGeneration,
          contentGeneration,
          leaseGeneration,
        )) {
          return;
        }
        forceSeek = false;
      }

      if (needsLoad || _loadedVolume != request.volume) {
        await output.setVolume(request.volume);
        if (!_isCurrent(
          reconcileGeneration,
          contentGeneration,
          leaseGeneration,
        )) {
          return;
        }
        _loadedVolume = request.volume;
      }

      final actualPositionMs = output.positionMs;
      final driftMs = actualPositionMs == null
          ? null
          : actualPositionMs - expectedPositionMs;
      if (forceSeek || driftMs == null || driftMs.abs() > _driftToleranceMs) {
        await output.seek(expectedPositionMs);
        if (!_isCurrent(
          reconcileGeneration,
          contentGeneration,
          leaseGeneration,
        )) {
          return;
        }
      }

      final shouldPlay =
          _clock.isPlaying && !_clock.isScrubbing && !_clock.isBufferingHeld;
      if (shouldPlay && !output.isPlaying) {
        await output.play();
      } else if (!shouldPlay && output.isPlaying) {
        await output.pause();
      }
      if (!_isCurrent(
        reconcileGeneration,
        contentGeneration,
        leaseGeneration,
      )) {
        return;
      }
      _emit(ClickAuditionState(
        ClickAuditionStatus.ready,
        queueItemId: request.queueItemId,
      ));
    } catch (error) {
      await _failCurrentOutput(
        output: output,
        contentGeneration: contentGeneration,
        leaseGeneration: leaseGeneration,
        error: error,
      );
    }
  }

  ClickAudioOutput _createOutput(
    int contentGeneration,
    int leaseGeneration,
  ) {
    final output = _outputFactory();
    output.setAsyncFailureHandler((error, _) {
      unawaited(
        _failCurrentOutput(
          output: output,
          contentGeneration: contentGeneration,
          leaseGeneration: leaseGeneration,
          error: error,
        ),
      );
    });
    return output;
  }

  Future<void> _failCurrentOutput({
    required ClickAudioOutput output,
    required int contentGeneration,
    required int leaseGeneration,
    required Object error,
  }) {
    if (!_isCurrentOutputContent(
      output,
      contentGeneration,
      leaseGeneration,
    )) {
      return Future<void>.value();
    }
    final queueItemId = _request?.queueItemId;
    _failedContentGeneration = contentGeneration;
    _reconcileGeneration++;
    _operations = Future<void>.value();
    return _detachOutput().then((_) {
      if (_disposed ||
          contentGeneration != _contentGeneration ||
          leaseGeneration != _leaseGeneration) {
        return;
      }
      _emit(ClickAuditionState(
        ClickAuditionStatus.error,
        queueItemId: queueItemId,
        error: error,
      ));
    });
  }

  ProjectedClickTrack? _projectionFor(
    int contentGeneration,
    ClickAuditionRequest request,
  ) {
    if (_projectedContentGeneration != contentGeneration) {
      _projection = projectClickAudition(model: _model, request: request);
      _projectedContentGeneration = contentGeneration;
    }
    return _projection;
  }

  Future<void> _detachOutput() {
    final output = _output;
    if (output == null) return Future<void>.value();
    output.setAsyncFailureHandler(null);
    _output = null;
    _loadedContentGeneration = -1;
    _loadedVolume = null;
    late final Future<void> retirement;
    retirement = _retireOutput(output).whenComplete(() {
      _retirements.remove(retirement);
    });
    _retirements.add(retirement);
    return retirement;
  }

  void _onCanonicalPosition(int positionMs) {
    if (_disposed || _clock.isScrubbing) return;
    final request = _request;
    final projection =
        request == null ? null : _projectionFor(_contentGeneration, request);
    final isTargetActive = projection != null &&
        positionMs >= projection.timelineStartMs &&
        positionMs < projection.timelineEndMs;
    final crossedTargetBoundary =
        _lastTargetActive != null && _lastTargetActive != isTargetActive;
    _lastTargetActive = isTargetActive;

    if (crossedTargetBoundary) {
      if (!isTargetActive) {
        _reconcileGeneration++;
        _detachOutput();
        _operations = Future<void>.value();
      }
      _lastObservedPositionMs = positionMs;
      _scheduleReconcile(forceSeek: true);
      return;
    }

    final observed = _lastObservedPositionMs;
    if (observed == null ||
        (positionMs - observed).abs() >= _driftObservationIntervalMs) {
      _lastObservedPositionMs = positionMs;
      _scheduleReconcile();
    }
  }

  Future<void> _retireOutput(ClickAudioOutput output) async {
    try {
      await output.stop();
    } catch (_) {
      // Disposal is still required when a platform stop races a pending load.
    }
    try {
      await output.dispose();
    } catch (_) {
      // The output is already detached and can never become current again.
    }
  }

  bool _isCurrent(
    int reconcileGeneration,
    int contentGeneration,
    int leaseGeneration,
  ) {
    return !_disposed &&
        reconcileGeneration == _reconcileGeneration &&
        contentGeneration == _contentGeneration &&
        leaseGeneration == _leaseGeneration;
  }

  bool _isCurrentOutputContent(
    ClickAudioOutput output,
    int contentGeneration,
    int leaseGeneration,
  ) {
    return !_disposed &&
        identical(_output, output) &&
        contentGeneration == _contentGeneration &&
        leaseGeneration == _leaseGeneration;
  }

  void _emit(ClickAuditionState state) {
    if (_state.status == state.status &&
        _state.queueItemId == state.queueItemId &&
        identical(_state.error, state.error)) {
      return;
    }
    _state = state;
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }
}

class ClickAuditionLease {
  ClickAuditionLease._(this._owner, this._leaseId);

  final ClickAuditioner _owner;
  final int _leaseId;
  Future<void> _settled = Future<void>.value();

  bool get isCurrent => _owner._isCurrentLease(_leaseId);

  /// Completion of the most recent open/update/dispose reconciliation.
  Future<void> get settled => _settled;

  Future<void> update(ClickAuditionRequest request) {
    _settled = _owner._updateLease(_leaseId, request);
    return _settled;
  }

  Future<void> dispose() {
    _settled = _owner._releaseLease(_leaseId);
    return _settled;
  }
}
