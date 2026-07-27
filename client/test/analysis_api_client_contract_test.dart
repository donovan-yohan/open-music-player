import 'dart:convert';

import 'package:audio_service/audio_service.dart' as audio_service;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:open_music_player/core/audio/queue_persistence.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/models/waveform.dart';

import 'support/analysis_envelope_fixture.dart';
import 'support/mock_dio_client.dart';

void main() {
  test('analysis GET preserves descriptor artifacts as rich waveform detail',
      () async {
    http.Request? seen;
    final client = mockQueueApiClient((request) async {
      seen = request;
      return http.Response(
        jsonEncode(productionBands3AnalysisEnvelope()),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final analysis = await client.getTrackAnalysis(42);

    expect(seen?.method, 'GET');
    expect(seen?.url.path, '/api/v1/tracks/42/analysis');
    _expectRichWaveformArtifacts(analysis);
  });

  test('analysis override PATCH preserves rich artifacts in its response',
      () async {
    http.Request? seen;
    final client = mockQueueApiClient((request) async {
      seen = request;
      return http.Response(
        jsonEncode(
          productionBands3AnalysisEnvelope(includeOverrides: true),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    final analysis = await client.updateTrackAnalysisOverrides(
      42,
      const TrackAnalysisOverrides(bpm: 124),
    );

    expect(seen?.method, 'PATCH');
    expect(seen?.url.path, '/api/v1/tracks/42/analysis/overrides');
    expect(
      (jsonDecode(seen!.body) as Map<String, dynamic>)['overrides']['bpm']
          ['value'],
      124,
    );
    expect(analysis.summary?.bpm?.numericValue, 124);
    _expectRichWaveformArtifacts(analysis);
  });

  test('analysis override API omits preserve and sends replace and clear',
      () async {
    final requests = <http.Request>[];
    final client = mockQueueApiClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({
          'status': 'analyzed',
          'overrides': <String, dynamic>{},
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });

    await client.updateTrackAnalysisOverrides(
      42,
      const TrackAnalysisOverrides(musicalKey: 'A minor'),
    );
    await client.updateTrackAnalysisOverrides(
      42,
      const TrackAnalysisOverrides(
        manualTiming: ManualTimingOverride(bpm: 126),
        timingMutation: AnalysisTimingMutation.replace,
      ),
      expectedRevision: 1,
    );
    await client.updateTrackAnalysisOverrides(
      42,
      const TrackAnalysisOverrides(
        timingMutation: AnalysisTimingMutation.clear,
      ),
      expectedRevision: 2,
    );

    final bodies = [
      for (final request in requests)
        jsonDecode(request.body) as Map<String, dynamic>,
    ];
    expect(bodies, hasLength(3));
    expect(bodies[0], isNot(contains('timing_mutation')));
    expect(bodies[1]['timing_mutation'], 'replace');
    expect(bodies[1]['expected_revision'], 1);
    expect(bodies[1]['overrides']['manual_timing_v2']['bpm'], 126);
    expect(bodies[2]['timing_mutation'], 'clear');
    expect(bodies[2]['expected_revision'], 2);
    expect(bodies[2]['overrides'], isEmpty);
  });

  test('rich analysis stays detail-free through playback persistence', () {
    final envelope = productionBands3AnalysisEnvelope();
    final analysis = TrackAnalysis.fromJson(
      status: envelope['status'],
      summary: envelope['summary'],
      artifacts: envelope['artifacts'],
      updatedAt: envelope['updated_at'],
    );
    expect(analysis.summary?.waveform?.maxPeaks, isNotEmpty);

    final serialized = mediaItemToPlaybackJson(
      audio_service.MediaItem(
        id: '42',
        title: 'Fixture',
        duration: const Duration(seconds: 4),
        extras: {
          'analysisStatus': analysis.status.name,
          'analysisSummary': analysis.summary!.toJson(),
          'analysisUpdatedAt': analysis.updatedAt!.toIso8601String(),
        },
      ),
    );
    final compact =
        Map<String, dynamic>.from(serialized['analysisSummary'] as Map);

    expect((compact['bpm'] as Map)['value'], 120);
    expect((compact['beat_grid'] as Map)['beats_ms'], [0, 500, 1000]);
    expect((compact['downbeats'] as Map)['positions_ms'], [0]);
    expect((compact['key'] as Map)['value'], 'A minor');
    expect((compact['camelot'] as Map)['value'], '8A');
    for (final detailKey in [
      'waveform',
      'loudness',
      'true_peak',
      'transients',
      'silence',
      'energy',
    ]) {
      expect(compact.containsKey(detailKey), isFalse, reason: detailKey);
    }
    expect(serialized.containsKey('artifacts'), isFalse);
    final encodedCompact = jsonEncode(compact);
    for (final detailToken in [
      'artifact_ref',
      'peaks',
      'minima',
      'maxima',
      'rms',
      'channels',
      'spectral_bands',
    ]) {
      expect(encodedCompact, isNot(contains(detailToken)), reason: detailToken);
    }
  });
}

void _expectRichWaveformArtifacts(TrackAnalysis analysis) {
  final waveform = analysis.summary?.waveform;
  expect(waveform?.minPeaks, [-0.08, -0.9, -0.1, -0.4]);
  expect(waveform?.maxPeaks, [0.1, 0.95, 0.12, 0.5]);
  expect(waveform?.channels?.values['low']?.values, [0.9, 0.8, 0.2, 0.1]);
  expect(waveform?.channels?.values['mid']?.values, [0.1, 0.3, 0.8, 0.7]);
  expect(waveform?.channels?.values['high']?.values, [0.05, 0.2, 0.7, 0.9]);

  final rich = richWaveformForTrack(
    QueueTrack(
      id: '42',
      playbackTrackId: '42',
      title: 'Fixture',
      artist: 'Test',
      duration: 4,
      addedAt: DateTime.utc(2026, 1, 1),
      analysis: analysis,
    ),
    sampleCount: 4,
  );
  expect(rich.frames, hasLength(4));
  expect(rich.frames[1].resolvedMinPeak, -0.9);
  expect(rich.frames[1].resolvedMaxPeak, 0.95);
  expect(rich.frames.first.resolvedChannels, {
    'low': 0.9,
    'mid': 0.1,
    'high': 0.05,
  });
}
