import 'dart:async';

import 'package:audio_session/audio_session.dart';

import '../models/settings_model.dart';

/// A connected output reduced to the stable calibration category the app uses.
class AuditionOutputDevice {
  final String id;
  final ClickAuditionOutputRoute route;

  const AuditionOutputDevice({required this.id, required this.route});

  @override
  bool operator ==(Object other) {
    return other is AuditionOutputDevice &&
        other.id == id &&
        other.route == route;
  }

  @override
  int get hashCode => Object.hash(id, route);
}

/// Read-only source used by [AuditionOutputRouteMonitor].
///
/// Implementations report connected output devices only. They do not select an
/// output, activate/configure the audio session, or own interruption handling.
abstract interface class AuditionOutputRouteSource {
  Future<Set<AuditionOutputDevice>> getConnectedOutputs();

  Stream<void> get connectedOutputsChanged;
}

/// The production connected-device source backed by the shared audio session.
class AudioSessionAuditionOutputRouteSource
    implements AuditionOutputRouteSource {
  final AudioSession _session;

  const AudioSessionAuditionOutputRouteSource(this._session);

  static Future<AudioSessionAuditionOutputRouteSource> create() async {
    return AudioSessionAuditionOutputRouteSource(await AudioSession.instance);
  }

  @override
  Future<Set<AuditionOutputDevice>> getConnectedOutputs() async {
    final devices = await _session.getDevices(
      includeInputs: false,
      includeOutputs: true,
    );
    return devices
        .where((device) => device.isOutput)
        .map(
          (device) => AuditionOutputDevice(
            id: device.id,
            // audio_session exposes read-only output classification through an
            // experimental enum. Keep that dependency contained at this edge.
            // ignore: experimental_member_use
            route: clickAuditionRouteForAudioDeviceTypeName(device.type.name),
          ),
        )
        .toSet();
  }

  @override
  Stream<void> get connectedOutputsChanged => _session.devicesChangedEventStream
      .where(
        (event) =>
            event.devicesAdded.any((device) => device.isOutput) ||
            event.devicesRemoved.any((device) => device.isOutput),
      )
      .map((_) {});
}

ClickAuditionOutputRoute clickAuditionRouteForAudioDeviceTypeName(String name) {
  return switch (name) {
    'bluetoothSco' ||
    'bluetoothA2dp' ||
    'bluetoothLe' ||
    'hearingAid' =>
      ClickAuditionOutputRoute.bluetooth,
    'wiredHeadset' ||
    'wiredHeadphones' ||
    'lineAnalog' ||
    'lineDigital' ||
    'usbAudio' ||
    'auxLine' =>
      ClickAuditionOutputRoute.wired,
    'builtInSpeaker' => ClickAuditionOutputRoute.speaker,
    'unknown' => ClickAuditionOutputRoute.unknown,
    _ => ClickAuditionOutputRoute.other,
  };
}

/// Conservative route observation derived from connected outputs.
///
/// `audio_session` exposes connected devices on Android, not the active media
/// route. The label therefore always makes the inference explicit so a
/// calibration value is never presented as having a confirmed active route.
class AuditionOutputRouteObservation {
  /// A coarse connected-output hint, or the confirmed active route when
  /// [activeRouteConfirmed] is true.
  ///
  /// Android's connected-device API does not identify the active media route,
  /// so callers must never use an unconfirmed value to select calibration.
  final ClickAuditionOutputRoute route;
  final List<ClickAuditionOutputRoute> connectedRoutes;
  final bool activeRouteConfirmed;

  AuditionOutputRouteObservation._({
    required this.route,
    required Iterable<ClickAuditionOutputRoute> connectedRoutes,
    required this.activeRouteConfirmed,
  }) : connectedRoutes = List.unmodifiable(connectedRoutes);

  factory AuditionOutputRouteObservation.fromConnectedOutputs(
    Iterable<AuditionOutputDevice> devices,
  ) {
    final connected = {
      for (final device in devices) device.route,
    };
    final stableConnected = [
      for (final route in ClickAuditionOutputRoute.values)
        if (connected.contains(route)) route,
    ];
    return AuditionOutputRouteObservation._(
      route: _preferredRoute(connected),
      connectedRoutes: stableConnected,
      activeRouteConfirmed: false,
    );
  }

  /// Explicit constructor for platforms that can truthfully report the active
  /// media route. Android's production source does not currently use this.
  factory AuditionOutputRouteObservation.confirmedActiveRoute(
    ClickAuditionOutputRoute route, {
    Iterable<ClickAuditionOutputRoute> connectedRoutes = const [],
  }) {
    return AuditionOutputRouteObservation._(
      route: route,
      connectedRoutes: connectedRoutes,
      activeRouteConfirmed: true,
    );
  }

  static final unknown = AuditionOutputRouteObservation._(
    route: ClickAuditionOutputRoute.unknown,
    connectedRoutes: const [],
    activeRouteConfirmed: false,
  );

  String get label {
    final category = switch (route) {
      ClickAuditionOutputRoute.bluetooth => 'Bluetooth output',
      ClickAuditionOutputRoute.wired => 'Wired output',
      ClickAuditionOutputRoute.speaker => 'Device speaker',
      ClickAuditionOutputRoute.other => 'Other output',
      ClickAuditionOutputRoute.unknown => 'Unknown output',
    };
    if (activeRouteConfirmed) return '$category (active media route)';
    if (connectedRoutes.isEmpty) {
      return 'No connected output hint (active media route unavailable)';
    }
    return 'Connected output hint: $category '
        '(inferred from connected outputs; active media route unconfirmed)';
  }

  @override
  bool operator ==(Object other) {
    if (other is! AuditionOutputRouteObservation ||
        other.route != route ||
        other.activeRouteConfirmed != activeRouteConfirmed ||
        other.connectedRoutes.length != connectedRoutes.length) {
      return false;
    }
    for (var index = 0; index < connectedRoutes.length; index++) {
      if (other.connectedRoutes[index] != connectedRoutes[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
        route,
        activeRouteConfirmed,
        Object.hashAll(connectedRoutes),
      );
}

ClickAuditionOutputRoute _preferredRoute(
  Set<ClickAuditionOutputRoute> connected,
) {
  for (final route in const [
    ClickAuditionOutputRoute.bluetooth,
    ClickAuditionOutputRoute.wired,
    ClickAuditionOutputRoute.other,
    ClickAuditionOutputRoute.speaker,
    ClickAuditionOutputRoute.unknown,
  ]) {
    if (connected.contains(route)) return route;
  }
  return ClickAuditionOutputRoute.unknown;
}

/// Observes coarse output-route changes without becoming an audio-session owner.
class AuditionOutputRouteMonitor {
  final AuditionOutputRouteSource _source;
  final StreamController<AuditionOutputRouteObservation> _controller =
      StreamController.broadcast(sync: true);

  StreamSubscription<void>? _changesSubscription;
  AuditionOutputRouteObservation _current =
      AuditionOutputRouteObservation.unknown;
  int _refreshGeneration = 0;
  bool _started = false;
  bool _disposed = false;
  bool _hasEmitted = false;

  AuditionOutputRouteMonitor({required AuditionOutputRouteSource source})
      : _source = source;

  static Future<AuditionOutputRouteMonitor> create() async {
    return AuditionOutputRouteMonitor(
      source: await AudioSessionAuditionOutputRouteSource.create(),
    );
  }

  AuditionOutputRouteObservation get current => _current;

  Stream<AuditionOutputRouteObservation> get observations => _controller.stream;

  Future<void> start() async {
    if (_disposed) {
      throw StateError('AuditionOutputRouteMonitor is disposed');
    }
    if (_started) return;
    _started = true;
    _changesSubscription = _source.connectedOutputsChanged.listen(
      (_) => unawaited(refresh()),
    );
    await refresh();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final generation = ++_refreshGeneration;
    try {
      final devices = await _source.getConnectedOutputs();
      if (_disposed || generation != _refreshGeneration) return;
      _emit(AuditionOutputRouteObservation.fromConnectedOutputs(devices));
    } catch (_) {
      if (_disposed || generation != _refreshGeneration) return;
      _emit(AuditionOutputRouteObservation.unknown);
    }
  }

  void _emit(AuditionOutputRouteObservation observation) {
    if (_hasEmitted && observation == _current) return;
    _hasEmitted = true;
    _current = observation;
    _controller.add(observation);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _refreshGeneration++;
    await _changesSubscription?.cancel();
    _changesSubscription = null;
    await _controller.close();
  }
}
