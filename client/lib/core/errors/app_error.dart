import 'dart:io';

/// Error categories matching the backend
enum ErrorCategory {
  client,
  server,
  external,
  network,
}

/// Base application error class
class AppError implements Exception {
  final String code;
  final String message;
  final String? requestId;
  final int? statusCode;
  final ErrorCategory category;
  final Map<String, dynamic>? details;
  final dynamic originalError;

  const AppError({
    required this.code,
    required this.message,
    this.requestId,
    this.statusCode,
    required this.category,
    this.details,
    this.originalError,
  });

  /// Create from API error response JSON
  factory AppError.fromApiResponse(Map<String, dynamic> json, int? statusCode) {
    final error = json['error'] as Map<String, dynamic>?;
    if (error != null) {
      return AppError(
        code: error['code'] as String? ?? 'UNKNOWN_ERROR',
        message: error['message'] as String? ?? 'An unknown error occurred',
        requestId: error['request_id'] as String?,
        statusCode: statusCode,
        category: _categoryFromStatusCode(statusCode),
        details: error['details'] as Map<String, dynamic>?,
      );
    }

    // Legacy format support
    return AppError(
      code: json['code'] as String? ?? 'UNKNOWN_ERROR',
      message: json['message'] as String? ?? 'An unknown error occurred',
      statusCode: statusCode,
      category: _categoryFromStatusCode(statusCode),
      details: json['details'] as Map<String, dynamic>?,
    );
  }

  /// Create a network error
  factory AppError.network({
    String? message,
    dynamic originalError,
  }) {
    return AppError(
      code: 'NETWORK_ERROR',
      message: message ?? 'Network connection failed',
      category: ErrorCategory.network,
      originalError: originalError,
    );
  }

  /// Create an offline error
  factory AppError.offline() {
    return const AppError(
      code: 'OFFLINE',
      message: 'You appear to be offline. Please check your internet connection.',
      category: ErrorCategory.network,
    );
  }

  /// Create a timeout error
  factory AppError.timeout({String? service}) {
    return AppError(
      code: 'TIMEOUT',
      message: service != null
          ? '$service request timed out. Please try again.'
          : 'Request timed out. Please try again.',
      category: ErrorCategory.network,
    );
  }

  /// Create an unknown error
  factory AppError.unknown({dynamic originalError}) {
    return AppError(
      code: 'UNKNOWN_ERROR',
      message: 'An unexpected error occurred. Please try again.',
      category: ErrorCategory.client,
      originalError: originalError,
    );
  }

  static ErrorCategory _categoryFromStatusCode(int? statusCode) {
    if (statusCode == null) return ErrorCategory.client;
    if (statusCode >= 400 && statusCode < 500) return ErrorCategory.client;
    if (statusCode >= 500 && statusCode < 600) return ErrorCategory.server;
    if (statusCode == 502 || statusCode == 503 || statusCode == 504) {
      return ErrorCategory.external;
    }
    return ErrorCategory.client;
  }

  /// Whether this error is retryable
  bool get isRetryable {
    switch (category) {
      case ErrorCategory.network:
        return true;
      case ErrorCategory.external:
        return true;
      case ErrorCategory.server:
        return code != 'DATABASE_ERROR';
      case ErrorCategory.client:
        return false;
    }
  }

  /// Whether this is an authentication error that requires re-login
  bool get isAuthError {
    return code == 'UNAUTHORIZED' ||
           code == 'INVALID_TOKEN' ||
           code == 'TOKEN_EXPIRED';
  }

  /// Whether this is a not found error
  bool get isNotFound {
    return statusCode == 404 ||
           code == 'NOT_FOUND' ||
           code.endsWith('_NOT_FOUND');
  }

  /// Whether this is a validation error
  bool get isValidationError {
    return code == 'VALIDATION_ERROR' || code == 'INVALID_REQUEST';
  }

  /// Whether this is a conflict error (e.g., duplicate)
  bool get isConflict {
    return statusCode == 409 || code == 'CONFLICT' || code == 'EMAIL_EXISTS';
  }

  /// User-friendly error message
  String get displayMessage {
    switch (code) {
      case 'NETWORK_ERROR':
      case 'OFFLINE':
        return 'Please check your internet connection and try again.';
      case 'TIMEOUT':
        return 'The request took too long. Please try again.';
      case 'UNAUTHORIZED':
      case 'INVALID_TOKEN':
      case 'TOKEN_EXPIRED':
        return 'Your session has expired. Please log in again.';
      case 'INVALID_CREDENTIALS':
        return 'Invalid email or password.';
      case 'VALIDATION_ERROR':
      case 'INVALID_REQUEST':
        return message; // Validation messages are usually user-friendly
      case 'EMAIL_EXISTS':
        return 'This email is already registered.';
      case 'NOT_FOUND':
      case 'TRACK_NOT_FOUND':
      case 'ARTIST_NOT_FOUND':
      case 'ALBUM_NOT_FOUND':
      case 'PLAYLIST_NOT_FOUND':
        return message;
      case 'RATE_LIMITED':
        return 'Too many requests. Please wait a moment and try again.';
      case 'MUSICBRAINZ_ERROR':
        return 'Music database is temporarily unavailable. Please try again.';
      case 'STORAGE_ERROR':
        return 'File storage error. Please try again.';
      default:
        if (category == ErrorCategory.server) {
          return 'Something went wrong on our end. Please try again.';
        }
        return message;
    }
  }

  @override
  String toString() {
    final buffer = StringBuffer('AppError: $message (code: $code');
    if (requestId != null) {
      buffer.write(', request_id: $requestId');
    }
    if (statusCode != null) {
      buffer.write(', status: $statusCode');
    }
    buffer.write(')');
    return buffer.toString();
  }
}

/// Extension to convert common exceptions to AppError
extension ExceptionToAppError on Object {
  AppError toAppError() {
    if (this is AppError) return this as AppError;

    if (this is SocketException) {
      return AppError.network(
        message: 'Could not connect to server',
        originalError: this,
      );
    }

    if (this is HttpException) {
      return AppError.network(
        message: 'Network request failed',
        originalError: this,
      );
    }

    return AppError.unknown(originalError: this);
  }
}
