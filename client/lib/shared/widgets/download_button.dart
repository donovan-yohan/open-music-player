import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/download/download_state.dart';
import '../models/models.dart';

class DownloadButton extends StatelessWidget {
  final Track track;
  final double size;

  const DownloadButton({
    super.key,
    required this.track,
    this.size = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<DownloadState>(
      builder: (context, downloadState, child) {
        final progress = downloadState.getProgress(track.id);
        final isDownloading = progress != null;

        return FutureBuilder<bool>(
          future: downloadState.isDownloaded(track.id),
          builder: (context, snapshot) {
            final isDownloaded = snapshot.data ?? false;

            if (isDownloaded) {
              return _buildDownloadedButton(context, downloadState);
            }

            if (isDownloading) {
              return _buildProgressButton(context, downloadState, progress);
            }

            return _buildDownloadButton(context, downloadState);
          },
        );
      },
    );
  }

  Widget _buildDownloadedButton(
      BuildContext context, DownloadState downloadState) {
    return IconButton(
      icon: Icon(
        Icons.check_circle,
        color: Theme.of(context).colorScheme.primary,
        size: size,
      ),
      onPressed: () => _showDeleteDialog(context, downloadState),
      tooltip: 'Downloaded',
    );
  }

  Widget _buildProgressButton(
    BuildContext context,
    DownloadState downloadState,
    DownloadProgress progress,
  ) {
    return SizedBox(
      width: size + 16,
      height: size + 16,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CircularProgressIndicator(
            value: progress.progress,
            strokeWidth: 2,
            color: Theme.of(context).colorScheme.primary,
          ),
          IconButton(
            icon: Icon(Icons.close, size: size * 0.6),
            onPressed: () => downloadState.cancelDownload(track.id),
            tooltip: 'Cancel download',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
        ],
      ),
    );
  }

  Widget _buildDownloadButton(
      BuildContext context, DownloadState downloadState) {
    return IconButton(
      icon: Icon(
        Icons.download_outlined,
        size: size,
      ),
      onPressed: () => downloadState.downloadTrack(track),
      tooltip: 'Download',
    );
  }

  void _showDeleteDialog(BuildContext context, DownloadState downloadState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Download'),
        content: Text('Remove "${track.title}" from downloads?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              downloadState.deleteDownload(track.id);
              Navigator.pop(context);
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

/// What a whole collection's offline state adds up to, as one label.
enum DownloadAllStatus {
  /// Nothing to download.
  empty,

  /// No track is on disk yet.
  none,

  /// Some tracks are on disk, none is transferring.
  partial,

  /// At least one transfer is running.
  inProgress,

  /// Every track is on disk.
  complete,
}

/// The aggregate the "Download all" affordance renders.
///
/// Kept as a plain value so the collapse from per-track state to one label is
/// unit-testable without pumping a widget.
@immutable
class DownloadAllAggregate {
  const DownloadAllAggregate({
    required this.total,
    required this.downloaded,
    required this.inProgress,
  });

  /// Collapses [tracks] against the app's download state.
  factory DownloadAllAggregate.of(
    DownloadState downloadState,
    List<Track> tracks,
  ) {
    final completed = downloadState.downloadedTrackIds;
    var downloaded = 0;
    var inProgress = 0;
    for (final track in tracks) {
      if (downloadState.isDownloading(track.id)) {
        inProgress++;
      } else if (completed.contains(track.id)) {
        downloaded++;
      }
    }
    return DownloadAllAggregate(
      total: tracks.length,
      downloaded: downloaded,
      inProgress: inProgress,
    );
  }

  final int total;
  final int downloaded;
  final int inProgress;

  /// Tracks a tap would still have to fetch.
  int get remaining => total - downloaded - inProgress;

  DownloadAllStatus get status {
    if (total == 0) return DownloadAllStatus.empty;
    if (inProgress > 0) return DownloadAllStatus.inProgress;
    if (downloaded >= total) return DownloadAllStatus.complete;
    if (downloaded > 0) return DownloadAllStatus.partial;
    return DownloadAllStatus.none;
  }

  String get label => switch (status) {
        DownloadAllStatus.empty => 'Download all',
        DownloadAllStatus.none => 'Download all',
        DownloadAllStatus.partial => 'Download $remaining more',
        DownloadAllStatus.inProgress => 'Downloading $downloaded/$total',
        DownloadAllStatus.complete => 'Downloaded',
      };
}

/// One-tap offline download for a whole collection (playlist, Liked Songs).
///
/// The button is inert while a transfer is running, which — together with
/// `DownloadService.downloadTracks` skipping in-flight and already-downloaded
/// tracks — is what keeps a re-tap from duplicating jobs.
class DownloadAllButton extends StatelessWidget {
  const DownloadAllButton({
    super.key,
    required this.tracks,
    this.buttonKey,
  });

  /// Convenience for the playlist surfaces, which hold a [Playlist].
  DownloadAllButton.forPlaylist(
    Playlist playlist, {
    Key? key,
    Key? buttonKey,
  }) : this(
          key: key,
          tracks: playlist.tracks ?? const <Track>[],
          buttonKey: buttonKey,
        );

  final List<Track> tracks;

  /// Key placed on the tappable button itself, for surface-specific tests.
  final Key? buttonKey;

  @override
  Widget build(BuildContext context) {
    // Nullable lookup: offline downloads are an optional capability, so a
    // surface rendered without a DownloadState simply shows no affordance
    // instead of crashing.
    final downloadState = context.watch<DownloadState?>();
    if (downloadState == null) return const SizedBox.shrink();

    final aggregate = DownloadAllAggregate.of(downloadState, tracks);
    if (aggregate.status == DownloadAllStatus.empty) {
      return const SizedBox.shrink();
    }

    final busy = aggregate.status == DownloadAllStatus.inProgress;
    final done = aggregate.status == DownloadAllStatus.complete;

    return TextButton.icon(
      key: buttonKey ?? const ValueKey('download_all_button'),
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(done ? Icons.check_circle : Icons.download),
      label: Text(aggregate.label),
      onPressed: busy || done
          ? null
          : () => downloadState.downloadTracks(List<Track>.of(tracks)),
    );
  }
}
