import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:open_music_player/core/api/api_client.dart';
import 'package:open_music_player/core/audio/local_audio_artifact_resolver.dart';
import 'package:open_music_player/core/audio/playback_state.dart';
import 'package:open_music_player/core/audio/signed_audio_url_service.dart';
import 'package:open_music_player/core/engine/playback_engine.dart';
import 'package:open_music_player/core/engine/voice.dart';
import 'package:open_music_player/features/playlists/mix/desktop_mix_editor_screen.dart';
import 'package:open_music_player/models/mix_plan.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../test/support/mock_dio_client.dart';

const _lengthMs = 9000;
const _planId = 'native-timeline-fixture';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('macOS editor starts four AVPlayer voices and seeks to a fifth',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final cache = await getApplicationCacheDirectory();
    final temp = await cache.createTemp('soundq-timeline-probe-');
    final engine = PlaybackEngine(
      voiceFactory: () => JustAudioVoice(debugId: 'timeline-probe'),
    );
    final owner = PlaybackState(
      engine,
      localResolver: _FixtureSources(temp),
      signedAudioUrlService: SignedAudioUrlService.withRequester(
        (_) async =>
            throw StateError('Local audio must not request a signed URL'),
      ),
    );
    try {
      final wav = _silentWav();
      for (var id = 1; id <= 5; id++) {
        await File('${temp.path}/$id.wav').writeAsBytes(wav);
      }
      await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: _FixtureApi()),
          ChangeNotifierProvider<PlaybackState>.value(value: owner),
        ],
        child: const MaterialApp(home: DesktopMixEditorScreen(planId: _planId)),
      ));

      Future<void> waitFor(String label, bool Function() ready) async {
        final timer = Stopwatch()..start();
        while (!ready() && timer.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
          await tester.pump();
        }
        expect(ready(), isTrue,
            reason: '$label; session=${owner.snapshot.sessionId} '
                'position=${engine.positionMs} error=${owner.playbackError}; '
                'voices=${engine.pool.activeVoices.map((id, voice) => MapEntry(id, 'loaded=${voice.isLoaded} ready=${voice.isReady} '
                    'playing=${voice.isPlaying} pos=${voice.currentLocalPositionMs}'))}; '
                'messages=${find.byType(Text).evaluate().map((node) => (node.widget as Text).data).whereType<String>().where((text) => text.contains('Could not') || text.contains('Preparing')).toList()}');
      }

      final play = find.byKey(const ValueKey('mix-play'));
      await waitFor(
          'saved mix loaded into the editor', () => play.evaluate().isNotEmpty);
      expect(engine.pool.activeVoices, isEmpty);
      await tester.tap(play);
      await waitFor('four real voices are loaded and playing together', () {
        final voices = engine.pool.activeVoices;
        return voices.length == 4 &&
            voices.values.every(
              (voice) =>
                  voice is JustAudioVoice &&
                  voice.isReady &&
                  voice.isPlaying &&
                  (voice.currentLocalPositionMs ?? 0) >= 200,
            );
      });
      expect(engine.pool.activeVoices.keys,
          unorderedEquals(['clip-1', 'clip-2', 'clip-3', 'clip-4']));
      final simultaneousPositions = {
        for (final entry in engine.pool.activeVoices.entries)
          entry.key: entry.value.currentLocalPositionMs,
      };

      await tester.tap(find.byKey(const ValueKey('mix-pause')));
      await waitFor(
          'Pause stops every voice',
          () =>
              !owner.snapshot.playing &&
              engine.pool.activeVoices.values
                  .every((voice) => !voice.isPlaying));
      await tester.pump();
      final ruler = find.byKey(const ValueKey('mix-time-ruler'));
      // Default timeline scale is 35 pixels per second.
      await tester.tapAt(tester.getTopLeft(ruler) + const Offset(350, 12));
      await waitFor('ruler seeks to 10 seconds while paused',
          () => owner.snapshot.globalPosition == const Duration(seconds: 10));
      await tester.tap(play);
      await waitFor('the fifth, sequential clip starts on its own', () {
        final voices = engine.pool.activeVoices;
        final later = voices['clip-5'];
        return voices.length == 1 &&
            later != null &&
            later.isReady &&
            later.isPlaying &&
            (later.currentLocalPositionMs ?? 0) > 1000;
      });
      expect(tester.takeException(), isNull);
      // A native player clock receipt, not PCM or speaker capture.
      debugPrint('SOUNDQ_MACOS_TIMELINE ${jsonEncode({
            'fourPlayingPositionsMs': simultaneousPositions,
            'fifthPlayingPositionMs':
                engine.pool.activeVoices['clip-5']!.currentLocalPositionMs,
          })}');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await owner.stop();
      owner.dispose();
      await engine.dispose();
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}

Map<String, Object> _plan() => {
      'id': _planId,
      'name': 'Four-voice runtime fixture',
      'schemaVersion': 1,
      'version': 1,
      'createdAt': '2026-01-01T00:00:00Z',
      'updatedAt': '2026-01-01T00:00:00Z',
      'clips': [
        for (var id = 1; id <= 5; id++)
          {
            'clipId': 'clip-$id',
            'queueItemId': 'item-$id',
            'trackId': id,
            'sourceStartMs': 0,
            'sourceEndMs': _lengthMs,
            'timelineStartMs': id == 5 ? _lengthMs : 0,
            'gainDb': 0,
          },
      ],
      'summary': {
        'clipCount': 5,
        'trackIds': [1, 2, 3, 4, 5],
        'durationMs': 2 * _lengthMs,
      },
    };

class _FixtureSources implements LocalAudioArtifactResolver {
  _FixtureSources(this.directory);
  final Directory directory;

  @override
  Future<String?> localAudioPath(int trackId) async {
    final file = File('${directory.path}/$trackId.wav');
    return await file.length() == _silentWavSize ? file.path : null;
  }
}

const _sampleRate = 48000;
const _audioBytes = _sampleRate * 4 * _lengthMs ~/ 1000;
const _silentWavSize = 44 + _audioBytes;

class _FixtureApi extends ApiClient {
  _FixtureApi()
      : super(
            dio: mockQueueDio(
                (_) async => throw StateError('No network access expected')));

  @override
  Future<MixPlan> getMixPlan(String id) async {
    if (id != _planId) throw StateError('Unexpected saved mix: $id');
    return MixPlan.fromAuthoringJson(_plan());
  }
}

Uint8List _silentWav() {
  final data = ByteData(_silentWavSize);
  final bytes = data.buffer.asUint8List();
  void tag(int offset, String name) =>
      bytes.setRange(offset, offset + 4, name.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, _silentWavSize - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, _sampleRate, Endian.little);
  data.setUint32(28, _sampleRate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, _audioBytes, Endian.little);
  return bytes;
}
