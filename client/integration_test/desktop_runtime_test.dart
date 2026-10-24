import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:open_music_player/core/platform/desktop_initialization.dart';
import 'package:open_music_player/main.dart' as app;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS keychain writes survive a separate plugin instance',
      (tester) async {
    final storage = applicationSecureStorage();
    final key = 'soundq-desktop-smoke-${DateTime.now().microsecondsSinceEpoch}';
    try {
      await storage.write(key: key, value: 'local-runtime-probe');
      expect(await applicationSecureStorage().read(key: key),
          'local-runtime-probe');
    } finally {
      await storage.delete(key: key);
    }
  });

  testWidgets(
      'desktop plugins and production entrypoint reach login without playback',
      (tester) async {
    expect(Platform.environment['SOUNDQ_NATIVE_DEVICE_LIBRARY'], isNull);
    final library = ffi.DynamicLibrary.open(
      '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/libsoundq_device.dylib',
    );
    for (final symbol in [
      'sq_create',
      'sq_render',
      'sq_device_open',
      'sq_device_start',
      'sq_opus_decoder_open'
    ]) {
      expect(library.providesSymbol(symbol), isTrue, reason: symbol);
    }
    // An isolated database, never the user's library.
    final cache = await getApplicationCacheDirectory();
    final dir = await Directory('${cache.path}/soundq-desktop-smoke-'
            '${DateTime.now().microsecondsSinceEpoch}')
        .create(recursive: true);
    final db = await openDatabase('${dir.path}/probe.sqlite');
    try {
      await db.execute('CREATE TABLE probe (value TEXT NOT NULL)');
      await db.insert('probe', {'value': 'macOS plugin'});
      expect((await db.query('probe')).single['value'], 'macOS plugin');
    } finally {
      await db.close();
    }
    expect((await getApplicationCacheDirectory()).path, isNotEmpty);
    expect(await LocalAuthentication().isDeviceSupported(), isA<bool>());
    final listening = AudioPlayer();
    try {
      // Decode/load one second of local silence using the actual macOS AVPlayer
      // plugin. Never call play(), openDevice() or startDevice().
      final wav = ByteData(44 + 48000 * 4);
      void tag(int offset, String text) {
        wav.buffer
            .asUint8List()
            .setRange(offset, offset + text.length, text.codeUnits);
      }

      tag(0, 'RIFF');
      wav.setUint32(4, wav.lengthInBytes - 8, Endian.little);
      tag(8, 'WAVEfmt ');
      wav.setUint32(16, 16, Endian.little);
      wav.setUint16(20, 1, Endian.little);
      wav.setUint16(22, 2, Endian.little);
      wav.setUint32(24, 48000, Endian.little);
      wav.setUint32(28, 48000 * 4, Endian.little);
      wav.setUint16(32, 4, Endian.little);
      wav.setUint16(34, 16, Endian.little);
      tag(36, 'data');
      wav.setUint32(40, 48000 * 4, Endian.little);
      final file = await File('${dir.path}/probe.wav')
          .writeAsBytes(wav.buffer.asUint8List());
      expect(
          await listening.setFilePath(file.path), const Duration(seconds: 1));
      expect(listening.playing, isFalse);
      expect(listening.processingState, ProcessingState.ready);
    } finally {
      await listening.dispose();
      await dir.delete(recursive: true);
    }
    await app.main(); // Includes the actual audio_service macOS initialization.
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('Sign in to continue'), findsOneWidget);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
