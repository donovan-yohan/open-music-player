import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:rxdart/rxdart.dart';
import '../../shared/models/track.dart';
import '../audio/playback_session.dart';
import '../connect/device_presence_service.dart';
import '../storage/secure_storage.dart';
import 'jam_models.dart';
import 'jam_service.dart';

typedef JamAdmission = Future<JamAdmissionReceipt> Function(String jamId,
    JamRequest request, String expectedSessionId, bool Function() stillCurrent);

/// Application-owned host lifetime. The route only owns panel visibility.
/// Heartbeat never follows window focus. No playback/auth/Connect owner here.
class JamHostController extends ChangeNotifier with WidgetsBindingObserver {
  JamHostController(
      {required this.service,
      required this.presence,
      required this.source,
      required this.canonicalSessionGeneration,
      required this.admit,
      required this.accountChanges,
      required this.accountRevision,
      Uri? guestOrigin}) {
    if (guestOrigin != null) {
      _origin = validateJamOrigin(guestOrigin.toString());
    }
    const configured = String.fromEnvironment('JAM_GUEST_WEB_ORIGIN');
    if (_origin == null && configured.isNotEmpty) {
      _origin = validateJamOrigin(configured);
    }
    _sessionId = source.hasValue ? source.value.sessionId : '';
    _sourceSubscription = source.listen((s) {
      if (s.sessionId != _sessionId) {
        _sessionId = s.sessionId;
        _approvalEpoch++;
      }
      _latest = JamNowPlaying.fromSnapshot(s);
      _notify();
    });
    if (source.hasValue) _latest = JamNowPlaying.fromSnapshot(source.value);
    service.api.authSessionChanges.addListener(_authChanged);
    accountChanges.addListener(_accountChanged);
    presence.addListener(_proofChanged);
    WidgetsBinding.instance.addObserver(this);
  }
  final JamService service;
  final DevicePresenceService presence;
  final ValueStream<PlaybackSnapshot> source;

  /// Read the canonical owner's incarnation, not its reusable saved-session ID.
  final int Function() canonicalSessionGeneration;
  final JamAdmission admit;
  final Listenable accountChanges;
  final int Function() accountRevision;
  int? _capturedAccountRevision;
  late final StreamSubscription<PlaybackSnapshot> _sourceSubscription;
  AuthSessionScope? _scope;
  JamHostProof? _proof;
  Uri? _origin, _link;
  JamSnapshot? _snapshot, _latestSnapshot;
  JamNowPlaying? _latest;
  JamInvite? _invite;
  String? _id, _message;
  String _sessionId = '';
  List<int>? _createTracks;
  Timer? _heartbeatTimer, _pollTimer, _expiryTimer;
  CancelToken? _cancel;
  int _epoch = 0, _approvalEpoch = 0, _sequence = 0;
  bool _disposed = false,
      _wireBusy = false,
      _actionBusy = false,
      _heartbeatDue = false,
      _pollDue = false,
      _panelVisible = false,
      _resumed = true,
      _detached = false,
      _connected = false;
  Future<void>? _tail;
  final Map<String, _Decision> _decisions = {};
  JamSnapshot? get snapshot => _snapshot;
  JamNowPlaying? get hostMetadata => _current ? _latest : null;
  String? get message => _message;
  Uri? get invitationLink => _link;
  DateTime? get invitationExpiresAt => _invite?.expiresAt;
  Uri? get guestOrigin => _origin;
  bool get busy => _actionBusy;
  bool get hasJam => _id != null;
  bool get isHosting =>
      _id != null &&
      _proof != null &&
      _proof!.stillCurrent &&
      !(_latestSnapshot?.terminal ?? false) &&
      !_detached;
  bool get canApprove =>
      isHosting &&
      _resumed &&
      _panelVisible &&
      _connected &&
      !busy &&
      _snapshot?.state == 'open';
  bool attempted(String id) => _decisions.containsKey(id);
  bool hasReceipt(String id) => _decisions[id]?.receipt != null;
  bool get _current =>
      !_disposed &&
      !_detached &&
      _scope != null &&
      _capturedAccountRevision == accountRevision() &&
      service.api.acceptsAuthSession(_scope!);
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setGuestOrigin(String value) {
    _origin = validateJamOrigin(value);
    _link = null;
    _notify();
  }

  void setPanelVisible(bool value) {
    if (_panelVisible == value) return;
    _panelVisible = value;
    if (!value) _approvalEpoch++;
    _configurePolling();
  }

  void setLifecycle(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    if (!_resumed) _approvalEpoch++;
    if (state == AppLifecycleState.detached) {
      _detached = true;
      _retire(clear: true);
    }
    _configurePolling();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      setLifecycle(state);
  void _configurePolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (_current && hasJam && _panelVisible && _resumed) {
      _pollDue = true;
      _pump();
      _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        _pollDue = true;
        _pump();
      });
    } else {
      _pollDue = false;
    }
    _notify();
  }

  void _authChanged() {
    if (_scope != null && !service.api.acceptsAuthSession(_scope!)) {
      _retire(clear: true);
    }
  }

  void _accountChanged() {
    if (_scope != null && _capturedAccountRevision != accountRevision()) {
      _retire(clear: true);
    }
  }

  void _proofChanged() {
    if (_proof != null && !_proof!.stillCurrent) {
      _epoch++;
      _approvalEpoch++;
      _cancel?.cancel('Host connection changed');
      _heartbeatTimer?.cancel();
      _heartbeatDue = false;
      _connected = false;
      _link = null;
      _actionBusy = false;
      _message = 'Host connection changed. End this Jam to start a new one.';
      _notify();
    }
  }

  /// Serialize actual adapter lifetimes, including cancelled-but-unsettled Dio.
  Future<T> _wire<T>(Future<T> Function(CancelToken) action) {
    final epoch = _epoch;
    Future<T> run() async {
      if (!_current || epoch != _epoch) throw StateError('Jam changed');
      _wireBusy = true;
      final cancel = CancelToken();
      _cancel = cancel;
      try {
        return await action(cancel);
      } finally {
        if (identical(_cancel, cancel)) _cancel = null;
        _wireBusy = false;
      }
    }

    final previous = _tail;
    final result =
        previous == null ? Future<T>.sync(run) : previous.then((_) => run());
    late final Future<void> barrier;
    barrier = result
        .then<void>((_) {}, onError: (Object _, StackTrace __) {})
        .whenComplete(() {
      if (identical(_tail, barrier)) {
        _tail = null;
        _pump();
      }
    });
    _tail = barrier;
    return result;
  }

  Future<void> start(List<int> tracks) async {
    if (_actionBusy || hasJam || _disposed) return;
    if (tracks.isEmpty ||
        tracks.length > 20 ||
        tracks.any((i) => i <= 0) ||
        tracks.toSet().length != tracks.length) {
      _message = 'Choose 1–20 library tracks.';
      _notify();
      return;
    }
    final proof = presence.captureJamHostProof();
    if (proof == null) {
      _message = 'Connect this device, then start your Jam.';
      _notify();
      return;
    }
    _proof = proof;
    _scope = proof.scope;
    _capturedAccountRevision = accountRevision();
    _id = newJamId();
    _createTracks = List.unmodifiable(tracks);
    _sequence = 0;
    _actionBusy = true;
    _message = null;
    final epoch = _epoch;
    _notify();
    try {
      final created = await _wire(
          (c) => service.create(proof, _id!, _createTracks!, cancel: c));
      if (!_valid(epoch)) return;
      _accept(created);
      await _read(epoch);
      _beginHeartbeat();
    } catch (_) {
      if (_valid(epoch)) {
        _message = 'Start not confirmed. Check Jam status.';
      }
    } finally {
      if (_valid(epoch)) {
        _actionBusy = false;
        _notify();
      }
    }
  }

  Future<void> retryStart() async {
    if (!_current ||
        !hasJam ||
        _snapshot != null ||
        _actionBusy ||
        !(_proof?.stillCurrent ?? false)) {
      return;
    }
    _actionBusy = true;
    final epoch = _epoch;
    _notify();
    try {
      final created = await _wire(
          (c) => service.create(_proof!, _id!, _createTracks!, cancel: c));
      if (!_valid(epoch)) return;
      _accept(created);
      await _read(epoch);
      _beginHeartbeat();
    } catch (_) {
      if (_valid(epoch)) _message = 'Start not confirmed. Check Jam status.';
    } finally {
      if (_valid(epoch)) {
        _actionBusy = false;
        _notify();
      }
    }
  }

  bool _valid(int epoch) => _current && epoch == _epoch;
  void _beginHeartbeat() {
    if (!isHosting) return;
    _heartbeatTimer?.cancel();
    _heartbeatDue = true;
    _pump();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _heartbeatDue = true;
      _pump();
    });
    _configurePolling();
  }

  void _pump() {
    if (!_current || !hasJam || _wireBusy || _tail != null || !isHosting) {
      return;
    }
    if (_heartbeatDue) {
      _heartbeatDue = false;
      unawaited(_beat());
    } else if (_pollDue && _panelVisible && _resumed) {
      _pollDue = false;
      unawaited(_backgroundRead());
    }
  }

  Future<void> _beat() async {
    final epoch = _epoch;
    try {
      final s = await _wire((c) =>
          service.heartbeat(_proof!, _id!, ++_sequence, _latest, cancel: c));
      if (!_valid(epoch)) return;
      _connected = true;
      _accept(s);
    } catch (_) {
      if (_valid(epoch)) {
        _connected = false;
        _link = null;
        _message = 'Host offline. Check connection.';
        _notify();
      }
    }
  }

  Future<void> _backgroundRead() async {
    final epoch = _epoch;
    try {
      await _read(epoch);
    } catch (_) {
      if (_valid(epoch)) {
        _connected = false;
        _message = 'Could not refresh requests.';
        _notify();
      }
    }
  }

  Future<void> _read(int epoch) async {
    final s = await _wire((c) => service.read(_scope!, _id!, cancel: c));
    if (!_valid(epoch)) return;
    _connected = true;
    _accept(s, host: true);
  }

  void _accept(JamSnapshot next, {bool host = false}) {
    final old = _latestSnapshot;
    if (old != null &&
        (next.version < old.version ||
            (next.version == old.version &&
                next.serverTime.isBefore(old.serverTime)))) {
      return;
    }
    _latestSnapshot = next;
    // Heartbeat response is the public projection: do not erase private requests.
    if (host || old == null) _snapshot = next;
    if (next.terminal) {
      _heartbeatTimer?.cancel();
      _pollTimer?.cancel();
      _link = null;
      _invite = null;
      _approvalEpoch++;
      _message = next.state == 'expired' ? 'Jam expired.' : 'Jam ended.';
    }
    if (host) {
      for (final r in next.hostRequests) {
        if (r.status == 'queued' || r.status == 'declined') {
          _decisions.remove(r.requestId);
        }
      }
    }
    _notify();
  }

  Future<void> refresh() async {
    if (!_current || !hasJam || _actionBusy) return;
    _actionBusy = true;
    final epoch = _epoch;
    _notify();
    try {
      await _read(epoch);
      if (_valid(epoch) && isHosting && _heartbeatTimer == null) {
        _beginHeartbeat();
      }
    } catch (_) {
      if (_valid(epoch)) _message = 'Could not refresh Jam. Try again.';
    } finally {
      if (_valid(epoch)) {
        _actionBusy = false;
        _notify();
      }
    }
  }

  Future<({List<Track> tracks, int total})> libraryPage(
      {int offset = 0, String? query}) async {
    final scope = service.api.captureAuthSession();
    // Selection is read-only and never changes the host's captured account.
    return service.libraryPage(scope, offset: offset, query: query);
  }

  Future<void> rotateInvite() async {
    if (!isHosting || _actionBusy) return;
    if (_origin == null) {
      _message = 'Set your guest web origin.';
      _notify();
      return;
    }
    _actionBusy = true;
    _link = null;
    _invite = null;
    final epoch = _epoch;
    _notify();
    try {
      await _read(epoch);
      if (!_valid(epoch) || _snapshot?.state != 'open') return;
      final invite =
          await _wire((c) => service.invite(_proof!, _id!, cancel: c));
      if (!_valid(epoch) || !_proof!.stillCurrent) return;
      _invite = invite;
      _link = invite.link(_origin!, _id!);
      _message = null;
      _expiryTimer?.cancel();
      final remaining = invite.expiresAt.difference(_snapshot!.serverTime);
      _expiryTimer =
          Timer(remaining.isNegative ? Duration.zero : remaining, () {
        _link = null;
        _invite = null;
        _message = 'Invitation expired. Create a new invitation.';
        _notify();
      });
    } catch (_) {
      if (_valid(epoch)) {
        _message = 'Invitation not confirmed. Create a new invitation.';
      }
    } finally {
      if (_valid(epoch)) {
        _actionBusy = false;
        _notify();
      }
    }
  }

  JamRequest? _request(String id) {
    for (final r in _snapshot?.hostRequests ?? <JamRequest>[]) {
      if (r.requestId == id) return r;
    }
    return null;
  }

  Future<void> approve(String requestId) async {
    if (!canApprove || attempted(requestId)) return;
    _actionBusy = true;
    final epoch = _epoch, session = _sessionId;
    final current = _decisionGuard();
    _notify();
    try {
      await _read(epoch);
      if (!current()) return;
      final request = _request(requestId);
      if (request == null ||
          request.status != 'pending' ||
          _snapshot?.state != 'open') {
        return;
      }
      final catalog =
          _snapshot!.catalog.firstWhere((c) => c.id == request.catalogItemId);
      await _wire((_) {
        if (!current()) throw StateError('Approval changed');
        return service.ownedTrack(_scope!, request.trackId!, catalog.title);
      });
      if (!current()) return;
      // Latch before calling the canonical owner: an unknown error cannot replay.
      _decisions[requestId] = const _Decision('uncertain');
      JamAdmissionReceipt? receipt;
      try {
        receipt = await _wire<JamAdmissionReceipt>((_) {
          if (!current()) throw StateError('Approval changed');
          return admit(_id!, request, session, current);
        });
        JamAdmissionReceipt.fromJson(
            Map<String, dynamic>.from(receipt.toJson()));
        if (receipt.requestId != requestId || receipt.sessionId != session) {
          throw StateError('Mismatched receipt');
        }
      } catch (_) {
        receipt = null;
      }
      if (!_valid(epoch)) return;
      final decision = current() && receipt != null
          ? _Decision('queued', receipt)
          : const _Decision('uncertain');
      _decisions[requestId] = decision;
      if (!current()) {
        _message = 'Approval interrupted. Refresh to reconcile.';
        return;
      }
      await _publish(requestId, decision, epoch, stillCurrent: current);
    } catch (_) {
      if (_valid(epoch)) {
        _message = 'Could not approve request. Refresh to check status.';
      }
    } finally {
      if (_valid(epoch)) {
        _actionBusy = false;
        _notify();
      }
    }
  }

  Future<void> decline(String requestId) async {
    if (!canApprove) return;
    _actionBusy = true;
    final epoch = _epoch;
    final current = _decisionGuard();
    _notify();
    try {
      await _read(epoch);
      if (!current()) return;
      final request = _request(requestId);
      if (request == null ||
          !{'pending', 'uncertain'}.contains(request.status)) {
        return;
      }
      const decision = _Decision('declined');
      _decisions[requestId] = decision;
      await _publish(requestId, decision, epoch, stillCurrent: current);
    } catch (_) {
      if (_valid(epoch)) {
        _message = 'Decision not confirmed. Refresh to check status.';
      }
    } finally {
      if (_valid(epoch)) {
        _actionBusy = false;
        _notify();
      }
    }
  }

  /// Freeze explicit consent before any await. Visibility/lifecycle ABA retires
  /// the epoch even when the panel is visible and resumed again at send time.
  bool Function() _decisionGuard() {
    final epoch = _epoch, approval = ++_approvalEpoch;
    final scope = _scope!, proof = _proof!, id = _id!;
    final revision = accountRevision();
    final session = _sessionId, generation = canonicalSessionGeneration();
    return () =>
        _valid(epoch) &&
        identical(_scope, scope) &&
        service.api.acceptsAuthSession(scope) &&
        accountRevision() == revision &&
        identical(_proof, proof) &&
        proof.stillCurrent &&
        _id == id &&
        _approvalEpoch == approval &&
        _sessionId == session &&
        canonicalSessionGeneration() == generation &&
        _resumed &&
        _panelVisible &&
        isHosting &&
        _snapshot?.state == 'open';
  }

  /// Explicit retry of a known receipt/uncertain statement, NEVER admission.
  Future<void> reconcileDecision(String requestId) async {
    if (!canApprove || !attempted(requestId)) return;
    _actionBusy = true;
    final epoch = _epoch;
    final current = _decisionGuard();
    _notify();
    try {
      await _read(epoch);
      if (!current()) return;
      final decision = _decisions[requestId];
      final r = _request(requestId);
      if (decision != null &&
          r != null &&
          {'pending', 'uncertain'}.contains(r.status)) {
        await _publish(requestId, decision, epoch, stillCurrent: current);
      }
    } catch (_) {
      if (_valid(epoch)) {
        _message = 'Decision not confirmed. Refresh to check status.';
      }
    } finally {
      if (_valid(epoch)) {
        _actionBusy = false;
        _notify();
      }
    }
  }

  Future<void> _publish(String requestId, _Decision decision, int epoch,
      {required bool Function() stillCurrent}) async {
    try {
      await _wire((c) {
        if (!stillCurrent()) throw StateError('Approval changed');
        return service.decide(_proof!, _id!, requestId,
            version: _snapshot!.version,
            status: decision.status,
            receipt: decision.receipt,
            cancel: c);
      });
    } catch (_) {
      if (_valid(epoch)) {
        _message = 'Decision not confirmed. Refresh to check status.';
      }
    }
    // Exact target readback even after a successful response or lost ack. No retry.
    if (_valid(epoch)) {
      try {
        await _read(epoch);
      } catch (_) {
        _message = 'Decision not confirmed. Refresh to check status.';
      }
    }
  }

  Future<void> end() async {
    if (!_current || !hasJam || _actionBusy) return;
    _actionBusy = true;
    _approvalEpoch++;
    final epoch = _epoch;
    _notify();
    try {
      await _wire((c) => service.close(_scope!, _id!, cancel: c));
      await _read(epoch);
      if (_valid(epoch) && _snapshot?.state == 'closed') _retire(clear: true);
    } catch (_) {
      if (_valid(epoch)) _message = 'End not confirmed. Check Jam status.';
    } finally {
      if (_valid(epoch)) {
        _actionBusy = false;
        _notify();
      }
    }
  }

  void _retire({required bool clear}) {
    _epoch++;
    _approvalEpoch++;
    _heartbeatTimer?.cancel();
    _pollTimer?.cancel();
    _expiryTimer?.cancel();
    _cancel?.cancel('Jam retired');
    _heartbeatDue = false;
    _pollDue = false;
    _link = null;
    _invite = null;
    _actionBusy = false;
    _proof = null;
    _connected = false;
    if (clear) {
      _id = null;
      _snapshot = null;
      _latestSnapshot = null;
      _scope = null;
      _createTracks = null;
      _decisions.clear();
      _message = null;
    }
    _notify();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _retire(clear: true);
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    service.api.authSessionChanges.removeListener(_authChanged);
    accountChanges.removeListener(_accountChanged);
    presence.removeListener(_proofChanged);
    unawaited(_sourceSubscription.cancel());
    super.dispose();
  }
}

class _Decision {
  const _Decision(this.status, [this.receipt]);
  final String status;
  final JamAdmissionReceipt? receipt;
}
