import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/cache/playback_cache_manager.dart';
import 'package:open_music_player/core/cache/playback_cache_entry.dart';

import 'support/fake_playback_cache_store.dart';

SignedAudioDescriptor audio(int id, {String version = 'v1', int size = 100}) =>
    SignedAudioDescriptor(
      trackId: id,
      url: 'https://objects.example/$id?signature=$version',
      expiresAt: DateTime.utc(2030),
      storageKeyVersion: version,
      etag: version,
      sizeBytes: size,
    );

void main() {
  late Directory dir;
  late FakePlaybackCacheStore store;
  late int calls;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('cache_leases_');
    store = FakePlaybackCacheStore();
    calls = 0;
  });
  tearDown(() async => dir.delete(recursive: true));

  PlaybackCacheManager manager({
    int maxBytes = 300,
    AudioArtifactDownloader? downloader,
  }) =>
      PlaybackCacheManager(
        store: store,
        maxBytes: maxBytes,
        cacheDirectoryProvider: () async => dir.path,
        downloader: downloader ??
            (url, path, {cancelToken, onProgress}) async {
              calls++;
              await File(path).writeAsBytes(List.filled(100, calls));
            },
      );

  test('acquirePath pins only an exact verified current cache entry', () async {
    final cache = manager();
    await cache.warm(1, audio(1));
    final path = store.entries[1]!.localPath;
    final external = File('${dir.path}/unmanaged/1.audio');
    await external.parent.create();
    await external.writeAsBytes(List.filled(100, 9));
    expect(await cache.acquirePath(external.path), isNull);
    expect(await cache.acquirePath('$path-other'), isNull);
    expect(store.entries.containsKey(1), isTrue);
    final lease = (await cache.acquirePath(path))!;
    await cache.clear();
    expect(await File(path).exists(), isTrue);
    expect(await external.exists(), isTrue);
    await lease.release();
    expect(await File(path).exists(), isFalse);
    expect(await external.exists(), isTrue);
  });

  test('acquirePath rejects changed bytes without invalidating the row',
      () async {
    final cache = manager();
    await cache.warm(1, audio(1));
    final entry = store.entries[1]!;
    await File(entry.localPath).writeAsBytes([1]);
    expect(await cache.acquirePath(entry.localPath), isNull);
    expect(store.entries[1], same(entry));
    expect(await File(entry.localPath).exists(), isTrue);
  });

  test(
      'same-identity concurrent preparation has independent pins with one transfer',
      () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final cache =
        manager(downloader: (url, path, {cancelToken, onProgress}) async {
      calls++;
      started.complete();
      await gate.future;
      await File(path).writeAsBytes(List.filled(100, 1));
    });
    final first = cache.warmAndAcquire(1, audio(1));
    await started.future;
    final second = cache.warmAndAcquire(1, audio(1));
    gate.complete();
    final leases = await Future.wait([first, second]);
    expect(calls, 1);
    await cache.clear();
    await leases[0]!.release();
    expect(await File(leases[1]!.localPath).exists(), isTrue);
    await leases[1]!.release();
    expect(await File(leases[1]!.localPath).exists(), isFalse);
  });

  test('empty stored bytes never become a verified lease', () async {
    final cache = manager();
    await cache.warm(1, audio(1));
    final entry = store.entries[1]!;
    await File(entry.localPath).writeAsBytes([]);
    store.entries[1] = PlaybackCacheEntry(
      trackId: 1,
      localPath: entry.localPath,
      fileSizeBytes: 0,
      lastAccessedAt: DateTime.utc(2026),
    );
    expect(await cache.acquire(1, audio(1)), isNull);
  });

  test('overlapping version preparation hands each caller its own version pin',
      () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final cache =
        manager(downloader: (url, path, {cancelToken, onProgress}) async {
      calls++;
      if (calls == 1) {
        started.complete();
        await gate.future;
      }
      await File(path).writeAsBytes(List.filled(100, calls));
    });
    final first = cache.warmAndAcquire(1, audio(1));
    await started.future;
    final second = cache.warmAndAcquire(1, audio(1, version: 'v2'));
    gate.complete();
    final leases = await Future.wait([first, second]);
    expect(leases.every((lease) => lease != null), isTrue);
    expect(leases[0]!.localPath, isNot(leases[1]!.localPath));
    expect((await File(leases[0]!.localPath).readAsBytes()).first, 1);
    expect((await File(leases[1]!.localPath).readAsBytes()).first, 2);
    await leases[0]!.release();
    await leases[1]!.release();
  });

  test(
      'cancel releases an incoming reservation before a shared transfer finishes',
      () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final cache =
        manager(downloader: (url, path, {cancelToken, onProgress}) async {
      started.complete();
      await gate.future;
      await File(path).writeAsBytes(List.filled(100, 1));
    });
    final token = CancelToken();
    final pending = cache.warmAndAcquire(1, audio(1), cancelToken: token);
    await started.future;
    token.cancel();
    expect(await pending.timeout(const Duration(seconds: 1)), isNull);
    gate.complete();
    await cache.warm(1, audio(1));
    expect((await cache.clear()).isComplete, isTrue);
  });

  test('warmAndAcquire pins an incoming file before another warm can evict it',
      () async {
    final cache = manager(maxBytes: 100);
    final incoming = cache.warmAndAcquire(1, audio(1));
    final lease = (await incoming)!;
    await cache.warm(2, audio(2));
    expect(await File(lease.localPath).exists(), isTrue);
    expect(store.entries.containsKey(1), isTrue);
    expect(store.entries.containsKey(2), isFalse);
    await lease.release();
  });

  test('different versions in flight do not incorrectly deduplicate', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final cache =
        manager(downloader: (url, path, {cancelToken, onProgress}) async {
      calls++;
      if (calls == 1) {
        started.complete();
        await gate.future;
      }
      await File(path).writeAsBytes(List.filled(100, calls));
    });
    final first = cache.warm(1, audio(1));
    await started.future;
    final second = cache.warm(1, audio(1, version: 'v2'));
    gate.complete();
    await Future.wait([first, second]);
    expect(calls, 2);
    expect(await cache.get(1, audio(1, version: 'v2')), isNotNull);
  });

  test('clear fences an already running warm and it cannot repopulate later',
      () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final cache =
        manager(downloader: (url, path, {cancelToken, onProgress}) async {
      started.complete();
      await gate.future;
      await File(path).writeAsBytes(List.filled(100, 1));
    });
    final warm = cache.warm(1, audio(1));
    await started.future;
    final cleared = await cache.clear();
    expect(cleared.isComplete, isFalse);
    expect(cleared.pendingTransfers, 1);
    gate.complete();
    await warm;
    expect(store.entries, isEmpty);
    expect(await dir.list().toList(), isEmpty);
  });

  test('live pins defeat eviction and insufficient space rejects only the warm',
      () async {
    final cache = manager(maxBytes: 100);
    await cache.warm(1, audio(1));
    final lease = (await cache.acquire(1, audio(1)))!;
    await cache.warm(2, audio(2));
    expect(store.entries.containsKey(1), isTrue);
    expect(store.entries.containsKey(2), isFalse);
    expect(await File(lease.localPath).exists(), isTrue);
    expect(await cache.currentSizeBytes(), 100);
    await lease.release();
  });

  test(
      'replacement never overwrites a leased version and accounts retired bytes',
      () async {
    final cache = manager();
    await cache.warm(1, audio(1));
    final lease = (await cache.acquire(1, audio(1)))!;
    final before = await File(lease.localPath).readAsBytes();
    await cache.warm(1, audio(1, version: 'v2'));
    final next = (await cache.acquire(1, audio(1, version: 'v2')))!;
    expect(next.localPath, isNot(lease.localPath));
    expect(await File(lease.localPath).readAsBytes(), before);
    expect(await cache.currentSizeBytes(), 200);
    await lease.release();
    expect(await File(lease.localPath).exists(), isFalse);
    expect(await cache.currentSizeBytes(), 100);
    expect(await File(next.localPath).exists(), isTrue);
    await next.release();
  });

  test('clear defers pinned bytes until the last independent lease releases',
      () async {
    final cache = manager();
    await cache.warm(1, audio(1));
    final first = (await cache.acquire(1, audio(1)))!;
    final second = (await cache.acquire(1, audio(1)))!;
    expect(first.localPath, second.localPath);
    final result = await cache.clear();
    expect(result.deferredFiles, 1);
    expect(result.deferredBytes, 100);
    expect(result.isComplete, isFalse);
    expect(store.entries, isEmpty);
    expect(await cache.currentSizeBytes(), 100);
    expect(await File(first.localPath).exists(), isTrue);
    await first.release();
    await first.release(); // Idempotent; cannot release the second owner's pin.
    expect(await File(second.localPath).exists(), isTrue);
    await second.release();
    expect(await File(second.localPath).exists(), isFalse);
    expect(await cache.currentSizeBytes(), 0);
  });
}
