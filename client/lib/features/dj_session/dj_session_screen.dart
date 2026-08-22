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
  });

  final DjSessionDataSource? service;
  final int Function()? randomSeed;

  @override
  State<DjSessionScreen> createState() => _DjSessionScreenState();
}

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
  late final TextEditingController _requestController;
  final FocusNode _requestFocusNode = FocusNode();
  DjSessionFilters _filters = const DjSessionFilters();
  List<DjLineupBlock> _blocks = const [];
  final Set<String> _loadingBlockIds = {};
  final Map<String, String> _blockErrors = {};
  final Map<String, int> _blockRevisions = {};

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

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? DjSessionService(context.read<ApiClient>());
    _randomSeed = widget.randomSeed ?? () => Random().nextInt(1 << 31);
    _requestController = TextEditingController();
    _loadAll();
    _maybeShowCoachMark();
  }

  @override
  void dispose() {
    _requestController.dispose();
    _requestFocusNode.dispose();
    super.dispose();
  }

  List<DjLineupBlock> get _visibleBlocks =>
      _blocks.isEmpty ? _fallbackBlocks : _blocks;

  bool get _isEmptyLibrary =>
      !_loadingAll &&
      _blockErrors.isEmpty &&
      _loadedAllOnce &&
      _blocks.every((block) => block.tracks.isEmpty);

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
        _loadingAll = false;
        _loadedAllOnce = true;
        _loadingBlockIds.clear();
        _blockErrors.clear();
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

  Future<void> _enqueue(DjLineupTrack track, {bool playNext = false}) async {
    final queue = context.read<QueueProvider>();
    await queue.addToQueue([track.id.toString()], playNext: playNext);
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
                            revision:
                                _blockRevisions[_visibleBlocks[0].id] ?? 0,
                            onReroll: () => _reroll(_visibleBlocks[0]),
                            onTrackActivated: _showTrackActions,
                            onEnqueueTrack: (track) =>
                                _enqueue(track, playNext: false),
                            reducedMotion: reducedMotion,
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
                              revision:
                                  _blockRevisions[_visibleBlocks[i].id] ?? 0,
                              onReroll: () => _reroll(_visibleBlocks[i]),
                              onTrackActivated: _showTrackActions,
                              onEnqueueTrack: (track) =>
                                  _enqueue(track, playNext: false),
                              reducedMotion: reducedMotion,
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
        Tooltip(
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
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
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
    required this.revision,
    required this.onReroll,
    required this.onTrackActivated,
    required this.onEnqueueTrack,
    required this.reducedMotion,
  });

  final DjLineupBlock block;
  final bool isLoading;
  final String? errorMessage;
  final int revision;
  final VoidCallback onReroll;
  final Future<void> Function(DjLineupTrack track) onTrackActivated;
  final Future<void> Function(DjLineupTrack track) onEnqueueTrack;
  final bool reducedMotion;

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
                  ],
                ),
              ),
              const SizedBox(width: 8),
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

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 88),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        color: Theme.of(context).colorScheme.errorContainer,
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline),
          const SizedBox(width: 10),
          Expanded(child: Text(message)),
          TextButton(onPressed: onRetry, child: const Text('Retry')),
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
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 0),
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


