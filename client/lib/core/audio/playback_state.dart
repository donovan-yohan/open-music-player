import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'audio_player_service.dart';
import 'signed_audio_url_service.dart';

class PlaybackState extends ChangeNotifier {
  final AudioPlayerService _audioService;
  final SignedAudioUrlService _signedAudioUrlService;

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
  String? _playbackError;
  bool _isResolvingSignedUrl = false;

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
  String? get playbackError => _playbackError;
  bool get isResolvingSignedUrl => _isResolvingSignedUrl;

  PlaybackState(
    this._audioService, {
    required SignedAudioUrlService signedAudioUrlService,
  }) : _signedAudioUrlService = signedAudioUrlService {
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
    await _resolveSignedUrls(() async {
      final trackId = _readTrackId(track);
      final descriptor =
          await _signedAudioUrlService.requireDescriptor(trackId);
      final mediaItem = _buildMediaItem(track, descriptor);
      await _audioService.setQueue([mediaItem]);
      await _audioService.play();
    });
  }

  Future<void> playQueue(List<Map<String, dynamic>> tracks,
      {int startIndex = 0}) async {
    if (tracks.isEmpty) return;

    await _resolveSignedUrls(() async {
      final trackIds = tracks.map(_readTrackId).toList();
      final descriptors =
          await _signedAudioUrlService.requireDescriptors(trackIds);
      final items = tracks.map((track) {
        final trackId = _readTrackId(track);
        return _buildMediaItem(track, descriptors[trackId]!);
      }).toList();

      await _audioService.setQueue(items, initialIndex: startIndex);
      await _audioService.play();
    });
  }

  MediaItem _buildMediaItem(
    Map<String, dynamic> track,
    SignedAudioDescriptor descriptor,
  ) {
    return MediaItem(
      id: descriptor.trackId.toString(),
      title: track['title'] as String? ?? 'Unknown',
      artist: track['artist'] as String? ?? 'Unknown Artist',
      album: track['album'] as String? ?? 'Unknown Album',
      duration: Duration(seconds: track['duration'] as int? ?? 0),
      artUri: track['artwork_url'] != null
          ? Uri.parse(track['artwork_url'] as String)
          : null,
      extras: {
        'url': descriptor.url,
        'expiresAt': descriptor.expiresAt.toIso8601String(),
        if (descriptor.contentType != null)
          'contentType': descriptor.contentType,
        if (descriptor.sizeBytes != null) 'sizeBytes': descriptor.sizeBytes,
        if (descriptor.etag != null) 'etag': descriptor.etag,
        if (descriptor.storageVersion != null)
          'storageVersion': descriptor.storageVersion,
      },
    );
  }

  int _readTrackId(Map<String, dynamic> track) {
    final id = track['id'];
    if (id is int && id > 0) return id;
    if (id is String) {
      final parsed = int.tryParse(id);
      if (parsed != null && parsed > 0) return parsed;
    }
    throw const SignedAudioUrlException(
      code: 'INVALID_TRACK_ID',
      message: 'Track is missing a numeric ID for playback URL issuance.',
    );
  }

  Future<void> _resolveSignedUrls(Future<void> Function() action) async {
    _isResolvingSignedUrl = true;
    _playbackError = null;
    notifyListeners();

    try {
      await action();
    } on SignedAudioUrlException catch (error) {
      _playbackError = _userFacingPlaybackError(error);
      if (kDebugMode) {
        debugPrint('Playback URL resolution failed: ${error.code}');
      }
      rethrow;
    } catch (error) {
      _playbackError = 'Playback failed before audio could start.';
      if (kDebugMode) {
        debugPrint('Playback start failed: $error');
      }
      rethrow;
    } finally {
      _isResolvingSignedUrl = false;
      notifyListeners();
    }
  }

  String _userFacingPlaybackError(SignedAudioUrlException error) {
    switch (error.code) {
      case 'AUDIO_UNAVAILABLE':
      case 'OBJECT_UNAVAILABLE':
        return 'Audio is unavailable for this track.';
      case 'PLAYBACK_URL_EXPIRED':
        return 'The playback link expired. Try playing the track again.';
      case 'TRACK_NOT_FOUND':
        return 'This track is no longer available.';
      case 'FORBIDDEN':
        return 'You do not have access to play this track.';
      default:
        return 'Could not prepare a signed playback URL.';
    }
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
