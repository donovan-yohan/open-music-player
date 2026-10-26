/// Workload completion evidence, not a renderer or physical timing budget.
class ProfileScrollLeg {
  const ProfileScrollLeg({
    required this.target,
    required this.offset,
    required this.elapsedUs,
    required this.requestedUs,
  });

  final double target, offset;
  final int elapsedUs, requestedUs;

  void requireComplete() {
    // Subpixel tolerance accommodates layout rounding, not a shorter journey.
    if (!target.isFinite ||
        !offset.isFinite ||
        (offset - target).abs() > 0.5 ||
        requestedUs <= 0 ||
        elapsedUs < requestedUs) {
      throw StateError('fixture-scroll-leg-incomplete');
    }
  }

  Map<String, Object> toJson() => {
        'target': target,
        'offset': offset,
        'elapsed_us': elapsedUs,
        'requested_us': requestedUs,
      };
}
