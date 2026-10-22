import 'dart:convert';

/// Validated encoded stem descriptors. This is not the UI/energy DTO and does
/// not establish decoder readiness: PCM alignment is claimed metadata until a
/// real Opus decoder has applied preskip/end trimming.
class PreparedStemManifest {
  PreparedStemManifest._({
    required this.trackId,
    required this.channelSet,
    required this.stemModelVersion,
    required this.sourceFileHash,
    required this.sourceStorageKey,
    required this.generation,
    required this.durationMs,
    required this.channels,
    required this.members,
  });

  static const schemaVersion = 1;
  static const hybridChannelSet = 'stems5-hybrid-v1';
  static const fourChannelSet = 'stems4-demucs-v1';
  static const _models = {
    hybridChannelSet: 'audio-separator-htdemucs-ft-4s-v1+lr4-180',
    fourChannelSet: 'audio-separator-htdemucs-ft-4s-v1',
  };
  static const _channels = {
    hybridChannelSet: ['vocals', 'melody', 'bass', 'kick', 'perc'],
    fourChannelSet: ['vocals', 'drums', 'bass', 'other'],
  };

  final int trackId;
  final String channelSet;
  final String stemModelVersion;
  final String sourceFileHash;
  final String sourceStorageKey;
  final int generation;
  final int durationMs;
  final List<String> channels;

  /// Hybrid manifests include the drums null-sum reference in addition to the
  /// five disjoint DJ channels; never sum drums together with kick/perc.
  final Map<String, PreparedStemMember> members;
  int get sampleFrames => members.values.first.sampleFrames;
  int get sampleRateHz => members.values.first.sampleRateHz;
  int get audioChannels => members.values.first.audioChannels;
  int get totalBytes =>
      members.values.fold(0, (sum, member) => sum + member.bytes);

  /// Immutable publication identity, deliberately independent of URL/query/TTL.
  String get identity => '$trackId/$channelSet/$stemModelVersion/'
      '$sourceFileHash/g$generation/'
      '${members.values.map((member) => '${member.channel}:${member.sha256}:${member.bytes}').join('/')}';

  static void validateRequest(int trackId, String channelSet,
      String expectedSourceFileHash, int? expectedGeneration) {
    _require(trackId > 0 && trackId <= _maxInteger, 'invalid track identity');
    _require(_models.containsKey(channelSet), 'unknown channel set');
    _require(
        _sourceHash.hasMatch(expectedSourceFileHash), 'invalid source hash');
    _require(
        expectedGeneration == null ||
            (expectedGeneration > 0 && expectedGeneration <= _maxInteger),
        'invalid expected generation');
  }

  factory PreparedStemManifest.fromStatusJson(
    Map<String, dynamic> status, {
    required int expectedTrackId,
    required String channelSet,
    required String expectedSourceFileHash,
    int? expectedGeneration,
    DateTime? now,
    bool allowLoopbackHttp = false,
  }) {
    validateRequest(expectedTrackId, channelSet, expectedSourceFileHash,
        expectedGeneration);
    final manifest = _map(status['publishedManifest'], 'publishedManifest');
    final model = _models[channelSet]!;
    final generation = _integer(status['generation'], 'generation');
    _integer(status['schemaVersion'], 'schemaVersion');
    _integer(status['trackId'], 'trackId');
    _integer(manifest['schema_version'], 'schema_version');
    _integer(manifest['track_id'], 'track_id');
    _integer(manifest['generation'], 'manifest generation');
    _require(
        status['status'] == 'ready' &&
            status['schemaVersion'] == schemaVersion &&
            status['trackId'] == expectedTrackId &&
            status['channelSet'] == channelSet &&
            status['stemModelVersion'] == model &&
            status['sourceFileHash'] == expectedSourceFileHash &&
            (expectedGeneration == null || generation == expectedGeneration) &&
            manifest['schema_version'] == schemaVersion &&
            manifest['track_id'] == expectedTrackId &&
            manifest['channel_set'] == channelSet &&
            manifest['stem_model_version'] == model &&
            manifest['source_file_hash'] == expectedSourceFileHash &&
            manifest['generation'] == generation,
        'publication identity mismatch');
    final provenance = _map(manifest['provenance'], 'provenance');
    _require(
        provenance['worker'] == 'stemsep-worker' &&
            provenance['worker_version'] == '2026-08-30-1',
        'unsupported worker');
    final artifacts = _map(manifest['artifacts'], 'artifacts');
    final codec = _map(artifacts['codec'], 'codec');
    _require(
        codec['name'] == 'libopus' &&
            _integer(codec['sample_rate_hz'], 'codec rate') == 48000 &&
            _integer(codec['channels'], 'codec channels') == 2,
        'unsupported codec');
    if (channelSet == hybridChannelSet) {
      final nullSum = _map(artifacts['null_sum'], 'null_sum');
      final residual = nullSum['residual_db'];
      final pair = _list(nullSum['pair'], 'null_sum pair');
      _require(
          nullSum['passed'] == true &&
              residual is num &&
              residual.isFinite &&
              residual <= -80 &&
              nullSum['threshold_db'] == -80 &&
              pair.length == 2 &&
              pair[0] == 'kick' &&
              pair[1] == 'perc' &&
              nullSum['against'] == 'drums',
          'invalid crossover null sum');
    }
    final roles = [
      ..._channels[channelSet]!,
      if (channelSet == hybridChannelSet) 'drums'
    ];
    final objects = _list(artifacts['objects'], 'objects');
    final downloads = _list(status['memberDownloads'], 'memberDownloads');
    _require(objects.length == roles.length && downloads.length == roles.length,
        'incomplete member set');
    final downloadsByChannel = <String, Map<String, dynamic>>{};
    for (final value in downloads) {
      final download = _map(value, 'download');
      final channel = _string(download['channel'], 'download channel');
      _require(
          roles.contains(channel) && !downloadsByChannel.containsKey(channel),
          'unknown or duplicate download');
      downloadsByChannel[channel] = download;
    }
    final members = <String, PreparedStemMember>{};
    for (final value in objects) {
      final object = _map(value, 'member');
      final channel = _string(object['channel'], 'channel');
      _require(roles.contains(channel) && !members.containsKey(channel),
          'unknown or duplicate member');
      final download = downloadsByChannel[channel]!;
      final digest = _string(object['sha256'], 'sha256');
      final key = _string(object['key'], 'key');
      final size = _integer(object['bytes'], 'bytes');
      final baseChannel = channel == 'melody' ? 'other' : channel;
      final expectedKey = 'stems/$expectedTrackId/$model/'
          '${expectedSourceFileHash.substring(7)}/g$generation/$baseChannel/$digest.opus';
      _require(
          _digest.hasMatch(digest) &&
              key == expectedKey &&
              (object['path'] == null || object['path'] == '') &&
              object['derivation'] ==
                  (channel == 'kick' || channel == 'perc'
                      ? 'dsp-crossover-lr4-180'
                      : 'separator'),
          'invalid member identity');
      _require(
          download['key'] == key &&
              download['sha256'] == digest &&
              _integer(download['bytes'], 'download bytes') == size,
          'download identity mismatch');
      final url = Uri.tryParse(_string(download['url'], 'url'));
      _require(
          url != null &&
              url.isAbsolute &&
              url.hasAuthority &&
              url.host.isNotEmpty &&
              url.userInfo.isEmpty &&
              !url.hasFragment &&
              (url.scheme == 'https' ||
                  (allowLoopbackHttp &&
                      url.scheme == 'http' &&
                      ['127.0.0.1', '::1', 'localhost'].contains(url.host))),
          'unsafe download URL');
      final expires =
          DateTime.tryParse(_string(download['expiresAt'], 'expiresAt'));
      _require(expires != null && expires.isAfter(now ?? DateTime.now()),
          'expired download URL');
      final member = PreparedStemMember._(
        channel: channel,
        key: key,
        sha256: digest,
        bytes: size,
        sampleFrames: _integer(object['sample_frames'], 'sample_frames'),
        sampleRateHz: _integer(object['sample_rate_hz'], 'sample_rate_hz'),
        audioChannels: _integer(object['channels'], 'channels'),
        durationMs: _integer(object['duration_ms'], 'duration_ms'),
        originFrame:
            _integer(object['origin_frame'], 'origin_frame', minimum: 0),
        delayFrames:
            _integer(object['delay_frames'], 'delay_frames', minimum: 0),
        encoderDelayFrames: _integer(
            object['encoder_delay_frames'], 'encoder_delay_frames',
            minimum: 0),
        url: url!,
        expiresAt: expires!,
      );
      _require(
          member.sampleRateHz == 48000 &&
              member.audioChannels == 2 &&
              member.originFrame == 0 &&
              member.delayFrames == 0 &&
              object['delay_provenance'] ==
                  'ffmpeg-ogg-opus-preskip-end-trim-v1' &&
              (member.durationMs - member.sampleFrames * 1000 / 48000).abs() <=
                  1,
          'invalid member PCM timeline');
      if (members.isNotEmpty) {
        final first = members.values.first;
        _require(
            member.sampleFrames == first.sampleFrames &&
                member.encoderDelayFrames == first.encoderDelayFrames,
            'unaligned stem members');
      }
      members[channel] = member;
    }
    // Validate the independent 80 Hz visualization grid without projecting it
    // onto PCM frame count or retaining decoded energy buffers.
    final energy = _map(artifacts['energy'], 'energy');
    final energyChannels = _map(energy['channels'], 'energy channels');
    final energyFrames =
        _integer(energy['frame_count'], 'energy frame_count', minimum: 0);
    _require(
        _integer(energy['frame_hz'], 'energy frame_hz') == 80 &&
            energy['encoding'] == 'uint8-linear' &&
            energyFrames ==
                (members.values.first.sampleFrames * 80 / 48000).round() &&
            energyChannels.length == roles.length,
        'invalid energy grid');
    for (final role in roles) {
      final encoded = energyChannels[role];
      _require(
          encoded is String && encoded.length == ((energyFrames + 2) ~/ 3) * 4,
          'invalid energy member');
      _require(base64.decode(encoded as String).length == energyFrames,
          'invalid energy bytes');
    }
    final durationMs = _integer(manifest['duration_ms'], 'duration_ms');
    _require(
        (durationMs - members.values.first.sampleFrames * 1000 / 48000).abs() <=
            1,
        'manifest duration mismatch');
    // Snapshot declaration order into canonical member order, independently of
    // JSON/download ordering. Identity additionally records every byte digest.
    return PreparedStemManifest._(
        trackId: expectedTrackId,
        channelSet: channelSet,
        stemModelVersion: model,
        sourceFileHash: expectedSourceFileHash,
        sourceStorageKey:
            _string(manifest['source_storage_key'], 'source_storage_key'),
        generation: generation,
        durationMs: _integer(manifest['duration_ms'], 'duration_ms'),
        channels: List.unmodifiable(_channels[channelSet]!),
        members:
            Map.unmodifiable({for (final role in roles) role: members[role]!}));
  }
}

class PreparedStemMember {
  const PreparedStemMember._(
      {required this.channel,
      required this.key,
      required this.sha256,
      required this.bytes,
      required this.sampleFrames,
      required this.sampleRateHz,
      required this.audioChannels,
      required this.durationMs,
      required this.originFrame,
      required this.delayFrames,
      required this.encoderDelayFrames,
      required this.url,
      required this.expiresAt});
  final String channel;
  final String key;
  final String sha256;
  final int bytes;
  final int sampleFrames;
  final int sampleRateHz;
  final int audioChannels;
  final int durationMs;
  final int originFrame;
  final int delayFrames;
  final int encoderDelayFrames;
  final Uri url;
  final DateTime expiresAt;
}

const _maxInteger = 9007199254740991; // Exact on Dart native and JS.
final _sourceHash = RegExp(r'^sha256:[0-9a-f]{64}$');
final _digest = RegExp(r'^[0-9a-f]{64}$');
void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

Map<String, dynamic> _map(Object? value, String name) {
  if (value is! Map<String, dynamic>) throw FormatException('invalid $name');
  return value;
}

List<dynamic> _list(Object? value, String name) {
  if (value is! List) throw FormatException('invalid $name');
  return value;
}

String _string(Object? value, String name) {
  if (value is! String || value.isEmpty || value.trim() != value) {
    throw FormatException('invalid $name');
  }
  return value;
}

int _integer(Object? value, String name, {int minimum = 1}) {
  if (value is! int || value < minimum || value > _maxInteger) {
    throw FormatException('invalid $name');
  }
  return value;
}
