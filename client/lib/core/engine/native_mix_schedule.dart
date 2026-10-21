import 'dart:math' as math;

import 'native_mix_renderer.dart';
import 'timeline_model.dart';
import 'gain_envelope.dart';
import '../stems/prepared_stem_manifest.dart';
import '../../models/stem_edits.dart';

/// Explicit prepared-window origin, stable slot and nonzero playback-instance
/// identity supplied by the existing playback owner. Not a second controller.
class NativeMixClipInput {
  NativeMixClipInput({
    required this.pcm,
    required this.slot,
    required this.instanceId,
    required Iterable<NativeMixBus> buses,
    this.sourceOriginFrame = 0,
  }) : buses = List.unmodifiable(buses);
  final NativePreparedPcm pcm;
  final int slot;
  final int instanceId;
  final int sourceOriginFrame;
  final List<NativeMixBus> buses;
}

/// Explicit verified source identity plus bounded decoded residency supplied by
/// the preparation owner. This compiler neither verifies bytes nor invents IDs.
class NativeArrangementClipInput {
  NativeArrangementClipInput({
    required this.instanceId,
    required this.assetId,
    required this.sourceFrameCount,
    required this.sourceFileHash,
    required Iterable<NativeMixBus> buses,
    required Iterable<NativeArrangementWindow> windows,
    this.stemManifest,
    Iterable<String> busChannels = const [],
    this.stemOverrideMask = 0,
  })  : buses = List.unmodifiable(buses),
        windows = List.unmodifiable(windows),
        busChannels = List.unmodifiable(busChannels);
  final int instanceId, assetId, sourceFrameCount, stemOverrideMask;

  /// Caller-verified canonical original-file identity; never synthesized here.
  final String sourceFileHash;
  final PreparedStemManifest? stemManifest;
  final List<String> busChannels;
  final List<NativeMixBus> buses;
  final List<NativeArrangementWindow> windows;
}

/// Immutable transport projection: native output frames never rewind. The
/// existing controller supplies a NEW anchor after a logical pause/seek/resume
/// barrier, using its logical frame and the native completed-frame snapshot.
/// Neither this value nor the compiler starts, pauses or seeks any device.
class NativeMixClockAnchor {
  const NativeMixClockAnchor({this.nativeFrame = 0, this.timelineFrame = 0});
  final int nativeFrame;
  final int timelineFrame;

  int nativeFrameFor(int logicalFrame) {
    _frame(nativeFrame, 'nativeFrame');
    _frame(timelineFrame, 'timelineFrame');
    _frame(logicalFrame, 'logicalFrame');
    final delta = logicalFrame - timelineFrame;
    if (delta < -nativeFrame || delta > _maxFrame - nativeFrame) {
      throw ArgumentError('Clock mapping falls outside supported frame range');
    }
    return nativeFrame + delta;
  }

  int timelineFrameFor(int completedNativeFrame) {
    _frame(completedNativeFrame, 'completedNativeFrame');
    _frame(nativeFrame, 'nativeFrame');
    _frame(timelineFrame, 'timelineFrame');
    final delta = completedNativeFrame - nativeFrame;
    if (delta < -timelineFrame || delta > _maxFrame - timelineFrame) {
      throw ArgumentError('Clock mapping falls outside supported frame range');
    }
    return timelineFrame + delta;
  }
}

/// Pure projections onto the existing native engine. Full immutable arrangements
/// support authored curves; legacy bounded snapshots deliberately fail closed.
class NativeMixSchedule {
  /// Full rate-one authored arrangement. No transport/decoder state is owned.
  /// Validates all metadata before returning; the renderer validates ownership,
  /// density and native capacity atomically before accepting any revision.
  static NativeArrangementPlan compileArrangement({
    required TimelineModel timeline,
    required Map<String, NativeArrangementClipInput> inputs,
    required int sampleRate,
    required int revision,
    int? maxBlockFrames,
    NativeMixClockAnchor clock = const NativeMixClockAnchor(),
    double masterGain = 1,
  }) {
    if (sampleRate <= 0 ||
        sampleRate > 0xffffffff ||
        revision <= 0 ||
        revision > _maxFrame) {
      throw ArgumentError('Invalid rate/revision');
    }
    _frame(clock.nativeFrame, 'nativeFrame');
    _frame(clock.timelineFrame, 'timelineFrame');
    _gain(masterGain);
    if (maxBlockFrames != null &&
        (maxBlockFrames <= 0 || maxBlockFrames > 65536)) {
      throw ArgumentError('Invalid block bound');
    }
    if (timeline.clips.length > NativeArrangementPlan.maxClips) {
      throw ArgumentError('Clip limit exceeded');
    }
    final clips = <NativeArrangementClip>[];
    final windows = <NativeArrangementWindow>[];
    final ids = <int>{};
    final assets = <int, String>{};
    var totalEvents = 0;
    final eventFrames = <int>[];
    for (final clip in timeline.clips) {
      if (clip.playbackRate != 1 ||
          clip.rateAutomation.baseRate != 1 ||
          clip.rateAutomation.segments.isNotEmpty) {
        throw UnsupportedError('Native renderer supports constant rate 1 only');
      }
      final envelope = clip.envelope;
      if (!envelope.baseGainDb.isFinite ||
          envelope.baseGainDb > 0 ||
          envelope.fadeInMs < 0 ||
          envelope.fadeOutMs < 0) {
        throw UnsupportedError('Finite non-amplifying envelope required');
      }
      final input = inputs[clip.id];
      if (input == null) {
        throw StateError('Missing verified source for ${clip.id}');
      }
      if (input.instanceId <= 0 ||
          input.instanceId > _maxFrame ||
          !ids.add(input.instanceId) ||
          input.assetId <= 0 ||
          input.assetId > _maxFrame ||
          input.sourceFrameCount <= 0 ||
          input.sourceFrameCount > _maxFrame ||
          !RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(input.sourceFileHash) ||
          input.buses.isEmpty ||
          input.buses.length > 5 ||
          input.stemOverrideMask < 0 ||
          input.stemOverrideMask >= (1 << input.buses.length)) {
        throw ArgumentError('Invalid verified input ${clip.id}');
      }
      for (final bus in input.buses) {
        _gain(bus.gain);
        if (bus.rampFrames < 0 || bus.rampFrames > 0xffffffff) {
          throw ArgumentError('Invalid ramp');
        }
      }
      final manifest = input.stemManifest;
      if (manifest != null) {
        if (manifest.trackId.toString() != clip.trackId ||
            manifest.sourceFileHash != input.sourceFileHash ||
            manifest.sampleRateHz != sampleRate ||
            manifest.sampleFrames != input.sourceFrameCount ||
            manifest.channels.length != input.buses.length ||
            input.busChannels.length != manifest.channels.length ||
            !List.generate(manifest.channels.length,
                    (i) => manifest.channels[i] == input.busChannels[i])
                .every((v) => v)) {
          throw ArgumentError(
              'Verified manifest/channel identity mismatch ${clip.id}');
        }
      } else if (input.buses.length != 1 || input.busChannels.isNotEmpty) {
        throw ArgumentError('Multibus inputs require verified stem manifest');
      }
      final identity =
          '${input.sourceFileHash}/${input.sourceFrameCount}/${manifest?.identity ?? 'original'}/${input.busChannels.join(',')}';
      final previous = assets[input.assetId];
      if (previous != null && previous != identity) {
        throw ArgumentError('Asset ID aliases distinct sources');
      }
      assets[input.assetId] = identity;
      final events = <NativeStemGainEvent>[];
      final edits = clip.stemEdits;
      if (edits != null) {
        if (manifest == null ||
            edits.sourceFileHash != input.sourceFileHash ||
            edits.channelSet.id != manifest.channelSet ||
            edits.stemModelVersion != manifest.stemModelVersion ||
            !edits.hasCanonicalStemModelVersion ||
            edits.unknownKeys.isNotEmpty ||
            (edits.beatGridRef?.unknownKeys.isNotEmpty ?? false)) {
          throw UnsupportedError(
              'Saved stem semantics/identity not supported ${clip.id}');
        }
        if (edits.events.length > NativeArrangementPlan.maxEventsPerClip) {
          throw ArgumentError('Clip event limit');
        }
        totalEvents += edits.events.length;
        if (totalEvents > NativeArrangementPlan.maxEvents) {
          throw ArgumentError('Plan event limit');
        }
        for (final event in edits.events) {
          final bus = input.busChannels.indexOf(event.channel);
          final source = framesForMilliseconds(event.atMs, sampleRate);
          final ramp = framesForMilliseconds(event.rampMs, sampleRate);
          if (event.unknownKeys.isNotEmpty ||
              bus < 0 ||
              source >= input.sourceFrameCount ||
              event.rampMs < stemRampMinMs ||
              event.rampMs > stemRampMaxMs ||
              ramp <= 0 ||
              ramp > 0xffffffff) {
            throw UnsupportedError('Unsupported saved stem event');
          }
          _gain(event.gain);
          events.add(NativeStemGainEvent(
              sourceFrame: source,
              bus: bus,
              gain: event.gain,
              rampFrames: ramp));
        }
        events.sort((a, b) {
          final f = a.sourceFrame.compareTo(b.sourceFrame);
          return f != 0 ? f : a.bus.compareTo(b.bus);
        });
        for (var i = 1; i < events.length; i++) {
          if (events[i].sourceFrame == events[i - 1].sourceFrame &&
              events[i].bus == events[i - 1].bus) {
            throw UnsupportedError(
                'Source-ms events collide at native sample rate');
          }
        }
      }
      final start = framesForMilliseconds(clip.timelineStartMs, sampleRate);
      final end = framesForMilliseconds(clip.timelineEndMs, sampleRate);
      final sourceStart =
          framesForMilliseconds(clip.placement.sourceStartMs, sampleRate);
      if (sourceStart > input.sourceFrameCount ||
          end - start > input.sourceFrameCount - sourceStart) {
        throw ArgumentError('Clip outside verified source extent');
      }
      for (final w in input.windows) {
        if (w.assetId != input.assetId ||
            w.pcm.isReleased ||
            w.pcm.sampleRate != sampleRate ||
            w.pcm.busCount != input.buses.length ||
            w.sourceStartFrame < 0 ||
            w.sourceStartFrame > input.sourceFrameCount ||
            w.pcm.frameCount > input.sourceFrameCount - w.sourceStartFrame) {
          throw ArgumentError('Resident window identity/coverage mismatch');
        }
      }
      if (end <= clock.timelineFrame || end <= start) continue;
      final clippedStart = math.max(start, clock.timelineFrame);
      final clippedSource = sourceStart + clippedStart - start;
      for (final event in events) {
        if (event.sourceFrame >= clippedSource &&
            event.sourceFrame - clippedSource < end - clippedStart) {
          eventFrames.add(clock.nativeFrameFor(clippedStart) +
              event.sourceFrame -
              clippedSource);
        }
      }
      var fadeIn = envelope.fadeInMs, fadeOut = envelope.fadeOutMs;
      if (fadeIn + fadeOut > clip.timelineDurationMs) {
        fadeIn =
            (fadeIn * clip.timelineDurationMs / (fadeIn + fadeOut)).floor();
        fadeOut = clip.timelineDurationMs - fadeIn;
      }
      final inFrames = framesForMilliseconds(fadeIn, sampleRate);
      final outFrames = framesForMilliseconds(fadeOut, sampleRate);
      if (inFrames + outFrames > end - start) {
        throw UnsupportedError('Fade rounding exceeds clip');
      }
      clips.add(NativeArrangementClip(
          instanceId: input.instanceId,
          assetId: input.assetId,
          startFrame: clock.nativeFrameFor(clippedStart),
          endFrame: clock.nativeFrameFor(end),
          sourceStartFrame: sourceStart + clippedStart - start,
          sourceFrameCount: input.sourceFrameCount,
          buses: input.buses,
          baseGain: math.pow(10, envelope.baseGainDb / 20).toDouble(),
          envelopeSourceStartFrame: sourceStart,
          envelopeFrameCount: end - start,
          fadeInFrames: inFrames,
          fadeOutFrames: outFrames,
          equalPowerFade: envelope.curve == FadeCurve.equalPower,
          stemEvents: events,
          stemOverrideMask: input.stemOverrideMask));
      for (final w in input.windows) {
        if (!windows.any((x) =>
            x.assetId == w.assetId &&
            x.sourceStartFrame == w.sourceStartFrame &&
            identical(x.pcm, w.pcm))) {
          windows.add(w);
        }
      }
    }
    if (windows.length > NativeArrangementPlan.maxWindows ||
        windows.fold<int>(0, (n, w) => n + w.pcm.frameCount) >
            NativeArrangementPlan.maxResidentFrames) {
      throw ArgumentError('Residency budget exceeded');
    }
    if (maxBlockFrames != null) {
      eventFrames.sort();
      for (var i = NativeArrangementPlan.maxEventsPerBlock;
          i < eventFrames.length;
          i++) {
        if (eventFrames[i] -
                eventFrames[i - NativeArrangementPlan.maxEventsPerBlock] <
            maxBlockFrames) {
          throw UnsupportedError(
              'Authored event density exceeds callback budget');
        }
      }
    }
    return NativeArrangementPlan(
        revision: revision,
        clips: clips,
        windows: windows,
        masterGain: masterGain);
  }

  /// ONE bounded logical window, at most four intersecting instances (even if
  /// sequential). Does not execute saved stem edits or fades; use the full path.
  static NativeMixPlan compileWindow({
    required TimelineModel timeline,
    required Map<String, NativeMixClipInput> inputs,
    required int sampleRate,
    required int revision,
    required int windowStartFrame,
    required int windowEndFrame,
    NativeMixClockAnchor clock = const NativeMixClockAnchor(),
    double masterGain = 1,
  }) {
    if (sampleRate <= 0 || sampleRate > 0xffffffff) {
      throw ArgumentError.value(sampleRate, 'sampleRate');
    }
    _frame(windowStartFrame, 'windowStartFrame');
    _frame(windowEndFrame, 'windowEndFrame');
    if (windowEndFrame <= windowStartFrame) throw ArgumentError('Empty window');
    _gain(masterGain);
    if (revision <= 0) throw ArgumentError.value(revision, 'revision');
    // Capacity is an arrangement/window capability, independent of prepared
    // slot assignment. Detect it before rejecting an inevitable slot collision.
    final intersecting = timeline.clips.where((clip) =>
        framesForMilliseconds(clip.timelineEndMs, sampleRate) >
            windowStartFrame &&
        framesForMilliseconds(clip.timelineStartMs, sampleRate) <
            windowEndFrame);
    if (intersecting.length > 4) {
      throw UnsupportedError(
          'Window intersects a fifth clip; split the window');
    }
    final decks = <NativeMixDeck>[];
    final ids = <String>{};
    final slots = <int>{};
    for (final clip in timeline.clips) {
      if (!ids.add(clip.id)) {
        throw ArgumentError('Duplicate clip ID: ${clip.id}');
      }
      final start = framesForMilliseconds(clip.timelineStartMs, sampleRate);
      final end = framesForMilliseconds(clip.timelineEndMs, sampleRate);
      if (end <= windowStartFrame || start >= windowEndFrame) continue;

      if (clip.stemEdits != null) {
        throw UnsupportedError('Saved stem automation is not compiled yet');
      }
      if (clip.playbackRate != 1 ||
          clip.rateAutomation.baseRate != 1 ||
          clip.rateAutomation.segments.isNotEmpty) {
        throw UnsupportedError('Native renderer supports constant rate 1 only');
      }
      final envelope = clip.envelope;
      if (!envelope.baseGainDb.isFinite ||
          envelope.baseGainDb > 0 ||
          envelope.fadeInMs != 0 ||
          envelope.fadeOutMs != 0) {
        throw UnsupportedError(
            'Only finite non-amplifying flat envelopes supported');
      }
      final input = inputs[clip.id];
      if (input == null) throw StateError('No prepared PCM for ${clip.id}');
      if (input.pcm.isReleased ||
          input.pcm.sampleRate != sampleRate ||
          input.slot < 0 ||
          input.slot > 3 ||
          !slots.add(input.slot) ||
          input.instanceId <= 0 ||
          input.buses.length != input.pcm.busCount) {
        throw ArgumentError('Invalid prepared input for ${clip.id}');
      }
      _frame(input.sourceOriginFrame, 'sourceOriginFrame');
      final clippedStart = math.max(start, windowStartFrame);
      final clippedEnd = math.min(end, windowEndFrame);
      final source =
          framesForMilliseconds(clip.placement.sourceStartMs, sampleRate) +
              (clippedStart - start) -
              input.sourceOriginFrame;
      if (source < 0 ||
          source >= input.pcm.frameCount ||
          clippedEnd - clippedStart > input.pcm.frameCount - source) {
        throw StateError(
            'Prepared PCM does not cover requested window: ${clip.id}');
      }
      final baseGain = math.pow(10, envelope.baseGainDb / 20).toDouble();
      final controls = <NativeMixBus>[];
      for (final bus in input.buses) {
        _gain(bus.gain);
        if (bus.rampFrames < 0 || bus.rampFrames > 0xffffffff) {
          throw ArgumentError.value(bus.rampFrames, 'rampFrames');
        }
        controls.add(NativeMixBus(
            gain: bus.gain * baseGain,
            muted: bus.muted,
            rampFrames: bus.rampFrames));
      }
      decks.add(NativeMixDeck(
        slot: input.slot,
        instanceId: input.instanceId,
        pcm: input.pcm,
        startFrame: clock.nativeFrameFor(clippedStart),
        endFrame: clock.nativeFrameFor(clippedEnd),
        sourceStartFrame: source,
        buses: controls,
      ));
    }
    return NativeMixPlan(
        revision: revision, decks: decks, masterGain: masterGain);
  }

  /// Nonnegative nearest-frame rounding; exact half ties round UP. Integer
  /// arithmetic avoids double loss for long arrangements; reject signed overflow.
  static int framesForMilliseconds(int milliseconds, int sampleRate) {
    if (milliseconds < 0 ||
        sampleRate <= 0 ||
        sampleRate > 0xffffffff ||
        milliseconds > (_maxFrame - 500) ~/ sampleRate) {
      throw ArgumentError('Milliseconds/sample rate outside supported range');
    }
    return (milliseconds * sampleRate + 500) ~/ 1000;
  }
}

const _maxFrame = 0x7fffffffffffffff;
void _frame(int value, String name) {
  if (value < 0 || value > _maxFrame) throw ArgumentError.value(value, name);
}

void _gain(double gain) {
  if (!gain.isFinite || gain < 0 || gain > 1) {
    throw ArgumentError.value(gain, 'gain', 'Must be finite in [0,1]');
  }
}
