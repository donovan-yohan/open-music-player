import 'package:dio/dio.dart';

import '../models/track.dart';

class ApiClient {
  final Dio _dio;
  String? _authToken;

  ApiClient({String? baseUrl})
      : _dio = Dio(BaseOptions(
          baseUrl: baseUrl ?? 'http://localhost:8080/api/v1',
          connectTimeout: const Duration(seconds: 30),
          receiveTimeout: const Duration(seconds: 30),
        )) {
    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (_authToken != null) {
          options.headers['Authorization'] = 'Bearer $_authToken';
        }
        return handler.next(options);
      },
    ));
  }

  void setAuthToken(String? token) {
    _authToken = token;
  }

  Future<List<Track>> getLibrary({int page = 1, int limit = 50}) async {
    final response = await _dio.get('/library', queryParameters: {
      'page': page,
      'limit': limit,
    });
    final data = response.data as Map<String, dynamic>;
    final tracks = (data['tracks'] as List?)
            ?.map((t) => Track.fromJson(t as Map<String, dynamic>))
            .toList() ??
        [];
    return tracks;
  }

  Future<Track> getTrack(int id) async {
    final response = await _dio.get('/tracks/$id');
    return Track.fromJson(response.data as Map<String, dynamic>);
  }

  Future<String> getStreamUrl(int trackId) async {
    final response = await _dio.get('/tracks/$trackId/stream');
    return response.data['url'] as String;
  }

  Future<String> getDownloadUrl(int trackId) async {
    final response = await _dio.get('/tracks/$trackId/download');
    return response.data['url'] as String;
  }

  Future<void> addToLibrary(int trackId) async {
    await _dio.post('/library/tracks/$trackId');
  }

  Future<void> removeFromLibrary(int trackId) async {
    await _dio.delete('/library/tracks/$trackId');
  }

  Future<List<Track>> searchTracks(String query) async {
    final response = await _dio.get('/search/recordings', queryParameters: {
      'q': query,
    });
    final data = response.data as Map<String, dynamic>;
    final tracks = (data['tracks'] as List?)
            ?.map((t) => Track.fromJson(t as Map<String, dynamic>))
            .toList() ??
        [];
    return tracks;
  }
}
