import 'package:flutter/material.dart';

/// Values captured by [PlaylistEditDialog] on save.
class PlaylistEditResult {
  final String name;
  final String? description;
  final String? coverUrl;
  final bool isPublic;

  const PlaylistEditResult({
    required this.name,
    this.description,
    this.coverUrl,
    required this.isPublic,
  });
}

class PlaylistEditDialog extends StatefulWidget {
  final String? initialName;
  final String? initialDescription;
  final String? initialCoverUrl;
  final bool initialIsPublic;
  final Future<void> Function(PlaylistEditResult result) onSave;

  const PlaylistEditDialog({
    super.key,
    this.initialName,
    this.initialDescription,
    this.initialCoverUrl,
    this.initialIsPublic = false,
    required this.onSave,
  });

  @override
  State<PlaylistEditDialog> createState() => _PlaylistEditDialogState();
}

class _PlaylistEditDialogState extends State<PlaylistEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _coverUrlController;
  late bool _isPublic;
  bool _isSaving = false;

  bool get _isEditing => widget.initialName != null;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName ?? '');
    _descriptionController =
        TextEditingController(text: widget.initialDescription ?? '');
    _coverUrlController =
        TextEditingController(text: widget.initialCoverUrl ?? '');
    _isPublic = widget.initialIsPublic;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _coverUrlController.dispose();
    super.dispose();
  }

  Future<void> _onSave() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      final description = _descriptionController.text.trim();
      final coverUrl = _coverUrlController.text.trim();
      await widget.onSave(
        PlaylistEditResult(
          name: _nameController.text.trim(),
          description: description.isNotEmpty ? description : null,
          coverUrl: coverUrl.isNotEmpty ? coverUrl : null,
          isPublic: _isPublic,
        ),
      );
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEditing ? 'Edit Playlist' : 'Create Playlist'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'Enter playlist name',
                ),
                autofocus: true,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                  hintText: 'Enter description',
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _coverUrlController,
                decoration: const InputDecoration(
                  labelText: 'Cover image URL (optional)',
                  hintText: 'https://…',
                ),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Public'),
                subtitle: const Text('Anyone with the link can view'),
                value: _isPublic,
                onChanged: _isSaving
                    ? null
                    : (value) => setState(() => _isPublic = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _onSave,
          child: _isSaving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isEditing ? 'Save' : 'Create'),
        ),
      ],
    );
  }
}
