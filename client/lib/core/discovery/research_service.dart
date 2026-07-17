import 'package:dio/dio.dart';

import '../api/api_client.dart';
import 'discovery_models.dart';
import 'research_models.dart';

abstract interface class ResearchJobService {
  Future<ResearchSnapshot> create({
    required String query,
    List<String> providers = const ['youtube', 'soundcloud'],
    int limit = 12,
    String? idempotencyKey,
  });

  Future<ResearchSnapshot> get(String jobId);

  Future<ResearchEventPage> events(String jobId, {int afterSequence = 0});

  Future<ResearchSnapshot> cancel(String jobId);

  Future<ResearchSnapshot> retry(String jobId);

  Future<SourceSelectionDecision> review({
    required String jobId,
    required String candidateId,
    required SourceSelectionAction action,
    String? reason,
    String? idempotencyKey,
  });
}

class ResearchService implements ResearchJobService {
  const ResearchService(this._apiClient);

  final ApiClient _apiClient;

  @override
  Future<ResearchSnapshot> create({
    required String query,
    List<String> providers = const ['youtube', 'soundcloud'],
    int limit = 12,
    String? idempotencyKey,
  }) async {
    try {
      final response = await _apiClient.post<Map<String, dynamic>>(
        '/research-jobs',
        headers: {'Idempotency-Key': idempotencyKey ?? _idempotencyKey()},
        data: {'query': query, 'providers': providers, 'limit': limit},
      );
      return ResearchSnapshot.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ResearchException('Failed to create research job', _status(error));
    }
  }

  @override
  Future<ResearchSnapshot> get(String jobId) async {
    try {
      final response = await _apiClient.get<Map<String, dynamic>>(
        '/research-jobs/${Uri.encodeComponent(jobId)}',
      );
      return ResearchSnapshot.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ResearchException('Failed to load research job', _status(error));
    }
  }

  @override
  Future<ResearchEventPage> events(
    String jobId, {
    int afterSequence = 0,
  }) async {
    try {
      final response = await _apiClient.get<Map<String, dynamic>>(
        '/research-jobs/${Uri.encodeComponent(jobId)}/events',
        queryParameters: {'afterSequence': afterSequence, 'limit': 50},
      );
      return ResearchEventPage.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ResearchException(
        'Failed to load research progress',
        _status(error),
      );
    }
  }

  @override
  Future<ResearchSnapshot> cancel(String jobId) => _mutation(jobId, 'cancel');

  @override
  Future<ResearchSnapshot> retry(String jobId) => _mutation(jobId, 'retry');

  @override
  Future<SourceSelectionDecision> review({
    required String jobId,
    required String candidateId,
    required SourceSelectionAction action,
    String? reason,
    String? idempotencyKey,
  }) async {
    try {
      final response = await _apiClient.post<Map<String, dynamic>>(
        '/research-jobs/${Uri.encodeComponent(jobId)}/reviews',
        headers: {'Idempotency-Key': idempotencyKey ?? _idempotencyKey()},
        data: {
          'candidateId': candidateId,
          'action': action.jsonValue,
          if (reason != null && reason.trim().isNotEmpty)
            'reason': reason.trim(),
        },
      );
      return SourceSelectionDecision.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ResearchException('Failed to save research review', _status(error));
    }
  }

  Future<ResearchSnapshot> _mutation(String jobId, String operation) async {
    try {
      final response = await _apiClient.post<Map<String, dynamic>>(
        '/research-jobs/${Uri.encodeComponent(jobId)}/$operation',
      );
      return ResearchSnapshot.fromJson(_responseMap(response.data));
    } on DioException catch (error) {
      throw ResearchException(
        'Failed to $operation research job',
        _status(error),
      );
    }
  }

  int _status(DioException error) => error.response?.statusCode ?? 0;

  Map<String, dynamic> _responseMap(Object? data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw const FormatException(
      'Research endpoint returned an invalid response.',
    );
  }

  String _idempotencyKey() =>
      'research-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
}

class ResearchException implements Exception {
  const ResearchException(this.message, this.statusCode);

  final String message;
  final int statusCode;

  bool get canFallBackToAssist => statusCode == 0 || statusCode == 404;

  @override
  String toString() => '$message (status: $statusCode)';
}
