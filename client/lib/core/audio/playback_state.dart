import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'audio_player_service.dart';

class PlaybackState extends ChangeNotifier {
  final AudioPlayerService _audioService;

  List<StreamSubscription> _subscriptions = [];

  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _bufferedPosition = Duration.zero;
  Duration _duration = Duration.zero;
  MediaItem? _currentItem;
  List<MediaItem> _queue = [];
  int? _currentIndex;
  bool _shuffleEnabled = false;
  LoopMode _loopMode = LoopMode.off;

  bool get isPlaying => _isPlaying;
  Duration get position => _position;
  Duration get bufferedPosition => _bufferedPosition;
  Duration get duration => _duration;
  MediaItem? get currentItem => _currentItem;
  List<MediaItem> get queue => _queue;
  int? get currentIndex => _currentIndex;
  bool get shuffleEnabled => _shuffleEnabled;
  LoopMode get loopMode => _loopMode;
  bool get hasTrack => _currentItem != null;

  PlaybackState(this._audioService) {
    _init();
  }

  void _init() {
    _subscriptions = [
      _audioService.playerStateStream.listen((state) {
        _isPlaying = state.playing;
        notifyListeners();
      }),
      _audioService.positionStream.listen((pos) {
        _position = pos;
        notifyListeners();
      }),
      _audioService.bufferedPositionStream.listen((pos) {
        _bufferedPosition = pos;
        notifyListeners();
      }),
      _audioService.durationStream.listen((dur) {
        _duration = dur ?? Duration.zero;
        notifyListeners();
      }),
      _audioService.currentMediaItemStream.listen((item) {
        _currentItem = item;
        notifyListeners();
      }),
      _audioService.queueStream.listen((q) {
        _queue = q;
        notifyListeners();
      }),
      _audioService.currentIndexStream.listen((index) {
        _currentIndex = index;
        notifyListeners();
      }),
      _audioService.shuffleEnabledStream.listen((enabled) {
        _shuffleEnabled = enabled;
        notifyListeners();
      }),
      _audioService.loopModeStream.listen((mode) {
        _loopMode = mode;
        notifyListeners();
      }),
    ];
  }

  Future<void> playTrack(Map<String, dynamic> track) async {
    final mediaItem = MediaItem(
      id: track['id'].toString(),
      title: track['title'] ?? 'Unknown',
      artist: track['artist'] ?? 'Unknown Artist',
      album: track['album'] ?? 'Unknown Album',
      duration: Duration(seconds: track['duration'] ?? 0),
      artUri: track['artwork_url'] != null ? Uri.parse(track['artwork_url']) : null,
      extras: {
        'url': track['stream_url'],
      },
    );
    await _audioService.setQueue([mediaItem]);
    await _audioService.play();
  }

  Future<void> playQueue(List<Map<String, dynamic>> tracks, {int startIndex = 0}) async {
    final items = tracks.map((track) => MediaItem(
      id: track['id'].toString(),
      title: track['title'] ?? 'Unknown',
      artist: track['artist'] ?? 'Unknown Artist',
      album: track['album'] ?? 'Unknown Album',
      duration: Duration(seconds: track['duration'] ?? 0),
      artUri: track['artwork_url'] != null ? Uri.parse(track['artwork_url']) : null,
      extras: {
        'url': track['stream_url'],
      },
    )).toList();

    await _audioService.setQueue(items, initialIndex: startIndex);
    await _audioService.play();
  }

  Future<void> play() => _audioService.play();
  Future<void> pause() => _audioService.pause();
  Future<void> stop() => _audioService.stop();
  Future<void> seek(Duration position) => _audioService.seek(position);
  Future<void> skipToNext() => _audioService.skipToNext();
  Future<void> skipToPrevious() => _audioService.skipToPrevious();
  Future<void> skipToIndex(int index) => _audioService.skipToIndex(index);
  Future<void> toggleShuffle() => _audioService.toggleShuffle();
  Future<void> cycleLoopMode() => _audioService.cycleLoopMode();

  Future<void> togglePlayPause() async {
    if (_isPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    super.dispose();
  }
}
