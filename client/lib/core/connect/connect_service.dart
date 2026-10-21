import 'package:dio/dio.dart';
import '../api/api_client.dart';
import '../storage/secure_storage.dart';
import 'connect_models.dart';

class ConnectService {
  ConnectService(this.api);
  final ApiClient api;
  Future<ConnectedDevice> register(AuthSessionScope scope,
      {required String deviceId,
      required String label,
      required String platform,
      required String writerSecret,
      CancelToken? cancelToken}) async {
    final response = await api.sessionRequest(scope, '/me/devices',
        method: 'POST',
        cancelToken: cancelToken,
        data: {
          'deviceId': deviceId,
          'label': label,
          'platform': platform,
          'writerSecret': writerSecret
        });
    _check(scope, response.statusCode, 201);
    return ConnectedDevice.fromJson(
        connectObject(connectObject(response.data)['device']));
  }

  Future<ConnectedDevice> report(AuthSessionScope scope,
      {required String deviceId,
      required String leaseId,
      required String writerSecret,
      required int sequence,
      required ConnectPlayback? playback,
      CancelToken? cancelToken}) async {
    final response = await api.sessionRequest(
        scope, '/me/devices/${Uri.encodeComponent(deviceId)}',
        method: 'PUT',
        cancelToken: cancelToken,
        data: {
          'leaseId': leaseId,
          'writerSecret': writerSecret,
          'sequence': sequence,
          'playback': playback?.toJson()
        });
    _check(scope, response.statusCode, 200);
    return ConnectedDevice.fromJson(
        connectObject(connectObject(response.data)['device']));
  }

  Future<ConnectedDevices> list(AuthSessionScope scope,
      {CancelToken? cancelToken}) async {
    final response = await api.sessionRequest(scope, '/me/devices',
        method: 'GET', cancelToken: cancelToken);
    _check(scope, response.statusCode, 200);
    return ConnectedDevices.fromJson(connectObject(response.data));
  }

  Future<void> remove(AuthSessionScope scope,
      {required String deviceId,
      required String leaseId,
      required String writerSecret,
      CancelToken? cancelToken}) async {
    final response = await api.sessionRequest(
        scope, '/me/devices/${Uri.encodeComponent(deviceId)}',
        method: 'DELETE',
        cancelToken: cancelToken,
        data: {'leaseId': leaseId, 'writerSecret': writerSecret});
    _check(scope, response.statusCode, 204);
  }

  void _check(AuthSessionScope scope, int? status, int expected) {
    if (!api.acceptsAuthSession(scope)) {
      throw StateError('Authentication session changed');
    }
    if (status != expected) {
      throw const FormatException('Unexpected Connect status');
    }
  }
}

String? connectErrorCode(Object error) {
  if (error is! DioException) return null;
  final data = error.response?.data;
  if (data is! Map) return null;
  final nested = data['error'];
  final code = nested is Map ? nested['code'] : data['code'];
  return code is String ? code : null;
}
