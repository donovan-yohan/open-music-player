import 'package:flutter/material.dart';

/// Badge widget that indicates track verification status.
/// Shows a warning icon for unverified tracks with a tooltip.
class VerificationBadge extends StatelessWidget {
  final bool isVerified;
  final double size;

  const VerificationBadge({
    super.key,
    required this.isVerified,
    this.size = 16,
  });

  @override
  Widget build(BuildContext context) {
    if (isVerified) {
      return const SizedBox.shrink();
    }

    return Tooltip(
      message: 'Metadata not verified',
      child: Icon(
        Icons.info_outline,
        size: size,
        color: Colors.orange[400],
      ),
    );
  }
}
