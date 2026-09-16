import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/models/playlist_import.dart';
import '../../core/services/playlist_import_service.dart';

/// Tracks an import job that has already been started.
///
/// This screen owns progress only: it polls an existing job (`importJobId`),
/// renders its status, and retries status refreshes. Starting an import is
/// owned by the shared playlist creation dialog
/// (`playlist_creation_dialog.dart`), which is the only caller that navigates
/// here.
class PlaylistImportProgressScreen extends StatefulWidget {
  final Duration pollInterval;
  final PlaylistImportStatus? initialStatus;
  final String? importJobId;
  final PlaylistImportService? importService;

  const PlaylistImportProgressScreen({
    super.key,
    this.pollInterval = const Duration(seconds: 2),
    this.initialStatus,
    this.importJobId,
    this.importService,
  });

  @override
  State<PlaylistImportProgressScreen> createState() =>
      _PlaylistImportProgressScreenState();
}

class _PlaylistImportProgressScreenState
    extends State<PlaylistImportProgressScreen> {
  String? _sourceImportJobId;

  PlaylistImportService? _service;
  PlaylistImportStatus? _importStatus;
  Timer? _pollTimer;
  bool _isRefreshing = false;
  bool _isLoadingInitialStatus = false;
  int _statusRequestGeneration = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _importStatus = widget.initialStatus;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final routeJobId = widget.importJobId;
    if (_sourceImportJobId == routeJobId) {
      if (_importStatus != null &&
          !_importStatus!.isTerminal &&
          _pollTimer == null) {
        _startPollingIfNeeded(_importStatus!);
      }
      return;
    }
    _sourceImportJobId = routeJobId;
    if (_importStatus != null) {
      _startPollingIfNeeded(_importStatus!);
    } else if (routeJobId != null && routeJobId.isNotEmpty) {
      _refreshStatus(importId: routeJobId, manual: true);
    }
  }

  @override
  void didUpdateWidget(covariant PlaylistImportProgressScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.importJobId == widget.importJobId &&
        oldWidget.initialStatus == widget.initialStatus) {
      return;
    }

    _pollTimer?.cancel();
    _pollTimer = null;
    _statusRequestGeneration++;
    _importStatus = widget.initialStatus;
    _sourceImportJobId = widget.importJobId;
    if (_importStatus != null) {
      _startPollingIfNeeded(_importStatus!);
    } else if (widget.importJobId != null && widget.importJobId!.isNotEmpty) {
      _refreshStatus(importId: widget.importJobId!, manual: true);
    }
  }

  PlaylistImportService get _playlistImportService =>
      _service ??= widget.importService ??
          PlaylistImportService(api: context.read<ApiClient>());

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  void _startPollingIfNeeded(PlaylistImportStatus status) {
    _pollTimer?.cancel();
    if (status.isTerminal || status.id.isEmpty) return;
    _pollTimer = Timer.periodic(widget.pollInterval, (_) => _refreshStatus());
  }

  Future<void> _refreshStatus({String? importId, bool manual = false}) async {
    final id = importId ?? _importStatus?.id;
    if (id == null || id.isEmpty || (_isRefreshing && importId == null)) return;

    final requestGeneration = ++_statusRequestGeneration;
    setState(() {
      _isRefreshing = true;
      _isLoadingInitialStatus = _importStatus == null;
      if (manual) _error = null;
    });

    try {
      final status = await _playlistImportService.getImport(id);
      if (!mounted || requestGeneration != _statusRequestGeneration) return;
      setState(() => _importStatus = status);
      if (status.isTerminal) {
        _pollTimer?.cancel();
        _pollTimer = null;
      } else if (_pollTimer == null) {
        _startPollingIfNeeded(status);
      }
    } on DioException catch (error) {
      if (!mounted || requestGeneration != _statusRequestGeneration) return;
      if (manual) setState(() => _error = apiErrorMessage(error));
    } catch (error) {
      if (!mounted || requestGeneration != _statusRequestGeneration) return;
      if (manual) setState(() => _error = 'Could not refresh import: $error');
    } finally {
      if (mounted && requestGeneration == _statusRequestGeneration) {
        setState(() {
          _isRefreshing = false;
          _isLoadingInitialStatus = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Import progress')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        _ErrorCard(
                          message: _error!,
                          onRetry: widget.importJobId?.isNotEmpty == true
                              ? () => _refreshStatus(
                                    importId: widget.importJobId,
                                    manual: true,
                                  )
                              : null,
                        ),
                      ],
                      if (_isLoadingInitialStatus) ...[
                        const SizedBox(height: 16),
                        const Card(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 12),
                                Text('Loading import progress…'),
                              ],
                            ),
                          ),
                        ),
                      ],
                      if (_importStatus != null) ...[
                        const SizedBox(height: 16),
                        _ImportProgressCard(
                          status: _importStatus!,
                          isRefreshing: _isRefreshing,
                          onRefresh: () => _refreshStatus(manual: true),
                          onOpenPlaylist: _importStatus!.playlistId > 0
                              ? () => context.push(
                                    '/playlists/${_importStatus!.playlistId}',
                                  )
                              : null,
                        ),
                      ],
                      // Deep-link arrival with nothing to show. Starting an
                      // import belongs to the shared creation dialog, which is
                      // also the only caller that reaches this route with a job.
                      if (_importStatus == null &&
                          !_isLoadingInitialStatus) ...[
                        const SizedBox(height: 16),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'No import in progress',
                                  style: theme.textTheme.titleMedium,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Start one from Create Playlist on the Playlists or Library screen.',
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ImportProgressCard extends StatelessWidget {
  final PlaylistImportStatus status;
  final bool isRefreshing;
  final VoidCallback onRefresh;
  final VoidCallback? onOpenPlaylist;

  const _ImportProgressCard({
    required this.status,
    required this.isRefreshing,
    required this.onRefresh,
    required this.onOpenPlaylist,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failures = status.items.where((item) => item.isFailed).toList();
    final reused = status.items.where((item) => item.isDuplicateReuse).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status.sourceTitle ?? 'Playlist import',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(_statusDescription(status)),
                    ],
                  ),
                ),
                _StatusPill(status: status.status),
              ],
            ),
            const SizedBox(height: 16),
            LinearProgressIndicator(value: status.progressFraction),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MetricChip(
                  label: 'Imported',
                  value: status.importedItems,
                  icon: Icons.library_add_check,
                ),
                _MetricChip(
                  label: 'Reused',
                  value: status.reusedItems,
                  icon: Icons.repeat,
                ),
                _MetricChip(
                  label: 'Queued',
                  value: status.queuedItems,
                  icon: Icons.downloading,
                ),
                _MetricChip(
                  label: 'Failed',
                  value: status.failedItems,
                  icon: Icons.error_outline,
                ),
                _MetricChip(
                  label: 'Total',
                  value: status.totalItems,
                  icon: Icons.format_list_bulleted,
                ),
              ],
            ),
            if (status.error != null) ...[
              const SizedBox(height: 12),
              Text(
                status.error!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            if (reused.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '${reused.length} duplicate ${reused.length == 1 ? 'track was' : 'tracks were'} reused and added without counting as failures.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (failures.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Partial failures', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              ...failures.take(5).map(
                    (item) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: const Icon(Icons.error_outline),
                      title: Text(item.displayTitle),
                      subtitle: Text(
                        item.error ?? 'Could not import this item',
                      ),
                    ),
                  ),
              if (failures.length > 5)
                Text(
                  '+${failures.length - 5} more failed items',
                  style: theme.textTheme.bodySmall,
                ),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: isRefreshing ? null : onRefresh,
                  icon: isRefreshing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
                if (onOpenPlaylist != null)
                  FilledButton.icon(
                    onPressed: onOpenPlaylist,
                    icon: const Icon(Icons.queue_music),
                    label: const Text('Open playlist'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _statusDescription(PlaylistImportStatus status) {
    switch (status.status) {
      case PlaylistImportStatus.resolving:
        return 'Reading playlist metadata from YouTube…';
      case PlaylistImportStatus.importing:
        return 'Importing tracks into the OMP playlist.';
      case PlaylistImportStatus.complete:
        return 'Import complete. Imported or reused ${status.successfulOrReusedItems} tracks.';
      case PlaylistImportStatus.partialFailure:
        return 'Import finished with partial failures. Successful tracks are still in the playlist.';
      case PlaylistImportStatus.failed:
        return 'Import failed before it could finish.';
      case PlaylistImportStatus.cancelled:
        return 'Import was cancelled.';
      default:
        return 'Import status: ${status.status.replaceAll('_', ' ')}';
    }
  }
}

class _MetricChip extends StatelessWidget {
  final String label;
  final int value;
  final IconData icon;

  const _MetricChip({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Chip(
      avatar: Icon(icon, size: 18),
      label: Text('$label: $value'),
      backgroundColor: theme.colorScheme.surfaceContainerHighest,
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (status) {
      PlaylistImportStatus.complete => Colors.green,
      PlaylistImportStatus.partialFailure => Colors.orange,
      PlaylistImportStatus.failed => theme.colorScheme.error,
      PlaylistImportStatus.cancelled => theme.colorScheme.error,
      _ => theme.colorScheme.primary,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        status.replaceAll('_', ' '),
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const _ErrorCard({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                  if (onRetry != null) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: onRetry,
                      child: const Text('Retry'),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
