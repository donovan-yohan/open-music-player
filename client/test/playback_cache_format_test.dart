import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/cache/playback_cache_entry.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';
import 'package:path/path.dart' as p;

import 'support/fake_playback_cache_store.dart';

class _RejectMigrationStore extends FakePlaybackCacheStore {
  @override
  Future<void> upsertEntry(PlaybackCacheEntry entry) async {
    throw StateError('migration publication refused');
  }
}

SignedAudioDescriptor audio({
  String? type = 'audio/wav',
  String? codec = 'pcm_s16le',
  String path = 'object',
  String signature = 'first',
  String version = 'v1',
}) =>
    SignedAudioDescriptor(
      trackId: 7,
      url:
          'https://objects.example/$path?sig=$signature&name=wrong.mp3#fake.flac',
      expiresAt: DateTime.utc(2030),
      contentType: type,
      codec: codec,
      sizeBytes: 8,
      etag: version,
      storageKeyVersion: version,
    );

void main() {
  late Directory dir;
  late FakePlaybackCacheStore store;
  late int transfers;
  const bytes = [82, 73, 70, 70, 1, 2, 3, 4];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cache_format_');
    store = FakePlaybackCacheStore();
    transfers = 0;
  });
  tearDown(() async => dir.delete(recursive: true));

  PlaybackCacheManager manager({int maxBytes = 32}) => PlaybackCacheManager(
        store: store,
        maxBytes: maxBytes,
        cacheDirectoryProvider: () async => dir.path,
        downloader: (url, path, {cancelToken, onProgress}) async {
          transfers++;
          await File(path).writeAsBytes(bytes);
        },
      );

  Future<PlaybackCacheEntry> legacy(SignedAudioDescriptor descriptor) async {
    final file = File(p.join(dir.path, '7.audio'));
    await file.writeAsBytes(bytes);
    final entry = PlaybackCacheEntry(
      trackId: 7,
      localPath: file.path,
      fileSizeBytes: bytes.length,
      etag: descriptor.etag,
      storageKeyVersion: descriptor.storageKeyVersion,
      expectedSizeBytes: descriptor.sizeBytes,
      urlIdentity: audioObjectIdentity(descriptor.url),
      lastAccessedAt: DateTime.utc(2026),
    );
    store.entries[7] = entry;
    return entry;
  }

  final formats = <(String?, String?, String, String)>[
    ('audio/wav', 'pcm_s16le', 'object', '.wav'),
    (' Audio/X-WAV ; codecs=pcm', 'pcm_s24le', 'wrong.mp3', '.wav'),
    ('audio/wave', null, 'object', '.wav'),
    ('audio/vnd.wave', null, 'object', '.wav'),
    ('audio/ogg; codecs=opus', 'opus', 'wrong.mp3', '.opus'),
    ('audio/ogg', 'opus', 'object', '.opus'),
    ('audio/opus', null, 'object', '.opus'),
    ('audio/ogg', 'vorbis', 'object', '.ogg'),
    ('audio/mpeg', 'mp3', 'object', '.mp3'),
    ('audio/mp4', 'aac', 'object', '.m4a'),
    ('audio/mp4', 'alac', 'object', '.m4a'),
    ('audio/aac', 'aac', 'object', '.aac'),
    ('audio/flac', 'flac', 'object', '.flac'),
    ('audio/x-flac', null, 'object', '.flac'),
    ('audio/webm', 'opus', 'wrong.opus', '.webm'),
    ('application/octet-stream', 'aac', 'source.M4A', '.m4a'),
    (null, 'opus', 'source.opus', '.opus'),
    (null, null, 'source.wav', '.wav'),
    (null, null, 'source.mp3', '.mp3'),
    (null, null, 'source.ogg', '.ogg'),
    (null, null, 'source.flac', '.flac'),
    (null, null, 'source.webm', '.webm'),
    // Neither a codec nor query/fragment determines its container.
    (null, 'aac', 'object', '.audio'),
    ('application/octet-stream', 'opus', 'object', '.audio'),
    (null, 'pcm_s16le', 'object', '.audio'),
    ('audio/unknown', 'mp3', 'object', '.audio'),
    (null, null, 'source.exe', '.audio'),
  ];
  for (final (type, codec, path, extension) in formats) {
    test('warm/get uses $extension for $type / $codec / $path', () async {
      final cache = manager();
      final descriptor = audio(type: type, codec: codec, path: path);
      await cache.warm(7, descriptor);
      final hit = (await cache.get(7, descriptor))!;
      expect(p.extension(hit), extension);
      expect(await File(hit).readAsBytes(), bytes);
      expect(transfers, 1);
      expect(store.entries[7]!.etag, 'v1');
      expect(
          store.entries[7]!.urlIdentity, audioObjectIdentity(descriptor.url));
      final refreshed =
          audio(type: type, codec: codec, path: path, signature: 'replacement');
      expect(playbackCacheKey(refreshed), playbackCacheKey(descriptor));
      expect(await cache.get(7, refreshed), hit);
      await cache.warm(7, refreshed);
      expect(transfers, 1);
    });
  }

  test('legacy row migrates verified bytes without transfer or identity change',
      () async {
    final cache = manager();
    final descriptor = audio();
    final old = await legacy(descriptor);
    final hit = (await cache.get(7, descriptor))!;
    expect(p.extension(hit), '.wav');
    expect(hit, isNot(old.localPath));
    expect(await File(old.localPath).exists(), isFalse);
    expect(await File(hit).readAsBytes(), bytes);
    expect(transfers, 0);
    final row = store.entries[7]!;
    expect(row.etag, old.etag);
    expect(row.storageKeyVersion, old.storageKeyVersion);
    expect(row.expectedSizeBytes, old.expectedSizeBytes);
    expect(row.urlIdentity, old.urlIdentity);
    expect(await cache.currentSizeBytes(), bytes.length);
    expect(await cache.acquirePath(old.localPath), isNull);
    final pin = (await cache.acquirePath(hit))!;
    await pin.release();
  });

  test('pinned legacy path falls back until both exact-path leases release',
      () async {
    final cache = manager(maxBytes: 8);
    final descriptor = audio(type: 'audio/ogg', codec: 'opus');
    final old = await legacy(descriptor);
    final first = (await cache.acquirePath(old.localPath))!;
    final second = (await cache.acquirePath(old.localPath))!;
    expect(await cache.get(7, descriptor), isNull);
    expect(await cache.acquire(7, descriptor), isNull);
    await cache.warm(7, descriptor);
    expect(transfers, 0);
    expect(store.entries[7]!.localPath, old.localPath);
    expect(await File(old.localPath).readAsBytes(), bytes);
    await first.release();
    await first.release();
    expect(await cache.get(7, descriptor), isNull);
    await second.release();
    final pin = (await cache.acquire(7, descriptor))!;
    expect(p.extension(pin.localPath), '.opus');
    expect(await File(pin.localPath).readAsBytes(), bytes);
    expect(await cache.currentSizeBytes(), 8);
    final clear = await cache.clear();
    expect(clear.deferredFiles, 1);
    expect(clear.deferredBytes, 8);
    expect(await File(pin.localPath).exists(), isTrue);
    await pin.release();
    expect(await cache.currentSizeBytes(), 0);
    expect(await dir.list().toList(), isEmpty);
  });

  test('legacy migration retains sparse identity and rejects stale descriptor',
      () async {
    final cache = manager();
    final old = await legacy(audio());
    store.entries[7] = PlaybackCacheEntry(
      trackId: 7,
      localPath: old.localPath,
      fileSizeBytes: old.fileSizeBytes,
      lastAccessedAt: old.lastAccessedAt,
    );
    final migrated = (await cache.get(7, audio()))!;
    expect(p.extension(migrated), '.wav');
    expect(store.entries[7]!.etag, isNull);
    expect(store.entries[7]!.urlIdentity, isNull);
    await cache.clear();
    final stale = await legacy(audio());
    expect(await cache.get(7, audio(version: 'v2')), isNull);
    expect(await File(stale.localPath).exists(), isFalse);
    expect(store.entries, isEmpty);
  });

  test('recognized versions keep independent paths, bytes and clear accounting',
      () async {
    final cache = manager();
    final first = (await cache.warmAndAcquire(7, audio()))!;
    final secondPin = (await cache.acquirePath(first.localPath))!;
    final next = (await cache.warmAndAcquire(7, audio(version: 'v2')))!;
    expect(p.extension(first.localPath), '.wav');
    expect(p.extension(next.localPath), '.wav');
    expect(next.localPath, isNot(first.localPath));
    expect(await File(first.localPath).readAsBytes(), bytes);
    expect(await cache.acquirePath(first.localPath), isNull);
    expect(await cache.currentSizeBytes(), 16);
    final result = await cache.clear();
    expect(result.deferredFiles, 2);
    expect(result.deferredBytes, 16);
    await first.release();
    await first.release();
    expect(await File(secondPin.localPath).exists(), isTrue);
    await secondPin.release();
    expect(await File(first.localPath).exists(), isFalse);
    expect(await File(next.localPath).exists(), isTrue);
    await next.release();
    expect(await cache.currentSizeBytes(), 0);
  });

  test('clear retires held legacy path without migrating or repopulating',
      () async {
    final cache = manager();
    final old = await legacy(audio());
    final pin = (await cache.acquirePath(old.localPath))!;
    expect(await cache.get(7, audio()), isNull);
    final result = await cache.clear();
    expect(result.deferredFiles, 1);
    expect(result.deferredBytes, 8);
    expect(store.entries, isEmpty);
    expect(await cache.get(7, audio()), isNull);
    expect(await File(old.localPath).readAsBytes(), bytes);
    await pin.release();
    expect(await dir.list().toList(), isEmpty);
  });

  test('migration publication failure restores original row and exact bytes',
      () async {
    final descriptor = audio();
    final old = await legacy(descriptor);
    final rejecting = _RejectMigrationStore()..entries[7] = old;
    final cache = PlaybackCacheManager(
      store: rejecting,
      cacheDirectoryProvider: () async => dir.path,
    );
    expect(await cache.get(7, descriptor), isNull);
    expect(rejecting.entries[7], same(old));
    expect(await File(old.localPath).readAsBytes(), bytes);
    expect((await dir.list().toList()).map((f) => f.path), [old.localPath]);
  });

  test('legacy migration never adopts an external path with the same basename',
      () async {
    final descriptor = audio();
    final old = await legacy(descriptor);
    final ownedDir = Directory(p.join(dir.path, 'owned'));
    await ownedDir.create();
    final cache = PlaybackCacheManager(
      store: store,
      cacheDirectoryProvider: () async => ownedDir.path,
    );
    expect(await cache.get(7, descriptor), isNull);
    expect(store.entries[7], same(old));
    expect(await File(old.localPath).readAsBytes(), bytes);
    expect(await ownedDir.list().toList(), isEmpty);
  });

  test('overlapping recognized versions preserve per-caller suffix and bytes',
      () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final cache = PlaybackCacheManager(
      store: store,
      maxBytes: 32,
      cacheDirectoryProvider: () async => dir.path,
      downloader: (url, path, {cancelToken, onProgress}) async {
        transfers++;
        if (transfers == 1) {
          started.complete();
          await gate.future;
        }
        await File(path).writeAsBytes(List.filled(8, transfers));
      },
    );
    final first = cache.warmAndAcquire(7, audio());
    await started.future;
    final second = cache.warmAndAcquire(
        7, audio(type: 'audio/ogg', codec: 'opus', version: 'v2'));
    gate.complete();
    final leases = await Future.wait([first, second]);
    expect(transfers, 2);
    expect(p.extension(leases[0]!.localPath), '.wav');
    expect(p.extension(leases[1]!.localPath), '.opus');
    expect(await File(leases[0]!.localPath).readAsBytes(), List.filled(8, 1));
    expect(await File(leases[1]!.localPath).readAsBytes(), List.filled(8, 2));
    await leases[0]!.release();
    expect(await File(leases[0]!.localPath).exists(), isFalse);
    await leases[1]!.release();
  });
}
