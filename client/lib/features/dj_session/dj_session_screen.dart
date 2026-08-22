import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
  static const _fallbackBlocks = [
    DjLineupBlock(
      id: 'on-repeat',
      title: 'On Repeat',
      reason: 'Tracks you keep coming back to',
      tracks: [],
    ),
    DjLineupBlock(
      id: 'flashback',
      title: 'Flashback',
      reason: 'A familiar turn from your archive',
      tracks: [],
    ),
    DjLineupBlock(
      id: 'fresh-finds',
      title: 'Fresh Finds',
      reason: 'A new lane in your library',
      tracks: [],
    ),
  ];

  late final DjSessionDataSource _service;
  late final int Function() _randomSeed;
  late final TextEditingController _requestController;
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
  String? _refreshError;

  @override
  void initState() {
    super.initState();
    _service = widget.service ?? DjSessionService(context.read<ApiClient>());
    _randomSeed = widget.randomSeed ?? () => Random().nextInt(1 << 31);
    _requestController = TextEditingController();
    _loadAll();
  }

  @override
  void dispose() {
    _requestController.dispose();
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

  Future<void> _loadAll() async {
    ++_fullLoadGeneration;
    final responseGeneration = ++_fullResponseGeneration;
    if (mounted) {
      setState(() {
        _loadingAll = true;
        _refreshError = null;
        _loadingBlockIds.addAll(_visibleBlocks.map((block) => block.id));
      });
    }

    try {
      final lineup = await _service.fetchLineup(_requestForFilters());
      if (!mounted || responseGeneration != _fullResponseGeneration) return;
      setState(() {
        _blocks = lineup.blocks;
        _loadingAll = false;
        _loadedAllOnce = true;
        _loadingBlockIds.clear();
        _blockErrors.clear();
      });
    } catch (_) {
      if (!mounted || responseGeneration != _fullResponseGeneration) return;
      setState(() {
        _loadingAll = false;
        _loadingBlockIds.clear();
        if (_blocks.isEmpty) {
          _blocks = _fallbackBlocks;
          for (final block in _fallbackBlocks) {
            _blockErrors[block.id] = 'Could not load this lineup block.';
          }
        } else {
          _refreshError = 'Could not refresh the full lineup.';
        }
      });
    }
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
    } catch (_) {
      if (!mounted ||
          rerollGeneration != _rerollGenerations[block.id] ||
          fullLoadGeneration != _fullLoadGeneration) {
        return;
      }
      setState(() {
        _loadingBlockIds.remove(block.id);
        _blockErrors[block.id] = 'Could not reroll this block.';
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
        const SnackBar(content: Text('Could not add to queue')),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(playNext ? 'Queued to play next' : 'Added to queue'),
      ),
    );
  }

  Future<void> _showTrackActions(DjLineupTrack track) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListTile(
          leading: const Icon(Icons.playlist_play),
          title: const Text('Play next'),
          subtitle: Text(track.title),
          onTap: () {
            Navigator.of(sheetContext).pop();
            _enqueue(track, playNext: true);
          },
        ),
      ),
    );
  }

  void _applyTextRequest() {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadAll,
          child: CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                sliver: SliverToBoxAdapter(child: _buildHeader(theme)),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(child: _buildRequestBar(theme)),
              ),
              if (!_filters.isEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  sliver: SliverToBoxAdapter(child: _buildActiveFilters()),
                ),
              if (_refreshError != null)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  sliver: SliverToBoxAdapter(
                    child: _RefreshFailure(
                      message: _refreshError!,
                      onRetry: _loadAll,
                    ),
                  ),
                ),
              if (_isEmptyLibrary)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: _EmptyLibraryState(),
                )
              else
                SliverList.separated(
                  itemCount: _visibleBlocks.length,
                  itemBuilder: (context, index) {
                    final block = _visibleBlocks[index];
                    return Padding(
                      padding: EdgeInsets.fromLTRB(
                        20,
                        index == 0 ? 20 : 8,
                        20,
                        16,
                      ),
                      child: _LineupBlockSection(
                        block: block,
                        isLoading: _loadingBlockIds.contains(block.id),
                        errorMessage: _blockErrors[block.id],
                        revision: _blockRevisions[block.id] ?? 0,
                        onReroll: () => _reroll(block),
                        onTapTrack: _enqueue,
                        onLongPressTrack: _showTrackActions,
                      ),
                    );
                  },
                  separatorBuilder: (_, __) => const SizedBox(height: 2),
                ),
            ],
          ),
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
          'made for you from your library',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildRequestBar(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _requestController,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _applyTextRequest(),
          decoration: InputDecoration(
            hintText: 'ask for a vibe…',
            prefixIcon: const Icon(Icons.auto_awesome),
            suffixIcon: IconButton(
              tooltip: 'Apply DJ request',
              icon: const Icon(Icons.arrow_forward),
              onPressed: _applyTextRequest,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final preset in DjVibePreset.values)
              ActionChip(
                label: Text(preset.label),
                onPressed: () {
                  _requestController.clear();
                  _applyFilters(djPresetFilters(preset));
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildActiveFilters() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (_filters.energy != null)
          InputChip(
            label: Text('Energy: ${_filters.energy!.label}'),
            onDeleted: _clearEnergy,
          ),
        if (_filters.query != null && _filters.query!.isNotEmpty)
          InputChip(
            label: Text('Vibe: ${_filters.query}'),
            onDeleted: _clearQuery,
          ),
      ],
    );
  }
}

class _LineupBlockSection extends StatelessWidget {
  const _LineupBlockSection({
    required this.block,
    required this.isLoading,
    required this.errorMessage,
    required this.revision,
    required this.onReroll,
    required this.onTapTrack,
    required this.onLongPressTrack,
  });

  final DjLineupBlock block;
  final bool isLoading;
  final String? errorMessage;
  final int revision;
  final VoidCallback onReroll;
  final Future<void> Function(DjLineupTrack track) onTapTrack;
  final Future<void> Function(DjLineupTrack track) onLongPressTrack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(block.title, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 2),
                  Text(
                    block.reason,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              key: ValueKey('dj_reroll_${block.id}'),
              tooltip: 'Reroll ${block.title}',
              icon: const Icon(Icons.refresh),
              onPressed: isLoading ? null : onReroll,
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (errorMessage != null)
          _InlineBlockFailure(message: errorMessage!, onRetry: onReroll)
        else if (isLoading && block.tracks.isEmpty)
          const SizedBox(
            height: 168,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (block.tracks.isEmpty)
          const _EmptyBlockState()
        else
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 260),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0.04, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            ),
            child: KeyedSubtree(
              key: ValueKey('dj_lineup_${block.id}_$revision'),
              child: _TrackRail(
                tracks: block.tracks,
                onTapTrack: onTapTrack,
                onLongPressTrack: onLongPressTrack,
              ),
            ),
          ),
      ],
    );
  }
}

class _TrackRail extends StatelessWidget {
  const _TrackRail({
    required this.tracks,
    required this.onTapTrack,
    required this.onLongPressTrack,
  });

  final List<DjLineupTrack> tracks;
  final Future<void> Function(DjLineupTrack track) onTapTrack;
  final Future<void> Function(DjLineupTrack track) onLongPressTrack;

  @override
  Widget build(BuildContext context) {
    final cardWidth = (MediaQuery.sizeOf(context).width * 0.48)
        .clamp(156.0, 224.0)
        .toDouble();
    return SizedBox(
      height: 214,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: tracks.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) => SizedBox(
          width: cardWidth,
          child: _DjTrackCard(
            track: tracks[index],
            onTap: () => onTapTrack(tracks[index]),
            onLongPress: () => onLongPressTrack(tracks[index]),
          ),
        ),
      ),
    );
  }
}

class _DjTrackCard extends StatelessWidget {
  const _DjTrackCard({
    required this.track,
    required this.onTap,
    required this.onLongPress,
  });

  final DjLineupTrack track;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label:
          '${track.title} by ${track.artist}. Tap to add to queue. Long press to play next.',
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          key: ValueKey('dj_track_${track.id}'),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _TrackArtwork(track: track)),
                const SizedBox(height: 10),
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  track.artist.isEmpty ? 'Unknown artist' : track.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (track.djMeta.isNotEmpty) ...[
                  const SizedBox(height: 5),
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
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
            'No matching tracks in this block yet.',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      );
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
              'Your DJ session starts with your library',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Add a few tracks, then pull to refresh for a made-for-you lineup.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
