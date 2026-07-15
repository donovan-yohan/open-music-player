import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/audio/playback_state.dart';
import '../../core/discovery/discovery_models.dart';
import '../../core/discovery/discovery_service.dart';
import '../../core/models/models.dart' as local;
import '../../core/services/api_client.dart' as local_api;
import '../../core/services/search_service.dart';
import '../../models/track.dart';
import '../../providers/queue_provider.dart';
import '../../shared/widgets/queue_swipe_action.dart';
import '../../shared/widgets/song_metadata_chips.dart';
import 'search_local_logic.dart';

class SearchScreen extends StatefulWidget {
  /// Optional injection seam for tests: supply a [SearchService] wired to a
  /// capturing/fake ApiClient. Production builds construct one lazily.
  final SearchService? searchService;

  const SearchScreen({super.key, this.searchService});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocusNode = FocusNode();
  final Set<String> _pendingCandidateKeys = <String>{};
  Timer? _debounceTimer;
  Timer? _pollTimer;

  late DiscoveryService _discoveryService;
  bool _didPrimeQueue = false;
  bool _isPollingQueue = false;

  // Scope toggle: Catalog keeps the discovery/assist path; Library runs local
  // library search via SearchService. Catalog stays the default so the existing
  // discovery/AI-assist flow (and its tests) are untouched.
  SearchScope _scope = SearchScope.catalog;

  // Local (My Library) search state, kept fully separate from the discovery
  // fields above so switching scope never crosses their view state.
  SearchService? _searchService;
  final RecentSearchesStore _recentSearches = RecentSearchesStore();
  List<String> _recentQueries = const [];
  SearchTypeFilter _typeFilter = SearchTypeFilter.all;
  LocalSearchResults _localResults = const LocalSearchResults();
  int _localRequestSerial = 0;
  bool _isLocalSearching = false;
  String _localQuery = '';
  String? _localError;

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
  String? _sourceSelectionStatus;
  String? _sourceSelectionRetryDecisionId;

  // A prompt that begins with an absolute http(s) URL is routed to the assist
  // endpoint even from Search mode: its direct-URL resolver grounds the link
  // into a queueable candidate without the user rewriting it, and that path
  // works even when the model is disabled.
  static final RegExp _urlPrompt = RegExp(r'^https?://', caseSensitive: false);

  @override
  void initState() {
    super.initState();
    _queryFocusNode.addListener(_onFocusChanged);
    _loadRecentSearches();
  }

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
    _queryFocusNode.removeListener(_onFocusChanged);
    _queryFocusNode.dispose();
    _queryController.dispose();
    super.dispose();
  }

  void _onFocusChanged() {
    // Focus drives the focused-but-empty recent-searches panel in Library scope.
    if (_scope == SearchScope.library) setState(() {});
  }

  /// Lazily built local-search service. Tests inject one via the widget; the
  /// production default wraps the parser-based ApiClient (its own secure-storage
  /// token read matches the app's stored access token).
  SearchService get _localSearch => _searchService ??=
      widget.searchService ?? SearchService(local_api.ApiClient());

  Future<void> _loadRecentSearches() async {
    try {
      final entries = await _recentSearches.load();
      if (!mounted) return;
      setState(() => _recentQueries = entries);
    } catch (_) {
      // A missing/broken prefs store just means no history yet — never fatal.
    }
  }

  void _onQueryChanged(String value) {
    if (_sourceSelectionStatus != null ||
        _sourceSelectionRetryDecisionId != null) {
      setState(_clearSourceSelectionStatus);
    }
    if (_scope == SearchScope.library) {
      final next = value.trim();
      _debounceTimer?.cancel();
      if (next.isEmpty) {
        setState(_resetLocalSearch);
        return;
      }
      setState(() {});
      _debounceTimer = Timer(const Duration(milliseconds: 350), () {
        if (next == _localQuery) return;
        _runLocalSearch(query: next);
      });
      return;
    }

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
        _clearSourceSelectionStatus();
        _query = '';
        _response = null;
        _searchError = null;
        _isSearching = false;
      });
      return;
    }

    setState(() {
      _clearSourceSelectionStatus();
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
    _clearSourceSelectionStatus();
    _assistRequestSerial++;
    _assistResponse = null;
    _assistError = null;
    _askedPrompt = '';
    _isAsking = false;
  }

  void _resetSearch() {
    _clearSourceSelectionStatus();
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
    if (_scope == SearchScope.library) {
      _runLocalSearch(query: text);
      return;
    }
    if (_assistMode || _urlPrompt.hasMatch(text)) {
      if (!_assistMode) setState(() => _assistMode = true);
      _runAssist(prompt: text);
    } else {
      _runSearch(query: text);
    }
  }

  /// Flip between Catalog (discovery/assist) and My Library (local search),
  /// re-running the SAME typed query in the new scope so the user never retypes.
  void _setScope(SearchScope scope) {
    if (scope == _scope) return;
    _debounceTimer?.cancel();
    setState(() {
      _scope = scope;
      _clearSourceSelectionStatus();
      _resetLocalSearch();
    });
    final text = _queryController.text.trim();
    if (text.isEmpty) return;
    if (scope == SearchScope.library) {
      _runLocalSearch(query: text);
    } else if (!_assistMode) {
      _runSearch(query: text);
    }
  }

  void _resetLocalSearch() {
    _clearSourceSelectionStatus();
    _localRequestSerial++;
    _localResults = const LocalSearchResults();
    _localError = null;
    _localQuery = '';
    _isLocalSearching = false;
    _typeFilter = SearchTypeFilter.all;
  }

  /// Runs a local library search across recordings/artists/releases in parallel,
  /// guarded by a monotonic serial so a superseded response can neither
  /// overwrite a newer result nor strand the spinner. On success the query is
  /// recorded in recent searches.
  Future<void> _runLocalSearch({String? query}) async {
    final text = (query ?? _queryController.text).trim();
    _debounceTimer?.cancel();
    final requestId = ++_localRequestSerial;

    if (text.isEmpty) {
      setState(_resetLocalSearch);
      return;
    }

    setState(() {
      _localQuery = text;
      _isLocalSearching = true;
      _localError = null;
    });

    try {
      final results = await Future.wait([
        _localSearch.searchTracks(text),
        _localSearch.searchArtists(text),
        _localSearch.searchAlbums(text),
      ]);
      if (!mounted || requestId != _localRequestSerial) return;
      final tracks = results[0] as local.SearchResponse<local.TrackResult>;
      final artists = results[1] as local.SearchResponse<local.ArtistResult>;
      final albums = results[2] as local.SearchResponse<local.AlbumResult>;
      setState(() {
        _localResults = LocalSearchResults(
          tracks: tracks.results,
          artists: artists.results,
          albums: albums.results,
        );
      });
      unawaited(_recordRecentSearch(text));
    } catch (error) {
      if (!mounted || requestId != _localRequestSerial) return;
      setState(() {
        _localResults = const LocalSearchResults();
        _localError = _friendlyLocalError(error);
      });
    } finally {
      if (mounted && requestId == _localRequestSerial) {
        setState(() => _isLocalSearching = false);
      }
    }
  }

  Future<void> _recordRecentSearch(String query) async {
    try {
      final entries = await _recentSearches.add(query);
      if (!mounted) return;
      setState(() => _recentQueries = entries);
    } catch (_) {
      // Persisting history is best-effort; never surface it to the user.
    }
  }

  Future<void> _removeRecentSearch(String query) async {
    final entries = await _recentSearches.remove(query);
    if (!mounted) return;
    setState(() => _recentQueries = entries);
  }

  Future<void> _clearRecentSearches() async {
    final entries = await _recentSearches.clear();
    if (!mounted) return;
    setState(() => _recentQueries = entries);
  }

  void _runRecentSearch(String query) {
    _queryController.text = query;
    _queryController.selection = TextSelection.collapsed(offset: query.length);
    _queryFocusNode.unfocus();
    _runLocalSearch(query: query);
  }

  Future<void> _playLocalTrack(local.TrackResult track) async {
    final id = track.id;
    if (id == null) return;
    await context.read<PlaybackState>().playQueue([
      _localTrackPlaybackJson(track),
    ]);
  }

  Future<void> _enqueueLocalTrack(local.TrackResult track) async {
    final id = track.id;
    if (id == null) return;
    final playback = context.read<PlaybackState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await playback.enqueue(_localTrackPlaybackJson(track));
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('Added "${track.title}" to queue')),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not add to queue')),
      );
    }
  }

  Map<String, dynamic> _localTrackPlaybackJson(local.TrackResult track) => {
        'id': track.id,
        'title': track.title,
        'artist': track.artist,
        'album': track.album,
        'duration': track.duration != null ? track.duration! ~/ 1000 : 0,
        'artwork_url': track.coverUrl,
        if (track.analysis != null)
          'analysisStatus': track.analysis!.status.name,
        if (track.analysis?.summary != null)
          'analysisSummary': track.analysis!.summary!.toJson(),
        if (track.analysis?.overrides != null)
          'analysisOverrides': track.analysis!.overrides!.toJson(),
        if (track.analysis?.updatedAt != null)
          'analysisUpdatedAt':
              track.analysis!.updatedAt!.toUtc().toIso8601String(),
      };

  String _friendlyLocalError(Object error) {
    if (error is local_api.ApiException) return error.message;
    if (error is DioException) {
      return error.message ?? 'Search failed. Please try again.';
    }
    return 'Search failed. Please try again.';
  }

  void _setAssistMode(bool enabled) {
    if (enabled == _assistMode) return;
    _debounceTimer?.cancel();
    setState(() {
      _assistMode = enabled;
      // Drop both modes' results because the typed prompt is carried across. A
      // previous result from either mode would contradict the current input as
      // soon as the user flips the Search/Assist toggle.
      _resetSearch();
      _resetAssist();
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
      _clearSourceSelectionStatus();
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

  Future<void> _chooseCandidate(
    DiscoveryCandidate candidate,
    DiscoverySelectionSession? selection,
  ) async {
    if (selection == null || !selection.isPresent || selection.isExpired) {
      _showSelectionRecoveryError();
      return;
    }
    if (selection.isRecommended(candidate)) {
      await _submitSourceChoice(
        candidate,
        selection,
        SourceSelectionAction.accepted,
      );
      return;
    }

    final reason = await _promptForOverrideReason(candidate);
    if (reason == null || !mounted) return;
    await _submitSourceChoice(
      candidate,
      selection,
      SourceSelectionAction.overridden,
      reason: reason,
    );
  }

  Future<String?> _promptForOverrideReason(DiscoveryCandidate candidate) async {
    final controller = TextEditingController(text: 'I prefer this version.');
    try {
      return await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose alternate source',
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 6),
              Text(
                candidate.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('source_override_reason'),
                controller: controller,
                maxLength: 2000,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Why this source?',
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () {
                    final value = controller.text.trim();
                    Navigator.of(
                      sheetContext,
                    ).pop(value.isEmpty ? 'I prefer this version.' : value);
                  },
                  child: const Text('Choose source'),
                ),
              ),
            ],
          ),
        ),
      );
    } finally {
      // The modal completes before its dismissal animation stops rebuilding
      // the TextField, so keep the controller alive through that transition.
      await Future<void>.delayed(kThemeAnimationDuration);
      controller.dispose();
    }
  }

  Future<void> _submitSourceChoice(
    DiscoveryCandidate candidate,
    DiscoverySelectionSession selection,
    SourceSelectionAction action, {
    String? reason,
  }) async {
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

    SourceSelectionDecision? decision;
    try {
      final createdDecision =
          await context.read<ApiClient>().createSourceSelection(
                sessionId: selection.sessionId,
                candidateId: candidate.candidateId,
                action: action,
                reason: reason,
              );
      decision = createdDecision;
      await provider.addSourceDecision(createdDecision.id);
      if (!mounted) return;
      setState(() {
        _sourceSelectionStatus = action == SourceSelectionAction.accepted
            ? 'Selected ${candidate.title} as recommended. ${candidate.sourceQuality?.debugReason ?? ''}'
            : 'Selected ${candidate.title}. ${createdDecision.reason ?? reason ?? ''}';
      });
    } catch (error) {
      if (!mounted) return;
      if (decision != null) {
        setState(() {
          _sourceSelectionRetryDecisionId = decision!.id;
          _sourceSelectionStatus =
              'Source choice saved. Queue is unavailable; retry adding it.';
        });
      } else {
        _showSelectionRecoveryError();
      }
    } finally {
      if (mounted) {
        setState(() {
          _pendingCandidateKeys.remove(key);
        });
        _ensurePolling();
      }
    }
  }

  Future<void> _retrySourceSelectionQueue() async {
    final decisionId = _sourceSelectionRetryDecisionId;
    if (decisionId == null) return;
    try {
      await context.read<QueueProvider>().addSourceDecision(decisionId);
      if (!mounted) return;
      setState(() {
        _sourceSelectionRetryDecisionId = null;
        _sourceSelectionStatus = 'Source choice added to queue.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _sourceSelectionStatus =
            'Source choice saved. Queue is unavailable; retry adding it.';
      });
    }
  }

  void _clearSourceSelectionStatus() {
    _sourceSelectionStatus = null;
    _sourceSelectionRetryDecisionId = null;
  }

  void _showSelectionRecoveryError() {
    const message =
        'That source choice expired or is unavailable. Run the search again.';
    if (!mounted) return;
    setState(() {
      if (_assistMode) {
        _assistError = message;
      } else {
        _searchError = message;
      }
    });
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
    final library = _scope == SearchScope.library;

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
            if (library && _localQuery.isNotEmpty)
              _runLocalSearch()
            else if (!library && _assistMode && _askedPrompt.isNotEmpty)
              _runAssist(prompt: _askedPrompt)
            else if (!library && !_assistMode && _query.isNotEmpty)
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
            _buildScopeToggle(),
            const SizedBox(height: 10),
            if (library)
              ..._buildLibraryBody()
            else
              ..._buildCatalogBody(queueProvider),
            const SizedBox(height: 16),
            _buildQueueAffordance(queueProvider),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCatalogBody(QueueProvider queueProvider) {
    final queueError = queueProvider.error;
    final modeError = _assistMode ? _assistError : _searchError;
    return [
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
    ];
  }

  Widget _buildScopeToggle() {
    return Align(
      alignment: Alignment.centerLeft,
      child: SegmentedButton<SearchScope>(
        key: const ValueKey('search_scope_toggle'),
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments: const [
          ButtonSegment<SearchScope>(
            value: SearchScope.catalog,
            icon: Icon(Icons.public, size: 18),
            label: Text('Catalog'),
          ),
          ButtonSegment<SearchScope>(
            value: SearchScope.library,
            icon: Icon(Icons.library_music, size: 18),
            label: Text('My Library'),
          ),
        ],
        selected: {_scope},
        onSelectionChanged: (selection) => _setScope(selection.first),
      ),
    );
  }

  List<Widget> _buildSearchModeBody(QueueProvider queueProvider) {
    return [
      if (_searchError != null) _buildErrorCard(_searchError!, _runSearch),
      if (_sourceSelectionStatus != null) _buildSourceSelectionStatus(),
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

  List<Widget> _buildLibraryBody() {
    final fieldEmpty = _queryController.text.trim().isEmpty;
    // Focused-but-empty surfaces recent searches for one-tap re-run.
    if (_queryFocusNode.hasFocus && fieldEmpty && _recentQueries.isNotEmpty) {
      return [_buildRecentSearches()];
    }

    final hasActiveQuery = _localQuery.isNotEmpty || _isLocalSearching;
    return [
      if (hasActiveQuery) ...[_buildTypeChips(), const SizedBox(height: 12)],
      _buildLocalResultsSection(),
    ];
  }

  Widget _buildRecentSearches() {
    return Column(
      key: const ValueKey('search_recent_searches'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.history,
              size: 18,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Recent searches',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            TextButton(
              key: const ValueKey('search_recent_clear_all'),
              onPressed: _clearRecentSearches,
              child: const Text('Clear all'),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final query in _recentQueries)
          ListTile(
            key: ValueKey('search_recent_$query'),
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.history),
            title: Text(query, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              key: ValueKey('search_recent_remove_$query'),
              tooltip: 'Remove',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => _removeRecentSearch(query),
            ),
            onTap: () => _runRecentSearch(query),
          ),
      ],
    );
  }

  Widget _buildTypeChips() {
    return Wrap(
      key: const ValueKey('search_type_chips'),
      spacing: 8,
      children: SearchTypeFilter.values.map((filter) {
        return ChoiceChip(
          key: ValueKey('search_type_chip_${filter.name}'),
          label: Text(filter.label),
          selected: _typeFilter == filter,
          onSelected: (_) => setState(() => _typeFilter = filter),
        );
      }).toList(),
    );
  }

  Widget _buildLocalResultsSection() {
    if (_localError != null) {
      return _buildErrorCard(_localError!, _runLocalSearch);
    }

    if (_isLocalSearching) {
      return const Padding(
        key: ValueKey('search_local_loading'),
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_localQuery.isEmpty) {
      return _buildEmptyPanel(
        icon: Icons.library_music,
        title: 'Search your library',
        body:
            'Find the songs, artists, and albums already in your library. Switch to Catalog to discover new sources.',
      );
    }

    final filtered = _localResults.filtered(_typeFilter);
    if (filtered.isEmpty) {
      // Distinguish "nothing matched at all" from "this type is empty" so a
      // chip that hides every result never looks like a failed search.
      final scoped = _localResults.isEmpty
          ? 'No results for "$_localQuery"'
          : 'No ${_typeFilter.label.toLowerCase()} for "$_localQuery"';
      return _buildEmptyPanel(
        key: const ValueKey('search_local_empty'),
        icon: Icons.search_off,
        title: 'No results',
        body: scoped,
      );
    }

    return Column(
      key: const ValueKey('search_local_results'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (filtered.tracks.isNotEmpty) ...[
          _buildSectionHeader(Icons.music_note, 'Songs'),
          const SizedBox(height: 8),
          ...filtered.tracks.map(_buildLocalTrackTile),
          const SizedBox(height: 12),
        ],
        if (filtered.artists.isNotEmpty) ...[
          _buildSectionHeader(Icons.person, 'Artists'),
          const SizedBox(height: 8),
          ...filtered.artists.map(_buildLocalArtistTile),
          const SizedBox(height: 12),
        ],
        if (filtered.albums.isNotEmpty) ...[
          _buildSectionHeader(Icons.album, 'Albums'),
          const SizedBox(height: 8),
          ...filtered.albums.map(_buildLocalAlbumTile),
        ],
      ],
    );
  }

  Widget _buildLocalTrackTile(local.TrackResult track) {
    final playable = track.id != null;
    final subtitle = [
      track.artist,
      track.album,
    ].where((value) => value != null && value.isNotEmpty).join(' • ');
    final tile = Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        key: ValueKey('local_track_${track.id ?? track.title}'),
        leading: _buildThumb(track.coverUrl, size: 44),
        title: Text(
          track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SongMetadataChips(
              analysis: track.analysis,
              singleLine: true,
              compact: true,
            ),
            if (playable) ...[
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Play',
                icon: const Icon(Icons.play_arrow),
                onPressed: () => _playLocalTrack(track),
              ),
            ],
          ],
        ),
        onTap: playable ? () => _playLocalTrack(track) : null,
      ),
    );
    if (!playable) return tile;
    return QueueSwipeAction(
      actionKey: ValueKey('search_local_queue_${track.id}_${track.title}'),
      onAddToQueue: () => _enqueueLocalTrack(track),
      child: tile,
    );
  }

  Widget _buildLocalArtistTile(local.ArtistResult artist) {
    final count = artist.trackCount;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.person)),
        title: Text(
          artist.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: count != null
            ? Text('$count track${count == 1 ? '' : 's'} in library')
            : null,
      ),
    );
  }

  Widget _buildLocalAlbumTile(local.AlbumResult album) {
    final subtitle = [
      album.artist,
      album.releaseYear,
    ].where((value) => value != null && value.isNotEmpty).join(' • ');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: _buildThumb(album.coverUrl, size: 44),
        title: Text(
          album.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _buildSearchBox() {
    final library = _scope == SearchScope.library;
    final assist = !library && _assistMode;
    return TextField(
      key: const ValueKey('search_assist_input'),
      controller: _queryController,
      focusNode: _queryFocusNode,
      minLines: 1,
      maxLines: assist ? 3 : 1,
      textInputAction: assist ? TextInputAction.go : TextInputAction.search,
      onChanged: _onQueryChanged,
      onSubmitted: _onSubmit,
      decoration: InputDecoration(
        labelText: library
            ? 'Search your library'
            : assist
                ? 'Ask for a song or paste a link'
                : 'Search songs, artists, albums, or sources',
        hintText: library
            ? 'Songs, artists, albums in your library...'
            : assist
                ? 'that live Porter Robinson Shelter from YouTube...'
                : 'iPod Touch, Ninajirachi, live set...',
        prefixIcon: Icon(
          library
              ? Icons.library_music
              : assist
                  ? Icons.auto_awesome
                  : Icons.travel_explore,
        ),
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

    if (_sourceSelectionStatus != null) {
      widgets.add(_buildSourceSelectionStatus());
    }

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

    final verification = response.verification;
    if (verification != null) {
      widgets.add(_buildVerificationDisclosure(verification));
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
        widgets.add(
          _buildResultTile(
            queueProvider,
            candidate,
            selection: response.directSelection,
          ),
        );
      }
    }

    // Grounded provider search sections (tracks / artists / albums / sources).
    final sections =
        response.search?.sections ?? const <DiscoverySearchSection>[];
    for (final section in sections) {
      widgets.add(const SizedBox(height: 8));
      widgets.add(
        _buildSearchSection(
          queueProvider,
          section,
          selection: response.searchSelection,
        ),
      );
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
            if (_sourceSelectionRetryDecisionId != null) ...[
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('source_selection_retry'),
                onPressed: _retrySourceSelectionQueue,
                child: const Text('Retry queue'),
              ),
            ],
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
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
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
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVerificationDisclosure(
    DiscoveryAssistVerification verification,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('assist_verification_disclosure'),
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant)),
      ),
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        leading: Icon(Icons.fact_check_outlined, color: colorScheme.primary),
        title: const Text(
          'Why this result?',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        children: [
          if (verification.interpretedQuery.isNotEmpty)
            _buildVerificationDetail(
              icon: Icons.manage_search_outlined,
              title: 'Interpreted query',
              detail: verification.interpretedQuery,
            ),
          if (verification.groundingSources.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildVerificationHeading('Grounded Sources'),
            const SizedBox(height: 4),
            ...verification.groundingSources.map(_buildGroundingSourceRow),
          ],
          if (verification.checks.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildVerificationHeading('Checks'),
            const SizedBox(height: 4),
            ...verification.checks.map(_buildVerificationCheckRow),
          ],
          if (verification.unverified.isNotEmpty) ...[
            const SizedBox(height: 8),
            _buildVerificationHeading('Not verified'),
            const SizedBox(height: 4),
            ...verification.unverified.map(
              (item) => _buildVerificationDetail(
                icon: Icons.help_outline,
                title: _verificationLabel(item, fallback: 'Unverified item'),
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildVerificationHeading(String text) {
    return Text(
      text,
      style: Theme.of(
        context,
      ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
    );
  }

  Widget _buildGroundingSourceRow(DiscoveryAssistGroundingSource source) {
    final provider = source.provider.isNotEmpty ? source.provider : source.kind;
    final label = provider.isNotEmpty ? provider : 'Source';
    final count = source.candidateCount;
    final status = source.status.isNotEmpty ? source.status : 'unknown';
    return _buildVerificationDetail(
      icon: _verificationStatusIcon(status),
      title: '$label • $count ${count == 1 ? 'candidate' : 'candidates'}',
      detail: '${_verificationLabel(source.kind, fallback: 'Source')} • '
          '${_verificationStatusLabel(status)}',
      color: _verificationStatusColor(status),
    );
  }

  Widget _buildVerificationCheckRow(DiscoveryAssistVerificationCheck check) {
    final status = check.status.isNotEmpty ? check.status : 'unknown';
    final title = check.id == 'grounded_sources'
        ? 'Source grounding'
        : _verificationLabel(check.id, fallback: 'Check');
    return _buildVerificationDetail(
      icon: _verificationStatusIcon(status),
      title: title,
      detail: check.detail.isNotEmpty
          ? check.detail
          : _verificationStatusLabel(status),
      color: _verificationStatusColor(status),
    );
  }

  Widget _buildVerificationDetail({
    required IconData icon,
    required String title,
    String? detail,
    Color? color,
  }) {
    final textColor = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: textColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 13)),
                if (detail != null && detail.isNotEmpty)
                  Text(
                    detail,
                    style: TextStyle(fontSize: 12, color: textColor),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _verificationStatusIcon(String status) {
    switch (status.trim().toLowerCase()) {
      case 'pass':
      case 'passed':
      case 'ok':
      case 'success':
        return Icons.check_circle_outline;
      case 'warn':
      case 'warning':
      case 'degraded':
        return Icons.warning_amber_outlined;
      case 'fail':
      case 'failed':
      case 'error':
        return Icons.error_outline;
      default:
        return Icons.info_outline;
    }
  }

  Color _verificationStatusColor(String status) {
    final colorScheme = Theme.of(context).colorScheme;
    switch (status.trim().toLowerCase()) {
      case 'pass':
      case 'passed':
      case 'ok':
      case 'success':
        return colorScheme.primary;
      case 'warn':
      case 'warning':
      case 'degraded':
        return colorScheme.tertiary;
      case 'fail':
      case 'failed':
      case 'error':
        return colorScheme.error;
      default:
        return colorScheme.onSurfaceVariant;
    }
  }

  String _verificationStatusLabel(String status) {
    switch (status.trim().toLowerCase()) {
      case 'pass':
      case 'passed':
      case 'ok':
      case 'success':
        return 'Passed';
      case 'warn':
      case 'warning':
      case 'degraded':
        return 'Needs attention';
      case 'fail':
      case 'failed':
      case 'error':
        return 'Did not pass';
      default:
        return 'Status unavailable';
    }
  }

  String _verificationLabel(String value, {required String fallback}) {
    final words = value
        .trim()
        .split(RegExp(r'[_:-]+'))
        .where((word) => word.isNotEmpty)
        .map((word) => '${word[0].toUpperCase()}${word.substring(1)}');
    final label = words.join(' ');
    return label.isEmpty ? fallback : label;
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
          _buildSearchSection(
            queueProvider,
            section,
            selection: _response?.selection,
          ),
          const SizedBox(height: 16),
        ],
      ],
    );
  }

  Widget _buildSearchSection(
    QueueProvider queueProvider,
    DiscoverySearchSection section, {
    DiscoverySelectionSession? selection,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(_sectionIcon(section.kind), section.title),
        const SizedBox(height: 8),
        ...section.items.map((item) {
          final candidate = item.candidate;
          if (candidate != null) {
            return _buildResultTile(
              queueProvider,
              candidate,
              selection: selection,
            );
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
    DiscoveryCandidate candidate, {
    DiscoverySelectionSession? selection,
  }) {
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
                      if (candidate.sourceQuality != null) ...[
                        const SizedBox(height: 5),
                        _buildSourceQualityChip(candidate.sourceQuality!),
                      ],
                      if (selection?.isRecommended(candidate) ?? false) ...[
                        const SizedBox(height: 5),
                        _buildRecommendedSourceChip(),
                      ],
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
                  selection: selection,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRecommendedSourceChip() {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        key: const ValueKey('source_recommended_chip'),
        decoration: BoxDecoration(
          color: colors.primaryContainer,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.recommend, size: 13, color: colors.onPrimaryContainer),
              const SizedBox(width: 4),
              Text(
                'Recommended',
                style: TextStyle(
                  color: colors.onPrimaryContainer,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSourceSelectionStatus() {
    final colors = Theme.of(context).colorScheme;
    return Card(
      key: const ValueKey('source_selection_status'),
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Icon(Icons.fact_check_outlined, color: colors.onPrimaryContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _sourceSelectionStatus!,
                style: TextStyle(color: colors.onPrimaryContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceQualityChip(DiscoverySourceQuality quality) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, background, foreground) = switch (quality.recommendation) {
      'preferred' => (
          Icons.verified,
          colorScheme.primaryContainer,
          colorScheme.onPrimaryContainer,
        ),
      'acceptable' => (
          Icons.check_circle_outline,
          colorScheme.secondaryContainer,
          colorScheme.onSecondaryContainer,
        ),
      'avoid' => (
          Icons.warning_amber,
          colorScheme.errorContainer,
          colorScheme.onErrorContainer,
        ),
      _ => (
          Icons.info_outline,
          colorScheme.surfaceContainerHighest,
          colorScheme.onSurfaceVariant,
        ),
    };
    return Tooltip(
      message: quality.debugReason,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: ValueKey(
              'source_quality_chip_${quality.classification}_${quality.recommendation}',
            ),
            borderRadius: BorderRadius.circular(999),
            onTap: () => _showSourceQualityDetails(quality),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 13, color: foreground),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        quality.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showSourceQualityDetails(DiscoverySourceQuality quality) {
    final theme = Theme.of(context);
    final scoreLabel = '${quality.score}/100';
    final confidenceLabel =
        '${(quality.confidence.clamp(0, 1) * 100).round()}%';
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            shrinkWrap: true,
            children: [
              Text(
                'Source quality',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildSourceQualityDetailPill(
                    icon: Icons.graphic_eq,
                    label: quality.label,
                  ),
                  _buildSourceQualityDetailPill(
                    icon: Icons.check_circle_outline,
                    label: _humanizeSourceQualityToken(quality.recommendation),
                  ),
                  _buildSourceQualityDetailPill(
                    icon: Icons.speed,
                    label: scoreLabel,
                  ),
                  _buildSourceQualityDetailPill(
                    icon: Icons.fact_check_outlined,
                    label: confidenceLabel,
                  ),
                ],
              ),
              if (quality.warnings.isNotEmpty) ...[
                const SizedBox(height: 18),
                _buildSourceQualityDetailSection('Warnings', quality.warnings),
              ],
              if (quality.reasons.isNotEmpty) ...[
                const SizedBox(height: 18),
                _buildSourceQualityDetailSection('Reasons', quality.reasons),
              ],
              if (quality.provenance.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  'Provenance',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                SelectableText(
                  quality.provenance,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildSourceQualityDetailPill({
    required IconData icon,
    required String label,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: colorScheme.onSurfaceVariant,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceQualityDetailSection(String title, List<String> values) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        ...values.map(
          (value) => Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(value, style: theme.textTheme.bodyMedium),
          ),
        ),
      ],
    );
  }

  String _humanizeSourceQualityToken(String value) {
    final words = value
        .split('_')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (words.isEmpty) return 'Review';
    return words
        .map((word) => word[0].toUpperCase() + word.substring(1))
        .join(' ');
  }

  Widget _buildQueueAction(
    QueueProvider queueProvider,
    DiscoveryCandidate candidate,
    Track? queuedTrack, {
    required bool pending,
    required bool mobile,
    required DiscoverySelectionSession? selection,
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
              onPressed: _goToImports,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('View imports', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      );
    }

    final onPressed = !candidate.downloadable
        ? null
        : () => _chooseCandidate(candidate, selection);
    final recommended = selection?.isRecommended(candidate) ?? false;

    if (mobile) {
      return IconButton.filledTonal(
        tooltip: recommended ? 'Use recommended source' : 'Choose source',
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
      label: Text(
        recommended ? 'Use' : 'Choose',
        style: const TextStyle(fontSize: 13),
      ),
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
                '$count item${count == 1 ? '' : 's'} in Import queue',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            TextButton.icon(
              onPressed: _goToImports,
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('View imports'),
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

  void _goToImports() {
    context.go('/queue/imports');
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
    Key? key,
  }) {
    return Container(
      key: key,
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
