import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../core/services/library_service.dart';
import 'local_browse_screens.dart';

/// Route patterns for the library-backed artist/album pages.
///
/// These are the single definition used by both the app router and the
/// navigation tests, so the push -> match -> screen round trip is exercised
/// exactly as shipped.
const String localArtistRoutePattern = '/library/artist/:name';
const String localAlbumRoutePattern = '/library/album/:name';

/// Placeholder shown for a track with no artist. It addresses no real artist,
/// so it is never a navigable name.
const String unknownArtistLabel = 'Unknown Artist';

/// Builds the location for the local artist page.
///
/// Artist/album names are free text out of `tracks.artist` / `tracks.album`, so
/// they are percent-encoded into a single path segment: `AC/DC` must not split
/// the path and `Sigur Rós` must not land raw in the location. go_router
/// already decodes path parameters once on the way back out, so the route
/// builders below must not decode a second time — doing so throws on any name
/// containing a space or a literal `%`.
String localArtistRoute(String artist) =>
    '/library/artist/${Uri.encodeComponent(artist)}';

/// Builds the location for the local album page. See [localArtistRoute].
String localAlbumRoute(String album) =>
    '/library/album/${Uri.encodeComponent(album)}';

/// Whether [name] identifies something the local pages can filter on.
///
/// Blank names and the [unknownArtistLabel] placeholder would filter the
/// library down to nothing, so they are not offered as tap targets.
bool canBrowseLocalName(String? name) {
  final value = name?.trim();
  return value != null && value.isNotEmpty && value != unknownArtistLabel;
}

/// Pushes the local artist page for [artist]. No-op for a name that
/// [canBrowseLocalName] rejects, so callers can wire this unconditionally.
void openLocalArtist(BuildContext context, String? artist) {
  if (!canBrowseLocalName(artist)) return;
  context.push(localArtistRoute(artist!.trim()));
}

/// Pushes the local album page for [album]. See [openLocalArtist].
void openLocalAlbum(BuildContext context, String? album) {
  if (!canBrowseLocalName(album)) return;
  context.push(localAlbumRoute(album!.trim()));
}

/// The artist/album routes, mounted by the app router inside the shell.
///
/// [libraryService] is injectable so navigation tests can render the
/// destination screens without HTTP; production passes nothing and each screen
/// builds its own service.
List<GoRoute> localBrowseRoutes({LibraryService? libraryService}) => [
      GoRoute(
        path: localArtistRoutePattern,
        pageBuilder: (context, state) => NoTransitionPage(
          child: LocalArtistScreen(
            artist: state.pathParameters['name']!,
            libraryService: libraryService,
          ),
        ),
      ),
      GoRoute(
        path: localAlbumRoutePattern,
        pageBuilder: (context, state) => NoTransitionPage(
          child: LocalAlbumScreen(
            album: state.pathParameters['name']!,
            libraryService: libraryService,
          ),
        ),
      ),
    ];
