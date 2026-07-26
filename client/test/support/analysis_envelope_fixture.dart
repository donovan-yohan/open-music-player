Map<String, dynamic> productionBands3AnalysisEnvelope({
  bool includeOverrides = false,
  double bpm = 120,
}) {
  final beatMs = (60000 / bpm).round();
  const normalization = {'kind': 'shared_peak', 'scalar': 0.9};
  const weights = {'low': 1.0, 'mid': 1.6, 'high': 2.8};
  const crossovers = {'low_mid': 250.0, 'mid_high': 4000.0};
  const provenance = 'librosa-mel-bands-v2';

  Map<String, dynamic> bandDescriptor(String name, String tier) => {
        'sample_count': tier == 'detail' ? 4 : 2,
        'artifact_ref': 'spectral_bands.$tier.$name',
        'normalization': normalization,
        'weight': weights[name],
        'provenance': provenance,
      };

  Map<String, dynamic> channelDescriptor(String name) => {
        'sample_count': 4,
        'artifact_ref': 'channels.detail.$name',
        'normalization': normalization,
        'weight': weights[name],
        'provenance': provenance,
      };

  return {
    'schema_version': 2,
    'track_id': 42,
    'status': 'analyzed',
    'requested_at': '2026-07-10T10:59:58.123456Z',
    'completed_at': '2026-07-10T11:00:00.123456Z',
    'updated_at': '2026-07-10T11:00:00.123456Z',
    'provenance': {
      'analyzer': 'audio-analyzer',
      'version': 'bands3-v1',
    },
    'summary': {
      ...productionCompactAnalysisSummary(bpm: bpm),
      'loudness': {
        'integrated_lufs': -11.4,
        'confidence': 0.94,
        'provenance': 'ebur128-v1',
      },
      'true_peak': {
        'dbtp': -1.1,
        'confidence': 0.94,
        'provenance': 'ebur128-v1',
      },
      'waveform': {
        'sample_count': 4,
        'resolutions': [
          {
            'name': 'overview',
            'sample_count': 2,
            'samples_per_pixel': 2,
            'artifact_ref': 'waveforms.overview',
            'spectral_bands': {
              for (final name in ['low', 'mid', 'high'])
                name: bandDescriptor(name, 'overview'),
            },
          },
          {
            'name': 'detail',
            'sample_count': 4,
            'samples_per_pixel': 1,
            'artifact_ref': 'waveforms.detail',
            'spectral_bands': {
              for (final name in ['low', 'mid', 'high'])
                name: bandDescriptor(name, 'detail'),
            },
          },
        ],
        'spectral_bands': {
          for (final name in ['low', 'mid', 'high'])
            name: bandDescriptor(name, 'detail'),
        },
        'channels': {
          'channel_set': 'bands3-v1',
          'audio_ref': null,
          'sample_count': 4,
          'normalization': normalization,
          'weights': weights,
          'crossovers_hz': crossovers,
          'provenance': provenance,
          'values': {
            for (final name in ['low', 'mid', 'high'])
              name: channelDescriptor(name),
          },
        },
        'confidence': 0.92,
        'provenance': provenance,
      },
      'transients': {
        'count': 2,
        'density_per_second': 0.5,
        'strongest_ms': [10120, 20180],
        'confidence': 0.86,
        'provenance': 'librosa-onset-v1',
      },
      'silence': {
        'leading_ms': 320,
        'trailing_ms': 180,
        'ranges': [
          {'start_ms': 0, 'end_ms': 320},
        ],
        'confidence': 0.97,
        'provenance': 'rms-threshold-v1',
      },
    },
    'artifacts': {
      'source': {
        'duration_ms': beatMs * 8,
        'sample_rate_hz': 44100,
        'channels': 2,
      },
      'waveforms': {
        'overview': {
          'peaks': [0.95, 0.5],
          'minima': [-0.9, -0.4],
          'maxima': [0.95, 0.5],
          'rms': [0.5, 0.25],
        },
        'detail': {
          'peaks': [0.1, 0.95, 0.12, 0.5],
          'minima': [-0.08, -0.9, -0.1, -0.4],
          'maxima': [0.1, 0.95, 0.12, 0.5],
          'rms': [0.04, 0.5, 0.05, 0.25],
        },
      },
      'spectral_bands': {
        'overview': {
          'low': [0.9, 0.2],
          'mid': [0.3, 0.8],
          'high': [0.2, 0.9],
        },
        'detail': {
          'low': [0.9, 0.8, 0.2, 0.1],
          'mid': [0.1, 0.3, 0.8, 0.7],
          'high': [0.05, 0.2, 0.7, 0.9],
        },
      },
      'channels': {
        'channel_set': 'bands3-v1',
        'audio_ref': null,
        'normalization': normalization,
        'weights': weights,
        'crossovers_hz': crossovers,
        'provenance': provenance,
        'overview': {
          'low': [0.9, 0.2],
          'mid': [0.3, 0.8],
          'high': [0.2, 0.9],
        },
        'detail': {
          'low': [0.9, 0.8, 0.2, 0.1],
          'mid': [0.1, 0.3, 0.8, 0.7],
          'high': [0.05, 0.2, 0.7, 0.9],
        },
      },
      'beat_grid': {
        'beats_ms': [0, beatMs, beatMs * 2],
      },
      'markers': {
        'downbeats_ms': [0],
        'transients_ms': [10120, 20180],
      },
      'waveform_resolution': {
        'overview': 2,
        'detail': 4,
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

Map<String, dynamic> productionBands3DescriptorSummary({
  double bpm = 120,
}) {
  final envelope = productionBands3AnalysisEnvelope(bpm: bpm);
  return Map<String, dynamic>.from(
    envelope['summary'] as Map<String, dynamic>,
  );
}

Map<String, dynamic> productionCompactAnalysisSummary({
  double bpm = 120,
}) {
  final beatMs = (60000 / bpm).round();
  return {
    'bpm': {
      'value': bpm,
      'confidence': 0.96,
      'provenance': 'beat-this-v1',
    },
    'beat_grid': {
      'bpm': bpm,
      'offset_ms': 0,
      'beats_ms': [0, beatMs, beatMs * 2],
      'confidence': 0.94,
      'provenance': 'beat-this-v1',
    },
    'downbeats': {
      'positions_ms': [0],
      'confidence': 0.9,
      'provenance': 'beat-this-v1',
    },
    'key': {
      'value': 'A minor',
      'confidence': 0.88,
      'provenance': 'key-estimator-v1',
    },
    'camelot': {
      'value': '8A',
      'confidence': 0.88,
      'provenance': 'key-estimator-v1',
    },
    'energy': {
      'value': 0.72,
      'confidence': 0.91,
      'provenance': 'rms-energy-v1',
    },
  };
}
