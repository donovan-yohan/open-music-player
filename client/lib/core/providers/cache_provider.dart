import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'settings_provider.dart';

/// Cache info model
class CacheInfo {
  final int sizeInBytes;
  final bool isCalculating;

  const CacheInfo({this.sizeInBytes = 0, this.isCalculating = false});

  String get formattedSize {
    if (sizeInBytes < 1024) {
      return '$sizeInBytes B';
    } else if (sizeInBytes < 1024 * 1024) {
      return '${(sizeInBytes / 1024).toStringAsFixed(1)} KB';
    } else if (sizeInBytes < 1024 * 1024 * 1024) {
      return '${(sizeInBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(sizeInBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  CacheInfo copyWith({int? sizeInBytes, bool? isCalculating}) {
    return CacheInfo(
      sizeInBytes: sizeInBytes ?? this.sizeInBytes,
      isCalculating: isCalculating ?? this.isCalculating,
    );
  }
}

/// Cache notifier for managing cache state
class CacheNotifier extends StateNotifier<CacheInfo> {
  final SharedPreferences _prefs;

  CacheNotifier(this._prefs) : super(const CacheInfo()) {
    calculateCacheSize();
  }

  Future<void> calculateCacheSize() async {
    state = state.copyWith(isCalculating: true);

    try {
      // Get the app's cache directory size
      // This is a simplified implementation - in production you'd use path_provider
      final cacheSize = _prefs.getInt('estimated_cache_size') ?? 0;
      state = CacheInfo(sizeInBytes: cacheSize, isCalculating: false);
    } catch (_) {
      state = const CacheInfo(sizeInBytes: 0, isCalculating: false);
    }
  }

  Future<void> clearCache() async {
    state = state.copyWith(isCalculating: true);

    try {
      // Clear cached files
      // In production, this would clear actual cache directories
      await _prefs.setInt('estimated_cache_size', 0);

      // Simulate cache clearing delay
      await Future.delayed(const Duration(milliseconds: 500));

      state = const CacheInfo(sizeInBytes: 0, isCalculating: false);
    } catch (_) {
      state = state.copyWith(isCalculating: false);
    }
  }
}

/// Provider for cache info
final cacheProvider = StateNotifierProvider<CacheNotifier, CacheInfo>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return CacheNotifier(prefs);
});
