import 'package:flutter/material.dart';

import '../../../app/theme.dart';

enum DjPanel { cues, loop, stems }

class DjPanelSwitcher extends StatelessWidget {
  const DjPanelSwitcher({
    super.key,
    required this.selected,
    required this.onSelected,
    this.compact = false,
  });

  final DjPanel selected;
  final ValueChanged<DjPanel> onSelected;

  /// Set by `DjLayout` when the control field is below the reference budget and
  /// the switcher band steps down to [kDjPanelSwitcherCompactHeight]. Only then
  /// does the switcher give up its padded 48dp tap target.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    // STEMS is always reachable. It used to be hidden until stems existed,
    // which made the opt-in unreachable: the panel behind this segment is now
    // where a track gets separated in the first place.
    const panels = <DjPanel>[DjPanel.cues, DjPanel.loop, DjPanel.stems];
    return SegmentedButton<DjPanel>(
      key: const ValueKey('dj_panel_switcher'),
      showSelectedIcon: false,
      // At and above the reference budget the switcher keeps Material's padded
      // 48dp tap target, which is what docs/dj-deck-spec.md requires. Only in
      // the compact band does it shrink-wrap, and it would clip a padded target
      // there anyway. Labels clip rather than wrap: STEMS used to break to
      // STEM/S and grow the row (#411).
      style: SegmentedButton.styleFrom(
        tapTargetSize: compact
            ? MaterialTapTargetSize.shrinkWrap
            : MaterialTapTargetSize.padded,
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
