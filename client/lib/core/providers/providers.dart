import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/download_repository.dart';
import '../database/track_repository.dart';
import '../models/download_job.dart';
import '../models/track.dart';
import '../services/api_client.dart';
import '../services/audio_service.dart';
import '../services/connectivity_service.dart';
import '../services/download_service.dart';

// Repositories
final trackRepositoryProvider = Provider<TrackRepository>((ref) {
  return TrackRepository();
});

final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  return DownloadRepository();
});

// Services
final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient();
});

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final service = ConnectivityService();
  ref.onDispose(() => service.dispose());
  return service;
});

final downloadServiceProvider = Provider<DownloadService>((ref) {
  final service = DownloadService(
    apiClient: ref.watch(apiClientProvider),
    connectivityService: ref.watch(connectivityServiceProvider),
    downloadRepository: ref.watch(downloadRepositoryProvider),
    trackRepository: ref.watch(trackRepositoryProvider),
  );
  ref.onDispose(() => service.dispose());
  return service;
});

final audioServiceProvider = Provider<AudioService>((ref) {
  final service = AudioService(
    apiClient: ref.watch(apiClientProvider),
    connectivityService: ref.watch(connectivityServiceProvider),
    downloadRepository: ref.watch(downloadRepositoryProvider),
  );
  ref.onDispose(() => service.dispose());
  return service;
});

// State providers
final networkStatusProvider = StreamProvider<NetworkStatus>((ref) {
  final service = ref.watch(connectivityServiceProvider);
  return service.statusStream;
});

final currentNetworkStatusProvider = Provider<NetworkStatus>((ref) {
  return ref.watch(connectivityServiceProvider).currentStatus;
});

final downloadProgressProvider = StreamProvider<DownloadJob>((ref) {
  return ref.watch(downloadServiceProvider).progressStream;
});

final currentTrackProvider = StreamProvider<Track?>((ref) {
  return ref.watch(audioServiceProvider).trackStream;
});

final playbackStateProvider = StreamProvider<PlaybackState>((ref) {
  return ref.watch(audioServiceProvider).stateStream;
});

final playbackPositionProvider = StreamProvider<Duration>((ref) {
  return ref.watch(audioServiceProvider).positionStream;
});

final playbackDurationProvider = StreamProvider<Duration?>((ref) {
  return ref.watch(audioServiceProvider).durationStream;
});

// Library state
final libraryTracksProvider = FutureProvider<List<Track>>((ref) async {
  final trackRepo = ref.watch(trackRepositoryProvider);
  return trackRepo.getAllTracks();
});

final downloadedTracksProvider = FutureProvider<List<Track>>((ref) async {
  final trackRepo = ref.watch(trackRepositoryProvider);
  return trackRepo.getDownloadedTracks();
});

final downloadedOnlyFilterProvider = StateProvider<bool>((ref) => false);

final filteredLibraryTracksProvider = FutureProvider<List<Track>>((ref) async {
  final downloadedOnly = ref.watch(downloadedOnlyFilterProvider);
  final trackRepo = ref.watch(trackRepositoryProvider);

  if (downloadedOnly) {
    return trackRepo.getDownloadedTracks();
  }
  return trackRepo.getAllTracks();
});

// Download stats
final downloadStatsProvider = FutureProvider<DownloadStats>((ref) async {
  final downloadRepo = ref.watch(downloadRepositoryProvider);
  final count = await downloadRepo.getDownloadedTrackCount();
  final size = await downloadRepo.getTotalDownloadedSize();
  return DownloadStats(trackCount: count, totalSizeBytes: size);
});

class DownloadStats {
  final int trackCount;
  final int totalSizeBytes;

  DownloadStats({required this.trackCount, required this.totalSizeBytes});

  String get formattedSize {
    if (totalSizeBytes < 1024) return '$totalSizeBytes B';
    if (totalSizeBytes < 1024 * 1024) {
      return '${(totalSizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    if (totalSizeBytes < 1024 * 1024 * 1024) {
      return '${(totalSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(totalSizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

// Track download status
final trackDownloadStatusProvider =
    FutureProvider.family<bool, int>((ref, trackId) async {
  final downloadRepo = ref.watch(downloadRepositoryProvider);
  return downloadRepo.isTrackDownloaded(trackId);
});
