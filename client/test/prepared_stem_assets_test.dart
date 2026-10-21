import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/stems/prepared_stem_assets.dart';

import 'prepared_stem_manifest_test.dart'
    show
        parsePrepared,
        preparedStatus,
        preparedBytes,
        preparedNow,
        preparedRoles,
        preparedModel;

// ignore_for_file: depend_on_referenced_packages

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory(Platform.environment['TMPDIR']!)
        .createTemp('prepared-stems-test-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
      'rejects same-size corruption, wrong size and failures without deleting foreign files',
      () async {
    for (final kind in ['hash', 'size', 'download']) {
      final foreign = File('${root.path}/original.mp3');
      await foreign.writeAsBytes([1, 2, 3]);
      final manifest = parsePrepared(preparedStatus());
      final service = PreparedStemAssets(
          rootDirectory: root,
          now: () => preparedNow,
          downloader: (url, path, {cancelToken, onProgress}) async {
            final channel = manifest.members.values
                .firstWhere((m) => m.url.toString() == url)
                .channel;
            var bytes = preparedBytes(channel);
            if (kind == 'hash') bytes = [...bytes]..[0] ^= 1;
            if (kind == 'size') bytes = bytes.sublist(1);
            await File(path).writeAsBytes(bytes);
            if (kind == 'download') throw StateError('network failed');
          });
      await expectLater(
          service.acquire(manifest),
          throwsA(
              kind == 'download' ? isA<StateError>() : isA<FormatException>()));
      expect((await root.list().toList()).map((f) => f.path), [foreign.path]);
      expect(await foreign.readAsBytes(), [1, 2, 3]);
    }
  });
  test(
      'cancelled uncooperative downloader settles before cleanup and does not publish',
      () async {
    final manifest = parsePrepared(preparedStatus());
    final started = Completer<void>();
    final gate = Completer<void>();
    final cancel = CancelToken();
    var calls = 0;
    var settled = false;
    final service = PreparedStemAssets(
        rootDirectory: root,
        now: () => preparedNow,
        downloader: (url, path, {cancelToken, onProgress}) async {
          calls++;
          await File(path).writeAsBytes([1]);
          if (!started.isCompleted) started.complete();
          await gate.future;
          final channel = manifest.members.values
              .firstWhere((m) => m.url.toString() == url)
              .channel;
          await File(path).writeAsBytes(preparedBytes(channel));
        });
    final outcome = service
        .acquire(manifest, cancelToken: cancel)
        .whenComplete(() => settled = true);
    final check = expectLater(
        outcome,
        throwsA(isA<DioException>()
            .having((e) => e.type, 'type', DioExceptionType.cancel)));
    await started.future;
    cancel.cancel('caller gone');
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    expect(await root.list().toList(), isNotEmpty);
    gate.complete();
    await check;
    expect(calls, 1);
    expect(await root.list().toList(), isEmpty);
  });
  test('expired URL is rejected again before acquisition', () async {
    var calls = 0;
    final service = PreparedStemAssets(
        rootDirectory: root,
        now: () => preparedNow.add(const Duration(hours: 1)),
        downloader: (url, path, {cancelToken, onProgress}) async {
          calls++;
        });
    await expectLater(service.acquire(parsePrepared(preparedStatus())),
        throwsFormatException);
    expect(calls, 0);
    expect(await root.list().toList(), isEmpty);
  });

  test('byte budget reserves live leases and failure returns its reservation',
      () async {
    final manifest = parsePrepared(preparedStatus());
    var calls = 0;
    final service = PreparedStemAssets(
        rootDirectory: root,
        now: () => preparedNow,
        maxBytes: manifest.totalBytes,
        downloader: (url, path, {cancelToken, onProgress}) async {
          calls++;
          final channel = manifest.members.values
              .firstWhere((m) => m.url.toString() == url)
              .channel;
          await File(path).writeAsBytes(preparedBytes(channel));
        });
    final first = await service.acquire(manifest);
    await expectLater(service.acquire(manifest), throwsStateError);
    expect(calls, 6);
    await first.release();
    final retry = await service.acquire(manifest);
    await retry.release();
    expect(await root.list().toList(), isEmpty);
    final tooSmall = PreparedStemAssets(
        rootDirectory: root, maxBytes: manifest.totalBytes - 1);
    await expectLater(tooSmall.acquire(manifest), throwsStateError);
    expect(await root.list().toList(), isEmpty);
  });
  test(
      'failed acquisition returns budget and concurrent copies have isolated ownership',
      () async {
    final manifest = parsePrepared(preparedStatus());
    var fail = true;
    final service = PreparedStemAssets(
        rootDirectory: root,
        now: () => preparedNow,
        maxBytes: manifest.totalBytes * 2,
        downloader: (url, path, {cancelToken, onProgress}) async {
          final channel = manifest.members.values
              .firstWhere((m) => m.url.toString() == url)
              .channel;
          await File(path).writeAsBytes(preparedBytes(channel));
          if (fail) throw StateError('first transfer failed');
        });
    await expectLater(service.acquire(manifest), throwsStateError);
    fail = false;
    final leases = await Future.wait(
        [service.acquire(manifest), service.acquire(manifest)]);
    expect(leases[0].directory.path, isNot(leases[1].directory.path));
    await leases[0].release();
    expect(await leases[1].directory.exists(), isTrue);
    await leases[1].release();
    expect(await root.list().toList(), isEmpty);
  });
  test('pre-cancelled request performs no filesystem or downloader work',
      () async {
    var calls = 0;
    final token = CancelToken()..cancel();
    final service = PreparedStemAssets(
        rootDirectory: root,
        now: () => preparedNow,
        downloader: (url, path, {cancelToken, onProgress}) async {
          calls++;
        });
    await expectLater(
        service.acquire(parsePrepared(preparedStatus()), cancelToken: token),
        throwsA(isA<DioException>()));
    expect(calls, 0);
    expect(await root.list().toList(), isEmpty);
  });
  test('unsettled cancelled work retains concurrency admission slot', () async {
    final manifest = parsePrepared(preparedStatus());
    final started = Completer<void>();
    final gate = Completer<void>();
    final token = CancelToken();
    final service = PreparedStemAssets(
        rootDirectory: root,
        now: () => preparedNow,
        maxConcurrentAcquisitions: 1,
        downloader: (url, path, {cancelToken, onProgress}) async {
          if (!started.isCompleted) started.complete();
          await gate.future;
        });
    final first = service.acquire(manifest, cancelToken: token);
    final check = expectLater(first, throwsA(isA<DioException>()));
    await started.future;
    token.cancel();
    await expectLater(service.acquire(manifest), throwsStateError);
    gate.complete();
    await check;
    expect(await root.list().toList(), isEmpty);
  });
  test('progress overflow aborts and cleans owned partials', () async {
    final service = PreparedStemAssets(
        rootDirectory: root,
        now: () => preparedNow,
        downloader: (url, path, {cancelToken, onProgress}) async {
          await File(path).writeAsBytes([1]);
          onProgress!(999999, 999999);
          expect(cancelToken!.isCancelled, isTrue);
        });
    await expectLater(service.acquire(parsePrepared(preparedStatus())),
        throwsFormatException);
    expect(await root.list().toList(), isEmpty);
  });
  test('symlink member cannot publish foreign bytes as an owned artifact',
      () async {
    final manifest = parsePrepared(preparedStatus());
    final foreign = File('${root.path}/foreign.opus');
    await foreign.writeAsBytes(preparedBytes('vocals'));
    final service = PreparedStemAssets(
        rootDirectory: root,
        now: () => preparedNow,
        downloader: (url, path, {cancelToken, onProgress}) async {
          final channel = manifest.members.values
              .firstWhere((m) => m.url.toString() == url)
              .channel;
          final target = File('${root.path}/foreign/$channel.opus');
          await target.parent.create(recursive: true);
          await target.writeAsBytes(preparedBytes(channel));
          await Link(path).create(target.path);
        });
    await expectLater(service.acquire(manifest), throwsFormatException);
    expect(await foreign.readAsBytes(), preparedBytes('vocals'));
    expect(
        (await root.list().toList()).where(
            (f) => f.path.contains('ready-') || f.path.contains('.staging-')),
        isEmpty);
  });
  test(
      'real Opus bytes preserve decoded trimmed frame alignment independently of energy',
      () async {
    final fixture = File('${root.path}/generated.opus');
    final encode = await Process.run('ffmpeg', [
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=48000:duration=1',
      '-ac',
      '2',
      '-c:a',
      'libopus',
      fixture.path
    ]);
    expect(encode.exitCode, 0, reason: encode.stderr.toString());
    final encoded = await fixture.readAsBytes();
    final digest = sha256.convert(encoded).toString();
    // Read the actual OpusHead preskip instead of assuming encoder defaults.
    final head = String.fromCharCodes(encoded).indexOf('OpusHead');
    expect(head, greaterThanOrEqualTo(0));
    expect(String.fromCharCodes(encoded.sublist(head, head + 8)), 'OpusHead');
    final preskip = encoded[head + 10] | (encoded[head + 11] << 8);
    final body = preparedStatus();
    for (final object in body['publishedManifest']['artifacts']['objects']) {
      final channel = object['channel'];
      final key =
          'stems/42/$preparedModel/${'a' * 64}/g7/${channel == 'melody' ? 'other' : channel}/$digest.opus';
      object['sha256'] = digest;
      object['key'] = key;
      object['bytes'] = encoded.length;
      object['encoder_delay_frames'] = preskip;
      final download = (body['memberDownloads'] as List)
          .firstWhere((d) => d['channel'] == channel);
      download['sha256'] = digest;
      download['key'] = key;
      download['bytes'] = encoded.length;
    }
    final manifest = parsePrepared(body);
    final owned = Directory('${root.path}/owned');
    final service = PreparedStemAssets(
        rootDirectory: owned,
        now: () => preparedNow,
        downloader: (url, path, {cancelToken, onProgress}) async {
          await fixture.copy(path);
        });
    final lease = await service.acquire(manifest);
    for (final channel in preparedRoles) {
      final raw = File('${root.path}/$channel.f32le');
      final decode = await Process.run('ffmpeg', [
        '-hide_banner',
        '-loglevel',
        'error',
        '-i',
        File.fromUri(lease.files[channel]!).path,
        '-f',
        'f32le',
        raw.path
      ]);
      expect(decode.exitCode, 0, reason: decode.stderr.toString());
      expect(await raw.length(), manifest.sampleFrames * 2 * 4);
      expect(manifest.members[channel]!.encoderDelayFrames, preskip);
    }
    expect(manifest.sampleFrames, 48000);
    expect(body['artifacts']['energy']['frame_count'], 80);
    await lease.release();
    expect(await owned.list().toList(), isEmpty);
  });
  test(
      'default shared downloader sends no API credentials to local object host',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final manifest = parsePrepared(
          preparedStatus(objectOrigin: 'http://127.0.0.1:${server.port}'),
          allowLoopbackHttp: true);
      final received = <String?>[];
      final subscription = server.listen((request) async {
        received.add(request.headers.value(HttpHeaders.authorizationHeader));
        final channel = manifest.members.values
            .firstWhere((m) => m.url.path == request.uri.path)
            .channel;
        request.response.add(preparedBytes(channel));
        await request.response.close();
      });
      try {
        final service =
            PreparedStemAssets(rootDirectory: root, now: () => preparedNow);
        final lease = await service.acquire(manifest);
        expect(received, List<String?>.filled(6, null));
        await lease.release();
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    }, _RealHttp());
  });
  test(
      'publishes complete real verified bytes atomically and retains until last lease',
      () async {
    final manifest = parsePrepared(preparedStatus());
    final gate = Completer<void>();
    final started = Completer<void>();
    final service = PreparedStemAssets(
        rootDirectory: root,
        now: () => preparedNow,
        downloader: (url, path, {cancelToken, onProgress}) async {
          expect(path, contains('.staging-'));
          expect(url, startsWith('https://objects.invalid/'));
          final channel = manifest.members.values
              .firstWhere((m) => m.url.toString() == url)
              .channel;
          await File(path).writeAsBytes(preparedBytes(channel));
          if (!started.isCompleted) started.complete();
          await gate.future;
        });
    final pending = service.acquire(manifest);
    await started.future;
    expect((await root.list().toList()).where((e) => e.path.contains('ready-')),
        isEmpty);
    gate.complete();
    final lease = await pending;
    expect(lease.files.keys, preparedRoles);
    expect(
        lease.channelFiles.keys, ['vocals', 'melody', 'bass', 'kick', 'perc']);
    expect(lease.channelFiles.containsKey('drums'), isFalse);
    expect(() => lease.channelFiles.clear(), throwsUnsupportedError);
    expect(lease.directory.path, contains('ready-'));
    expect(lease.directory.path, isNot(contains('signature')));
    for (final channel in preparedRoles) {
      expect(await File.fromUri(lease.files[channel]!).readAsBytes(),
          preparedBytes(channel));
    }
    final second = lease.retain();
    final directory = lease.directory;
    await lease.release();
    await lease.release();
    expect(await directory.exists(), isTrue);
    expect(() => lease.retain(), throwsStateError);
    await second.release();
    expect(await directory.exists(), isFalse);
    expect(await root.list().toList(), isEmpty);
  });
}

class _RealHttp extends HttpOverrides {}
