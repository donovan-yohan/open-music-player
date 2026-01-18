import 'api_client.dart';

class QueueService {
  final ApiClient _apiClient;

  QueueService(this._apiClient);

  Future<void> addToQueue(List<String> trackIds, {String position = 'last'}) async {
    await _apiClient.post(
      '/queue/tracks',
      body: {
        'trackIds': trackIds,
        'position': position,
      },
    );
  }

  Future<void> clearQueue() async {
    await _apiClient.delete('/queue');
  }
}
