import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/models/queue_state.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';

void main() {
  test(
    'QueueState parses canonical queue items with camelCase fields',
    () {
      final state = QueueState.fromJson({
        'items': [
          {
            'id': 'q_42',
            'queueItemId': 'q_42',
            'trackId': 42,
            'title': 'Seed Track',
            'artist': 'Seed Artist',
            'album': 'QA Queue',
            'durationMs': 185000,
            'coverUrl': 'https://example.test/cover.png',
            'addedAt': '2026-06-03T00:00:00Z',
          },
        ],
        'currentPosition': 0,
        // Legacy server fields are deliberately ignored. PlaybackState's
        // QueueTimelineController is the only repeat/shuffle authority.
        'repeatMode': 'all',
        'shuffled': true,
      });

      expect(state.currentIndex, 0);
      expect(state.tracks, hasLength(1));
      expect(state.tracks.single.id, 'q_42');
      expect(state.tracks.single.playbackTrackId, '42');
      expect(state.tracks.single.title, 'Seed Track');
      expect(state.tracks.single.duration, 185);
      expect(state.tracks.single.coverUrl, 'https://example.test/cover.png');
    },
  );

  test(
    'QueueState parses queue item status aliases into track queue statuses',
    () {
      final state = QueueState.fromJson({
        'items': [
          {'id': 1, 'title': 'Queued', 'duration': 1, 'status': 'pending'},
          {
            'id': 2,
            'title': 'Downloading',
            'duration': 1,
            'downloadStatus': 'downloading',
          },
          {
            'id': 'q_failed',
            'queueItemId': 'q_failed',
            'trackId': 3,
            'title': 'Failed',
            'duration': 1,
            'playbackState': 'failed',
            'canRetry': true,
          },
          {
            'id': 'q_ready',
            'queueItemId': 'q_ready',
            'trackId': 4,
            'title': 'Ready',
            'duration': 1,
            'status': 'completed',
            'canPlay': true,
          },
        ],
        'currentPosition': 0,
      });

      expect(state.tracks[0].queueStatus, TrackQueueStatus.pending);
      expect(state.tracks[1].queueStatus, TrackQueueStatus.downloading);
      expect(state.tracks[2].queueStatus, TrackQueueStatus.failed);
      expect(state.tracks[2].id, 'q_failed');
      expect(state.tracks[2].queueItemId, 'q_failed');
      expect(state.tracks[2].playbackTrackId, '3');
      expect(state.tracks[2].canRetry, isTrue);
      expect(state.tracks[3].queueStatus, TrackQueueStatus.playable);
      expect(state.tracks[3].toPlaybackJson()['id'], '4');
    },
  );

  test('QueueState projects source-backed queue items for Search status', () {
    final state = QueueState.fromJson({
      'items': [
        {
          'queueItemId': 'q_source',
          'playbackState': 'downloading',
          'progress': 42,
          'sourceCandidate': {
            'candidateId': 'youtube:abc',
            'provider': 'youtube',
            'sourceUrl': 'https://youtube.test/watch?v=abc',
            'title': 'Plastic Love',
            'uploader': 'mariya channel',
            'durationMs': 253000,
            'thumbnailUrl': 'https://img.example/cover.jpg',
          },
          'canPlay': false,
        },
      ],
    });

    final track = state.tracks.single;
    expect(track.id, 'q_source');
    expect(track.queueItemId, 'q_source');
    expect(track.sourceCandidateId, 'youtube:abc');
    expect(track.sourceUrl, 'https://youtube.test/watch?v=abc');
    expect(track.title, 'Plastic Love');
    expect(track.artist, 'mariya channel');
    expect(track.duration, 253);
    expect(track.coverUrl, 'https://img.example/cover.jpg');
    expect(track.queueStatus, TrackQueueStatus.downloading);
    expect(track.canPlay, isFalse);
  });

  test('Track round-trips top-level source candidate fields', () {
    final track = Track(
      id: 'queue-item-1',
      queueItemId: 'queue-item-1',
      sourceCandidateId: 'yt:lofi-study-1',
      sourceUrl: 'https://youtube.example/watch?v=lofi-study-1',
      title: 'lofi study mix',
      artist: 'QA Turtle',
      duration: 185,
      addedAt: DateTime.utc(2026, 6, 4),
      queueStatus: TrackQueueStatus.pending,
    );

    final restored = Track.fromJson(track.toJson());

    expect(restored.sourceCandidateId, 'yt:lofi-study-1');
    expect(restored.sourceUrl, 'https://youtube.example/watch?v=lofi-study-1');
    expect(restored.queueStatus, TrackQueueStatus.pending);
    expect(restored.canPlay, isFalse);
  });

  test('QueueState parses real backend playbackState contract fields', () {
    final state = QueueState.fromJson({
      'items': [
        {
          'id': 'q_uploading',
          'queueItemId': 'q_uploading',
          'trackId': 12,
          'title': 'Uploading Should Not Be Playable',
          'duration': 180,
          'playbackState': 'uploading',
        },
        {
          'id': 'q_failed',
          'queueItemId': 'q_failed',
          'trackId': 13,
          'title': 'Failed Retry Track',
          'duration': 195,
          'playbackState': 'failed',
        },
        {
          'id': 'q_queued',
          'queueItemId': 'q_queued',
          'title': 'Queued Pending Track',
          'duration': 120,
          'playbackState': 'queued',
        },
        {
          'id': 'q_playable',
          'queueItemId': 'q_playable',
          'trackId': 14,
          'title': 'Playable Track',
          'duration': 200,
          'playbackState': 'playable',
        },
      ],
    });

    expect(state.tracks[0].queueStatus, TrackQueueStatus.downloading);
    expect(state.tracks[0].canPlay, isFalse);
    expect(state.tracks[0].queueItemId, 'q_uploading');
    expect(state.tracks[0].toPlaybackJson()['id'], '12');

    expect(state.tracks[1].queueStatus, TrackQueueStatus.failed);
    expect(state.tracks[1].canPlay, isFalse);
    expect(state.tracks[1].canRetry, isTrue);
    expect(state.tracks[1].queueItemId, 'q_failed');
    expect(state.tracks[1].toPlaybackJson()['id'], '13');

    expect(state.tracks[2].queueStatus, TrackQueueStatus.pending);
    expect(state.tracks[2].canPlay, isFalse);

    expect(state.tracks[3].queueStatus, TrackQueueStatus.playable);
    expect(state.tracks[3].canPlay, isTrue);
    expect(state.tracks[3].toPlaybackJson()['id'], '14');
  });

  test('QueueState parses queue analysis summary contract fields', () {
    final state = QueueState.fromJson({
      'items': [
        {
          'id': 'q_analysis',
          'queueItemId': 'q_analysis',
          'trackId': 42,
          'title': 'Analyzed Track',
          'duration': 198,
          'playbackState': 'playable',
          'analysisStatus': 'analyzed',
          'analysisUpdatedAt': '2026-07-10T11:00:00.123456Z',
          'analysisSummary': {
            'bpm': {'value': 124.0, 'confidence': 0.94},
            'beat_grid': {
              'beats_ms': [320, 804, 1288],
            },
            'downbeats': {
              'positions_ms': [320],
            },
            'key': {'value': 'A minor'},
            'camelot': {'value': '8A'},
            'energy': {'value': 0.73},
            'loudness': {'integrated_lufs': -11.8},
            'true_peak': {'dbtp': -1.2},
            'waveform': {
              'peaks': [0.0, 0.21, 0.65, 0.78, 0.58, 0.22],
              'rms': [0.0, 0.14, 0.41, 0.49, 0.37, 0.11],
              'sample_count': 6,
              'confidence': 0.99,
              'resolutions': [
                {'name': 'overview', 'sample_count': 6},
                {'name': 'detail', 'sample_count': 12},
              ],
            },
            'transients': {
              'count': 48,
              'strongest_ms': [10120, 20180, 30240],
            },
            'silence': {
              'ranges': [
                {'start_ms': 0, 'end_ms': 320},
              ],
            },
            'intro': {'start_ms': 320, 'end_ms': 16000},
            'outro': {'start_ms': 180000, 'end_ms': 197500},
            'sections': [
              {'label': 'intro', 'start_ms': 320, 'end_ms': 16000},
              {'label': 'drop', 'start_ms': 64000, 'end_ms': 128000},
            ],
            'cue_candidates': [
              {'kind': 'mix_in', 'start_ms': 16000},
              {'kind': 'mix_out', 'start_ms': 180000},
            ],
          },
        },
      ],
    });

    final analysis = state.tracks.single.analysis!;
    expect(analysis.status, TrackAnalysisStatus.analyzed);
    expect(
      analysis.updatedAt,
      DateTime.utc(2026, 7, 10, 11, 0, 0, 123, 456),
    );
    expect(
      state.tracks.single.toPlaybackJson()['analysisUpdatedAt'],
      '2026-07-10T11:00:00.123456Z',
    );
    expect(analysis.summary!.bpm!.numericValue, 124.0);
    expect(analysis.summary!.camelot!.textValue, '8A');
    expect(analysis.summary!.energy!.numericValue, 0.73);
    expect(analysis.summary!.beatGrid!.beatsMs, [320, 804, 1288]);
    expect(analysis.summary!.downbeats!.positionsMs, [320]);
    expect(analysis.summary!.loudness!.integratedLufs, -11.8);
    expect(analysis.summary!.truePeak!.dbtp, -1.2);
    expect(analysis.summary!.waveform!.sampleCount, 6);
    expect(analysis.summary!.waveform!.peaks, [
      0.0,
      0.21,
      0.65,
      0.78,
      0.58,
      0.22,
    ]);
    expect(analysis.summary!.waveform!.rms, [
      0.0,
      0.14,
      0.41,
      0.49,
      0.37,
      0.11,
    ]);
    expect(analysis.summary!.waveform!.resolutions, hasLength(2));
    expect(analysis.summary!.transients!.strongestMs, [10120, 20180, 30240]);
    expect(analysis.summary!.silence!.ranges.single.endMs, 320);
    expect(analysis.summary!.sections, hasLength(2));
    expect(analysis.summary!.cueCandidates, hasLength(2));
    expect(
      analysis.summary!.displayLabels,
      containsAll([
        '124 BPM',
        '3 beats',
        '1 downbeat',
        'A minor · 8A',
        'Energy 73%',
        'Loudness -11.8 LUFS',
        'Peak -1.2 dBTP',
        'Waveform 6 samples',
        '6 peaks',
        '2 waveform layers',
        '48 transients',
        '1 silence range',
        'Intro 0:00-0:16',
        'Outro 3:00-3:18',
        '2 sections',
        'Cue in 0:16',
        'Cue out 3:00',
      ]),
    );
  });

  test('QueueState applies manual analysis overrides before playback', () {
    final state = QueueState.fromJson({
      'items': [
        {
          'id': 'q_corrected',
          'queueItemId': 'q_corrected',
          'trackId': 99,
          'title': 'Corrected Track',
          'duration': 240,
          'playbackState': 'playable',
          'analysisStatus': 'analyzed',
          'analysisSummary': {
            'bpm': {'value': 118.0, 'confidence': 0.42},
            'beat_grid': {
              'bpm': 118.0,
              'beats_ms': [0, 508, 1016],
            },
            'downbeats': {
              'positions_ms': [0],
            },
            'key': {'value': 'G minor'},
            'camelot': {'value': '6A'},
          },
          'analysisOverrides': {
            'bpm': {
              'value': 124.0,
              'confidence': 1.0,
              'provenance': 'manual_override',
            },
            'beat_grid': {
              'bpm': 124.0,
              'beats_ms': [120, 604, 1088],
              'confidence': 1.0,
              'provenance': 'manual_override',
            },
            'downbeats': {
              'positions_ms': [120, 2056],
              'confidence': 1.0,
              'provenance': 'manual_override',
            },
            'key': {'value': 'A minor'},
            'camelot': {'value': '8A'},
          },
        },
      ],
    });

    final track = state.tracks.single;
    final analysis = track.analysis!;
    expect(analysis.summary!.bpm!.numericValue, 124);
    expect(analysis.summary!.bpm!.provenance, 'manual_override');
    expect(analysis.summary!.bpm!.confidence, 1.0);
    expect(analysis.summary!.beatGrid!.bpm, 124);
    expect(analysis.summary!.beatGrid!.beatsMs, [120, 604, 1088]);
    expect(analysis.summary!.beatGrid!.confidence, 1.0);
    expect(analysis.summary!.beatGrid!.provenance, 'manual_override');
    expect(analysis.summary!.downbeats!.positionsMs, [120, 2056]);
    expect(analysis.summary!.downbeats!.confidence, 1.0);
    expect(analysis.summary!.downbeats!.provenance, 'manual_override');
    expect(analysis.summary!.key!.textValue, 'A minor');
    expect(analysis.summary!.camelot!.textValue, '8A');

    final playbackJson = track.toPlaybackJson();
    expect(playbackJson['analysisSummary']['bpm']['value'], 124);
    expect(
      playbackJson['analysisSummary']['downbeats']['positions_ms'],
      [120, 2056],
    );
    expect(playbackJson['analysisOverrides'], isA<Map<String, dynamic>>());
  });

  test('QueueState parses non-success queue analysis states', () {
    final state = QueueState.fromJson({
      'items': [
        {'id': 'pending', 'title': 'Pending', 'analysisStatus': 'pending'},
        {
          'id': 'analyzing',
          'title': 'Analyzing',
          'analysisStatus': 'analyzing',
        },
        {'id': 'failed', 'title': 'Failed', 'analysisStatus': 'failed'},
        {'id': 'stale', 'title': 'Stale', 'analysisStatus': 'stale'},
        {
          'id': 'unsupported',
          'title': 'Unsupported',
          'analysisStatus': 'unsupported',
        },
      ],
    });

    expect(state.tracks[0].analysis!.status, TrackAnalysisStatus.pending);
    expect(state.tracks[1].analysis!.status, TrackAnalysisStatus.analyzing);
    expect(state.tracks[2].analysis!.status, TrackAnalysisStatus.failed);
    expect(state.tracks[3].analysis!.status, TrackAnalysisStatus.stale);
    expect(state.tracks[4].analysis!.status, TrackAnalysisStatus.unsupported);
  });

  test('Track keeps status-only analysis metadata summary absent', () {
    final track = Track.fromJson({
      'id': 'pending-analysis',
      'title': 'Pending Analysis',
      'analysisStatus': 'pending',
    });

    expect(track.analysis, isNotNull);
    expect(track.analysis!.status, TrackAnalysisStatus.pending);
    expect(track.analysis!.summary, isNull);
    expect(track.toJson(), isNot(contains('analysisSummary')));
  });

  test('Analysis metadata time labels clamp negative milliseconds', () {
    final range = AnalysisRange.fromJson({
      'start_ms': -5000,
      'end_ms': 1000,
    });
    final cue = CueCandidate.fromJson({
      'kind': 'mix_in',
      'start_ms': -900,
    });

    expect(range!.formattedRange, '0:00-0:01');
    expect(cue!.displayLabel, 'Cue in 0:00');
  });
}
