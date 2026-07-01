import { AppError, type ApiErrorResponse, ErrorCodes, toAppError } from '../errors';
import {
  getAuthTokens,
  getRefreshToken,
  setAuthTokens,
  clearAuthTokens,
} from '../storage';

const API_BASE_URL = 'http://localhost:8080';
const DEFAULT_TIMEOUT = 30000; // 30 seconds
const MAX_RETRIES = 3;
const INITIAL_BACKOFF = 1000; // 1 second

/** Retry configuration */
interface RetryConfig {
  maxRetries: number;
  initialBackoff: number;
  maxBackoff: number;
}

const defaultRetryConfig: RetryConfig = {
  maxRetries: MAX_RETRIES,
  initialBackoff: INITIAL_BACKOFF,
  maxBackoff: 30000,
};

/** Calculate exponential backoff with jitter */
function calculateBackoff(attempt: number, config: RetryConfig): number {
  const backoff = Math.min(
    config.initialBackoff * Math.pow(2, attempt),
    config.maxBackoff
  );
  // Add jitter (±25%)
  const jitter = backoff * 0.25 * (Math.random() * 2 - 1);
  return Math.floor(backoff + jitter);
}

/** Check if error is retryable */
function isRetryable(error: unknown): boolean {
  if (error instanceof AppError) {
    return error.isRetryable;
  }
  // Network errors are typically retryable
  if (error instanceof TypeError) {
    return true;
  }
  return false;
}

/** Sleep for specified milliseconds */
function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/** Check if we're online */
function isOnline(): boolean {
  return navigator.onLine;
}

/** Fetch with timeout */
async function fetchWithTimeout(
  url: string,
  options: RequestInit,
  timeout: number
): Promise<Response> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeout);

  try {
    const response = await fetch(url, {
      ...options,
      signal: controller.signal,
    });
    return response;
  } finally {
    clearTimeout(timeoutId);
  }
}

/**
 * Raw fetch with the same exponential-backoff retry policy as {@link fetchApi}
 * (retries 5xx/429 and network failures) but returns the {@link Response}
 * untouched instead of parsing/throwing. Lets callers inspect status codes and
 * response bodies for their own error handling (e.g. 401 refresh, 409 dedup).
 */
export async function fetchWithRetry(
  url: string,
  options: RequestInit,
  maxRetries: number = MAX_RETRIES
): Promise<Response> {
  let lastError: Error | null = null;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const response = await fetchWithTimeout(url, options, DEFAULT_TIMEOUT);

      // Don't retry client errors (4xx except 429).
      if (response.status >= 400 && response.status < 500 && response.status !== 429) {
        return response;
      }

      // Retry server errors (5xx) and rate limiting (429).
      if (response.status >= 500 || response.status === 429) {
        lastError = new Error(`Server error: ${response.status}`);
        if (attempt < maxRetries) {
          await sleep(calculateBackoff(attempt, defaultRetryConfig));
          continue;
        }
      }

      return response;
    } catch (err) {
      if (err instanceof DOMException && err.name === 'AbortError') {
        lastError = new Error('Request timed out');
      } else {
        lastError = err instanceof Error ? err : new Error(String(err));
      }

      if (attempt < maxRetries) {
        await sleep(calculateBackoff(attempt, defaultRetryConfig));
        continue;
      }
    }
  }

  throw lastError ?? new Error('Request failed after all retries');
}

/** Enhanced API fetch with retry logic and proper error handling */
export async function fetchApi<T>(
  endpoint: string,
  options?: RequestInit & {
    timeout?: number;
    retryConfig?: Partial<RetryConfig>;
    skipRetry?: boolean;
  }
): Promise<T> {
  // Check offline status
  if (!isOnline()) {
    throw AppError.offline();
  }

  const {
    timeout = DEFAULT_TIMEOUT,
    retryConfig: customRetryConfig,
    skipRetry = false,
    ...fetchOptions
  } = options ?? {};

  const config = { ...defaultRetryConfig, ...customRetryConfig };
  const maxAttempts = skipRetry ? 1 : config.maxRetries + 1;
  let lastError: unknown;

  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      const response = await fetchWithTimeout(
        `${API_BASE_URL}${endpoint}`,
        {
          ...fetchOptions,
          headers: {
            'Content-Type': 'application/json',
            ...fetchOptions.headers,
          },
        },
        timeout
      );

      if (!response.ok) {
        let errorBody: ApiErrorResponse | undefined;
        try {
          errorBody = await response.json();
        } catch {
          // Couldn't parse error body
        }

        const error = AppError.fromApiResponse(response, errorBody);

        // Don't retry client errors (4xx except 429)
        if (!error.isRetryable || skipRetry) {
          throw error;
        }

        // Retry server errors
        lastError = error;
        if (attempt < maxAttempts - 1) {
          const backoff = calculateBackoff(attempt, config);
          console.log(`Retrying request to ${endpoint} in ${backoff}ms (attempt ${attempt + 1}/${maxAttempts})`);
          await sleep(backoff);
          continue;
        }
      }

      // Success - parse response
      if (response.status === 204) {
        return undefined as T;
      }

      return await response.json();
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') {
        lastError = AppError.timeout();
      } else if (error instanceof AppError) {
        lastError = error;
        if (!error.isRetryable || skipRetry) {
          throw error;
        }
      } else {
        // Network error
        lastError = toAppError(error);
      }

      // Retry on retryable errors
      if (isRetryable(lastError) && !skipRetry && attempt < maxAttempts - 1) {
        const backoff = calculateBackoff(attempt, config);
        console.log(`Retrying request to ${endpoint} in ${backoff}ms (attempt ${attempt + 1}/${maxAttempts})`);
        await sleep(backoff);
        continue;
      }
    }
  }

  // All retries exhausted
  throw lastError ?? AppError.network('Request failed after all retries');
}

/** Send message to extension background script */
export function sendMessage<T>(message: unknown): Promise<T> {
  return new Promise((resolve, reject) => {
    chrome.runtime.sendMessage(message, (response: T) => {
      if (chrome.runtime.lastError) {
        reject(new AppError({
          code: ErrorCodes.INTERNAL_ERROR,
          message: chrome.runtime.lastError.message ?? 'Extension communication error',
        }));
      } else {
        resolve(response);
      }
    });
  });
}

/** Refresh endpoint (relative to {@link API_BASE_URL}). */
const AUTH_REFRESH_ENDPOINT = '/api/v1/auth/refresh';
/** Default access-token lifetime (seconds) when the backend omits expiresIn. */
const DEFAULT_ACCESS_TOKEN_TTL_SECONDS = 15 * 60;

/** Shape of the backend auth response (login/register/refresh). */
interface AuthTokenResponse {
  accessToken: string;
  refreshToken: string;
  expiresIn?: number;
}

/**
 * Single source of truth for authenticated requests across the extension.
 *
 * Loads tokens from {@link module:storage}, attaches the access token, and on a
 * 401 automatically calls the refresh endpoint (rotating tokens), persists the
 * rotated pair, and retries the original request exactly once. Concurrent 401s
 * coalesce onto a single in-flight refresh so the rotated refresh token is only
 * spent once.
 */
export class ApiClient {
  private refreshInFlight: Promise<string | null> | null = null;

  private async getAccessToken(): Promise<string | null> {
    return (await getAuthTokens())?.accessToken ?? null;
  }

  /** Coalesces concurrent refreshes onto one in-flight rotation. */
  private async refreshAccessToken(): Promise<string | null> {
    if (!this.refreshInFlight) {
      this.refreshInFlight = this.performRefresh().finally(() => {
        this.refreshInFlight = null;
      });
    }
    return this.refreshInFlight;
  }

  private async performRefresh(): Promise<string | null> {
    const refreshToken = await getRefreshToken();
    if (!refreshToken) {
      await clearAuthTokens();
      return null;
    }

    try {
      const response = await fetchWithTimeout(
        `${API_BASE_URL}${AUTH_REFRESH_ENDPOINT}`,
        {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ refreshToken }),
        },
        DEFAULT_TIMEOUT
      );

      if (!response.ok) {
        await clearAuthTokens();
        return null;
      }

      const data = (await response.json()) as AuthTokenResponse;
      await setAuthTokens({
        accessToken: data.accessToken,
        refreshToken: data.refreshToken,
        expiresAt:
          Date.now() +
          (data.expiresIn ?? DEFAULT_ACCESS_TOKEN_TTL_SECONDS) * 1000,
      });
      return data.accessToken;
    } catch {
      await clearAuthTokens();
      return null;
    }
  }

  private buildInit(options: RequestInit, token: string | null): RequestInit {
    return {
      ...options,
      headers: {
        'Content-Type': 'application/json',
        ...(options.headers as Record<string, string> | undefined),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
    };
  }

  /**
   * Performs an authenticated request against `endpoint` (relative to the API
   * host) and returns the raw {@link Response}. Retries 5xx/429/network errors
   * with backoff and transparently refreshes-then-retries once on a 401.
   */
  async authorizedFetch(
    endpoint: string,
    options: RequestInit = {}
  ): Promise<Response> {
    const url = `${API_BASE_URL}${endpoint}`;
    const accessToken = await this.getAccessToken();
    let response = await fetchWithRetry(url, this.buildInit(options, accessToken));

    if (response.status === 401) {
      const refreshedToken = await this.refreshAccessToken();
      if (refreshedToken) {
        response = await fetchWithRetry(
          url,
          this.buildInit(options, refreshedToken)
        );
      }
    }

    return response;
  }

  private async requestJson<T>(
    endpoint: string,
    method: string,
    body?: unknown,
    options?: RequestInit
  ): Promise<T> {
    const response = await this.authorizedFetch(endpoint, {
      ...options,
      method,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });

    if (!response.ok) {
      let errorBody: ApiErrorResponse | undefined;
      try {
        errorBody = await response.json();
      } catch {
        // Couldn't parse error body
      }
      throw AppError.fromApiResponse(response, errorBody);
    }

    if (response.status === 204) {
      return undefined as T;
    }
    return (await response.json()) as T;
  }

  async get<T>(endpoint: string, options?: RequestInit): Promise<T> {
    return this.requestJson<T>(endpoint, 'GET', undefined, options);
  }

  async post<T>(endpoint: string, body?: unknown, options?: RequestInit): Promise<T> {
    return this.requestJson<T>(endpoint, 'POST', body, options);
  }

  async put<T>(endpoint: string, body?: unknown, options?: RequestInit): Promise<T> {
    return this.requestJson<T>(endpoint, 'PUT', body, options);
  }

  async delete<T>(endpoint: string, options?: RequestInit): Promise<T> {
    return this.requestJson<T>(endpoint, 'DELETE', undefined, options);
  }
}

export const apiClient = new ApiClient();
