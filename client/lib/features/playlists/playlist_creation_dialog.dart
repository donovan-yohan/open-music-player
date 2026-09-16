import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_client.dart';
import '../../core/models/playlist_import.dart';
import '../../core/services/playlist_import_service.dart';
import '../../core/services/playlist_service.dart';
import '../../core/share/shared_url_parser.dart';
import '../../shared/models/playlist.dart';

/// The provider-neutral variants supported by the create-playlist surface.
enum PlaylistCreationKind { blank, youtubeImport }

/// User input collected by the shared playlist creation surface.
sealed class PlaylistCreationIntent {
  const PlaylistCreationIntent();
}

final class BlankPlaylistCreationIntent extends PlaylistCreationIntent {
  final String name;
  final String? description;
  final String? coverUrl;
  final bool isPublic;

  const BlankPlaylistCreationIntent({
    required this.name,
    this.description,
    this.coverUrl,
    required this.isPublic,
  });
}

final class YouTubePlaylistCreationIntent extends PlaylistCreationIntent {
  final String sourceUrl;
  final String? name;
  final String? description;
  final int? maxItems;

  const YouTubePlaylistCreationIntent({
    required this.sourceUrl,
    this.name,
    this.description,
    this.maxItems,
  });
}

/// Result returned after a create or import request has been accepted.
sealed class PlaylistCreationOutcome {
  const PlaylistCreationOutcome();
}

final class PlaylistCreatedOutcome extends PlaylistCreationOutcome {
  final Playlist playlist;

  const PlaylistCreatedOutcome(this.playlist);
}

final class PlaylistImportedOutcome extends PlaylistCreationOutcome {
  final PlaylistImportStatus status;

  const PlaylistImportedOutcome(this.status);
}

String? validateYouTubePlaylistUrl(String? value) {
  final url = value?.trim() ?? '';
  if (url.isEmpty) return 'Paste a YouTube playlist URL first.';
  if (!isYouTubePlaylistUrl(url)) {
    return 'Use a YouTube or YouTube Music URL with a playlist list= parameter.';
  }
  return null;
}

String? validatePlaylistImportMaxItems(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  final maxItems = int.tryParse(text);
  if (maxItems == null || maxItems < 1 || maxItems > 1000) {
    return 'Max items must be between 1 and 1000.';
  }
  return null;
}

/// Shared fields and validation for the supported YouTube import request.
///
/// Both the modal creation flow and the legacy progress route use this widget,
/// so URL/name/description/limit semantics cannot drift between entry points.
class PlaylistImportForm extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController sourceUrlController;
  final TextEditingController nameController;
  final TextEditingController descriptionController;
  final TextEditingController maxItemsController;
  final bool isSubmitting;
  final bool showSubmitButton;
  final VoidCallback? onSubmit;

  const PlaylistImportForm({
    super.key,
    required this.formKey,
    required this.sourceUrlController,
    required this.nameController,
    required this.descriptionController,
    required this.maxItemsController,
    required this.isSubmitting,
    this.showSubmitButton = false,
    this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Form(
      key: formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: sourceUrlController,
            enabled: !isSubmitting,
            autofocus: true,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'YouTube playlist URL',
              hintText: 'https://music.youtube.com/playlist?list=...',
              prefixIcon: Icon(Icons.link),
              border: OutlineInputBorder(),
            ),
            validator: validateYouTubePlaylistUrl,
          ),
          const SizedBox(height: 12),
          TextFormField(
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
          TextFormField(
            controller: descriptionController,
            enabled: !isSubmitting,
            textInputAction: TextInputAction.next,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              hintText: 'Enter description',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: maxItemsController,
            enabled: !isSubmitting,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: showSubmitButton ? (_) => onSubmit?.call() : null,
            decoration: const InputDecoration(
              labelText: 'Max items',
              helperText:
                  'Keeps massive playlists bounded. Backend hard limit: 1000.',
              prefixIcon: Icon(Icons.format_list_numbered),
              border: OutlineInputBorder(),
            ),
            validator: validatePlaylistImportMaxItems,
          ),
          if (showSubmitButton) ...[
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
              label:
                  Text(isSubmitting ? 'Starting import…' : 'Import playlist'),
            ),
          ],
        ],
      ),
    );
  }
}

/// Renders any submit failure as an actionable message.
///
/// API failures carry the backend's own message in the response body; a bare
/// `toString()` buries it under transport boilerplate. Shared with the route
/// import screen so the modal and the route cannot disagree about the same
/// failure.
String playlistCreationErrorMessage(Object error) {
  if (error is DioException) return apiErrorMessage(error);
  final message = error.toString();
  return message.startsWith('Exception: ')
      ? message.substring('Exception: '.length)
      : message;
}

/// A single modal shell for blank playlist creation and supported imports.
class PlaylistCreationDialog extends StatefulWidget {
  final Future<PlaylistCreationOutcome> Function(PlaylistCreationIntent intent)
      onSubmit;

  const PlaylistCreationDialog({super.key, required this.onSubmit});

  @override
  State<PlaylistCreationDialog> createState() => _PlaylistCreationDialogState();
}

class _PlaylistCreationDialogState extends State<PlaylistCreationDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _coverUrlController = TextEditingController();
  final _sourceUrlController = TextEditingController();
  final _maxItemsController = TextEditingController(text: '500');

  PlaylistCreationKind? _kind;
  bool _isPublic = false;
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _coverUrlController.dispose();
    _sourceUrlController.dispose();
    _maxItemsController.dispose();
    super.dispose();
  }

  bool get _isImport => _kind == PlaylistCreationKind.youtubeImport;

  String get _submitLabel => _isImport ? 'Import playlist' : 'Create playlist';

  void _selectKind(PlaylistCreationKind kind) {
    if (_isSubmitting) return;
    setState(() {
      _kind = kind;
      _error = null;
    });
  }

  void _goBackToSourceChoices() {
    if (_isSubmitting) return;
    setState(() {
      _kind = null;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_isSubmitting || _kind == null || !_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final intent = _isImport
          ? YouTubePlaylistCreationIntent(
              sourceUrl: _sourceUrlController.text.trim(),
              name: _optionalText(_nameController),
              description: _optionalText(_descriptionController),
              maxItems: int.tryParse(_maxItemsController.text.trim()),
            )
          : BlankPlaylistCreationIntent(
              name: _nameController.text.trim(),
              description: _optionalText(_descriptionController),
              coverUrl: _optionalText(_coverUrlController),
              isPublic: _isPublic,
            );
      final outcome = await widget.onSubmit(intent);
      if (mounted) Navigator.of(context).pop(outcome);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  String? _validateBlankName(String? value) {
    if (value == null || value.trim().isEmpty) return 'Please enter a name';
    return null;
  }

  String? _optionalText(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : value;
  }

  String _errorMessage(Object error) => playlistCreationErrorMessage(error);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      // While a submit is in flight the modal owns the outcome: dismissing it
      // would silently drop a playlist or import job the server already
      // created. Back-navigation is blocked for the same reason as the scrim.
      canPop: !_isSubmitting,
      child: AlertDialog(
        key: const ValueKey('playlist_creation_dialog'),
        title: Row(
          children: [
            if (_kind != null)
              IconButton(
                key: const ValueKey('playlist_creation_back'),
                onPressed: _isSubmitting ? null : _goBackToSourceChoices,
                tooltip: 'Choose another playlist type',
                icon: const Icon(Icons.arrow_back),
              ),
            Expanded(child: Text(_kind == null ? 'Create Playlist' : _title)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: SingleChildScrollView(
            child: _kind == null ? _buildSourceChoices(theme) : _buildForm(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _isSubmitting ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          if (_kind != null)
            FilledButton(
              key: const ValueKey('playlist_creation_submit'),
              onPressed: _isSubmitting ? null : _submit,
              child: _isSubmitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_submitLabel),
            ),
        ],
      ),
    );
  }

  String get _title =>
      _isImport ? 'Import from YouTube' : 'Create blank playlist';

  Widget _buildSourceChoices(ThemeData theme) {
    return Column(
      key: const ValueKey('playlist_creation_source_choices'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Choose how you want to start.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        _SourceChoiceTile(
          key: const ValueKey('playlist_creation_blank'),
          icon: Icons.playlist_add,
          title: 'Blank playlist',
          subtitle: 'Start with your own name, details, and visibility.',
          onTap: () => _selectKind(PlaylistCreationKind.blank),
        ),
        const SizedBox(height: 8),
        _SourceChoiceTile(
          key: const ValueKey('playlist_creation_youtube'),
          icon: Icons.video_library_outlined,
          title: 'Import from YouTube',
          subtitle: 'Bring in a YouTube or YouTube Music playlist.',
          onTap: () => _selectKind(PlaylistCreationKind.youtubeImport),
        ),
      ],
    );
  }

  Widget _buildForm() {
    if (_isImport) {
      return Column(
        children: [
          PlaylistImportForm(
            formKey: _formKey,
            sourceUrlController: _sourceUrlController,
            nameController: _nameController,
            descriptionController: _descriptionController,
            maxItemsController: _maxItemsController,
            isSubmitting: _isSubmitting,
          ),
          if (_error != null) _buildErrorMessage(),
        ],
      );
    }

    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _nameController,
            enabled: !_isSubmitting,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Playlist name',
              hintText: 'Enter playlist name',
              prefixIcon: Icon(Icons.edit_note),
              border: OutlineInputBorder(),
            ),
            validator: _validateBlankName,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _descriptionController,
            enabled: !_isSubmitting,
            textInputAction: TextInputAction.next,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              hintText: 'Enter description',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _coverUrlController,
            enabled: !_isSubmitting,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              labelText: 'Cover image URL (optional)',
              hintText: 'https://…',
              prefixIcon: Icon(Icons.image_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Public'),
            subtitle: const Text('Anyone with the link can view'),
            value: _isPublic,
            onChanged: _isSubmitting
                ? null
                : (value) => setState(() => _isPublic = value),
          ),
          if (_error != null) _buildErrorMessage(),
        ],
      ),
    );
  }

  Widget _buildErrorMessage() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          _error!,
          key: const ValueKey('playlist_creation_error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
    );
  }
}

class _SourceChoiceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _SourceChoiceTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

/// Opens the shared create surface and performs the client-side completion
/// contract for blank creation and import-job navigation.
Future<PlaylistCreationOutcome?> showPlaylistCreationDialog(
  BuildContext context, {
  required PlaylistService playlistService,
  required PlaylistImportService playlistImportService,
  void Function(Playlist playlist)? onBlankCreated,
}) async {
  final outcome = await showDialog<PlaylistCreationOutcome>(
    context: context,
    // A scrim tap must not dismiss the modal: the outcome of a submit is
    // delivered by popping this dialog, and no client surface lists
    // playlist-import jobs, so a dismissed modal would silently drop a playlist
    // or import job the server already created. Cancel (idle only) and the
    // dialog's own PopScope cover the dismissal paths instead.
    barrierDismissible: false,
    builder: (_) => PlaylistCreationDialog(
      onSubmit: (intent) async {
        if (intent is BlankPlaylistCreationIntent) {
          final playlist = await playlistService.createPlaylist(
            name: intent.name,
            description: intent.description,
            coverUrl: intent.coverUrl,
            isPublic: intent.isPublic,
          );
          return PlaylistCreatedOutcome(playlist);
        }

        final import = intent as YouTubePlaylistCreationIntent;
        final status = await playlistImportService.createImport(
          url: import.sourceUrl,
          name: import.name,
          description: import.description,
          maxItems: import.maxItems,
        );
        return PlaylistImportedOutcome(status);
      },
    ),
  );

  if (!context.mounted || outcome == null) return outcome;
  if (outcome is PlaylistCreatedOutcome) {
    onBlankCreated?.call(outcome.playlist);
  } else if (outcome is PlaylistImportedOutcome) {
    final jobId = Uri.encodeQueryComponent(outcome.status.id);
    context.push('/playlists/import?importJobId=$jobId', extra: outcome.status);
  }
  return outcome;
}
