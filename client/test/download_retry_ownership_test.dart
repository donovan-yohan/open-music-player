import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/playback_source_resolver.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/download/download_service.dart';
import 'package:open_music_player/core/engine/engine_audio_source_resolver.dart';
import 'package:open_music_player/core/engine/timeline_clock.dart';
import 'package:open_music_player/core/engine/timeline_model.dart';
import 'package:open_music_player/core/engine/voice_pool.dart';
import 'package:open_music_player/models/timeline_clip.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:path/path.dart' as p;

import 'support/fake_offline_download_store.dart';
import 'support/fake_voice.dart';

void main() {
  late Directory dir;
  late FakeOfflineDownloadStore store;
  const originalBytes = [1, 2, 3, 4];
  const replacementBytes = [5, 6, 7, 8];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('download_retry_ownership_');
    store = FakeOfflineDownloadStore();
  });
  tearDown(() async => dir.delete(recursive: true));

  Track track(int id) => Track(
        id: id,
        identityHash: 'retry-$id',
        title: 'Retry ownership',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

  SignedAudioUrlService signed() =>
      SignedAudioUrlService.withRequester((body) async => {
            'urls': [
              for (final id in body['trackIds'] as List)
                {
                  'trackId': id,
                  'url': 'https://objects.example/$id',
                  'expiresAt': DateTime.now()
                      .toUtc()
                      .add(const Duration(hours: 1))
                      .toIso8601String(),
                  'contentType': 'audio/wav',
                  'codec': 'pcm_s16le',
                  'sizeBytes': replacementBytes.length,
                }
            ]
          });

  DownloadService downloads() {
    final service = DownloadService(
      db: store,
      signedAudioUrlService: signed(),
      downloadDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        await File(path).writeAsBytes(replacementBytes);
      },
    );
    addTearDown(service.dispose);
    return service;
  }

  Future<void> seedDownload(int id, String path) async {
    await File(path).writeAsBytes(originalBytes);
    store.downloads[id] = DownloadedTrack(
      trackId: id,
      localPath: path,
      fileSizeBytes: originalBytes.length,
      status: DownloadStatus.completed,
      downloadedAt: DateTime.utc(2026),
    );
  }

  test('retry must preserve a source still owned by a transport', () async {
    final old = p.join(dir.path, '1.mp3');
    await seedDownload(1, old);
    final service = downloads();
    final item = await PlaybackSourceResolver(
      signedAudioUrlService: signed(),
      localResolver: service,
    ).resolveTrack({'id': 1});
    expect(item.extras!['localPath'], old);
    final clip = MixClip(
      placement: TimelineClip.clamped(
        id: 'active',
        trackId: '1',
        sourceDurationMs: 10000,
        sourceStartMs: 0,
        sourceEndMs: 10000,
        timelineStartMs: 0,
      ),
      audioSourceRef: Uri.file(item.extras!['localPath'] as String).toString(),
    );
    // Keep production source resolution and pool ownership; fake only hardware.
    final voice = FakeVoice('retry-hardware-fake');
    final clock = DefaultTimelineClock(
      uiTickInterval: const Duration(hours: 1),
    );
    final pool = VoicePool(
      clock: clock,
      voiceFactory: () => voice,
      maxVoices: 1,
      warmSpareVoices: 0,
      resolver: const DirectEngineAudioSourceResolver(),
    );
    addTearDown(() async {
      await pool.dispose();
      await clock.dispose();
    });
    await pool.start();
    await pool.loadMix(TimelineModel(clips: [clip]));
    expect(pool.activeVoices['active'], same(voice));
    expect(voice.loads, [Uri.file(old)]);
    expect(voice.isLoaded, isTrue);

    await service.retryDownload(track(1));

    expect(store.downloads[1]!.isCompleted, isTrue);
    final replacement = (await service.localAudioPath(1))!;
    expect(replacement, p.join(dir.path, '1.wav'));
    expect(await File(replacement).readAsBytes(), replacementBytes);
    expect(pool.activeVoices['active'], same(voice));
    expect(voice.isLoaded, isTrue);
    expect(voice.loads, [Uri.file(old)]);
    expect(await File(voice.loads.single.toFilePath()).exists(), isTrue,
        reason: 'delivered transport source has not been released');
    expect(await File(old).readAsBytes(), originalBytes);
  });

  test('retry must not delete another completed rows artifact', () async {
    final foreign = p.join(dir.path, '2.mp3');
    await seedDownload(2, foreign);
    final foreignRow = store.downloads[2]!;
    // A stale row can alias a different completed row in the same directory.
    store.downloads[1] = DownloadedTrack(
      trackId: 1,
      localPath: foreign,
      fileSizeBytes: originalBytes.length,
      status: DownloadStatus.failed,
      downloadedAt: DateTime.utc(2026),
    );
    final service = downloads();
    expect(await service.localAudioPath(2), foreign);
    expect(await File(foreign).readAsBytes(), originalBytes);

    await service.retryDownload(track(1));

    expect(store.downloads[1]!.isCompleted, isTrue);
    final replacement = (await service.localAudioPath(1))!;
    expect(replacement, p.join(dir.path, '1.wav'));
    expect(await File(replacement).readAsBytes(), replacementBytes);
    expect(store.downloads[2], same(foreignRow));
    expect(store.downloads[2]!.isCompleted, isTrue);
    expect(await File(foreign).exists(), isTrue,
        reason:
            'directory containment does not make track 2 artifact track 1 owned');
    expect(await service.localAudioPath(2), foreign);
    expect(await File(foreign).readAsBytes(), originalBytes);
  });
}
