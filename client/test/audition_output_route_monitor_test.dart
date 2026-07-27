import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/core/audio/audition_output_route_monitor.dart';
import 'package:open_music_player/core/models/settings_model.dart';

void main() {
  test('audio device types map to stable calibration buckets', () {
    expect(
      clickAuditionRouteForAudioDeviceTypeName('bluetoothA2dp'),
      ClickAuditionOutputRoute.bluetooth,
    );
    expect(
      clickAuditionRouteForAudioDeviceTypeName('bluetoothLe'),
      ClickAuditionOutputRoute.bluetooth,
    );
    expect(
      clickAuditionRouteForAudioDeviceTypeName('wiredHeadphones'),
      ClickAuditionOutputRoute.wired,
    );
    expect(
      clickAuditionRouteForAudioDeviceTypeName('usbAudio'),
      ClickAuditionOutputRoute.wired,
    );
    expect(
      clickAuditionRouteForAudioDeviceTypeName('builtInSpeaker'),
      ClickAuditionOutputRoute.speaker,
    );
    expect(
      clickAuditionRouteForAudioDeviceTypeName('hdmi'),
      ClickAuditionOutputRoute.other,
    );
    expect(
      clickAuditionRouteForAudioDeviceTypeName('unknown'),
      ClickAuditionOutputRoute.unknown,
    );
  });

  test('connected outputs remain hints instead of claiming an active route',
      () {
    final observation =
        AuditionOutputRouteObservation.fromConnectedOutputs(const [
      AuditionOutputDevice(
        id: 'headphones',
        route: ClickAuditionOutputRoute.bluetooth,
      ),
    ]);

    expect(observation.route, ClickAuditionOutputRoute.bluetooth);
    expect(observation.activeRouteConfirmed, isFalse);
    expect(observation.label, contains('Connected output hint'));
    expect(observation.label, contains('active media route unconfirmed'));
  });

  test('only an explicit active-route observation is confirmed', () {
    final observation = AuditionOutputRouteObservation.confirmedActiveRoute(
      ClickAuditionOutputRoute.speaker,
      connectedRoutes: const [ClickAuditionOutputRoute.speaker],
    );

    expect(observation.route, ClickAuditionOutputRoute.speaker);
    expect(observation.activeRouteConfirmed, isTrue);
    expect(observation.label, 'Device speaker (active media route)');
    expect(
      observation,
      isNot(
        AuditionOutputRouteObservation.fromConnectedOutputs(const [
          AuditionOutputDevice(
            id: 'speaker',
            route: ClickAuditionOutputRoute.speaker,
          ),
        ]),
      ),
    );
  });

  test('monitor emits stable connected-device inference on route changes',
      () async {
    final source = _FakeRouteSource({
      const AuditionOutputDevice(
        id: 'speaker',
        route: ClickAuditionOutputRoute.speaker,
      ),
      const AuditionOutputDevice(
        id: 'headphones',
        route: ClickAuditionOutputRoute.bluetooth,
      ),
    });
    final monitor = AuditionOutputRouteMonitor(source: source);
    final observations = <AuditionOutputRouteObservation>[];
    final subscription = monitor.observations.listen(observations.add);

    await monitor.start();

    expect(monitor.current.route, ClickAuditionOutputRoute.bluetooth);
    expect(
      monitor.current.connectedRoutes,
      [
        ClickAuditionOutputRoute.bluetooth,
        ClickAuditionOutputRoute.speaker,
      ],
    );
    expect(monitor.current.activeRouteConfirmed, isFalse);
    expect(monitor.current.label, contains('inferred from connected outputs'));
    expect(monitor.current.label, contains('unconfirmed'));

    source.devices = {
      const AuditionOutputDevice(
        id: 'speaker',
        route: ClickAuditionOutputRoute.speaker,
      ),
      const AuditionOutputDevice(
        id: 'cable',
        route: ClickAuditionOutputRoute.wired,
      ),
    };
    final nextWired = monitor.observations.firstWhere(
      (observation) => observation.route == ClickAuditionOutputRoute.wired,
    );
    source.emitChange();
    await nextWired;

    expect(monitor.current.route, ClickAuditionOutputRoute.wired);
    expect(observations, hasLength(2));

    await subscription.cancel();
    await monitor.dispose();
    await source.dispose();
  });

  test('newer route refresh wins over an older delayed read', () async {
    final source = _ControlledRouteSource();
    final oldRead = source.enqueueRead();
    final newRead = source.enqueueRead();
    final monitor = AuditionOutputRouteMonitor(source: source);

    final start = monitor.start();
    final refresh = monitor.refresh();
    newRead.complete({
      const AuditionOutputDevice(
        id: 'wired',
        route: ClickAuditionOutputRoute.wired,
      ),
    });
    await refresh;
    oldRead.complete({
      const AuditionOutputDevice(
        id: 'bluetooth',
        route: ClickAuditionOutputRoute.bluetooth,
      ),
    });
    await start;

    expect(monitor.current.route, ClickAuditionOutputRoute.wired);

    await monitor.dispose();
    await source.dispose();
  });

  test('dispose invalidates an in-flight read without a late observation',
      () async {
    final source = _ControlledRouteSource();
    final pendingRead = source.enqueueRead();
    final monitor = AuditionOutputRouteMonitor(source: source);
    final observations = <AuditionOutputRouteObservation>[];
    monitor.observations.listen(observations.add);

    final start = monitor.start();
    await monitor.dispose();
    pendingRead.complete({
      const AuditionOutputDevice(
        id: 'bluetooth',
        route: ClickAuditionOutputRoute.bluetooth,
      ),
    });
    await start;

    expect(observations, isEmpty);
    expect(
      monitor.current.route,
      ClickAuditionOutputRoute.unknown,
    );

    await source.dispose();
  });
}

class _FakeRouteSource implements AuditionOutputRouteSource {
  _FakeRouteSource(this.devices);

  final StreamController<void> _changes = StreamController.broadcast();
  Set<AuditionOutputDevice> devices;

  @override
  Stream<void> get connectedOutputsChanged => _changes.stream;

  @override
  Future<Set<AuditionOutputDevice>> getConnectedOutputs() async => devices;

  void emitChange() => _changes.add(null);

  Future<void> dispose() => _changes.close();
}

class _ControlledRouteSource implements AuditionOutputRouteSource {
  final StreamController<void> _changes = StreamController.broadcast();
  final List<Completer<Set<AuditionOutputDevice>>> _reads = [];
  var _readIndex = 0;

  @override
  Stream<void> get connectedOutputsChanged => _changes.stream;

  Completer<Set<AuditionOutputDevice>> enqueueRead() {
    final completer = Completer<Set<AuditionOutputDevice>>();
    _reads.add(completer);
    return completer;
  }

  @override
  Future<Set<AuditionOutputDevice>> getConnectedOutputs() {
    return _reads[_readIndex++].future;
  }

  Future<void> dispose() => _changes.close();
}
