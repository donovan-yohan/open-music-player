import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/engine/tempo_automation.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/models/track.dart';
import 'package:open_music_player/models/track_analysis.dart';
import 'package:open_music_player/models/trim_range.dart';
import 'package:open_music_player/providers/queue_provider.dart';

import 'support/mock_dio_client.dart';

Track _track({
  String id = '7',
  String queueItemId = 'queue-7',
  String? playbackTrackId = '7',
  int duration = 240,
  TrackAnalysis? analysis,
}) =>
    Track(
      id: id,
      queueItemId: queueItemId,
      playbackTrackId: playbackTrackId,
      title: 'Track $id',
      artist: 'Artist $id',
      duration: duration,
      addedAt: DateTime.utc(2026, 1, 1),
      analysis: analysis,
    );

TrackAnalysis _tempoAnalysis({
  double bpm = 120,
  int durationMs = 240000,
  DateTime? updatedAt,
}) {
  final beatMs = (60000 / bpm).round();
  final downbeatMs = beatMs * 8;
  return TrackAnalysis(
    status: TrackAnalysisStatus.analyzed,
    summary: TrackAnalysisSummary(
      bpm: AnalysisValue(value: bpm, confidence: 0.9),
      beatGrid: BeatGridSummary(
        bpm: bpm,
        beatsMs: List<int>.generate(
          (durationMs / beatMs).floor() + 1,
          (index) => index * beatMs,
        ),
        confidence: 0.9,
      ),
      downbeats: DownbeatSummary(
        positionsMs: List<int>.generate(
          (durationMs / downbeatMs).floor() + 1,
          (index) => index * downbeatMs,
        ),
        confidence: 0.9,
      ),
    ),
    updatedAt: updatedAt,
  );
}

class _FailedQueueMutation {
  final String name;
  final String method;
  final bool Function(String path) matchesPath;
  final Future<void> Function(QueueProvider provider) run;

  const _FailedQueueMutation({
    required this.name,
    required this.method,
    required this.matchesPath,
    required this.run,
  });
}

TimelineClip _fallback(Track track) => TimelineClip.clamped(
      id: 'clip_${track.queueItemId}',
      trackId: track.id,
      sourceDurationMs: track.durationMs,
      sourceStartMs: 0,
      sourceEndMs: track.durationMs,
      timelineStartMs: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // The unified ApiClient reads the access token from secure storage before
    // each request; back it with an in-memory mock so queue loads don't hit the
    // platform channel.
    FlutterSecureStorage.setMockInitialValues({});
  });

  test('waveform peaks are stable between UI rebuilds', () {
    final provider = QueueProvider(ApiClient());
    final track = _track();

    expect(
        identical(
            provider.waveformPeaksFor(track), provider.waveformPeaksFor(track)),
        isTrue);
  });

  test('rich timeline waveforms use analysis peaks and bucket zoom detail', () {
    final provider = QueueProvider(ApiClient());
    final track = _track(
      analysis: const TrackAnalysis(
        status: TrackAnalysisStatus.analyzed,
        summary: TrackAnalysisSummary(
          bpm: AnalysisValue(value: 120),
          beatGrid: BeatGridSummary(beatsMs: [0, 500, 1000, 1500]),
          downbeats: DownbeatSummary(positionsMs: [0]),
          waveform: WaveformSummary(
            peaks: [0.0, 0.25, 1.0, 0.5],
            rms: [0.0, 0.18, 0.62, 0.3],
            sampleCount: 4,
          ),
          transients: TransientsSummary(strongestMs: [750]),
          silence: SilenceSummary(
            ranges: [AnalysisRange(startMs: 0, endMs: 250)],
          ),
        ),
      ),
    );

    final overview = provider.waveformFor(track, 48);
    final detail = provider.waveformFor(track, 900);
    final closeDetail = provider.waveformFor(track, 6000);

    expect(overview.analyzed, isTrue);
    expect(overview.beatsMs, [0, 500, 1000, 1500]);
    expect(overview.downbeatsMs, [0]);
    expect(overview.transientsMs, [750]);
    expect(overview.silenceRanges.single.endMs, 250);
    expect(overview.frames.length, 4);
    expect(detail.frames.length, 4);
    expect(closeDetail.frames.length, 4);
    expect(provider.waveformFor(track, 100000).frames.length, 4);
    expect(identical(provider.waveformFor(track, 900), detail), isTrue);
  });

  test('timeline waveform cache retains real 65k detail and 80Hz frames', () {
    final provider = QueueProvider(ApiClient());
    final highResolution = _track(
      duration: 120,
      analysis: TrackAnalysis(
        status: TrackAnalysisStatus.analyzed,
        summary: TrackAnalysisSummary(
          waveform: WaveformSummary(
            peaks: List<double>.filled(65536, 0.5),
          ),
        ),
      ),
    );
    final eightyHz = _track(
      id: '80hz',
      queueItemId: 'queue-80hz',
      duration: 120,
      analysis: TrackAnalysis(
        status: TrackAnalysisStatus.analyzed,
        summary: TrackAnalysisSummary(
          waveform: WaveformSummary(
            peaks: List<double>.filled(9600, 0.5),
          ),
        ),
      ),
    );

    expect(
        provider.waveformFor(highResolution, 65536).frames, hasLength(65536));
    expect(provider.waveformFor(eightyHz, 65536).frames, hasLength(9600));
  });

  test('waveform cache is flat, source-shared, and counts peak bytes', () {
    final provider = QueueProvider(ApiClient());
    final analysis = TrackAnalysis(
      status: TrackAnalysisStatus.analyzed,
      updatedAt: DateTime.utc(2026, 1, 1),
      summary: TrackAnalysisSummary(
        waveform: WaveformSummary(peaks: List<double>.filled(2048, 0.5)),
      ),
    );
    final first = _track(
      id: 'shared-row',
      queueItemId: 'queue-a',
      playbackTrackId: '42',
      analysis: analysis,
    );
    final duplicate = _track(
      id: 'shared-row',
      queueItemId: 'queue-b',
      playbackTrackId: '42',
      analysis: analysis,
    );

    final detail = provider.waveformFor(first, 1024);
    expect(identical(provider.waveformFor(duplicate, 1024), detail), isTrue);
    expect(provider.cachedWaveformEntryCount, 1);

    provider.waveformFor(first, 2048);
    expect(provider.cachedWaveformEntryCount, 2);
    final beforePeaks = provider.cachedWaveformByteCount;
    expect(
      identical(
        provider.waveformPeaksFor(first),
        provider.waveformPeaksFor(duplicate),
      ),
      isTrue,
    );
    expect(provider.cachedWaveformEntryCount, 3);
    expect(provider.cachedWaveformByteCount, greaterThan(beforePeaks));
  });

  test('waveform cache enforces true frame and byte LRU budgets', () {
    final provider = QueueProvider(ApiClient());
    final analysis = TrackAnalysis(
      status: TrackAnalysisStatus.analyzed,
      updatedAt: DateTime.utc(2026, 1, 1),
      summary: TrackAnalysisSummary(
        waveform: WaveformSummary(
          peaks: List<double>.filled(65536, 0.5),
        ),
      ),
    );
    Track sourceTrack(int index) => _track(
          id: 'source-$index',
          queueItemId: 'queue-$index',
          playbackTrackId: '${100 + index}',
          analysis: analysis,
        );

    final first = provider.waveformFor(sourceTrack(0), 65536);
    final second = provider.waveformFor(sourceTrack(1), 65536);
    provider.waveformFor(sourceTrack(2), 65536);
    expect(
        identical(provider.waveformFor(sourceTrack(0), 65536), first), isTrue);
    provider.waveformFor(sourceTrack(3), 65536);

    expect(provider.cachedWaveformFrameCount, lessThanOrEqualTo(196608));
    expect(
        provider.cachedWaveformByteCount, lessThanOrEqualTo(12 * 1024 * 1024));
    expect(
        identical(provider.waveformFor(sourceTrack(0), 65536), first), isTrue);
    expect(identical(provider.waveformFor(sourceTrack(1), 65536), second),
        isFalse);
  });

  test('compact playback analysis lazily hydrates full waveform by track id',
      () async {
    final notified = Completer<void>();
    var analysisRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method == 'GET' &&
            request.url.path.endsWith('/tracks/42/analysis')) {
          analysisRequests++;
          return http.Response(
            jsonEncode({
              'status': 'analyzed',
              'summary': {
                'beat_grid': {
                  'bpm': 120,
                  'beats_ms': [0, 500, 1000],
                },
                'waveform': {
                  'sample_count': 4,
                  'peaks': [0.1, 0.5, 0.9, 0.2],
                  'rms': [0.08, 0.3, 0.6, 0.12],
                  'spectral_bands': {
                    'low': {
                      'sample_count': 4,
                      'values': [0.9, 0.8, 0.4, 0.2],
                    },
                    'mid': {
                      'sample_count': 4,
                      'values': [0.2, 0.5, 0.9, 0.7],
                    },
                    'high': {
                      'sample_count': 4,
                      'values': [0.1, 0.2, 0.6, 0.9],
                    },
                  },
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
    );
    provider.addListener(() {
      if (!notified.isCompleted) notified.complete();
    });

    final playbackTrack = _track(
      id: 'playback_queue_0',
      queueItemId: '0',
      playbackTrackId: '42',
      analysis: _tempoAnalysis(),
    );

    final compact = provider.trackWithAnalysis(playbackTrack);
    expect(compact.analysis?.summary?.bpm?.numericValue, 120);
    expect(compact.analysis?.summary?.waveform, isNull);
    await notified.future.timeout(const Duration(seconds: 1));

    final enriched = provider.trackWithAnalysis(playbackTrack);
    expect(analysisRequests, 1);
    expect(enriched.analysis?.status, TrackAnalysisStatus.analyzed);
    expect(provider.waveformFor(enriched, 512).analyzed, isTrue);
    expect(provider.waveformFor(enriched, 512).frames.first.low,
        greaterThan(provider.waveformFor(enriched, 512).frames.first.high));
  });

  test('analyzed compact update replaces cached pending analysis', () async {
    final firstResponse = Completer<void>();
    final secondResponse = Completer<void>();
    var analysisRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        analysisRequests++;
        if (analysisRequests == 1) {
          return http.Response(
            jsonEncode({'status': 'pending'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response(
          jsonEncode({
            'status': 'analyzed',
            'summary': {
              'bpm': {'value': 128},
              'waveform': {
                'sample_count': 4,
                'peaks': [0.1, 0.4, 0.9, 0.2],
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    provider.addListener(() {
      if (analysisRequests == 1 && !firstResponse.isCompleted) {
        firstResponse.complete();
      } else if (analysisRequests == 2 && !secondResponse.isCompleted) {
        secondResponse.complete();
      }
    });

    final pending = _track(
      playbackTrackId: '42',
      analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
    );
    provider.trackWithAnalysis(pending);
    await firstResponse.future.timeout(const Duration(seconds: 1));

    final analyzed = _track(
      playbackTrackId: '42',
      analysis: _tempoAnalysis(bpm: 128),
    );
    expect(
      provider.trackWithAnalysis(analyzed).analysis?.summary?.bpm?.numericValue,
      128,
    );
    await secondResponse.future.timeout(const Duration(seconds: 1));

    final hydrated = provider.trackWithAnalysis(analyzed);
    expect(analysisRequests, 2);
    expect(hydrated.analysis?.status, TrackAnalysisStatus.analyzed);
    expect(hydrated.analysis?.summary?.bpm?.numericValue, 128);
    expect(hydrated.analysis?.summary?.waveform?.peaks, isNotEmpty);
  });

  test('unchanged pending snapshot cannot downgrade hydrated analysis',
      () async {
    final hydrated = Completer<void>();
    var analysisRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        analysisRequests++;
        return http.Response(
          jsonEncode({
            'status': 'analyzed',
            'summary': {
              'bpm': {'value': 128},
              'waveform': {
                'sample_count': 4,
                'peaks': [0.1, 0.4, 0.9, 0.2],
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    provider.addListener(() {
      if (!hydrated.isCompleted) hydrated.complete();
    });
    final pending = _track(
      playbackTrackId: '42',
      analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
    );

    provider.trackWithAnalysis(pending);
    await hydrated.future.timeout(const Duration(seconds: 1));

    for (var i = 0; i < 5; i++) {
      final result = provider.trackWithAnalysis(pending);
      expect(result.analysis?.status, TrackAnalysisStatus.analyzed);
      expect(result.analysis?.summary?.waveform?.peaks, isNotEmpty);
    }
    expect(analysisRequests, 1);
  });

  test('pending analysis retries after the hydration cooldown', () async {
    final firstResponse = Completer<void>();
    final secondResponse = Completer<void>();
    var now = DateTime.utc(2026, 7, 10);
    var analysisRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        analysisRequests++;
        return http.Response(
          jsonEncode({'status': 'pending'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      analysisClock: () => now,
    );
    provider.addListener(() {
      if (analysisRequests == 1 && !firstResponse.isCompleted) {
        firstResponse.complete();
      } else if (analysisRequests == 2 && !secondResponse.isCompleted) {
        secondResponse.complete();
      }
    });
    final pending = _track(
      playbackTrackId: '42',
      analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
    );

    provider.trackWithAnalysis(pending);
    await firstResponse.future.timeout(const Duration(seconds: 1));
    provider.trackWithAnalysis(pending);
    expect(analysisRequests, 1);

    now = now.add(const Duration(seconds: 16));
    provider.trackWithAnalysis(pending);
    await secondResponse.future.timeout(const Duration(seconds: 1));
    expect(analysisRequests, 2);
  });

  test('pending analysis schedules its own hydration retry', () async {
    final secondRequest = Completer<void>();
    var analysisRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        analysisRequests++;
        if (analysisRequests == 2 && !secondRequest.isCompleted) {
          secondRequest.complete();
        }
        return http.Response(
          jsonEncode(
            analysisRequests == 1
                ? {'status': 'pending'}
                : {
                    'status': 'analyzed',
                    'summary': {
                      'waveform': {
                        'sample_count': 4,
                        'peaks': [0.1, 0.4, 0.9, 0.2],
                      },
                    },
                  },
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      analysisRetryCooldown: const Duration(milliseconds: 10),
    );
    final pending = _track(
      playbackTrackId: '42',
      analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
    );

    provider.trackWithAnalysis(pending);
    await secondRequest.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(analysisRequests, 2);
    expect(
      provider.trackWithAnalysis(pending).analysis?.status,
      TrackAnalysisStatus.analyzed,
    );
    provider.dispose();
  });

  test('permanent analysis errors do not retry while interest is retained',
      () async {
    final firstRequest = Completer<void>();
    var analysisRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        analysisRequests++;
        if (!firstRequest.isCompleted) firstRequest.complete();
        return http.Response('', 404);
      }),
      analysisRetryCooldown: const Duration(milliseconds: 5),
    );
    final pending = _track(
      playbackTrackId: '42',
      analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
    );

    provider.trackWithAnalysis(pending);
    await firstRequest.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (var index = 0; index < 3; index++) {
      provider.trackWithAnalysis(pending);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(analysisRequests, 1);
    provider.dispose();
  });

  test('transient analysis errors stop after the bounded retry budget',
      () async {
    var analysisRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        analysisRequests++;
        return http.Response('', 503);
      }),
      analysisRetryCooldown: const Duration(milliseconds: 2),
    );
    final pending = _track(
      playbackTrackId: '42',
      analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
    );

    provider.trackWithAnalysis(pending);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    provider.trackWithAnalysis(pending);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(analysisRequests, 4);
    provider.dispose();
  });

  test('valid pending analysis keeps polling beyond transport retry budget',
      () async {
    final analyzed = Completer<void>();
    var analysisRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        analysisRequests++;
        if (analysisRequests == 5 && !analyzed.isCompleted) {
          analyzed.complete();
        }
        return http.Response(
          jsonEncode(
            analysisRequests < 5
                ? {'status': 'pending'}
                : {
                    'status': 'analyzed',
                    'summary': {
                      'waveform': {
                        'sample_count': 2,
                        'peaks': [0.2, 0.8],
                      },
                    },
                  },
          ),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      analysisRetryCooldown: const Duration(milliseconds: 1),
    );
    final pending = _track(
      playbackTrackId: '42',
      analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
    );

    provider.trackWithAnalysis(pending);
    await analyzed.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(analysisRequests, 5);
    expect(
      provider.trackWithAnalysis(pending).analysis?.status,
      TrackAnalysisStatus.analyzed,
    );
    provider.dispose();
  });

  test('clearing timeline interest cancels a pending analysis retry', () async {
    final firstResponse = Completer<void>();
    var analysisRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        analysisRequests++;
        return http.Response(
          jsonEncode({'status': 'pending'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
      analysisRetryCooldown: const Duration(milliseconds: 20),
    );
    provider.addListener(() {
      if (!firstResponse.isCompleted) firstResponse.complete();
    });
    final pending = _track(
      playbackTrackId: '42',
      analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
    );

    provider.trackWithAnalysis(pending);
    await firstResponse.future.timeout(const Duration(seconds: 1));
    provider.clearAnalysisHydrationInterest();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(analysisRequests, 1);
    provider.dispose();
  });

  test('new compact override merges into cached detailed analysis', () async {
    final firstResponse = Completer<void>();
    var analysisRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        analysisRequests++;
        return http.Response(
          jsonEncode({
            'status': 'analyzed',
            'summary': {
              'bpm': {'value': 120},
              'beat_grid': {
                'bpm': 120,
                'beats_ms': [0, 500, 1000],
              },
              'waveform': {
                'sample_count': 4,
                'peaks': [0.1, 0.4, 0.9, 0.2],
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    provider.addListener(() {
      if (analysisRequests == 1 && !firstResponse.isCompleted) {
        firstResponse.complete();
      }
    });

    final original = _track(
      playbackTrackId: '42',
      analysis: _tempoAnalysis(),
    );
    provider.trackWithAnalysis(original);
    await firstResponse.future.timeout(const Duration(seconds: 1));
    expect(
      provider.trackWithAnalysis(original).analysis?.summary?.bpm?.numericValue,
      120,
    );

    final corrected = _track(
      playbackTrackId: '42',
      analysis: const TrackAnalysis(
        status: TrackAnalysisStatus.analyzed,
        summary: TrackAnalysisSummary(
          bpm: AnalysisValue(value: 128),
          beatGrid: BeatGridSummary(bpm: 128),
        ),
        overrides: TrackAnalysisOverrides(bpm: 128),
      ),
    );
    final refreshed = provider.trackWithAnalysis(corrected);
    expect(analysisRequests, 1);
    expect(refreshed.analysis?.summary?.bpm?.numericValue, 128);
    expect(refreshed.analysis?.summary?.beatGrid?.beatsMs, [0, 500, 1000]);
    expect(refreshed.analysis?.summary?.waveform?.peaks, isNotEmpty);
  });

  test('hydration cache compaction preserves distinct timing provenance',
      () async {
    final hydrated = Completer<void>();
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        return http.Response(
          jsonEncode({
            'status': 'analyzed',
            'updated_at': '2026-07-10T12:00:00Z',
            'summary': {
              'bpm': {
                'value': 120,
                'confidence': 0.9,
                'provenance': 'analyzer-bpm',
              },
              'beat_grid': {
                'bpm': 120,
                'offset_ms': 25,
                'beats_ms': [25, 525, 1025],
                'confidence': 0.9,
                'provenance': 'analyzer-grid',
              },
              'downbeats': {
                'positions_ms': [25],
                'confidence': 0.9,
                'provenance': 'analyzer-downbeat',
              },
              'waveform': {
                'sample_count': 2,
                'peaks': [0.2, 0.8],
              },
            },
            'overrides': {
              'bpm': {'value': 124, 'provenance': 'bpm-source'},
              'beat_grid': {
                'offset_ms': 87,
                'beats_ms': [87, 571, 1055],
                'provenance': 'grid-source',
              },
              'downbeats': {
                'positions_ms': [87],
                'provenance': 'downbeat-source',
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    provider.addListener(() {
      if (!hydrated.isCompleted) hydrated.complete();
    });

    final track = _track(playbackTrackId: '42');
    provider.trackWithAnalysis(track);
    await hydrated.future.timeout(const Duration(seconds: 1));
    expect(
      provider
          .trackWithAnalysis(track, requestHydration: false)
          .analysis
          ?.summary
          ?.waveform
          ?.peaks,
      [0.2, 0.8],
    );

    provider.clearAnalysisHydrationInterest();
    final compacted =
        provider.trackWithAnalysis(track, requestHydration: false).analysis!;
    final overrides = compacted.overrides!;
    final json = overrides.toJson();
    final tempo = ClipTempoMetadata.fromSessionJson(
      ClipTempoMetadata.fromAnalysisSummary(
        compacted.summary?.toJson(),
        overrides: json,
      ).toJson(),
    );

    expect(compacted.summary?.waveform, isNull);
    expect(overrides.beatGridOffsetMs, 87);
    expect(overrides.bpmProvenance, 'bpm-source');
    expect(overrides.beatGridProvenance, 'grid-source');
    expect(overrides.downbeatProvenance, 'downbeat-source');
    expect(json['bpm']['provenance'], 'bpm-source');
    expect(json['beat_grid']['provenance'], 'grid-source');
    expect(json['downbeats']['provenance'], 'downbeat-source');
    expect(tempo.beatGridOffsetMs, 87);
    expect(tempo.bpmProvenance, 'bpm-source');
    expect(tempo.beatGridProvenance, 'grid-source');
    expect(tempo.downbeatProvenance, 'downbeat-source');
    provider.dispose();
  });

  test('explicit compact override clear replaces cached detailed override',
      () async {
    final hydrated = Completer<void>();
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (!request.url.path.endsWith('/tracks/42/analysis')) {
          return http.Response('', 404);
        }
        return http.Response(
          jsonEncode({
            'status': 'analyzed',
            'summary': {
              'bpm': {'value': 120},
              'beat_grid': {
                'bpm': 120,
                'beats_ms': [0, 500, 1000],
              },
              'waveform': {
                'sample_count': 4,
                'peaks': [0.1, 0.4, 0.9, 0.2],
              },
            },
            'overrides': {
              'bpm': {'value': 128},
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    provider.addListener(() {
      if (!hydrated.isCompleted) hydrated.complete();
    });
    final corrected = _track(
      playbackTrackId: '42',
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'bpm': {'value': 120},
          'beat_grid': {'bpm': 120},
        },
        overrides: {
          'bpm': {'value': 128},
        },
        overridesPresent: true,
      ),
    );

    provider.trackWithAnalysis(corrected);
    await hydrated.future.timeout(const Duration(seconds: 1));
    expect(
      provider
          .trackWithAnalysis(corrected)
          .analysis
          ?.summary
          ?.bpm
          ?.numericValue,
      128,
    );

    final cleared = _track(
      playbackTrackId: '42',
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'bpm': {'value': 120},
          'beat_grid': {
            'bpm': 120,
            'beats_ms': [0, 500, 1000],
          },
        },
        overrides: const <String, dynamic>{},
        overridesPresent: true,
      ),
    );
    final result = provider.trackWithAnalysis(cleared);

    expect(result.analysis?.summary?.bpm?.numericValue, 120);
    expect(result.analysis?.overrides, isNull);
    expect(result.analysis?.overridesPresent, isTrue);
    expect(result.analysis?.summary?.waveform?.peaks, isNotEmpty);
    provider.dispose();
  });

  test('saved override rejects payloads older than its server revision',
      () async {
    final staleRevision = DateTime.utc(2026, 7, 10, 12);
    final savedRevision = staleRevision.add(const Duration(microseconds: 1));
    final reversionRevision =
        savedRevision.add(const Duration(microseconds: 1));

    Track analyzedTrack(double bpm, DateTime revision) => _track(
          id: '42',
          playbackTrackId: '42',
          analysis: TrackAnalysis.fromJson(
            status: 'analyzed',
            summary: {
              'bpm': {'value': 120},
              'waveform': {
                'sample_count': 2,
                'peaks': [0.2, 0.8],
              },
            },
            overrides: {
              'bpm': {'value': bpm},
            },
            overridesPresent: true,
            updatedAt: revision,
          ),
        );

    final staleGenerations = [
      analyzedTrack(124, staleRevision),
      analyzedTrack(126, staleRevision),
      analyzedTrack(128, staleRevision),
    ];
    final legitimateReversion = analyzedTrack(126, reversionRevision);
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method == 'PATCH' &&
            request.url.path.endsWith('/tracks/42/analysis/overrides')) {
          return http.Response(
            jsonEncode({
              'status': 'analyzed',
              'summary': {
                'bpm': {'value': 120},
                'waveform': {
                  'sample_count': 2,
                  'peaks': [0.2, 0.8],
                },
              },
              'overrides': <String, dynamic>{},
              'updated_at': savedRevision.toIso8601String(),
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
          return http.Response(
            jsonEncode({
              'items': [legitimateReversion.toJson()],
              'currentPosition': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/mix-plans')) {
          return http.Response(
            jsonEncode({'data': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
    );

    for (final stale in staleGenerations) {
      provider.trackWithAnalysis(stale, requestHydration: false);
    }
    final cleared = await provider.updateAnalysisOverrides(
      staleGenerations.last,
      const TrackAnalysisOverrides(),
    );
    expect(cleared.summary?.bpm?.numericValue, 120);

    for (final stale in staleGenerations) {
      final replayed =
          provider.trackWithAnalysis(stale, requestHydration: false);
      expect(replayed.analysis?.summary?.bpm?.numericValue, 120);
      expect(replayed.analysis?.overrides, isNull);
      expect(replayed.analysis?.overridesPresent, isTrue);
    }

    await provider.loadQueue();
    expect(
      provider.queue.tracks.single.analysis?.summary?.bpm?.numericValue,
      126,
    );

    for (final stale in staleGenerations) {
      final replayed =
          provider.trackWithAnalysis(stale, requestHydration: false);
      expect(replayed.analysis?.summary?.bpm?.numericValue, 126);
      expect(replayed.analysis?.updatedAt, reversionRevision);
    }
    provider.dispose();
  });

  test('newer concurrent queue load wins when responses complete out of order',
      () async {
    final firstStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final olderRevision = DateTime.utc(2026, 7, 10, 12);
    final newerRevision = olderRevision.add(const Duration(microseconds: 1));
    var queueRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
          queueRequests++;
          final requestNumber = queueRequests;
          if (requestNumber == 1) {
            firstStarted.complete();
            await releaseFirst.future;
          }
          final track = _track(
            id: '42',
            playbackTrackId: '42',
            analysis: _tempoAnalysis(
              bpm: requestNumber == 1 ? 120 : 130,
              updatedAt: requestNumber == 1 ? olderRevision : newerRevision,
            ),
          );
          return http.Response(
            jsonEncode({
              'items': [track.toJson()],
              'currentPosition': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/mix-plans')) {
          return http.Response(
            jsonEncode({'data': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
    );

    final firstLoad = provider.loadQueue();
    await firstStarted.future.timeout(const Duration(seconds: 1));
    final secondLoad = provider.loadQueue();
    await secondLoad;
    releaseFirst.complete();
    await firstLoad;

    expect(queueRequests, 2);
    expect(provider.isLoading, isFalse);
    expect(
      provider.queue.tracks.single.analysis?.summary?.bpm?.numericValue,
      130,
    );
    expect(provider.queue.tracks.single.analysis?.updatedAt, newerRevision);
    provider.dispose();
  });

  for (final loadCompletesFirst in <bool>[true, false]) {
    test(
        'successful add wins over an older load when ${loadCompletesFirst ? 'load' : 'add'} completes first',
        () async {
      final loadStarted = Completer<void>();
      final addStarted = Completer<void>();
      final releaseLoad = Completer<void>();
      final releaseAdd = Completer<void>();
      final staleTrack = _track(
        id: '41',
        queueItemId: 'queue-stale',
        playbackTrackId: '41',
      );
      final addedTrack = _track(
        id: '42',
        queueItemId: 'queue-added',
        playbackTrackId: '42',
      );
      final provider = QueueProvider(
        mockQueueApiClient((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            loadStarted.complete();
            await releaseLoad.future;
            return http.Response(
              jsonEncode({
                'items': [staleTrack.toJson()],
                'currentPosition': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/queue/items')) {
            addStarted.complete();
            await releaseAdd.future;
            return http.Response(
              jsonEncode({
                'items': [addedTrack.toJson()],
                'currentPosition': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('', 404);
        }),
      );

      final load = provider.loadQueue();
      await loadStarted.future.timeout(const Duration(seconds: 1));
      final add = provider.addToQueue(const ['42']);
      await addStarted.future.timeout(const Duration(seconds: 1));

      if (loadCompletesFirst) {
        releaseLoad.complete();
        await load;
        releaseAdd.complete();
      } else {
        releaseAdd.complete();
        await add;
        releaseLoad.complete();
      }
      await Future.wait([load, add]);

      expect(provider.queue.tracks.single.queueItemId, 'queue-added');
      expect(provider.isLoading, isFalse);
      expect(provider.error, isNull);
      provider.dispose();
    });
  }

  test('newer load waits for failed remove and never accepts its rollback',
      () async {
    final removeStarted = Completer<void>();
    final reloadStarted = Completer<void>();
    final releaseRemove = Completer<void>();
    final releaseReload = Completer<void>();
    final initialTrack = _track(
      id: '41',
      queueItemId: 'queue-initial',
      playbackTrackId: '41',
    );
    final loadedTrack = _track(
      id: '42',
      queueItemId: 'queue-loaded',
      playbackTrackId: '42',
    );
    var queueRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
          queueRequests++;
          if (queueRequests == 1) {
            return http.Response(
              jsonEncode({
                'items': [initialTrack.toJson()],
                'currentPosition': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          reloadStarted.complete();
          await releaseReload.future;
          return http.Response(
            jsonEncode({
              'items': [loadedTrack.toJson()],
              'currentPosition': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/mix-plans')) {
          return http.Response(
            jsonEncode({'data': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'DELETE' &&
            request.url.path.endsWith('/queue/items/queue-initial')) {
          removeStarted.complete();
          await releaseRemove.future;
          return http.Response('', 500);
        }
        return http.Response('', 404);
      }),
    );

    await provider.loadQueue();
    final remove = provider.removeFromQueue(0);
    await removeStarted.future.timeout(const Duration(seconds: 1));
    final reload = provider.loadQueue();
    await Future<void>.delayed(Duration.zero);
    expect(reloadStarted.isCompleted, isFalse);

    releaseRemove.complete();
    await remove;
    await reloadStarted.future.timeout(const Duration(seconds: 1));
    releaseReload.complete();
    await reload;

    expect(provider.queue.tracks.single.queueItemId, 'queue-loaded');
    expect(provider.isLoading, isFalse);
    expect(provider.error, isNull);
    provider.dispose();
  });

  test('failed clear reconciles a preceding successful add', () async {
    final addStarted = Completer<void>();
    final clearStarted = Completer<void>();
    final releaseAdd = Completer<void>();
    final addedTrack = _track(
      id: '42',
      queueItemId: 'queue-added',
      playbackTrackId: '42',
    );
    var serverTracks = <Track>[];
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method == 'POST' &&
            request.url.path.endsWith('/queue/items')) {
          addStarted.complete();
          await releaseAdd.future;
          serverTracks = [addedTrack];
          return http.Response(
            jsonEncode({
              'items': serverTracks.map((track) => track.toJson()).toList(),
              'currentPosition': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'DELETE' && request.url.path.endsWith('/queue')) {
          clearStarted.complete();
          return http.Response('', 500);
        }
        if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
          return http.Response(
            jsonEncode({
              'items': serverTracks.map((track) => track.toJson()).toList(),
              'currentPosition': serverTracks.isEmpty ? -1 : 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/mix-plans')) {
          return http.Response(
            jsonEncode({'data': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
    );

    final add = provider.addToQueue(const ['42']);
    await addStarted.future.timeout(const Duration(seconds: 1));
    final clear = provider.clearQueue();
    releaseAdd.complete();
    await clearStarted.future.timeout(const Duration(seconds: 1));
    await Future.wait([add, clear]);

    expect(provider.queue.tracks.single.queueItemId, 'queue-added');
    expect(provider.error, contains('Failed to clear queue'));
    provider.dispose();
  });

  test('successful reorder waits for failed reorder reconciliation', () async {
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final firstTrack = _track(
      id: '41',
      queueItemId: 'queue-41',
      playbackTrackId: '41',
    );
    final secondTrack = _track(
      id: '42',
      queueItemId: 'queue-42',
      playbackTrackId: '42',
    );
    final thirdTrack = _track(
      id: '43',
      queueItemId: 'queue-43',
      playbackTrackId: '43',
    );
    var serverTracks = [firstTrack, secondTrack, thirdTrack];
    var queueRequests = 0;
    var reorderRequests = 0;
    Map<String, dynamic>? successfulRequest;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
          queueRequests++;
          return http.Response(
            jsonEncode({
              'items': serverTracks.map((track) => track.toJson()).toList(),
              'currentPosition': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/mix-plans')) {
          return http.Response(
            jsonEncode({'data': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PUT' &&
            request.url.path.endsWith('/queue/reorder')) {
          reorderRequests++;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (reorderRequests == 1) {
            firstStarted.complete();
            await releaseFirst.future;
            return http.Response('', 500);
          }

          successfulRequest = body;
          secondStarted.complete();
          final queueItemId = body['queueItemId'] as String;
          final toPosition = body['toPosition'] as int;
          final fromPosition = serverTracks.indexWhere(
            (track) => track.queueItemId == queueItemId,
          );
          final reordered = List<Track>.from(serverTracks);
          final moved = reordered.removeAt(fromPosition);
          reordered.insert(toPosition, moved);
          serverTracks = reordered;
          return http.Response(
            jsonEncode({
              'items': serverTracks.map((track) => track.toJson()).toList(),
              'currentPosition': 1,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
    );

    await provider.loadQueue();
    final first = provider.reorderQueue(0, 2);
    await firstStarted.future.timeout(const Duration(seconds: 1));
    expect(
      provider.queue.tracks.map((track) => track.queueItemId),
      ['queue-42', 'queue-43', 'queue-41'],
    );

    final second = provider.reorderQueue(1, 0);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(secondStarted.isCompleted, isFalse);

    releaseFirst.complete();
    await first;
    await secondStarted.future.timeout(const Duration(seconds: 1));
    await second;

    expect(queueRequests, 2);
    expect(successfulRequest, {
      'queueItemId': 'queue-43',
      'toPosition': 0,
    });
    expect(
      provider.queue.tracks.map((track) => track.queueItemId),
      ['queue-43', 'queue-41', 'queue-42'],
    );
    expect(provider.error, isNull);
    provider.dispose();
  });

  test('off-queue analysis authority is bounded and evicts oldest floors', () {
    final provider = QueueProvider(
      mockQueueApiClient((_) async => http.Response('', 404)),
    );
    final revision = DateTime.utc(2026, 7, 10, 12);

    Track analyzedTrack(int id, double bpm, DateTime updatedAt) => _track(
          id: '$id',
          queueItemId: 'queue-$id',
          playbackTrackId: '$id',
          analysis: TrackAnalysis.fromJson(
            status: 'analyzed',
            summary: {
              'bpm': {'value': bpm},
              'waveform': {
                'sample_count': 4,
                'peaks': [0.1, 0.4, 0.8, 0.2],
              },
            },
            updatedAt: updatedAt,
          ),
        );

    for (var id = 1; id <= 256; id++) {
      provider.trackWithAnalysis(
        analyzedTrack(id, 100 + id.toDouble(), revision),
        requestHydration: false,
      );
    }

    expect(provider.retainedAnalysisAuthorityCount, lessThanOrEqualTo(128));
    final oldestReplay = provider.trackWithAnalysis(
      analyzedTrack(
        1,
        99,
        revision.subtract(const Duration(microseconds: 1)),
      ),
      requestHydration: false,
    );
    final newestReplay = provider.trackWithAnalysis(
      analyzedTrack(
        256,
        99,
        revision.subtract(const Duration(microseconds: 1)),
      ),
      requestHydration: false,
    );

    expect(oldestReplay.analysis?.summary?.bpm?.numericValue, 99);
    expect(newestReplay.analysis?.summary?.bpm?.numericValue, 356);
    expect(provider.retainedAnalysisAuthorityCount, lessThanOrEqualTo(128));
    provider.dispose();
  });

  test('large active queues retain bounded authority marker arrays', () async {
    final revision = DateTime.utc(2026, 7, 10, 12);
    final tracks = List<Track>.generate(
      129,
      (index) {
        final id = index + 1;
        final baseAnalysis = _tempoAnalysis(
          durationMs: 600000,
          updatedAt: revision,
        );
        final analysis = index == 0
            ? TrackAnalysis.fromJson(
                status: 'analyzed',
                summary: baseAnalysis.summary?.toJson(),
                overrides: {
                  'beat_grid': {
                    'beats_ms': List<int>.generate(
                      20000,
                      (marker) => marker * 10,
                    ),
                  },
                  'downbeats': {
                    'positions_ms': List<int>.generate(
                      5000,
                      (marker) => marker * 40,
                    ),
                  },
                },
                updatedAt: revision,
              )
            : baseAnalysis;
        return _track(
          id: '$id',
          queueItemId: 'queue-$id',
          playbackTrackId: '$id',
          duration: 600,
          analysis: analysis,
        );
      },
      growable: false,
    );
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
          return http.Response(
            jsonEncode({
              'items': tracks.map((track) => track.toJson()).toList(),
              'currentPosition': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/mix-plans')) {
          return http.Response(
            jsonEncode({'data': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
    );

    await provider.loadQueue();

    expect(provider.retainedAnalysisAuthorityCount, greaterThanOrEqualTo(129));
    for (final id in [1, 65, 129]) {
      final resolved = provider.trackWithAnalysis(
        _track(
          id: '$id',
          queueItemId: 'playback-$id',
          playbackTrackId: '$id',
          duration: 600,
        ),
        requestHydration: false,
      );
      expect(
        resolved.analysis?.summary?.beatGrid?.beatsMs.length,
        lessThanOrEqualTo(128),
      );
      expect(
        resolved.analysis?.summary?.downbeats?.positionsMs.length,
        lessThanOrEqualTo(64),
      );
      expect(
        resolved.analysis?.overrides?.beatsMs?.length ?? 0,
        lessThanOrEqualTo(128),
      );
      expect(
        resolved.analysis?.overrides?.downbeatsMs?.length ?? 0,
        lessThanOrEqualTo(64),
      );
    }
    provider.dispose();
  });

  test('concurrent override saves serialize server writes before reload',
      () async {
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final releaseFirst = Completer<void>();
    final releaseSecond = Completer<void>();
    var patchRequests = 0;
    var queueRequests = 0;
    double persistedBpm = 120;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
          queueRequests++;
          final persistedTrack = _track(
            id: '42',
            playbackTrackId: '42',
            analysis: TrackAnalysis.fromJson(
              status: 'analyzed',
              summary: {
                'bpm': {'value': 120},
                'waveform': {
                  'sample_count': 2,
                  'peaks': [0.2, 0.8],
                },
              },
              overrides: {
                'bpm': {'value': persistedBpm},
              },
              overridesPresent: true,
            ),
          );
          return http.Response(
            jsonEncode({
              'items': [persistedTrack.toJson()],
              'currentPosition': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/mix-plans')) {
          return http.Response(
            jsonEncode({'data': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PATCH' &&
            request.url.path.endsWith('/tracks/42/analysis/overrides')) {
          patchRequests++;
          final requestNumber = patchRequests;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final overrides = body['overrides'] as Map<String, dynamic>;
          final bpm =
              ((overrides['bpm'] as Map<String, dynamic>)['value'] as num)
                  .toDouble();
          if (requestNumber == 1) {
            firstStarted.complete();
            await releaseFirst.future;
          } else {
            secondStarted.complete();
            await releaseSecond.future;
          }
          persistedBpm = bpm;
          return http.Response(
            jsonEncode({
              'status': 'analyzed',
              'summary': {
                'bpm': {'value': 120},
                'waveform': {
                  'sample_count': 2,
                  'peaks': [0.2, 0.8],
                },
              },
              'overrides': {
                'bpm': {'value': bpm},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
    );
    final track = _track(
      id: '42',
      playbackTrackId: '42',
      analysis: TrackAnalysis.fromJson(
        status: 'analyzed',
        summary: {
          'bpm': {'value': 120},
          'waveform': {
            'sample_count': 2,
            'peaks': [0.2, 0.8],
          },
        },
      ),
    );
    provider.trackWithAnalysis(track);

    final first = provider.updateAnalysisOverrides(
      track,
      const TrackAnalysisOverrides(bpm: 128),
    );
    await firstStarted.future.timeout(const Duration(seconds: 1));
    final second = provider.updateAnalysisOverrides(
      track,
      const TrackAnalysisOverrides(bpm: 130),
    );
    final reload = provider.loadQueue();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(patchRequests, 1);
    expect(secondStarted.isCompleted, isFalse);
    expect(queueRequests, 0);

    releaseFirst.complete();
    await secondStarted.future.timeout(const Duration(seconds: 1));
    releaseSecond.complete();
    final firstResult = await first;
    final newest = await second;
    await reload;

    expect(firstResult.summary?.bpm?.numericValue, 128);
    expect(newest.summary?.bpm?.numericValue, 130);
    expect(patchRequests, 2);
    expect(queueRequests, 1);
    expect(persistedBpm, 130);
    expect(
      provider.queue.tracks.single.analysis?.summary?.bpm?.numericValue,
      130,
    );
    provider.dispose();
  });

  test('failed latest override preserves the prior serialized server write',
      () async {
    var patchRequests = 0;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method != 'PATCH' ||
            !request.url.path.endsWith('/tracks/42/analysis/overrides')) {
          return http.Response('', 404);
        }
        patchRequests++;
        if (patchRequests == 2) {
          return http.Response('', 500);
        }
        return http.Response(
          jsonEncode({
            'status': 'analyzed',
            'summary': {
              'bpm': {'value': 120},
              'waveform': {
                'sample_count': 2,
                'peaks': [0.2, 0.8],
              },
            },
            'overrides': {
              'bpm': {'value': 128},
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final track = _track(
      id: '42',
      playbackTrackId: '42',
      analysis: _tempoAnalysis(),
    );
    provider.trackWithAnalysis(track, requestHydration: false);

    final first = provider.updateAnalysisOverrides(
      track,
      const TrackAnalysisOverrides(bpm: 128),
    );
    final second = provider.updateAnalysisOverrides(
      track,
      const TrackAnalysisOverrides(bpm: 130),
    );

    expect((await first).summary?.bpm?.numericValue, 128);
    await expectLater(second, throwsA(isA<ApiException>()));
    expect(patchRequests, 2);
    expect(
      provider
          .trackWithAnalysis(track, requestHydration: false)
          .analysis
          ?.summary
          ?.bpm
          ?.numericValue,
      128,
    );
    provider.dispose();
  });

  for (final mutation in <_FailedQueueMutation>[
    _FailedQueueMutation(
      name: 'remove',
      method: 'DELETE',
      matchesPath: (path) => path.endsWith('/queue/items/queue-42'),
      run: (provider) => provider.removeFromQueue(0),
    ),
    _FailedQueueMutation(
      name: 'reorder',
      method: 'PUT',
      matchesPath: (path) => path.endsWith('/queue/reorder'),
      run: (provider) => provider.reorderQueue(0, 1),
    ),
    _FailedQueueMutation(
      name: 'clear',
      method: 'DELETE',
      matchesPath: (path) => path.endsWith('/queue'),
      run: (provider) => provider.clearQueue(),
    ),
  ]) {
    test('failed ${mutation.name} rollback preserves a concurrent correction',
        () async {
      final mutationStarted = Completer<void>();
      final releaseMutation = Completer<void>();
      final originalRevision = DateTime.utc(2026, 7, 10, 12);
      final correctedRevision =
          originalRevision.add(const Duration(microseconds: 1));
      final originalTrack = _track(
        id: '42',
        queueItemId: 'queue-42',
        playbackTrackId: '42',
        analysis: _tempoAnalysis(
          bpm: 120,
          updatedAt: originalRevision,
        ),
      );
      final otherTrack = _track(
        id: '43',
        queueItemId: 'queue-43',
        playbackTrackId: '43',
      );
      final provider = QueueProvider(
        mockQueueApiClient((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [originalTrack.toJson(), otherTrack.toJson()],
                'currentPosition': 0,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({'data': []}),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          if (request.method == mutation.method &&
              mutation.matchesPath(request.url.path)) {
            mutationStarted.complete();
            await releaseMutation.future;
            return http.Response('', 500);
          }
          if (request.method == 'PATCH' &&
              request.url.path.endsWith('/tracks/42/analysis/overrides')) {
            return http.Response(
              jsonEncode({
                'status': 'analyzed',
                'summary': {
                  'bpm': {'value': 120},
                },
                'overrides': {
                  'bpm': {'value': 128},
                },
                'updated_at': correctedRevision.toIso8601String(),
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response('', 404);
        }),
      );

      await provider.loadQueue();
      final queuedTrack = provider.queue.tracks.first;
      final mutationFuture = mutation.run(provider);
      await mutationStarted.future.timeout(const Duration(seconds: 1));
      await provider.updateAnalysisOverrides(
        queuedTrack,
        const TrackAnalysisOverrides(bpm: 128),
      );
      releaseMutation.complete();
      await mutationFuture;

      expect(provider.queue.tracks, hasLength(2));
      final restored = provider.queue.tracks.firstWhere(
        (track) => track.playbackTrackId == '42',
      );
      expect(restored.analysis?.summary?.bpm?.numericValue, 128);
      expect(restored.analysis?.updatedAt, correctedRevision);
      provider.dispose();
    });
  }

  test('analysis invalidation does not evict prefix-matching track ids', () {
    Track analyzedTrack(int id, double bpm) => _track(
          id: '$id',
          playbackTrackId: '$id',
          analysis: TrackAnalysis.fromJson(
            status: 'analyzed',
            summary: {
              'bpm': {'value': bpm},
              'waveform': {
                'sample_count': 2,
                'peaks': [0.2, 0.8],
              },
            },
          ),
        );
    final provider = QueueProvider(mockQueueApiClient((_) async {
      return http.Response('', 404);
    }));
    final track42 = analyzedTrack(42, 120);
    final track420 = analyzedTrack(420, 128);
    provider.trackWithAnalysis(track42);
    provider.trackWithAnalysis(track420);
    final waveform420 = provider.waveformFor(track420, 512);

    provider.trackWithAnalysis(analyzedTrack(42, 122));

    expect(identical(provider.waveformFor(track420, 512), waveform420), isTrue);
    provider.dispose();
  });

  test('older hydration response cannot overwrite a newer override', () async {
    final getStarted = Completer<void>();
    final releaseGet = Completer<void>();
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method == 'GET' &&
            request.url.path.endsWith('/tracks/42/analysis')) {
          getStarted.complete();
          await releaseGet.future;
          return http.Response(
            jsonEncode({
              'status': 'analyzed',
              'summary': {
                'bpm': {'value': 120},
                'waveform': {
                  'sample_count': 4,
                  'peaks': [0.1, 0.4, 0.9, 0.2],
                },
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PATCH' &&
            request.url.path.endsWith('/tracks/42/analysis/overrides')) {
          return http.Response(
            jsonEncode({
              'status': 'analyzed',
              'summary': {
                'bpm': {'value': 128},
                'waveform': {
                  'sample_count': 4,
                  'peaks': [0.2, 0.5, 1.0, 0.3],
                },
              },
              'overrides': {
                'bpm': {'value': 128},
              },
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
    );
    final original = _track(
      id: '42',
      playbackTrackId: '42',
      analysis: _tempoAnalysis(),
    );

    provider.trackWithAnalysis(original);
    await getStarted.future.timeout(const Duration(seconds: 1));
    final corrected = await provider.updateAnalysisOverrides(
      original,
      const TrackAnalysisOverrides(bpm: 128),
    );
    releaseGet.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    final result = provider.trackWithAnalysis(
      _track(
        id: '42',
        playbackTrackId: '42',
        analysis: corrected,
      ),
    );
    expect(result.analysis?.summary?.bpm?.numericValue, 128);
    expect(result.analysis?.summary?.waveform?.peaks.first, 0.2);
  });

  test('analysis hydration uses bounded request concurrency', () async {
    var active = 0;
    var maxActive = 0;
    final releases = <int, Completer<void>>{};
    final started = <int>[];
    final firstWaveStarted = Completer<void>();
    final allStarted = Completer<void>();
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        final match =
            RegExp(r'/tracks/(\d+)/analysis$').firstMatch(request.url.path);
        if (match == null) return http.Response('', 404);
        final trackId = int.parse(match.group(1)!);
        final release = releases.putIfAbsent(trackId, Completer<void>.new);
        started.add(trackId);
        if (started.length == 3 && !firstWaveStarted.isCompleted) {
          firstWaveStarted.complete();
        }
        if (started.length == 6 && !allStarted.isCompleted) {
          allStarted.complete();
        }
        active++;
        if (active > maxActive) maxActive = active;
        await release.future;
        active--;
        return http.Response(
          jsonEncode({
            'status': 'analyzed',
            'summary': {
              'waveform': {
                'sample_count': 2,
                'peaks': [0.2, 0.8],
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );

    for (var id = 1; id <= 6; id++) {
      provider.trackWithAnalysis(
        _track(
          id: '$id',
          playbackTrackId: '$id',
          analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
        ),
      );
    }
    await firstWaveStarted.future.timeout(const Duration(seconds: 1));
    expect(started, hasLength(3));
    expect(maxActive, 3);

    for (final id in List<int>.from(started)) {
      releases[id]!.complete();
    }
    await allStarted.future.timeout(const Duration(seconds: 1));
    for (final id in started.skip(3)) {
      releases[id]!.complete();
    }
    await Future<void>.delayed(Duration.zero);

    expect(maxActive, 3);
    provider.dispose();
  });

  test('queued hydration discards a stale generation before it starts',
      () async {
    final releases = <int, Completer<void>>{};
    final started = <int>[];
    final firstWaveStarted = Completer<void>();
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        final match =
            RegExp(r'/tracks/(\d+)/analysis$').firstMatch(request.url.path);
        if (match == null) return http.Response('', 404);
        final trackId = int.parse(match.group(1)!);
        started.add(trackId);
        if (started.length == 3 && !firstWaveStarted.isCompleted) {
          firstWaveStarted.complete();
        }
        final release = releases.putIfAbsent(trackId, Completer<void>.new);
        await release.future;
        return http.Response(
          jsonEncode({
            'status': 'analyzed',
            'summary': {
              'waveform': {
                'sample_count': 2,
                'peaks': [0.2, 0.8],
              },
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final pendingTracks = [
      for (var id = 1; id <= 4; id++)
        _track(
          id: '$id',
          playbackTrackId: '$id',
          analysis: const TrackAnalysis(status: TrackAnalysisStatus.pending),
        ),
    ];
    for (final track in pendingTracks) {
      provider.trackWithAnalysis(track);
    }
    await firstWaveStarted.future.timeout(const Duration(seconds: 1));

    provider.trackWithAnalysis(
      pendingTracks.last.copyWith(
        analysis: TrackAnalysis.fromJson(
          status: 'analyzed',
          summary: {
            'waveform': {
              'sample_count': 2,
              'peaks': [0.3, 0.9],
            },
          },
        ),
      ),
    );
    for (final release in releases.values) {
      release.complete();
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(started, isNot(contains(4)));
    provider.dispose();
  });

  test('analysis override updates patch backend and refresh timeline markers',
      () async {
    final originalAnalysis = TrackAnalysis.fromJson(
      status: 'analyzed',
      summary: {
        'bpm': {'value': 120},
        'beat_grid': {
          'bpm': 120,
          'beats_ms': [0, 500, 1000],
        },
        'downbeats': {
          'positions_ms': [0],
        },
        'waveform': {
          'sample_count': 4,
          'peaks': [0.1, 0.5, 0.9, 0.2],
          'rms': [0.08, 0.3, 0.6, 0.12],
        },
      },
    );
    final track = _track(
      id: '42',
      queueItemId: 'queue-42',
      playbackTrackId: '42',
      analysis: originalAnalysis,
    );
    Map<String, dynamic>? capturedPatch;
    final provider = QueueProvider(
      mockQueueApiClient((request) async {
        if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
          return http.Response(
            jsonEncode({
              'items': [track.toJson()],
              'currentPosition': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' &&
            request.url.path.endsWith('/mix-plans')) {
          return http.Response(
            jsonEncode({'data': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        if (request.method == 'PATCH' &&
            request.url.path.endsWith('/tracks/42/analysis/overrides')) {
          capturedPatch = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'status': 'analyzed',
              'summary': originalAnalysis.summary!.toJson(),
              'overrides': capturedPatch!['overrides'],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('', 404);
      }),
    );

    await provider.loadQueue();
    final before = provider.queue.tracks.single;
    expect(provider.waveformFor(before, 512).beatsMs, [0, 500, 1000]);

    await provider.updateAnalysisOverrides(
      before,
      const TrackAnalysisOverrides(
        bpm: 128,
        bpmConfidence: 1,
        beatsMs: [120, 589, 1058],
        downbeatsMs: [120],
        musicalKey: 'B minor',
        camelot: '10A',
      ),
    );

    final updated = provider.queue.tracks.single;
    expect(capturedPatch?['overrides']['bpm']['value'], 128);
    expect(updated.analysis?.summary?.bpm?.numericValue, 128);
    expect(updated.analysis?.summary?.key?.textValue, 'B minor');
    expect(provider.waveformFor(updated, 512).beatsMs.take(3).toList(), [
      120,
      589,
      1058,
    ]);
    expect(provider.waveformFor(updated, 512).downbeatsMs, [120]);
  });

  test('mix plan clips feed timeline placement and trim state when available',
      () {
    final provider = QueueProvider(ApiClient());
    final track = _track();
    final fallback = TimelineClip.clamped(
      id: 'clip_${track.id}',
      trackId: track.id,
      sourceDurationMs: track.durationMs,
      sourceStartMs: 0,
      sourceEndMs: track.durationMs,
      timelineStartMs: 0,
    );

    provider.applyMixPlanClips([
      MixPlanClip(
        clipId: 'clip-7',
        queueItemId: track.queueItemId,
        trackId: track.playbackTrackId!,
        sourceStartMs: 12000,
        sourceEndMs: 180000,
        timelineStartMs: 42000,
      ),
    ]);

    expect(provider.trimRangeFor(track).startOffsetMs, 12000);
    expect(provider.trimRangeFor(track).endOffsetMs, 180000);
    expect(provider.timelineClipFor(track, fallback).timelineStartMs, 42000);
    expect(provider.timelineClipFor(track, fallback).sourceStartMs, 12000);
  });

  test(
      'timeline edit gestures update mix plan contract fields without local-only trim regression',
      () {
    final provider = QueueProvider(ApiClient());
    final track = _track();
    provider.applyMixPlanClips([
      MixPlanClip(
        clipId: 'clip-7',
        queueItemId: track.queueItemId,
        trackId: track.playbackTrackId!,
        sourceStartMs: 0,
        sourceEndMs: track.durationMs,
        timelineStartMs: 10000,
      ),
    ]);

    provider.setTimelineStartMs(track, 25000);
    provider.setStartOffsetMs(track, 30000);
    provider.setEndOffsetMs(track, 190000);

    final fallback = TimelineClip.clamped(
      id: 'clip_${track.id}',
      trackId: track.id,
      sourceDurationMs: track.durationMs,
      sourceStartMs: 0,
      sourceEndMs: track.durationMs,
      timelineStartMs: 0,
    );
    final edited = provider.timelineClipFor(track, fallback);

    expect(edited.timelineStartMs, 25000);
    expect(edited.sourceStartMs, 30000);
    expect(edited.sourceEndMs, 190000);
    expect(provider.trimRangeFor(track).startOffsetMs, 30000);
    expect(provider.trimRangeFor(track).endOffsetMs, 190000);
  });

  group('duplicate queue item timing isolation', () {
    test('trim ranges prefer unique queueItemId over shared track id',
        () async {
      final provider = QueueProvider(ApiClient());
      final first = _track(id: '7', queueItemId: 'queue-a');
      final second = _track(id: '7', queueItemId: 'queue-b');

      await provider.setTrimRange(
        first,
        TrimRange.clamped(
          trackDurationMs: first.durationMs,
          startOffsetMs: 10000,
          endOffsetMs: 100000,
        ),
      );
      await provider.setTrimRange(
        second,
        TrimRange.clamped(
          trackDurationMs: second.durationMs,
          startOffsetMs: 20000,
          endOffsetMs: 120000,
        ),
      );

      expect(provider.trimRangeFor(first).startOffsetMs, 10000);
      expect(provider.trimRangeFor(second).startOffsetMs, 20000);
    });

    test('timeline starts prefer unique queueItemId over shared track id', () {
      final provider = QueueProvider(ApiClient());
      final first = _track(id: '7', queueItemId: 'queue-a');
      final second = _track(id: '7', queueItemId: 'queue-b');

      provider.setTimelineStartMs(first, 1000);
      provider.setTimelineStartMs(second, 2000);

      expect(
        provider.timelineClipFor(first, _fallback(first)).timelineStartMs,
        1000,
      );
      expect(
        provider.timelineClipFor(second, _fallback(second)).timelineStartMs,
        2000,
      );
    });

    test('mix plan clips prefer unique queueItemId over shared track id', () {
      final provider = QueueProvider(ApiClient());
      final first = _track(id: '7', queueItemId: 'queue-a');
      final second = _track(id: '7', queueItemId: 'queue-b');

      provider.applyMixPlanClips([
        MixPlanClip(
          clipId: 'clip-a',
          queueItemId: first.queueItemId,
          trackId: first.playbackTrackId!,
          sourceStartMs: 10000,
          sourceEndMs: 100000,
          timelineStartMs: 1000,
        ),
        MixPlanClip(
          clipId: 'clip-b',
          queueItemId: second.queueItemId,
          trackId: second.playbackTrackId!,
          sourceStartMs: 20000,
          sourceEndMs: 120000,
          timelineStartMs: 2000,
        ),
      ]);

      expect(
        provider.timelineClipFor(first, _fallback(first)).timelineStartMs,
        1000,
      );
      expect(
        provider.timelineClipFor(second, _fallback(second)).timelineStartMs,
        2000,
      );
    });

    test('loadQueue prunes stale shared local timing aliases', () async {
      final first = _track(id: '7', queueItemId: 'queue-a');
      final second = _track(id: '7', queueItemId: 'queue-b');
      final fresh = _track(id: '7', queueItemId: 'queue-c');
      var queueRequests = 0;
      final provider = QueueProvider(
        ApiClient(
          dio: mockQueueDio((request) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/queue')) {
              queueRequests++;
              final tracks = switch (queueRequests) {
                1 => [first.toJson(), second.toJson()],
                2 => [first.toJson()],
                _ => [first.toJson(), fresh.toJson()],
              };
              return http.Response(
                jsonEncode({'items': tracks, 'currentPosition': 0}),
                200,
              );
            }
            return http.Response('', 404);
          }),
        ),
      );

      await provider.loadQueue();
      await provider.setTrimRange(
        first,
        TrimRange.clamped(
          trackDurationMs: first.durationMs,
          startOffsetMs: 10000,
          endOffsetMs: 100000,
        ),
      );
      provider.setTimelineStartMs(first, 1000);
      await provider.setTrimRange(
        second,
        TrimRange.clamped(
          trackDurationMs: second.durationMs,
          startOffsetMs: 20000,
          endOffsetMs: 120000,
        ),
      );
      provider.setTimelineStartMs(second, 2000);

      await provider.loadQueue();
      await provider.loadQueue();

      expect(provider.trimRangeFor(first).startOffsetMs, 10000);
      expect(provider.timelineClipFor(first, _fallback(first)).timelineStartMs,
          1000);
      expect(provider.trimRangeFor(fresh).isFullTrack, isTrue);
      expect(
          provider.timelineClipFor(fresh, _fallback(fresh)).timelineStartMs, 0);
    });

    test('removing one duplicate prunes its stale mix plan aliases', () async {
      final first = _track(id: '7', queueItemId: 'queue-a');
      final second = _track(id: '7', queueItemId: 'queue-b');
      final provider = QueueProvider(
        ApiClient(
          dio: mockQueueDio((request) async {
            if (request.method == 'GET' &&
                request.url.path.endsWith('/queue')) {
              return http.Response(
                jsonEncode({
                  'items': [first.toJson(), second.toJson()],
                  'currentPosition': 0,
                }),
                200,
              );
            }
            if (request.method == 'DELETE' &&
                request.url.path.endsWith('/queue/items/queue-a')) {
              return http.Response(
                jsonEncode({
                  'items': [second.toJson()],
                  'currentPosition': 0,
                }),
                200,
              );
            }
            return http.Response('', 404);
          }),
        ),
      );

      await provider.loadQueue();
      provider.applyMixPlanClips([
        MixPlanClip(
          clipId: 'clip-a',
          queueItemId: first.queueItemId,
          trackId: first.playbackTrackId!,
          sourceStartMs: 10000,
          sourceEndMs: 100000,
          timelineStartMs: 1000,
        ),
        MixPlanClip(
          clipId: 'clip-b',
          queueItemId: second.queueItemId,
          trackId: second.playbackTrackId!,
          sourceStartMs: 20000,
          sourceEndMs: 120000,
          timelineStartMs: 2000,
        ),
      ]);

      await provider.removeFromQueue(0);

      expect(provider.queue.tracks, hasLength(1));
      expect(provider.queue.tracks.single.queueItemId, 'queue-b');
      expect(provider.mixPlanClips.containsKey('queue-a'), isFalse);
      expect(provider.mixPlanClips.containsKey('clip-a'), isFalse);
      expect(provider.mixPlanClips['queue-b']?.queueItemId, 'queue-b');
      expect(provider.mixPlanClips.containsKey('7'), isFalse);
      expect(
        provider.timelineClipFor(second, _fallback(second)).timelineStartMs,
        2000,
      );
    });
  });

  test('loadQueue hydrates queue timing from the saved Queue timing mix plan',
      () async {
    final track =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [track.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-queue-timing',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'clip-a',
                        'queueItemId': 'queue-a',
                        'trackId': 42,
                        'sourceStartMs': 12000,
                        'sourceEndMs': 90000,
                        'timelineStartMs': 30000,
                        'gainDb': 0,
                        'pitchMode': 'followTempo',
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': 108000,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();

    expect(provider.trimRangeFor(track).startOffsetMs, 12000);
    expect(provider.trimRangeFor(track).endOffsetMs, 90000);
    expect(provider.pitchModeFor(track), pitchModeFollowTempo);
    expect(provider.timelineClipFor(track, _fallback(track)).timelineStartMs,
        30000);
  });

  test(
      'loadQueue gives missing analyzed queue clips downbeat-locked default timing',
      () async {
    final first = _track(
      id: '42',
      queueItemId: 'queue-a',
      playbackTrackId: '42',
      analysis: _tempoAnalysis(),
    );
    final second = _track(
      id: '43',
      queueItemId: 'queue-b',
      playbackTrackId: '43',
      analysis: _tempoAnalysis(),
    );
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [first.toJson(), second.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-queue-timing',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'queue-a',
                        'queueItemId': 'queue-a',
                        'trackId': 42,
                        'sourceStartMs': 0,
                        'sourceEndMs': first.durationMs,
                        'timelineStartMs': 0,
                        'gainDb': 0,
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': first.durationMs,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();

    expect(
      provider.timelineClipFor(second, _fallback(second)).timelineStartMs,
      232000,
    );
    expect(provider.mixPlanClips['queue-b']?.queueItemId, 'queue-b');
  });

  test(
      'loadQueue does not hydrate stale queue-item-aware clips through shared track id',
      () async {
    final fresh =
        _track(id: '42', queueItemId: 'queue-new', playbackTrackId: '42');
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [fresh.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-queue-timing',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'queue-old',
                        'queueItemId': 'queue-old',
                        'trackId': 42,
                        'sourceStartMs': 12000,
                        'sourceEndMs': 90000,
                        'timelineStartMs': 30000,
                        'gainDb': 0,
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': 78000,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();

    expect(provider.trimRangeFor(fresh).isFullTrack, isTrue);
    expect(
        provider.timelineClipFor(fresh, _fallback(fresh)).timelineStartMs, 0);
    expect(provider.mixPlanClips, isEmpty);
  });

  test('legacy fallback save writes unique queue-item clip ids for duplicates',
      () async {
    final first =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final second =
        _track(id: '42', queueItemId: 'queue-b', playbackTrackId: '42');
    Map<String, dynamic>? savedBody;
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [first.toJson(), second.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-queue-timing',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'legacy-clip-42',
                        'queueItemId': '',
                        'trackId': 42,
                        'sourceStartMs': 12000,
                        'sourceEndMs': 90000,
                        'timelineStartMs': 30000,
                        'gainDb': 0,
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': 78000,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          if (request.method == 'PUT' &&
              request.url.path.endsWith('/mix-plans/plan-queue-timing')) {
            savedBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'plan-queue-timing',
                'schemaVersion': 1,
                'name': savedBody!['name'],
                'clips': savedBody!['clips'],
                'summary': {
                  'clipCount': 2,
                  'trackIds': [42],
                  'durationMs': 78000,
                },
                'version': 3,
                'createdAt': '2026-06-03T01:02:03Z',
                'updatedAt': '2026-06-03T02:03:05Z',
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();
    await provider.setStartOffsetMs(second, 10000);

    final clips = savedBody!['clips'] as List<dynamic>;
    expect(
        clips.map((clip) => clip['clipId']).toList(), ['queue-a', 'queue-b']);
    expect(clips.map((clip) => clip['queueItemId']).toList(),
        ['queue-a', 'queue-b']);
  });

  test('loadQueue keeps legacy clips without queueItemId as track-id fallback',
      () async {
    final fresh =
        _track(id: '42', queueItemId: 'queue-new', playbackTrackId: '42');
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [fresh.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-queue-timing',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'legacy-clip-42',
                        'queueItemId': '',
                        'trackId': 42,
                        'sourceStartMs': 12000,
                        'sourceEndMs': 90000,
                        'timelineStartMs': 30000,
                        'gainDb': 0,
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': 78000,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();

    expect(provider.trimRangeFor(fresh).startOffsetMs, 12000);
    expect(provider.trimRangeFor(fresh).endOffsetMs, 90000);
    expect(provider.timelineClipFor(fresh, _fallback(fresh)).timelineStartMs,
        30000);
  });

  test('trim edits save the current queue timing to the mix-plan API',
      () async {
    final first =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final second =
        _track(id: '43', queueItemId: 'queue-b', playbackTrackId: '43');
    Map<String, dynamic>? savedBody;
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [first.toJson(), second.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({'data': [], 'total': 0, 'limit': 50, 'offset': 0}),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/mix-plans')) {
            savedBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'plan-queue-timing',
                'schemaVersion': 1,
                'name': savedBody!['name'],
                'clips': savedBody!['clips'],
                'summary': {
                  'clipCount': 2,
                  'trackIds': [42, 43],
                  'durationMs': 240000,
                },
                'version': 1,
                'createdAt': '2026-06-03T01:02:03Z',
                'updatedAt': '2026-06-03T02:03:04Z',
              }),
              201,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();
    await provider.setStartOffsetMs(second, 10000);

    expect(savedBody, isNotNull);
    expect(savedBody!['name'], 'Queue timing');
    expect(savedBody!['schemaVersion'], 1);
    expect(savedBody!['clips'], [
      {
        'clipId': 'queue-a',
        'queueItemId': 'queue-a',
        'trackId': 42,
        'sourceStartMs': 0,
        'sourceEndMs': first.durationMs,
        'timelineStartMs': 0,
        'gainDb': 0.0,
      },
      {
        'clipId': 'queue-b',
        'queueItemId': 'queue-b',
        'trackId': 43,
        'sourceStartMs': 10000,
        'sourceEndMs': second.durationMs,
        'timelineStartMs': 240000,
        'gainDb': 0.0,
      },
    ]);
  });

  test('pitch mode edits save the current queue timing to the mix-plan API',
      () async {
    final first =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    Map<String, dynamic>? savedBody;
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [first.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({'data': [], 'total': 0, 'limit': 50, 'offset': 0}),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/mix-plans')) {
            savedBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'plan-queue-timing',
                'schemaVersion': 1,
                'name': savedBody!['name'],
                'clips': savedBody!['clips'],
                'summary': {
                  'clipCount': 1,
                  'trackIds': [42],
                  'durationMs': first.durationMs,
                },
                'version': 1,
                'createdAt': '2026-06-03T01:02:03Z',
                'updatedAt': '2026-06-03T02:03:04Z',
              }),
              201,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();
    provider.setPitchMode(first, pitchModeFollowTempo);
    for (var i = 0; i < 10 && savedBody == null; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(provider.pitchModeFor(first), pitchModeFollowTempo);
    expect(savedBody, isNotNull);
    expect(savedBody!['clips'], [
      {
        'clipId': 'queue-a',
        'queueItemId': 'queue-a',
        'trackId': 42,
        'sourceStartMs': 0,
        'sourceEndMs': first.durationMs,
        'timelineStartMs': 0,
        'gainDb': 0.0,
        'pitchMode': pitchModeFollowTempo,
      },
    ]);
  });

  test('analyzed trim edits save downbeat-locked queue timing defaults',
      () async {
    final first = _track(
      id: '42',
      queueItemId: 'queue-a',
      playbackTrackId: '42',
      analysis: _tempoAnalysis(),
    );
    final second = _track(
      id: '43',
      queueItemId: 'queue-b',
      playbackTrackId: '43',
      analysis: _tempoAnalysis(),
    );
    Map<String, dynamic>? savedBody;
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [first.toJson(), second.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({'data': [], 'total': 0, 'limit': 50, 'offset': 0}),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/mix-plans')) {
            savedBody = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'plan-queue-timing',
                'schemaVersion': 1,
                'name': savedBody!['name'],
                'clips': savedBody!['clips'],
                'summary': {
                  'clipCount': 2,
                  'trackIds': [42, 43],
                  'durationMs': 472000,
                },
                'version': 1,
                'createdAt': '2026-06-03T01:02:03Z',
                'updatedAt': '2026-06-03T02:03:04Z',
              }),
              201,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();
    await provider.setTrimRange(second, TrimRange.full(second.durationMs));

    expect(savedBody, isNotNull);
    expect(
        (savedBody!['clips'] as List).map((clip) {
          final json = clip as Map<String, dynamic>;
          return json['timelineStartMs'];
        }),
        [0, 232000]);
    expect(
      provider.timelineClipFor(second, _fallback(second)).timelineStartMs,
      232000,
    );
  });

  test('overlapping timing edits create one plan then coalesce into update',
      () async {
    final first =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final second =
        _track(id: '43', queueItemId: 'queue-b', playbackTrackId: '43');
    var createCount = 0;
    var updateCount = 0;
    final createCompleter = Completer<http.Response>();
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [first.toJson(), second.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({'data': [], 'total': 0, 'limit': 50, 'offset': 0}),
              200,
            );
          }
          if (request.method == 'POST' &&
              request.url.path.endsWith('/mix-plans')) {
            createCount += 1;
            return createCompleter.future;
          }
          if (request.method == 'PUT' &&
              request.url.path.endsWith('/mix-plans/plan-queue-timing')) {
            updateCount += 1;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response(
              jsonEncode({
                'id': 'plan-queue-timing',
                'schemaVersion': 1,
                'name': body['name'],
                'clips': body['clips'],
                'summary': {
                  'clipCount': 2,
                  'trackIds': [42, 43],
                  'durationMs': 240000,
                },
                'version': 2,
                'createdAt': '2026-06-03T01:02:03Z',
                'updatedAt': '2026-06-03T02:03:05Z',
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();
    provider.setTimelineStartMs(second, 12000);
    provider.setTimelineStartMs(second, 24000);

    // The unified client attaches auth through an async interceptor, so the
    // POST reaches the mock transport a few event-loop turns later than the old
    // synchronous http client did. Pump until the create is dispatched.
    for (var i = 0; i < 5 && createCount == 0; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(createCount, 1);
    expect(updateCount, 0);

    createCompleter.complete(http.Response(
      jsonEncode({
        'id': 'plan-queue-timing',
        'schemaVersion': 1,
        'name': 'Queue timing',
        'clips': [
          {
            'clipId': 'queue-a',
            'queueItemId': 'queue-a',
            'trackId': 42,
            'sourceStartMs': 0,
            'sourceEndMs': first.durationMs,
            'timelineStartMs': 0,
            'gainDb': 0,
          },
          {
            'clipId': 'queue-b',
            'queueItemId': 'queue-b',
            'trackId': 43,
            'sourceStartMs': 0,
            'sourceEndMs': second.durationMs,
            'timelineStartMs': 12000,
            'gainDb': 0,
          },
        ],
        'summary': {
          'clipCount': 2,
          'trackIds': [42, 43],
          'durationMs': 240000,
        },
        'version': 1,
        'createdAt': '2026-06-03T01:02:03Z',
        'updatedAt': '2026-06-03T02:03:04Z',
      }),
      201,
    ));

    await provider.setTrimRange(
      second,
      TrimRange.clamped(
        trackDurationMs: second.durationMs,
        startOffsetMs: 8000,
        endOffsetMs: second.durationMs,
      ),
    );

    expect(createCount, 1);
    expect(updateCount, 1);
  });

  test(
      'loadQueue hydrates legacy mix-plan clips without queueItemId by track id',
      () async {
    final track =
        _track(id: '42', queueItemId: 'queue-a', playbackTrackId: '42');
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio((request) async {
          if (request.method == 'GET' && request.url.path.endsWith('/queue')) {
            return http.Response(
              jsonEncode({
                'items': [track.toJson()],
                'currentPosition': 0,
              }),
              200,
            );
          }
          if (request.method == 'GET' &&
              request.url.path.endsWith('/mix-plans')) {
            return http.Response(
              jsonEncode({
                'data': [
                  {
                    'id': 'plan-legacy',
                    'schemaVersion': 1,
                    'name': 'Queue timing',
                    'clips': [
                      {
                        'clipId': 'legacy-clip-a',
                        'queueItemId': '',
                        'trackId': 42,
                        'sourceStartMs': 5000,
                        'sourceEndMs': 90000,
                        'timelineStartMs': 30000,
                        'gainDb': 0,
                      },
                    ],
                    'summary': {
                      'clipCount': 1,
                      'trackIds': [42],
                      'durationMs': 85000,
                    },
                    'version': 2,
                    'createdAt': '2026-06-03T01:02:03Z',
                    'updatedAt': '2026-06-03T02:03:04Z',
                  },
                ],
                'total': 1,
                'limit': 50,
                'offset': 0,
              }),
              200,
            );
          }
          return http.Response('', 404);
        }),
      ),
    );

    await provider.loadQueue();

    expect(provider.trimRangeFor(track).startOffsetMs, 5000);
    expect(provider.trimRangeFor(track).endOffsetMs, 90000);
    expect(provider.timelineClipFor(track, _fallback(track)).timelineStartMs,
        30000);
  });

  test('loading an empty queue prunes stale timing and mix-plan state',
      () async {
    final track = _track();
    final provider = QueueProvider(
      ApiClient(
        dio: mockQueueDio(
          (request) async => http.Response(
            jsonEncode(
                {'items': <Map<String, Object?>>[], 'currentPosition': -1}),
            200,
          ),
        ),
      ),
    );

    await provider.setTrimRange(
      track,
      TrimRange.clamped(
        trackDurationMs: track.durationMs,
        startOffsetMs: 10000,
        endOffsetMs: 100000,
      ),
    );
    provider.setTimelineStartMs(track, 4000);
    provider.applyMixPlanClips([
      MixPlanClip(
        clipId: 'clip-7',
        queueItemId: track.queueItemId,
        trackId: track.playbackTrackId!,
        sourceStartMs: 10000,
        sourceEndMs: 100000,
        timelineStartMs: 4000,
      ),
    ]);

    await provider.loadQueue();

    expect(provider.queue.isEmpty, isTrue);
    expect(provider.trimRanges, isEmpty);
    expect(provider.mixPlanClips, isEmpty);
    expect(
        provider.timelineClipFor(track, _fallback(track)).timelineStartMs, 0);
    expect(provider.trimRangeFor(track).isFullTrack, isTrue);
  });
}
