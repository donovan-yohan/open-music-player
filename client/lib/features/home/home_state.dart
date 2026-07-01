import '../../shared/models/models.dart';

/// The data for the three Home sections, decoupled from any widget so the
/// empty/loaded decision can be unit-tested without pumping a widget tree.
class HomeSections {
  const HomeSections({
    this.recentlyPlayed = const [],
    this.topTracks = const [],
    this.playlists = const [],
  });

  final List<Track> recentlyPlayed;
  final List<Track> topTracks;
  final List<Playlist> playlists;

  /// True when every section came back empty. Drives the single "get started"
  /// empty state rather than three individually-empty sections.
  bool get isEmpty =>
      recentlyPlayed.isEmpty && topTracks.isEmpty && playlists.isEmpty;
}

/// Which single presentation the Home screen should render. Deliberately
/// mutually exclusive: [empty] is NOT a spinner and NOT an error — it is the
/// terminal "nothing to show yet" state.
enum HomeView { loading, error, empty, content }

/// Pure view-model for the Home screen. The named constructors encode the one
/// rule worth testing: loaded-but-everything-empty collapses to a single
/// [HomeView.empty], never a spinner or an error.
class HomeState {
  const HomeState._(
    this.view, {
    this.sections = const HomeSections(),
    this.errorMessage,
  });

  final HomeView view;
  final HomeSections sections;
  final String? errorMessage;

  const HomeState.loading() : this._(HomeView.loading);

  factory HomeState.error(String message) =>
      HomeState._(HomeView.error, errorMessage: message);

  /// Resolves loaded data into either [HomeView.empty] (all sections empty) or
  /// [HomeView.content].
  factory HomeState.loaded(HomeSections sections) => HomeState._(
        sections.isEmpty ? HomeView.empty : HomeView.content,
        sections: sections,
      );
}
