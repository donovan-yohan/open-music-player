import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../api/api_client.dart';

const int defaultSignedAudioTtlSeconds = 5 * 60;

typedef PlaybackUrlRequester =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> body);

class SignedAudioDescriptor {
  final int trackId;
  final String url;
  final DateTime expiresAt;
  final String? contentType;
  final int? sizeBytes;
  final String? etag;
  final String? storageVersion;

  const SignedAudioDescriptor({
    required this.trackId,
    required this.url,
    required this.expiresAt,
    this.contentType,
    this.sizeBytes,
    this.etag,
    this.storageVersion,
  });

  factory SignedAudioDescriptor.fromJson(Map<String, dynamic> json) {
    final trackId = json['trackId'];
    final url = json['url'];
    final expiresAt = json['expiresAt'];

    if (trackId is! int ||
        url is! String ||
        url.isEmpty ||
        expiresAt is! String) {
      throw const SignedAudioUrlException(
        code: 'INVALID_DESCRIPTOR',
        message: 'Playback URL response was missing a usable signed URL.',
      );
    }

    return SignedAudioDescriptor(
      trackId: trackId,
      url: url,
      expiresAt: DateTime.parse(expiresAt).toUtc(),
      contentType: json['contentType'] as String?,
      sizeBytes: json['sizeBytes'] as int?,
      etag: json['etag'] as String?,
      storageVersion:
          json['storageKeyVersion'] as String? ??
          json['storageVersion'] as String?,
    );
  }

  bool isExpired({DateTime? now}) {
    return !(now ?? DateTime.now().toUtc()).isBefore(expiresAt);
  }
}

class SignedAudioUnavailable {
  final int trackId;
  final String code;
  final String message;

  const SignedAudioUnavailable({
    required this.trackId,
    required this.code,
    required this.message,
  });

  factory SignedAudioUnavailable.fromJson(Map<String, dynamic> json) {
    return SignedAudioUnavailable(
      trackId: json['trackId'] as int,
      code: json['code'] as String? ?? 'AUDIO_UNAVAILABLE',
      message: json['message'] as String? ?? 'Audio is unavailable.',
    );
  }
}

class SignedAudioUrlResponse {
  final List<SignedAudioDescriptor> urls;
  final List<SignedAudioUnavailable> unavailable;

  const SignedAudioUrlResponse({required this.urls, required this.unavailable});

  factory SignedAudioUrlResponse.fromJson(Map<String, dynamic> json) {
    final urlsJson = json['urls'] as List<dynamic>? ?? const [];
    final unavailableJson = json['unavailable'] as List<dynamic>? ?? const [];

    return SignedAudioUrlResponse(
      urls: urlsJson
          .map(
            (item) =>
                SignedAudioDescriptor.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
      unavailable: unavailableJson
          .map(
            (item) =>
                SignedAudioUnavailable.fromJson(item as Map<String, dynamic>),
          )
          .toList(),
    );
  }

  Map<int, SignedAudioDescriptor> get byTrackId => {
    for (final descriptor in urls) descriptor.trackId: descriptor,
  };
}

class SignedAudioUrlException implements Exception {
  final String code;
  final String message;
  final int? statusCode;
  final int? trackId;

  const SignedAudioUrlException({
    required this.code,
    required this.message,
    this.statusCode,
    this.trackId,
  });

  factory SignedAudioUrlException.fromDio(DioException error) {
    final data = error.response?.data;
    if (data is Map<String, dynamic>) {
      return SignedAudioUrlException(
        code: data['code'] as String? ?? 'PLAYBACK_URL_REQUEST_FAILED',
        message:
            data['message'] as String? ?? 'Failed to request playback URL.',
        statusCode: error.response?.statusCode,
      );
    }

    return SignedAudioUrlException(
      code: 'PLAYBACK_URL_REQUEST_FAILED',
      message: error.message ?? 'Failed to request playback URL.',
      statusCode: error.response?.statusCode,
    );
  }

  @override
  String toString() => 'SignedAudioUrlException($code): $message';
}

class SignedAudioUrlService {
  final ApiClient? _api;
  final PlaybackUrlRequester? _requester;
  final int defaultTtlSeconds;

  const SignedAudioUrlService(
    ApiClient api, {
    this.defaultTtlSeconds = defaultSignedAudioTtlSeconds,
  }) : _api = api,
       _requester = null;

  const SignedAudioUrlService.withRequester(
    PlaybackUrlRequester requester, {
    this.defaultTtlSeconds = defaultSignedAudioTtlSeconds,
  }) : _api = null,
       _requester = requester;

  Future<SignedAudioUrlResponse> requestDescriptors(
    Iterable<int> trackIds, {
    int? ttlSeconds,
  }) async {
    final normalizedIds = _normalizeTrackIds(trackIds);
    if (normalizedIds.isEmpty) {
      throw const SignedAudioUrlException(
        code: 'INVALID_TRACK_IDS',
        message: 'At least one track ID is required for playback URL issuance.',
      );
    }

    final body = <String, dynamic>{
      'trackIds': normalizedIds,
      'ttlSeconds': ttlSeconds ?? defaultTtlSeconds,
    };

    try {
      final data = await _request(body);
      return SignedAudioUrlResponse.fromJson(data);
    } on DioException catch (error) {
      final mapped = SignedAudioUrlException.fromDio(error);
      _debugPlaybackUrlFailure(mapped);
      throw mapped;
    } on SignedAudioUrlException catch (error) {
      _debugPlaybackUrlFailure(error);
      rethrow;
    } catch (error) {
      final mapped = SignedAudioUrlException(
        code: 'PLAYBACK_URL_PARSE_FAILED',
        message: 'Failed to parse playback URL response: $error',
      );
      _debugPlaybackUrlFailure(mapped);
      throw mapped;
    }
  }

  Future<SignedAudioDescriptor> requireDescriptor(
    int trackId, {
    int? ttlSeconds,
  }) async {
    final response = await requestDescriptors([
      trackId,
    ], ttlSeconds: ttlSeconds);
    final descriptor = response.byTrackId[trackId];
    if (descriptor != null) {
      if (descriptor.isExpired()) {
        throw SignedAudioUrlException(
          code: 'PLAYBACK_URL_EXPIRED',
          message: 'Received an expired playback URL. Try again to refresh it.',
          trackId: trackId,
        );
      }
      return descriptor;
    }

    for (final unavailable in response.unavailable) {
      if (unavailable.trackId == trackId) {
        throw SignedAudioUrlException(
          code: unavailable.code,
          message: unavailable.message,
          trackId: trackId,
        );
      }
    }

    throw SignedAudioUrlException(
      code: 'PLAYBACK_URL_MISSING',
      message: 'Backend did not return a playback URL for track $trackId.',
      trackId: trackId,
    );
  }

  Future<Map<int, SignedAudioDescriptor>> requireDescriptors(
    Iterable<int> trackIds, {
    int? ttlSeconds,
  }) async {
    final normalizedIds = _normalizeTrackIds(trackIds);
    final response = await requestDescriptors(
      normalizedIds,
      ttlSeconds: ttlSeconds,
    );
    final descriptors = response.byTrackId;

    for (final unavailable in response.unavailable) {
      throw SignedAudioUrlException(
        code: unavailable.code,
        message: unavailable.message,
        trackId: unavailable.trackId,
      );
    }

    for (final trackId in normalizedIds) {
      final descriptor = descriptors[trackId];
      if (descriptor == null) {
        throw SignedAudioUrlException(
          code: 'PLAYBACK_URL_MISSING',
          message: 'Backend did not return a playback URL for track $trackId.',
          trackId: trackId,
        );
      }
      if (descriptor.isExpired()) {
        throw SignedAudioUrlException(
          code: 'PLAYBACK_URL_EXPIRED',
          message:
              'Received an expired playback URL for track $trackId. Try again to refresh it.',
          trackId: trackId,
        );
      }
    }

    return descriptors;
  }

  Future<Map<String, dynamic>> _request(Map<String, dynamic> body) async {
    final requester = _requester;
    if (requester != null) {
      return requester(body);
    }

    final api = _api;
    if (api == null) {
      throw const SignedAudioUrlException(
        code: 'PLAYBACK_URL_CLIENT_MISSING',
        message: 'Playback URL client is not configured.',
      );
    }

    final response = await api.post<Map<String, dynamic>>(
      '/playback/urls',
      data: body,
    );
    final data = response.data;
    if (data == null) {
      throw const SignedAudioUrlException(
        code: 'PLAYBACK_URL_EMPTY_RESPONSE',
        message: 'Playback URL response was empty.',
      );
    }
    return data;
  }

  List<int> _normalizeTrackIds(Iterable<int> trackIds) {
    final seen = <int>{};
    final normalized = <int>[];
    for (final id in trackIds) {
      if (id <= 0 || seen.contains(id)) continue;
      seen.add(id);
      normalized.add(id);
    }
    return normalized;
  }

  void _debugPlaybackUrlFailure(SignedAudioUrlException error) {
    if (kDebugMode) {
      debugPrint(
        'Signed audio URL request failed '
        '(code=${error.code}, status=${error.statusCode}, trackId=${error.trackId}).',
      );
    }
  }
}
