Map<String, dynamic> productionBands3AnalysisEnvelope({
  bool includeOverrides = false,
}) {
  return {
    'track_id': 42,
    'status': 'analyzed',
    'updated_at': '2026-07-10T11:00:00.123456Z',
    'summary': {
      'bpm': {'value': 120},
      'beat_grid': {
        'bpm': 120,
        'beats_ms': [0, 500, 1000],
      },
      'downbeats': {
        'positions_ms': [0],
      },
      'key': {'value': 'A minor'},
      'camelot': {'value': '8A'},
      'energy': {'value': 0.72},
      'loudness': {'integrated_lufs': -11.4},
      'true_peak': {'dbtp': -1.1},
      'waveform': {
        'sample_count': 4,
        'resolutions': [
          {
            'name': 'detail',
            'sample_count': 4,
            'artifact_ref': 'waveforms.detail',
          },
        ],
        'spectral_bands': {
          'low': {
            'sample_count': 4,
            'artifact_ref': 'spectral_bands.detail.low',
          },
        },
        'channels': {
          'channel_set': 'bands3-v1',
          'audio_ref': null,
          'sample_count': 4,
          'normalization': {'kind': 'shared_peak', 'scalar': 0.9},
          'weights': {'low': 1.0, 'mid': 1.6, 'high': 2.8},
          'provenance': 'librosa-mel-bands-v2',
          'values': {
            'low': {
              'sample_count': 4,
              'artifact_ref': 'channels.detail.low',
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
      },
      'transients': {
        'count': 2,
        'strongest_ms': [10120, 20180],
      },
      'silence': {
        'ranges': [
          {'start_ms': 0, 'end_ms': 320},
        ],
      },
    },
    'artifacts': {
      'waveforms': {
        'detail': {
          'minima': [-0.08, -0.9, -0.1, -0.4],
          'maxima': [0.1, 0.95, 0.12, 0.5],
          'rms': [0.04, 0.5, 0.05, 0.25],
        },
      },
      'spectral_bands': {
        'detail': {
          'low': [0.9, 0.8, 0.2, 0.1],
        },
      },
      'channels': {
        'detail': {
          'low': [0.9, 0.8, 0.2, 0.1],
          'mid': [0.1, 0.3, 0.8, 0.7],
          'high': [0.05, 0.2, 0.7, 0.9],
        },
      },
    },
    if (includeOverrides)
      'overrides': {
        'bpm': {
          'value': 124,
          'confidence': 1.0,
          'provenance': 'manual_override',
        },
      },
  };
}

Map<String, dynamic> productionBands3DescriptorSummary() {
  final envelope = productionBands3AnalysisEnvelope();
  return Map<String, dynamic>.from(
    envelope['summary'] as Map<String, dynamic>,
  );
}
