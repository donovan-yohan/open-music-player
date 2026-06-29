import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/models/playlist_import.dart';
import '../../core/services/playlist_import_service.dart';
import '../../core/share/shared_url_parser.dart';

class PlaylistImportScreen extends StatefulWidget {
  final Duration pollInterval;

  const PlaylistImportScreen({
    super.key,
    this.pollInterval = const Duration(seconds: 2),
  });

  @override
  State<PlaylistImportScreen> createState() => _PlaylistImportScreenState();
}

class _PlaylistImportScreenState extends State<PlaylistImportScreen> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final _maxItemsController = TextEditingController(text: '500');

  PlaylistImportService? _service;
  PlaylistImportStatus? _importStatus;
  Timer? _pollTimer;
  bool _isSubmitting = false;
  bool _isRefreshing = false;
  String? _error;

  PlaylistImportService get _playlistImportService =>
      _service ??= PlaylistImportService(api: context.read<ApiClient>());

  @override
  void dispose() {
    _pollTimer?.cancel();
    _urlController.dispose();
    _nameController.dispose();
    _maxItemsController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final validationError = _validateForm();
    if (validationError != null) {
      setState(() => _error = validationError);
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final status = await _playlistImportService.createImport(
        url: _urlController.text,
        name: _nameController.text,
        maxItems: int.tryParse(_maxItemsController.text.trim()),
      );
      if (!mounted) return;
      setState(() => _importStatus = status);
      _startPollingIfNeeded(status);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Playlist import started')));
    } on DioException catch (error) {
      if (!mounted) return;
      setState(() => _error = _apiErrorMessage(error));
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not start playlist import: $error');
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  String? _validateForm() {
    final url = _urlController.text.trim();
    if (url.isEmpty) return 'Paste a YouTube playlist URL first.';
    if (!isYouTubePlaylistUrl(url)) {
      return 'Use a YouTube or YouTube Music URL with a playlist list= parameter.';
    }

    final maxItemsText = _maxItemsController.text.trim();
    if (maxItemsText.isNotEmpty) {
      final maxItems = int.tryParse(maxItemsText);
      if (maxItems == null || maxItems < 1 || maxItems > 1000) {
        return 'Max items must be between 1 and 1000.';
      }
    }
    return null;
  }

  void _startPollingIfNeeded(PlaylistImportStatus status) {
    _pollTimer?.cancel();
    if (status.isTerminal || status.id.isEmpty) return;
    _pollTimer = Timer.periodic(widget.pollInterval, (_) => _refreshStatus());
  }

  Future<void> _refreshStatus({bool manual = false}) async {
    final importId = _importStatus?.id;
    if (importId == null || importId.isEmpty || _isRefreshing) return;

    setState(() {
      _isRefreshing = true;
      if (manual) _error = null;
    });

    try {
      final status = await _playlistImportService.getImport(importId);
      if (!mounted) return;
      setState(() => _importStatus = status);
      if (status.isTerminal) {
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    } on DioException catch (error) {
      if (!mounted) return;
      if (manual) setState(() => _error = _apiErrorMessage(error));
    } catch (error) {
      if (!mounted) return;
      if (manual) setState(() => _error = 'Could not refresh import: $error');
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  String _apiErrorMessage(DioException error) {
    final data = error.response?.data;
    if (data is Map<String, dynamic>) {
      final message = data['message'] ?? data['error'];
      if (message is String && message.isNotEmpty) return message;
    }
    return error.message ?? 'server request failed';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Import YouTube playlist')),
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
                      Text(
                        'Turn a YouTube playlist into an OMP playlist.',
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Single-track imports still stay single-track; this path is the explicit bulk importer.',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      _ImportFormCard(
                        urlController: _urlController,
                        nameController: _nameController,
                        maxItemsController: _maxItemsController,
                        isSubmitting: _isSubmitting,
                        onSubmit: _submit,
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        _ErrorCard(message: _error!),
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

class _ImportFormCard extends StatelessWidget {
  final TextEditingController urlController;
  final TextEditingController nameController;
  final TextEditingController maxItemsController;
  final bool isSubmitting;
  final VoidCallback onSubmit;

  const _ImportFormCard({
    required this.urlController,
    required this.nameController,
    required this.maxItemsController,
    required this.isSubmitting,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: urlController,
              enabled: !isSubmitting,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'YouTube playlist URL',
                hintText: 'https://music.youtube.com/playlist?list=...',
                prefixIcon: Icon(Icons.link),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              enabled: !isSubmitting,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Playlist name (optional)',
                hintText: 'Use the source playlist title by default',
                prefixIcon: Icon(Icons.edit_note),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: maxItemsController,
              enabled: !isSubmitting,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => isSubmitting ? null : onSubmit(),
              decoration: const InputDecoration(
                labelText: 'Max items',
                helperText:
                    'Keeps massive playlists bounded. Backend hard limit: 1000.',
                prefixIcon: Icon(Icons.format_list_numbered),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: isSubmitting ? null : onSubmit,
              icon: isSubmitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.playlist_add),
              label: Text(
                isSubmitting ? 'Starting import…' : 'Import playlist',
              ),
            ),
          ],
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

  const _ErrorCard({required this.message});

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
              child: Text(
                message,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
