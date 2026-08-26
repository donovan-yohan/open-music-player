import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/theme.dart';
import '../../core/api/api_client.dart';
import '../../providers/queue_provider.dart';
import 'dj_session_filters.dart';
import 'dj_session_models.dart';
import 'dj_session_service.dart';

/// A portrait-first, queue-backed DJ discovery surface.
///
/// It intentionally owns only request/filter and lineup rendering state. Every
/// track action delegates to [QueueProvider], leaving QueueTimelineController
/// and PlaybackState as the application's sole playback authorities.
///
/// Presentation follows the Hotate DJ-session design spec: the hero steer pill
/// is the focal point, section rhythm uses the AppTheme space tokens, and all
/// copy speaks in the friend-at-the-decks voice defined in the spec.
class DjSessionScreen extends StatefulWidget {
  const DjSessionScreen({
    super.key,
    this.service,
    this.randomSeed,
    this.clock,
  });

  final DjSessionDataSource? service;
  final int Function()? randomSeed;

  /// Injectable clock for time-of-day UI (prompt suggestions). Production
  /// callers omit it; widget tests pin it so suggestions are deterministic.
  final DateTime Function()? clock;

  @override
  State<DjSessionScreen> createState() => _DjSessionScreenState();
}

/// Server id of the flag-gated harmonic block. It is not a themed block: the
/// pin endpoint's enum is deliberately frozen at the three themes, so the pin
/// affordance is hidden here rather than offering a control the server rejects.
/// See docs/adr/0008-harmonic-lineup-candidate-composition.md.
const djHarmonicBlockId = 'harmonic';

class _DjSessionScreenState extends State<DjSessionScreen> {
  static const _coachMarkSeenKey = 'dj_session.coach_mark_seen';
  static const _requestSubmittedKey = 'dj_session.request_submitted';
  static const _fallbackBlocks = [
    DjLineupBlock(
      id: 'on-repeat',
      title: 'On repeat',
      reason: 'The ones you keep coming back to.',
      tracks: [],
    ),
    DjLineupBlock(
      id: 'flashback',
      title: 'Flashback',
      reason: "Haven't heard this in a minute.",
      tracks: [],
    ),
    DjLineupBlock(
      id: 'fresh-finds',
      title: 'Fresh finds',
      reason: 'Barely played. Worth your time.',
      tracks: [],
    ),
  ];

  late final DjSessionDataSource _service;
  late final int Function() _randomSeed;
  late final DateTime Function() _clock;
  late final TextEditingController _requestController;
  final FocusNode _requestFocusNode = FocusNode();
  DjSessionFilters _filters = const DjSessionFilters();
  List<DjLineupBlock> _blocks = const [];
  final Set<String> _loadingBlockIds = {};
  final Map<String, String> _blockErrors = {};
  final Map<String, int> _blockRevisions = {};

  /// Block ids whose latest Swap returned an empty-but-successful block while
  /// other sections still had content. These render the friendly inline line
  /// instead of the transport-failure banner (spec QA-a).
  final Set<String> _emptySwapBlockIds = {};

  bool get _isAnySectionLoading =>
      _loadingAll || _loadingBlockIds.isNotEmpty;

  // Full requests invalidate every in-flight block reroll, while rerolls only
  // invalidate a full response that started before them. That keeps two
  // independent block rerolls useful without letting stale responses replace
  // the lineup chosen by the listener's latest filter or refresh action.
  int _fullLoadGeneration = 0;
  int _fullResponseGeneration = 0;
  final Map<String, int> _rerollGenerations = {};
  bool _loadingAll = true;
  bool _loadedAllOnce = false;
  bool _steering = false;
  bool _heroPressed = false;
  bool _coachMarkVisible = false;
  String _refreshError = '';
  String _announcement = '';

  /// Block id of the active vibe pin as mirrored by the lineup response.
  /// Null when no pin exists.
  String? _pinnedBlockId;

  /// Block id whose pin/unpin request is currently in flight (drives the
  /// inline spinner and disables competing pin toggles).
  String? _pendingPinBlockId;

  bool get _isPinBusy =>
      _pendingPinBlockId != null || _loadingBlockIds.isNotEmpty;

  /// The queue provider this screen observes for its anchor. QueueProvider is
  /// hydrated lazily by whichever surface loads it first, so a cold start into
  /// the DJ session reads an empty snapshot and omits anchorTrackId entirely.
  QueueProvider? _queue;

  /// True once a non-empty queue snapshot has been seen. Until then, the
  /// first snapshot to arrive re-issues the lineup load so the anchor is
  /// actually sent — this screen still never fetches the queue itself.
  bool _anchorSettled = false;

  /// True while this screen is the one mutating the queue. Its own enqueues
  /// already know the anchor, and reloading the lineup under the listener's
  /// tap would swap the set they just acted on.
  bool _mutatingQueue = false;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? DjSessionService(context.read<ApiClient>());
    _randomSeed = widget.randomSeed ?? () => Random().nextInt(1 << 31);
    _clock = widget.clock ?? DateTime.now;
    _requestController = TextEditingController();
    final queue = context.read<QueueProvider>();
    _queue = queue;
    _anchorSettled = queue.queue.tracks.isNotEmpty;
    queue.addListener(_onQueueChanged);
    _loadAll();
    _maybeShowCoachMark();
  }

  @override
  void dispose() {
    _queue?.removeListener(_onQueueChanged);
    _requestController.dispose();
    _requestFocusNode.dispose();
    super.dispose();
  }

  /// Reloads the lineup the first time the queue hydrates, so a session opened
  /// before the queue snapshot existed still gets a queue-tail-anchored lineup.
  /// Fires at most once, and never for this screen's own queue mutations.
  void _onQueueChanged() {
    if (!mounted || _anchorSettled) return;
    if (_queue?.queue.tracks.isEmpty ?? true) return;
    _anchorSettled = true;
    if (_mutatingQueue) return;
    _loadAll();
  }

  List<DjLineupBlock> get _visibleBlocks =>
      _blocks.isEmpty ? _fallbackBlocks : _blocks;

  String _titleOf(String blockId) {
    for (final block in _visibleBlocks) {
      if (block.id == blockId) return block.title;
    }
    return 'vibe';
  }

  bool get _isEmptyLibrary =>
      !_loadingAll &&
      _blockErrors.isEmpty &&
      _loadedAllOnce &&
      _blocks.every((block) => block.tracks.isEmpty);

  /// Last enqueued track id from the queue snapshot this screen already has.
  /// The DJ session surface stays a discovery surface: it never triggers a
  /// queue fetch and never becomes a queue authority.
  int? _queueTailTrackId() {
    if (!mounted) return null;
    final tracks = context.read<QueueProvider>().queue.tracks;
    if (tracks.isEmpty) return null;
    final tail = tracks.last;
    return int.tryParse(tail.playbackTrackId ?? tail.id);
  }

  DjLineupRequest _requestForFilters({
    String? block,
    List<int> excludeIds = const [],
    int? seed,
  }) {
    return DjLineupRequest(
      blocks: block == null ? 3 : null,
      perBlock: 5,
      energy: _filters.energy,
      query: _filters.query,
      block: block,
      excludeIds: excludeIds,
      seed: seed,
      anchorTrackId: _queueTailTrackId(),
    );
  }

  /// Loads the full lineup. When [steering] is true (hero pill tap) the
  /// request carries a fresh seed so the listener hears a genuinely new set.
  Future<void> _loadAll({bool steering = false}) async {
    ++_fullLoadGeneration;
    final responseGeneration = ++_fullResponseGeneration;
    if (mounted) {
      setState(() {
        _loadingAll = true;
        if (steering) _steering = true;
        _refreshError = '';
        _loadingBlockIds.addAll(_visibleBlocks.map((block) => block.id));
      });
    }

    try {
      final lineup = await _service.fetchLineup(
        _requestForFilters(seed: steering ? _randomSeed() : null),
      );
      if (!mounted || responseGeneration != _fullResponseGeneration) return;
      setState(() {
        _blocks = lineup.blocks;
        _pinnedBlockId = lineup.pinnedBlockId;
        _loadingAll = false;
        _loadedAllOnce = true;
        _loadingBlockIds.clear();
        _blockErrors.clear();
        // A full lineup refresh replaces every section, so any lingering
        // empty-swap markers refer to blocks that no longer exist as rendered.
        _emptySwapBlockIds.clear();
      });
      _scheduleStaggeredRevisionBumps(responseGeneration);
      if (steering) _finishSteering();
      _announce('Session updated');
    } catch (_) {
      if (!mounted || responseGeneration != _fullResponseGeneration) return;
      setState(() {
        _loadingAll = false;
        if (steering) _steering = false;
        _loadingBlockIds.clear();
        if (_blocks.isEmpty) {
          _blocks = _fallbackBlocks;
          for (final block in _fallbackBlocks) {
            _blockErrors[block.id] = "This block didn't load.";
          }
        } else {
          _refreshError = "Couldn't refresh the session.";
        }
      });
    }
  }

  /// Re-keys each section rail in 120ms steps after a full reload so the swap
  /// choreography staggers down the page instead of firing all at once.
  void _scheduleStaggeredRevisionBumps(int responseGeneration) {
    final ids = _blocks.map((block) => block.id).toList(growable: false);
    for (var i = 1; i < ids.length; i++) {
      final blockId = ids[i];
      unawaited(Future<void>.delayed(Duration(milliseconds: 120 * i), () {
        if (!mounted || responseGeneration != _fullResponseGeneration) return;
        setState(() {
          _blockRevisions[blockId] = (_blockRevisions[blockId] ?? 0) + 1;
        });
      }));
    }
  }

  void _finishSteering() {
    if (!mounted) return;
    setState(() => _steering = false);
  }

  Future<void> _reroll(DjLineupBlock block) async {
    if (_loadingBlockIds.contains(block.id)) return;
    final fullLoadGeneration = _fullLoadGeneration;
    final rerollGeneration = (_rerollGenerations[block.id] ?? 0) + 1;
    _rerollGenerations[block.id] = rerollGeneration;
    ++_fullResponseGeneration;
    setState(() {
      _loadingBlockIds.add(block.id);
      _blockErrors.remove(block.id);
    });

    try {
      final lineup = await _service.fetchLineup(
        _requestForFilters(
          block: block.id,
          excludeIds: block.tracks.map((track) => track.id).toList(),
          seed: _randomSeed(),
        ),
      );
      if (!mounted ||
          rerollGeneration != _rerollGenerations[block.id] ||
          fullLoadGeneration != _fullLoadGeneration) {
        return;
      }
      final replacement = lineup.blocks.where((item) => item.id == block.id);
      if (replacement.isEmpty) {
        throw const FormatException(
            'Reroll did not return the requested block');
      }
      setState(() {
        final index = _blocks.indexWhere((item) => item.id == block.id);
        if (index >= 0) {
          _blocks = List<DjLineupBlock>.of(_blocks)
            ..[index] = replacement.first;
        } else {
          _blocks = [
            for (final item in _visibleBlocks)
              if (item.id == block.id) replacement.first else item,
          ];
        }
        _blockRevisions[block.id] = (_blockRevisions[block.id] ?? 0) + 1;
        _loadingBlockIds.remove(block.id);
        // An empty swap is a success ("that's everyone here"), not a failure.
        // Only treat it as such while other sections still carry content.
        final othersHaveContent = _blocks.any(
          (item) => item.id != block.id && item.tracks.isNotEmpty,
        );
        if (replacement.first.tracks.isEmpty && othersHaveContent) {
          _emptySwapBlockIds.add(block.id);
        } else {
          _emptySwapBlockIds.remove(block.id);
        }
      });
      _announce('${block.title} updated');
    } catch (_) {
      if (!mounted ||
          rerollGeneration != _rerollGenerations[block.id] ||
          fullLoadGeneration != _fullLoadGeneration) {
        return;
      }
      setState(() {
        _loadingBlockIds.remove(block.id);
        _blockErrors[block.id] = "Swap didn't take. Try again.";
      });
    }
  }

  /// Toggles this block's pin. Optimistic: the pinned state flips immediately
  /// and rolls back with an inline snackbar if the request fails. On success
  /// the full lineup is refetched so the server-side envelope filtering shows
  /// up right away (per-section loading spinners render during the refetch).
  Future<void> _togglePin(DjLineupBlock block) async {
    if (_pendingPinBlockId != null || _loadingBlockIds.contains(block.id)) {
      return;
    }
    final wasPinned = _pinnedBlockId == block.id;
    setState(() => _pendingPinBlockId = block.id);

    try {
      if (wasPinned) {
        await _service.unpinBlock();
      } else {
        await _service.pinBlock(block.id);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _pendingPinBlockId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text(wasPinned ? "Couldn't unpin" : "Couldn't pin that vibe"),
        ),
      );
      return;
    }
    if (!mounted) return;

    // Optimistic flip while the refetch runs; the refetched lineup is the
    // authority and corrects any divergence.
    setState(() {
      _pinnedBlockId = wasPinned ? null : block.id;
      _pendingPinBlockId = null;
      _loadingBlockIds.addAll(_visibleBlocks.map((item) => item.id));
    });

    final loadGeneration = _fullLoadGeneration;
    try {
      final lineup =
          await _service.fetchLineup(_requestForFilters());
      if (!mounted || loadGeneration != _fullLoadGeneration) return;
      setState(() {
        _blocks = lineup.blocks;
        _pinnedBlockId = lineup.pinnedBlockId;
        _loadingBlockIds.clear();
        _blockErrors.clear();
        _emptySwapBlockIds.clear();
      });
      _announce(
        wasPinned ? 'Vibe unlocked' : 'Vibe locked: ${block.title}',
      );
    } catch (_) {
      if (!mounted || loadGeneration != _fullLoadGeneration) return;
      setState(() {
        _loadingBlockIds.clear();
        _refreshError = "Couldn't refresh the session.";
      });
    }
  }

  /// Unlock affordance on the pinned banner: DELETE then refetch.
  Future<void> _unlockFromBanner() async {
    final pinnedId = _pinnedBlockId;
    if (pinnedId == null) return;
    // The fallback must carry the pinned id, not the first visible block:
    // with the harmonic block leading the lineup, unlocking would otherwise
    // POST a pin for an unpinnable block instead of DELETEing the real one.
    await _togglePin(_visibleBlocks.firstWhere(
      (item) => item.id == pinnedId,
      orElse: () => DjLineupBlock(
        id: pinnedId,
        title: _titleOf(pinnedId),
        reason: '',
        tracks: const [],
      ),
    ));
  }

  /// Enqueues every track across all loaded blocks in visual order (block
  /// order, card order within each block) through the canonical QueueProvider
  /// path. Tracks already in the queue — including duplicates within the
  /// lineup itself — are skipped, matching append (playNext: false) semantics.
  Future<void> _enqueueSession() async {
    if (_isAnySectionLoading) return;
    final queue = context.read<QueueProvider>();
    _mutatingQueue = true;
    try {
      await _enqueueSessionThrough(queue);
    } finally {
      _mutatingQueue = false;
    }
  }

  Future<void> _enqueueSessionThrough(QueueProvider queue) async {
    // Seed the provider's view of the queue so pre-existing tracks aren't
    // re-added; a failed load falls back to an empty snapshot (append-only).
    await queue.loadQueue();
    final queuedIds = queue.queue.tracks
        .map((track) => track.playbackTrackId ?? track.id)
        .whereType<String>()
        .toSet();

    final pending = <DjLineupTrack>[];
    for (final block in _visibleBlocks) {
      for (final track in block.tracks) {
        final trackId = track.id.toString();
        if (!queuedIds.add(trackId)) continue; // already queued or duplicate
        pending.add(track);
      }
    }

    var enqueued = 0;
    for (final track in pending) {
      await queue.addToQueue([track.id.toString()], playNext: false);
      if (queue.error != null) break; // transport/5xx: stop and report partial
      enqueued++;
    }

    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (pending.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Everything here is already queued')),
      );
      return;
    }
    if (queue.error != null || enqueued < pending.length) {
      messenger.showSnackBar(
        SnackBar(content: Text('Queued $enqueued of ${pending.length} tracks')),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text('Session queued · $enqueued tracks')),
    );
  }

  Future<void> _enqueue(DjLineupTrack track, {bool playNext = false}) async {
    final queue = context.read<QueueProvider>();
    _mutatingQueue = true;
    try {
      await queue.addToQueue([track.id.toString()], playNext: playNext);
    } finally {
      _mutatingQueue = false;
    }
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    if (queue.error != null) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't add that track")),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(playNext ? 'Playing next' : 'Added to queue'),
      ),
    );
  }

  /// Card tap opens this sheet instead of enqueueing directly: browsing a rail
  /// must never be a misfire machine for queue additions (spec H4/H5).
  Future<void> _showTrackActions(DjLineupTrack track) async {
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
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    track.artist.isEmpty ? 'Unknown artist' : track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(sheetContext)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(
                          color: Theme.of(sheetContext)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.playlist_play),
              title: const Text('Play next'),
              subtitle: Text(track.title),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _enqueue(track, playNext: true);
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

  void _applyTextRequest() {
    _dismissCoachMark();
    unawaited(_markRequestSubmitted());
    _applyFilters(parseDjVibeText(_requestController.text));
  }

  /// Submits a suggestion chip through the exact typed-text pipeline: the chip
  /// text goes through [parseDjVibeText] as if the listener had typed it.
  void _applySuggestion(DjPromptSuggestion suggestion) {
    _requestController.text = suggestion.text;
    _applyTextRequest();
    if (mounted) _requestFocusNode.unfocus();
  }

  void _applyFilters(DjSessionFilters filters) {
    setState(() => _filters = filters);
    _loadAll();
  }

  void _clearEnergy() {
    _applyFilters(_filters.copyWith(clearEnergy: true));
  }

  void _clearQuery() {
    _requestController.clear();
    _applyFilters(_filters.copyWith(clearQuery: true));
  }

  void _focusRequestField() {
    _requestFocusNode.requestFocus();
  }

  void _announce(String message) {
    if (!mounted) return;
    setState(() {
      _announcement = message;
    });
  }

  /// Whether the user has ever submitted a request. The coach mark is
  /// suppressed entirely once a request has been submitted (spec).
  Future<void> _markRequestSubmitted() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_requestSubmittedKey, true);
    } catch (_) {
      // Preferences unavailable (e.g. widget tests): nothing to persist.
    }
  }

  Future<void> _maybeShowCoachMark() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final submittedBefore =
          prefs.getBool(_requestSubmittedKey) ?? false;
      if (!mounted ||
          submittedBefore ||
          (prefs.getBool(_coachMarkSeenKey) ?? false)) {
        return;
      }
      setState(() => _coachMarkVisible = true);
      await prefs.setBool(_coachMarkSeenKey, true);
    } catch (_) {
      // Preferences unavailable (e.g. widget tests): skip the coach mark.
    }
  }

  void _dismissCoachMark() {
    if (!_coachMarkVisible) return;
    setState(() => _coachMarkVisible = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            RefreshIndicator(
              onRefresh: () => _loadAll(),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                    sliver: SliverToBoxAdapter(child: _buildHeader(theme)),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                    sliver: SliverToBoxAdapter(child: _buildHeroPill(theme)),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                    sliver:
                        SliverToBoxAdapter(child: _buildRequestBar(theme)),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                    sliver: SliverToBoxAdapter(
                      child: _buildChipsRow(theme),
                    ),
                  ),
                  if (_refreshError.isNotEmpty)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      sliver: SliverToBoxAdapter(
                        child: _RefreshFailure(
                          message: _refreshError,
                          onRetry: () => _loadAll(),
                        ),
                      ),
                    ),
                  if (_pinnedBlockId != null)
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      sliver: SliverToBoxAdapter(
                        child: _PinnedBanner(
                          blockTitle: _titleOf(_pinnedBlockId!),
                          onUnlock: _unlockFromBanner,
                          enabled:
                              !_isPinBusy && !_isAnySectionLoading,
                        ),
                      ),
                    ),
                  if (_isEmptyLibrary)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: _EmptyLibraryState(),
                    )
                  else ...[
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
                      sliver: SliverToBoxAdapter(
                        child: Semantics(
                          liveRegion: true,
                          label: _announcement,
                          child: _LineupBlockSection(
                            block: _visibleBlocks[0],
                            isLoading:
                                _loadingBlockIds.contains(_visibleBlocks[0].id),
                            errorMessage: _blockErrors[_visibleBlocks[0].id],
                            showEmptySwapNote: _emptySwapBlockIds
                                .contains(_visibleBlocks[0].id),
                            revision:
                                _blockRevisions[_visibleBlocks[0].id] ?? 0,
                            onReroll: () => _reroll(_visibleBlocks[0]),
                            onTrackActivated: _showTrackActions,
                            onEnqueueTrack: (track) =>
                                _enqueue(track, playNext: false),
                            reducedMotion: reducedMotion,
                            isPinned:
                                _pinnedBlockId == _visibleBlocks[0].id,
                            pinPending:
                                _pendingPinBlockId == _visibleBlocks[0].id,
                            pinBlockedByOther: (_pendingPinBlockId != null &&
                                    _pendingPinBlockId !=
                                        _visibleBlocks[0].id) ||
                                (_pinnedBlockId != null &&
                                    _pinnedBlockId !=
                                        _visibleBlocks[0].id),
                            onTogglePin: () => _togglePin(_visibleBlocks[0]),
                          ),
                        ),
                      ),
                    ),
                    for (var i = 1; i < _visibleBlocks.length; i++)
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 32, 20, 0),
                        sliver: SliverToBoxAdapter(
                          child: Semantics(
                            liveRegion: true,
                            label: _announcement,
                            child: _LineupBlockSection(
                              block: _visibleBlocks[i],
                              isLoading: _loadingBlockIds
                                  .contains(_visibleBlocks[i].id),
                              errorMessage:
                                  _blockErrors[_visibleBlocks[i].id],
                              showEmptySwapNote: _emptySwapBlockIds
                                  .contains(_visibleBlocks[i].id),
                              revision:
                                  _blockRevisions[_visibleBlocks[i].id] ?? 0,
                              onReroll: () => _reroll(_visibleBlocks[i]),
                              onTrackActivated: _showTrackActions,
                              onEnqueueTrack: (track) =>
                                  _enqueue(track, playNext: false),
                              reducedMotion: reducedMotion,
                              isPinned:
                                  _pinnedBlockId == _visibleBlocks[i].id,
                              pinPending:
                                  _pendingPinBlockId == _visibleBlocks[i].id,
                              pinBlockedByOther:
                                  (_pendingPinBlockId != null &&
                                          _pendingPinBlockId !=
                                              _visibleBlocks[i].id) ||
                                      (_pinnedBlockId != null &&
                                          _pinnedBlockId !=
                                              _visibleBlocks[i].id),
                              onTogglePin: () =>
                                  _togglePin(_visibleBlocks[i]),
                            ),
                          ),
                        ),
                      ),
                    const SliverToBoxAdapter(child: _FooterSignOff()),
                    const SliverToBoxAdapter(
                      child: SizedBox(height: 48),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DJ Session', style: theme.textTheme.headlineMedium),
        const SizedBox(height: 4),
        Text(
          'Built from your library.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildHeroPill(ThemeData theme) {
    final busy = _steering;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Tooltip(
          message: 'Reroll the full lineup. Hold to request a vibe.',
          child: Semantics(
            button: true,
            label: 'Reroll session. Double-tap to reroll the full lineup. '
                'Long press to request a vibe.',
            key: const ValueKey('dj_reroll_session'),
            child: GestureDetector(
              onLongPress: () {
                _heroPressed = false;
                setState(() {});
                _focusRequestField();
              },
              onLongPressStart: (_) {
                HapticFeedback.mediumImpact();
                setState(() => _heroPressed = true);
              },
              onLongPressEnd: (_) {
                if (_heroPressed) setState(() => _heroPressed = false);
              },
              onLongPressCancel: () {
                if (_heroPressed) setState(() => _heroPressed = false);
              },
              child: AnimatedScale(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOutBack,
                scale: _heroPressed ? 0.97 : 1.0,
                child: SizedBox(
                  width: double.infinity,
                  height: 64,
                  child: FilledButton.icon(
                    key: const ValueKey('dj_hero_pill'),
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusLarge),
                      ),
                      textStyle: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                    onPressed: busy ? null : _onHeroTap,
                    icon: busy
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.4,
                              color: theme.colorScheme.onPrimary,
                            ),
                          )
                        : const Icon(Icons.autorenew, size: 24),
                    label: Text(busy ? 'Steering…' : 'Reroll session'),
                  ),
                ),
              ),
            ),
          ),
        ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 148,
              height: 56,
              child: OutlinedButton.icon(
                key: const ValueKey('dj_play_session'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.onSurface,
                  side: BorderSide(
                    color: theme.colorScheme.outlineVariant,
                    width: 1.4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                  ),
                ),
                onPressed: _isAnySectionLoading ? null : _enqueueSession,
                icon: const Icon(Icons.play_arrow, size: 24),
                label: Text(
                  'Play session',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color:
                        _isAnySectionLoading ? null : theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_coachMarkVisible) ...[
          const SizedBox(height: 8),
          Text(
            'Hold to ask for something specific.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  void _onHeroTap() {
    unawaited(HapticFeedback.mediumImpact());
    _dismissCoachMark();
    _loadAll(steering: true);
  }

  Widget _buildRequestBar(ThemeData theme) {
    return TextField(
      key: const ValueKey('dj_request_field'),
      controller: _requestController,
      focusNode: _requestFocusNode,
      textInputAction: TextInputAction.search,
      onChanged: (_) => setState(() {}),
      onSubmitted: (_) => _applyTextRequest(),
      decoration: InputDecoration(
        hintText: 'Request a vibe',
        prefixIcon: const Icon(Icons.auto_awesome),
        suffixIcon: IconButton(
          tooltip: 'Send request',
          icon: const Icon(Icons.arrow_forward),
          onPressed: _applyTextRequest,
        ),
        filled: true,
        fillColor: theme.colorScheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        ),
      ),
    );
  }

  Widget _buildChipsRow(ThemeData theme) {
    final activeFilterChips = <Widget>[
      if (_filters.energy != null)
        InputChip(
          label: Text('${_filters.energy!.chipLabel} energy'),
          onDeleted: _clearEnergy,
        ),
      if (_filters.query != null && _filters.query!.isNotEmpty)
        InputChip(label: Text('“${_filters.query}”'), onDeleted: _clearQuery),
    ];
    final showSuggestions =
        _requestController.text.trim().isEmpty && _filters.isEmpty;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (showSuggestions) ...[
                    for (final suggestion
                        in djPromptSuggestions(now: _clock())) ...[
                      ActionChip(
                        key: ValueKey('dj_suggestion_${suggestion.label}'),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        label: Text(suggestion.label),
                        onPressed: () => _applySuggestion(suggestion),
                      ),
                      const SizedBox(width: 8),
                    ],
                    VerticalDivider(
                      width: 17,
                      indent: 8,
                      endIndent: 8,
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ],
                  for (final preset in DjVibePreset.values) ...[
                    ActionChip(
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      backgroundColor: _isPresetActive(preset)
                          ? theme.colorScheme.primary.withValues(alpha: 0.18)
                          : null,
                      label: Text(preset.label),
                      onPressed: () {
                        _requestController.clear();
                        _applyFilters(djPresetFilters(preset));
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                  for (var i = 0; i < activeFilterChips.length; i++) ...[
                    activeFilterChips[i],
                    if (i < activeFilterChips.length - 1)
                      const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _isPresetActive(DjVibePreset preset) {
    final presetFilters = djPresetFilters(preset);
    return _filters.energy == presetFilters.energy &&
        (_filters.query == null || _filters.query!.isEmpty);
  }
}

class _LineupBlockSection extends StatelessWidget {
  const _LineupBlockSection({
    required this.block,
    required this.isLoading,
    required this.errorMessage,
    required this.showEmptySwapNote,
    required this.revision,
    required this.onReroll,
    required this.onTrackActivated,
    required this.onEnqueueTrack,
    required this.reducedMotion,
    required this.isPinned,
    required this.pinPending,
    required this.pinBlockedByOther,
    required this.onTogglePin,
  });

  final DjLineupBlock block;
  final bool isLoading;
  final String? errorMessage;
  final bool showEmptySwapNote;
  final int revision;
  final VoidCallback onReroll;
  final Future<void> Function(DjLineupTrack track) onTrackActivated;
  final Future<void> Function(DjLineupTrack track) onEnqueueTrack;
  final bool reducedMotion;
  final bool isPinned;
  final bool pinPending;
  final bool pinBlockedByOther;
  final VoidCallback onTogglePin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      block.title,
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      block.reason,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (block.detail.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        block.detail,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.8),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // The harmonic block cannot be pinned: POST /dj/pin validates
              // against the frozen three-theme enum and 400s on 'harmonic'.
              if (block.id != djHarmonicBlockId)
                _PinButton(
                  blockId: block.id,
                  isPinned: isPinned,
                  pending: pinPending,
                  disabled: pinBlockedByOther || isLoading,
                  onTogglePin: onTogglePin,
                ),
              Tooltip(
                message: 'Swap these tracks',
                child: TextButton.icon(
                  key: ValueKey('dj_swap_${block.id}'),
                  onPressed: isLoading ? null : onReroll,
                  icon: const Icon(Icons.autorenew, size: 20),
                  label: const Text('Swap'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (errorMessage != null)
          _InlineBlockFailure(message: errorMessage!, onRetry: onReroll)
        else if (isLoading && block.tracks.isEmpty)
          const _RailSkeleton()
        else if (block.tracks.isEmpty && showEmptySwapNote)
          const _EmptySwapNote()
        else if (block.tracks.isEmpty)
          const _EmptyBlockState()
        else
          AnimatedSwitcher(
            duration:
                Duration(milliseconds: reducedMotion ? 150 : 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              if (reducedMotion) {
                return FadeTransition(
                    opacity: animation, child: child);
              }
              return FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.04),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              );
            },
            child: KeyedSubtree(
              key: ValueKey('dj_lineup_${block.id}_$revision'),
              child: Opacity(
                opacity: isLoading ? 0.6 : 1.0,
                child: _TrackRail(
                  tracks: block.tracks,
                  onTrackActivated: onTrackActivated,
                  onEnqueueTrack: onEnqueueTrack,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Pin affordance in the section header, next to Swap. Outlined pin while
/// unpinned, filled pin plus a muted "Pinned" badge while pinned, spinner
/// while its request is in flight, and a disabled state while another block's
/// pin request is pending — the server allows only one active pin.
class _PinButton extends StatelessWidget {
  const _PinButton({
    required this.blockId,
    required this.isPinned,
    required this.pending,
    required this.disabled,
    required this.onTogglePin,
  });

  final String blockId;
  final bool isPinned;
  final bool pending;
  final bool disabled;
  final VoidCallback onTogglePin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        SizedBox(
          width: 36,
          height: 36,
          child: IconButton(
            key: ValueKey('dj_pin_$blockId'),
            tooltip: isPinned ? 'Unlock vibe' : 'Pin this vibe',
            onPressed: pending || disabled ? null : onTogglePin,
            icon: pending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                    size: 20,
                  ),
          ),
        ),
        if (isPinned) ...[
          const SizedBox(height: 2),
          Container(
            key: ValueKey('dj_pinned_badge_$blockId'),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
            ),
            child: Text(
              'Pinned',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Slim muted banner between the chips area and the first section announcing
/// the active pin with an inline Unlock action. Deliberately not error red.
class _PinnedBanner extends StatelessWidget {
  const _PinnedBanner({
    required this.blockTitle,
    required this.onUnlock,
    required this.enabled,
  });

  final String blockTitle;
  final VoidCallback onUnlock;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('dj_pinned_banner'),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: AppTheme.surfaceRaised,
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      ),
      child: Row(
        children: [
          Icon(
            Icons.push_pin,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Vibe locked: $blockTitle',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('dj_unlock_pin'),
            onPressed: enabled ? onUnlock : null,
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.orange,
              textStyle: const TextStyle(
                fontWeight: FontWeight.w800,
                color: AppTheme.orange,
              ),
            ),
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
  }
}

class _RailSkeleton extends StatelessWidget {
  const _RailSkeleton();

  @override
  Widget build(BuildContext context) {
    final cardWidth = _cardWidthOf(context);
    return SizedBox(
      height: 212,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: 3,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) => SizedBox(
          width: cardWidth,
          child: _SkeletonCard(),
        ),
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const placeholder = AppTheme.surfaceRaised;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              height: 148,
              decoration: BoxDecoration(
                color: placeholder,
                borderRadius:
                    BorderRadius.circular(AppTheme.radiusMedium),
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: 96,
              height: 12,
              decoration: BoxDecoration(
                color: placeholder,
                borderRadius:
                    BorderRadius.circular(AppTheme.radiusSmall),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: 64,
              height: 10,
              color: placeholder,
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackRail extends StatelessWidget {
  const _TrackRail({
    required this.tracks,
    required this.onTrackActivated,
    required this.onEnqueueTrack,
  });

  final List<DjLineupTrack> tracks;
  final Future<void> Function(DjLineupTrack track) onTrackActivated;
  final Future<void> Function(DjLineupTrack track) onEnqueueTrack;

  @override
  Widget build(BuildContext context) {
    // Rail height derives from content (IntrinsicHeight) so large font scales
    // grow the cards instead of clipping them (spec H12). Blocks carry at most
    // perBlock (5) tracks, so an unvirtualized row stays cheap.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.only(right: 4),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < tracks.length; i++) ...[
                if (i > 0) const SizedBox(width: 12),
                SizedBox(
                  width: _cardWidthOf(context),
                  child: _DjTrackCard(
                    key: ValueKey('dj_track_${tracks[i].id}'),
                    track: tracks[i],
                    onTap: () => onTrackActivated(tracks[i]),
                    onEnqueue: () => onEnqueueTrack(tracks[i]),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

double _cardWidthOf(BuildContext context) {
  return (MediaQuery.sizeOf(context).width * 0.46)
      .clamp(156.0, 200.0)
      .toDouble();
}

class _DjTrackCard extends StatelessWidget {
  const _DjTrackCard({
    super.key,
    required this.track,
    required this.onTap,
    required this.onEnqueue,
  });

  final DjLineupTrack track;
  final VoidCallback onTap;
  final VoidCallback onEnqueue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: '${track.title} by ${track.artist}. Tap for actions. '
          'Add button queues this track.',
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: double.infinity,
                  height: 148,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _TrackArtwork(track: track),
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: IconButton.filledTonal(
                            tooltip: 'Add to queue',
                            icon: const Icon(Icons.playlist_add, size: 22),
                            onPressed: onEnqueue,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist.isEmpty ? 'Unknown artist' : track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (track.djMeta.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    track.djMeta.join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackArtwork extends StatelessWidget {
  const _TrackArtwork({required this.track});

  final DjLineupTrack track;

  @override
  Widget build(BuildContext context) {
    final artworkUrl = track.artworkUrl;
    final theme = Theme.of(context);
    final placeholder = Container(
      color: theme.colorScheme.secondaryContainer,
      alignment: Alignment.center,
      child: Icon(
        Icons.graphic_eq,
        size: 40,
        color: theme.colorScheme.onSecondaryContainer,
      ),
    );
    if (artworkUrl == null || artworkUrl.isEmpty) return placeholder;
    return Image.network(
      artworkUrl,
      fit: BoxFit.cover,
      errorBuilder: (_, __, ___) => placeholder,
    );
  }
}

class _InlineBlockFailure extends StatelessWidget {
  const _InlineBlockFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  /// Dark red failure-panel background. Kept as a literal because AppTheme
  /// has no dark-red surface token yet (its [AppTheme.error] is a bright
  /// accent meant for icons/borders, not panel fills). If a token is added,
  /// replace this literal with it.
  static const Color _panelColor = Color(0xFF3A0E0C);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Near-white message text (~12:1) and a bright retry link (~4.9:1) both
    // clear the 4.5:1 contrast bar against the dark red panel.
    const panelColor = _panelColor;
    return Container(
      constraints: const BoxConstraints(minHeight: 88),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        color: panelColor,
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.95),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.orange,
              textStyle: const TextStyle(
                fontWeight: FontWeight.w800,
                color: AppTheme.orange,
              ),
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _RefreshFailure extends StatelessWidget {
  const _RefreshFailure({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => _InlineBlockFailure(
        message: message,
        onRetry: onRetry,
      );
}

class _EmptySwapNote extends StatelessWidget {
  const _EmptySwapNote();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 88,
      child: Center(
        child: Text(
          "That's everyone here for now.",
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }
}

class _EmptyBlockState extends StatelessWidget {
  const _EmptyBlockState();

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 88,
        child: Center(
          child: Text(
            'Nothing matches that here.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
}

class _FooterSignOff extends StatelessWidget {
  const _FooterSignOff();

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 24dp bottom padding keeps breathing room without the dead void QA
      // flagged on the emulator.
      padding: const EdgeInsets.fromLTRB(20, 24, 20, AppTheme.space5),
      child: Text(
        "That's the set. Reroll anytime.",
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      ),
    );
  }
}

class _EmptyLibraryState extends StatelessWidget {
  const _EmptyLibraryState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.library_music_outlined,
              size: 56,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'Your library is empty',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Add some tracks and the session writes itself.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => GoRouter.of(context).go('/library'),
              icon: const Icon(Icons.library_music),
              label: const Text('Add tracks'),
            ),
          ],
        ),
      ),
    );
  }
}


