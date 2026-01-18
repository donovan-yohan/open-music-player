import 'package:flutter/material.dart';
import 'app_error.dart';

/// A full-screen error display with retry option
class ErrorView extends StatelessWidget {
  final AppError? error;
  final String? title;
  final String? message;
  final VoidCallback? onRetry;
  final Widget? icon;

  const ErrorView({
    super.key,
    this.error,
    this.title,
    this.message,
    this.onRetry,
    this.icon,
  });

  /// Create an offline error view
  factory ErrorView.offline({VoidCallback? onRetry}) {
    return ErrorView(
      error: AppError.offline(),
      title: 'No Connection',
      icon: const Icon(
        Icons.wifi_off,
        size: 64,
        color: Colors.grey,
      ),
      onRetry: onRetry,
    );
  }

  /// Create a generic error view
  factory ErrorView.generic({
    String? message,
    VoidCallback? onRetry,
  }) {
    return ErrorView(
      title: 'Something went wrong',
      message: message ?? 'An unexpected error occurred. Please try again.',
      icon: const Icon(
        Icons.error_outline,
        size: 64,
        color: Colors.grey,
      ),
      onRetry: onRetry,
    );
  }

  /// Create an empty state view
  factory ErrorView.empty({
    String? title,
    String? message,
    VoidCallback? onAction,
    String? actionLabel,
  }) {
    return ErrorView(
      title: title ?? 'Nothing here',
      message: message ?? 'No items found.',
      icon: const Icon(
        Icons.inbox,
        size: 64,
        color: Colors.grey,
      ),
      onRetry: onAction,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayTitle = title ?? _getTitle();
    final displayMessage = message ?? error?.displayMessage ?? 'An error occurred';
    final showRetry = error?.isRetryable ?? true;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            icon ??
                Icon(
                  _getIcon(),
                  size: 64,
                  color: theme.colorScheme.outline,
                ),
            const SizedBox(height: 16),
            Text(
              displayTitle,
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              displayMessage,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (showRetry && onRetry != null) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getTitle() {
    if (error == null) return 'Error';

    switch (error!.category) {
      case ErrorCategory.network:
        return error!.code == 'OFFLINE' ? 'No Connection' : 'Connection Error';
      case ErrorCategory.server:
        return 'Server Error';
      case ErrorCategory.external:
        return 'Service Unavailable';
      case ErrorCategory.client:
        return error!.isAuthError ? 'Session Expired' : 'Error';
    }
  }

  IconData _getIcon() {
    if (error == null) return Icons.error_outline;

    switch (error!.category) {
      case ErrorCategory.network:
        return error!.code == 'OFFLINE' ? Icons.wifi_off : Icons.cloud_off;
      case ErrorCategory.server:
        return Icons.dns;
      case ErrorCategory.external:
        return Icons.cloud_off;
      case ErrorCategory.client:
        return error!.isAuthError ? Icons.lock_outline : Icons.error_outline;
    }
  }
}

/// Inline error display with retry button
class InlineError extends StatelessWidget {
  final AppError? error;
  final String? message;
  final VoidCallback? onRetry;

  const InlineError({
    super.key,
    this.error,
    this.message,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayMessage = message ?? error?.displayMessage ?? 'An error occurred';
    final showRetry = error?.isRetryable ?? true;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            Icons.error_outline,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              displayMessage,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
          if (showRetry && onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}

/// A retry button with loading state
class RetryButton extends StatefulWidget {
  final Future<void> Function() onRetry;
  final String? label;
  final bool compact;

  const RetryButton({
    super.key,
    required this.onRetry,
    this.label,
    this.compact = false,
  });

  @override
  State<RetryButton> createState() => _RetryButtonState();
}

class _RetryButtonState extends State<RetryButton> {
  bool _loading = false;

  Future<void> _handleRetry() async {
    if (_loading) return;

    setState(() => _loading = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact) {
      return IconButton(
        onPressed: _loading ? null : _handleRetry,
        icon: _loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.refresh),
      );
    }

    return FilledButton.icon(
      onPressed: _loading ? null : _handleRetry,
      icon: _loading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh),
      label: Text(widget.label ?? 'Retry'),
    );
  }
}

/// AsyncValue-like wrapper for handling loading/error/data states
class AsyncResult<T> {
  final T? data;
  final AppError? error;
  final bool isLoading;

  const AsyncResult._({
    this.data,
    this.error,
    this.isLoading = false,
  });

  factory AsyncResult.loading() => const AsyncResult._(isLoading: true);

  factory AsyncResult.data(T data) => AsyncResult._(data: data);

  factory AsyncResult.error(AppError error) => AsyncResult._(error: error);

  bool get hasData => data != null;
  bool get hasError => error != null;

  /// Map over the result states
  R when<R>({
    required R Function() loading,
    required R Function(T data) data,
    required R Function(AppError error) error,
  }) {
    if (isLoading) return loading();
    if (hasError) return error(this.error!);
    return data(this.data as T);
  }

  /// Build a widget based on the result state
  Widget build({
    required Widget Function() loading,
    required Widget Function(T data) data,
    required Widget Function(AppError error, VoidCallback? onRetry) error,
    VoidCallback? onRetry,
  }) {
    return when(
      loading: loading,
      data: data,
      error: (e) => error(e, onRetry),
    );
  }
}

/// Builder widget for async operations with automatic error handling
class AsyncBuilder<T> extends StatelessWidget {
  final AsyncResult<T> result;
  final Widget Function(T data) builder;
  final Widget Function()? loadingBuilder;
  final Widget Function(AppError error, VoidCallback? onRetry)? errorBuilder;
  final VoidCallback? onRetry;

  const AsyncBuilder({
    super.key,
    required this.result,
    required this.builder,
    this.loadingBuilder,
    this.errorBuilder,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return result.build(
      loading: loadingBuilder ?? () => const Center(child: CircularProgressIndicator()),
      data: builder,
      error: errorBuilder ??
          (error, retry) => ErrorView(
                error: error,
                onRetry: retry,
              ),
      onRetry: onRetry,
    );
  }
}
