import 'dart:async';
import 'package:flutter/material.dart';
import 'app_error.dart';

/// Callback signature for error handlers
typedef ErrorCallback = void Function(AppError error);

/// Global error handler service
class ErrorHandler {
  static final ErrorHandler _instance = ErrorHandler._internal();
  factory ErrorHandler() => _instance;
  ErrorHandler._internal();

  final _errorController = StreamController<AppError>.broadcast();

  /// Stream of errors for global listening
  Stream<AppError> get errors => _errorController.stream;

  /// Callbacks for specific error types
  ErrorCallback? onAuthError;
  ErrorCallback? onNetworkError;

  /// Handle an error, optionally showing UI feedback
  void handle(
    Object error, {
    BuildContext? context,
    bool showSnackbar = true,
    bool showDialog = false,
    VoidCallback? onRetry,
  }) {
    final appError = error is AppError ? error : error.toAppError();

    // Emit to stream for global listeners
    _errorController.add(appError);

    // Handle auth errors
    if (appError.isAuthError && onAuthError != null) {
      onAuthError!(appError);
      return;
    }

    // Handle network errors
    if (appError.category == ErrorCategory.network && onNetworkError != null) {
      onNetworkError!(appError);
    }

    // Show UI feedback if context is available
    if (context != null && context.mounted) {
      if (showDialog) {
        _showErrorDialog(context, appError, onRetry: onRetry);
      } else if (showSnackbar) {
        _showErrorSnackbar(context, appError, onRetry: onRetry);
      }
    }
  }

  /// Show error as a snackbar
  void _showErrorSnackbar(
    BuildContext context,
    AppError error, {
    VoidCallback? onRetry,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error.displayMessage),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        action: error.isRetryable && onRetry != null
            ? SnackBarAction(
                label: 'Retry',
                onPressed: onRetry,
              )
            : null,
      ),
    );
  }

  /// Show error as a dialog
  void _showErrorDialog(
    BuildContext context,
    AppError error, {
    VoidCallback? onRetry,
  }) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(error.displayMessage),
        actions: [
          if (error.isRetryable && onRetry != null)
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
                onRetry();
              },
              child: const Text('Retry'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Wrap an async operation with error handling
  Future<T?> wrap<T>(
    Future<T> Function() operation, {
    BuildContext? context,
    bool showSnackbar = true,
    VoidCallback? onRetry,
    T? fallback,
  }) async {
    try {
      return await operation();
    } catch (e) {
      handle(
        e,
        context: context,
        showSnackbar: showSnackbar,
        onRetry: onRetry,
      );
      return fallback;
    }
  }

  /// Dispose resources
  void dispose() {
    _errorController.close();
  }
}

/// Extension to provide easy error handling on BuildContext
extension ErrorHandlerExtension on BuildContext {
  /// Show an error snackbar
  void showError(
    Object error, {
    VoidCallback? onRetry,
  }) {
    ErrorHandler().handle(
      error,
      context: this,
      showSnackbar: true,
      onRetry: onRetry,
    );
  }

  /// Show an error dialog
  void showErrorDialog(
    Object error, {
    VoidCallback? onRetry,
  }) {
    ErrorHandler().handle(
      error,
      context: this,
      showDialog: true,
      onRetry: onRetry,
    );
  }
}
