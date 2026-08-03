import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/mix_plan.dart';
import '../models/stem_edits.dart';
import 'timeline_waveform_painter.dart';

/// Per-clip stem gain automation editor (ADR 0006 `stemEdits` v1).
///
/// One row per channel of the active channel set, listing that channel's
/// change points as chips. This is an authoring surface only: it mutates a
/// [StemEdits] document and hands it back through [onEditsChanged]. It owns no
/// playback, transport, or current-track state (ADR 0001).
class StemAutomationSection extends StatelessWidget {
  const StemAutomationSection({
    super.key,
    required this.clip,
    required this.edits,
    required this.onEditsChanged,
    this.playheadSourceMs,
    this.beatGridMs = const <int>[],
  });

  final MixPlanClip clip;
  final StemEdits edits;
  final ValueChanged<StemEdits> onEditsChanged;

  /// Current playhead in absolute source ms, used to prefill a new change
  /// point. Falls back to the clip's source start.
  final int? playheadSourceMs;

  /// Optional beat grid in absolute source ms. When empty the dialog hides its
  /// snap-to-beat toggle.
  final List<int> beatGridMs;

  int get _defaultAtMs =>
      (playheadSourceMs ?? clip.sourceStartMs)
          .clamp(clip.sourceStartMs, clip.sourceEndMs)
          .toInt();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('stem_automation_section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Stem edits', style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                stemCutHonestyCopy,
                key: const ValueKey('stem_automation_honesty_copy'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        for (final descriptor in edits.channelSet.channels)
          _channelRow(context, descriptor),
      ],
    );
  }

  Widget _channelRow(BuildContext context, StemChannelDescriptor descriptor) {
    final theme = Theme.of(context);
    final channelEvents = edits.eventsFor(descriptor.id);
    final color = stemChannelColor(descriptor.id);

    return Padding(
      key: ValueKey('stem_channel_row_${descriptor.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Tooltip(
                  message: descriptor.honestyCopy,
                  child: Text(
                    descriptor.label,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
              ),
              IconButton(
                key: ValueKey('stem_add_change_point_${descriptor.id}'),
                icon: const Icon(Icons.add),
                iconSize: 18,
                tooltip: 'Add ${descriptor.label} change point',
                onPressed: () => _openDialog(context, descriptor, null),
              ),
            ],
          ),
          if (channelEvents.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 14, bottom: 4),
              child: Text(
                'No change points',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.disabledColor,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(left: 14, bottom: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final event in channelEvents)
                    InputChip(
                      key: ValueKey(
                        'stem_change_point_${descriptor.id}_${event.atMs}',
                      ),
                      label: Text(stemChangePointLabel(event)),
                      onPressed: () =>
                          _openDialog(context, descriptor, event),
                      deleteIcon: Icon(
                        Icons.close,
                        key: ValueKey(
                          'stem_remove_change_point_'
                          '${descriptor.id}_${event.atMs}',
                        ),
                        size: 16,
                      ),
                      onDeleted: () => onEditsChanged(
                        edits.withoutEvent(
                          channel: descriptor.id,
                          atMs: event.atMs,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _openDialog(
    BuildContext context,
    StemChannelDescriptor descriptor,
    StemGainEvent? existing,
  ) async {
    final result = await showDialog<StemGainEvent>(
      context: context,
      builder: (dialogContext) => StemChangePointDialog(
        descriptor: descriptor,
        initialAtMs: existing?.atMs ?? _defaultAtMs,
        initialGain: existing?.gain ?? 0.0,
        minMs: clip.sourceStartMs,
        maxMs: clip.sourceEndMs,
        beatGridMs: beatGridMs,
      ),
    );
    if (result == null) return;

    var next = edits;
    if (existing != null && existing.atMs != result.atMs) {
      next = next.withoutEvent(
        channel: descriptor.id,
        atMs: existing.atMs,
      );
    }
    onEditsChanged(next.withEvent(result));
  }
}

/// Chip copy for one change point, e.g. `12.0s -> 0%`.
String stemChangePointLabel(StemGainEvent event) {
  final seconds = (event.atMs / 1000).toStringAsFixed(1);
  final percent = (event.gain * 100).round();
  return '${seconds}s -> $percent%';
}

/// Add/edit dialog for a single stem gain change point.
class StemChangePointDialog extends StatefulWidget {
  const StemChangePointDialog({
    super.key,
    required this.descriptor,
    required this.initialAtMs,
    required this.initialGain,
    required this.minMs,
    required this.maxMs,
    this.beatGridMs = const <int>[],
  });

  final StemChannelDescriptor descriptor;
  final int initialAtMs;
  final double initialGain;
  final int minMs;
  final int maxMs;
  final List<int> beatGridMs;

  @override
  State<StemChangePointDialog> createState() => _StemChangePointDialogState();
}

class _StemChangePointDialogState extends State<StemChangePointDialog> {
  late final TextEditingController _atMsController;
  late double _gain;
  bool _snapToBeat = false;

  bool get _hasBeatGrid => widget.beatGridMs.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _atMsController =
        TextEditingController(text: widget.initialAtMs.toString());
    _gain = widget.initialGain.clamp(0.0, 1.0).toDouble();
  }

  @override
  void dispose() {
    _atMsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const ValueKey('stem_change_point_dialog'),
      title: Text(widget.descriptor.label),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.descriptor.honestyCopy,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('stem_change_point_time_field'),
              controller: _atMsController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Source position (ms)',
                helperText: 'Milliseconds are authoritative',
              ),
            ),
            const SizedBox(height: 12),
            Text('Gain ${(_gain * 100).round()}%',
                style: theme.textTheme.labelLarge),
            Slider(
              key: const ValueKey('stem_change_point_gain_slider'),
              value: _gain,
              divisions: 100,
              label: '${(_gain * 100).round()}%',
              onChanged: (value) => setState(() => _gain = value),
            ),
            Row(
              children: [
                OutlinedButton(
                  key: const ValueKey('stem_change_point_cut'),
                  onPressed: () => setState(() => _gain = 0),
                  child: const Text(stemCutActionLabel),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  key: const ValueKey('stem_change_point_full'),
                  onPressed: () => setState(() => _gain = 1),
                  child: const Text(stemFullActionLabel),
                ),
              ],
            ),
            if (_hasBeatGrid)
              SwitchListTile(
                key: const ValueKey('stem_change_point_snap'),
                contentPadding: EdgeInsets.zero,
                title: const Text('Snap to beat'),
                subtitle: const Text('Stores the snapped millisecond'),
                value: _snapToBeat,
                onChanged: (value) => setState(() => _snapToBeat = value),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('stem_change_point_cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('stem_change_point_save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _save() {
    final parsed =
        int.tryParse(_atMsController.text.trim()) ?? widget.initialAtMs;
    var atMs = parsed.clamp(widget.minMs, widget.maxMs).toInt();
    int? beatIndex;
    if (_snapToBeat && _hasBeatGrid) {
      final index = nearestBeatIndex(widget.beatGridMs, atMs);
      if (index != null) {
        beatIndex = index;
        atMs = widget.beatGridMs[index];
      }
    }
    Navigator.of(context).pop(
      StemGainEvent(
        channel: widget.descriptor.id,
        atMs: atMs,
        gain: _gain,
        beatIndex: beatIndex,
      ),
    );
  }
}
