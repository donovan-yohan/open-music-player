import 'dart:async';


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/audio/playback_state.dart';
import '../../core/audio/signed_audio_url_service.dart';
import '../../core/api/api_client.dart';
import '../../core/cache/playback_cache_manager.dart';
import '../../core/download/download_service.dart';
import '../../core/engine/engine_audio_source_resolver.dart';
import '../../core/services/stems_service.dart';
import '../../providers/queue_provider.dart';
import '../stems/track_stem_channel_source.dart';
import 'dj_layout.dart';
import 'dj_system_overlay_style.dart';
import 'engine/deck_controller.dart';
import 'providers/dj_session_provider.dart';
import '../../app/theme.dart';
import '../../core/download/download_state.dart';
import '../../models/track.dart';
import 'dj_deck_actions.dart';
import 'models/dj_deck_state.dart';

/// Direct-Voice performance view.
///
/// This screen owns two `Voice`s outside `QueueTimelineController`. That is a
/// sanctioned but scoped exception to ADR 0001 — see the
/// "DJ deck's direct-voice exception" addendum in
/// `docs/adr/0001-playback-timeline-source-of-truth.md` for what the exception
/// covers and what ends it. It is reachable only while
/// `SettingsModel.djModeEnabled` is on.
///
/// TODO(dj-production): replace [DjSessionProvider] direct voices with the
/// QueueTimelineController deck projection (step 1 of the addendum's
/// integration path).
class DjScreen extends StatefulWidget {
  const DjScreen({
    super.key,
    this.session,
    this.filePicker,
    this.sessionFactory,
  });
  final DjSessionProvider? session;
  final DjFilePicker? filePicker;

  /// Test seam for the owned-session path.
  ///
  /// Production passes neither [session] nor this, so the screen builds — and
  /// therefore owns — its own prototype session. A test cannot reach that
  /// branch otherwise, because the real session builds `JustAudioVoice`s from
  /// the app's provider tree. A screen that builds its own session owns it,
  /// however it was built.
  @visibleForTesting
  final DjSessionProvider Function()? sessionFactory;

  @override
  State<DjScreen> createState() => _DjScreenState();
}

class _DjScreenState extends State<DjScreen> {
  DjSessionProvider? _session;
  TrackStemChannelSource? _stems;
  bool _ownsSession = false;
  bool _seeded = false;

  /// The QueueProvider the seed actually read, pinned so dispose removes the
  /// listener from the same object addListener was called on (#410).
  ///
  /// Its remaining job is analysis hydration: waveform peak arrays live on the
  /// per-track analysis endpoint, and QueueProvider is the client's cache of
  /// them. It is *not* the deck's source of "what is playing" any more — that
  /// is the playback queue (ADR 0012).
  QueueProvider? _queue;

  /// The canonical playback session, or null in a narrow harness that mounts
  /// the deck without app playback. Never watched directly: its snapshot loop
  /// publishes continuously while audio plays, so the deck subscribes to
  /// [PlaybackState.snapshotStream] and gates on the distilled
  /// [DjPlaybackSignal] instead.
  PlaybackState? _playback;
  StreamSubscription<DjPlaybackSignal>? _playbackSubscription;

  /// Serializes deck seeds so two voices never load concurrently.
  Future<void> _seedChain = Future<void>.value();

  /// Last analysis revision already pushed onto the decks. QueueProvider also
  /// notifies for queue/position changes, which must not re-seed anything.
  int _lastAnalysisRevision = -1;

  /// Track ids whose deck download ended badly. `DownloadState` removes a
  /// failed transfer from its active-progress map, so it cannot answer this.
  final Set<int> _downloadFailures = <int>{};

  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // _session is pinned on first resolution, so ownership must be pinned with
    // it. Recomputing ownership against a later widget.session would make the
    // screen release voices it created without ever disposing them.
    if (_session == null) {
      _session =
          widget.session ?? (widget.sessionFactory ?? _newPrototypeSession)();
      _ownsSession = widget.session == null;
    }
    if (_seeded) return;
    _seeded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Direct prototype voices share the app audio session; park its canonical
      // session before they are loaded.
      try {
        await context.read<PlaybackState>().pause();
      } on ProviderNotFoundException {
        // Focused widget tests may intentionally mount the view without app
        // playback. Production always supplies PlaybackState.
      }
      if (!mounted) return;
      final queue = context.read<QueueProvider?>();
      final playback = context.read<PlaybackState?>();
      _queue = queue;
      _playback = playback;
      // The deck reads the *playback* queue, not the import queue whose
      // `currentPosition` never advances (#453). It is subscribed rather than
      // read once: `main.dart` restores the saved queue with
      // `unawaited(restore())`, so at first frame the playback queue can still
      // be empty and a one-shot read would reopen #409.
      //
      // Distinct on the distilled signal, so the 33 Hz position loop cannot
      // drive re-seeds or widget work: only a real change of playing/next cue
      // or queue length gets through.
      _playbackSubscription = playback?.snapshotStream
          .map(playback.djPlaybackSignalFor)
          .distinct()
          .listen(_onPlaybackSignal);
      // A queue that already hydrated still seeds immediately, so the deck is
      // not left waiting for the next cue change.
      await _seedDecksFromPlayback();
      if (!mounted) return;
      // Attached only after the seed: a listener that fired mid-seed would race
      // DeckController.load. Waveform peak arrays are never in the queue
      // collection payload (queue_provider.dart:197-199), so the deck's first
      // read is always a cold cache and this subscription is the only thing
      // that lets the hydrated arrays reach the lane (#410).
      queue?.addListener(_onQueueAnalysisChanged);
      // A hydration that completed while the seed above was awaiting fired
      // before this listener existed, and recording the current revision as
      // already-seen would strand the deck on the unhydrated snapshot forever.
      // Reconcile once, from a deliberately impossible revision.
      _lastAnalysisRevision = -1;
      _onQueueAnalysisChanged();
    });
  }

  /// Seeds whichever deck is still empty from the playing track and its
  /// play-order successor.
  ///
  /// Only empty decks are filled. A deck already holding audio is never
  /// replaced: this is a performance surface, and a track change under a loaded
  /// lane must not silence it (a picked local file, a downloaded track, or the
  /// previous track still under the fader).
  ///
  /// Calls are serialized through [_seedChain]. Seed loads are awaited per deck
  /// and the snapshot stream can emit while one is still in flight, so without
  /// this a second pass would see deck B still empty and load it concurrently —
  /// two voices' loads overlapping on the one shared audio session, which the
  /// prototype's voices cannot do.
  Future<void> _seedDecksFromPlayback() {
    final next = _seedChain.then((_) => _seedEmptyDecks());
    _seedChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _seedEmptyDecks() async {
    final playback = _playback;
    final session = _session;
    if (!mounted || playback == null || session == null) return;
    final current = _hydrated(playback.currentPlaybackTrack());
    final next = _hydrated(playback.nextPlaybackTrack());
    // Deck A is awaited before deck B: the prototype's two voices share one
    // audio session, so their loads must not overlap.
    if (current != null && !session.deckA.isLoaded) {
      final seeds = DjSessionProvider.queueSeeds(current, null);
      if (seeds.isNotEmpty) await session.load(DjDeckId.a, seeds.first);
      // Resolve stem availability for whatever actually landed on deck A. A
      // local-file fallback load has no library track id, so the panel says so
      // rather than offering a separation that cannot be queued.
      await _stems?.bindTrack(_libraryTrackId(session.deckA.trackRef));
      if (!mounted) return;
    }
    if (next != null && !session.deckB.isLoaded) {
      final seeds = DjSessionProvider.queueSeeds(next, null);
      if (seeds.isNotEmpty) await session.load(DjDeckId.b, seeds.first);
    }
  }

  /// [track] with whatever hydrated analysis the client already holds, and with
  /// hydration interest re-armed so the deck's peaks arrive (#410).
  QueueTrack? _hydrated(QueueTrack? track) {
    if (track == null) return null;
    return _queue?.trackWithAnalysis(track) ?? track;
  }

  void _onPlaybackSignal(DjPlaybackSignal signal) {
    if (!mounted) return;
    unawaited(_seedDecksFromPlayback());
  }

  /// Re-seeds both decks from queue analysis when hydrated analysis lands.
  void _onQueueAnalysisChanged() {
    final queue = _queue;
    final session = _session;
    if (!mounted || queue == null || session == null) return;
    final revision = queue.analysisRevision;
    // Position/queue-only notifications leave the revision alone.
    if (revision == _lastAnalysisRevision) return;
    _lastAnalysisRevision = revision;
    final playback = _playback;
    if (playback == null) return;
    final current = playback.currentPlaybackTrack();
    final next = playback.nextPlaybackTrack();
    // trackWithAnalysis re-arms hydration interest (queue_provider.dart:215-218),
    // so a deck whose analysis was purged by another screen's
    // setAnalysisHydrationInterest re-requests it instead of staying blank.
    session.applyAnalysisUpdate([
      for (final track in [current, next])
        if (track != null) queue.trackWithAnalysis(track),
    ]);
  }

  /// Deck refs are `playbackTrackId ?? queueItemId` for library tracks and
  /// `local:<path>` for the picker fallback; only the former can be separated.
  static int? _libraryTrackId(String? trackRef) {
    if (trackRef == null) return null;
    final parsed = int.tryParse(trackRef.trim());
    return parsed != null && parsed > 0 ? parsed : null;
  }

  DjSessionProvider _newPrototypeSession() {
    _stems = TrackStemChannelSource(
        service: StemsService(context.read<ApiClient>()));
    return DjSessionProvider.prototype(
      resolver: DefaultEngineAudioSourceResolver(
        signedAudioUrlService: SignedAudioUrlService(context.read<ApiClient>()),
        localResolver: context.read<DownloadService>(),
        cacheManager: context.read<PlaybackCacheManager?>(),
      ),
      stems: _stems,
    );
  }

  /// Dependency-free local source fallback for an empty queue. A user supplies
  /// an absolute device path; DeckController accepts only the resulting file:
  /// URI and refuses remote schemes.
  ///
  /// The controller is owned by [_DjLocalFilePrompt], whose `State.dispose`
  /// runs when the route actually unmounts. Disposing it here, the frame
  /// `showDialog`'s future resolved, tore down a `TextEditingController` while
  /// the dialog's `TextField` was still mounted for its exit transition;
  /// `EditableText.dispose` then removed a listener from a disposed notifier,
  /// threw mid-unmount and stranded an `InheritedElement`'s dependents
  /// (`_dependents.isEmpty` assertion, #414 residual 2).
  Future<DjDeckLoad?> _promptForLocalFile() async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => const _DjLocalFilePrompt(),
    );
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final slash = trimmed.lastIndexOf('/');
    return DjDeckLoad(
      trackRef: 'local:$trimmed',
      title: slash < 0 ? trimmed : trimmed.substring(slash + 1),
      localUri: Uri.file(trimmed),
    );
  }

  @override
  void dispose() {
    unawaited(_playbackSubscription?.cancel() ?? Future<void>.value());
    _queue?.removeListener(_onQueueAnalysisChanged);
    _stems?.dispose();
    if (_ownsSession) {
      // DeckController.dispose releases its Voice; do not overlap it with a
      // second release from stopAll.
      _session?.dispose();
    } else {
      // The injected session remains caller-owned, but an exited screen must
      // still park its prototype voices.
      unawaited(_session?.stopAll() ?? Future<void>.value());
    }
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    super.dispose();
  }

  /// The playback queue row still standing behind [deck], or null.
  ///
  /// A refused deck keeps its `queueItemId` (deck_controller.dart), so the
  /// candidate is accepted only when it still matches: a queue that moved out
  /// from under the deck yields null rather than downloading the wrong track.
  QueueTrack? _queueTrackFor(DjDeckId deck) {
    final playback = _playback;
    if (playback == null) return null;
    final candidate = deck == DjDeckId.a
        ? playback.currentPlaybackTrack()
        : playback.nextPlaybackTrack();
    if (candidate == null) return null;
    return candidate.queueItemId == _session!.stateFor(deck).queueItemId
        ? candidate
        : null;
  }

  int? _downloadTrackIdFor(DjDeckId deck) {
    final track = _queueTrackFor(deck);
    if (track == null) return null;
    final ref = DjSessionProvider.djDeckTrackRef(track);
    return ref == null ? null : int.tryParse(ref);
  }

  DjDeckDownload _downloadForDeck(DjDeckId deck, DownloadState? downloads) {
    if (downloads == null) return DjDeckDownload.unavailable;
    final id = _downloadTrackIdFor(deck);
    if (id == null) return DjDeckDownload.unavailable;
    final progress = downloads.getProgress(id);
    if (progress != null) return DjDeckDownload.running(progress.progress);
    return _downloadFailures.contains(id)
        ? DjDeckDownload.failed
        : DjDeckDownload.idle;
  }

  /// Sends the deck's refused track through the app's one download pipeline
  /// and, on success, re-seeds that single deck in place.
  ///
  /// The re-seed goes through `DjSessionProvider.queueSeeds` so this is not a
  /// second seed authority; the deck the user is looking at reloads without
  /// leaving `/dj`.
  Future<void> _downloadDeck(DjDeckId deck) async {
    final queueTrack = _queueTrackFor(deck);
    if (queueTrack == null) return;
    final track = djDownloadTrackFor(queueTrack);
    if (track == null) return;
    final downloads = context.read<DownloadState?>();
    if (downloads == null) return;
    if (_downloadFailures.remove(track.id) && mounted) setState(() {});
    try {
      await downloads.downloadTrack(track);
    } catch (_) {
      // DownloadState drops a failed transfer from its active progress map,
      // so the terminal state is recorded here or nowhere.
      if (mounted) setState(() => _downloadFailures.add(track.id));
      return;
    }
    if (!mounted) return;
    // Seeded through the same hydration path as the cold entry above, not from
    // the raw queue row: collection payloads never carry waveform arrays
    // (queue_provider.dart:197-199), so re-seeding from `queueTrack` loaded the
    // deck under a lane that said "Analyzing…" and had no peaks. It also
    // re-arms hydration interest, which a deck refused long enough for another
    // screen to evict its analysis needs (#410).
    final seedTrack = _queue?.trackWithAnalysis(queueTrack) ?? queueTrack;
    final seeds = DjSessionProvider.queueSeeds(seedTrack, null);
    if (seeds.isEmpty) return;
    await _session!.load(deck, seeds.first);
    if (!mounted) return;
    // A deck that still refuses after a completed transfer has no usable local
    // file; say so rather than leaving the same button offering the same thing.
    if (_session!.stateFor(deck).loadFailure != null) {
      setState(() => _downloadFailures.add(track.id));
    } else {
      setState(() {});
    }
  }

  /// Loads a picked local file onto [deck].
  ///
  /// The lane renders this affordance on whichever deck is empty, so the target
  /// has to come from the lane. Hardcoding deck A here made deck B's button
  /// replace deck A's live track and silence it (#414 review).
  Future<void> _pickLocalFile(DjDeckId deck) async {
    final picked = await (widget.filePicker ?? _promptForLocalFile)();
    if (picked != null && mounted) await _session!.load(deck, picked);
  }

  @override
  Widget build(BuildContext context) {
    // Watched, not read: the lane's download affordance has to follow the
    // transfer's progress and its completion without the user leaving /dj.
    final downloads = context.watch<DownloadState?>();
    return ChangeNotifierProvider<DjSessionProvider>.value(
      value: _session!,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: djSystemOverlayStyle(context),
        child: _PlaybackSignalBuilder(
          builder: (signal) => DjDeckActions(
            onPickLocalFile: _pickLocalFile,
            onDownload: downloads == null ? null : _downloadDeck,
            downloadFor: (deck) => _downloadForDeck(deck, downloads),
            // "Is anything queued" is a *playback* queue fact (#453), and it is
            // selected rather than watched: `Selector` rebuilds only when the
            // distilled signal changes, so the 33 Hz snapshot loop cannot
            // dirty this subtree.
            queueHasTracks: signal.hasQueue,
            child: const Scaffold(
              key: ValueKey('dj_screen'),
              body: DjLayout(),
            ),
          ),
        ),
      ),
    );
  }
}

/// Rebuilds its subtree only when the distilled [DjPlaybackSignal] changes.
///
/// The snapshot loop publishes continuously while audio plays; watching
/// [PlaybackState] here would rebuild the deck chrome ~33 times a second, which
/// `client/test/perf/` gates against. [Selector] compares the projected signal
/// and rebuilds when it differs, so a position tick costs nothing.
///
/// Null-tolerant: a narrow harness that mounts the deck without app playback
/// gets [DjPlaybackSignal.empty] rather than a `ProviderNotFoundException`,
/// which is a supported state for the deck's lane tests.
class _PlaybackSignalBuilder extends StatelessWidget {
  const _PlaybackSignalBuilder({required this.builder});

  final Widget Function(DjPlaybackSignal signal) builder;

  @override
  Widget build(BuildContext context) {
    if (context.read<PlaybackState?>() == null) {
      return builder(DjPlaybackSignal.empty);
    }
    return Selector<PlaybackState, DjPlaybackSignal>(
      selector: (_, playback) => playback.djPlaybackSignalFor(playback.snapshot),
      builder: (context, signal, _) => builder(signal),
    );
  }
}

/// The local-file prompt, owning its own [TextEditingController].
///
/// `scrollable` + a tightened inset keep it inside a landscape window with the
/// soft keyboard up, where it used to paint `BOTTOM OVERFLOWED BY 70 PIXELS`.
class _DjLocalFilePrompt extends StatefulWidget {
  const _DjLocalFilePrompt();

  @override
  State<_DjLocalFilePrompt> createState() => _DjLocalFilePromptState();
}

class _DjLocalFilePromptState extends State<_DjLocalFilePrompt> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        scrollable: true,
        insetPadding: const EdgeInsets.symmetric(
          horizontal: AppTheme.space6,
          vertical: AppTheme.space3,
        ),
        title: const Text('Load local audio file'),
        content: TextField(
          key: const ValueKey('dj_local_file_path'),
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '/storage/emulated/0/Music/track.mp3',
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('dj_local_file_cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('dj_local_file_load'),
            onPressed: () => Navigator.of(context).pop(_controller.text),
            child: const Text('Load'),
          ),
        ],
      );
}
