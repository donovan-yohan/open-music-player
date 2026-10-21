import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/services/stems_service.dart';
import 'package:open_music_player/core/stems/stem_channel_source.dart';
import 'package:open_music_player/features/stems/track_stem_channel_source.dart';

import 'support/gated_stems_service.dart';

TrackStems ready(int id, String channel) => TrackStems(
      trackId: id,
      channelSet: defaultStemChannelSet,
      status: StemsStatus.ready,
      channels: [channel],
    );

void main() {
  test('old GET failure cannot clear a newer binding loading flag or error',
      () async {
    final service = GatedStemsService();
    final source = TrackStemChannelSource(service: service);
    final first = source.bindTrack(1);
    final next = source.bindTrack(2);
    service.gets.first.$2.completeError(StateError('old GET'));
    await first;
    expect(source.isLoading, isTrue);
    expect(source.errorMessage, isNull);
    service.gets.last.$2.complete(ready(2, 'bass'));
    await next;
    source.dispose();
  });

  test('unbind invalidates a pending GET without reviving a manifest',
      () async {
    final service = GatedStemsService();
    final source = TrackStemChannelSource(service: service);
    final first = source.bindTrack(1);
    await source.bindTrack(null);
    service.gets.first.$2.complete(ready(1, 'vocals'));
    await first;
    expect(source.trackId, isNull);
    expect(source.channels, isEmpty);
    expect(source.isLoading, isFalse);
    source.dispose();
  });

  test('late POST cannot change a rebound track or refresh it', () async {
    final service = GatedStemsService();
    final source = TrackStemChannelSource(service: service);
    final binding = source.bindTrack(1);
    service.gets.single.$2.complete(TrackStems.unavailable(1));
    await binding;
    final posting = source.requestSeparation();
    final next = source.bindTrack(2);
    service.gets.last.$2.complete(ready(2, 'bass'));
    await next;
    service.posts.single.$2.complete(const StemsRequestResult(
      trackId: 1,
      channelSet: defaultStemChannelSet,
      status: StemsStatus.pending,
      queued: true,
    ));
    await posting;
    expect(service.gets.map((r) => r.$1), [1, 2]);
    expect(source.channels.single.id, 'bass');
    expect(source.isPending, isFalse);
    source.dispose();
  });

  for (final fail in [false, true]) {
    test('disposed GET ignores ${fail ? 'error' : 'success'} without notifying',
        () async {
      final service = GatedStemsService();
      final source = TrackStemChannelSource(service: service);
      final loading = source.bindTrack(1);
      source.dispose();
      if (fail) {
        service.gets.single.$2.completeError(StateError('late GET'));
      } else {
        service.gets.single.$2.complete(ready(1, 'vocals'));
      }
      await loading;
      expect(source.channels, isEmpty);
      expect(source.errorMessage, isNull);
      await source.refresh();
      await source.requestSeparation();
      await source.bindTrack(3);
      expect(service.gets, hasLength(1));
      expect(service.posts, isEmpty);
    });
  }

  test('disposed POST never performs its follow-up GET', () async {
    final service = GatedStemsService();
    final source = TrackStemChannelSource(service: service);
    final binding = source.bindTrack(1);
    service.gets.single.$2.complete(TrackStems.unavailable(1));
    await binding;
    final posting = source.requestSeparation();
    source.dispose();
    service.posts.single.$2.complete(const StemsRequestResult(
      trackId: 1,
      channelSet: defaultStemChannelSet,
      status: StemsStatus.pending,
      queued: true,
    ));
    await posting;
    expect(service.gets, hasLength(1));
    expect(source.isPending, isFalse);
  });

  test('rebind starts its own GET and ignores a late prior manifest', () async {
    final service = GatedStemsService();
    final source = TrackStemChannelSource(service: service);
    final first = source.bindTrack(1);
    final second = source.bindTrack(2);
    expect(service.gets.map((request) => request.$1), [1, 2]);
    service.gets[1].$2.complete(ready(2, 'bass'));
    await second;
    await source.setGain('bass', .4);
    service.gets.first.$2.complete(ready(1, 'vocals'));
    await first;
    expect(source.trackId, 2);
    expect(source.channels.single.id, 'bass');
    expect(source.channels.single.gain, .4);
    source.dispose();
  });
}
