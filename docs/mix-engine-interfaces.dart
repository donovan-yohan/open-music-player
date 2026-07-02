
```dart
// ===== client/lib/core/engine/gain_envelope.dart =====

/// Shape of a per-clip fade ramp. [equalPower] (constant-power / cosine) is
/// the MVP DEFAULT — a plain [linear] amplitude crossfade between two
/// independent, unrelated tracks produces an audible perceived-loudness dip
/// at the transition midpoint, and equal-power costs nothing architecturally
/// (pure gainAt() math, no new persisted field: curve is a client-rendering
/// convention layered on the existing gainDb/fadeInMs/fadeOutMs schema).
enum FadeCurve { linear, equalPower }

/// Trapezoid gain envelope for one clip: silence -> [baseGainDb] over
/// [fadeInMs], flat, then [baseGainDb] -> silence over the trailing
/// [fadeOutMs]. Maps 1:1 onto the persisted mix_plan clip fields
/// (gainDb/fadeInMs/fadeOutMs, backend/internal/api/mix_plan_handlers.go).
/// Pure value type; no IO.
class GainEnvelope {
  final double baseGainDb;
  final int fadeInMs;
  final int fadeOutMs;
  final FadeCurve curve;

  const GainEnvelope({
    this.baseGainDb = 0,
    this.fadeInMs = 0,
    this.fadeOutMs = 0,
    this.curve = FadeCurve.equalPower,
  });

  const GainEnvelope.flat() : this();

  /// Amplitude multiplier at [localOffsetMs] within a clip of
  /// [clipDurationMs]. ALWAYS returns a value hard-clamped to [0.0, 1.0]
  /// regardless of [baseGainDb]'s sign/magnitude -- this is a safety net so
  /// every Voice.setVolume call is guaranteed platform-valid even if an
  /// upstream mix_plan authored an out-of-range gainDb (see
  /// TimelineModel.fromMixPlan's additional load-time clamp, which is the
  /// primary defense; this is defense-in-depth).
  /// Proportionally shrinks fadeIn/fadeOut when their sum exceeds
  /// clipDurationMs (mirrors TrimRange/TimelineClip's clamped-ctor idiom).
  double gainAt(int localOffsetMs, int clipDurationMs);

  GainEnvelope withBaseGainDb(double db);
  GainEnvelope withFadeInMs(int ms);
  GainEnvelope withFadeOutMs(int ms);
  GainEnvelope withCurve(FadeCurve curve);

  @override
  bool operator ==(Object other);
  @override
  int get hashCode;
}


// ===== client/lib/core/engine/timeline_model.dart =====

import '../../models/timeline_clip.dart';
import '../../models/mix_plan.dart';
import 'gain_envelope.dart';

/// One playable layer on the global mix timeline. Wraps the existing pure
/// [TimelineClip] (timing/overlap math, already half-open [start, end) --
/// reused verbatim, not re-decided here) rather than reimplementing it.
class MixClip {
  final TimelineClip placement;
  final GainEnvelope envelope;

  /// Opaque source identity a Voice resolves via EngineAudioSourceResolver.
  /// Defaults to placement.trackId (FIXED from an earlier draft that
  /// defaulted to '' -- covered by a dedicated regression test); this layer
  /// never sees a URL.
  final String audioSourceRef;

  /// Persistence-only passthrough for the backend's queueItemId; unused by
  /// playback math. Falls back to placement.id when absent.
  final String? queueItemId;

  MixClip({
    required this.placement,
    this.envelope = const GainEnvelope.flat(),
    String? audioSourceRef,
    this.queueItemId,
  }) : audioSourceRef = audioSourceRef ?? placement.trackId;

  int get timelineStartMs => placement.timelineStartMs;
  int get timelineEndMs => placement.timelineEndMs;
  int get durationMs => placement.selectedDurationMs;

  /// Amplitude gain at global position [globalMs] (already [0,1]-clamped by
  /// GainEnvelope.gainAt), 0 outside the clip's half-open active window.
  double gainAt(int globalMs);

  MixClip withPlacement(TimelineClip next);
  MixClip withEnvelope(GainEnvelope next);

  @override
  bool operator ==(Object other);
  @override
  int get hashCode;
}

/// Result of a TimelineModel.canPlace check.
class PlacementCheck {
  final bool allowed;
  final int wouldPeakDepth;

  const PlacementCheck({required this.allowed, required this.wouldPeakDepth});
}

/// Client-side draft of the backend save payload (models/mix_plan.dart is
/// the wire model); kept separate so this layer stays IO-free.
class MixPlanPayloadDraft {
  final String name;
  final List<MixPlanClip> clips;

  const MixPlanPayloadDraft({required this.name, required this.clips});
}

/// Immutable, pure (no IO) model of a mix's clip arrangement. Hard-caps
/// concurrent overlap at [maxConcurrentVoices]. Single playback and the
/// gapless queue are both just instances of this model (1-clip / sequential).
class TimelineModel {
  static const int maxConcurrentVoices = 4;

  final List<MixClip> clips;

  const TimelineModel({this.clips = const []});

  factory TimelineModel.empty();

  /// Zero-overlap, flat-gain arrangement from an ordered track list -- the
  /// gapless-queue case. Single playback is the 1-element case.
  factory TimelineModel.sequential({
    required List<String> trackIds,
    required int Function(String trackId) sourceDurationMsFor,
    TimelineClip Function(String trackId, TimelineClip defaultPlacement)?
        placementFor,
  });

  /// Defensive reconstruction from a persisted/shared MixPlan (the C17
  /// "save playlist as mix" product surface): clips are applied in payload
  /// order; any clip that would push overlap depth past [maxConcurrentVoices]
  /// is dropped (backend does not yet enforce the cap -- Open Decision #2);
  /// gainDb is clamped to <= 0 (logged on clamp -- see GainEnvelope.gainAt's
  /// doc for why this is defense-in-depth, not the only guard).
  factory TimelineModel.fromMixPlan(
    MixPlan plan, {
    required int Function(String trackId) sourceDurationMsFor,
  });

  /// Reconstruction specifically for QueueProvider's "Queue timing" persisted
  /// plan class, which is NOT the same shape fromMixPlan assumes: today,
  /// every clip the user hasn't manually dragged is persisted with
  /// timelineStartMs=0 (see QueueProvider._queueTimingClips), so feeding an
  /// ordinary unedited 5+ track queue plan through fromMixPlan would collapse
  /// every clip to depth 5 at t=0 and silently drop a track past the cap.
  ///
  /// This constructor builds the TimelineModel.sequential(trackOrder,...)
  /// baseline FIRST, then treats a persisted clip's placement/source range as
  /// an explicit override only when it differs from the computed sequential
  /// baseline for that track (heuristic "was this actually edited" detection
  /// -- documented limitation, see design doc Open Decision #9 for the
  /// proper long-term fix of an explicit isTimelineStartExplicit flag).
  factory TimelineModel.fromQueuePlan(
    MixPlan plan, {
    required List<String> trackOrder,
    required int Function(String trackId) sourceDurationMsFor,
  });

  MixPlanPayloadDraft toMixPlanPayload({required String name});

  int get totalDurationMs;
  bool get isEmpty;
  bool get isSingleClip;

  /// Half-open per TimelineClip's own interval semantics: a clip is active
  /// on [timelineStartMs, timelineEndMs).
  List<MixClip> activeClipsAt(int globalMs);
  int overlapDepthAt(int globalMs);

  /// Highest-gain active clip at [globalMs]; drives the notification's
  /// dominant-voice title and MixAudioHandler.mixIdentity's continuity rule.
  MixClip? dominantClipAt(int globalMs);

  /// Checked only across [candidate]'s own active interval -- other clips'
  /// depth elsewhere on the timeline is unaffected.
  PlacementCheck canPlace(MixClip candidate, {String? replacingClipId});

  TimelineModel withClipAdded(MixClip clip);
  TimelineModel withClipUpdated(MixClip clip);
  TimelineModel withClipRemoved(String clipId);

  @override
  bool operator ==(Object other);
  @override
  int get hashCode;
}


// ===== client/lib/core/engine/timeline_clock.dart =====

/// Master transport: the single source of truth for the mix's playback
/// position. NEVER reads position back from a Voice; advances via a
/// monotonic wall-clock ticker while playing.
abstract class TimelineClock {
  Stream<int> get positionMsStream;
  int get positionMs;

  int get durationMs;
  set durationMs(int value);

  bool get isPlaying;
  Stream<bool> get isPlayingStream;

  /// Fixed at 1.0 for the MVP (Open Decision #7, resolved as: leave fixed,
  /// document as an intentional no-op). Present so a future speed/
  /// time-stretch control doesn't require a new seam.
  double get rate;

  bool get isScrubbing;

  /// True while VoicePool has determined zero currently-active voices are
  /// ready (including the ordinary 1-voice stall case) and has called
  /// holdForBuffering(). Distinct from a user pause() -- UI should render a
  /// buffering indicator, not a paused icon, while this is true.
  bool get isBufferingHeld;
  Stream<bool> get isBufferingHeldStream;

  /// Holds position advancement without changing isPlaying/user intent.
  /// Idempotent. VoicePool calls this when the active voice set has no ready
  /// voice, so the transport pauses through a stall instead of the clock
  /// free-running through silence and then skipping forward on recovery.
  void holdForBuffering();

  /// Releases a hold and resumes advancing from the held position. Idempotent
  /// (a no-op if not currently held).
  void releaseHold();

  /// Fires once when positionMs reaches durationMs while playing.
  Stream<void> get completedStream;

  /// Fires only on endScrub/seek -- the signal VoicePool uses to recompute
  /// the active-clip set (regular playback re-diffs on every tick instead).
  Stream<int> get scrubCommittedStream;

  Future<void> play();
  Future<void> pause();

  void beginScrub();

  /// Cheap: repositions positionMs immediately for instant playhead
  /// feedback; triggers no voice reassignment.
  void updateScrub(int globalMs);

  /// Commits a scrub: final position + scrubCommittedStream event.
  Future<void> endScrub(int globalMs);

  /// One-shot seek (tap-to-seek, skip buttons, notification seekbar) =
  /// beginScrub + updateScrub + endScrub in one call.
  Future<void> seek(int globalMs);

  Future<void> dispose();
}

/// Default implementation. [now] is an injectable time source (defaults to
/// DateTime.now) so unit tests can deterministically fast-forward virtual
/// time instead of relying on real Future.delayed -- required for the
/// drift-check-cadence and hold-timeout tests promised in Phase 0/2.
class DefaultTimelineClock implements TimelineClock {
  DefaultTimelineClock({
    DateTime Function() now = DateTime.now,
    Duration uiTickInterval = const Duration(milliseconds: 150),
    Duration bufferingHoldTimeout = const Duration(seconds: 15),
  });

  @override
  Stream<int> get positionMsStream;
  @override
  int get positionMs;
  @override
  int get durationMs;
  @override
  set durationMs(int value);
  @override
  bool get isPlaying;
  @override
  Stream<bool> get isPlayingStream;
  @override
  double get rate;
  @override
  bool get isScrubbing;
  @override
  bool get isBufferingHeld;
  @override
  Stream<bool> get isBufferingHeldStream;
  @override
  void holdForBuffering();
  @override
  void releaseHold();
  @override
  Stream<void> get completedStream;
  @override
  Stream<int> get scrubCommittedStream;
  @override
  Future<void> play();
  @override
  Future<void> pause();
  @override
  void beginScrub();
  @override
  void updateScrub(int globalMs);
  @override
  Future<void> endScrub(int globalMs);
  @override
  Future<void> seek(int globalMs);
  @override
  Future<void> dispose();
}


// ===== client/lib/core/engine/voice.dart =====

enum VoiceEventKind { ready, buffering, stalled, completed, error }

class VoiceEvent {
  final VoiceEventKind kind;
  final Object? error;

  const VoiceEvent(this.kind, {this.error});
}

/// Injection seam so VoicePool never directly constructs a real
/// just_audio-backed Voice in tests.
typedef VoiceFactory = Voice Function();

/// Wraps exactly one just_audio AudioPlayer instance ("one CDJ deck"). Never
/// touches the master clock or other voices; only VoicePool/Mixer calls it.
///
/// Concrete implementations MUST configure a short buffer window (~10-15s
/// min / ~20-30s max target on the platform LoadControl/
/// AudioLoadConfiguration) rather than accepting ExoPlayer's single-deck-
/// tuned defaults, to bound per-instance memory across 4-5 concurrent decks.
abstract class Voice {
  String get debugId;

  bool get isLoaded;
  bool get isReady;
  bool get isPlaying;

  Stream<VoiceEvent> get events;

  Future<void> load(Uri source, {int initialLocalPositionMs = 0});
  Future<void> seekLocal(int localPositionMs);

  /// Caller (GainEnvelope.gainAt) guarantees [linearGain] is already clamped
  /// to [0,1]; implementations should still clamp defensively at the
  /// platform-channel boundary.
  Future<void> setVolume(double linearGain);

  /// Small pitch-adjacent speed nudges (Mixer uses ~+/-2%, applied for well
  /// under a second) to absorb sub-threshold drift without the audible
  /// micro-mute a hard seek causes. NOT used for user-facing time-stretch
  /// (rate stays advertised as 1.0 on TimelineClock -- see Open Decision #7).
  Future<void> setSpeed(double rate);

  Future<void> play();
  Future<void> pause();

  /// Stops and clears the loaded source but KEEPS the native player instance
  /// warm for fast pool reuse. This is the steady-state pool-return path.
  Future<void> release();

  /// Full teardown of the native player. Called only when the pool itself
  /// shrinks or on app-level disposal -- never on the steady-state
  /// activate/deactivate path (that's release()).
  Future<void> dispose();

  /// The wrapped player's own reported position -- used ONLY for
  /// drift-checking, never as a source of truth for the mix position.
  int? get currentLocalPositionMs;

  int? driftMs(int expectedLocalPositionMs);
  Future<void> resync(int expectedLocalPositionMs);
}


// ===== client/lib/core/engine/engine_audio_source_resolver.dart =====

import '../audio/local_audio_artifact_resolver.dart';
import '../audio/signed_audio_url_service.dart';
import '../cache/playback_cache_manager.dart';

class ResolvedAudioSource {
  final Uri uri;
  final bool isLocal;

  const ResolvedAudioSource({required this.uri, required this.isLocal});
}

/// Supplies the track-metadata map (title/artist/album/duration/artwork_url)
/// SignedAudioUrlService needs per track -- mirrors what PlaybackSourceResolver
/// already receives as its `List<Map<String,dynamic>>` batch input, but keyed
/// per-id so the engine's single-clip resolve calls fit naturally.
abstract class TrackAudioDescriptorProvider {
  Future<Map<String, dynamic>> trackJsonFor(String trackId);
}

/// Caps total concurrent network fetches shared across streaming
/// Voice.load() calls and speculative EngineAudioSourceResolver.warm() calls,
/// and de-prioritizes speculative warms while several voices are actively
/// streaming -- prevents ~8 simultaneous connections at the densest overlap
/// window, exactly when bandwidth matters most for gapless activation.
abstract class SharedFetchGate {
  /// Runs [fetch] once a fetch slot is available. [priority] high = an
  /// imminent look-ahead/activation fetch; low = a speculative cache warm.
  Future<T> schedule<T>(
    Future<T> Function() fetch, {
    required bool highPriority,
  });

  int get activeStreamingVoiceCount;
  set activeStreamingVoiceCount(int value);
}

/// Resolves a MixClip.audioSourceRef (a track id) to a playable Uri, reusing
/// the SAME per-track internals PlaybackSourceResolver already uses
/// (local-artifact -> playback-cache -> signed-URL), rather than wrapping
/// PlaybackSourceResolver's batch/Map API, which does not fit a single-id
/// engine call.
abstract class EngineAudioSourceResolver {
  Future<ResolvedAudioSource> resolve(String trackId);

  /// Best-effort background cache warm ahead of activation. Never throws.
  /// [protect] is REQUIRED: VoicePool always passes its current active-clip
  /// track ids, matching PlaybackSourceResolver._scheduleWarm's existing
  /// eviction-safety pattern -- a speculative warm must never evict a
  /// currently-playing clip's cached artifact.
  Future<void> warm(String trackId, {required Set<String> protect});
}

/// Default adapter mirroring PlaybackSourceResolver's own internals
/// per-track, rather than delegating to its batch resolveQueue/resolveTrack
/// methods (which would re-trigger that method's own internal cache-prefetch
/// scheduling redundantly with the Mixer's look-ahead logic).
class DefaultEngineAudioSourceResolver implements EngineAudioSourceResolver {
  DefaultEngineAudioSourceResolver({
    required SignedAudioUrlService signedAudioUrlService,
    required TrackAudioDescriptorProvider descriptorProvider,
    LocalAudioArtifactResolver? localResolver,
    PlaybackCacheManager? cacheManager,
    SharedFetchGate? fetchGate,
  });

  @override
  Future<ResolvedAudioSource> resolve(String trackId);

  @override
  Future<void> warm(String trackId, {required Set<String> protect});
}


// ===== client/lib/core/engine/voice_pool.dart =====

import 'engine_audio_source_resolver.dart';
import 'timeline_clock.dart';
import 'timeline_model.dart';
import 'voice.dart';

/// Owns a bounded pool of Voices (maxConcurrentVoices active + warmSpareVoices
/// extra for look-ahead preload) and keeps a STABLE clip-id -> voice mapping
/// so an already-playing overlapping clip is never reloaded because the
/// active set changed elsewhere. The only layer that mutates real audio
/// state in response to the clock; never advances position itself.
///
/// Sizing note: steady-state pool sizing (4 + warmSpareVoices) is sufficient
/// even for scrub-commit because reassignment is explicitly
/// release-before-acquire (leaving clips, already silent from their own
/// fade-out tail, are released back to the pool BEFORE newly-active clips
/// acquire voices) -- documented as a load-bearing ordering, not an
/// implementation detail.
class VoicePool {
  VoicePool({
    required TimelineClock clock,
    required EngineAudioSourceResolver sourceResolver,
    required VoiceFactory voiceFactory,
    int warmSpareVoices = 1,
    int lookAheadMs = 5000,
    int voiceAttackLeadMs = 120,
    int gainUpdateIntervalMs = 50,
    int speedNudgeThresholdMs = 150,
    int hardSeekDriftThresholdMs = 400,
    Duration driftCheckInterval = const Duration(milliseconds: 750),
    Duration prepareTimeout = const Duration(milliseconds: 1500),
  });

  TimelineModel get timelineModel;
  set timelineModel(TimelineModel value);

  Map<String, Voice> get activeVoices;

  /// Monotonically increasing per reassignment pass (tick-diff or
  /// scrub-commit). Every async load/seekLocal callback captures the
  /// generation it was issued under and drops its result if the pool's
  /// current generation has since moved on -- prevents a stale scrub's
  /// callback from stomping a voice already reassigned by a newer scrub.
  int get generation;

  /// Per-clip readiness, for a lane-local "buffering" chip without stalling
  /// the master clock.
  Stream<Map<String, VoiceEventKind>> get voiceStatusStream;

  /// Starts the pool: begins reacting to clock ticks, scrubCommittedStream,
  /// and clock.isPlayingStream (pausing/resuming all active voices in
  /// lockstep with play()/pause() -- including audio-focus-driven pauses
  /// from AudioFocusCoordinator -- with no corrective seek on resume, since
  /// the clock itself was held while paused).
  Future<void> start();
  Future<void> stop();
  Future<void> dispose();
}


// ===== client/lib/core/engine/playback_engine.dart =====

import 'timeline_model.dart';

/// Aggregate "now playing" snapshot for a mix at the current position -- the
/// single source both PlaybackState and MixAudioHandler read from.
class MixNowPlayingInfo {
  final String? dominantTrackId;
  final int activeVoiceCount;
  final int positionMs;
  final int durationMs;
  final bool isPlaying;
  final bool isBufferingHeld;

  const MixNowPlayingInfo({
    this.dominantTrackId,
    required this.activeVoiceCount,
    required this.positionMs,
    required this.durationMs,
    required this.isPlaying,
    this.isBufferingHeld = false,
  });
}

/// Fires when a clip's own active window ends. [wasSkipped] is false when the
/// clock crossed the clip's timelineEndMs during ordinary forward playback
/// (this is the signal PlaybackState's translation layer uses to synthesize
/// the legacy ProcessingState.completed event for PlayRecorderService); true
/// when the clip instead left the active set because a seek/scrub jumped
/// past it.
class ClipCompletionEvent {
  final String trackId;
  final String clipId;
  final bool wasSkipped;

  const ClipCompletionEvent({
    required this.trackId,
    required this.clipId,
    required this.wasSkipped,
  });
}

class TrackDisplayMetadata {
  final String title;
  final String artist;
  final String? album;
  final Uri? artUri;
  final int durationMs;

  const TrackDisplayMetadata({
    required this.title,
    required this.artist,
    this.album,
    this.artUri,
    required this.durationMs,
  });
}

/// Resolves a track id to display metadata. Kept outside TimelineModel/MixClip
/// so the pure engine layers never depend on models/track.dart or MediaItem.
abstract class TrackMetadataProvider {
  TrackDisplayMetadata? metadataFor(String trackId);
}

/// Facade owning TimelineClock + VoicePool + the current TimelineModel. The
/// ONE playback path: single song = 1-clip model, gapless queue = sequential
/// model, hand-authored mix = dense model.
///
/// Deliberately exposes NO just_audio/audio_service types -- only plain Dart
/// value types (MixNowPlayingInfo, ClipCompletionEvent). PlaybackState (not
/// this class) is responsible for translating these into the just_audio/
/// audio_service-shaped streams legacy consumers (PlayRecorderService) still
/// depend on -- see design doc §1.9.
abstract class PlaybackEngine {
  Stream<int> get positionMsStream;
  int get positionMs;
  int get durationMs;

  bool get isPlaying;
  Stream<bool> get isPlayingStream;

  TimelineModel get timelineModel;
  Stream<TimelineModel> get timelineModelStream;

  Stream<MixNowPlayingInfo> get nowPlayingStream;
  MixNowPlayingInfo get nowPlaying;

  /// Fires when dominantClipAt's track identity changes -- drives
  /// MixAudioHandler.mixIdentity's single-voice continuity rule and
  /// PlaybackState's currentMediaItemStream.
  Stream<String?> get dominantTrackIdChangedStream;

  /// See ClipCompletionEvent doc. Strict improvement over the old
  /// just_audio-ProcessingState.completed-only signal, which only reliably
  /// fired at the very end of the whole ConcatenatingAudioSource sequence.
  Stream<ClipCompletionEvent> get clipCompletedStream;

  Future<void> loadMix(TimelineModel mix, {bool autoplay = false});

  /// Convenience for the unified single-track/queue case: wraps
  /// TimelineModel.sequential + loadMix.
  Future<void> loadSequentialQueue(
    List<String> trackIds, {
    required int Function(String trackId) sourceDurationMsFor,
    int startIndex = 0,
    bool autoplay = false,
  });

  Future<void> play();
  Future<void> pause();

  /// One-shot seek (tap-to-seek, skip buttons, notification seekbar).
  Future<void> seek(int globalMs);

  void beginScrub();
  void updateScrub(int globalMs);
  Future<void> endScrub(int globalMs);

  /// Sequential-case semantics are fully specified: skipToPreviousClip() at
  /// the first clip restarts it from zero (matches today's
  /// AudioPlayerService), not a no-op. The overlapping-mix case ("next/
  /// previous distinct timelineStartMs") remains a product call -- Open
  /// Decision #6.
  Future<void> skipToNextClip();
  Future<void> skipToPreviousClip();
  Future<void> skipToClipIndex(int index);

  Future<void> dispose();
}


// ===== client/lib/core/audio/audio_focus_coordinator.dart =====

import 'package:audio_session/audio_session.dart';
import '../engine/playback_engine.dart';

/// Owns exactly one responsibility: on Android audio-focus loss (call,
/// notification sound, another app's playback) or a "becoming noisy"
/// (headphones unplugged) event, call PlaybackEngine.pause(); on focus
/// regain, call PlaybackEngine.play(). Deliberately NOT aware of individual
/// voices -- multi-voice coordination (pausing all active voices in lockstep,
/// resuming with no corrective seek) already lives in VoicePool's own
/// clock.isPlayingStream subscription, so this class only needs to drive the
/// existing play()/pause() entry points.
abstract class AudioFocusCoordinator {
  Future<void> start();
  Future<void> dispose();
}

class DefaultAudioFocusCoordinator implements AudioFocusCoordinator {
  DefaultAudioFocusCoordinator({
    required PlaybackEngine engine,
    required AudioSession session,
  });

  @override
  Future<void> start();
  @override
  Future<void> dispose();
}


// ===== client/lib/core/audio/mix_audio_handler.dart =====

import 'package:audio_service/audio_service.dart';
import '../engine/playback_engine.dart';

/// Replaces just_audio_background's single-track model. Reports the whole
/// mix as ONE MediaItem: global position/duration from PlaybackEngine,
/// title/art from the dominant voice, "· N layered" appended when more than
/// one voice is active. Every transport control (incl. the notification
/// seekbar) calls back into the SAME PlaybackEngine.
///
/// A minimal version (play/pause/seek passthrough, coarse metadata) ships in
/// Phase 2 alongside AudioFocusCoordinator, specifically so 4-voice overlap
/// and screen-off/backgrounding are validated together rather than deferred
/// to Phase 5.
class MixAudioHandler extends BaseAudioHandler with SeekHandler {
  MixAudioHandler({
    required PlaybackEngine engine,
    required TrackMetadataProvider metadata,
  });

  /// Returns the dominant track's own id whenever nowPlaying.activeVoiceCount
  /// == 1 (re-derived on every dominantTrackIdChangedStream event), so plain
  /// single-track playback and gapless queue advance present to the OS
  /// exactly like today's per-track MediaItem continuity. Only switches to a
  /// distinct "layered mix" identity when activeVoiceCount > 1.
  String mixIdentity();

  @override
  Future<void> play();
  @override
  Future<void> pause();
  @override
  Future<void> seek(Duration position);
  @override
  Future<void> skipToNext();
  @override
  Future<void> skipToPrevious();
  @override
  Future<void> stop();
}


// ===== client/lib/core/audio/queue_timeline_controller.dart =====

import 'package:audio_service/audio_service.dart';
import '../engine/playback_engine.dart';

/// Rebuilds the sequential (non-overlapping) TimelineModel used by
/// PlaybackState's queue-style playback (playQueue/enqueue/playNext/shuffle/
/// loop) on top of PlaybackEngine, replacing AudioPlayerService's
/// ConcatenatingAudioSource. QueueProvider's existing "Queue timing" mix-plan
/// auto-save is rebased onto TimelineModel.fromQueuePlan specifically (NOT
/// fromMixPlan -- see design doc §3/§6 for why the persisted plan's
/// default-zero timelineStartMs makes that distinction load-bearing).
abstract class QueueTimelineController {
  List<MediaItem> get queue;
  int? get currentIndex;
  bool get shuffleEnabled;
  LoopMode get loopMode;

  Future<void> setQueue(List<MediaItem> items, {int initialIndex = 0});
  Future<void> addToQueue(MediaItem item);
  Future<void> insertIntoQueue(int index, MediaItem item);
  Future<void> removeFromQueue(int index);

  Future<void> skipToNext();

  /// At the first item, restarts it from zero rather than no-op -- matches
  /// today's AudioPlayerService boundary behavior exactly (resolves the
  /// previously-unspecified boundary case).
  Future<void> skipToPrevious();
  Future<void> skipToIndex(int index);

  /// Contract: keeps the current item in place (matches just_audio's own
  /// shuffle() semantics that AudioPlayerService relies on today) rather than
  /// an unspecified reordering.
  Future<void> setShuffleMode(bool enabled);
  Future<void> setLoopMode(LoopMode mode);
}
```
