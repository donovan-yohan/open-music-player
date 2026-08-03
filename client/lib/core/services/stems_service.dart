import '../stems/stem_channel_source.dart';
import 'api_client.dart';

/// Default channel set requested by this client. Matches
/// `stems.DefaultChannelSet` in the backend.
const String defaultStemChannelSet = 'stems5-hybrid-v1';

/// Durable separation state for one `(track, channelSet)` identity.
///
/// This is the client projection of the backend's `StemsStatusResponse`. The
/// [channels] list is read out of `artifacts.objects[].channel` — the worker's
/// manifest is the only authority on which stems actually exist on disk, so a
/// `ready` row with no objects is reported as having no channels rather than
/// being assumed to hold the full registry set.
class TrackStems {
  const TrackStems({
    required this.trackId,
    required this.channelSet,
    required this.status,
    this.stemModelVersion = '',
    this.channels = const <String>[],
    this.error = '',
    this.queuePosition = -1,
  });

  /// The state of a track the backend has never been asked about (404
  /// `STEMS_NOT_FOUND`), which is the normal starting point for every track.
  factory TrackStems.unavailable(
    int trackId, {
    String channelSet = defaultStemChannelSet,
  }) =>
      TrackStems(
        trackId: trackId,
        channelSet: channelSet,
        status: StemsStatus.unavailable,
      );

  factory TrackStems.fromJson(Map<String, dynamic> json) {
    final artifacts = json['artifacts'];
    return TrackStems(
      trackId: (json['trackId'] as num?)?.toInt() ?? 0,
      channelSet: json['channelSet'] as String? ?? defaultStemChannelSet,
      stemModelVersion: json['stemModelVersion'] as String? ?? '',
      status: stemsStatusFromWire(json['status'] as String?),
      channels: _channelsFromArtifacts(artifacts),
      error: json['error'] as String? ?? '',
      queuePosition: (json['queuePosition'] as num?)?.toInt() ?? -1,
    );
  }

  final int trackId;
  final String channelSet;
  final String stemModelVersion;
  final StemsStatus status;

  /// Canonical channel names present in the manifest, in manifest order.
  final List<String> channels;

  /// Backend failure text, empty unless [status] is [StemsStatus.failed].
  final String error;

  /// Live queue position, or `-1` when the job is not waiting.
  final int queuePosition;

  /// True only when the row says ready *and* the manifest actually lists
  /// objects. A ready row with an empty manifest is a backend bug, and a mixer
  /// with no channels is worse than an honest "not separated" state.
  bool get isReady => status == StemsStatus.ready && channels.isNotEmpty;

  bool get isPending => status == StemsStatus.pending;

  static List<String> _channelsFromArtifacts(Object? artifacts) {
    if (artifacts is! Map) return const <String>[];
    final objects = artifacts['objects'];
    if (objects is! List) return const <String>[];
    final channels = <String>[];
    for (final object in objects) {
      if (object is! Map) continue;
      final channel = (object['channel'] as String?)?.trim();
      if (channel == null || channel.isEmpty) continue;
      if (channels.contains(channel)) continue;
      channels.add(channel);
    }
    return List<String>.unmodifiable(channels);
  }
}

/// Result of the idempotent separation trigger.
class StemsRequestResult {
  const StemsRequestResult({
    required this.trackId,
    required this.channelSet,
    required this.status,
    required this.queued,
    this.queuePosition = -1,
    this.reason = '',
  });

  factory StemsRequestResult.fromJson(Map<String, dynamic> json) =>
      StemsRequestResult(
        trackId: (json['trackId'] as num?)?.toInt() ?? 0,
        channelSet: json['channelSet'] as String? ?? defaultStemChannelSet,
        status: stemsStatusFromWire(json['status'] as String?),
        queued: json['queued'] as bool? ?? false,
        queuePosition: (json['queuePosition'] as num?)?.toInt() ?? -1,
        reason: json['reason'] as String? ?? '',
      );

  final int trackId;
  final String channelSet;
  final StemsStatus status;

  /// False when the call was an idempotent no-op (already ready, already in
  /// flight). The durable row is authoritative either way.
  final bool queued;
  final int queuePosition;
  final String reason;
}

/// Client for the opt-in stem separation endpoints.
///
/// `GET /tracks/{id}/stems` legitimately 404s for every track nobody has asked
/// about yet, so that case is translated into [TrackStems.unavailable] instead
/// of an exception — "no stems" is a state, not an error. Every other failure
/// (401, 422 unknown channel set, 503 separation disabled) still surfaces as an
/// [ApiException] so a deck can say why the mixer is missing.
class StemsService {
  StemsService(this._apiClient);

  final ApiClient _apiClient;

  Future<TrackStems> getTrackStems(
    int trackId, {
    String channelSet = defaultStemChannelSet,
  }) async {
    try {
      return await _apiClient.get<TrackStems>(
        '/tracks/$trackId/stems',
        queryParams: {'channelSet': channelSet},
        parser: TrackStems.fromJson,
      );
    } on ApiException catch (e) {
      if (e.statusCode == 404) {
        return TrackStems.unavailable(trackId, channelSet: channelSet);
      }
      rethrow;
    }
  }

  /// Triggers separation. Idempotent: repeated calls converge on the single
  /// durable row and the single deterministic queue job, so a double tap on
  /// "Separate stems" cannot enqueue twice.
  Future<StemsRequestResult> requestSeparation(
    int trackId, {
    String channelSet = defaultStemChannelSet,
  }) =>
      _apiClient.post<StemsRequestResult>(
        '/tracks/$trackId/stems',
        body: {'channelSet': channelSet},
        parser: StemsRequestResult.fromJson,
      );
}
