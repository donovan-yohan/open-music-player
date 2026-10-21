import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_music_player/core/stems/native_stem_decoder.dart';
import 'package:open_music_player/core/stems/prepared_stem_assets.dart';
import 'package:open_music_player/core/stems/prepared_stem_manifest.dart';

import 'prepared_stem_manifest_test.dart'
    show
        preparedStatus,
        parsePrepared,
        preparedNow,
        preparedModel,
        preparedRoles;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'worker decodes verified files through production host and pins until close',
      () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final library = Platform.environment['SOUNDQ_NATIVE_DEVICE_LIBRARY'] ??
          Platform.environment['SOUNDQ_NATIVE_DEVICE_TEST_LIBRARY'];
      expect(library, isNotNull,
          reason: 'Build the real device host; no FFI skip');
      final root = await Directory(Platform.environment['TMPDIR']!)
          .createTemp('native-stem-decoder-');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final encoded = File('${root.path}/fixture.opus');
      final raw = File('${root.path}/reference.f32');
      final encode = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'aevalsrc=0.21*sin(2*PI*431*t)|0.17*sin(2*PI*997*t):s=48000:d=1',
        '-c:a',
        'libopus',
        encoded.path,
      ]);
      expect(encode.exitCode, 0, reason: '${encode.stderr}');
      final decode = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-c:a',
        'libopus',
        '-request_sample_fmt',
        'flt',
        '-i',
        encoded.path,
        '-f',
        'f32le',
        raw.path,
      ]);
      expect(decode.exitCode, 0, reason: '${decode.stderr}');
      final bytes = await encoded.readAsBytes();
      final reference = (await raw.readAsBytes()).buffer.asFloat32List();
      final memberBytes = <String, List<int>>{'vocals': bytes};
      final memberReference = <String, Float32List>{'vocals': reference};
      for (var i = 1; i < preparedRoles.length; i++) {
        final role = preparedRoles[i];
        final file = File('${root.path}/$role.opus');
        final pcm = File('${root.path}/$role.f32');
        final result = await Process.run('ffmpeg', [
          '-v',
          'error',
          '-i',
          encoded.path,
          '-af',
          'volume=${.1 * (i + 1)}',
          '-c:a',
          'libopus',
          file.path
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        final oracle = await Process.run('ffmpeg', [
          '-v',
          'error',
          '-c:a',
          'libopus',
          '-request_sample_fmt',
          'flt',
          '-i',
          file.path,
          '-f',
          'f32le',
          pcm.path
        ]);
        expect(oracle.exitCode, 0, reason: '${oracle.stderr}');
        memberBytes[role] = await file.readAsBytes();
        memberReference[role] =
            (await pcm.readAsBytes()).buffer.asFloat32List();
      }
      final objectsByPath = <String, List<int>>{};
      final body =
          preparedStatus(objectOrigin: 'http://127.0.0.1:${server.port}');
      final head = String.fromCharCodes(bytes).indexOf('OpusHead');
      final preSkip = bytes[head + 10] | (bytes[head + 11] << 8);
      for (final object in body['publishedManifest']['artifacts']['objects']) {
        final channel = object['channel'];
        final encodedMember = memberBytes[channel]!;
        final digest = sha256.convert(encodedMember).toString();
        final key = 'stems/42/$preparedModel/${'a' * 64}/g7/'
            '${channel == 'melody' ? 'other' : channel}/$digest.opus';
        object['key'] = key;
        object['sha256'] = digest;
        object['bytes'] = encodedMember.length;
        object['encoder_delay_frames'] = preSkip;
        final download = (body['memberDownloads'] as List)
            .firstWhere((d) => d['channel'] == channel);
        download['key'] = key;
        download['sha256'] = digest;
        download['bytes'] = encodedMember.length;
        download['url'] = 'http://127.0.0.1:${server.port}/$key';
        objectsByPath['/$key'] = encodedMember;
      }
      var requests = 0;
      List<int>? servedMono;
      final subscription = server.listen((request) async {
        requests++;
        expect(request.headers.value(HttpHeaders.authorizationHeader), isNull);
        request.response.add(request.uri.path == '/mono'
            ? servedMono!
            : objectsByPath[request.uri.path]!);
        await request.response.close();
      });
      NativeStemDecoder? decoder;
      try {
        final manifest = parsePrepared(body, allowLoopbackHttp: true);
        final assets = PreparedStemAssets(
            rootDirectory: Directory('${root.path}/assets'),
            now: () => preparedNow,
            maxBytes: manifest.totalBytes);
        final lease = await assets.acquire(manifest);
        expect(requests, preparedRoles.length);
        decoder = NativeStemDecoder(lease: lease, libraryPath: library!);
        await lease.release();
        await decoder.ready;
        expect(await lease.directory.exists(), isTrue);
        expect(decoder.metadata.members.keys, preparedRoles);
        for (final member in decoder.metadata.members.values) {
          expect(member.sampleFrames, 48000);
          expect(member.preSkipFrames, preSkip);
          expect(member.sampleRateHz, 48000);
          expect(member.audioChannels, 2);
        }
        for (final range in [
          (0, 4096),
          (311, 1024),
          (47000, 4096),
          (48000, 128)
        ]) {
          final window = await decoder.readWindow(
              sourceStartFrame: range.$1, frameCount: range.$2);
          expect(window.sourceStartFrame, range.$1);
          expect(window.frameCount,
              range.$1 == 48000 ? 0 : (range.$1 == 47000 ? 1000 : range.$2));
          expect(window.manifestIdentity, manifest.identity);
          expect(window.stemModelVersion, manifest.stemModelVersion);
          expect(window.channels.keys, manifest.channels);
          expect(window.channels.containsKey('drums'), isFalse);
          for (final entry in window.channels.entries) {
            final pcm = entry.value;
            final expectedPcm = memberReference[entry.key]!;
            expect(pcm, isA<Float32List>());
            expect(pcm.length, window.frameCount * 2);
            for (var i = 0; i < pcm.length; i++) {
              expect((pcm[i] - expectedPcm[range.$1 * 2 + i]).abs(),
                  lessThan(.003));
            }
          }
          expect(() => window.channels.clear(), throwsUnsupportedError);
          if (window.frameCount > 0) {
            expect(() => window.channels.values.first[0] = 0,
                throwsUnsupportedError);
          }
          window.release();
          window.release();
          expect(() => window.channels, throwsStateError);
          expect(decoder.reservedPcmBytes, 0);
        }
        final closing = decoder.close();
        expect(identical(closing, decoder.close()), isTrue);
        await closing;
        expect(await lease.directory.exists(), isFalse);
        await expectLater(
            decoder.readWindow(sourceStartFrame: 0, frameCount: 1),
            throwsStateError);

        final foreignLease = await assets.acquire(manifest);
        NativeStemDecoder? acceptedForeign;
        try {
          expect(() {
            acceptedForeign = NativeStemDecoder(
                lease: _ForeignLease(foreignLease), libraryPath: library);
          }, throwsArgumentError);
        } finally {
          await acceptedForeign?.close();
          await foreignLease.release();
        }

        expect(() => NativeStemDecoder(lease: lease, libraryPath: library),
            throwsStateError);
        final boundsLease = await assets.acquire(manifest);
        decoder = NativeStemDecoder(
            lease: boundsLease,
            libraryPath: library,
            maxQueuedReads: 1,
            maxPcmBytes: 1920000);
        await boundsLease.release();
        await decoder.ready;
        for (final range in [(-1, 1), (48001, 1), (0, -1), (0, 48001)]) {
          await expectLater(
              decoder.readWindow(
                  sourceStartFrame: range.$1, frameCount: range.$2),
              throwsArgumentError);
        }
        final preCancelled = CancelToken()..cancel('before read');
        await expectLater(
            decoder.readWindow(
                sourceStartFrame: 0, frameCount: 1, cancelToken: preCancelled),
            throwsA(isA<DioException>()));

        final token = CancelToken();
        final held = await decoder.readWindow(
            sourceStartFrame: 0, frameCount: 48000, cancelToken: token);
        expect(decoder.reservedPcmBytes, 1920000);
        await expectLater(
            decoder.readWindow(sourceStartFrame: 0, frameCount: 1),
            throwsStateError);
        token.cancel('after delivery must not release PCM');
        await Future<void>.delayed(Duration.zero);
        expect(held.channels['vocals']!.length, 96000);
        expect(decoder.reservedPcmBytes, 1920000);
        held.release();
        expect(decoder.reservedPcmBytes, 0);

        // All three calls happen before the main isolate accepts a reply.
        final inFlightToken = CancelToken();
        final inFlight = decoder.readWindow(
            sourceStartFrame: 0, frameCount: 1024, cancelToken: inFlightToken);
        final inFlightCheck =
            expectLater(inFlight, throwsA(isA<DioException>()));
        final queuedToken = CancelToken();
        final queued = decoder.readWindow(
            sourceStartFrame: 100, frameCount: 1024, cancelToken: queuedToken);
        final queuedCheck = expectLater(queued, throwsA(isA<DioException>()));
        final fullCheck = expectLater(
            decoder.readWindow(sourceStartFrame: 0, frameCount: 1),
            throwsStateError);
        queuedToken.cancel('queued');
        inFlightToken.cancel('inflight');
        await Future.wait([inFlightCheck, queuedCheck, fullCheck]);
        expect(decoder.reservedPcmBytes, 0);
        expect(await boundsLease.directory.exists(), isTrue);
        await decoder.close();
        expect(await boundsLease.directory.exists(), isFalse);

        final drainLease = await assets.acquire(manifest);
        decoder = NativeStemDecoder(lease: drainLease, libraryPath: library);
        await decoder.ready;
        final draining =
            decoder.readWindow(sourceStartFrame: 0, frameCount: 48000);
        final drainingCheck = expectLater(draining, throwsStateError);
        final discarded =
            decoder.readWindow(sourceStartFrame: 0, frameCount: 1024);
        final discardedCheck = expectLater(discarded, throwsStateError);
        final drainClose = decoder.close();
        expect(drainLease.directory.existsSync(), isTrue);
        await drainLease.release();
        await Future.wait([drainClose, drainingCheck, discardedCheck]);
        expect(decoder.reservedPcmBytes, 0);
        expect(await drainLease.directory.exists(), isFalse);

        final cancelledLease = await assets.acquire(manifest);
        final openCancel = CancelToken();
        decoder = NativeStemDecoder(
            lease: cancelledLease,
            libraryPath: library,
            cancelToken: openCancel);
        final cancelledReady =
            expectLater(decoder.ready, throwsA(isA<DioException>()));
        openCancel.cancel('cancel open');
        await cancelledLease.release();
        await cancelledReady;
        await decoder.close();
        expect(await cancelledLease.directory.exists(), isFalse);

        final deliveredLease = await assets.acquire(manifest);
        final deliveredCancel = CancelToken();
        decoder = NativeStemDecoder(
            lease: deliveredLease,
            libraryPath: library,
            cancelToken: deliveredCancel);
        await deliveredLease.release();
        await decoder.ready;
        deliveredCancel.cancel('request owner gone after delivery');
        await Future<void>.delayed(Duration.zero);
        final independent =
            await decoder.readWindow(sourceStartFrame: 0, frameCount: 1);
        await decoder.close();
        expect(independent.channels['vocals']!.length, 2);
        independent.release();
        expect(await deliveredLease.directory.exists(), isFalse);

        // Immediate close must drain asynchronous native open and never deliver
        // queued PCM. Keep the private directory pinned until that barrier.
        final pendingLease = await assets.acquire(manifest);
        decoder = NativeStemDecoder(lease: pendingLease, libraryPath: library);
        final pending =
            decoder.readWindow(sourceStartFrame: 0, frameCount: 1024);
        final pendingCheck = expectLater(pending, throwsStateError);
        final readyCheck = expectLater(decoder.ready, throwsStateError);
        final pendingClose = decoder.close();
        expect(pendingLease.directory.existsSync(), isTrue);
        await pendingLease.release();
        await Future.wait([pendingClose, pendingCheck, readyCheck]);
        expect(await pendingLease.directory.exists(), isFalse);

        // Validate the sixth/reference member too: a verified manifest can claim
        // a hash for an actual, well-formed but incompatible Opus stream.
        final mono = File('${root.path}/mono.opus');
        final monoEncode = await Process.run('ffmpeg', [
          '-v',
          'error',
          '-i',
          encoded.path,
          '-ac',
          '1',
          '-c:a',
          'libopus',
          mono.path
        ]);
        expect(monoEncode.exitCode, 0, reason: '${monoEncode.stderr}');
        final monoBytes = await mono.readAsBytes();
        final monoDigest = sha256.convert(monoBytes).toString();
        final badMemberBody = Map<String, dynamic>.from(body);
        // Deep-copy because the manifest objects intentionally share references.
        final badMember = _copyJson(badMemberBody);
        final last = badMember['publishedManifest']['artifacts']['objects'][5];
        final lastDownload = badMember['memberDownloads'][5];
        final monoKey =
            'stems/42/$preparedModel/${'a' * 64}/g7/drums/$monoDigest.opus';
        for (final object in [last, lastDownload]) {
          object['key'] = monoKey;
          object['sha256'] = monoDigest;
          object['bytes'] = monoBytes.length;
        }
        lastDownload['url'] = 'http://127.0.0.1:${server.port}/mono';
        servedMono = monoBytes;
        final invalidManifests = [
          parsePrepared(badMember, allowLoopbackHttp: true),
          for (final kind in ['preskip', 'frames'])
            parsePrepared(_wrongMetadata(body, kind), allowLoopbackHttp: true),
        ];
        for (final invalidManifest in invalidManifests) {
          final failedLease = await assets.acquire(invalidManifest);
          decoder = NativeStemDecoder(lease: failedLease, libraryPath: library);
          final failureCheck = expectLater(
              decoder.ready, throwsA(isA<NativeStemDecoderException>()));
          await failedLease.release();
          await failureCheck;
          await decoder.close();
          expect(await failedLease.directory.exists(), isFalse);
        }

        final missingLibLease = await assets.acquire(manifest);
        decoder = NativeStemDecoder(
            lease: missingLibLease, libraryPath: '${root.path}/absent.dylib');
        final failureCheck = expectLater(
            decoder.ready, throwsA(isA<NativeStemDecoderException>()));
        await missingLibLease.release();
        await failureCheck;
        await decoder.close();
        expect(await missingLibLease.directory.exists(), isFalse);
      } finally {
        await decoder?.close();
        await subscription.cancel();
        await server.close(force: true);
        await root.delete(recursive: true);
      }
    }, _RealHttp());
  });
}

class _RealHttp extends HttpOverrides {}

Map<String, dynamic> _copyJson(Map<String, dynamic> body) =>
    jsonDecode(jsonEncode(body)) as Map<String, dynamic>;

Map<String, dynamic> _wrongMetadata(Map<String, dynamic> body, String kind) {
  final result = _copyJson(body);
  for (final member in result['publishedManifest']['artifacts']['objects']) {
    if (kind == 'preskip') {
      member['encoder_delay_frames']++;
    } else {
      // Remains within the manifest duration tolerance; only native metadata
      // establishes the actual trimmed frame count.
      member['sample_frames']--;
    }
  }
  return result;
}

// An interface implementation cannot establish verified private file ownership.
class _ForeignLease implements PreparedStemLease {
  _ForeignLease(this.delegate);
  final PreparedStemLease delegate;
  @override
  PreparedStemManifest get manifest => delegate.manifest;
  @override
  Directory get directory => delegate.directory;
  @override
  Map<String, Uri> get files => delegate.files;
  @override
  Map<String, Uri> get channelFiles => delegate.channelFiles;
  @override
  PreparedStemLease retain() => delegate.retain();
  @override
  Future<void> release() => delegate.release();
}
