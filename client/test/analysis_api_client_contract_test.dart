import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
