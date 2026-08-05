import 'package:flutter/material.dart';

enum DjPanel { cues, loop, stems }

class DjPanelSwitcher extends StatelessWidget {
  const DjPanelSwitcher({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final DjPanel selected;
  final ValueChanged<DjPanel> onSelected;

  @override
  Widget build(BuildContext context) {
    // STEMS is always reachable. It used to be hidden until stems existed,
    // which made the opt-in unreachable: the panel behind this segment is now
    // where a track gets separated in the first place.
    const panels = <DjPanel>[DjPanel.cues, DjPanel.loop, DjPanel.stems];
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
