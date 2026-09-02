import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../core/audio/playback_context.dart';
import '../../core/audio/playback_state.dart';
import '../../core/audio/queue_ordering.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/services/playlist_service.dart';
import '../../core/api/api_client.dart';
import '../../../models/mix_plan.dart';
import '../../models/nearby_tracks.dart';
import '../../models/playback_payload.dart';
import '../../core/storage/secure_storage.dart';
import '../../shared/models/playlist.dart';
import '../../shared/models/track.dart';
import '../../shared/widgets/download_button.dart';
import '../../shared/widgets/like_button.dart';
import '../../shared/widgets/queue_swipe_action.dart';
import '../../shared/widgets/track_tile.dart';
import 'mix/mix_models.dart';
import 'mix/mix_presets.dart';
import 'mix/mix_transition_editor.dart';
import 'harmonic_discovery_sheet.dart';
import 'mixed_playlist_view.dart';
import 'playlist_edit_dialog.dart';
import 'playlist_selection.dart';

/// Applies [edit] to [source], keeping the persisted invariant
/// `fadeOut(i) == fadeIn(i+1) == placement overlap` at every seam.
///
/// The overlap change moves the edited pair, and because the incoming clip's
/// end moves with its start, the entire downstream tail shifts by the same
/// delta so all later seams keep their exact geometry. Returns null when
/// either edited clip is absent from [source] — e.g. a regeneration replaced
/// the clip set underneath the editor.
///
/// Top-level and visible for test on purpose: the rebase it performs is the
/// H1 regression surface, and every widget-level route into it injects a save
/// stub, so the version-conflict rebase branch is reachable only from a unit
/// test.
@visibleForTesting
List<MixPlanClip>? clipsWithSeamEdit(
  List<MixPlanClip> source,
  MixTransitionEdit edit,
) {
  final outgoingIndex =
      source.indexWhere((clip) => clip.clipId == edit.outgoing.clipId);
  final incomingIndex =
      source.indexWhere((clip) => clip.clipId == edit.incoming.clipId);
  if (outgoingIndex < 0 || incomingIndex < 0) return null;

  final clips = [...source];

  // Apply only the authored fade values onto the CURRENT clips rather than
  // substituting the stale editor copies wholesale: a concurrent writer's
  // non-fade fields (gain, source bounds, stem edits) must survive a rebase.
  // (Review finding H1.)
  clips[outgoingIndex] =
      source[outgoingIndex].copyWith(fadeOutMs: edit.outgoing.fadeOutMs);
  clips[incomingIndex] =
      source[incomingIndex].copyWith(fadeInMs: edit.incoming.fadeInMs);

  final previousOutgoing = source[outgoingIndex];
  final previousIncoming = source[incomingIndex];
  final newOverlapMs = edit.overlapMs;
  // Timeline overlap between two clips: outgoing end minus incoming start.
  final previousOverlapMs =
      previousOutgoing.timelineEndMs - previousIncoming.timelineStartMs;
  final placementDeltaMs = newOverlapMs - previousOverlapMs;
  clips[incomingIndex] = clips[incomingIndex].withTimelineStartMs(
      previousIncoming.timelineStartMs - placementDeltaMs);
  for (var j = incomingIndex + 1; j < clips.length; j++) {
    clips[j] = clips[j]
        .withTimelineStartMs(clips[j].timelineStartMs - placementDeltaMs);
  }
  return clips;
}

class PlaylistDetailScreen extends StatefulWidget {
  final int playlistId;
  final PlaylistService? playlistService;

  /// Persists edited plan clips. Injectable so tests can stub persistence;
  /// defaults to the authenticated mix-plan API.
  final Future<MixPlan> Function(MixPlan plan, List<MixPlanClip> clips)?
      onSaveMixPlan;

  /// Runs the harmonic discovery query. Injectable for the same reason as
  /// [onSaveMixPlan]: the screen's own [ApiClient] is not constructor-injected,
  /// so without this seam the entry point cannot be driven in a widget test.
  /// Defaults to the authenticated `GET /tracks/nearby`.
  final HarmonicSearch? harmonicSearch;

  const PlaylistDetailScreen({
    super.key,
    required this.playlistId,
    this.playlistService,
    this.onSaveMixPlan,
    this.harmonicSearch,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  late final PlaylistService _playlistService = widget.playlistService ??
      PlaylistService(api: ApiClient(storage: SecureStorage()));
  late final ApiClient _mixPlanApiClient = ApiClient(storage: SecureStorage());

  Playlist? _playlist;
  bool _isLoading = true;
  String? _error;
  bool _isEditMode = false;
  bool _isSelectMode = false;
  PlaylistSelection _selection = const PlaylistSelection();
  bool _mixEnabled = false;
  bool _isMixLoading = false;
  AutoMixResult? _mixPlan;

  /// True while the blended list is scrolling fast; seam connectors collapse
  /// to hairlines so long playlists stay scannable.
  final ValueNotifier<bool> _fastScrolling = ValueNotifier(false);
  Timer? _seamExpandTimer;
  DateTime? _lastScrollTimestamp;

  static const double _fastScrollVelocityDpPerMs = 1.2;

  @override
  void initState() {
    super.initState();
    _loadPlaylist();
  }

  void _handleScrollMetrics(ScrollUpdateNotification notification) {
    if (!_mixEnabled) return;

    final now = DateTime.now();
    final previous = _lastScrollTimestamp;
    _lastScrollTimestamp = now;
    final delta = notification.scrollDelta;
    if (delta == null || previous == null) return;

    final deltaMs = now.difference(previous).inMicroseconds / 1000;
    if (deltaMs <= 0) return;
    final pixelsPerMs = delta.abs() / deltaMs;

    if (pixelsPerMs >= _fastScrollVelocityDpPerMs) {
      if (!_fastScrolling.value) _fastScrolling.value = true;
    }
    _scheduleSeamExpansion();
  }

  void _scheduleSeamExpansion() {
    _seamExpandTimer?.cancel();
    _seamExpandTimer = Timer(const Duration(milliseconds: 180), () {
      _lastScrollTimestamp = null;
      if (_fastScrolling.value) _fastScrolling.value = false;
    });
  }

  void _handleScrollSettled() {
    _seamExpandTimer?.cancel();
    _lastScrollTimestamp = null;
    if (_fastScrolling.value) _fastScrolling.value = false;
  }

  @override
  void dispose() {
    _seamExpandTimer?.cancel();
    _fastScrolling.dispose();
    super.dispose();
  }

  /// Toggles the blended view. Turning it on calls POST /auto-mix and keeps
  /// the returned plan in memory; turning it off only changes the local view
  /// — the server-side plan is preserved for later slices.
  Future<void> _toggleMix() async {
    if (_isMixLoading || !_hasMixEligibleTracks) return;
    final messenger = ScaffoldMessenger.of(context);

    if (_mixEnabled) {
      setState(() => _mixEnabled = false);
      return;
    }

    setState(() => _isMixLoading = true);
    try {
      final result = await _playlistService.autoMix(widget.playlistId);
      if (!mounted) return;
      setState(() {
        _mixEnabled = true;
        _mixPlan = result;
        _isMixLoading = false;
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Blended ${result.transitions.length} transitions. Tap any seam to adjust.',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _isMixLoading = false);
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not blend this playlist. Try again.'),
        ),
      );
    }
  }

  Future<void> _openSeam(int seamIndex, MixTransition? transition) async {
    final tracks = _playlist?.tracks ?? const <Track>[];
    if (seamIndex + 1 >= tracks.length) return;
    final plan = _mixPlan?.mixPlan;
    if (plan == null || plan.clips.length < seamIndex + 2) return;

    // Defense-in-depth: fail loudly if the displayed list no longer matches
    // the plan's clip order, mirroring playback's order validation.
    for (var i = 0; i < 2; i++) {
      if (plan.clips[seamIndex + i].trackId !=
          tracks[seamIndex + i].id.toString()) {
        return;
      }
    }

    final edit = await MixTransitionEditorSheet.show(
      context,
      outgoingTrack: tracks[seamIndex],
      incomingTrack: tracks[seamIndex + 1],
      outgoingClip: plan.clips[seamIndex],
      incomingClip: plan.clips[seamIndex + 1],
      transition: transition,
      outgoingIsEndpoint: seamIndex == 0,
      incomingIsEndpoint: seamIndex + 1 == tracks.length - 1,
      onSave: (edit) => _saveSeamEdit(plan, edit),
      onPreview: (draft) => _previewSeam(plan, seamIndex, draft),
      onStopPreview: _stopSeamPreview,
    );
    if (edit == null || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('Transition saved')),
    );
  }

  /// Auditions the draft seam without persisting it: the draft geometry is
  /// applied to a throwaway copy of the plan and handed to the one playback
  /// session, so the user hears exactly what Save would write.
  Future<void> _previewSeam(
    MixPlan plan,
    int seamIndex,
    MixTransitionEdit draft,
  ) async {
    final tracks = _playlist?.tracks ?? const <Track>[];
    final clips = clipsWithSeamEdit(plan.clips, draft);
    if (clips == null || tracks.length != clips.length) return;
    final playback = context.read<PlaybackState>();
    await playback.previewMixSeam(
      tracks.map((track) => track.toPlaybackJson()).toList(),
      _planWithClips(plan, clips),
      seamIndex: seamIndex,
      context: _playlistContext(),
    );
  }

  Future<void> _stopSeamPreview() async {
    if (!mounted) return;
    await context.read<PlaybackState>().endMixSeamPreview();
  }

  static MixPlan _planWithClips(MixPlan plan, List<MixPlanClip> clips) =>
      MixPlan(
        id: plan.id,
        schemaVersion: plan.schemaVersion,
        name: plan.name,
        clips: clips,
        summary: plan.summary,
        version: plan.version,
        createdAt: plan.createdAt,
        updatedAt: plan.updatedAt,
      );

  Future<void> _saveSeamEdit(MixPlan plan, MixTransitionEdit edit) async {
    final clips = clipsWithSeamEdit(plan.clips, edit);
    if (clips == null) {
      throw const FormatException('Edited clips are missing from the plan.');
    }

    MixPlan saved;
    if (widget.onSaveMixPlan != null) {
      saved = await widget.onSaveMixPlan!(plan, clips);
    } else {
      try {
        saved = await _mixPlanApiClient.updateMixPlan(
          id: plan.id,
          version: plan.version,
          name: plan.name,
          clips: clips,
        );
      } on ApiException catch (error) {
        if (error.statusCode != http409Conflict ||
            error.errorCode != 'VERSION_CONFLICT') {
          rethrow;
        }
        // Someone else updated the plan underneath us. Reload it, reapply
        // this edit against the fresh geometry, and retry once with the new
        // version so "try again" is actually actionable.
        final fresh = await _mixPlanApiClient.getMixPlan(plan.id);
        final retried = _rebaseSeamEdit(fresh, edit);
        if (retried == null) {
          throw ApiException(
            'This mix changed since you opened the editor. Reopen the seam and apply your change again.',
            error.statusCode,
            errorCode: 'VERSION_CONFLICT',
          );
        }
        saved = await _mixPlanApiClient.updateMixPlan(
          id: fresh.id,
          version: fresh.version,
          name: fresh.name,
          clips: retried,
        );
      }
    }
    if (!mounted) return;
    setState(() {
      _mixPlan = _resultWithSavedClips(saved);
    });
  }

  static const int http409Conflict = 409;

  /// Applies [edit] to [fresh] by clipId. Returns null when either edited
  /// clip no longer exists in the fresh plan (e.g. a regeneration replaced
  /// the clip set), in which case the user must reopen the seam.
  List<MixPlanClip>? _rebaseSeamEdit(MixPlan fresh, MixTransitionEdit edit) =>
      clipsWithSeamEdit(fresh.clips, edit);

  /// Rebuilds the transition decorations from a freshly saved plan so seam
  /// badges reflect what was actually persisted.
  AutoMixResult? _resultWithSavedClips(MixPlan saved) {
    final current = _mixPlan;
    if (current == null) return null;
    final trackIds = [for (final clip in saved.clips) int.parse(clip.trackId)];
    final rebuilt = <MixTransition>[];
    for (var i = 0; i + 1 < saved.clips.length; i++) {
      final stale =
          current.transitionsByPair['${trackIds[i]}-${trackIds[i + 1]}'];
      rebuilt.add(
        MixTransition(
          index: i,
          outgoingTrackId: trackIds[i],
          incomingTrackId: trackIds[i + 1],
          overlapMs: _overlapBetween(saved.clips[i], saved.clips[i + 1]),
          // Mirror the backend's downgrade rule: once the authored overlap
          // no longer equals what the preset was derived for, the transition
          // is no longer bar-aligned — report a plain volume-only Fade
          // instead of claiming Blend/Rise geometry that no longer holds.
          preset: _isUnchanged(stale, saved.clips[i], saved.clips[i + 1])
              ? (stale?.preset ?? 'Fade')
              : MixPreset.forOverlapMs(
                  _overlapBetween(saved.clips[i], saved.clips[i + 1]),
                ).label,
          bars: _isUnchanged(stale, saved.clips[i], saved.clips[i + 1])
              ? stale?.bars
              : 0,
          keyMatch: stale?.keyMatch ?? false,
          tempoMatched: stale?.tempoMatched ?? false,
          tempoShift: stale?.tempoShift ?? false,
          simpleFade: _isUnchanged(stale, saved.clips[i], saved.clips[i + 1])
              ? (stale?.simpleFade ?? true)
              : true,
        ),
      );
    }
    return AutoMixResult(
      transitions: rebuilt,
      mixPlan: saved,
      transitionsByPair: {
        for (final transition in rebuilt)
          '${transition.outgoingTrackId}-${transition.incomingTrackId}':
              transition,
      },
    );
  }

  static int _overlapBetween(MixPlanClip outgoing, MixPlanClip incoming) =>
      math.max(
        0,
        outgoing.timelineEndMs - incoming.timelineStartMs,
      );

  /// True when the persisted seam still matches what the generator emitted,
  /// i.e. its fades equal the transition's reported overlap.
  static bool _isUnchanged(
    MixTransition? stale,
    MixPlanClip outgoing,
    MixPlanClip incoming,
  ) {
    if (stale == null || stale.overlapMs <= 0) return true;
    final fadeOut = outgoing.fadeOutMs;
    if (fadeOut == null) return true;
    return fadeOut == stale.overlapMs;
  }

  Future<void> _loadPlaylist() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final playlist = await _playlistService.getPlaylist(widget.playlistId);
      setState(() {
        _playlist = playlist;
        _mixEnabled = false;
        _mixPlan = null;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _removeTrack(Track track) async {
    if (_playlist == null) return;

    final playlist = _playlist!;
    final messenger = ScaffoldMessenger.of(context);

    try {
      final updated = await _playlistService.batchRemoveTracks(
        playlist.id,
        [track.id],
      );
      if (mounted) {
        setState(() {
          _playlist = updated;
          _mixEnabled = false;
          _mixPlan = null;
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text('Removed "${track.title}"'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final result =
                    await _playlistService.addTracks(_playlist!.id, [track.id]);
                if (mounted && result.hasSkipped && !result.hasAdded) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text(result.feedbackMessage(playlist.name)),
                    ),
                  );
                }
                _loadPlaylist();
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to remove "${track.title}"')),
        );
      }
    }
  }

  Future<void> _enqueueTrack(Track track) =>
      _enqueuePayload(track.toPlaybackJson(), track.title);

  /// The single queue-append path for this screen, so a playlist row and a
  /// harmonic match report success and failure identically.
  Future<void> _enqueuePayload(
    Map<String, dynamic> payload,
    String title,
  ) async {
    final playback = context.read<PlaybackState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await playback.enqueue(payload);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Added "$title" to queue')),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not add to queue')),
      );
    }
  }

  String get _playlistDisplayName => _playlist?.name ?? 'this playlist';

  /// Opens harmonic discovery seeded from the first analyzed track in this
  /// playlist. Results come from the whole library, so the sheet is useful
  /// even when nothing here is analyzed — the user can type a tempo and key.
  Future<void> _openHarmonicDiscovery() async {
    final tracks = _playlist?.tracks ?? const <Track>[];
    final seed = harmonicSeedFromTracks(tracks);
    final seeded = seed.bpm != null && seed.camelot != null;
    await HarmonicDiscoverySheet.show(
      context,
      search: widget.harmonicSearch ?? _searchNearbyTracks,
      playlistName: _playlistDisplayName,
      seedBpm: seed.bpm,
      seedCamelot: seed.camelot,
      // Only meaningful once the anchor actually drove the query.
      excludeTrackId: seeded ? seed.trackId : null,
      onAddToQueue: _enqueueMatch,
      onAddToPlaylist: _addMatchToPlaylist,
    );
  }

  Future<NearbyTracksResult> _searchNearbyTracks({
    required double bpm,
    required String camelot,
    required double tolerance,
    required bool orderByHistory,
  }) =>
      _mixPlanApiClient.getNearbyTracks(
        bpm: bpm,
        camelot: camelot,
        tolerance: tolerance,
        orderByHistory: orderByHistory,
      );

  /// Prefers the library track already on screen: it carries artwork and
  /// analysis that `/tracks/nearby` does not return. Otherwise the match's own
  /// `duration_ms` builds the payload — a queue item of unknown length becomes
  /// a zero-length timeline clip that is never active, so it would be silently
  /// skipped in playback while colliding with the next track's slot. That is
  /// worse than not queueing at all, so an unknown length is refused out loud.
  Future<void> _enqueueMatch(NearbyTrack match) {
    for (final track in _playlist?.tracks ?? const <Track>[]) {
      if (track.id == match.id) {
        return _enqueuePayload(track.toPlaybackJson(), track.title);
      }
    }
    final durationMs = match.durationMs;
    if (durationMs == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not add "${match.title}" to queue: its length is unknown.',
          ),
        ),
      );
      return Future<void>.value();
    }
    return _enqueuePayload(
      buildPlaybackPayload(
        id: match.id,
        title: match.title,
        artist: match.artist,
        album: match.album,
        duration: Duration(milliseconds: durationMs),
      ),
      match.title,
    );
  }

  Future<void> _addMatchToPlaylist(NearbyTrack match) async {
    final messenger = ScaffoldMessenger.of(context);
    final playlistName = _playlistDisplayName;
    try {
      final result = await _playlistService.addTracks(
        widget.playlistId,
        [match.id],
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(result.feedbackMessage(playlistName))),
      );
      await _loadPlaylist();
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not add to this playlist. Try again.'),
        ),
      );
    }
  }

  void _toggleSelectMode() {
    setState(() {
      _isSelectMode = !_isSelectMode;
      _selection = const PlaylistSelection();
      if (_isSelectMode) _isEditMode = false;
    });
  }

  void _toggleTrackSelection(int trackId) {
    setState(() => _selection = _selection.toggle(trackId));
  }

  /// Removes every selected track in a single batch-remove request.
  Future<void> _removeSelectedTracks() async {
    if (_playlist == null || _selection.isEmpty) return;

    final ids = _selection.selectedIds.toList();
    final messenger = ScaffoldMessenger.of(context);
    final label = _selection.removeLabel.toLowerCase();

    try {
      final updated =
          await _playlistService.batchRemoveTracks(_playlist!.id, ids);
      if (!mounted) return;
      setState(() {
        _playlist = updated;
        _mixEnabled = false;
        _mixPlan = null;
        _isSelectMode = false;
        _selection = const PlaylistSelection();
      });
      messenger.showSnackBar(
        SnackBar(content: Text('Removed ${ids.length} tracks')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to $label: $e')),
      );
    }
  }

  /// Sequences the playlist by tempo and key on the server.
  ///
  /// The server persists the new order and regenerates the active plan for it
  /// in the same request, so what is shown here is what was persisted and what
  /// will play — no client-side display ordering.
  Future<void> _smartReorder() async {
    if (_isMixLoading || !_hasMixEligibleTracks) return;
    final playlist = _playlist;
    final tracks = playlist?.tracks;
    if (playlist == null || tracks == null) return;
    final messenger = ScaffoldMessenger.of(context);

    setState(() => _isMixLoading = true);
    try {
      final result = await _playlistService.smartReorder(
        playlist.id,
        mixPlanId: _mixPlan?.mixPlan?.id,
      );
      if (!mounted) return;
      final reordered = _tracksInOrder(tracks, result.order);
      setState(() {
        _isMixLoading = false;
        if (reordered != null) {
          _playlist = playlist.copyWith(tracks: reordered);
        }
        if (result.mix != null) {
          _mixPlan = result.mix;
        } else if (reordered != null && _mixPlan != null) {
          // The order moved but no plan came back, so the plan we hold no
          // longer describes what is displayed. Drop it rather than let the
          // two disagree.
          _mixPlan = null;
          _mixEnabled = false;
        }
      });
      if (reordered == null) {
        // The server's order does not describe the list we are showing.
        // Reload rather than render a guess.
        await _loadPlaylist();
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(result.feedbackMessage())),
      );
    } on ApiException catch (error) {
      // The server's rejections here are deliberate and actionable — an
      // unlinked plan asks the user to reblend first — so render the server's
      // own message verbatim instead of burying it under a generic retry
      // prompt (review finding P1-c, mirroring the seam editor sheet).
      await _recoverFromFailedReorder(playlist, messenger, error.message);
    } catch (_) {
      await _recoverFromFailedReorder(
        playlist,
        messenger,
        'Could not reorder this playlist. Try again.',
      );
    }
  }

  /// Puts the screen back on solid ground after a failed reorder, then reports
  /// [message].
  ///
  /// A failed reorder may have persisted the order but not the plan
  /// (server-side compensation is best-effort), so the list we hold can be
  /// stale in either direction. Reload from the server, preserving the mix
  /// view so a transient failure does not tear down blended mode.
  Future<void> _recoverFromFailedReorder(
    Playlist playlist,
    ScaffoldMessengerState messenger,
    String message,
  ) async {
    if (!mounted) return;
    setState(() => _isMixLoading = false);
    final reloaded = await _playlistService.getPlaylist(playlist.id);
    if (!mounted) return;
    setState(() {
      _playlist = reloaded;
      if (reloaded.tracks == null || _mixPlanMissingTracks(reloaded.tracks!)) {
        _mixPlan = null;
        _mixEnabled = false;
      }
    });
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  /// True when [tracks] no longer contains every clip track of [_mixPlan], i.e.
  /// the held plan cannot describe this playlist anymore.
  bool _mixPlanMissingTracks(List<Track> tracks) {
    final plan = _mixPlan?.mixPlan;
    if (plan == null) return false;
    final ids = tracks.map((t) => t.id).toSet();
    return plan.clips.any((c) => !ids.contains(int.parse(c.trackId)));
  }

  /// Reorders [tracks] to match [order], or null when [order] is not exactly
  /// this playlist's track set.
  static List<Track>? _tracksInOrder(List<Track> tracks, List<int> order) {
    if (order.length != tracks.length) return null;
    final byId = {for (final track in tracks) track.id: track};
    final reordered = <Track>[];
    for (final id in order) {
      final track = byId.remove(id);
      if (track == null) return null;
      reordered.add(track);
    }
    return reordered;
  }

  Future<void> _reorderTrack(int oldIndex, int newIndex) async {
    if (_playlist == null || _playlist!.tracks == null) return;

    final tracks = List<Track>.from(_playlist!.tracks!);
    final track = tracks.removeAt(oldIndex);
    tracks.insert(newIndex, track);

    setState(() {
      _playlist = _playlist!.copyWith(tracks: tracks);
      _mixEnabled = false;
      _mixPlan = null;
    });

    try {
      await _playlistService.reorderTrack(
        _playlist!.id,
        trackId: track.id,
        newPosition: newIndex,
      );
    } catch (e) {
      _loadPlaylist();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to reorder: $e')),
        );
      }
    }
  }

  void _showEditDialog() {
    if (_playlist == null) return;

    showDialog(
      context: context,
      builder: (context) => PlaylistEditDialog(
        initialName: _playlist!.name,
        initialDescription: _playlist!.description,
        initialCoverUrl: _playlist!.coverUrl,
        initialIsPublic: _playlist!.isPublic,
        onSave: (result) async {
          try {
            final updated = await _playlistService.updatePlaylist(
              _playlist!.id,
              name: result.name,
              description: result.description,
              coverUrl: result.coverUrl ?? '',
              isPublic: result.isPublic,
            );
            if (!mounted) return;
            setState(
                () => _playlist = updated.copyWith(tracks: _playlist!.tracks));
            ScaffoldMessenger.of(this.context).showSnackBar(
              const SnackBar(content: Text('Playlist updated')),
            );
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(this.context).showSnackBar(
              SnackBar(content: Text('Failed to update: $e')),
            );
          }
        },
      ),
    );
  }

  void _showDeleteConfirmation() {
    final playlist = _playlist;
    if (playlist == null) return;
    final router = GoRouter.of(context);
    final messenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete playlist?'),
        content: Text(
          'Are you sure you want to delete "${playlist.name}"? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await _playlistService.deletePlaylist(playlist.id);
                if (!mounted) return;
                router.pop();
                messenger.showSnackBar(
                  SnackBar(content: Text('Deleted "${playlist.name}"')),
                );
              } catch (e) {
                if (!mounted) return;
                messenger.showSnackBar(
                  SnackBar(content: Text('Failed to delete: $e')),
                );
              }
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  bool get _hasPlayableTracks => _playlist?.tracks?.isNotEmpty ?? false;
  bool get _hasMixEligibleTracks => (_playlist?.tracks?.length ?? 0) >= 2;

  Future<bool> _tryMixPlayback(Future<void> Function() start) async {
    try {
      await start();
      return true;
    } on FormatException {
      // A stale or unmappable server plan must never make the playlist
      // unplayable. Plain queue playback is the safe fallback.
      return false;
    }
  }

  /// Plays the whole playlist into the listening queue, optionally shuffled.
  Future<void> _playAll({bool shuffle = false}) async {
    final tracks = playCollectionOrder(
      _playlist?.tracks ?? const <Track>[],
      shuffled: shuffle,
    );
    if (tracks.isEmpty) return;
    final playback = context.read<PlaybackState>();
    final plan = !shuffle && _mixEnabled ? _mixPlan?.mixPlan : null;
    if (plan != null &&
        await _tryMixPlayback(
          () => playback.playMixPlan(
            tracks.map((track) => track.toPlaybackJson()).toList(),
            plan,
            context: _playlistContext(),
          ),
        )) {
      return;
    }
    await playback.playQueue(
      tracks.map((t) => t.toPlaybackJson()).toList(),
      context: _playlistContext(),
    );
  }

  PlaybackContext? _playlistContext() {
    final playlist = _playlist;
    if (playlist == null) return null;
    return PlaybackContext(
      kind: PlaybackContextKind.playlist,
      label: playlist.name,
      id: playlist.id.toString(),
    );
  }

  /// Plays the playlist starting from the tapped track (context = the playlist).
  Future<void> _playFromIndex(int index) async {
    final tracks = _playlist?.tracks ?? const [];
    if (index < 0 || index >= tracks.length) return;
    final playback = context.read<PlaybackState>();
    final plan = _mixEnabled ? _mixPlan?.mixPlan : null;
    if (plan != null &&
        await _tryMixPlayback(
          () => playback.playMixPlan(
            tracks.map((track) => track.toPlaybackJson()).toList(),
            plan,
            startIndex: index,
            context: _playlistContext(),
          ),
        )) {
      return;
    }
    await playback.playQueue(
      tracks.map((t) => t.toPlaybackJson()).toList(),
      startIndex: index,
      context: _playlistContext(),
    );
  }

  bool _isCurrentPlaylistQueue(PlaybackContext? playbackContext) {
    final playlist = _playlist;
    if (playlist == null) return false;
    return playbackContext?.kind == PlaybackContextKind.playlist &&
        playbackContext?.id == playlist.id.toString();
  }

  bool _isCurrentTrackInThisPlaylist(
    PlaybackContext? playbackContext,
    String? currentItemId,
    Track track,
  ) {
    if (!_isCurrentPlaylistQueue(playbackContext)) return false;
    return int.tryParse(currentItemId ?? '') == track.id;
  }

  String _activeTrackLabel(bool isPlaying) {
    return isPlaying ? 'Now playing' : 'Paused here';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _withScrollObserver(_buildBody()),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 16),
            Text('Error: $_error'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loadPlaylist,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_playlist == null) {
      return const Center(child: Text('Playlist not found'));
    }

    return CustomScrollView(
      slivers: [
        _buildAppBar(),
        _buildHeader(),
        _mixEnabled ? _buildMixedTracksList() : _buildTracksList(),
      ],
    );
  }

  /// Notification wrapper keeps scroll-velocity handling local to the blended
  /// view without owning a second scroll position.
  Widget _withScrollObserver(Widget child) {
    if (!_mixEnabled) return child;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification) {
          _handleScrollMetrics(notification);
        } else if (notification is ScrollEndNotification) {
          _handleScrollSettled();
        }
        return false;
      },
      child: child,
    );
  }

  Widget _buildAppBar() {
    if (_isSelectMode) return _buildSelectionAppBar();
    return SliverAppBar(
      expandedHeight: 200,
      pinned: true,
      flexibleSpace: FlexibleSpaceBar(
        title: Text(
          _playlist!.name,
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            shadows: [Shadow(blurRadius: 4)],
          ),
        ),
        background: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.6),
                Theme.of(context).scaffoldBackgroundColor,
              ],
            ),
          ),
          child: Center(
            child: Icon(
              Icons.queue_music,
              size: 80,
              color: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
      actions: [
        _HarmonicDiscoveryAction(onPressed: _openHarmonicDiscovery),
        if (_hasMixEligibleTracks && _isMixLoading)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        if (_mixEnabled && !_isMixLoading)
          IconButton(
            key: const ValueKey('mix_reorder_button'),
            icon: const Icon(Icons.sort),
            onPressed: _smartReorder,
            tooltip: 'Smart reorder by tempo and key',
          ),
        if (_hasMixEligibleTracks && !_isMixLoading)
          IconButton(
            key: const ValueKey('mix_toggle'),
            icon: Icon(
              Icons.auto_awesome,
              color: _mixEnabled ? AppTheme.orange : null,
            ),
            onPressed: _toggleMix,
            tooltip: _mixEnabled
                ? 'Blended — transitions between every track'
                : 'Blend this playlist',
          ),
        IconButton(
          icon: Icon(_isEditMode ? Icons.check : Icons.edit),
          onPressed: () => setState(() => _isEditMode = !_isEditMode),
          tooltip: _isEditMode ? 'Done editing' : 'Edit mode',
        ),
        PopupMenuButton(
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'select',
              child: ListTile(
                leading: Icon(Icons.checklist),
                title: Text('Select tracks'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'edit',
              child: ListTile(
                leading: Icon(Icons.edit),
                title: Text('Edit details'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete, color: Colors.red),
                title: Text('Delete', style: TextStyle(color: Colors.red)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
          onSelected: (value) {
            if (value == 'select') _toggleSelectMode();
            if (value == 'edit') _showEditDialog();
            if (value == 'delete') _showDeleteConfirmation();
          },
        ),
      ],
    );
  }

  Widget _buildSelectionAppBar() {
    return SliverAppBar(
      pinned: true,
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _toggleSelectMode,
        tooltip: 'Cancel selection',
      ),
      title: Text(
        _selection.isEmpty ? 'Select tracks' : '${_selection.count} selected',
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: _selection.removeLabel,
          onPressed: _selection.isEmpty ? null : _confirmRemoveSelected,
        ),
      ],
    );
  }

  void _confirmRemoveSelected() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove tracks?'),
        content: Text('Remove ${_selection.count} tracks from this playlist?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _removeSelectedTracks();
            },
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final theme = Theme.of(context);

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_playlist!.description != null &&
                _playlist!.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  _playlist!.description!,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            Text(
              '${_playlist!.trackCount} tracks • ${_playlist!.formattedDuration}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _hasPlayableTracks ? () => _playAll() : null,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Play'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _hasPlayableTracks && !_mixEnabled
                        ? () => _playAll(shuffle: true)
                        : null,
                    icon: const Icon(Icons.shuffle),
                    label: const Text('Shuffle'),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: DownloadAllButton.forPlaylist(
                _playlist!,
                buttonKey: const ValueKey('playlist_download_all'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTracksList() {
    final tracks = _playlist!.tracks ?? [];
    final playbackContext = context.select<PlaybackState, PlaybackContext?>(
      (playback) => playback.playbackContext,
    );
    final currentItemId = context.select<PlaybackState, String?>(
      (playback) => playback.currentItem?.id,
    );
    final isPlaying = context.select<PlaybackState, bool>(
      (playback) => playback.isPlaying,
    );

    if (tracks.isEmpty) {
      return const SliverFillRemaining(
        hasScrollBody: false,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.music_note, size: 48, color: Colors.grey),
              SizedBox(height: 16),
              Text('No tracks yet'),
              SizedBox(height: 8),
              Text(
                'Add tracks from your library',
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    if (_isSelectMode) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final track = tracks[index];
            final selected = _selection.contains(track.id);
            final isCurrent = _isCurrentTrackInThisPlaylist(
              playbackContext,
              currentItemId,
              track,
            );
            return TrackTile.fromTrack(
              track,
              isCurrent: isCurrent,
              onTap: () => _toggleTrackSelection(track.id),
              trailing: Checkbox(
                value: selected,
                onChanged: (_) => _toggleTrackSelection(track.id),
              ),
            );
          },
          childCount: tracks.length,
        ),
      );
    }

    if (_isEditMode) {
      return SliverReorderableList(
        itemCount: tracks.length,
        onReorderItem: _reorderTrack,
        itemBuilder: (context, index) {
          final track = tracks[index];
          final isCurrent = _isCurrentTrackInThisPlaylist(
            playbackContext,
            currentItemId,
            track,
          );
          return ReorderableDragStartListener(
            key: Key('track_${track.id}'),
            index: index,
            child: TrackTile.fromTrack(
              track,
              isCurrent: isCurrent,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => _removeTrack(track),
                    color: Colors.red,
                  ),
                  const Icon(Icons.drag_handle),
                ],
              ),
            ),
          );
        },
      );
    }

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final track = tracks[index];
          final isCurrent = _isCurrentTrackInThisPlaylist(
            playbackContext,
            currentItemId,
            track,
          );
          return QueueSwipeAction(
            actionKey:
                Key('playlist_queue_${widget.playlistId}_${track.id}_$index'),
            onAddToQueue: () => _enqueueTrack(track),
            child: TrackTile.fromTrack(
              track,
              isCurrent: isCurrent,
              onTap: () => _playFromIndex(index),
              activeLabel: isCurrent ? _activeTrackLabel(isPlaying) : null,
              action: LikeToggleButton(
                track: track,
                buttonKey: ValueKey('playlist_like_${track.id}'),
              ),
            ),
          );
        },
        childCount: tracks.length,
      ),
    );
  }

  /// Blended list: track rows gain BPM/key badges, and every pair of adjacent
  /// rows is separated by a tappable seam connector. Seams collapse to
  /// hairlines while the user scrolls fast and expand back on settle.
  Widget _buildMixedTracksList() {
    final tracks = _playlist!.tracks ?? const <Track>[];
    if (tracks.isEmpty) return _buildTracksList();

    final playbackContext = context.select<PlaybackState, PlaybackContext?>(
      (playback) => playback.playbackContext,
    );
    final currentItemId = context.select<PlaybackState, String?>(
      (playback) => playback.currentItem?.id,
    );
    final isPlaying = context.select<PlaybackState, bool>(
      (playback) => playback.isPlaying,
    );

    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          // Interleave: even indices are track rows, odd ones are seams.
          if (index.isOdd) {
            final seamIndex = index ~/ 2;
            final transition =
                _mixPlan?.between(tracks[seamIndex], tracks[seamIndex + 1]);
            return ValueListenableBuilder<bool>(
              key: Key(
                  'mix_seam_${tracks[seamIndex].id}_${tracks[seamIndex + 1].id}'),
              valueListenable: _fastScrolling,
              builder: (context, collapsed, _) {
                return MixSeamConnector(
                  transition: transition,
                  collapsed: collapsed,
                  onTap: () => _openSeam(seamIndex, transition),
                );
              },
            );
          }

          final rowIndex = index ~/ 2;
          final track = tracks[rowIndex];
          final isCurrent = _isCurrentTrackInThisPlaylist(
            playbackContext,
            currentItemId,
            track,
          );
          return Column(
            key: Key('mixed_track_${track.id}'),
            children: [
              // Built directly (not via fromTrack) so the plain tile does not
              // render its own metadata chips; the blended badges below are
              // the single metadata surface in this view.
              TrackTile(
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.formattedDuration,
                coverArtUrl: track.displayArtworkUrl,
                artworkKind: track.artworkKind,
                isCurrent: isCurrent,
                activeLabel: isCurrent ? _activeTrackLabel(isPlaying) : null,
                onTap: () => _playFromIndex(rowIndex),
                action: LikeToggleButton(
                  track: track,
                  buttonKey: ValueKey('playlist_like_${track.id}'),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: MixTrackBadges(analysis: track.analysis),
                ),
              ),
            ],
          );
        },
        childCount: tracks.length * 2 - 1,
      ),
    );
  }
}

/// The only way into harmonic discovery.
///
/// Unlike the DJ deck this surface allocates no audio voices and has no
/// URL-reachable state, so there is nothing a route redirect could protect
/// that hiding the entry point does not — the gate lives here, on the entry
/// point itself, and reads the same user-controlled `djModeEnabled` switch
/// that bounds every other DJ-facing affordance.
class _HarmonicDiscoveryAction extends StatelessWidget {
  const _HarmonicDiscoveryAction({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    try {
      riverpod.ProviderScope.containerOf(context, listen: false);
    } catch (_) {
      // Narrow widget harnesses mount PlaylistDetailScreen without the
      // app-level ProviderScope. With no settings to consult there is no
      // recorded opt-in, so the entry point stays hidden rather than turning
      // itself on by default.
      return const SizedBox.shrink();
    }
    return riverpod.Consumer(
      builder: (context, ref, _) {
        final enabled = ref.watch(
          settingsProvider.select((settings) => settings.djModeEnabled),
        );
        if (!enabled) return const SizedBox.shrink();
        return IconButton(
          key: const ValueKey('harmonic_discovery_action'),
          icon: const Icon(Icons.travel_explore),
          tooltip: 'Find harmonic matches',
          onPressed: onPressed,
        );
      },
    );
  }
}
