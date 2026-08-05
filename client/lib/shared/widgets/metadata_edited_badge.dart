import 'package:flutter/material.dart';

/// Subtle pill marking a row whose title/artist/album the current user has
/// edited by hand.
///
/// Deliberately worded "Edited" rather than anything verification-shaped: the
/// unverified affordance already owns "Metadata not verified", and the two
/// facts are independent.
class MetadataEditedBadge extends StatelessWidget {
  static const String semanticsLabel = 'Metadata edited by you';

  final String label;

  const MetadataEditedBadge({super.key, this.label = 'Edited'});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.secondary;
    return Tooltip(
      message: semanticsLabel,
      child: Semantics(
        label: semanticsLabel,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.7)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.edit_outlined, size: 11, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
