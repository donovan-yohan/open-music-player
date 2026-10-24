import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/download/download_service.dart';
import 'package:open_music_player/shared/models/models.dart';
import 'package:path/path.dart' as p;

import 'support/fake_offline_download_store.dart';

void main() {
  late Directory dir;
  late FakeOfflineDownloadStore store;
  const bytes = [1, 2, 3, 4];
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('download_format_');
    store = FakeOfflineDownloadStore();
  });
  tearDown(() async => dir.delete(recursive: true));

  Track track() => Track(
        id: 1,
        identityHash: 'track-one',
        title: 'Title does not choose format',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      );

  DownloadService service(String? type, String? codec, String path) {
    final signed = SignedAudioUrlService.withRequester((_) async => {
          'urls': [
            {
              'trackId': 1,
              'url': 'https://objects.example/$path?name=wrong.mp3#fake.wav',
              'expiresAt': DateTime.now()
                  .toUtc()
                  .add(const Duration(minutes: 10))
                  .toIso8601String(),
              'contentType': type,
              'codec': codec,
              'sizeBytes': bytes.length,
              'etag': 'etag-v1',
              'storageKeyVersion': 'v1',
            }
          ]
        });
    final svc = DownloadService(
      db: store,
      signedAudioUrlService: signed,
      downloadDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        await File(path).writeAsBytes(bytes);
      },
    );
    addTearDown(svc.dispose);
    return svc;
  }

  for (final (type, codec, path, extension) in [
    ('audio/wav', 'pcm_s16le', 'object', '.wav'),
    ('audio/ogg', 'opus', 'object', '.opus'),
    ('audio/mp4', 'aac', 'object', '.m4a'),
    ('audio/webm', 'opus', 'object', '.webm'),
    ('audio/mpeg', 'mp3', 'object', '.mp3'),
    (null, null, 'source.flac', '.flac'),
    ('application/octet-stream', 'aac', 'object', '.audio'),
  ]) {
    test('download uses container $extension for $type / $codec', () async {
      final svc = service(type, codec, path);
      await svc.downloadTrack(track());
      final row = store.downloads[1]!;
      expect(row.isCompleted, isTrue);
      expect(p.extension(row.localPath), extension);
      expect(await svc.localAudioPath(1), row.localPath);
      expect(await File(row.localPath).readAsBytes(), bytes);
      expect(row.etag, 'etag-v1');
      expect(row.storageKeyVersion, 'v1');
      expect(row.expectedSizeBytes, bytes.length);
      expect((await dir.list().toList()).map((f) => f.path), [row.localPath]);
    });
  }

  test('legacy explicit rows remain offline-readable without guessing format',
      () async {
    final svc = service('audio/wav', 'pcm_s16le', 'object');
    final file = File(p.join(dir.path, '1.mp3'));
    await file.writeAsBytes(bytes);
    store.downloads[1] = DownloadedTrack(
      trackId: 1,
      localPath: file.path,
      fileSizeBytes: bytes.length,
      status: DownloadStatus.completed,
      downloadedAt: DateTime.utc(2026),
    );
    await svc.validateStoredArtifacts();
    expect(await svc.localAudioPath(1), file.path);
    expect(await file.readAsBytes(), bytes);
    expect(store.downloads[1]!.isCompleted, isTrue);
  });

  test('explicit retry corrects format while retaining previous bytes',
      () async {
    final svc = service('audio/wav', 'pcm_s16le', 'object');
    final old = File(p.join(dir.path, '1.mp3'));
    final unrelated = File(p.join(dir.path, '2.mp3'));
    await old.writeAsBytes(bytes);
    await unrelated.writeAsBytes(bytes);
    store.downloads[1] = DownloadedTrack(
      trackId: 1,
      localPath: old.path,
      fileSizeBytes: bytes.length,
      status: DownloadStatus.completed,
      downloadedAt: DateTime.utc(2026),
    );
    await svc.retryDownload(track());
    final path = (await svc.localAudioPath(1))!;
    expect(p.extension(path), '.wav');
    expect(await File(path).readAsBytes(), bytes);
    // A prior row does not prove exclusive ownership or transport release.
    // Requiring immediate deletion here was unsafe; preserve the old bytes.
    expect(await old.readAsBytes(), bytes);
    expect(await unrelated.readAsBytes(), bytes);
  });
}
