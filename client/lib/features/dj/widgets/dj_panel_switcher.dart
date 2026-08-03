import 'package:flutter/material.dart';

enum DjPanel { cues, loop, stems }

class DjPanelSwitcher extends StatelessWidget {
  const DjPanelSwitcher({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.stemsAvailable,
  });

  final DjPanel selected;
  final ValueChanged<DjPanel> onSelected;
  final bool stemsAvailable;

  @override
  Widget build(BuildContext context) {
    final panels = <DjPanel>[DjPanel.cues, DjPanel.loop];
    if (stemsAvailable) panels.add(DjPanel.stems);
    return SegmentedButton<DjPanel>(
      key: const ValueKey('dj_panel_switcher'),
      showSelectedIcon: false,
      segments: [
        for (final panel in panels)
          ButtonSegment(value: panel, label: Text(panel.name.toUpperCase())),
      ],
      selected: {selected},
      onSelectionChanged: (value) => onSelected(value.single),
    );
  }
}
