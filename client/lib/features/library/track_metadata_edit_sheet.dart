import 'package:flutter/material.dart';

import '../../core/services/api_client.dart';
import '../../core/services/library_service.dart';

const double trackMetadataEditDesktopBreakpoint = 960;

bool usesDesktopTrackMetadataEditor(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= trackMetadataEditDesktopBreakpoint;

/// Which write the editor performed before it closed.
enum TrackMetadataEditAction { saved, reset }

/// Outcome handed back to the surface that opened the editor.
///
/// [title], [artist] and [album] are the override values that were submitted,
/// so they are only the effective display values while the override is set.
/// After a reset the effective values come from the original metadata, which
/// the client never sees — surfaces must reload rather than patch locally.
class TrackMetadataEditResult {
  final TrackMetadataEditAction action;
  final bool hasMetadataOverride;
  final String? title;
  final String? artist;
  final String? album;

  const TrackMetadataEditResult({
    required this.action,
    required this.hasMetadataOverride,
    this.title,
    this.artist,
    this.album,
  });
}

/// Adaptive metadata editor. Phone layouts get a bottom sheet, desktop-width
/// layouts a bounded dialog, matching the analysis-correction editor.
Future<TrackMetadataEditResult?> showTrackMetadataEditSheet({
  required BuildContext context,
  required int trackId,
  required String title,
  String? artist,
  String? album,
  bool hasMetadataOverride = false,
  required LibraryService libraryService,
}) {
  final editor = TrackMetadataEditSheet(
    trackId: trackId,
    initialTitle: title,
    initialArtist: artist,
    initialAlbum: album,
    hasMetadataOverride: hasMetadataOverride,
    libraryService: libraryService,
  );
  if (usesDesktopTrackMetadataEditor(context)) {
    return showDialog<TrackMetadataEditResult>(
      context: context,
      builder: (_) => Dialog(
        key: const ValueKey('track_metadata_desktop_dialog'),
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 420, maxWidth: 560),
          child: editor,
        ),
      ),
    );
  }
  return showModalBottomSheet<TrackMetadataEditResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => editor,
  );
}

/// Edits the caller's per-user display metadata for one library track.
///
/// The backend contract is a full replacement: every field is written on save,
/// a blank field clears that field's override, and "Reset to original" removes
/// the override row outright.
class TrackMetadataEditSheet extends StatefulWidget {
  final int trackId;
  final String initialTitle;
  final String? initialArtist;
  final String? initialAlbum;
  final bool hasMetadataOverride;
  final LibraryService libraryService;

  const TrackMetadataEditSheet({
    super.key,
    required this.trackId,
    required this.initialTitle,
    this.initialArtist,
    this.initialAlbum,
    this.hasMetadataOverride = false,
    required this.libraryService,
  });

  @override
  State<TrackMetadataEditSheet> createState() => _TrackMetadataEditSheetState();
}

class _TrackMetadataEditSheetState extends State<TrackMetadataEditSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _titleController;
  late final TextEditingController _artistController;
  late final TextEditingController _albumController;
  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle);
    _artistController = TextEditingController(text: widget.initialArtist ?? '');
    _albumController = TextEditingController(text: widget.initialAlbum ?? '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    super.dispose();
  }

  String? _fieldValue(TextEditingController controller) {
    final trimmed = controller.text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _save() async {
    if (_isSaving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final title = _titleController.text.trim();
    final artist = _fieldValue(_artistController);
    final album = _fieldValue(_albumController);

    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      final result = await widget.libraryService.updateTrackMetadataOverride(
        trackId: widget.trackId,
        title: title,
        artist: artist,
        album: album,
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        TrackMetadataEditResult(
          action: TrackMetadataEditAction.saved,
          hasMetadataOverride: result.hasMetadataOverride,
          title: title,
          artist: artist,
          album: album,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _error = _failureMessage(error);
      });
    }
  }

  Future<void> _reset() async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
      _error = null;
    });
    try {
      await widget.libraryService.resetTrackMetadataOverride(widget.trackId);
      if (!mounted) return;
      Navigator.of(context).pop(
        const TrackMetadataEditResult(
          action: TrackMetadataEditAction.reset,
          hasMetadataOverride: false,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _error = _failureMessage(error);
      });
    }
  }

  String _failureMessage(Object error) {
    if (error is ApiException) return error.message;
    return 'Could not update this track. Your edits are still here.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_isSaving,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Edit metadata', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 4),
                  Text(
                    'Only you see these names. The original metadata is kept '
                    'and can be restored at any time.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    key: const ValueKey('track_metadata_title_field'),
                    controller: _titleController,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      hintText: 'Track title',
                    ),
                    textInputAction: TextInputAction.next,
                    autofocus: true,
                    enabled: !_isSaving,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter a title';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('track_metadata_artist_field'),
                    controller: _artistController,
                    decoration: const InputDecoration(
                      labelText: 'Artist (optional)',
                      hintText: 'Artist name',
                    ),
                    textInputAction: TextInputAction.next,
                    enabled: !_isSaving,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const ValueKey('track_metadata_album_field'),
                    controller: _albumController,
                    decoration: const InputDecoration(
                      labelText: 'Album (optional)',
                      hintText: 'Album name',
                    ),
                    enabled: !_isSaving,
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      _error!,
                      key: const ValueKey('track_metadata_error'),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      if (widget.hasMetadataOverride)
                        TextButton(
                          key: const ValueKey('track_metadata_reset'),
                          onPressed: _isSaving ? null : _reset,
                          child: const Text('Reset to original'),
                        ),
                      const Spacer(),
                      TextButton(
                        key: const ValueKey('track_metadata_cancel'),
                        onPressed:
                            _isSaving ? null : () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('track_metadata_save'),
                        onPressed: _isSaving ? null : _save,
                        child: _isSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
