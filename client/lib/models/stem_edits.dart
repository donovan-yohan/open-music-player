import 'dart:math' as math;

/// Source-time-anchored stem gain automation (ADR 0006, `stemEdits` v1).
///
/// The authoring form is a list of **change points**: `(channel, atMs, gain)`.
/// A gain is held from its change point until the next change point on the same
/// channel, and the implicit gain before a channel's first change point is
/// `1.0`. [StemEdits.compileRanges] turns that authoring form back into ADR
/// 0006's half-open `[startMs, endMs)` range form, so the two representations
/// are provably equivalent.
///
/// Milliseconds are authoritative. `beatIndex` is advisory provenance only —
/// re-analysis may move a beat grid, and the stored `atMs` must not move with
/// it.
///
/// `atMs` is anchored to the **source file** identified by `sourceFileHash`,
/// not to a clip's trim window and not to timeline time. Retrimming or moving
/// a clip therefore never rewrites an edit. [StemEdits.compileRanges] compiles
/// over the half-open window `[0, clipDurationMs)` in that same source-ms
/// space.
///
/// This file is an authoring/rendering model only. It owns no playback state
/// and must never grow a transport, voice, or current-track authority
/// (ADR 0001).

/// Wire value of the `schemaVersion` field this client can author and read.
const int stemEditsSchemaVersion = 1;

/// Click-safe ramp bounds for a gain change point, in milliseconds.
const int stemRampDefaultMs = 8;
const int stemRampMinMs = 1;
const int stemRampMaxMs = 250;

/// Honesty copy required by ADR 0006.
///
/// Separator bleed means a "cut" is *mostly removed*. Product copy must never
/// promise that a stem was "isolated" or bare-"removed".
const String stemCutActionLabel = 'Cut (mostly removed)';
const String stemCutHonestyCopy =
    'Separation bleeds. A cut stem is mostly removed, not isolated.';
const String stemFullActionLabel = 'Full';

/// Raised when a `stemEdits` document cannot be safely interpreted by this
/// client. Callers must surface this rather than silently coercing the data.
class StemEditsFormatException implements Exception {
  const StemEditsFormatException(this.message);

  final String message;

  @override
  String toString() => 'StemEditsFormatException: $message';
}

/// One channel inside a versioned channel set.
class StemChannelDescriptor {
  const StemChannelDescriptor({
    required this.id,
    required this.label,
    required this.honestyCopy,
    this.modelSourceChannel,
  });

  /// Canonical wire name, e.g. `perc`.
  final String id;

  /// Display label. Carries ADR 0006 honesty for lossy channels, e.g.
  /// `Kick (low drums)`.
  final String label;

  /// One-line explanation of what this channel actually contains.
  final String honestyCopy;

  /// The separator output this channel is derived from, when it is an alias
  /// rather than a native model output (e.g. `melody` aliases demucs `other`).
  final String? modelSourceChannel;
}

/// Versioned, ordered channel set. Only the sets registered here can be
/// authored; an unknown `channelSet` is rejected rather than guessed at.
class StemChannelSet {
  const StemChannelSet._({
    required this.id,
    required this.stemModelVersion,
    required this.channels,
  });

  /// Canonical wire id, e.g. `stems5-hybrid-v1`.
  final String id;

  /// Canonical stem model version that produces this set.
  final String stemModelVersion;

  /// Channels in canonical display order.
  final List<StemChannelDescriptor> channels;

  List<String> get channelIds => <String>[
        for (final channel in channels) channel.id,
      ];

  bool contains(String channelId) =>
      channels.any((channel) => channel.id == channelId);

  StemChannelDescriptor descriptorFor(String channelId) => channels.firstWhere(
        (channel) => channel.id == channelId,
        orElse: () => throw StemEditsFormatException(
          'channel "$channelId" is not part of channel set "$id"',
        ),
      );

  int indexOf(String channelId) =>
      channels.indexWhere((channel) => channel.id == channelId);

  /// Demucs four-stem output, used directly.
  static const StemChannelSet stems4Demucs = StemChannelSet._(
    id: 'stems4-demucs-v1',
    stemModelVersion: 'htdemucs-4s-v1',
    channels: <StemChannelDescriptor>[
      StemChannelDescriptor(
        id: 'vocals',
        label: 'Vocals',
        honestyCopy: 'Lead and backing vocals.',
      ),
      StemChannelDescriptor(
        id: 'drums',
        label: 'Drums',
        honestyCopy: 'Full drum kit.',
      ),
      StemChannelDescriptor(
        id: 'bass',
        label: 'Bass',
        honestyCopy: 'Bass guitar and low synth.',
      ),
      StemChannelDescriptor(
        id: 'other',
        label: 'Other',
        honestyCopy: 'Everything the separator did not classify.',
      ),
    ],
  );

  /// Five-channel hybrid set: demucs four-stem plus a low/high split of the
  /// drum stem. `hihat` is retired — `perc` is the canonical wire name — and
  /// `melody` is the alias of demucs `other`.
  static const StemChannelSet stems5Hybrid = StemChannelSet._(
    id: 'stems5-hybrid-v1',
    stemModelVersion: 'htdemucs-4s-v1+lr4-180',
    channels: <StemChannelDescriptor>[
      StemChannelDescriptor(
        id: 'vocals',
        label: 'Vocals',
        honestyCopy: 'Lead and backing vocals.',
      ),
      StemChannelDescriptor(
        id: 'melody',
        label: 'Melody',
        honestyCopy: 'Synths, guitars and keys — the demucs "other" stem.',
        modelSourceChannel: 'other',
      ),
      StemChannelDescriptor(
        id: 'bass',
        label: 'Bass',
        honestyCopy: 'Bass guitar and low synth.',
      ),
      StemChannelDescriptor(
        id: 'kick',
        label: 'Kick (low drums)',
        honestyCopy: 'Low band of the drum stem, not a clean kick track.',
        modelSourceChannel: 'drums',
      ),
      StemChannelDescriptor(
        id: 'perc',
        label: 'Hats & Percussion',
        honestyCopy: 'High band of the drum stem. Cymbal bleed is expected.',
        modelSourceChannel: 'drums',
      ),
    ],
  );

  static const List<StemChannelSet> registry = <StemChannelSet>[
    stems4Demucs,
    stems5Hybrid,
  ];

  static StemChannelSet? tryById(String id) {
    for (final set in registry) {
      if (set.id == id) return set;
    }
    return null;
  }

  static StemChannelSet byId(String id) {
    final resolved = tryById(id);
    if (resolved == null) {
      throw StemEditsFormatException(
        'unknown stem channelSet "$id"; supported: '
        '${registry.map((set) => set.id).join(', ')}',
      );
    }
    return resolved;
  }
}

/// Reference to the beat grid the advisory `beatIndex` values were taken from.
class StemBeatGridRef {
  StemBeatGridRef({
    required this.analysisRef,
    required this.analysisVersion,
    Map<String, dynamic> unknownKeys = const <String, dynamic>{},
  }) : unknownKeys = Map<String, dynamic>.unmodifiable(unknownKeys);

  final String analysisRef;
  final String analysisVersion;

  /// Keys written by a newer client, preserved verbatim on decode -> encode.
  final Map<String, dynamic> unknownKeys;

  static const Set<String> _knownKeys = <String>{
    'analysisRef',
    'analysisVersion',
  };

  factory StemBeatGridRef.fromJson(Map<String, dynamic> json) =>
      StemBeatGridRef(
        analysisRef: json['analysisRef']?.toString() ?? '',
        analysisVersion: json['analysisVersion']?.toString() ?? '',
        unknownKeys: _unknownKeysOf(json, _knownKeys),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'analysisRef': analysisRef,
        'analysisVersion': analysisVersion,
        ...unknownKeys,
      };

  @override
  bool operator ==(Object other) =>
      other is StemBeatGridRef &&
      other.analysisRef == analysisRef &&
      other.analysisVersion == analysisVersion &&
      _mapEquals(other.unknownKeys, unknownKeys);

  @override
  int get hashCode => Object.hash(analysisRef, analysisVersion);
}

/// A single change point: from [atMs] onwards, [channel] is held at [gain].
class StemGainEvent {
  StemGainEvent({
    required this.channel,
    required int atMs,
    required double gain,
    int rampMs = stemRampDefaultMs,
    this.beatIndex,
    Map<String, dynamic> unknownKeys = const <String, dynamic>{},
  })  : atMs = math.max(0, atMs),
        gain = gain.isNaN ? 0.0 : gain.clamp(0.0, 1.0).toDouble(),
        rampMs = rampMs.clamp(stemRampMinMs, stemRampMaxMs).toInt(),
        unknownKeys = Map<String, dynamic>.unmodifiable(unknownKeys);

  /// Canonical wire name of the channel this change point applies to.
  final String channel;

  /// Authoritative **source-time** position of the change point.
  final int atMs;

  /// Linear gain, 0.0 .. 1.0. `0.0` is a cut.
  final double gain;

  /// Click-safe ramp length applied at [atMs].
  final int rampMs;

  /// Advisory provenance only. Never used to recompute [atMs].
  final int? beatIndex;

  /// Keys written by a newer client, preserved verbatim on decode -> encode.
  final Map<String, dynamic> unknownKeys;

  bool get isCut => gain <= 0;

  static const Set<String> _knownKeys = <String>{
    'channel',
    'atMs',
    'gain',
    'rampMs',
    'beatIndex',
  };

  StemGainEvent copyWith({
    int? atMs,
    double? gain,
    int? rampMs,
    int? beatIndex,
    bool clearBeatIndex = false,
  }) =>
      StemGainEvent(
        channel: channel,
        atMs: atMs ?? this.atMs,
        gain: gain ?? this.gain,
        rampMs: rampMs ?? this.rampMs,
        beatIndex: clearBeatIndex ? null : (beatIndex ?? this.beatIndex),
        unknownKeys: unknownKeys,
      );

  factory StemGainEvent.fromJson(Map<String, dynamic> json) {
    final channel = json['channel'];
    if (channel is! String || channel.trim().isEmpty) {
      throw const StemEditsFormatException(
        'stemEdits event is missing a "channel"',
      );
    }
    final atMs = json['atMs'];
    if (atMs is! num) {
      throw StemEditsFormatException(
        'stemEdits event for "$channel" is missing a numeric "atMs"',
      );
    }
    final gain = json['gain'];
    if (gain is! num) {
      throw StemEditsFormatException(
        'stemEdits event for "$channel" is missing a numeric "gain"',
      );
    }
    return StemGainEvent(
      channel: channel,
      atMs: atMs.toInt(),
      gain: gain.toDouble(),
      rampMs: (json['rampMs'] as num?)?.toInt() ?? stemRampDefaultMs,
      beatIndex: (json['beatIndex'] as num?)?.toInt(),
      unknownKeys: _unknownKeysOf(json, _knownKeys),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'channel': channel,
        'atMs': atMs,
        'gain': gain,
        'rampMs': rampMs,
        if (beatIndex != null) 'beatIndex': beatIndex,
        ...unknownKeys,
      };

  @override
  bool operator ==(Object other) =>
      other is StemGainEvent &&
      other.channel == channel &&
      other.atMs == atMs &&
      other.gain == gain &&
      other.rampMs == rampMs &&
      other.beatIndex == beatIndex &&
      _mapEquals(other.unknownKeys, unknownKeys);

  @override
  int get hashCode => Object.hash(channel, atMs, gain, rampMs, beatIndex);

  @override
  String toString() =>
      'StemGainEvent($channel @${atMs}ms -> $gain, ramp ${rampMs}ms)';
}

/// ADR 0006 range form: `[startMs, endMs)` in **source** time, one constant
/// gain per range.
class StemGainRange {
  const StemGainRange({
    required this.channel,
    required this.startMs,
    required this.endMs,
    required this.gain,
  });

  final String channel;
  final int startMs;
  final int endMs;
  final double gain;

  int get durationMs => endMs - startMs;

  /// Half-open containment: `startMs <= ms < endMs`.
  bool contains(int ms) => ms >= startMs && ms < endMs;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'channel': channel,
        'startMs': startMs,
        'endMs': endMs,
        'gain': gain,
      };

  @override
  bool operator ==(Object other) =>
      other is StemGainRange &&
      other.channel == channel &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.gain == gain;

  @override
  int get hashCode => Object.hash(channel, startMs, endMs, gain);

  @override
  String toString() =>
      'StemGainRange($channel [$startMs, $endMs) -> $gain)';
}

/// The `stemEdits` v1 document that hangs off one clip.
class StemEdits {
  StemEdits({
    required this.channelSet,
    required this.sourceFileHash,
    String? stemModelVersion,
    this.beatGridRef,
    List<StemGainEvent> events = const <StemGainEvent>[],
    Map<String, dynamic> unknownKeys = const <String, dynamic>{},
  })  : stemModelVersion = stemModelVersion ?? channelSet.stemModelVersion,
        events = _canonicalize(events),
        unknownKeys = Map<String, dynamic>.unmodifiable(unknownKeys);

  /// Always [stemEditsSchemaVersion]; a document with any other version is
  /// rejected at decode time rather than coerced.
  int get schemaVersion => stemEditsSchemaVersion;

  final StemChannelSet channelSet;
  final String stemModelVersion;
  final String sourceFileHash;
  final StemBeatGridRef? beatGridRef;

  /// Canonical order: ascending `atMs`, then ascending `channel`. At most one
  /// event exists per `(channel, atMs)`.
  final List<StemGainEvent> events;

  /// Keys written by a newer client, preserved verbatim on decode -> encode.
  final Map<String, dynamic> unknownKeys;

  bool get isEmpty => events.isEmpty;
  bool get isNotEmpty => events.isNotEmpty;

  /// True when [stemModelVersion] still matches the channel set's canonical
  /// model. A mismatch is carried, not rejected — checkpoints may drift.
  bool get hasCanonicalStemModelVersion =>
      stemModelVersion == channelSet.stemModelVersion;

  static const Set<String> _knownKeys = <String>{
    'schemaVersion',
    'channelSet',
    'stemModelVersion',
    'sourceFileHash',
    'beatGridRef',
    'events',
  };

  /// Change points for one channel, in ascending `atMs`.
  List<StemGainEvent> eventsFor(String channel) => <StemGainEvent>[
        for (final event in events)
          if (event.channel == channel) event,
      ];

  /// The gain held at [ms] on [channel]. Before a channel's first change point
  /// the implicit gain is `1.0`.
  double gainAt(String channel, int ms) {
    var gain = 1.0;
    for (final event in events) {
      if (event.channel != channel) continue;
      if (event.atMs > ms) break;
      gain = event.gain;
    }
    return gain;
  }

  /// The change point that is currently in force on [channel] at [ms], if any.
  StemGainEvent? activeEventAt(String channel, int ms) {
    StemGainEvent? active;
    for (final event in events) {
      if (event.channel != channel) continue;
      if (event.atMs > ms) break;
      active = event;
    }
    return active;
  }

  /// Adds or replaces a change point. An existing event on the same
  /// `(channel, atMs)` collapses to [event] — the later write wins.
  StemEdits withEvent(StemGainEvent event) {
    if (!channelSet.contains(event.channel)) {
      throw StemEditsFormatException(
        'channel "${event.channel}" is not part of channel set '
        '"${channelSet.id}"',
      );
    }
    return _copyWithEvents(<StemGainEvent>[...events, event]);
  }

  /// Removes the change point at exactly `(channel, atMs)`, if present.
  StemEdits withoutEvent({required String channel, required int atMs}) =>
      _copyWithEvents(<StemGainEvent>[
        for (final event in events)
          if (!(event.channel == channel && event.atMs == atMs)) event,
      ]);

  /// Snaps every change point to the nearest beat in [beatMs] and records the
  /// beat's index as advisory provenance. The **snapped ms is what is stored**
  /// — milliseconds stay authoritative afterwards.
  StemEdits quantizeToBeats(List<int> beatMs) {
    if (beatMs.isEmpty || events.isEmpty) return this;
    final grid = <int>[...beatMs]..sort();
    return _copyWithEvents(<StemGainEvent>[
      for (final event in events) _snapEvent(event, grid),
    ]);
  }

  static StemGainEvent _snapEvent(StemGainEvent event, List<int> grid) {
    final index = nearestBeatIndex(grid, event.atMs)!;
    return event.copyWith(atMs: grid[index], beatIndex: index);
  }

  /// Compiles the change-point form into ADR 0006's half-open source-ms range
  /// form, one constant-gain range per span, for every channel in the set.
  ///
  /// Output order is channel-set order, then ascending `startMs`. A channel
  /// with no change points yields exactly one `[0, clipDurationMs)` range at
  /// gain `1.0`.
  List<StemGainRange> compileRanges({required int clipDurationMs}) {
    final duration = math.max(0, clipDurationMs);
    if (duration == 0) return const <StemGainRange>[];

    final ranges = <StemGainRange>[];
    for (final descriptor in channelSet.channels) {
      final channel = descriptor.id;
      final channelEvents = <StemGainEvent>[
        for (final event in events)
          if (event.channel == channel && event.atMs < duration) event,
      ];

      if (channelEvents.isEmpty) {
        ranges.add(
          StemGainRange(
            channel: channel,
            startMs: 0,
            endMs: duration,
            gain: 1.0,
          ),
        );
        continue;
      }

      // Implicit leading range: gain is 1.0 until the first change point.
      if (channelEvents.first.atMs > 0) {
        ranges.add(
          StemGainRange(
            channel: channel,
            startMs: 0,
            endMs: channelEvents.first.atMs,
            gain: 1.0,
          ),
        );
      }

      for (var index = 0; index < channelEvents.length; index++) {
        final event = channelEvents[index];
        final endMs = index + 1 < channelEvents.length
            ? channelEvents[index + 1].atMs
            : duration;
        if (endMs <= event.atMs) continue;
        ranges.add(
          StemGainRange(
            channel: channel,
            startMs: event.atMs,
            endMs: endMs,
            gain: event.gain,
          ),
        );
      }
    }
    return List<StemGainRange>.unmodifiable(ranges);
  }

  StemEdits _copyWithEvents(List<StemGainEvent> nextEvents) => StemEdits(
        channelSet: channelSet,
        sourceFileHash: sourceFileHash,
        stemModelVersion: stemModelVersion,
        beatGridRef: beatGridRef,
        events: nextEvents,
        unknownKeys: unknownKeys,
      );

  factory StemEdits.fromJson(Map<String, dynamic> json) {
    final rawVersion = json['schemaVersion'];
    if (rawVersion is! num) {
      throw const StemEditsFormatException(
        'stemEdits is missing a numeric "schemaVersion"',
      );
    }
    final version = rawVersion.toInt();
    if (version != stemEditsSchemaVersion) {
      throw StemEditsFormatException(
        'unsupported stemEdits schemaVersion $version; this client only '
        'reads version $stemEditsSchemaVersion',
      );
    }

    final rawChannelSet = json['channelSet'];
    if (rawChannelSet is! String) {
      throw const StemEditsFormatException(
        'stemEdits is missing a "channelSet"',
      );
    }
    final channelSet = StemChannelSet.byId(rawChannelSet);

    final rawEvents = json['events'];
    if (rawEvents != null && rawEvents is! List) {
      throw const StemEditsFormatException('stemEdits "events" must be a list');
    }
    final events = <StemGainEvent>[
      for (final raw in (rawEvents as List? ?? const <dynamic>[]))
        StemGainEvent.fromJson(Map<String, dynamic>.from(raw as Map)),
    ];
    for (final event in events) {
      if (!channelSet.contains(event.channel)) {
        throw StemEditsFormatException(
          'stemEdits event channel "${event.channel}" is not part of channel '
          'set "${channelSet.id}"',
        );
      }
    }

    final rawBeatGrid = json['beatGridRef'];
    return StemEdits(
      channelSet: channelSet,
      stemModelVersion: json['stemModelVersion']?.toString(),
      sourceFileHash: json['sourceFileHash']?.toString() ?? '',
      beatGridRef: rawBeatGrid is Map
          ? StemBeatGridRef.fromJson(Map<String, dynamic>.from(rawBeatGrid))
          : null,
      events: events,
      unknownKeys: _unknownKeysOf(json, _knownKeys),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schemaVersion': schemaVersion,
        'channelSet': channelSet.id,
        'stemModelVersion': stemModelVersion,
        'sourceFileHash': sourceFileHash,
        if (beatGridRef != null) 'beatGridRef': beatGridRef!.toJson(),
        'events': <Map<String, dynamic>>[
          for (final event in events) event.toJson(),
        ],
        ...unknownKeys,
      };

  /// Sorts by `(atMs, channel)` and collapses duplicate `(channel, atMs)`
  /// pairs to the later-written event.
  static List<StemGainEvent> _canonicalize(List<StemGainEvent> input) {
    // Keyed by a record so the identity is structural - no separator
    // character has to be reserved out of the channel namespace.
    final collapsed = <(String, int), StemGainEvent>{};
    for (final event in input) {
      collapsed[(event.channel, event.atMs)] = event;
    }
    final sorted = collapsed.values.toList()
      ..sort((a, b) {
        final byTime = a.atMs.compareTo(b.atMs);
        if (byTime != 0) return byTime;
        return a.channel.compareTo(b.channel);
      });
    return List<StemGainEvent>.unmodifiable(sorted);
  }

  @override
  bool operator ==(Object other) =>
      other is StemEdits &&
      other.channelSet.id == channelSet.id &&
      other.stemModelVersion == stemModelVersion &&
      other.sourceFileHash == sourceFileHash &&
      other.beatGridRef == beatGridRef &&
      _listEquals(other.events, events) &&
      _mapEquals(other.unknownKeys, unknownKeys);

  @override
  int get hashCode => Object.hash(
        channelSet.id,
        stemModelVersion,
        sourceFileHash,
        beatGridRef,
        Object.hashAll(events),
      );
}

/// Index of the beat in [beatMs] closest to [atMs], or `null` for an empty
/// grid. Ties resolve to the earlier beat.
int? nearestBeatIndex(List<int> beatMs, int atMs) {
  if (beatMs.isEmpty) return null;
  var bestIndex = 0;
  var bestDistance = (beatMs.first - atMs).abs();
  for (var index = 1; index < beatMs.length; index++) {
    final distance = (beatMs[index] - atMs).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      bestIndex = index;
    }
  }
  return bestIndex;
}

Map<String, dynamic> _unknownKeysOf(
  Map<String, dynamic> json,
  Set<String> knownKeys,
) {
  final unknown = <String, dynamic>{};
  for (final entry in json.entries) {
    if (knownKeys.contains(entry.key)) continue;
    unknown[entry.key] = entry.value;
  }
  return unknown;
}

bool _listEquals(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

bool _mapEquals(Map<String, dynamic> a, Map<String, dynamic> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key)) return false;
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
