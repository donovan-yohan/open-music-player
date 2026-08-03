import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/api_client.dart';
import 'package:open_music_player/core/services/stems_service.dart';
import 'package:open_music_player/core/stems/stem_channel_source.dart';
import 'package:open_music_player/features/stems/track_stem_channel_source.dart';

/// Scripted [StemsService] whose GET answer can change between calls, so a
/// pending -> ready transition is exercisable without a backend.
class _ScriptedStemsService implements StemsService {
  _ScriptedStemsService(this._responses);

  final List<TrackStems> _responses;
  int getCalls = 0;
  int requestCalls = 0;
  Object? getError;
  StemsRequestResult requestResult = const StemsRequestResult(
    trackId: 42,
    channelSet: defaultStemChannelSet,
    status: StemsStatus.pending,
    queued: true,
    queuePosition: 2,
  );

  @override
  Future<TrackStems> getTrackStems(
    int trackId, {
    String channelSet = defaultStemChannelSet,
  }) async {
    getCalls++;
    if (getError != null) throw getError!;
    // Hold the last scripted answer once the script runs out.
    final index = getCalls - 1;
    return _responses[index >= _responses.length ? _responses.length - 1 : index];
  }

  @override
  Future<StemsRequestResult> requestSeparation(
    int trackId, {
    String channelSet = defaultStemChannelSet,
  }) async {
    requestCalls++;
    return requestResult;
  }
}

TrackStems _ready({List<String> channels = const ['vocals', 'melody', 'bass', 'kick', 'perc']}) =>
    TrackStems(
      trackId: 42,
      channelSet: defaultStemChannelSet,
      status: StemsStatus.ready,
      channels: channels,
    );

TrackStems _pending({int queuePosition = 2}) => TrackStems(
      trackId: 42,
      channelSet: defaultStemChannelSet,
      status: StemsStatus.pending,
      queuePosition: queuePosition,
    );

void main() {
  test('an unbound source is honest and never calls the backend', () async {
    final service = _ScriptedStemsService([_ready()]);
    final source = TrackStemChannelSource(service: service);

    expect(source.trackId, isNull);
    expect(source.isAvailable, isFalse);
    expect(source.isPending, isFalse);
    expect(source.channels, isEmpty);

    await source.refresh();
    await source.requestSeparation();

    expect(service.getCalls, 0);
    expect(service.requestCalls, 0);
  });

  test('binding a track resolves availability from the manifest', () async {
    final source =
        TrackStemChannelSource(service: _ScriptedStemsService([_ready()]));

    await source.bindTrack(42);

    expect(source.isAvailable, isTrue);
    expect(source.status, StemsStatus.ready);
    expect(source.channels.map((c) => c.id).toList(),
        ['vocals', 'melody', 'bass', 'kick', 'perc']);
  });

  test('channels carry registry labels and ADR 0006 honesty copy', () async {
    final source =
        TrackStemChannelSource(service: _ScriptedStemsService([_ready()]));

    await source.bindTrack(42);

    final kick = source.channels.firstWhere((c) => c.id == 'kick');
    expect(kick.label, 'Kick (low drums)');
    expect(kick.honestyCopy, contains('not a clean kick track'));
    expect(
      source.channels.firstWhere((c) => c.id == 'perc').label,
      'Hats & Percussion',
    );
  });

  test('manifest channels render in canonical display order', () async {
    final service = _ScriptedStemsService([
      _ready(channels: ['perc', 'bass', 'vocals', 'kick', 'melody']),
    ]);
    final source = TrackStemChannelSource(service: service);

    await source.bindTrack(42);

    expect(source.channels.map((c) => c.id).toList(),
        ['vocals', 'melody', 'bass', 'kick', 'perc']);
  });

  test('a partial manifest only exposes the stems that exist', () async {
    final service =
        _ScriptedStemsService([_ready(channels: ['vocals', 'bass'])]);
    final source = TrackStemChannelSource(service: service);

    await source.bindTrack(42);

    expect(source.channels.map((c) => c.id).toList(), ['vocals', 'bass']);
  });

  test('a pending row reports in-flight, not available', () async {
    final source =
        TrackStemChannelSource(service: _ScriptedStemsService([_pending()]));

    await source.bindTrack(42);

    expect(source.isPending, isTrue);
    expect(source.isAvailable, isFalse);
    expect(source.channels, isEmpty);
    expect(source.queuePosition, 2);
  });

  test('requestSeparation triggers the opt-in and re-reads the row', () async {
    final service = _ScriptedStemsService([
      TrackStems.unavailable(42),
      _pending(),
    ]);
    final source = TrackStemChannelSource(service: service);
    await source.bindTrack(42);
    expect(source.status, StemsStatus.unavailable);

    await source.requestSeparation();

    expect(service.requestCalls, 1);
    expect(source.isPending, isTrue);
  });

  test('separation is not re-triggered while ready or in flight', () async {
    final readyService = _ScriptedStemsService([_ready()]);
    final ready = TrackStemChannelSource(service: readyService);
    await ready.bindTrack(42);
    await ready.requestSeparation();

    final pendingService = _ScriptedStemsService([_pending()]);
    final pending = TrackStemChannelSource(service: pendingService);
    await pending.bindTrack(42);
    await pending.requestSeparation();

    expect(readyService.requestCalls, 0, reason: 'already separated');
    expect(pendingService.requestCalls, 0, reason: 'already queued');
  });

  test('pending -> ready flips the panel on refresh', () async {
    final service = _ScriptedStemsService([_pending(), _ready()]);
    final source = TrackStemChannelSource(service: service);

    await source.bindTrack(42);
    expect(source.isAvailable, isFalse);

    await source.refresh();

    expect(source.isAvailable, isTrue);
    expect(source.channels, hasLength(5));
  });

  test('gain and mute are client-side state and notify listeners', () async {
    final source =
        TrackStemChannelSource(service: _ScriptedStemsService([_ready()]));
    await source.bindTrack(42);
    var notifications = 0;
    source.addListener(() => notifications++);

    await source.setGain('vocals', 0.25);
    await source.setMute('kick', true);

    expect(source.channels.firstWhere((c) => c.id == 'vocals').gain, 0.25);
    expect(source.channels.firstWhere((c) => c.id == 'kick').muted, isTrue);
    expect(source.channels.firstWhere((c) => c.id == 'bass').gain, 1.0);
    expect(notifications, 2);
  });

  test('gain is clamped and unknown channels are ignored', () async {
    final source =
        TrackStemChannelSource(service: _ScriptedStemsService([_ready()]));
    await source.bindTrack(42);

    await source.setGain('vocals', 4.2);
    expect(source.channels.firstWhere((c) => c.id == 'vocals').gain, 1.0);

    await source.setGain('vocals', -1);
    expect(source.channels.firstWhere((c) => c.id == 'vocals').gain, 0.0);

    await source.setGain('hihat', 0);
    await source.setMute('hihat', true);
    expect(source.channels.map((c) => c.id), isNot(contains('hihat')));
  });

  test('a refresh keeps the mix the user already dialled in', () async {
    final service = _ScriptedStemsService([_ready(), _ready()]);
    final source = TrackStemChannelSource(service: service);
    await source.bindTrack(42);
    await source.setGain('vocals', 0.1);
    await source.setMute('perc', true);

    await source.refresh();

    expect(source.channels.firstWhere((c) => c.id == 'vocals').gain, 0.1);
    expect(source.channels.firstWhere((c) => c.id == 'perc').muted, isTrue);
  });

  test('a channel dropped from the manifest drops its fader state', () async {
    final service = _ScriptedStemsService([
      _ready(),
      _ready(channels: ['vocals', 'bass']),
    ]);
    final source = TrackStemChannelSource(service: service);
    await source.bindTrack(42);
    await source.setMute('perc', true);

    await source.refresh();

    expect(source.channels.map((c) => c.id).toList(), ['vocals', 'bass']);
    await source.setMute('perc', false);
    expect(source.channels.map((c) => c.id), isNot(contains('perc')));
  });

  test('rebinding the same track keeps the faders; a new track clears them',
      () async {
    final service = _ScriptedStemsService([_ready()]);
    final source = TrackStemChannelSource(service: service);
    await source.bindTrack(42);
    await source.setGain('vocals', 0.3);

    await source.bindTrack(42);
    expect(source.channels.firstWhere((c) => c.id == 'vocals').gain, 0.3);
    expect(service.getCalls, 1, reason: 'a rebuild must not refetch');

    await source.bindTrack(77);
    expect(source.channels.firstWhere((c) => c.id == 'vocals').gain, 1.0);
    expect(source.trackId, 77);
  });

  test('binding null unbinds without hitting the backend', () async {
    final service = _ScriptedStemsService([_ready()]);
    final source = TrackStemChannelSource(service: service);
    await source.bindTrack(42);

    await source.bindTrack(null);

    expect(source.trackId, isNull);
    expect(source.isAvailable, isFalse);
    expect(service.getCalls, 1);
  });

  test('a transport failure is surfaced, not swallowed', () async {
    final service = _ScriptedStemsService([_ready()]);
    final source = TrackStemChannelSource(service: service);
    service.getError = ApiException(
      code: 'SERVICE_DISABLED',
      message: 'stem separation is unavailable',
      statusCode: 503,
    );

    await source.bindTrack(42);

    expect(source.errorMessage, contains('stem separation is unavailable'));
    expect(source.isAvailable, isFalse);
    expect(source.isLoading, isFalse);
  });

  test('the honesty copy names the Rung B gap', () {
    expect(stemPreviewNotAudibleCopy, contains('not yet audible'));
  });
}
