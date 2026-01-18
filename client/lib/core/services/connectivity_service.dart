import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

enum NetworkStatus { online, offline, wifiOnly }

class ConnectivityService {
  final Connectivity _connectivity = Connectivity();
  final _statusController = StreamController<NetworkStatus>.broadcast();

  NetworkStatus _currentStatus = NetworkStatus.online;
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  NetworkStatus get currentStatus => _currentStatus;
  Stream<NetworkStatus> get statusStream => _statusController.stream;
  bool get isOnline => _currentStatus != NetworkStatus.offline;
  bool get isOnWifi => _currentStatus == NetworkStatus.wifiOnly;

  Future<void> initialize() async {
    final results = await _connectivity.checkConnectivity();
    _updateStatus(results);

    _subscription = _connectivity.onConnectivityChanged.listen(_updateStatus);
  }

  void _updateStatus(List<ConnectivityResult> results) {
    NetworkStatus newStatus;

    if (results.contains(ConnectivityResult.none) || results.isEmpty) {
      newStatus = NetworkStatus.offline;
    } else if (results.contains(ConnectivityResult.wifi)) {
      newStatus = NetworkStatus.wifiOnly;
    } else {
      newStatus = NetworkStatus.online;
    }

    if (newStatus != _currentStatus) {
      _currentStatus = newStatus;
      _statusController.add(newStatus);
    }
  }

  Future<bool> checkConnectivity() async {
    final results = await _connectivity.checkConnectivity();
    _updateStatus(results);
    return isOnline;
  }

  void dispose() {
    _subscription?.cancel();
    _statusController.close();
  }
}
