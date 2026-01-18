/// Error handling library for the OpenMusicPlayer Flutter client.
///
/// This library provides:
/// - [AppError] - Structured error class matching backend error format
/// - [ErrorHandler] - Global error handling service
/// - [ErrorView] - Full-screen error display widget
/// - [InlineError] - Inline error display widget
/// - [RetryButton] - Button with loading state for retry operations
/// - [AsyncResult] - Wrapper for handling async loading/error/data states
/// - [OfflineBanner] - Banner showing when device is offline
/// - [OfflineIndicator] - Compact offline indicator for app bars
library errors;

export 'app_error.dart';
export 'error_handler.dart';
export 'error_widgets.dart';
export 'offline_banner.dart';
