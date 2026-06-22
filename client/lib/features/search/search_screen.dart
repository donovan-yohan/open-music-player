import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/discovery/discovery_models.dart';
import '../../core/discovery/discovery_service.dart';
import '../../models/track.dart';
import '../../providers/queue_provider.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _queryController = TextEditingController();
  final Set<String> _pendingCandidateKeys = <String>{};
  Timer? _debounceTimer;
  Timer? _pollTimer;

  late DiscoveryService _discoveryService;
  bool _didPrimeQueue = false;
  bool _isPollingQueue = false;

  DiscoverySearchResponse? _response;
  int _searchRequestSerial = 0;
  bool _isSearching = false;
  String _query = '';
  String? _searchError;

  // Assistive mode: the same search entry, switched to call the grounded AI
  // assist endpoint. Default stays plain discovery search so the fallback path
  // is always one tap away and never depends on the model being configured.
  bool _assistMode = false;
  DiscoveryAssistResponse? _assistResponse;
  int _assistRequestSerial = 0;
  bool _isAsking = false;
  String _askedPrompt = '';
  String? _assistError;

  // A prompt that begins with an absolute http(s) URL is routed to the assist
  // endpoint even from Search mode: its direct-URL resolver grounds the link
  // into a queueable candidate without the user rewriting it, and that path
  // works even when the model is disabled.
  static final RegExp _urlPrompt = RegExp(r'^https?://', caseSensitive: false);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _discoveryService = DiscoveryService(context.read<ApiClient>());
    if (!_didPrimeQueue) {
      _didPrimeQueue = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _refreshQueue(force: true);
      });
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    if (_assistMode) {
      // Assist calls cost a model round-trip, so they never fire on keystroke
      // debounce — only on explicit submit. Clearing the field clears the
      // grounded result so a stale answer never lingers under an empty prompt,
      // and bumps the serial so any in-flight request can neither resurrect a
      // result nor leave the spinner stuck under the now-empty box.
      _debounceTimer?.cancel();
      if (value.trim().isEmpty) {
        setState(_resetAssist);
      } else {
        setState(() {});
      }
      return;
    }

    final next = value.trim();
    _debounceTimer?.cancel();
    if (next.isEmpty) {
      setState(_resetSearch);
      return;
    }

    setState(() {});
    _debounceTimer = Timer(const Duration(milliseconds: 350), () {
      if (next == _query) return;
      _runSearch(query: next);
    });
  }

  Future<void> _runSearch({String? query}) async {
    final searchText = (query ?? _queryController.text).trim();
    _debounceTimer?.cancel();
    final requestId = ++_searchRequestSerial;

    if (searchText.isEmpty) {
      setState(() {
        _query = '';
        _response = null;
        _searchError = null;
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _query = searchText;
      _isSearching = true;
      _searchError = null;
    });

    try {
      final response = await _discoveryService.search(searchText);
      if (!mounted ||
          requestId != _searchRequestSerial ||
          _query != searchText) {
        return;
      }
      setState(() {
        _response = response;
      });
    } catch (error) {
      if (!mounted ||
          requestId != _searchRequestSerial ||
          _query != searchText) {
        return;
      }
      setState(() {
        _searchError = _friendlyApiError(error);
      });
    } finally {
      if (mounted && requestId == _searchRequestSerial) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  // Tear down a mode's transient view state in one place: bump its request
  // serial so any in-flight response is ignored on completion, then clear its
  // result/error/prompt/spinner. Callers wrap these in setState. This is the
  // single source of truth the mode toggle, clear, and fallback paths all route
  // through, so the "inactive mode is fully reset" invariant cannot drift.
  void _resetAssist() {
    _assistRequestSerial++;
    _assistResponse = null;
    _assistError = null;
    _askedPrompt = '';
    _isAsking = false;
  }

  void _resetSearch() {
    _searchRequestSerial++;
    _response = null;
    _searchError = null;
    _query = '';
    _isSearching = false;
  }

  /// Route an explicit submit. Assist mode (or a pasted URL from search mode)
  /// goes to the grounded assist endpoint; everything else is plain discovery
  /// search. Switching to assist on a pasted URL is the only implicit mode
  /// change, and it never queues/downloads — it only resolves a candidate.
  void _onSubmit(String value) {
    final text = value.trim();
    if (text.isEmpty) return;
    if (_assistMode || _urlPrompt.hasMatch(text)) {
      if (!_assistMode) setState(() => _assistMode = true);
      _runAssist(prompt: text);
    } else {
      _runSearch(query: text);
    }
  }

  void _setAssistMode(bool enabled) {
    if (enabled == _assistMode) return;
    _debounceTimer?.cancel();
    setState(() {
      _assistMode = enabled;
      // Drop the now-inactive mode's results so a stale answer can never render
      // under the other mode's input, and invalidate its in-flight request. The
      // typed prompt is intentionally carried across; only results are cleared,
      // so the box and what is shown can never contradict each other.
      if (enabled) {
        _resetSearch();
      } else {
        _resetAssist();
      }
    });
  }

  /// Fall back from a disabled/failing assistant to normal discovery search,
  /// reusing the prompt the user already typed. This is the guarantee that AI
  /// being off or erroring never strands the user.
  void _searchDirectly() {
    final prompt =
        _askedPrompt.isNotEmpty ? _askedPrompt : _queryController.text.trim();
    setState(() {
      _assistMode = false;
      _resetAssist();
    });
    if (prompt.isNotEmpty) {
      _queryController.text = prompt;
      _runSearch(query: prompt);
    }
  }

  Future<void> _runAssist({String? prompt}) async {
    final text = (prompt ?? _queryController.text).trim();
    _debounceTimer?.cancel();
    if (text.isEmpty) {
      setState(_resetAssist);
      return;
    }
    // A monotonic serial (mirroring _runSearch) is the completion guard, not
    // prompt equality: it guarantees a superseded request always releases the
    // spinner and can never overwrite a newer result, even on resubmit of the
    // same prompt or a clear mid-flight.
    final requestId = ++_assistRequestSerial;

    setState(() {
      _askedPrompt = text;
      _isAsking = true;
      _assistError = null;
    });

    try {
      final response = await _discoveryService.assist(text);
      if (!mounted || requestId != _assistRequestSerial) return;
      setState(() {
        _assistResponse = response;
      });
    } catch (error) {
      if (!mounted || requestId != _assistRequestSerial) return;
      // A transport failure (network/older backend without the route) is not a
      // model "disabled" envelope: surface it as an assist error that still
      // offers the search-directly fallback.
      setState(() {
        _assistResponse = null;
        _assistError = _friendlyApiError(error);
      });
    } finally {
      if (mounted && requestId == _assistRequestSerial) {
        setState(() {
          _isAsking = false;
        });
      }
    }
  }

  Future<void> _queueCandidate(DiscoveryCandidate candidate) async {
    final key = _candidateKey(candidate);
    final provider = context.read<QueueProvider>();
    if (!candidate.downloadable ||
        _pendingCandidateKeys.contains(key) ||
        _queuedTrackFor(provider, candidate) != null) {
      return;
    }

    setState(() {
      _pendingCandidateKeys.add(key);
      _searchError = null;
    });
    _ensurePolling();

    try {
      await provider.addSourceCandidate(candidate);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _searchError = _friendlyApiError(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _pendingCandidateKeys.remove(key);
        });
        _ensurePolling();
      }
    }
  }

  Future<void> _refreshQueue({bool force = false}) async {
    if (!mounted || _isPollingQueue) return;
    final provider = context.read<QueueProvider>();
    if (!force && !_queueHasActiveWork(provider)) {
      _ensurePolling();
      return;
    }

    _isPollingQueue = true;
    try {
      await provider.loadQueue();
    } finally {
      _isPollingQueue = false;
      if (mounted) {
        _ensurePolling();
      } else {
        _pollTimer?.cancel();
        _pollTimer = null;
      }
    }
  }

  void _ensurePolling() {
    if (!mounted) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    final provider = context.read<QueueProvider>();
    if (!_queueHasActiveWork(provider)) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      _refreshQueue();
    });
  }

  bool _queueHasActiveWork(QueueProvider provider) {
    if (_pendingCandidateKeys.isNotEmpty) return true;
    return provider.queue.tracks.any(
      (track) =>
          track.queueStatus == TrackQueueStatus.pending ||
          track.queueStatus == TrackQueueStatus.downloading,
    );
  }

  Track? _queuedTrackFor(QueueProvider provider, DiscoveryCandidate candidate) {
    final key = _candidateKey(candidate);
    for (final track in provider.queue.tracks) {
      if (track.sourceCandidateId != null && track.sourceCandidateId == key) {
        return track;
      }
      if (track.sourceUrl != null && track.sourceUrl == candidate.sourceUrl) {
        return track;
      }
    }
    return null;
  }

  String _candidateKey(DiscoveryCandidate candidate) {
    return candidate.candidateId.isNotEmpty
        ? candidate.candidateId
        : candidate.sourceUrl;
  }

  @override
  Widget build(BuildContext context) {
    final queueProvider = context.watch<QueueProvider>();
    final queueError = queueProvider.error;
    final modeError = _assistMode ? _assistError : _searchError;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Mobile Discovery',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh queue status',
            onPressed: () => _refreshQueue(force: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            if (_assistMode && _askedPrompt.isNotEmpty)
              _runAssist(prompt: _askedPrompt)
            else if (!_assistMode && _query.isNotEmpty)
              _runSearch(),
            _refreshQueue(force: true),
          ]);
        },
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
          children: [
            _buildSearchBox(),
            const SizedBox(height: 10),
            _buildModeToggle(),
            // A queue-load error is only shown when the active mode is otherwise
            // clean, so the mode's own error card stays the primary message.
            if (modeError == null && queueError != null)
              _buildErrorCard(queueError, () => _refreshQueue(force: true)),
            const SizedBox(height: 12),
            if (_assistMode)
              ..._buildAssistBody(queueProvider)
            else
              ..._buildSearchModeBody(queueProvider),
            const SizedBox(height: 16),
            _buildQueueAffordance(queueProvider),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildSearchModeBody(QueueProvider queueProvider) {
    return [
      if (_searchError != null) _buildErrorCard(_searchError!, _runSearch),
      if (_response != null) _buildProviderRow(_response!.providers),
      const SizedBox(height: 12),
      _buildResultsSection(queueProvider),
    ];
  }

  Widget _buildModeToggle() {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments: const [
          ButtonSegment<bool>(
            value: false,
            icon: Icon(Icons.travel_explore, size: 18),
            label: Text('Search'),
          ),
          ButtonSegment<bool>(
            value: true,
            icon: Icon(Icons.auto_awesome, size: 18),
            label: Text('Assist'),
          ),
        ],
        selected: {_assistMode},
        onSelectionChanged: (selection) => _setAssistMode(selection.first),
      ),
    );
  }

  Widget _buildSearchBox() {
    return TextField(
      key: const ValueKey('search_assist_input'),
      controller: _queryController,
      minLines: 1,
      maxLines: _assistMode ? 3 : 1,
      textInputAction:
          _assistMode ? TextInputAction.go : TextInputAction.search,
      onChanged: _onQueryChanged,
      onSubmitted: _onSubmit,
      decoration: InputDecoration(
        labelText: _assistMode
            ? 'Ask for a song or paste a link'
            : 'Search songs, artists, albums, or sources',
        hintText: _assistMode
            ? 'that live Porter Robinson Shelter from YouTube...'
            : 'iPod Touch, Ninajirachi, live set...',
        prefixIcon:
            Icon(_assistMode ? Icons.auto_awesome : Icons.travel_explore),
        suffixIcon: _queryController.text.isNotEmpty
            ? IconButton(
                tooltip: _assistMode ? 'Clear prompt' : 'Clear search',
                onPressed: () {
                  _queryController.clear();
                  _onQueryChanged('');
                },
                icon: const Icon(Icons.clear),
              )
            : null,
        border: const OutlineInputBorder(),
      ),
    );
  }

  List<Widget> _buildAssistBody(QueueProvider queueProvider) {
    if (_assistError != null) {
      return [
        _buildAssistStatusBanner(
          icon: Icons.error_outline,
          message: _assistError!,
          tone: _AssistTone.error,
          showRetry: true,
        ),
      ];
    }

    if (_isAsking) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    final response = _assistResponse;
    if (response == null) {
      return [
        _buildEmptyPanel(
          icon: Icons.auto_awesome,
          title: 'Ask for a song or paste a link',
          body:
              'Describe what you want — "that live Porter Robinson Shelter from YouTube" — or paste a YouTube/SoundCloud link. Results are grounded in your real sources, never invented by the model.',
        ),
      ];
    }

    final widgets = <Widget>[];

    // Status banners explain a degraded model and always keep a one-tap path
    // back to normal discovery search.
    if (response.isDisabled) {
      widgets.add(
        _buildAssistStatusBanner(
          icon: Icons.info_outline,
          message: response.assistantText.isNotEmpty
              ? response.assistantText
              : 'AI assist is not configured. You can still search directly or paste a YouTube/SoundCloud link.',
          tone: _AssistTone.info,
        ),
      );
    } else if (response.isError) {
      widgets.add(
        _buildAssistStatusBanner(
          icon: Icons.error_outline,
          message: response.assistantText.isNotEmpty
              ? response.assistantText
              : 'The assistant is unavailable right now. You can still search directly or paste a link.',
          tone: _AssistTone.error,
          showRetry: true,
        ),
      );
    } else if (response.assistantText.isNotEmpty) {
      widgets.add(
        _buildAssistantTextCard(
          response.assistantText,
          showProvenanceNote: response.hasGroundedResults,
        ),
      );
    }

    final clarification = response.clarification;
    if (clarification != null && clarification.question.isNotEmpty) {
      widgets.add(_buildClarificationCard(clarification));
    }

    if (response.caveats.isNotEmpty) {
      widgets.add(_buildCaveatsCard(response.caveats));
    }

    final providers =
        response.search?.providers ?? const <DiscoveryProviderSummary>[];
    if (providers.isNotEmpty) {
      widgets.add(_buildProviderRow(providers));
    }

    // Grounded direct-URL candidates (resolver output). Each reuses the same
    // result tile and its explicit queue control as normal search — nothing is
    // ever auto-queued.
    if (response.candidates.isNotEmpty) {
      widgets.add(const SizedBox(height: 8));
      widgets.add(_buildSectionHeader(Icons.link, 'Direct link'));
      for (final candidate in response.candidates) {
        widgets.add(_buildResultTile(queueProvider, candidate));
      }
    }

    // Grounded provider search sections (tracks / artists / albums / sources).
    final sections =
        response.search?.sections ?? const <DiscoverySearchSection>[];
    for (final section in sections) {
      widgets.add(const SizedBox(height: 8));
      widgets.add(_buildSearchSection(queueProvider, section));
    }

    // Honest empty state: the assistant ran but could ground nothing actionable.
    if (response.isOk &&
        !response.hasGroundedResults &&
        clarification == null) {
      widgets.add(
        _buildEmptyPanel(
          icon: Icons.search_off,
          title: 'No grounded sources',
          body:
              'The assistant could not find queueable sources for that. Try adding an artist, title, or a direct link.',
        ),
      );
    }

    return widgets;
  }

  Widget _buildAssistantTextCard(
    String text, {
    required bool showProvenanceNote,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('assist_text_card'),
      margin: const EdgeInsets.only(bottom: 4),
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.auto_awesome, size: 20, color: colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: const TextStyle(height: 1.3)),
                  // The provenance note only appears when grounded candidates
                  // actually follow, so it never promises results that the
                  // honest "no grounded sources" empty state then contradicts.
                  if (showProvenanceNote) ...[
                    const SizedBox(height: 4),
                    Text(
                      'AI-assisted. Candidates below come from your sources, not the model.',
                      style: TextStyle(
                        fontSize: 11,
                        color: colorScheme.onSurfaceVariant,
                      ),
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

  Widget _buildAssistStatusBanner({
    required IconData icon,
    required String message,
    required _AssistTone tone,
    bool showRetry = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final background = tone == _AssistTone.error
        ? colorScheme.errorContainer
        : colorScheme.secondaryContainer;
    final foreground = tone == _AssistTone.error
        ? colorScheme.onErrorContainer
        : colorScheme.onSecondaryContainer;
    return Card(
      key: const ValueKey('assist_status_banner'),
      color: background,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: foreground),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(message, style: TextStyle(color: foreground)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Wrap (not Row) so Retry + Search directly reflow instead of
            // overflowing the narrow mobile-web viewport when both are present.
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: [
                if (showRetry)
                  TextButton(
                    onPressed: () => _runAssist(prompt: _askedPrompt),
                    child: const Text('Retry'),
                  ),
                TextButton(
                  key: const ValueKey('assist_search_directly'),
                  onPressed: _searchDirectly,
                  child: const Text('Search directly'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildClarificationCard(DiscoveryAssistClarification clarification) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('assist_clarification_card'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.help_outline, size: 20, color: colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    clarification.question,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (clarification.options.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: clarification.options.map((option) {
                  return ActionChip(
                    label: Text(option),
                    onPressed: () {
                      _queryController.text = option;
                      _runAssist(prompt: option);
                    },
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCaveatsCard(List<String> caveats) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('assist_caveats_card'),
      color: colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Text(
                  'Heads up',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ...caveats.map(
              (caveat) => Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '• $caveat',
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 6),
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );
  }

  Widget _buildResultsSection(QueueProvider queueProvider) {
    if (_query.isEmpty) {
      return _buildEmptyPanel(
        icon: Icons.search,
        title: 'Find external tracks',
        body:
            'Search now groups songs, artists, albums, and queueable sources instead of dumping one cursed provider soup.',
      );
    }

    if (_isSearching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final sections = _response?.sections ?? const <DiscoverySearchSection>[];
    if (sections.isEmpty) {
      return _buildEmptyPanel(
        icon: Icons.search_off,
        title: 'No results',
        body:
            'Try a different query. MusicBrainz or yt-dlp may also be acting possessed.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in sections) ...[
          _buildSearchSection(queueProvider, section),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _buildSearchSection(
    QueueProvider queueProvider,
    DiscoverySearchSection section,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(_sectionIcon(section.kind), section.title),
        const SizedBox(height: 8),
        ...section.items.map((item) {
          final candidate = item.candidate;
          if (candidate != null) {
            return _buildResultTile(queueProvider, candidate);
          }
          return _buildEntityTile(item);
        }),
      ],
    );
  }

  IconData _sectionIcon(String kind) {
    return switch (kind) {
      'tracks' => Icons.music_note,
      'artists' => Icons.person,
      'albums' => Icons.album,
      'sources' => Icons.cloud_download,
      _ => Icons.search,
    };
  }

  Widget _buildEntityTile(DiscoverySearchItem item) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              radius: 22,
              child: Icon(_entityIcon(item.kind), size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (item.displaySubtitle.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      item.displaySubtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 12,
                        height: 1.16,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                _queryController.text = item.title;
                _runSearch(query: item.title);
              },
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Search', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  IconData _entityIcon(String kind) {
    return switch (kind) {
      'track' => Icons.music_note,
      'artist' => Icons.person,
      'album' => Icons.album,
      _ => Icons.search,
    };
  }

  Widget _buildResultTile(
    QueueProvider queueProvider,
    DiscoveryCandidate candidate,
  ) {
    final queuedTrack = _queuedTrackFor(queueProvider, candidate);
    final pending = _pendingCandidateKeys.contains(_candidateKey(candidate));
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mobile = constraints.maxWidth < 520;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildThumb(
                  candidate.thumbnailUrl,
                  overlay: _queuedOverlay(queuedTrack, pending),
                  size: mobile ? 42 : 48,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        candidate.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          height: 1.18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        candidate.displaySubtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
                          height: 1.16,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _buildQueueAction(
                  queueProvider,
                  candidate,
                  queuedTrack,
                  pending: pending,
                  mobile: mobile,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildQueueAction(
    QueueProvider queueProvider,
    DiscoveryCandidate candidate,
    Track? queuedTrack, {
    required bool pending,
    required bool mobile,
  }) {
    final queued = queuedTrack != null || pending;
    if (queued) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: mobile ? 92 : 120),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _buildResultStatusPill(candidate, queuedTrack, pending),
            const SizedBox(height: 4),
            TextButton(
              key: ValueKey('search_view_queue_${_candidateKey(candidate)}'),
              onPressed: _goToQueue,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('View Queue', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
    }

    final onPressed =
        !candidate.downloadable ? null : () => _queueCandidate(candidate);

    if (mobile) {
      return IconButton.filledTonal(
        tooltip: 'Queue',
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 40, height: 40),
        padding: EdgeInsets.zero,
        iconSize: 20,
        icon: const Icon(Icons.playlist_add),
      );
    }

    return FilledButton.tonalIcon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(84, 36),
      ),
      icon: const Icon(Icons.playlist_add, size: 18),
      label: const Text('Queue', style: TextStyle(fontSize: 13)),
    );
  }

  Widget _buildResultStatusPill(
    DiscoveryCandidate candidate,
    Track? queuedTrack,
    bool pending,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final status = pending
        ? TrackQueueStatus.pending
        : queuedTrack?.queueStatus ?? TrackQueueStatus.pending;
    final (label, icon, background, foreground) = switch (status) {
      TrackQueueStatus.playable => (
          'Playable',
          Icons.check_circle,
          colorScheme.primaryContainer,
          colorScheme.onPrimaryContainer,
        ),
      TrackQueueStatus.failed => (
          'Needs retry',
          Icons.error,
          colorScheme.errorContainer,
          colorScheme.onErrorContainer,
        ),
      TrackQueueStatus.downloading => (
          'Downloading',
          Icons.downloading,
          colorScheme.secondaryContainer,
          colorScheme.onSecondaryContainer,
        ),
      TrackQueueStatus.pending => (
          pending ? 'Pending' : 'Queued',
          Icons.schedule,
          colorScheme.secondaryContainer,
          colorScheme.onSecondaryContainer,
        ),
    };

    return DecoratedBox(
      key: ValueKey('search_queue_status_${_candidateKey(candidate)}'),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: foreground,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueueAffordance(QueueProvider provider) {
    final count = provider.queue.length + _pendingCandidateKeys.length;
    if (count == 0) return const SizedBox.shrink();

    return Card(
      key: const ValueKey('search_queue_affordance'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.queue_music),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$count item${count == 1 ? '' : 's'} in Queue',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            TextButton.icon(
              onPressed: _goToQueue,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('View Queue'),
            ),
          ],
        ),
      ),
    );
  }

  IconData? _queuedOverlay(Track? track, bool pending) {
    if (pending) return Icons.schedule;
    return switch (track?.queueStatus) {
      TrackQueueStatus.playable => Icons.check,
      TrackQueueStatus.failed => Icons.error,
      TrackQueueStatus.downloading => Icons.downloading,
      TrackQueueStatus.pending => Icons.schedule,
      null => null,
    };
  }

  void _goToQueue() {
    context.go('/queue');
  }

  Widget _buildProviderRow(List<DiscoveryProviderSummary> providers) {
    if (providers.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: providers.map((provider) {
          final ok = provider.status == 'ok';
          return Tooltip(
            message: provider.errorMessage ??
                '${provider.resultCount} result(s) in ${provider.elapsedMs}ms',
            child: Chip(
              avatar: Icon(
                ok ? Icons.check_circle : Icons.info_outline,
                size: 18,
              ),
              label: Text('${provider.provider}: ${provider.status}'),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildThumb(String? url, {IconData? overlay, double size = 48}) {
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (url != null)
              Image.network(
                url,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _thumbPlaceholder(size: size),
              )
            else
              _thumbPlaceholder(size: size),
            if (overlay != null)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.42),
                ),
                child: Icon(overlay, color: Colors.white, size: size * 0.48),
              ),
          ],
        ),
      ),
    );
  }

  Widget _thumbPlaceholder({double size = 48}) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(
        Icons.music_note,
        size: size * 0.46,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }

  Widget _buildErrorCard(
    String message,
    Future<void> Function() onRetry, {
    String label = 'Retry',
  }) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ),
            TextButton(onPressed: onRetry, child: Text(label)),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyPanel({
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Icon(icon, size: 42, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            body,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  String _friendlyApiError(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map<String, dynamic>) {
        return data['message'] as String? ?? error.message ?? 'Request failed.';
      }
      return error.message ?? 'Request failed.';
    }
    if (error is DiscoveryException) return error.message;
    return error.toString();
  }
}

/// Tone for an assist status banner: an informational disabled state versus a
/// recoverable error. Both keep the search-directly fallback.
enum _AssistTone { info, error }
