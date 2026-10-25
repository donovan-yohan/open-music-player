import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/api/api_client.dart';
import '../../../core/services/mix_exchange_service.dart';
import '../../../models/mix_plan.dart';

/// Exchanges saved performance metadata without granting access to source audio.
class MixExchangeMenu extends StatelessWidget {
  const MixExchangeMenu({
    super.key,
    required this.service,
    required this.onImported,
    this.planId,
    this.enabled = true,
  });
  final MixExchangeService service;
  final ValueChanged<MixPlan> onImported;
  final String? planId;
  final bool enabled;

  @override
  Widget build(BuildContext context) => PopupMenuButton<bool>(
        tooltip: 'Mix import and export',
        enabled: enabled,
        icon: const Icon(Icons.import_export),
        onSelected: (export) async {
          final imported = await showDialog<MixPlan>(
              context: context,
              builder: (_) => _MixExchangeDialog(
                  service: service, exportPlanId: export ? planId : null));
          if (context.mounted && imported != null) onImported(imported);
        },
        itemBuilder: (_) => [
          if (planId != null)
            const PopupMenuItem(value: true, child: Text('Export mix')),
          const PopupMenuItem(value: false, child: Text('Import mix')),
        ],
      );
}

class _MixExchangeDialog extends StatefulWidget {
  const _MixExchangeDialog({required this.service, this.exportPlanId});
  final MixExchangeService service;
  final String? exportPlanId;
  @override
  State<_MixExchangeDialog> createState() => _MixExchangeDialogState();
}

class _MixExchangeDialogState extends State<_MixExchangeDialog> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;
  bool get _export => widget.exportPlanId != null;

  @override
  void initState() {
    super.initState();
    if (_export) _loadExport();
  }

  Future<void> _loadExport() async {
    setState(() => _busy = true);
    try {
      final text = await widget.service.exportMix(widget.exportPlanId!);
      if (mounted) _text.text = text;
    } catch (error) {
      if (mounted) _error = _message(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final plan = await widget.service.importMix(_text.text);
      if (mounted) Navigator.pop(context, plan);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object error) => switch (error) {
        ApiException(errorCode: 'MISSING_SOURCES') =>
          'Add the matching audio to your library before importing.',
        ApiException(errorCode: 'AMBIGUOUS_SOURCE') =>
          'More than one library track matches a required source.',
        ApiException(:final message) => message,
        FormatException(:final message) => message,
        _ => 'Could not complete exchange. Check saved mixes before retrying.',
      };

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_busy,
        child: AlertDialog(
          title: Text(_export ? 'Export mix' : 'Import mix'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text(
                    'Performance metadata only. Matching audio is required in the recipient’s library.'),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('mix-import-json'),
                  controller: _text,
                  readOnly: _export || _busy,
                  minLines: 5,
                  maxLines: 10,
                  maxLength: 262144,
                  decoration: const InputDecoration(
                      labelText: 'Mix JSON', counterText: ''),
                ),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(_error!)),
              ]),
            ),
          ),
          actions: [
            TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('Close')),
            if (_export)
              FilledButton(
                  onPressed: _busy || _error != null
                      ? null
                      : () async {
                          await Clipboard.setData(
                              ClipboardData(text: _text.text));
                          if (context.mounted) Navigator.pop(context);
                        },
                  child: const Text('Copy'))
            else
              FilledButton(
                  onPressed: _busy ? null : _import,
                  child: const Text('Import')),
          ],
        ),
      );
}
