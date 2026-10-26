import 'package:flutter_test/flutter_test.dart';

import '../integration_test/native_player_profile_probe.dart' as probe;

Map<String, dynamic> endpoint({int position = 100, int generation = 8}) => {
      'session_id': 'session',
      'session_generation': 2,
      'cue_id': 'cue',
      'queue_item_id': 'occurrence',
      'track_id': '500',
      'pool_generation': generation,
      'native': <String, dynamic>{
        'pid': 100,
        'platform_id': 'player',
        'source_id': 'source',
        'player_witness': 1,
        'item_witness': 1,
        'timebase_numer': 125,
        'timebase_denom': 3,
        'position_value': position,
        'position_timescale': 1000,
        'before_ticks': position * 1000,
        'after_ticks': position * 1000 + 10,
        'rate': 1.0,
        'time_control_status': 2,
        'player_status': 1,
        'item_status': 1,
        'error_present': false,
      },
    };

void main() {
  test('real Library DTO becomes ordinary playback payload', () {
    final value = probe.nativeProbePlaybackTrack({
      'id': 500,
      'title': 'Fixture',
      'duration_ms': 30000,
    });
    expect(value['id'], 500);
    expect(value['duration'], 30.0);
  });

  test('normal pool synchronization does not invalidate endpoint evidence', () {
    probe.validateNativeEndpointPair(
      endpoint(),
      endpoint(position: 850, generation: 13),
    );
  });

  for (final key in [
    'session_id',
    'session_generation',
    'cue_id',
    'queue_item_id',
    'track_id'
  ]) {
    test('rejects changed canonical $key', () {
      final last = endpoint(position: 850)..[key] = 'changed';
      expect(() => probe.validateNativeEndpointPair(endpoint(), last),
          throwsStateError);
    });
  }
  for (final key in [
    'pid',
    'platform_id',
    'source_id',
    'player_witness',
    'item_witness',
    'timebase_numer',
    'timebase_denom'
  ]) {
    test('rejects changed native $key', () {
      final last = endpoint(position: 850);
      (last['native'] as Map)[key] = 'changed';
      expect(() => probe.validateNativeEndpointPair(endpoint(), last),
          throwsStateError);
    });
  }
  for (final key in [
    'rate',
    'time_control_status',
    'player_status',
    'item_status',
    'error_present'
  ]) {
    for (final side in ['first', 'last']) {
      test('rejects $side endpoint invalid $key', () {
        final first = endpoint();
        final last = endpoint(position: 850);
        ((side == 'first' ? first : last)['native'] as Map)[key] =
            key == 'error_present' ? true : 0;
        expect(() => probe.validateNativeEndpointPair(first, last),
            throwsStateError);
      });
    }
  }
  test('rejects stopped or backward native cursor', () {
    for (final position in [100, 90]) {
      expect(
          () => probe.validateNativeEndpointPair(
              endpoint(), endpoint(position: position)),
          throwsStateError);
    }
  });
  test('rejects overlapping native clock brackets', () {
    final last = endpoint(position: 850);
    (last['native'] as Map)['before_ticks'] = 100005;
    expect(() => probe.validateNativeEndpointPair(endpoint(), last),
        throwsStateError);
  });
}
