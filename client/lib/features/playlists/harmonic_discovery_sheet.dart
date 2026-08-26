import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../models/nearby_tracks.dart';
import '../../shared/models/track.dart';
import 'mixed_playlist_view.dart';

/// Runs one `/tracks/nearby` query. Injected so widget tests drive the sheet
/// without transport, and so the sheet never has to know about [ApiClient].
typedef HarmonicSearch = Future<NearbyTracksResult> Function({
  required double bpm,
  required String camelot,
  required double tolerance,
  required bool orderByHistory,
});

/// The tempo/key seed taken from a playlist's own tracks, plus the id of the
/// track it came from so the caller can exclude that anchor from results.
typedef HarmonicSeed = ({int? trackId, double? bpm, String? camelot});

/// Highest tempo the sheet will ask the server about. Above this the input is
/// far more likely to be a typo than a real track.
const double _maxSeedBpm = 300;

/// Widest ± window offered. The server treats tolerance as absolute BPM, so a
/// large value degenerates into "every analyzed track in my library".
const double _maxTolerance = 50;

/// "What else in my library plays well next to this?" — a modal sheet over
/// playlist detail that queries `GET /tracks/nearby` and offers the two
/// actions that already exist elsewhere in the app (queue, add to playlist).
///
/// This is a sheet rather than a route on purpose: unlike the DJ deck it
/// allocates no audio voices and holds no URL-reachable state, so there is
/// nothing a route redirect could protect that hiding the entry point does
/// not. The DJ-mode gate therefore lives on the entry point (see
/// `playlist_detail_screen.dart`).
class HarmonicDiscoverySheet extends StatefulWidget {
  const HarmonicDiscoverySheet({
    super.key,
    required this.search,
    required this.playlistName,
    required this.onAddToQueue,
    required this.onAddToPlaylist,
    this.seedBpm,
    this.seedCamelot,
    this.excludeTrackId,
  });

  final HarmonicSearch search;

  /// Named in the header so it is obvious where "Add to this playlist" lands.
  final String playlistName;

  final Future<void> Function(NearbyTrack match) onAddToQueue;
  final Future<void> Function(NearbyTrack match) onAddToPlaylist;

  /// When both seeds are present the fields are pre-filled and one search runs
  /// automatically, so opening from an analyzed anchor is a single tap.
  final double? seedBpm;
  final String? seedCamelot;

  /// The anchor track, filtered out of the rendered results: it is by
  /// definition its own best match. The endpoint has no exclude parameter and
  /// this slice must not change the backend, so the filter lives here.
  final int? excludeTrackId;

  static Future<void> show(
    BuildContext context, {
    required HarmonicSearch search,
    required String playlistName,
    required Future<void> Function(NearbyTrack match) onAddToQueue,
    required Future<void> Function(NearbyTrack match) onAddToPlaylist,
    double? seedBpm,
    String? seedCamelot,
    int? excludeTrackId,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => HarmonicDiscoverySheet(
        search: search,
        playlistName: playlistName,
        onAddToQueue: onAddToQueue,
        onAddToPlaylist: onAddToPlaylist,
        seedBpm: seedBpm,
        seedCamelot: seedCamelot,
        excludeTrackId: excludeTrackId,
      ),
    );
  }

  @override
  State<HarmonicDiscoverySheet> createState() => _HarmonicDiscoverySheetState();
}

class _HarmonicDiscoverySheetState extends State<HarmonicDiscoverySheet> {
  late final TextEditingController _bpmController;
  late final TextEditingController _camelotController;
  late final TextEditingController _toleranceController;

  /// Default on: a listener with no play history scores NULL and sorts last,
  /// so the server falls back to the identical deterministic harmonic order.
  /// Defaulting on therefore cannot produce a worse ordering, and it is what
  /// makes history-affinity ranking reachable at all.
  bool _orderByHistory = true;

  bool _loading = false;
  NearbyTracksResult? _result;
  String? _errorMessage;

  /// Monotonic request id. A late-returning response from a superseded query
  /// must never overwrite newer state.
  int _requestId = 0;

  @override
  void initState() {
    super.initState();
    final seedBpm = widget.seedBpm;
    final seedCamelot = MixMetadataBadges.normalizeCamelot(widget.seedCamelot);
    _bpmController = TextEditingController(
      text: seedBpm == null ? '' : seedBpm.round().toString(),
    );
    _camelotController = TextEditingController(text: seedCamelot ?? '');
    _toleranceController = TextEditingController(text: '5');

    if (seedBpm != null && seedCamelot != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_search());
      });
    }
  }

  @override
  void dispose() {
    _bpmController.dispose();
    _camelotController.dispose();
    _toleranceController.dispose();
    super.dispose();
  }

  double? get _parsedBpm {
    final value = double.tryParse(_bpmController.text.trim());
    if (value == null || !value.isFinite) return null;
    return value > 0 && value <= _maxSeedBpm ? value : null;
  }

  double? get _parsedTolerance {
    final value = double.tryParse(_toleranceController.text.trim());
    if (value == null || !value.isFinite) return null;
    return value >= 0 && value <= _maxTolerance ? value : null;
  }

  String? get _parsedCamelot =>
      MixMetadataBadges.normalizeCamelot(_camelotController.text);

  bool get _inputsValid =>
      _parsedBpm != null && _parsedCamelot != null && _parsedTolerance != null;

  /// Results minus the anchor track, without mutating the parsed response.
  List<NearbyTrack> get _visibleTracks {
    final tracks = _result?.tracks ?? const <NearbyTrack>[];
    final excluded = widget.excludeTrackId;
    if (excluded == null) return tracks;
    return tracks.where((track) => track.id != excluded).toList();
  }

  Future<void> _search() async {
    final bpm = _parsedBpm;
    final camelot = _parsedCamelot;
    final tolerance = _parsedTolerance;
    if (bpm == null || camelot == null || tolerance == null) return;

    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final result = await widget.search(
        bpm: bpm,
        camelot: camelot,
        tolerance: tolerance,
        orderByHistory: _orderByHistory,
      );
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _result = result;
        _errorMessage = null;
      });
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _loading = false;
        _result = null;
        _errorMessage = _messageFor(error);
      });
    }
  }

  /// A disabled server route is an honest, distinct state: nothing the user
  /// types will make it work, so it must not read as a transient failure.
  String _messageFor(Object error) {
    if (error is ApiException && error.statusCode == 404) {
      return 'Harmonic matching is turned off on this server.';
    }
    return 'Could not load harmonic matches. Try again.';
  }

  Future<void> _showResultActions(NearbyTrack match) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    match.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    match.artist ?? 'Unknown artist',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(sheetContext)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                  ),
                ],
              ),
            ),
            ListTile(
              key: const ValueKey('harmonic_action_add_to_queue'),
              leading: const Icon(Icons.queue_music),
              title: const Text('Add to queue'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await widget.onAddToQueue(match);
              },
            ),
            ListTile(
              key: const ValueKey('harmonic_action_add_to_playlist'),
              leading: const Icon(Icons.playlist_add),
              title: const Text('Add to this playlist'),
              onTap: () async {
                Navigator.of(sheetContext).pop();
                await widget.onAddToPlaylist(match);
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Harmonic matches', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Tracks in your library that mix well from this tempo and key. '
              'Add one to your queue or to "${widget.playlistName}".',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            _buildInputs(theme),
            const SizedBox(height: 12),
            Flexible(child: _buildBody(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildInputs(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('harmonic_bpm_field'),
                controller: _bpmController,
                enabled: !_loading,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'BPM',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const ValueKey('harmonic_camelot_field'),
                controller: _camelotController,
                enabled: !_loading,
                textCapitalization: TextCapitalization.characters,
                inputFormatters: const [_UpperCaseFormatter()],
                decoration: const InputDecoration(
                  labelText: 'Camelot key',
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('harmonic_tolerance_field'),
          controller: _toleranceController,
          enabled: !_loading,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Tempo range (± BPM)',
            isDense: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        SwitchListTile(
          key: const ValueKey('harmonic_history_order_toggle'),
          value: _orderByHistory,
          onChanged: _loading
              ? null
              : (value) => setState(() => _orderByHistory = value),
          title: const Text('Order by my listening history'),
          contentPadding: EdgeInsets.zero,
        ),
        if (!_inputsValid)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Enter a tempo in BPM and a Camelot key like 8A.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        FilledButton(
          key: const ValueKey('harmonic_search_button'),
          onPressed: _loading || !_inputsValid ? null : _search,
          style: FilledButton.styleFrom(backgroundColor: AppTheme.orange),
          child: const Text('Find matches'),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Padding(
        key: ValueKey('harmonic_discovery_loading'),
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final errorMessage = _errorMessage;
    if (errorMessage != null) {
      return Padding(
        key: const ValueKey('harmonic_discovery_error'),
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(errorMessage, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              key: const ValueKey('harmonic_discovery_retry'),
              onPressed: _search,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final result = _result;
    if (result == null) {
      return const SizedBox(
        key: ValueKey('harmonic_discovery_idle'),
        height: 0,
      );
    }

    final matches = _visibleTracks;
    if (matches.isEmpty) {
      return Padding(
        key: const ValueKey('harmonic_discovery_empty'),
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No harmonic matches in your library yet.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              'Try a wider tempo range, or analyze more tracks.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (result.orderedByHistory)
          Padding(
            key: const ValueKey('harmonic_discovery_history_caption'),
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'Ordered by your listening history',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        Flexible(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: matches.length,
            itemBuilder: (context, index) {
              final match = matches[index];
              return ListTile(
                key: ValueKey('harmonic_result_${match.id}'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  match.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  match.artist ?? 'Unknown artist',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: MixMetadataBadges(
                  bpm: match.bpm,
                  camelot: match.camelot,
                ),
                onTap: () => unawaited(_showResultActions(match)),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Camelot labels are canonically upper-case; typing `8a` should not read as a
/// different key from `8A`.
class _UpperCaseFormatter extends TextInputFormatter {
  const _UpperCaseFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return newValue.copyWith(text: newValue.text.toUpperCase());
  }
}

/// Picks the tempo/key seed for the discovery sheet from a playlist's tracks.
///
/// Prefers the first track that yields both a usable tempo and an on-wheel
/// Camelot key, because that is the only case where the sheet can search
/// immediately. Failing that it falls back to the first usable tempo alone, so
/// the user only has to supply the key. With neither, the sheet opens idle.
///
/// Deliberately not `@visibleForTesting`: `PlaylistDetailScreen` consumes this
/// in production, and the annotation would make that a lint violation (the
/// same trap that keeps `djModeEnabledForRouting` un-reusable).
HarmonicSeed harmonicSeedFromTracks(List<Track> tracks) {
  HarmonicSeed? tempoOnly;
  for (final track in tracks) {
    final summary = track.analysis?.summary;
    final bpm = summary?.bpm?.numericValue?.toDouble();
    if (bpm == null || !bpm.isFinite || bpm <= 0) continue;
    final camelot = MixMetadataBadges.normalizeCamelot(
      summary?.camelot?.textValue,
    );
    if (camelot != null) {
      return (trackId: track.id, bpm: bpm, camelot: camelot);
    }
    tempoOnly ??= (trackId: track.id, bpm: bpm, camelot: null);
  }
  return tempoOnly ?? (trackId: null, bpm: null, camelot: null);
}
