import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../database/download_repository.dart';
import '../models/track.dart';
import 'api_client.dart';
import 'connectivity_service.dart';

enum PlaybackState { idle, loading, playing, paused, completed, error }

class AudioService {
  final AudioPlayer _player = AudioPlayer();
  final ApiClient _apiClient;
  final ConnectivityService _connectivityService;
  final DownloadRepository _downloadRepository;

  Track? _currentTrack;
  final List<Track> _queue = [];
  int _currentIndex = -1;
  bool _shuffle = false;
  bool _repeat = false;

  final _stateController = StreamController<PlaybackState>.broadcast();
  final _trackController = StreamController<Track?>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration?>.broadcast();

  Track? get currentTrack => _currentTrack;
  List<Track> get queue => List.unmodifiable(_queue);
  int get currentIndex => _currentIndex;
  bool get shuffle => _shuffle;
  bool get repeat => _repeat;

  Stream<PlaybackState> get stateStream => _stateController.stream;
  Stream<Track?> get trackStream => _trackController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration?> get durationStream => _durationController.stream;

  AudioService({
    required ApiClient apiClient,
    required ConnectivityService connectivityService,
    required DownloadRepository downloadRepository,
  })  : _apiClient = apiClient,
        _connectivityService = connectivityService,
        _downloadRepository = downloadRepository {
    _setupListeners();
  }

  void _setupListeners() {
    _player.playerStateStream.listen((state) {
      PlaybackState playbackState;
      if (state.processingState == ProcessingState.idle) {
        playbackState = PlaybackState.idle;
      } else if (state.processingState == ProcessingState.loading ||
          state.processingState == ProcessingState.buffering) {
        playbackState = PlaybackState.loading;
      } else if (state.processingState == ProcessingState.completed) {
        playbackState = PlaybackState.completed;
        _handleCompletion();
      } else if (state.playing) {
        playbackState = PlaybackState.playing;
      } else {
        playbackState = PlaybackState.paused;
      }
      _stateController.add(playbackState);
    });

    _player.positionStream.listen((position) {
      _positionController.add(position);
    });

    _player.durationStream.listen((duration) {
      _durationController.add(duration);
    });
  }

  Future<void> play(Track track) async {
    _currentTrack = track;
    _trackController.add(track);

    try {
      final localPath = await _downloadRepository.getLocalPath(track.id);

      if (localPath != null) {
        await _player.setFilePath(localPath);
      } else if (_connectivityService.isOnline) {
        final streamUrl = await _apiClient.getStreamUrl(track.id);
        await _player.setUrl(streamUrl);
      } else {
        _stateController.add(PlaybackState.error);
        return;
      }

      await _player.play();
    } catch (e) {
      _stateController.add(PlaybackState.error);
    }
  }

  Future<void> playQueue(List<Track> tracks, {int startIndex = 0}) async {
    _queue.clear();
    _queue.addAll(tracks);
    _currentIndex = startIndex;

    if (_queue.isNotEmpty && startIndex < _queue.length) {
      await play(_queue[startIndex]);
    }
  }

  Future<void> resume() async {
    await _player.play();
  }

  Future<void> pause() async {
    await _player.pause();
  }

  Future<void> stop() async {
    await _player.stop();
    _currentTrack = null;
    _trackController.add(null);
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;

    if (_shuffle) {
      _currentIndex = (_currentIndex + 1) % _queue.length;
    } else {
      _currentIndex++;
      if (_currentIndex >= _queue.length) {
        if (_repeat) {
          _currentIndex = 0;
        } else {
          _currentIndex = _queue.length - 1;
          return;
        }
      }
    }

    await play(_queue[_currentIndex]);
  }

  Future<void> previous() async {
    if (_queue.isEmpty) return;

    if (_player.position.inSeconds > 3) {
      await seek(Duration.zero);
      return;
    }

    _currentIndex--;
    if (_currentIndex < 0) {
      _currentIndex = _repeat ? _queue.length - 1 : 0;
    }

    await play(_queue[_currentIndex]);
  }

  void toggleShuffle() {
    _shuffle = !_shuffle;
  }

  void toggleRepeat() {
    _repeat = !_repeat;
  }

  void _handleCompletion() {
    if (_repeat && _queue.isEmpty) {
      play(_currentTrack!);
    } else {
      next();
    }
  }

  Future<void> setVolume(double volume) async {
    await _player.setVolume(volume.clamp(0.0, 1.0));
  }

  void dispose() {
    _player.dispose();
    _stateController.close();
    _trackController.close();
    _positionController.close();
    _durationController.close();
  }
}
