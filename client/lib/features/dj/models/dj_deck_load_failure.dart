/// Why a deck refused a seed.
enum DjDeckLoadFailureKind {
  /// The resolver answered with a remote/signed source for a library track.
  unavailableOffline,

  /// The picker fallback supplied a non-`file:` URI.
  pickerNotLocal,

  /// Resolution or voice load failed outright.
  sourceUnavailable,
}

/// Why a deck refused a seed. The local/cache-only policy
/// (docs/dj-deck-spec.md:117) is unchanged; only the delivery is: a refusal is
/// deck state the lane can render instead of an unhandled async error (#409).
class DjDeckLoadFailure {
  const DjDeckLoadFailure({
    required this.kind,
    this.trackRef,
    this.title,
    this.detail,
  });

  final DjDeckLoadFailureKind kind;
  final String? trackRef;
  final String? title;

  /// Diagnostic only — never rendered.
  final String? detail;
}
