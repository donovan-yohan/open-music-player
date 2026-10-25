import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';
import '../audio/playback_session.dart';
import '../storage/secure_storage.dart';
import 'connect_models.dart';
import 'connect_service.dart';

enum DevicePresenceStatus { detached, connecting, online, offline, disabled }

/// Captured capability of this observer's existing writer, never a new device.
/// Secrets are private and can only be sent through the canonical scoped API.
class JamHostProof {
  JamHostProof._(this._owner, this._generation, this._device, this._lease,
      this._secret, this.scope);
  final DevicePresenceService _owner;
  final int _generation;
  final String _device, _lease, _secret;
  final AuthSessionScope scope;
  bool get stillCurrent =>
      _generation == _owner._generation &&
      _owner._canRun &&
      _owner._deviceId == _device &&
      _owner._leaseId == _lease &&
      _owner._secret == _secret &&
      _owner._status != DevicePresenceStatus.disabled &&
      (_owner._leaseExpiresAt?.isAfter(DateTime.now().toUtc()) ?? false);

  Future<Response<dynamic>> request(String path,
      {required String method,
      Map<String, Object?> data = const {},
      CancelToken? cancelToken}) {
    if (!stillCurrent) throw StateError('Host connection changed');
    return _owner.service.api.sessionRequest(scope, path,
        method: method,
        cancelToken: cancelToken,
        data: {
          ...data,
          'hostDeviceId': _device,
          'leaseId': _lease,
          'writerSecret': _secret
        });
  }

  @override
  String toString() => 'JamHostProof';
}

/// Metadata observer only: never owns a player, queue or transport command.
class DevicePresenceService extends ChangeNotifier {
  DevicePresenceService(this.service,
      {required this.label, required this.platform});
  final ConnectService service;
  final String label, platform;
  final Random _random = Random.secure();
  ValueStream<PlaybackSnapshot>? _source;
  AuthSessionScope? _scope;
  StreamSubscription<PlaybackSnapshot>? _subscription;
  CancelToken? _cancel;
  Timer? _rateTimer, _heartbeatTimer, _retryTimer;
  String? _deviceId, _secret, _leaseId, _sentSemantic;
  ConnectPlayback? _latest;
  int _sequence = 0, _generation = 0, _failures = 0;
  bool _active = true,
      _disposed = false,
      _inFlight = false,
      _rateReady = true,
      _heartbeatDue = false;
  DateTime? _leaseExpiresAt;
  JamHostProof? captureJamHostProof() {
    final scope = _scope,
        device = _deviceId,
        lease = _leaseId,
        secret = _secret;
    if (scope == null || device == null || lease == null || secret == null) {
      return null;
    }
    final proof =
        JamHostProof._(this, _generation, device, lease, secret, scope);
    return proof.stillCurrent ? proof : null;
  }

  DevicePresenceStatus _status = DevicePresenceStatus.detached;
  String? get deviceId => _deviceId;
  bool get isAttached => _source != null;
  DevicePresenceStatus get status => _status;

  /// [source] must be the canonical PlaybackState.snapshotStream. Its value is
  /// captured atomically; no separately read track/position/playing getters.
  void attach(ValueStream<PlaybackSnapshot> source, AuthSessionScope scope) {
    if (_disposed) throw StateError('Presence disposed');
    detach();
    if (!service.api.acceptsAuthSession(scope)) return;
    _source = source;
    _scope = scope;
    service.api.authSessionChanges.addListener(_authChanged);
    if (_active) _start();
  }

  void _authChanged() {
    final scope = _scope;
    if (scope != null && !service.api.acceptsAuthSession(scope)) detach();
  }

  void _start() {
    final source = _source;
    if (source == null || !_active) return;
    _freshIdentity();
    _latest =
        source.hasValue ? ConnectPlayback.fromSnapshot(source.value) : null;
    _subscription = source.listen((snapshot) {
      _latest = ConnectPlayback.fromSnapshot(snapshot);
      _pump();
    });
    _status = DevicePresenceStatus.connecting;
    _pump();
  }

  void _freshIdentity() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    _deviceId =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    _secret =
        base64UrlEncode(List<int>.generate(32, (_) => _random.nextInt(256)))
            .replaceAll('=', '');
    _leaseId = null;
    _sequence = 0;
    _sentSemantic = null;
    _rateReady = true;
    _heartbeatDue = true;
    _failures = 0;
  }

  String _semantic(ConnectPlayback? playback) =>
      playback?.semanticKey ?? 'null';
  bool get _canRun =>
      !_disposed &&
      _active &&
      _source != null &&
      _scope != null &&
      service.api.acceptsAuthSession(_scope!);
  void _pump() {
    if (!_canRun || _inFlight || !_rateReady || _retryTimer != null) {
      return;
    }
    if (_leaseId != null &&
        !_heartbeatDue &&
        _semantic(_latest) == _sentSemantic) {
      return;
    }
    _inFlight = true;
    unawaited(_send(_generation));
  }

  Future<void> _send(int generation) async {
    final scope = _scope!, device = _deviceId!, secret = _secret!;
    final cancel = CancelToken();
    _cancel = cancel;
    bool current() => generation == _generation && _canRun;
    try {
      if (_leaseId == null) {
        final registered = await service.register(scope,
            deviceId: device,
            label: label,
            platform: platform,
            writerSecret: secret,
            cancelToken: cancel);
        if (!current()) return;
        // A server lease belongs to exactly the identity just registered.
        if (registered.deviceId != device) {
          throw const FormatException('Mismatched device');
        }
        _leaseId = registered.leaseId;
        _leaseExpiresAt = registered.leaseExpiresAt;
        _sequence = registered.sequence;
      }
      if (!current()) return;
      final playback = _latest;
      _sentSemantic = _semantic(playback);
      _heartbeatDue = false;
      _rateReady = false;
      _rateTimer?.cancel();
      _rateTimer = Timer(const Duration(seconds: 1), () {
        _rateTimer = null;
        _rateReady = true;
        _pump();
      });
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer(const Duration(seconds: 5), () {
        _heartbeatTimer = null;
        _heartbeatDue = true;
        _pump();
      });
      final reported = await service.report(scope,
          deviceId: device,
          leaseId: _leaseId!,
          writerSecret: secret,
          sequence: ++_sequence,
          playback: playback,
          cancelToken: cancel);
      if (!current()) return;
      _leaseExpiresAt = reported.leaseExpiresAt;
      _failures = 0;
      _status = DevicePresenceStatus.online;
      notifyListeners();
    } catch (error) {
      if (!current()) return;
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _heartbeatDue = true;
      if (connectErrorCode(error) == 'SERVICE_DISABLED') {
        _status = DevicePresenceStatus.disabled;
        // The server also uses this code for temporary Redis/SQL failures.
        // Keep a slow probe instead of requiring a new login or process.
        _retryTimer = Timer(const Duration(seconds: 30), () {
          _retryTimer = null;
          _pump();
        });
      } else {
        _status = DevicePresenceStatus.offline;
        if (error is DioException &&
            {409, 410}.contains(error.response?.statusCode)) {
          _freshIdentity();
        }
        _failures++;
        final seconds = min(30, (1 << min(_failures, 5)) + _random.nextInt(2));
        _retryTimer = Timer(Duration(seconds: seconds), () {
          _retryTimer = null;
          _pump();
        });
      }
      notifyListeners();
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
      _inFlight = false;
      _pump();
    }
  }

  /// Synchronous suspension clears identity and pending metadata. Resume reads
  /// the current canonical value and registers a fresh incarnation; no backlog.
  void setActive(bool active) {
    if (_active == active || _disposed) return;
    _active = active;
    if (active) {
      _start();
    } else {
      _retire();
    }
    notifyListeners();
  }

  void _retire() {
    _generation++;
    _rateTimer?.cancel();
    _heartbeatTimer?.cancel();
    _retryTimer?.cancel();
    _rateTimer = null;
    _heartbeatTimer = null;
    _retryTimer = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _cancel?.cancel('Presence retired');
    // No parallel cleanup beside an outstanding report. Crashes/offline/auth
    // revocation rely on the server's 90-second lease rather than replay.
    final scope = _scope,
        device = _deviceId,
        lease = _leaseId,
        secret = _secret;
    if (!_inFlight &&
        scope != null &&
        scope.isCurrent &&
        device != null &&
        lease != null &&
        secret != null) {
      _inFlight = true;
      unawaited(service
          .remove(scope, deviceId: device, leaseId: lease, writerSecret: secret)
          .catchError((Object _) {})
          .whenComplete(() {
        _inFlight = false;
        _pump();
      }));
    }
    _deviceId = null;
    _leaseId = null;
    _secret = null;
    _leaseExpiresAt = null;
    _latest = null;
    _sentSemantic = null;
    _status = DevicePresenceStatus.detached;
  }

  void detach() {
    service.api.authSessionChanges.removeListener(_authChanged);
    _retire();
    _source = null;
    _scope = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    detach();
    _disposed = true;
    super.dispose();
  }
}
