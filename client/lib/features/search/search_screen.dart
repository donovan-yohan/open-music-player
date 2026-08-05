import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/api_client.dart';
import '../../core/commands/search_focus_controller.dart';
import '../../core/discovery/discovery_models.dart';
import '../../core/discovery/research_models.dart';
import '../../core/discovery/research_service.dart';
import '../../core/discovery/discovery_service.dart';
import '../../models/track.dart';
import '../../providers/queue_provider.dart';
import 'search_local_logic.dart';

class SearchScreen extends StatefulWidget {
  final ResearchJobService? researchService;
  final List<Duration> researchPollDelays;
  final SearchFocusController? commandFocusController;

  /// Injection seam for the source-verification link. Production always opens
  /// the provider page in its native application where possible.
  final Future<bool> Function(Uri url)? externalUrlLauncher;

  const SearchScreen({
    super.key,
    this.researchService,
    this.commandFocusController,
    this.externalUrlLauncher,
    this.researchPollDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
    ],
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _queryController = TextEditingController();
  final FocusNode _queryFocusNode = FocusNode();
  final Set<String> _pendingCandidateKeys = <String>{};
  Timer? _debounceTimer;
  Timer? _pollTimer;
  Timer? _researchPollTimer;

  late DiscoveryService _discoveryService;
  late ResearchJobService _researchService;
  bool _didPrimeQueue = false;
  bool _isPollingQueue = false;

  SearchResultTab _resultTab = SearchResultTab.song;

  DiscoverySearchResponse? _response;
  int _searchRequestSerial = 0;
  bool _isSearching = false;
  String _query = '';
  String? _searchError;

  // Assist is an explicitly invoked result view, not a search mode. Typing or
  // submitting continues to use normal catalog search unless the sparkle
  // button was deliberately tapped.
  bool _assistMode = false;
  DiscoveryAssistResponse? _assistResponse;
  int _assistRequestSerial = 0;
  bool _isAsking = false;
  String _askedPrompt = '';
  String? _assistError;
  String? _sourceSelectionStatus;
  String? _sourceSelectionRetryDecisionId;

  ResearchSnapshot? _researchSnapshot;
  List<ResearchEvent> _researchEvents = const [];
  List<String> _researchCandidateOrder = const [];
  int _researchEpoch = 0;
  int _researchLastEventSequence = 0;
  int _researchPollStep = 0;
  bool _isCreatingResearch = false;
  DateTime? _researchStartedAt;

  @override
  void initState() {
    super.initState();
    widget.commandFocusController?.register(_queryFocusNode);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _discoveryService = DiscoveryService(context.read<ApiClient>());
    _researchService =
        widget.researchService ?? ResearchService(context.read<ApiClient>());
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
    _researchPollTimer?.cancel();
    widget.commandFocusController?.unregister(_queryFocusNode);
    _queryFocusNode.dispose();
    _queryController.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    if (_sourceSelectionStatus != null ||
        _sourceSelectionRetryDecisionId != null) {
      setState(_clearSourceSelectionStatus);
    }
    // Editing always returns to ordinary search. AI is only invoked by its
    // explicit inline control, never by keystrokes or the keyboard action.
    if (_assistMode) {
      setState(() {
        _assistMode = false;
        _resetAssist();
      });
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
    _resetResearch();
  }

  void _resetResearch() {
    _researchEpoch++;
    _researchPollTimer?.cancel();
    _researchPollTimer = null;
    _researchSnapshot = null;
    _researchEvents = const [];
    _researchCandidateOrder = const [];
    _researchLastEventSequence = 0;
    _researchPollStep = 0;
    _isCreatingResearch = false;
    _researchStartedAt = null;
  }

  void _resetSearch() {
    _clearSourceSelectionStatus();
    _searchRequestSerial++;
    _response = null;
    _searchError = null;
    _query = '';
    _isSearching = false;
  }

  /// Keyboard submit is intentionally boring: it always runs ordinary search.
  /// AI research is opt-in via the sparkle control beside the field.
  void _onSubmit(String value) {
    final text = value.trim();
    if (text.isEmpty) return;
    if (_assistMode) {
      setState(() {
        _assistMode = false;
        _resetAssist();
      });
    }
    _runSearch(query: text);
  }

  void _triggerAssist() {
    final prompt = _queryController.text.trim();
    if (prompt.isEmpty) {
      _queryFocusNode.requestFocus();
      return;
    }
    _debounceTimer?.cancel();
    setState(() {
      _assistMode = true;
      _resetSearch();
      _resetAssist();
    });
    _runAssist(prompt: prompt);
  }

  void _dismissAssistResults() {
    final query = _queryController.text.trim();
    setState(() {
      _assistMode = false;
      _resetAssist();
    });
    if (query.isNotEmpty) _runSearch(query: query);
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
    if (text.startsWith('http://') || text.startsWith('https://')) {
      return _runSynchronousAssist(prompt: text);
    }
    return _runResearch(prompt: text);
  }

  Future<void> _runSynchronousAssist({String? prompt}) async {
    final text = (prompt ?? _queryController.text).trim();
    _debounceTimer?.cancel();
    _resetResearch();
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

  Future<void> _runResearch({String? prompt}) async {
    final text = (prompt ?? _queryController.text).trim();
    _debounceTimer?.cancel();
    if (text.isEmpty) {
      setState(_resetAssist);
      return;
    }

    // A natural-language job supersedes any direct-url/synchronous assist
    // request as well as older research polls.
    _assistRequestSerial++;
    final epoch = ++_researchEpoch;
    _researchPollTimer?.cancel();
    _researchPollTimer = null;
    setState(() {
      _clearSourceSelectionStatus();
      _askedPrompt = text;
      _assistResponse = null;
      _assistError = null;
      _isAsking = false;
      _isCreatingResearch = true;
      _researchSnapshot = null;
      _researchEvents = const [];
      _researchCandidateOrder = const [];
      _researchLastEventSequence = 0;
      _researchPollStep = 0;
      _researchStartedAt = DateTime.now();
    });

    try {
      final snapshot = await _researchService.create(query: text);
      if (!_isCurrentResearch(epoch, snapshot.job.id)) return;
      setState(() {
        _applyResearchSnapshot(snapshot);
        _isCreatingResearch = false;
      });
      _scheduleResearchPoll(epoch, snapshot.job.id);
    } on ResearchException catch (error) {
      if (!_isCurrentResearch(epoch, null)) return;
      if (error.canFallBackToAssist) {
        setState(() => _isCreatingResearch = false);
        await _runSynchronousAssist(prompt: text);
        return;
      }
      setState(() {
        _isCreatingResearch = false;
        _assistError = error.message;
      });
    } catch (error) {
      if (!_isCurrentResearch(epoch, null)) return;
      setState(() {
        _isCreatingResearch = false;
        _assistError = _friendlyApiError(error);
      });
    }
  }

  bool _isCurrentResearch(int epoch, String? jobId) {
    if (!mounted || epoch != _researchEpoch || !_assistMode) return false;
    final activeJob = _researchSnapshot?.job.id;
    return jobId == null || activeJob == null || activeJob == jobId;
  }

  void _applyResearchSnapshot(ResearchSnapshot snapshot) {
    final current = _researchSnapshot;
    if (current != null &&
        snapshot.job.id == current.job.id &&
        snapshot.latestRevision.number <= current.latestRevision.number) {
      // Job lifecycle/degradation is mutable, while revisions are immutable.
      // Preserve the rendered revision for equal/older snapshots, but retain
      // authoritative terminal state so polling stops promptly.
      _researchSnapshot = ResearchSnapshot(
        job: snapshot.job,
        revisions: current.revisions,
        latestDegradation: snapshot.latestDegradation,
      );
      return;
    }
    _researchSnapshot = snapshot;
    final latestIds = snapshot.latestRevision.payload.candidates
        .map((candidate) => candidate.candidateId)
        .toList();
    if (_researchCandidateOrder.isEmpty) {
      _researchCandidateOrder = latestIds;
    } else {
      _researchCandidateOrder = [
        ..._researchCandidateOrder.where(latestIds.contains),
        ...latestIds.where((id) => !_researchCandidateOrder.contains(id)),
      ];
    }
  }

  void _scheduleResearchPoll(int epoch, String jobId) {
    _researchPollTimer?.cancel();
    final snapshot = _researchSnapshot;
    if (snapshot == null ||
        !snapshot.job.isActive ||
        !_isCurrentResearch(epoch, jobId)) {
      return;
    }
    final delays = widget.researchPollDelays.isEmpty
        ? const [Duration(seconds: 1)]
        : widget.researchPollDelays;
    final delay = delays[_researchPollStep.clamp(0, delays.length - 1)];
    _researchPollStep++;
    _researchPollTimer = Timer(delay, () => _pollResearch(epoch, jobId));
  }

  Future<void> _pollResearch(int epoch, String jobId) async {
    if (!_isCurrentResearch(epoch, jobId)) return;
    try {
      final results = await Future.wait([
        _researchService.get(jobId),
        _researchService.events(
          jobId,
          afterSequence: _researchLastEventSequence,
        ),
      ]);
      if (!_isCurrentResearch(epoch, jobId)) return;
      final snapshot = results[0] as ResearchSnapshot;
      final page = results[1] as ResearchEventPage;
      setState(() {
        _applyResearchSnapshot(snapshot);
        if (page.events.isNotEmpty) {
          _researchEvents = [..._researchEvents, ...page.events];
          _researchLastEventSequence = page.events.last.sequence;
        }
      });
    } catch (_) {
      // Keep the deterministic revision already on screen. A later poll may
      // recover transient progress transport without replacing it with an error.
    } finally {
      if (_isCurrentResearch(epoch, jobId)) _scheduleResearchPoll(epoch, jobId);
    }
  }

  Future<void> _cancelResearch() async {
    final snapshot = _researchSnapshot;
    if (snapshot == null || !snapshot.job.isActive) return;
    final jobId = snapshot.job.id;
    final epoch = ++_researchEpoch;
    _researchPollTimer?.cancel();
    try {
      final next = await _researchService.cancel(jobId);
      if (!_isCurrentResearchJob(epoch, jobId)) return;
      setState(() {
        _assistError = null;
        _applyResearchSnapshot(next);
      });
      _scheduleResearchPoll(epoch, jobId);
    } catch (error) {
      if (!_isCurrentResearchJob(epoch, jobId)) return;
      setState(() => _assistError = _friendlyApiError(error));
      _scheduleResearchPoll(epoch, jobId);
    }
  }

  Future<void> _retryResearch() async {
    final snapshot = _researchSnapshot;
    if (snapshot == null || !snapshot.job.canRetry) return;
    final jobId = snapshot.job.id;
    final epoch = ++_researchEpoch;
    _researchPollTimer?.cancel();
    try {
      final next = await _researchService.retry(jobId);
      if (!_isCurrentResearchJob(epoch, jobId)) return;
      setState(() {
        _assistError = null;
        _researchPollStep = 0;
        _applyResearchSnapshot(next);
      });
      _scheduleResearchPoll(epoch, jobId);
    } catch (error) {
      if (!_isCurrentResearchJob(epoch, jobId)) return;
      setState(() => _assistError = _friendlyApiError(error));
    }
  }

  bool _isCurrentResearchJob(int epoch, String jobId) {
    return _isCurrentResearch(epoch, jobId) &&
        _researchSnapshot?.job.id == jobId;
  }

  Future<void> _chooseCandidate(
    DiscoveryCandidate candidate,
    DiscoverySelectionSession? selection,
  ) async {
    if (selection == null || !selection.isPresent || selection.isExpired) {
      _showSelectionRecoveryError();
      return;
    }
    await _submitSourceChoice(
      candidate,
      selection,
      SourceSelectionAction.selected,
    );
  }

  Future<void> _chooseResearchCandidate(
    ResearchCandidate researchCandidate,
  ) async {
    final snapshot = _researchSnapshot;
    if (snapshot == null) return;
    final candidate = researchCandidate.toDiscoveryCandidate();
    String? recommendedId;
    for (final recommendation
        in snapshot.latestRevision.payload.recommendations) {
      if (recommendation.rank == 1) {
        recommendedId = recommendation.candidateId;
        break;
      }
    }
    if (candidate.candidateId == recommendedId) {
      await _submitResearchChoice(candidate, SourceSelectionAction.accepted);
      return;
    }
    final reason = await _promptForOverrideReason(candidate, maxLength: 512);
    if (reason == null || !mounted) return;
    await _submitResearchChoice(
      candidate,
      SourceSelectionAction.overridden,
      reason: reason,
    );
  }

  Future<String?> _promptForOverrideReason(
    DiscoveryCandidate candidate, {
    int maxLength = 2000,
  }) async {
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
                maxLength: maxLength,
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

  Future<void> _submitResearchChoice(
    DiscoveryCandidate candidate,
    SourceSelectionAction action, {
    String? reason,
  }) async {
    final snapshot = _researchSnapshot;
    if (snapshot == null) return;
    final key = _candidateKey(candidate);
    final provider = context.read<QueueProvider>();
    if (!candidate.downloadable ||
        _pendingCandidateKeys.contains(key) ||
        _queuedTrackFor(provider, candidate) != null) {
      return;
    }
    setState(() => _pendingCandidateKeys.add(key));
    _ensurePolling();
    SourceSelectionDecision? decision;
    try {
      decision = await _researchService.review(
        jobId: snapshot.job.id,
        candidateId: candidate.candidateId,
        action: action,
        reason: reason,
      );
      await provider.addSourceDecision(decision.id);
      if (!mounted) return;
      setState(() {
        _sourceSelectionStatus = action == SourceSelectionAction.accepted
            ? 'Selected ${candidate.title} as recommended.'
            : 'Selected ${candidate.title}. ${decision?.reason ?? reason ?? ''}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        if (decision != null) {
          _sourceSelectionRetryDecisionId = decision.id;
          _sourceSelectionStatus =
              'Source choice saved. Queue is unavailable; retry adding it.';
        } else {
          _assistError = 'That source choice could not be saved. Try again.';
        }
      });
    } finally {
      if (mounted) {
        setState(() => _pendingCandidateKeys.remove(key));
        _ensurePolling();
      }
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
        _sourceSelectionStatus = 'Added ${candidate.title} to imports.';
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
    if (provider.queueServiceDisabled) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }
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
    if (provider.queueServiceDisabled || !_queueHasActiveWork(provider)) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      _refreshQueue();
    });
  }

  bool _queueHasActiveWork(QueueProvider provider) {
    if (provider.queueServiceDisabled) return false;
    if (_pendingCandidateKeys.isNotEmpty) return true;
    return provider.queue.tracks.any(
      (track) =>
          track.queueStatus == TrackQueueStatus.pending ||
          track.queueStatus == TrackQueueStatus.downloading,
    );
  }

  QueueTrack? _queuedTrackFor(
    QueueProvider provider,
    DiscoveryCandidate candidate,
  ) {
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
    final queueAvailable = !queueProvider.queueServiceDisabled;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Discover',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
        actions: queueAvailable
            ? [
                IconButton(
                  tooltip: 'Refresh queue status',
                  onPressed: () => _refreshQueue(force: true),
                  icon: const Icon(Icons.refresh),
                ),
              ]
            : const [],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            if (_assistMode && _askedPrompt.isNotEmpty)
              _runAssist(prompt: _askedPrompt)
            else if (!_assistMode && _query.isNotEmpty)
              _runSearch(),
            if (queueAvailable) _refreshQueue(force: true),
          ]);
        },
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 112),
          children: [
            _buildSearchBox(),
            const SizedBox(height: 6),
            _buildResultTabs(),
            const SizedBox(height: 6),
            ..._buildCatalogBody(queueProvider),
            const SizedBox(height: 16),
            if (queueAvailable) _buildQueueAffordance(queueProvider),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildCatalogBody(QueueProvider queueProvider) {
    final queueError =
        queueProvider.queueServiceDisabled ? null : queueProvider.error;
    final modeError = _assistMode ? _assistError : _searchError;
    return [
      // A queue-load error is only shown when the active mode is otherwise
      // clean, so the mode's own error card stays the primary message.
      if (modeError == null && queueError != null)
        _buildErrorCard(queueError, () => _refreshQueue(force: true)),
      const SizedBox(height: 12),
      if (_assistMode) ...[
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            key: const ValueKey('search_assist_dismiss'),
            onPressed: _dismissAssistResults,
            icon: const Icon(Icons.arrow_back, size: 16),
            label: const Text('Back to search'),
          ),
        ),
        ..._buildAssistBody(queueProvider),
      ] else
        ..._buildSearchModeBody(queueProvider),
    ];
  }

  List<Widget> _buildSearchModeBody(QueueProvider queueProvider) {
    return [
      if (_searchError != null) _buildErrorCard(_searchError!, _runSearch),
      if (_sourceSelectionStatus != null) _buildSourceSelectionStatus(),
      if (_response != null) _buildProviderRow(_response!.providers),
      const SizedBox(height: 12),
      _buildResultsSection(
        queueProvider,
        queueAvailable: !queueProvider.queueServiceDisabled,
      ),
    ];
  }

  Widget _buildResultTabs() {
    return SizedBox(
      // TabBar reserves a 2dp indicator/divider lane, so the 50dp container
      // leaves each actual tab a full 48dp touch target.
      height: 50,
      child: DefaultTabController(
        key: ValueKey('search_result_tabs_${_resultTab.name}'),
        length: SearchResultTab.values.length,
        initialIndex: _resultTab.index,
        child: TabBar(
          key: const ValueKey('search_result_tabs'),
          onTap: (index) =>
              setState(() => _resultTab = SearchResultTab.values[index]),
          labelPadding: EdgeInsets.zero,
          tabs: [
            for (final tab in SearchResultTab.values)
              Tab(
                key: ValueKey('search_result_tab_${tab.name}'),
                height: 50,
                text: tab.label,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBox() {
    return TextField(
      key: const ValueKey('search_assist_input'),
      controller: _queryController,
      focusNode: _queryFocusNode,
      minLines: 1,
      maxLines: 1,
      textInputAction: TextInputAction.search,
      onChanged: _onQueryChanged,
      onSubmitted: _onSubmit,
      decoration: InputDecoration(
        labelText: 'Discover songs, artists, albums',
        hintText: 'iPod Touch, Ninajirachi, live set...',
        prefixIcon: const Icon(Icons.travel_explore),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const ValueKey('search_ai_button'),
              tooltip: 'Ask AI',
              onPressed: _triggerAssist,
              icon: const Icon(Icons.auto_awesome),
            ),
            if (_queryController.text.isNotEmpty)
              IconButton(
                tooltip: 'Clear search',
                onPressed: () {
                  _queryController.clear();
                  _onQueryChanged('');
                },
                icon: const Icon(Icons.clear),
              ),
          ],
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 48),
        border: const OutlineInputBorder(),
      ),
    );
  }

  List<Widget> _buildAssistBody(QueueProvider queueProvider) {
    if (_isCreatingResearch || _researchSnapshot != null) {
      return _buildResearchBody(queueProvider);
    }
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
              : 'AI assist is not configured. You can still discover directly or paste a YouTube/SoundCloud link.',
          tone: _AssistTone.info,
        ),
      );
    } else if (response.isError) {
      widgets.add(
        _buildAssistStatusBanner(
          icon: Icons.error_outline,
          message: response.assistantText.isNotEmpty
              ? response.assistantText
              : 'The assistant is unavailable right now. You can still discover directly or paste a link.',
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
            queueAvailable: !queueProvider.queueServiceDisabled,
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
          queueAvailable: !queueProvider.queueServiceDisabled,
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

  List<Widget> _buildResearchBody(QueueProvider queueProvider) {
    final snapshot = _researchSnapshot;
    if (snapshot == null) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    final latest = snapshot.latestRevision;
    final byId = {
      for (final candidate in latest.payload.candidates)
        candidate.candidateId: candidate,
    };
    final candidates = _researchCandidateOrder
        .map((id) => byId[id])
        .whereType<ResearchCandidate>()
        .toList(growable: false);
    return [
      if (_assistError != null)
        _buildAssistStatusBanner(
          icon: Icons.error_outline,
          message: _assistError!,
          tone: _AssistTone.error,
          showRetry: true,
        ),
      if (_sourceSelectionStatus != null) _buildSourceSelectionStatus(),
      _buildResearchStatus(snapshot),
      const SizedBox(height: 8),
      _buildSectionHeader(Icons.travel_explore, 'Research results'),
      const SizedBox(height: 8),
      for (final researchCandidate in candidates)
        _buildResultTile(
          queueProvider,
          researchCandidate.toDiscoveryCandidate(),
          stableKey: ValueKey(
            'research_candidate_${researchCandidate.candidateId}',
          ),
          onChoose: () => _chooseResearchCandidate(researchCandidate),
          queueAvailable: !queueProvider.queueServiceDisabled,
        ),
      if (candidates.isEmpty)
        _buildEmptyPanel(
          icon: Icons.search_off,
          title: 'No grounded sources',
          body:
              'The deterministic search found no queueable sources for that prompt.',
        ),
    ];
  }

  Widget _buildResearchStatus(ResearchSnapshot snapshot) {
    final colors = Theme.of(context).colorScheme;
    final degradation = snapshot.latestDegradation;
    final elapsed = _researchStartedAt == null
        ? ''
        : ' ${DateTime.now().difference(_researchStartedAt!).inSeconds}s elapsed';
    final event = _researchEvents.isEmpty ? null : _researchEvents.last;
    final stage = snapshot.latestRevision.payload.stage.replaceAll('_', ' ');
    final active = snapshot.job.isActive;
    final message = degradation == null
        ? '${active ? 'Researching' : 'Research'}: $stage.$elapsed'
        : 'Research degraded: ${degradation.code.replaceAll('_', ' ')}. Baseline results remain available.$elapsed';
    return Semantics(
      liveRegion: true,
      label:
          '$message${event == null ? '' : ' Latest progress: ${event.kind.replaceAll('_', ' ')}.'}',
      child: Card(
        key: const ValueKey('research_status'),
        color: degradation == null
            ? colors.secondaryContainer
            : colors.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                degradation == null
                    ? Icons.manage_search
                    : Icons.warning_amber_outlined,
                color: degradation == null
                    ? colors.onSecondaryContainer
                    : colors.onErrorContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: degradation == null
                        ? colors.onSecondaryContainer
                        : colors.onErrorContainer,
                  ),
                ),
              ),
              if (active)
                IconButton(
                  key: const ValueKey('research_cancel'),
                  tooltip: 'Cancel research',
                  onPressed: _cancelResearch,
                  icon: const Icon(Icons.cancel_outlined),
                )
              else if (snapshot.job.canRetry)
                IconButton(
                  key: const ValueKey('research_retry'),
                  tooltip: 'Retry research',
                  onPressed: _retryResearch,
                  icon: const Icon(Icons.refresh),
                ),
            ],
          ),
        ),
      ),
    );
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
            // Wrap (not Row) so Retry + Discover directly reflow instead of
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
                    child: const Text('Discover directly'),
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
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _buildResultsSection(
    QueueProvider queueProvider, {
    required bool queueAvailable,
  }) {
    if (_query.isEmpty) {
      return _buildEmptyPanel(
        icon: Icons.search,
        title: 'Find external tracks',
        body:
            'Discover a song, artist, or album, then choose a source to import.',
      );
    }

    if (_isSearching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final response = _response;
    final sections = response?.sections ?? const <DiscoverySearchSection>[];
    if (sections.isEmpty && (response?.results.isEmpty ?? true)) {
      return _buildEmptyPanel(
        icon: Icons.search_off,
        title: 'No results',
        body:
            'Try a different query. MusicBrainz or yt-dlp may also be acting possessed.',
      );
    }

    final tab = _resultTab;
    if (tab == SearchResultTab.song) {
      final candidates = _rankSourceCandidates(response!);
      if (candidates.isEmpty) {
        return _buildEmptyPanel(
          icon: Icons.cloud_off,
          title: 'No downloadable sources',
          body: 'Try Artist or Album for catalog matches, or refine the song.',
        );
      }
      return Column(
        key: const ValueKey('search_sources_primary'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeader(Icons.cloud_download, 'Downloadable sources'),
          const SizedBox(height: 6),
          for (final candidate in candidates)
            _buildResultTile(
              queueProvider,
              candidate,
              selection: response.selection,
              queueAvailable: queueAvailable,
            ),
        ],
      );
    }

    final kind = tab == SearchResultTab.artist ? 'artists' : 'albums';
    final entities = sections
        .where((section) => section.kind == kind)
        .expand((section) => section.items)
        .where((item) => item.candidate == null)
        .toList(growable: false);
    if (entities.isEmpty) {
      return _buildEmptyPanel(
        icon: tab == SearchResultTab.artist
            ? Icons.person_off
            : Icons.album_outlined,
        title: 'No ${tab.label.toLowerCase()} matches',
        body: 'Try Song for downloadable sources or refine your query.',
      );
    }
    return Column(
      key: ValueKey('search_${tab.name}_entities'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeader(_sectionIcon(kind), '${tab.label}s'),
        const SizedBox(height: 6),
        for (final item in entities) _buildEntityTile(item),
      ],
    );
  }

  List<DiscoveryCandidate> _rankSourceCandidates(
    DiscoverySearchResponse response,
  ) {
    final byKey = <String, DiscoveryCandidate>{};
    for (final candidate in response.results) {
      byKey[_candidateKey(candidate)] = candidate;
    }
    for (final section in response.sections) {
      for (final item in section.items) {
        final candidate = item.candidate;
        if (candidate != null) byKey[_candidateKey(candidate)] = candidate;
      }
    }
    return byKey.values
        .where((candidate) => candidate.downloadable)
        .toList(growable: false);
  }

  Widget _buildSearchSection(
    QueueProvider queueProvider,
    DiscoverySearchSection section, {
    DiscoverySelectionSession? selection,
    bool queueAvailable = true,
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
              queueAvailable: queueAvailable,
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
              child: const Text('Discover', style: TextStyle(fontSize: 12)),
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
    Key? stableKey,
    VoidCallback? onChoose,
    bool queueAvailable = true,
  }) {
    final queuedTrack =
        queueAvailable ? _queuedTrackFor(queueProvider, candidate) : null;
    final pending = _pendingCandidateKeys.contains(_candidateKey(candidate));
    final canPreview = Uri.tryParse(candidate.sourceUrl)?.hasScheme ?? false;
    return Card(
      key: stableKey,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: canPreview ? () => _previewSource(candidate) : null,
        borderRadius: BorderRadius.circular(12),
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
                    overlay: queueAvailable
                        ? _queuedOverlay(queuedTrack, pending)
                        : null,
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
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                            fontSize: 12,
                            height: 1.16,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _buildCandidateActions(
                    queueProvider: queueProvider,
                    candidate: candidate,
                    queuedTrack: queuedTrack,
                    pending: pending,
                    mobile: mobile,
                    selection: selection,
                    onChoose: onChoose,
                    queueAvailable: queueAvailable,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCandidateActions({
    required QueueProvider queueProvider,
    required DiscoveryCandidate candidate,
    required QueueTrack? queuedTrack,
    required bool pending,
    required bool mobile,
    required DiscoverySelectionSession? selection,
    required bool queueAvailable,
    VoidCallback? onChoose,
  }) {
    final canPreview = Uri.tryParse(candidate.sourceUrl)?.hasScheme ?? false;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canPreview)
          IconButton(
            key: ValueKey(
              'discover_preview_source_${_candidateKey(candidate)}',
            ),
            tooltip: 'Preview source',
            onPressed: () => _previewSource(candidate),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(width: 40, height: 40),
            padding: EdgeInsets.zero,
            iconSize: 20,
            icon: const Icon(Icons.play_circle_outline),
          ),
        if (canPreview && queueAvailable) const SizedBox(width: 4),
        if (queueAvailable)
          _buildQueueAction(
            queueProvider,
            candidate,
            queuedTrack,
            pending: pending,
            mobile: mobile,
            selection: selection,
            onChoose: onChoose,
          ),
      ],
    );
  }

  Future<void> _previewSource(DiscoveryCandidate candidate) async {
    final uri = Uri.tryParse(candidate.sourceUrl);
    if (uri == null || !uri.hasScheme) return;
    final opened = await (widget.externalUrlLauncher?.call(uri) ??
        launchUrl(uri, mode: LaunchMode.externalApplication));
    if (!opened && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not preview source')));
    }
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

  Widget _buildQueueAction(
    QueueProvider queueProvider,
    DiscoveryCandidate candidate,
    QueueTrack? queuedTrack, {
    required bool pending,
    required bool mobile,
    required DiscoverySelectionSession? selection,
    VoidCallback? onChoose,
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
        : onChoose ?? () => _chooseCandidate(candidate, selection);
    if (mobile) {
      return IconButton.filledTonal(
        tooltip: 'Add to queue',
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
      label: const Text('Add', style: TextStyle(fontSize: 13)),
    );
  }

  Widget _buildResultStatusPill(
    DiscoveryCandidate candidate,
    QueueTrack? queuedTrack,
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

  IconData? _queuedOverlay(QueueTrack? track, bool pending) {
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
    final available =
        providers.where((provider) => provider.status == 'ok').length;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        key: const ValueKey('search_provider_summary'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => _showProviderDetails(providers),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Icon(
                available == providers.length
                    ? Icons.check_circle_outline
                    : Icons.info_outline,
                size: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$available/${providers.length} sources available',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  void _showProviderDetails(List<DiscoveryProviderSummary> providers) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          children: [
            Text(
              'Discover sources',
              style: Theme.of(
                sheetContext,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            for (final provider in providers)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  provider.status == 'ok'
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                ),
                title: Text('${provider.provider} · ${provider.status}'),
                subtitle: Text(
                  [
                    '${provider.resultCount} result${provider.resultCount == 1 ? '' : 's'}',
                    '${provider.elapsedMs}ms',
                    if (provider.errorKind != null)
                      'Error kind: ${provider.errorKind}',
                    if (provider.errorMessage != null) provider.errorMessage!,
                  ].join(' • '),
                ),
              ),
          ],
        ),
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
      if (error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return 'Search took too long to respond. Try again.';
      }
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
