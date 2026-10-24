import 'dart:async';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../../core/connect/connect_models.dart';
import '../../core/connect/connect_service.dart';
import '../../core/storage/secure_storage.dart';

/// Account-private observation only. [visible] must be false for a covered or
/// offstage route/tab. Polling also stops during app suspension and on unmount.
class DevicePanel extends StatefulWidget {
  const DevicePanel(
      {super.key,
      required this.service,
      required this.scope,
      this.visible = true});
  final ConnectService service;
  final AuthSessionScope scope;
  final bool visible;
  @override
  State<DevicePanel> createState() => _DevicePanelState();
}

class _DevicePanelState extends State<DevicePanel> with WidgetsBindingObserver {
  ConnectedDevices? _snapshot;
  Timer? _timer;
  CancelToken? _cancel;
  final _random = Random();
  bool _active = true, _busy = false, _offline = false, _disabled = false;
  int _generation = 0, _failures = 0;
  bool get _canPoll =>
      mounted &&
      widget.visible &&
      _active &&
      widget.service.api.acceptsAuthSession(widget.scope);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _active =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.service.api.authSessionChanges.addListener(_authChanged);
    _poll();
  }

  @override
  void didUpdateWidget(DevicePanel old) {
    super.didUpdateWidget(old);
    if (old.service != widget.service || old.scope != widget.scope) {
      old.service.api.authSessionChanges.removeListener(_authChanged);
      widget.service.api.authSessionChanges.addListener(_authChanged);
      _stop(clear: true);
      _disabled = false;
      _offline = false;
      _failures = 0;
    } else if (old.visible != widget.visible) {
      _stop(clear: !widget.visible);
    }
    if (_canPoll && _timer == null) _poll();
  }

  void _authChanged() {
    if (!widget.service.api.acceptsAuthSession(widget.scope)) {
      _stop(clear: true);
      if (mounted) setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final active = state == AppLifecycleState.resumed;
    if (active == _active) return;
    _active = active;
    _stop(clear: !active);
    if (active) _poll();
    if (mounted) setState(() {});
  }

  void _stop({required bool clear}) {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _cancel?.cancel('Panel hidden');
    if (clear) _snapshot = null;
  }

  Future<void> _poll() async {
    if (!_canPoll || _busy) return;
    _timer?.cancel();
    _timer = null;
    _busy = true;
    final generation = _generation, cancel = CancelToken();
    _cancel = cancel;
    try {
      final snapshot =
          await widget.service.list(widget.scope, cancelToken: cancel);
      if (generation != _generation || !_canPoll) return;
      setState(() {
        _snapshot = snapshot;
        _offline = false;
        _disabled = false;
        _failures = 0;
      });
    } catch (error) {
      if (generation != _generation || !_canPoll) return;
      setState(() {
        _offline = true;
        _failures++;
        _disabled = connectErrorCode(error) == 'SERVICE_DISABLED';
      });
    } finally {
      _busy = false;
      if (identical(_cancel, cancel)) _cancel = null;
      if (_canPoll) {
        final seconds = _disabled
            ? 30
            : _offline
                ? min(30, (1 << min(_failures, 5)) + _random.nextInt(2))
                : 5;
        _timer = Timer(Duration(seconds: seconds), () {
          _timer = null;
          _poll();
        });
      }
    }
  }

  @override
  void dispose() {
    widget.service.api.authSessionChanges.removeListener(_authChanged);
    WidgetsBinding.instance.removeObserver(this);
    _stop(clear: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (!widget.scope.isCurrent)
        const Text('Sign in to view connected devices.')
      else if (_disabled)
        const Text('Connected devices are not enabled on this server.')
      else if (_offline)
        const Text('Unable to refresh devices')
      else if (!_active || !widget.visible)
        const Text('Device updates paused.')
      else if (snapshot == null)
        const Text('Loading device reports…'),
      if (snapshot != null && snapshot.devices.isEmpty)
        const Text('No recent device reports.'),
      if (snapshot != null)
        for (final device in snapshot.devices)
          _DeviceCard(
              device: device, serverTime: snapshot.serverTime, stale: _offline),
    ]);
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard(
      {required this.device, required this.serverTime, required this.stale});
  final ConnectedDevice device;
  final DateTime serverTime;
  final bool stale;
  @override
  Widget build(BuildContext context) {
    final playback = device.playback;
    final old = stale ||
        !device.leaseExpiresAt.isAfter(serverTime) ||
        serverTime.difference(device.lastSeenAt) > const Duration(seconds: 15);
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(device.label,
                  style: Theme.of(context).textTheme.titleMedium),
              Text('${device.platform}${old ? ' · Stale report' : ''}'),
              if (playback == null)
                const Text('No listening metadata reported.')
              else ...[
                Text(playback.title),
                Text(playback.artist),
                Text(
                    '${playback.playing ? 'Playing' : 'Paused'} · ${playback.processingState} · ${playback.activeVoiceCount} active voices'),
                Text(
                    'Host-reported position: ${_time(playback.positionMs)} / ${_time(playback.durationMs)}'),
              ],
              Text('Last report: ${device.lastSeenAt.toIso8601String()}'),
            ])));
  }
}

String _time(int ms) =>
    '${ms ~/ 60000}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}';
