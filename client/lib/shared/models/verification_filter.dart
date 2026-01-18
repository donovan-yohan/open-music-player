/// Filter options for track verification status in the library.
enum VerificationFilter {
  /// Show all tracks regardless of verification status.
  all,

  /// Show only tracks with verified MusicBrainz metadata.
  verifiedOnly,

  /// Show only tracks without verified MusicBrainz metadata.
  unverifiedOnly,
}
