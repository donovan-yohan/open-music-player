/**
 * Error handling module for OpenMusicPlayer Chrome Extension
 */

/** Error categories matching the backend */
export type ErrorCategory = 'client' | 'server' | 'external' | 'network';

/** Error codes matching the backend */
export const ErrorCodes = {
  // Client errors
  VALIDATION_ERROR: 'VALIDATION_ERROR',
  INVALID_REQUEST: 'INVALID_REQUEST',
  UNAUTHORIZED: 'UNAUTHORIZED',
  FORBIDDEN: 'FORBIDDEN',
  NOT_FOUND: 'NOT_FOUND',
  CONFLICT: 'CONFLICT',
  RATE_LIMITED: 'RATE_LIMITED',

  // Auth specific
  INVALID_CREDENTIALS: 'INVALID_CREDENTIALS',
  INVALID_TOKEN: 'INVALID_TOKEN',
  TOKEN_EXPIRED: 'TOKEN_EXPIRED',
  EMAIL_EXISTS: 'EMAIL_EXISTS',

  // Server errors
  INTERNAL_ERROR: 'INTERNAL_ERROR',
  DATABASE_ERROR: 'DATABASE_ERROR',
  STORAGE_ERROR: 'STORAGE_ERROR',

  // External service errors
  MUSICBRAINZ_ERROR: 'MUSICBRAINZ_ERROR',
  DOWNLOAD_ERROR: 'DOWNLOAD_ERROR',
  EXTERNAL_TIMEOUT: 'EXTERNAL_TIMEOUT',

  // Network errors (client-side)
  NETWORK_ERROR: 'NETWORK_ERROR',
  OFFLINE: 'OFFLINE',
  TIMEOUT: 'TIMEOUT',
} as const;

export type ErrorCode = typeof ErrorCodes[keyof typeof ErrorCodes];

/** API error response format from backend */
export interface ApiErrorResponse {
  error: {
    code: string;
    message: string;
    request_id?: string;
    details?: Record<string, unknown>;
  };
}

/** Application error class */
export class AppError extends Error {
  code: ErrorCode | string;
  category: ErrorCategory;
  statusCode?: number;
  requestId?: string;
  details?: Record<string, unknown>;
  isRetryable: boolean;

  constructor(options: {
    code: ErrorCode | string;
    message: string;
    category?: ErrorCategory;
    statusCode?: number;
    requestId?: string;
    details?: Record<string, unknown>;
  }) {
    super(options.message);
    this.name = 'AppError';
    this.code = options.code;
    this.statusCode = options.statusCode;
    this.requestId = options.requestId;
    this.details = options.details;
    this.category = options.category ?? this.determineCategory();
    this.isRetryable = this.determineRetryable();
  }

  private determineCategory(): ErrorCategory {
    if (this.statusCode !== undefined) {
      if (this.statusCode >= 400 && this.statusCode < 500) return 'client';
      if (this.statusCode >= 500) return 'server';
      if (this.statusCode === 502 || this.statusCode === 503 || this.statusCode === 504) {
        return 'external';
      }
    }

    if (this.code === ErrorCodes.NETWORK_ERROR ||
        this.code === ErrorCodes.OFFLINE ||
        this.code === ErrorCodes.TIMEOUT) {
      return 'network';
    }

    return 'client';
  }

  private determineRetryable(): boolean {
    switch (this.category) {
      case 'network':
        return true;
      case 'external':
        return true;
      case 'server':
        return this.code !== ErrorCodes.DATABASE_ERROR;
      case 'client':
        return false;
      default:
        return false;
    }
  }

  /** Create from API response */
  static fromApiResponse(response: Response, body?: ApiErrorResponse): AppError {
    if (body?.error) {
      return new AppError({
        code: body.error.code as ErrorCode,
        message: body.error.message,
        statusCode: response.status,
        requestId: body.error.request_id,
        details: body.error.details,
      });
    }

    return new AppError({
      code: ErrorCodes.INTERNAL_ERROR,
      message: `API error: ${response.status}`,
      statusCode: response.status,
    });
  }

  /** Create a network error */
  static network(message?: string, originalError?: Error): AppError {
    return new AppError({
      code: ErrorCodes.NETWORK_ERROR,
      message: message ?? 'Network connection failed',
      category: 'network',
    });
  }

  /** Create an offline error */
  static offline(): AppError {
    return new AppError({
      code: ErrorCodes.OFFLINE,
      message: 'You appear to be offline',
      category: 'network',
    });
  }

  /** Create a timeout error */
  static timeout(service?: string): AppError {
    return new AppError({
      code: ErrorCodes.TIMEOUT,
      message: service ? `${service} request timed out` : 'Request timed out',
      category: 'network',
    });
  }

  /** Whether this is an auth error requiring re-login */
  get isAuthError(): boolean {
    return this.code === ErrorCodes.UNAUTHORIZED ||
           this.code === ErrorCodes.INVALID_TOKEN ||
           this.code === ErrorCodes.TOKEN_EXPIRED;
  }

  /** Get user-friendly display message */
  get displayMessage(): string {
    switch (this.code) {
      case ErrorCodes.NETWORK_ERROR:
      case ErrorCodes.OFFLINE:
        return 'Please check your internet connection and try again.';
      case ErrorCodes.TIMEOUT:
        return 'The request took too long. Please try again.';
      case ErrorCodes.UNAUTHORIZED:
      case ErrorCodes.INVALID_TOKEN:
      case ErrorCodes.TOKEN_EXPIRED:
        return 'Your session has expired. Please log in again.';
      case ErrorCodes.INVALID_CREDENTIALS:
        return 'Invalid email or password.';
      case ErrorCodes.EMAIL_EXISTS:
        return 'This email is already registered.';
      case ErrorCodes.RATE_LIMITED:
        return 'Too many requests. Please wait a moment and try again.';
      case ErrorCodes.MUSICBRAINZ_ERROR:
        return 'Music database is temporarily unavailable. Please try again.';
      case ErrorCodes.STORAGE_ERROR:
        return 'File storage error. Please try again.';
      default:
        if (this.category === 'server') {
          return 'Something went wrong on our end. Please try again.';
        }
        return this.message;
    }
  }
}

/** Convert any error to AppError */
export function toAppError(error: unknown): AppError {
  if (error instanceof AppError) {
    return error;
  }

  if (error instanceof TypeError) {
    // Usually indicates network error
    return AppError.network(error.message);
  }

  if (error instanceof Error) {
    return new AppError({
      code: ErrorCodes.INTERNAL_ERROR,
      message: error.message,
    });
  }

  return new AppError({
    code: ErrorCodes.INTERNAL_ERROR,
    message: String(error),
  });
}
