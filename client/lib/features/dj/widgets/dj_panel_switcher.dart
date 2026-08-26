import 'package:flutter/material.dart';

import '../../../app/theme.dart';

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
      // The switcher lives in a fixed 40dp band inside the control field, so
      // it must not claim a 48dp padded tap target it would only have clipped
      // anyway. Labels clip rather than wrap: STEMS used to break to STEM/S and
      // grow the row (#411).
      style: SegmentedButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.space1),
      ),
      segments: [
        for (final panel in panels)
          ButtonSegment(
            value: panel,
            label: Text(
              panel.name.toUpperCase(),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
            ),
          ),
      ],
      selected: {selected},
      onSelectionChanged: (value) => onSelected(value.single),
    );
  }
}
