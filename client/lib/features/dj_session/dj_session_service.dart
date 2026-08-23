import 'package:dio/dio.dart';

import '../../core/api/api_client.dart';
import 'dj_session_models.dart';

abstract interface class DjSessionDataSource {
  Future<DjLineup> fetchLineup(DjLineupRequest request);
}

/// Authenticated client boundary for the server-owned DJ lineup contract.
///
/// This service only discovers library tracks. Queue mutation stays in the
/// existing QueueProvider so the session surface cannot become a playback
/// controller of its own.
class DjSessionService implements DjSessionDataSource {
  DjSessionService(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<DjLineup> fetchLineup(DjLineupRequest request) async {
    final response = await _apiClient.get<Map<String, dynamic>>(
      '/dj/lineup',
      queryParameters: request.toQueryParameters(),
    );
    final payload = response.data;
    if (payload == null) {
      throw const FormatException('DJ lineup response was not an object');
    }
    return DjLineup.fromJson(payload);
  }

  /// Pins the given lineup block so its energy/genre guidance survives across
  /// sessions until it expires or is replaced.
  Future<DjPin> pinBlock(String blockId) async {
    final response = await _apiClient.post<Map<String, dynamic>>(
      '/dj/pin',
      data: {'blockId': blockId},
    );
    return DjPin.fromJson(_requiredObject(response.data, 'DJ pin response'));
  }

  /// Removes the active pin. A missing pin (404) is treated as already gone
  /// rather than a failure, matching the idempotent backend contract.
  Future<void> unpinBlock() async {
    try {
      await _apiClient.delete<dynamic>('/dj/pin');
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
    }
  }

  /// Returns the active pin, or null when no pin exists (404).
  Future<DjPin?> fetchPin() async {
    try {
      final response = await _apiClient.get<Map<String, dynamic>>('/dj/pin');
      return DjPin.fromJson(
        _requiredObject(response.data, 'DJ pin response'),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  Map<String, dynamic> _requiredObject(Object? data, String message) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw FormatException('$message was not an object');
  }
}
