import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../models/track.dart';
import '../../models/track_analysis.dart';
import '../api/api_client.dart';
import 'waveform_peak_cache.dart';

/// Analysis hydration, enrichment and revision bookkeeping for the import
/// queue.
///
/// Extracted from `QueueProvider` in step 5 of the ADR 0012 reconciliation
/// (`docs/adr/0012-import-queue-is-not-the-playback-queue.md`): the provider
/// keeps the import-queue concerns (download jobs, retries, mutations) and
/// this store owns "what analysis do we hold for a backend track id".
///
/// Two contracts this class exists to preserve, both easy to lose in a
/// verbatim move:
///
/// * [ingestCompact] is the typed entry point for the batched compact payload
///   that rides every queue response
///   (`backend/internal/queue/handlers.go:661-683`). The payload arrives as
///   `QueueTrack.analysis`; the store must never read provider state to find
///   it, because that path is the only reason compact analysis reaches the
///   client at all.
/// * [retain] is multi-root: the retained set is the UNION of every root's
///   claim, so a DJ deck and a timeline looking at different views both stay
///   hydrated, and releasing one root drops only that root's claim.
class TrackAnalysisStore {
  static const Duration defaultRetryCooldown = Duration(seconds: 15);

  /// Root used by callers that own the whole hydration surface rather than one
  /// lane of it, and by the opportunistic pins [trackWithAnalysis] takes.
  static const String defaultHydrationRoot = 'default';

  /// Detailed analysis is expensive to hold, so the union across roots is
  /// capped: at most [maxHydrationRoots] surfaces, each pinning at most
  /// [maxHydrationKeysPerRoot] tracks.
  static const int maxHydrationKeysPerRoot = 128;
  static const int maxHydrationRoots = 8;
  static const int _maxConcurrentRequests = 3;
  static const int _maxRequestAttempts = 4;
  static const int _maxRetainedAuthorityEntries = 128;
  static const int _maxRetainedBeatPositions = 128;
  static const int _maxRetainedDownbeatPositions = 64;
  static const Duration _maxRetryDelay = Duration(minutes: 2);

  final ApiClient _apiClient;
  final DateTime Function() _clock;
  final Duration _retryCooldown;

  /// The provider's queue-patch hook: an accepted override has to land in the
  /// import queue rows the user is looking at.
  final void Function(int trackId, TrackAnalysis analysis)? _onAnalysisApplied;

  /// Mirrors the provider's notify cadence: called exactly where the analysis
  /// half used to call `notifyListeners()`.
  final VoidCallback? _onChanged;

  final WaveformPeakCache _waveforms;

  final Map<String, TrackAnalysis> _analysisByTrackId = {};
  final Map<String, int> _appliedCompactAnalysisSignatures = {};
  final Map<String, TrackAnalysis> _lastIncomingAnalysisByTrackId = {};
  final Map<String, DateTime> _revisionFloors = {};
  final Map<String, TrackAnalysis> _revisionSnapshots = {};
  final Map<String, int> _generations = {};
  final Map<String, Future<void>> _overrideMutationTails = {};
  final Map<String, TrackAnalysis> _authoritativeLocks = {};
  final LinkedHashSet<String> _authorityLru = LinkedHashSet<String>();

  /// Retention claims keyed by root, ordered least-recently-claimed first.
  ///
  /// Each surface owns a named root so the timeline, the deck, and the import
  /// queue can pin analysis without evicting each other; the effective set is
  /// the union below, which is what every hydration check reads.
  final LinkedHashMap<String, List<String>> _hydrationRoots =
      LinkedHashMap<String, List<String>>();
  final Set<String> _hydrationInterest = {};
  final Set<String> _requestsInFlight = {};
  final Set<String> _requestsQueued = {};
  final Queue<_AnalysisRequest> _requestQueue = Queue<_AnalysisRequest>();
  final Map<String, DateTime> _lastRequestedAt = {};
  final Map<String, Timer> _retryTimers = {};
  final Map<String, int> _requestAttempts = {};
  final Map<String, int> _transportFailures = {};
  final Map<String, int> _analyzedDetailLessResponses = {};
  final Set<String> _permanentFailures = {};
  final Map<String, _EnrichedTrackCacheEntry> _enrichedTrackCache = {};

  /// Keys the import queue currently holds. Refreshed by the provider on every
  /// queue mutation so a prune here never needs provider state.
  Set<String> _queueKeys = {};

  int _revision = 0;
  bool _disposed = false;

  TrackAnalysisStore(
    this._apiClient, {
    required WaveformPeakCache waveforms,
    DateTime Function()? clock,
    Duration retryCooldown = defaultRetryCooldown,
    void Function(int trackId, TrackAnalysis analysis)? onAnalysisApplied,
    VoidCallback? onChanged,
  })  : _waveforms = waveforms,
        _clock = clock ?? DateTime.now,
        _retryCooldown = retryCooldown,
        _onAnalysisApplied = onAnalysisApplied,
        _onChanged = onChanged;

  int get analysisRevision => _revision;

  /// Bounded-retention count the provider surfaces to tests through its own
  /// `retainedAnalysisAuthorityCount` getter.
  int get retainedAuthorityCount => _authorityKeys().length;

  /// True while an override save is still serialized for some track.
  bool get hasPendingOverrideMutations => _overrideMutationTails.isNotEmpty;

  /// Completes when every queued override save has settled. Callers that
  /// reconcile the queue re-read it after this so a correction cannot land
  /// underneath the reload.
  Future<void> awaitPendingOverrideMutations() =>
      Future.wait(_overrideMutationTails.values.toList(growable: false));

  /// The numeric backend analysis id a track resolves to, if any.
  ///
  /// One parsing rule for both the analysis store and the import queue that
  /// carries its rows: a positive `playbackTrackId` wins over the row id.
  static int? analysisTrackIdFor(QueueTrack track) {
    for (final candidate in [track.playbackTrackId, track.id]) {
      if (candidate == null) continue;
      final parsed = int.tryParse(candidate);
      if (parsed != null && parsed > 0) return parsed;
    }
    return null;
  }

  /// Attach hydrated analysis by backend track ID. Collection responses carry
  /// tempo metadata but intentionally omit large waveform arrays, so the
  /// timeline hydrates those arrays lazily from the per-track endpoint.
  QueueTrack trackWithAnalysis(
    QueueTrack track, {
    bool requestHydration = true,
  }) {
    final trackId = _analysisTrackId(track);
    if (trackId == null) {
      return track;
    }

    final key = trackId.toString();
    final incoming = track.analysis;
    if (incoming != null &&
        !identical(_lastIncomingAnalysisByTrackId[key], incoming)) {
      _lastIncomingAnalysisByTrackId[key] = incoming;
      _ingestIncomingAnalysis(key, incoming);
    }

    if (requestHydration) {
      _retainAmbientHydration(key);
      _fetchAnalysisIfNeeded(trackId);
    }
    final cached = _analysisByTrackId[key] ??
        _authoritativeLocks[key] ??
        _revisionSnapshots[key];
    final result = cached == null || identical(cached, incoming)
        ? track
        : _enrichedTrack(track, key, cached);
    if (cached != null) _touchAuthority(key);
    _pruneAuthorityState();
    return result;
  }

  /// Fetches the correction editor's immutable base from the authoritative
  /// per-track endpoint, bypassing collection/cache freshness heuristics.
  Future<TrackAnalysis> refreshAuthoritatively(QueueTrack track) async {
    final trackId = _analysisTrackId(track);
    if (trackId == null) {
      throw ApiException('Track does not have a backend analysis id', 400);
    }
    final key = trackId.toString();
    final analysis = await _apiClient.getTrackAnalysis(trackId);
    if (_disposed) return analysis;
    _ingestIncomingAnalysis(key, analysis);
    final accepted = _analysisByTrackId[key] ??
        _authoritativeLocks[key] ??
        _revisionSnapshots[key] ??
        analysis;
    _touchAuthority(key);
    _onChanged?.call();
    return accepted;
  }

  /// Applies the batched compact analysis payload that rides every queue
  /// response and returns each track resolved against the analysis this store
  /// holds.
  ///
  /// The payload arrives on the tracks themselves (`track.analysis`), which is
  /// exactly how `compactAnalysisForState` ships it
  /// (`backend/internal/queue/handlers.go:661-683`). Reading it from here —
  /// rather than reaching back into the provider — is what keeps the batched
  /// path intact.
  List<QueueTrack> ingestCompact(Iterable<QueueTrack> tracks) {
    final resolvedTracks = <QueueTrack>[];
    for (final track in tracks) {
      final trackId = _analysisTrackId(track);
      if (trackId == null) {
        resolvedTracks.add(track);
        continue;
      }

      final key = trackId.toString();
      final incoming = track.analysis;
      if (incoming != null) {
        _lastIncomingAnalysisByTrackId[key] = incoming;
        _ingestIncomingAnalysis(key, incoming);
      }
      final resolved = _authoritativeLocks[key] ??
          _analysisByTrackId[key] ??
          _revisionSnapshots[key] ??
          incoming;
      resolvedTracks.add(
        resolved == null || identical(resolved, incoming)
            ? track
            : track.copyWith(analysis: resolved),
      );
    }
    return resolvedTracks;
  }

  /// Remembers the analysis currently carried by the import queue rows and
  /// refreshes the keys an authority prune treats as active.
  ///
  /// Called by the provider at the same points its `_rememberQueueAnalyses`
  /// ran, so bounded retention keeps counting live queue members.
  void rememberQueueAnalyses(Iterable<QueueTrack> tracks) {
    final queueTracks = tracks.toList(growable: false);
    _queueKeys = {
      for (final track in queueTracks)
        if (_analysisTrackId(track) case final trackId?) trackId.toString(),
    };
    for (final track in queueTracks) {
      _rememberTrackAnalysis(track);
    }
    _pruneAuthorityState();
  }

  /// Retains detailed analysis only for tracks a surface is actually showing.
  ///
  /// Collection payloads already carry compact BPM/key metadata. Waveform
  /// arrays are hydrated only while a lane needs them, which keeps removed
  /// tracks and hidden history from continuing background work.
  ///
  /// [rootId] names the claiming surface. Roots pin independently — the
  /// retained set is the union across roots — so a deck and a timeline looking
  /// at different tracks cannot evict each other's hydration, and releasing one
  /// root drops only that root's claim.
  ///
  /// Callers provide tracks in priority order. Requests that have not started
  /// are reordered to match the latest viewport while the existing in-flight
  /// cap, retry cooldown, and generation checks remain authoritative. A root
  /// keeps at most [maxHydrationKeysPerRoot] of them so the union stays
  /// bounded no matter how many surfaces claim at once.
  void retain(String rootId, Iterable<QueueTrack> tracks) {
    final retainedTracks = tracks.toList(growable: false);
    final claim = <String>[];
    final claimed = <String>{};
    for (final track in retainedTracks) {
      final trackId = _analysisTrackId(track);
      if (trackId == null) continue;
      final key = trackId.toString();
      if (claimed.add(key)) claim.add(key);
    }
    // Queue new requests before applying the final cross-root priority once.
    _applyHydrationClaim(rootId, claim, reprioritize: false);

    for (final track in retainedTracks) {
      final trackId = _analysisTrackId(track);
      if (trackId == null) continue;
      final key = trackId.toString();
      final incoming = track.analysis;
      if (incoming != null &&
          !identical(_lastIncomingAnalysisByTrackId[key], incoming)) {
        _lastIncomingAnalysisByTrackId[key] = incoming;
        _ingestIncomingAnalysis(key, incoming);
      }
      _fetchAnalysisIfNeeded(trackId);
    }
    // [_applyHydrationClaim] can only reprioritize requests that were already
    // queued. Put newly queued tracks from the claiming root in front of older
    // roots as well, so the freshest viewport really does lead.
    _reprioritizeQueuedRequests(_hydrationKeysByPriority(rootId));
    _pruneAuthorityState();
  }

  /// Drops [rootId]'s claim. Tracks another root still pins stay hydrated.
  void release(String rootId) {
    if (!_hydrationRoots.containsKey(rootId)) return;
    _applyHydrationClaim(rootId, const <String>[]);
    _pruneAuthorityState();
  }

  /// Single-root entry point for surfaces that own the whole hydration window;
  /// equivalent to claiming [defaultHydrationRoot].
  void retainDefault(Iterable<QueueTrack> tracks) =>
      retain(defaultHydrationRoot, tracks);

  void clearDefault() {
    if (!_hydrationRoots.containsKey(defaultHydrationRoot)) {
      return;
    }
    release(defaultHydrationRoot);
  }

  /// [trackWithAnalysis] pins opportunistically, with no viewport to bound it,
  /// so those keys ride the default root and the oldest one yields at the cap.
  /// Reprioritization is left alone: an incidental pin says nothing about what
  /// the already queued requests should do next.
  void _retainAmbientHydration(String key) {
    final claim = _hydrationRoots[defaultHydrationRoot];
    if (claim != null && claim.contains(key)) return;
    final next = [...?claim, key];
    _applyHydrationClaim(
      defaultHydrationRoot,
      next.length > maxHydrationKeysPerRoot
          ? next.sublist(next.length - maxHydrationKeysPerRoot)
          : next,
      reprioritize: false,
    );
  }

  void _applyHydrationClaim(
    String rootId,
    List<String> claim, {
    bool reprioritize = true,
  }) {
    // Re-inserting keeps the map least-recently-claimed first, so the root cap
    // below sheds the stalest surface rather than the one that just spoke.
    _hydrationRoots.remove(rootId);
    if (claim.isNotEmpty) {
      _hydrationRoots[rootId] = claim.length > maxHydrationKeysPerRoot
          ? claim.sublist(0, maxHydrationKeysPerRoot)
          : claim;
      while (_hydrationRoots.length > maxHydrationRoots) {
        _hydrationRoots.remove(_hydrationRoots.keys.first);
      }
    }

    final next = _hydrationKeysByPriority(rootId);
    final removed = _hydrationInterest.difference(next.toSet());
    if (removed.isNotEmpty) {
      for (final key in removed) {
        _releaseHydration(key);
      }
      _requestQueue.removeWhere(
        (request) => removed.contains(request.trackId.toString()),
      );
    }
    _hydrationInterest
      ..clear()
      ..addAll(next);
    if (reprioritize) _reprioritizeQueuedRequests(next);
  }

  /// The claiming root leads: it just described the freshest viewport. Every
  /// other root still contributes, because [_reprioritizeQueuedRequests]
  /// drops queued work it is not handed.
  List<String> _hydrationKeysByPriority(String leadRootId) {
    final ordered = <String>[];
    final seen = <String>{};
    void take(String rootId) {
      for (final key in _hydrationRoots[rootId] ?? const <String>[]) {
        if (seen.add(key)) ordered.add(key);
      }
    }

    take(leadRootId);
    for (final rootId in _hydrationRoots.keys) {
      if (rootId != leadRootId) take(rootId);
    }
    return ordered;
  }

  void _reprioritizeQueuedRequests(Iterable<String> priorityKeys) {
    if (_requestQueue.length < 2) return;
    final queuedByKey = <String, _AnalysisRequest>{
      for (final request in _requestQueue) request.trackId.toString(): request,
    };
    _requestQueue
      ..clear()
      ..addAll([
        for (final key in priorityKeys)
          if (queuedByKey[key] case final request?) request,
      ]);
  }

  Future<TrackAnalysis> updateOverrides(
    QueueTrack track,
    TrackAnalysisOverrides overrides, {
    int? expectedRevision,
  }) {
    final trackId = _analysisTrackId(track);
    if (trackId == null) {
      throw ApiException('Track does not have a backend analysis id', 400);
    }

    final key = trackId.toString();
    final previous = _overrideMutationTails[key];
    final result = () async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // A newer correction should still run after an older save fails.
        }
      }
      return _performOverrideUpdate(
        trackId: trackId,
        key: key,
        overrides: overrides,
        analysisBeingEdited: track.analysis,
        expectedRevision: expectedRevision,
      );
    }();
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (_, __) {});
    _overrideMutationTails[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_overrideMutationTails[key], tail)) {
          _overrideMutationTails.remove(key);
          _pruneAuthorityState();
        }
      }),
    );
    return result;
  }

  Future<TrackAnalysis> _performOverrideUpdate({
    required int trackId,
    required String key,
    required TrackAnalysisOverrides overrides,
    required TrackAnalysis? analysisBeingEdited,
    required int? expectedRevision,
  }) async {
    final prior = expectedRevision == null
        ? _authoritativeLocks[key] ??
            _analysisByTrackId[key] ??
            _revisionSnapshots[key] ??
            _lastIncomingAnalysisByTrackId[key] ??
            analysisBeingEdited
        : null;
    final analysis = await _apiClient.updateTrackAnalysisOverrides(
      trackId,
      overrides,
      expectedRevision:
          expectedRevision ?? (prior == null ? 0 : _overrideRevision(prior)),
    );
    if (_disposed) return analysis;
    _rememberAnalysisRevision(key, analysis);
    _authoritativeLocks[key] = _compactRevisionSnapshot(analysis);
    _touchAuthority(key);
    _advanceGeneration(key);
    _analysisByTrackId[key] = analysis;
    _lastIncomingAnalysisByTrackId[key] = analysis;
    _appliedCompactAnalysisSignatures[key] = _compactSignature(analysis);
    _resetRequestState(key);
    _invalidateAnalysisCache(key);
    _onAnalysisApplied?.call(trackId, analysis);
    _pruneAuthorityState();
    _onChanged?.call();
    return analysis;
  }

  void _rememberTrackAnalysis(QueueTrack track) {
    final analysis = track.analysis;
    final trackId = _analysisTrackId(track);
    if (analysis == null || trackId == null) return;
    final key = trackId.toString();
    _lastIncomingAnalysisByTrackId[key] = analysis;
    _ingestIncomingAnalysis(key, analysis);
  }

  bool _ingestIncomingAnalysis(String key, TrackAnalysis analysis) {
    if (!_acceptIncomingAnalysis(key, analysis)) return false;

    _touchAuthority(key);
    _rememberAnalysisRevision(key, analysis);
    final signature = _compactSignature(analysis);
    final cached = _analysisByTrackId[key];
    if (_hasWaveformDetail(analysis)) {
      _analyzedDetailLessResponses.remove(key);
      if (!identical(cached, analysis)) {
        _advanceGeneration(key);
        _analysisByTrackId[key] = analysis;
        _appliedCompactAnalysisSignatures[key] = signature;
        _resetRequestState(key);
        _invalidateAnalysisCache(key);
      }
      return true;
    }

    // Collection snapshots can remain pending after a newer per-track GET has
    // returned analyzed detail. Apply each distinct compact snapshot once so a
    // rebuild never downgrades that hydrated result back to the stale state.
    if (_appliedCompactAnalysisSignatures[key] == signature) {
      if (cached != null && _revisionSupersedes(analysis, cached)) {
        _advanceGeneration(key);
        _analysisByTrackId[key] = analysis;
        _resetRequestState(key);
        _invalidateAnalysisCache(key);
      }
      return true;
    }

    _advanceGeneration(key);
    _appliedCompactAnalysisSignatures[key] = signature;
    final preservesCachedDetail = cached != null &&
        _hasWaveformDetail(cached) &&
        !_revisionSupersedes(analysis, cached);
    _analysisByTrackId[key] = preservesCachedDetail
        ? _mergeDetailedAnalysis(cached, analysis)
        : analysis;
    _resetRequestState(key);
    _invalidateAnalysisCache(key);
    return true;
  }

  bool _acceptIncomingAnalysis(String key, TrackAnalysis analysis) {
    final cached = _authoritativeLocks[key] ??
        _analysisByTrackId[key] ??
        _revisionSnapshots[key];
    final incomingOverrideRevision = _overrideRevision(analysis);
    final cachedOverrideRevision =
        cached == null ? null : _overrideRevision(cached);
    if (cachedOverrideRevision != null &&
        incomingOverrideRevision != cachedOverrideRevision) {
      if (incomingOverrideRevision < cachedOverrideRevision) return false;
      _authoritativeLocks.remove(key);
      return true;
    }

    if (_analysisPredatesFloor(key, analysis)) return false;

    final authoritative = _authoritativeLocks[key];
    if (authoritative == null || identical(authoritative, analysis)) {
      return true;
    }

    final incomingRevision = analysis.updatedAt;
    if (incomingRevision == null) {
      return _compactSignature(analysis) == _compactSignature(authoritative);
    }

    final authoritativeRevision = authoritative.updatedAt;
    if (authoritativeRevision != null &&
        incomingRevision.isBefore(authoritativeRevision)) {
      return false;
    }
    _authoritativeLocks.remove(key);
    return true;
  }

  bool _analysisPredatesFloor(String key, TrackAnalysis analysis) {
    final snapshot = _revisionSnapshots[key];
    final incomingOverrideRevision = _overrideRevision(analysis);
    final snapshotOverrideRevision =
        snapshot == null ? null : _overrideRevision(snapshot);
    if (snapshotOverrideRevision != null &&
        incomingOverrideRevision != snapshotOverrideRevision) {
      return incomingOverrideRevision < snapshotOverrideRevision;
    }

    final floor = _revisionFloors[key];
    if (floor == null) return false;
    final revision = analysis.updatedAt;
    return revision == null || revision.isBefore(floor);
  }

  void _rememberAnalysisRevision(String key, TrackAnalysis analysis) {
    final revision = analysis.updatedAt;
    if (revision == null) return;
    final snapshot = _revisionSnapshots[key];
    if (snapshot != null && !_revisionSupersedes(analysis, snapshot)) {
      return;
    }
    final floor = _revisionFloors[key];
    if (snapshot == null && floor != null && revision.isBefore(floor)) return;
    _revisionFloors[key] = revision;
    _revisionSnapshots[key] = _compactRevisionSnapshot(analysis);
    _touchAuthority(key);
  }

  TrackAnalysis _compactRevisionSnapshot(TrackAnalysis analysis) {
    final sourceSummary = analysis.summary;
    final sourceOverrides = analysis.overrides;
    final summary = _compactAnalysisSummary(sourceSummary);
    final overrides = sourceOverrides == null
        ? null
        : TrackAnalysisOverrides(
            manualTiming: sourceOverrides.manualTiming,
            bpm: sourceOverrides.bpm,
            bpmConfidence: sourceOverrides.bpmConfidence,
            beatGridOffsetMs: sourceOverrides.beatGridOffsetMs,
            beatsMs: sourceOverrides.beatsMs == null
                ? null
                : _boundedMarkerPositions(
                    sourceOverrides.beatsMs!,
                    _maxRetainedBeatPositions,
                  ),
            downbeatsMs: sourceOverrides.downbeatsMs == null
                ? null
                : _boundedMarkerPositions(
                    sourceOverrides.downbeatsMs!,
                    _maxRetainedDownbeatPositions,
                  ),
            musicalKey: sourceOverrides.musicalKey,
            camelot: sourceOverrides.camelot,
            provenance: sourceOverrides.provenance,
            bpmProvenance: sourceOverrides.bpmProvenance,
            beatGridProvenance: sourceOverrides.beatGridProvenance,
            downbeatProvenance: sourceOverrides.downbeatProvenance,
          );
    return TrackAnalysis(
      status: analysis.status,
      generatedSummary: _compactAnalysisSummary(analysis.generatedSummary),
      summary: summary,
      overrides: overrides,
      overridesPresent: analysis.overridesPresent,
      updatedAt: analysis.updatedAt,
      overrideRevision: analysis.overrideRevision,
      overrideUpdatedAt: analysis.overrideUpdatedAt,
    );
  }

  TrackAnalysisSummary? _compactAnalysisSummary(TrackAnalysisSummary? source) {
    if (source == null) return null;
    final beatGrid = source.beatGrid;
    final downbeats = source.downbeats;
    return TrackAnalysisSummary(
      bpm: source.bpm,
      beatGrid: beatGrid == null
          ? null
          : BeatGridSummary(
              bpm: beatGrid.bpm,
              offsetMs: beatGrid.offsetMs,
              beatsMs: _boundedMarkerPositions(
                beatGrid.beatsMs,
                _maxRetainedBeatPositions,
              ),
              confidence: beatGrid.confidence,
              provenance: beatGrid.provenance,
            ),
      meter: source.meter,
      downbeatPhase: source.downbeatPhase,
      downbeats: downbeats == null
          ? null
          : DownbeatSummary(
              positionsMs: _boundedMarkerPositions(
                downbeats.positionsMs,
                _maxRetainedDownbeatPositions,
              ),
              confidence: downbeats.confidence,
              provenance: downbeats.provenance,
            ),
      key: source.key,
      camelot: source.camelot,
      energy: source.energy,
    );
  }

  List<int> _boundedMarkerPositions(List<int> positions, int limit) {
    if (positions.length <= limit) {
      return List<int>.unmodifiable(positions);
    }
    final headLength = limit ~/ 2;
    final tailLength = limit - headLength;
    return List<int>.unmodifiable([
      ...positions.take(headLength),
      ...positions.skip(positions.length - tailLength),
    ]);
  }

  bool _revisionSupersedes(TrackAnalysis incoming, TrackAnalysis cached) {
    final incomingOverrideRevision = _overrideRevision(incoming);
    final cachedOverrideRevision = _overrideRevision(cached);
    if (incomingOverrideRevision != cachedOverrideRevision) {
      return incomingOverrideRevision > cachedOverrideRevision;
    }
    final incomingRevision = incoming.updatedAt;
    if (incomingRevision == null) return false;
    final cachedRevision = cached.updatedAt;
    return cachedRevision == null || incomingRevision.isAfter(cachedRevision);
  }

  int _overrideRevision(TrackAnalysis analysis) =>
      analysis.overrideRevision ??
      analysis.overrides?.manualTiming?.revision ??
      0;

  bool _hasWaveformDetail(TrackAnalysis analysis) {
    final waveform = analysis.summary?.waveform;
    if (waveform == null) return false;
    if (waveform.peaks.isNotEmpty ||
        waveform.minPeaks.isNotEmpty ||
        waveform.maxPeaks.isNotEmpty ||
        waveform.rms.isNotEmpty ||
        _hasChannelSamples(waveform.channels?.values) ||
        _hasChannelSamples(waveform.spectralBands)) {
      return true;
    }
    return waveform.resolutions.any(
      (resolution) =>
          resolution.peaks.isNotEmpty ||
          resolution.minPeaks.isNotEmpty ||
          resolution.maxPeaks.isNotEmpty ||
          resolution.rms.isNotEmpty ||
          _hasChannelSamples(resolution.channels) ||
          _hasChannelSamples(resolution.spectralBands),
    );
  }

  bool _hasChannelSamples(Map<String, SpectralBandSummary>? channels) =>
      channels?.values.any((channel) => channel.values.isNotEmpty) ?? false;

  void _fetchAnalysisIfNeeded(int trackId) {
    final key = trackId.toString();
    if (!_hydrationInterest.contains(key) || !_analysisNeedsHydration(key)) {
      return;
    }
    if (_requestsInFlight.contains(key) || _requestsQueued.contains(key)) {
      return;
    }

    final now = _clock();
    final lastRequestedAt = _lastRequestedAt[key];
    if (lastRequestedAt != null &&
        now.difference(lastRequestedAt) < _retryCooldown) {
      _scheduleRetry(trackId, _retryCooldown - now.difference(lastRequestedAt));
      return;
    }

    _requestsQueued.add(key);
    _requestQueue.add(
      _AnalysisRequest(trackId: trackId, generation: _generations[key] ?? 0),
    );
    _drainRequests();
  }

  bool _analysisNeedsHydration(String key) {
    if (_permanentFailures.contains(key) ||
        (_transportFailures[key] ?? 0) >= _maxRequestAttempts ||
        (_analyzedDetailLessResponses[key] ?? 0) >= _maxRequestAttempts) {
      return false;
    }
    final cached = _analysisByTrackId[key];
    if (cached == null) return true;
    if (_hasWaveformDetail(cached) &&
        cached.status == TrackAnalysisStatus.analyzed) {
      _cancelRetry(key);
      return false;
    }
    if (cached.status == TrackAnalysisStatus.failed ||
        cached.status == TrackAnalysisStatus.unsupported) {
      _cancelRetry(key);
      return false;
    }
    return true;
  }

  void _drainRequests() {
    while (!_disposed &&
        _requestsInFlight.length < _maxConcurrentRequests &&
        _requestQueue.isNotEmpty) {
      final request = _requestQueue.removeFirst();
      final trackId = request.trackId;
      final key = trackId.toString();
      _requestsQueued.remove(key);
      if (_requestsInFlight.contains(key) ||
          !_hydrationInterest.contains(key)) {
        continue;
      }
      if ((_generations[key] ?? 0) != request.generation) {
        _fetchAnalysisIfNeeded(trackId);
        continue;
      }
      if (!_analysisNeedsHydration(key)) {
        continue;
      }
      _startRequest(request);
    }
  }

  void _startRequest(_AnalysisRequest request) {
    final trackId = request.trackId;
    final key = trackId.toString();
    final generation = request.generation;
    _lastRequestedAt[key] = _clock();
    _requestAttempts[key] = (_requestAttempts[key] ?? 0) + 1;
    _requestsInFlight.add(key);
    unawaited(() async {
      var shouldRetry = false;
      try {
        final analysis = await _apiClient.getTrackAnalysis(trackId);
        if (_disposed) return;
        if (!_hydrationInterest.contains(key) ||
            (_generations[key] ?? 0) != generation) {
          return;
        }

        if (!_ingestIncomingAnalysis(key, analysis)) {
          shouldRetry = true;
          return;
        }
        _permanentFailures.remove(key);
        _transportFailures.remove(key);
        final accepted = _analysisByTrackId[key] ?? analysis;
        if (accepted.status == TrackAnalysisStatus.analyzed &&
            !_hasWaveformDetail(accepted)) {
          _analyzedDetailLessResponses[key] =
              (_analyzedDetailLessResponses[key] ?? 0) + 1;
        } else {
          _analyzedDetailLessResponses.remove(key);
        }
        if (_hasWaveformDetail(accepted) &&
            accepted.status == TrackAnalysisStatus.analyzed) {
          _lastRequestedAt.remove(key);
          _requestAttempts.remove(key);
          _cancelRetry(key);
        } else {
          shouldRetry = analysis.status != TrackAnalysisStatus.failed &&
              analysis.status != TrackAnalysisStatus.unsupported;
        }
        _invalidateAnalysisCache(key);
        _onChanged?.call();
      } catch (error) {
        // Analysis is progressive enhancement. Playback and queue editing must
        // keep working if an individual track has no analyzed artifact yet.
        shouldRetry = _isRetryableAnalysisError(error);
        if (shouldRetry) {
          _transportFailures[key] = (_transportFailures[key] ?? 0) + 1;
        } else {
          _permanentFailures.add(key);
        }
      } finally {
        _requestsInFlight.remove(key);
        if (!_disposed) {
          final stillInterested = _hydrationInterest.contains(key);
          final sameGeneration = (_generations[key] ?? 0) == generation;
          if (shouldRetry && stillInterested && sameGeneration) {
            _scheduleRetry(trackId, _retryDelay(key));
          } else if (stillInterested && !sameGeneration) {
            _fetchAnalysisIfNeeded(trackId);
          }
          _drainRequests();
          _pruneAuthorityState();
        }
      }
    }());
  }

  void _scheduleRetry(int trackId, Duration delay) {
    final key = trackId.toString();
    if (_disposed ||
        !_hydrationInterest.contains(key) ||
        !_analysisNeedsHydration(key) ||
        _retryTimers.containsKey(key)) {
      return;
    }
    final generation = _generations[key] ?? 0;
    final retryDelay = delay.isNegative ? Duration.zero : delay;
    _retryTimers[key] = Timer(retryDelay, () {
      _retryTimers.remove(key);
      if (_disposed ||
          !_hydrationInterest.contains(key) ||
          (_generations[key] ?? 0) != generation) {
        return;
      }
      _lastRequestedAt.remove(key);
      _fetchAnalysisIfNeeded(trackId);
    });
  }

  Duration _retryDelay(String key) {
    final attempt = (_requestAttempts[key] ?? 1).clamp(1, 16);
    final multiplier = 1 << (attempt - 1);
    final milliseconds = (_retryCooldown.inMilliseconds * multiplier)
        .clamp(0, _maxRetryDelay.inMilliseconds)
        .toInt();
    return Duration(milliseconds: milliseconds);
  }

  bool _isRetryableAnalysisError(Object error) {
    if (error is! ApiException) return true;
    final statusCode = error.statusCode;
    return statusCode <= 0 ||
        statusCode == 408 ||
        statusCode == 425 ||
        statusCode == 429 ||
        statusCode >= 500;
  }

  void _cancelRetry(String key) {
    _retryTimers.remove(key)?.cancel();
  }

  void _resetRequestState(String key) {
    _lastRequestedAt.remove(key);
    _requestAttempts.remove(key);
    _transportFailures.remove(key);
    _permanentFailures.remove(key);
    _cancelRetry(key);
  }

  Set<String> _authorityKeys() => <String>{
        ..._revisionFloors.keys,
        ..._revisionSnapshots.keys,
        ..._generations.keys,
        ..._authoritativeLocks.keys,
        ..._appliedCompactAnalysisSignatures.keys,
        ..._lastIncomingAnalysisByTrackId.keys,
        ..._analysisByTrackId.keys,
        ..._lastRequestedAt.keys,
        ..._requestAttempts.keys,
        ..._transportFailures.keys,
        ..._analyzedDetailLessResponses.keys,
        ..._permanentFailures,
        ..._requestsQueued,
        ..._requestsInFlight,
        ..._retryTimers.keys,
      };

  Set<String> _activeAuthorityKeys() {
    final active = <String>{
      ..._hydrationInterest,
      ..._overrideMutationTails.keys,
      ..._requestsInFlight,
      ..._queueKeys,
    };
    return active;
  }

  void _touchAuthority(String key) {
    _authorityLru
      ..remove(key)
      ..add(key);
  }

  /// Bounds retained authority state. When [queueTracks] is given the import
  /// queue's active keys are refreshed first, which is what the provider's
  /// direct prune call sites need after they mutate the queue locally.
  void prune([Iterable<QueueTrack>? queueTracks]) {
    if (queueTracks != null) {
      _queueKeys = {
        for (final track in queueTracks)
          if (_analysisTrackId(track) case final trackId?) trackId.toString(),
      };
    }
    _pruneAuthorityState();
  }

  void _pruneAuthorityState() {
    if (_disposed) return;

    // Detailed waveform payloads only belong to visible timeline lanes. The
    // revision snapshots and correction locks below are compact metadata.
    final detailKeys = <String>{
      ..._analysisByTrackId.keys,
      ..._lastIncomingAnalysisByTrackId.keys,
    };
    for (final key in detailKeys) {
      if (_hydrationInterest.contains(key)) continue;
      final cached = _analysisByTrackId[key];
      final compactedAnalysis =
          cached != null && _analysisNeedsAuthorityCompaction(cached);
      if (cached != null && compactedAnalysis) {
        _analysisByTrackId[key] = _compactRevisionSnapshot(cached);
      }
      final removedIncoming = _lastIncomingAnalysisByTrackId.remove(key);
      if (compactedAnalysis || removedIncoming != null) {
        _invalidateAnalysisCache(key);
      }
    }

    final authorityKeys = _authorityKeys();
    _authorityLru.removeWhere((key) => !authorityKeys.contains(key));
    for (final key in authorityKeys) {
      _authorityLru.add(key);
    }

    final active = _activeAuthorityKeys();
    var retainedOffQueue =
        _authorityLru.where((key) => !active.contains(key)).length;
    while (retainedOffQueue > _maxRetainedAuthorityEntries) {
      String? evicted;
      for (final key in _authorityLru) {
        if (!active.contains(key)) {
          evicted = key;
          break;
        }
      }
      if (evicted == null) break;
      _evictAuthority(evicted);
      retainedOffQueue--;
    }
  }

  void _evictAuthority(String key) {
    _authorityLru.remove(key);
    _revisionFloors.remove(key);
    _revisionSnapshots.remove(key);
    _generations.remove(key);
    _authoritativeLocks.remove(key);
    _appliedCompactAnalysisSignatures.remove(key);
    _lastIncomingAnalysisByTrackId.remove(key);
    _analysisByTrackId.remove(key);
    _lastRequestedAt.remove(key);
    _requestAttempts.remove(key);
    _transportFailures.remove(key);
    _analyzedDetailLessResponses.remove(key);
    _permanentFailures.remove(key);
    _requestsQueued.remove(key);
    _requestQueue.removeWhere((request) => request.trackId.toString() == key);
    _cancelRetry(key);
    _invalidateAnalysisCache(key);
  }

  bool _analysisNeedsAuthorityCompaction(TrackAnalysis analysis) {
    final summary = analysis.summary;
    if (summary == null) return false;
    return _hasWaveformDetail(analysis) ||
        (summary.beatGrid?.beatsMs.length ?? 0) > _maxRetainedBeatPositions ||
        (summary.downbeats?.positionsMs.length ?? 0) >
            _maxRetainedDownbeatPositions ||
        summary.loudness != null ||
        summary.truePeak != null ||
        summary.transients != null ||
        summary.silence != null ||
        summary.intro != null ||
        summary.outro != null ||
        summary.sections.isNotEmpty ||
        summary.cueCandidates.isNotEmpty;
  }

  void _releaseHydration(String key) {
    _advanceGeneration(key);
    _requestsQueued.remove(key);
    _resetRequestState(key);
    _analyzedDetailLessResponses.remove(key);
    _analysisByTrackId.remove(key);
    _appliedCompactAnalysisSignatures.remove(key);
    _lastIncomingAnalysisByTrackId.remove(key);
    _invalidateAnalysisCache(key);
    _pruneAuthorityState();
  }

  void _advanceGeneration(String key) {
    _generations[key] = (_generations[key] ?? 0) + 1;
    _touchAuthority(key);
  }

  TrackAnalysis _mergeDetailedAnalysis(
    TrackAnalysis detailed,
    TrackAnalysis incoming,
  ) {
    final generatedSummary = _deepMergeAnalysisMaps(
      detailed.generatedSummary?.toJson() ?? const <String, dynamic>{},
      incoming.generatedSummary?.toJson() ?? const <String, dynamic>{},
    );
    final effectiveBase = incoming.overridesPresent
        ? _summaryWithoutAppliedOverrides(detailed)
        : detailed.summary?.toJson() ?? const <String, dynamic>{};
    final effectiveSummary = _deepMergeAnalysisMaps(
      effectiveBase,
      incoming.summary?.toJson() ?? const <String, dynamic>{},
    );
    final hasGeneratedSummary = generatedSummary.isNotEmpty;
    final overrides = incoming.overridesPresent
        ? incoming.overrides?.toJson() ?? const <String, dynamic>{}
        : detailed.overrides?.toJson();
    return TrackAnalysis.fromJson(
      status: incoming.status.name,
      summary: hasGeneratedSummary
          ? generatedSummary
          : (effectiveSummary.isEmpty ? null : effectiveSummary),
      overrides: overrides,
      overridesPresent: incoming.overridesPresent || detailed.overridesPresent,
      updatedAt: incoming.updatedAt ?? detailed.updatedAt,
      overrideRevision: incoming.overrideRevision ?? detailed.overrideRevision,
      overrideUpdatedAt:
          incoming.overrideUpdatedAt ?? detailed.overrideUpdatedAt,
      summaryProjection: hasGeneratedSummary
          ? TrackAnalysisSummaryProjection.generated
          : TrackAnalysisSummaryProjection.effective,
    );
  }

  /// Removes only facts invalidated by the incoming override from an
  /// already-effective summary. This map is never promoted to generated
  /// provenance; it exists solely to retain non-compact detail safely.
  Map<String, dynamic> _summaryWithoutAppliedOverrides(TrackAnalysis analysis) {
    final summary = Map<String, dynamic>.from(
      analysis.summary?.toJson() ?? const <String, dynamic>{},
    );
    final overrides = analysis.overrides;
    if (overrides == null) return summary;

    final manualTiming = overrides.manualTiming;
    if (manualTiming != null) {
      if (manualTiming.bpm != null) summary.remove('bpm');
      final beatGrid = _mutableNestedMap(summary, 'beat_grid');
      if (beatGrid != null) {
        if (manualTiming.bpm != null || manualTiming.beatAnchorMs != null) {
          beatGrid
            ..remove('bpm')
            ..remove('offset_ms')
            ..remove('beats_ms')
            ..remove('confidence')
            ..remove('provenance');
        }
        if (beatGrid.isEmpty) summary.remove('beat_grid');
      }
      if (manualTiming.bpm != null ||
          manualTiming.beatAnchorMs != null ||
          manualTiming.beatsPerBar != null ||
          manualTiming.downbeatPhaseIndex != null) {
        summary.remove('downbeats');
      }
      if (manualTiming.beatsPerBar != null) {
        summary.remove('meter');
        summary.remove('downbeat_phase');
      } else if (manualTiming.downbeatPhaseIndex != null) {
        summary.remove('downbeat_phase');
      }
    }

    if (overrides.bpm != null) summary.remove('bpm');
    final beatGrid = _mutableNestedMap(summary, 'beat_grid');
    if (beatGrid != null) {
      if (overrides.bpm != null) {
        beatGrid
          ..remove('bpm')
          ..remove('confidence')
          ..remove('provenance');
      }
      if (overrides.beatsMs != null) {
        beatGrid
          ..remove('beats_ms')
          ..remove('confidence')
          ..remove('provenance');
      }
      if (overrides.beatGridOffsetMs != null) {
        beatGrid.remove('offset_ms');
      }
      if (beatGrid.isEmpty) summary.remove('beat_grid');
    }
    if (overrides.downbeatsMs != null) summary.remove('downbeats');
    if (overrides.musicalKey != null) summary.remove('key');
    if (overrides.camelot != null) summary.remove('camelot');
    return summary;
  }

  Map<String, dynamic>? _mutableNestedMap(
    Map<String, dynamic> parent,
    String key,
  ) {
    final value = parent[key];
    if (value is! Map) return null;
    final result = Map<String, dynamic>.from(value);
    parent[key] = result;
    return result;
  }

  Map<String, dynamic> _deepMergeAnalysisMaps(
    Map<String, dynamic> base,
    Map<String, dynamic> incoming,
  ) {
    final merged = Map<String, dynamic>.from(base);
    for (final entry in incoming.entries) {
      final existing = merged[entry.key];
      final value = entry.value;
      if (existing is Map && value is Map) {
        merged[entry.key] = _deepMergeAnalysisMaps(
          Map<String, dynamic>.from(existing),
          Map<String, dynamic>.from(value),
        );
      } else {
        merged[entry.key] = value;
      }
    }
    return merged;
  }

  QueueTrack _enrichedTrack(
    QueueTrack track,
    String analysisKey,
    TrackAnalysis analysis,
  ) {
    final cacheKey = '${track.queueItemId}|${track.id}|$analysisKey';
    final cached = _enrichedTrackCache[cacheKey];
    if (cached != null &&
        identical(cached.source, track) &&
        identical(cached.analysis, analysis)) {
      return cached.result;
    }
    final result = track.copyWith(analysis: analysis);
    _enrichedTrackCache[cacheKey] = _EnrichedTrackCacheEntry(
      source: track,
      analysis: analysis,
      result: result,
    );
    return result;
  }

  int _compactSignature(TrackAnalysis analysis) {
    final summary = analysis.summary;
    final timing = analysis.effectiveTiming;
    final beatGrid = timing.beatGrid;
    final downbeats = timing.downbeats;
    return Object.hash(
      analysis.status,
      analysis.overridesPresent,
      analysis.overrideRevision,
      analysis.overrideUpdatedAt,
      _valueSignature(timing.bpm),
      beatGrid == null
          ? null
          : Object.hash(
              beatGrid.bpm,
              beatGrid.offsetMs,
              beatGrid.confidence,
              beatGrid.provenance,
              Object.hashAll(beatGrid.beatsMs),
            ),
      downbeats == null
          ? null
          : Object.hash(
              downbeats.confidence,
              downbeats.provenance,
              Object.hashAll(downbeats.positionsMs),
            ),
      timing.meter == null
          ? null
          : Object.hash(
              timing.meter?.beatsPerBar,
              timing.meter?.confidence,
              timing.meter?.provenance,
            ),
      timing.downbeatPhase == null
          ? null
          : Object.hash(
              timing.downbeatPhase?.index,
              timing.downbeatPhase?.confidence,
              timing.downbeatPhase?.provenance,
            ),
      _valueSignature(summary?.key),
      _valueSignature(summary?.camelot),
      _valueSignature(summary?.energy),
      _overridesSignature(analysis.overrides),
    );
  }

  int? _overridesSignature(TrackAnalysisOverrides? overrides) =>
      overrides == null
          ? null
          : Object.hash(
              overrides.manualTiming?.bpm,
              overrides.manualTiming?.beatAnchorMs,
              overrides.manualTiming?.beatsPerBar,
              overrides.manualTiming?.downbeatPhaseIndex,
              overrides.manualTiming?.phraseLengthBars,
              overrides.manualTiming?.confidence,
              overrides.manualTiming?.provenance,
              overrides.manualTiming?.revision,
              overrides.manualTiming?.updatedAt,
              overrides.bpm,
              overrides.bpmConfidence,
              overrides.beatGridOffsetMs,
              overrides.beatsMs == null
                  ? null
                  : Object.hashAll(overrides.beatsMs!),
              overrides.downbeatsMs == null
                  ? null
                  : Object.hashAll(overrides.downbeatsMs!),
              overrides.musicalKey,
              overrides.camelot,
              overrides.provenance,
              overrides.bpmProvenance,
              overrides.beatGridProvenance,
              overrides.downbeatProvenance,
            );

  int? _valueSignature(AnalysisValue? value) => value == null
      ? null
      : Object.hash(value.value, value.confidence, value.provenance);

  void _invalidateAnalysisCache(String trackId) {
    _revision++;
    _waveforms.invalidateTrack(trackId);
    _enrichedTrackCache.removeWhere(
      (cacheKey, _) => cacheKey.endsWith('|$trackId'),
    );
  }

  void dispose() {
    _disposed = true;
    for (final timer in _retryTimers.values) {
      timer.cancel();
    }
    _retryTimers.clear();
    _hydrationRoots.clear();
    _hydrationInterest.clear();
    _requestQueue.clear();
    _requestsQueued.clear();
  }
}

class _AnalysisRequest {
  final int trackId;
  final int generation;

  const _AnalysisRequest({required this.trackId, required this.generation});
}

class _EnrichedTrackCacheEntry {
  final QueueTrack source;
  final TrackAnalysis analysis;
  final QueueTrack result;

  const _EnrichedTrackCacheEntry({
    required this.source,
    required this.analysis,
    required this.result,
  });
}

/// The numeric backend analysis id a track resolves to, if any.
int? _analysisTrackId(QueueTrack track) =>
    TrackAnalysisStore.analysisTrackIdFor(track);
