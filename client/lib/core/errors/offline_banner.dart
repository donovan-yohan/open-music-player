import 'package:flutter/material.dart';
import '../network/connectivity_service.dart';

/// Banner that shows when the device is offline
class OfflineBanner extends StatelessWidget {
  final ConnectivityService connectivity;
  final Widget child;
  final bool showBanner;

  const OfflineBanner({
    super.key,
    required this.connectivity,
    required this.child,
    this.showBanner = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: connectivity,
      builder: (context, _) {
        return Column(
          children: [
            if (connectivity.isOffline && showBanner)
              MaterialBanner(
                content: const Row(
                  children: [
                    Icon(Icons.wifi_off, size: 20),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'You\'re offline. Some features may be unavailable.',
                      ),
                    ),
                  ],
                ),
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
                actions: [
                  TextButton(
                    onPressed: () => connectivity.checkConnectivity(),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            Expanded(child: child),
          ],
        );
      },
    );
  }
}

/// Compact offline indicator for app bars
class OfflineIndicator extends StatelessWidget {
  final ConnectivityService connectivity;

  const OfflineIndicator({
    super.key,
    required this.connectivity,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: connectivity,
      builder: (context, _) {
        if (connectivity.isOnline) return const SizedBox.shrink();

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.wifi_off,
                size: 16,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
              const SizedBox(width: 4),
              Text(
                'Offline',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Mixin for screens that need offline awareness
mixin OfflineAwareMixin<T extends StatefulWidget> on State<T> {
  ConnectivityService get connectivity;

  /// Whether to show loading indicators when going online
  bool get showOnlineLoadingIndicator => true;

  /// Called when connectivity changes to online
  void onOnline() {}

  /// Called when connectivity changes to offline
  void onOffline() {}

  @override
  void initState() {
    super.initState();
    connectivity.addListener(_onConnectivityChanged);
  }

  @override
  void dispose() {
    connectivity.removeListener(_onConnectivityChanged);
    super.dispose();
  }

  void _onConnectivityChanged() {
    if (connectivity.isOnline) {
      onOnline();
    } else {
      onOffline();
    }
  }

  /// Check if operation can proceed (with optional UI feedback)
  bool canProceed({bool showError = true}) {
    if (connectivity.isOffline) {
      if (showError && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('You\'re offline. Please check your connection.'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }
    return true;
  }
}

/// Widget that shows different content based on connectivity
class OfflineAwareBuilder extends StatelessWidget {
  final ConnectivityService connectivity;
  final Widget Function(BuildContext context) onlineBuilder;
  final Widget Function(BuildContext context)? offlineBuilder;
  final bool showOfflineFallback;

  const OfflineAwareBuilder({
    super.key,
    required this.connectivity,
    required this.onlineBuilder,
    this.offlineBuilder,
    this.showOfflineFallback = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: connectivity,
      builder: (context, _) {
        if (connectivity.isOffline && showOfflineFallback) {
          if (offlineBuilder != null) {
            return offlineBuilder!(context);
          }
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.wifi_off, size: 48, color: Colors.grey),
                SizedBox(height: 16),
                Text(
                  'You\'re offline',
                  style: TextStyle(fontSize: 18),
                ),
                SizedBox(height: 8),
                Text(
                  'This feature requires an internet connection.',
                  style: TextStyle(color: Colors.grey),
                ),
              ],
            ),
          );
        }
        return onlineBuilder(context);
      },
    );
  }
}
