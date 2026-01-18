import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

class AudioPlayerService {
  static AudioPlayerService? _instance;
  static AudioPlayerService get instance => _instance!;

  final AudioPlayer _player;
  final ConcatenatingAudioSource _playlist = ConcatenatingAudioSource(children: []);

  final BehaviorSubject<List<MediaItem>> _queue = BehaviorSubject.seeded([]);
  final BehaviorSubject<int?> _currentIndex = BehaviorSubject.seeded(null);
  final BehaviorSubject<bool> _shuffleEnabled = BehaviorSubject.seeded(false);
  final BehaviorSubject<LoopMode> _loopMode = BehaviorSubject.seeded(LoopMode.off);

  AudioPlayerService._internal() : _player = AudioPlayer() {
    _player.currentIndexStream.listen((index) {
      _currentIndex.add(index);
    });

    _player.shuffleModeEnabledStream.listen((enabled) {
      _shuffleEnabled.add(enabled);
    });

    _player.loopModeStream.listen((mode) {
      _loopMode.add(mode);
    });
  }

  static Future<AudioPlayerService> init() async {
    if (_instance != null) return _instance!;
    _instance = AudioPlayerService._internal();
    return _instance!;
  }

  AudioPlayer get player => _player;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration> get bufferedPositionStream => _player.bufferedPositionStream;
  Stream<List<MediaItem>> get queueStream => _queue.stream;
  Stream<int?> get currentIndexStream => _currentIndex.stream;
  Stream<bool> get shuffleEnabledStream => _shuffleEnabled.stream;
  Stream<LoopMode> get loopModeStream => _loopMode.stream;

  MediaItem? get currentMediaItem {
    final index = _currentIndex.value;
    final queue = _queue.value;
    if (index != null && index >= 0 && index < queue.length) {
      return queue[index];
    }
    return null;
  }

  Stream<MediaItem?> get currentMediaItemStream => Rx.combineLatest2(
    _queue.stream,
    _currentIndex.stream,
    (List<MediaItem> queue, int? index) {
      if (index != null && index >= 0 && index < queue.length) {
        return queue[index];
      }
      return null;
    },
  );

  Stream<PositionData> get positionDataStream => Rx.combineLatest3(
    _player.positionStream,
    _player.bufferedPositionStream,
    _player.durationStream,
    (position, buffered, duration) => PositionData(
      position: position,
      bufferedPosition: buffered,
      duration: duration ?? Duration.zero,
    ),
  );

  Future<void> setQueue(List<MediaItem> items, {int initialIndex = 0}) async {
    _queue.add(items);
    await _playlist.clear();

    final sources = items.map((item) => AudioSource.uri(
      Uri.parse(item.extras?['url'] ?? ''),
      tag: item,
    )).toList();

    await _playlist.addAll(sources);
    await _player.setAudioSource(_playlist, initialIndex: initialIndex);
  }

  Future<void> addToQueue(MediaItem item) async {
    final queue = List<MediaItem>.from(_queue.value)..add(item);
    _queue.add(queue);

    await _playlist.add(AudioSource.uri(
      Uri.parse(item.extras?['url'] ?? ''),
      tag: item,
    ));
  }

  Future<void> removeFromQueue(int index) async {
    final queue = List<MediaItem>.from(_queue.value)..removeAt(index);
    _queue.add(queue);
    await _playlist.removeAt(index);
  }

  Future<void> play() => _player.play();
  Future<void> pause() => _player.pause();
  Future<void> stop() => _player.stop();
  Future<void> seek(Duration position) => _player.seek(position);

  Future<void> skipToNext() async {
    if (_player.hasNext) {
      await _player.seekToNext();
    }
  }

  Future<void> skipToPrevious() async {
    if (_player.hasPrevious) {
      await _player.seekToPrevious();
    } else {
      await _player.seek(Duration.zero);
    }
  }

  Future<void> skipToIndex(int index) => _player.seek(Duration.zero, index: index);

  Future<void> setShuffleMode(bool enabled) => _player.setShuffleModeEnabled(enabled);

  Future<void> setLoopMode(LoopMode mode) => _player.setLoopMode(mode);

  Future<void> toggleShuffle() => setShuffleMode(!_shuffleEnabled.value);

  Future<void> cycleLoopMode() async {
    final modes = [LoopMode.off, LoopMode.all, LoopMode.one];
    final currentIndex = modes.indexOf(_loopMode.value);
    final nextIndex = (currentIndex + 1) % modes.length;
    await setLoopMode(modes[nextIndex]);
  }

  Future<void> dispose() async {
    await _queue.close();
    await _currentIndex.close();
    await _shuffleEnabled.close();
    await _loopMode.close();
    await _player.dispose();
    _instance = null;
  }
}

class PositionData {
  final Duration position;
  final Duration bufferedPosition;
  final Duration duration;

  PositionData({
    required this.position,
    required this.bufferedPosition,
    required this.duration,
  });
}
