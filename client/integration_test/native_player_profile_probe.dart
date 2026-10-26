// Actual application root and ordinary API/playback path. This probe has a
// separate stdout result schema; nonaudio renderer v1 remains unchanged.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:open_music_player/app/app.dart';
import 'package:open_music_player/core/performance/fixture_tokens.dart';
import 'package:open_music_player/core/performance/performance_fixture_io.dart';
import 'package:open_music_player/main.dart' as production;
import 'package:open_music_player/shared/models/track.dart' as library_model;

Map<String, dynamic> nativeProbePlaybackTrack(Map<String, dynamic> track) =>
    library_model.Track.fromLibraryJson(track).toPlaybackJson();

// Inputs have already passed the owned AudioPlayer's strict snapshot validator.
// This oracle joins endpoints, not an uninterrupted playback interval.
void validateNativeEndpointPair(
  Map<String, dynamic> first,
  Map<String, dynamic> last,
) {
  final a = first['native'] as Map;
  final b = last['native'] as Map;
  for (final key in [
    'session_id',
    'session_generation',
    'cue_id',
    'queue_item_id',
    'track_id'
  ]) {
    if (first[key] != last[key]) throw StateError('native-readback-stale');
  }
  // Pool generation advances on ordinary timeline synchronization. Each
  // read fences its loaded source capability instead; generation is diagnostic.
  for (final key in [
    'pid',
    'platform_id',
    'source_id',
    'player_witness',
    'item_witness',
    'timebase_numer',
    'timebase_denom'
  ]) {
    if (a[key] != b[key]) throw StateError('native-readback-stale');
  }
  for (final endpoint in [a, b]) {
    if (endpoint['rate'] != 1 ||
        endpoint['time_control_status'] != 2 ||
        endpoint['player_status'] != 1 ||
        endpoint['item_status'] != 1 ||
        endpoint['error_present'] != false) {
      throw StateError('native-readback-progress-unavailable');
    }
  }
  // Integer cross-products avoid rounding tiny positive deltas to equality.
  if (BigInt.from(b['position_value'] as int) *
              BigInt.from(a['position_timescale'] as int) <=
          BigInt.from(a['position_value'] as int) *
              BigInt.from(b['position_timescale'] as int) ||
      (b['before_ticks'] as int) <= (a['after_ticks'] as int)) {
    throw StateError('native-readback-progress-unavailable');
  }
}

Future<void> main() async {
  if (!kProfileMode ||
      !performanceFixtureEnabled ||
      !const bool.fromEnvironment('SOUNDQ_NATIVE_PLAYER_READBACK')) {
    throw StateError('native-readback-probe-opt-in-required');
  }
  final samples = <Map<String, dynamic>>[];
  var status = 'failed';
  var code = 'journey-incomplete';
  OpenMusicPlayerApp? app;
  int? revision;
  var stage = 'startup';
  var refusal = 'none';
  try {
    await production.main();
    final until = DateTime.now().add(const Duration(seconds: 30));
    while (app == null && DateTime.now().isBefore(until)) {
      final root = WidgetsBinding.instance.rootElement;
      final pending = <Element>[if (root != null) root];
      while (pending.isNotEmpty) {
        final element = pending.removeLast();
        if (element.widget is OpenMusicPlayerApp) {
          app = element.widget as OpenMusicPlayerApp;
          break;
        }
        element.visitChildren(pending.add);
      }
      if (app == null) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    if (app == null || !app.authState.isAuthenticated) {
      throw StateError('native-readback-root-unavailable');
    }
    revision = app.authState.sessionRevision;
    stage = 'library';
    app.router.go('/library');
    final response = await app.apiClient.get<Map<String, dynamic>>(
      '/library',
      queryParameters: {'limit': 1, 'offset': 0},
    );
    final tracks = response.data?['tracks'];
    if (tracks is! List || tracks.length != 1) {
      throw StateError('native-readback-source-unavailable');
    }
    stage = 'play';
    await app.playbackState.playTrack(
      nativeProbePlaybackTrack(Map<String, dynamic>.from(tracks.single as Map)),
    );
    final capability =
        Platform.environment['SOUNDQ_NATIVE_PLAYER_READBACK_TOKEN'];
    if (capability == null) throw StateError('native-readback-opt-in-required');
    final clock = Stopwatch()..start();
    stage = 'first-native-sample';
    while (clock.elapsed < const Duration(seconds: 12)) {
      try {
        final sample = await app.playbackState
            .soundqNativeReadback(capability: capability);
        final native = sample['native'] as Map;
        if (native['rate'] == 1 &&
            native['time_control_status'] == 2 &&
            native['player_status'] == 1 &&
            native['item_status'] == 1 &&
            native['error_present'] == false &&
            (native['position_value'] as int) > 0) {
          samples.add(sample);
          break;
        }
      } catch (error) {
        refusal = error is StateError &&
                {
                  'native-readback-unavailable',
                  'native-readback-stale',
                  'native-readback-invalid',
                }.contains(error.message)
            ? error.message.toString()
            : 'sample-refused';
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (samples.isEmpty) throw StateError('native-readback-unavailable');
    await Future<void>.delayed(const Duration(milliseconds: 750));
    stage = 'second-native-sample';
    samples.add(
        await app.playbackState.soundqNativeReadback(capability: capability));
    if (app.authState.sessionRevision != revision ||
        !app.authState.isAuthenticated) {
      throw StateError('native-readback-account-changed');
    }
    validateNativeEndpointPair(samples.first, samples.last);
    var invalidRefused = false;
    try {
      await app.playbackState.soundqNativeReadback(capability: 'invalid');
    } catch (_) {
      invalidRefused = true;
    }
    if (!invalidRefused) throw StateError('native-readback-refusal-failed');
    status = 'observed-native-endpoint-progress';
    code = 'none';
  } catch (_) {
    // Exceptions can contain signed URLs. Export only fixed schema/code.
    code = 'native-readback-journey-failed';
  } finally {
    try {
      await app?.playbackState.pause();
    } catch (_) {/* Owner reaps child. */}
    final fixture = PerformanceFixture.active;
    stdout.writeln('SOUNDQ_NATIVE_PLAYER_DIAGNOSTIC ${jsonEncode({
          'schema': 'soundq.flutter.native-player-diagnostic.v1',
          if (fixture != null) ...fixture.provenance,
          'pid': pid,
          'status': status,
          'failure_code': code,
          'stage': stage,
          'last_sample_refusal': refusal,
          'samples': samples,
          'scope': 'actual-root-ephemeral-native-player-endpoints',
          'audio_output': 'acoustic-output-unverified',
          'continuous_playback': 'unverified-between-endpoints',
          'matched': false,
          'full_app_accepted': false,
        })}');
  }
}
