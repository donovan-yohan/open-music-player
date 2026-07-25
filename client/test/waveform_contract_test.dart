import 'package:flutter_test/flutter_test.dart';

import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/models/waveform.dart';

void main() {
  test('bands3-v1 detail artifacts hydrate channels and signed peak tiers', () {
    final analysis = TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: {
        'waveform': {
          'sample_count': 4,
          'resolutions': [
            {
              'name': 'overview',
              'sample_count': 2,
              'artifact_ref': 'waveforms.overview',
            },
            {
              'name': 'detail',
              'sample_count': 4,
              'artifact_ref': 'waveforms.detail',
            },
          ],
          'channels': {
            'channel_set': 'bands3-v1',
            'audio_ref': null,
            'sample_count': 4,
            'normalization': {
              'kind': 'shared_peak',
              'scalar': 0.75,
            },
            'weights': {'low': 1.0, 'mid': 1.6, 'high': 2.8},
            'crossovers_hz': {'low_mid': 200, 'mid_high': 2000},
            'provenance': 'librosa-mel-bands-v2',
            'values': {
              'low': {
                'sample_count': 4,
                'artifact_ref': 'channels.detail.low',
                'normalization': {
                  'kind': 'shared_peak',
                  'scalar': 0.75,
                },
                'weight': 1.0,
                'provenance': 'librosa-mel-bands-v2',
              },
              'mid': {
                'sample_count': 4,
                'artifact_ref': 'channels.detail.mid',
              },
              'high': {
                'sample_count': 4,
                'artifact_ref': 'channels.detail.high',
              },
            },
          },
          'spectral_bands': {
            'low': {'sample_count': 4},
          },
        },
      },
      artifacts: {
        'waveforms': {
          'overview': {
            'peaks': [0.7, 0.8],
            'minima': [-0.6, -0.2],
            'maxima': [0.7, 0.8],
            'rms': [0.3, 0.4],
          },
          'detail': {
            'peaks': [0.1, 0.95, 0.12, 0.5],
            'minima': [-0.08, -0.9, -0.1, -0.4],
            'maxima': [0.1, 0.95, 0.12, 0.5],
            'rms': [0.04, 0.5, 0.05, 0.25],
          },
        },
        'channels': {
          'overview': {
            'low': [0.8, 0.2],
            'mid': [0.2, 0.7],
            'high': [0.1, 0.4],
          },
          'detail': {
            'low': [0.9, 0.8, 0.2, 0.1],
            'mid': [0.1, 0.3, 0.8, 0.7],
            'high': [0.05, 0.2, 0.7, 0.9],
          },
        },
        'spectral_bands': {
          'detail': {
            'low': [0.01, 0.01, 0.01, 0.01],
          },
        },
      },
    );

    final waveform = analysis.summary!.waveform!;
    expect(waveform.channels!.channelSet, 'bands3-v1');
    expect(waveform.channels!.audioRef, isNull);
    expect(waveform.channels!.normalization['kind'], 'shared_peak');
    expect(waveform.channels!.weights['high'], 2.8);
    expect(waveform.channels!.crossoversHz['low_mid'], 200);
    expect(waveform.channels!.values['low']!.weight, 1.0);
    expect(
      waveform.channels!.values['low']!.provenance,
      'librosa-mel-bands-v2',
    );
    expect(waveform.channels!.values['low']!.values, [0.9, 0.8, 0.2, 0.1]);
    expect(waveform.minPeaks, [-0.08, -0.9, -0.1, -0.4]);
    expect(waveform.maxPeaks, [0.1, 0.95, 0.12, 0.5]);
    expect(waveform.resolutions.first.minPeaks, [-0.6, -0.2]);
    expect(waveform.resolutions.last.maxPeaks, [0.1, 0.95, 0.12, 0.5]);

    final track = _track(analysis);
    final overview = richWaveformForTrack(track, sampleCount: 2);
    final detail = richWaveformForTrack(track, sampleCount: 4);
    expect(overview.resolutionLabel, 'overview');
    expect(overview.frames.first.resolvedMinPeak, -0.6);
    expect(overview.frames.first.resolvedMaxPeak, 0.7);
    expect(detail.resolutionLabel, 'detail');
    expect(detail.frames[1].resolvedMinPeak, -0.9);
    expect(detail.frames[1].resolvedMaxPeak, 0.95);
    expect(
      detail.frames.first.low,
      0.9,
      reason: 'named channels must win over the legacy spectral dual-write',
    );

    final roundTrip = TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: analysis.summary!.toJson(),
    );
    expect(
      roundTrip.summary!.waveform!.resolutions.last.channels['high']!.values,
      [0.05, 0.2, 0.7, 0.9],
    );
    expect(
      roundTrip.summary!.waveform!.resolutions.last.minPeaks,
      [-0.08, -0.9, -0.1, -0.4],
    );
  });

  test('legacy spectral bands remain a one-release parsing fallback', () {
    final track = _track(
      const TrackAnalysis(
        status: TrackAnalysisStatus.analyzed,
        summary: TrackAnalysisSummary(
          waveform: WaveformSummary(
            peaks: [0.4],
            spectralBands: {
              'low': SpectralBandSummary(values: [0.8]),
              'mid': SpectralBandSummary(values: [0.2]),
              'high': SpectralBandSummary(values: [0.1]),
            },
          ),
        ),
      ),
    );

    final waveform = richWaveformForTrack(track, sampleCount: 1);
    expect(waveform.frames.single.resolvedChannels, {
      'low': 0.8,
      'mid': 0.2,
      'high': 0.1,
    });
  });

  test('missing analysis stays empty, pending, and marker-honest', () {
    final waveform = richWaveformForTrack(_track(null), sampleCount: 1024);

    expect(waveform.frames, isEmpty);
    expect(waveform.beatsMs, isEmpty);
    expect(waveform.analyzed, isFalse);
    expect(waveform.resolutionLabel, 'pending');
  });
}

QueueTrack _track(TrackAnalysis? analysis) => QueueTrack(
      id: 'fixture-track',
      title: 'Fixture',
      artist: 'Test',
      duration: 4,
      addedAt: DateTime.utc(2026, 1, 1),
      analysis: analysis,
    );
