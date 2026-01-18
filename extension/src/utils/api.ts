import { AppError, type ApiErrorResponse, ErrorCodes, toAppError } from '../errors';

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

/** API client for authenticated requests */
export class ApiClient {
  private authToken: string | null = null;

  setAuthToken(token: string | null): void {
    this.authToken = token;
  }

  private getAuthHeaders(): Record<string, string> {
    if (!this.authToken) {
      return {};
    }
    return {
      Authorization: `Bearer ${this.authToken}`,
    };
  }

  async get<T>(endpoint: string, options?: Parameters<typeof fetchApi>[1]): Promise<T> {
    return fetchApi<T>(endpoint, {
      ...options,
      method: 'GET',
      headers: {
        ...this.getAuthHeaders(),
        ...options?.headers,
      },
    });
  }

  async post<T>(
    endpoint: string,
    body?: unknown,
    options?: Parameters<typeof fetchApi>[1]
  ): Promise<T> {
    return fetchApi<T>(endpoint, {
      ...options,
      method: 'POST',
      body: body ? JSON.stringify(body) : undefined,
      headers: {
        ...this.getAuthHeaders(),
        ...options?.headers,
      },
    });
  }

  async put<T>(
    endpoint: string,
    body?: unknown,
    options?: Parameters<typeof fetchApi>[1]
  ): Promise<T> {
    return fetchApi<T>(endpoint, {
      ...options,
      method: 'PUT',
      body: body ? JSON.stringify(body) : undefined,
      headers: {
        ...this.getAuthHeaders(),
        ...options?.headers,
      },
    });
  }

  async delete<T>(endpoint: string, options?: Parameters<typeof fetchApi>[1]): Promise<T> {
    return fetchApi<T>(endpoint, {
      ...options,
      method: 'DELETE',
      headers: {
        ...this.getAuthHeaders(),
        ...options?.headers,
      },
    });
  }
}

export const apiClient = new ApiClient();
