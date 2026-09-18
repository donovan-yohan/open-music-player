import 'package:flutter/material.dart';
import '../../models/track_analysis.dart';
import 'song_metadata_chips.dart';

/// Canonical list geometry. Playback decoration and surface commands stay outside.
/// The trailing budget protects title width; only accessibility text may wrap it.
class SongListItem extends StatelessWidget {
  const SongListItem(
      {super.key,
      required this.title,
      required this.leading,
      this.subtitle,
      this.trailing,
      this.analysis,
      this.onTap,
      this.onLongPress});
  final Widget title;
  final Widget leading;
  final Widget? subtitle;
  final Widget? trailing;
  final TrackAnalysis? analysis;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(children: [
            ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48),
                child: leading),
            const SizedBox(width: 12),
            Expanded(child: LayoutBuilder(builder: (context, constraints) {
              final enlarged = MediaQuery.textScalerOf(context).scale(1) > 1.3;
              final summary = analysis?.summary;
              final metadata = summary?.bpm?.numericValue != null ||
                  summary?.key?.textValue != null ||
                  summary?.camelot?.textValue != null;
              return Row(children: [
                Expanded(
                    child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DefaultTextStyle.merge(
                        style: ListTileTheme.of(context).titleTextStyle ??
                            theme.textTheme.bodyLarge!,
                        child: title),
                    if (subtitle != null)
                      DefaultTextStyle(
                          style: theme.textTheme.bodySmall!, child: subtitle!),
                  ],
                )),
                const SizedBox(width: 8),
                ConstrainedBox(
                  key: const ValueKey('track_tile_trailing'),
                  constraints:
                      BoxConstraints(maxWidth: constraints.maxWidth * 0.60),
                  child: enlarged
                      ? Wrap(
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (metadata)
                              SizedBox(
                                  width: constraints.maxWidth * 0.60,
                                  child: SongMetadataChips(
                                      analysis: analysis,
                                      singleLine: true,
                                      compact: true)),
                            if (trailing != null) trailing!,
                          ],
                        )
                      : Row(mainAxisSize: MainAxisSize.min, children: [
                          if (metadata) ...[
                            Flexible(
                                child: SongMetadataChips(
                                    analysis: analysis,
                                    singleLine: true,
                                    compact: true)),
                            const SizedBox(width: 6),
                          ],
                          if (trailing != null) trailing!,
                        ]),
                ),
              ]);
            })),
          ]),
        ),
      ),
    );
  }
}
