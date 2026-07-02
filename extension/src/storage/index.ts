import type { AuthTokens } from '../types';

const STORAGE_KEYS = {
  AUTH_TOKENS: 'auth_tokens',
  USER_EMAIL: 'user_email',
  REFRESH_TOKEN: 'refresh_token',
  API_BASE_URL: 'api_base_url',
  NOTIFICATIONS_ENABLED: 'notifications_enabled',
} as const;

// Legacy key previously written by the background service worker, which stored
// only a bare access-token string. Kept so an already-signed-in user is
// migrated to the canonical `auth_tokens` shape instead of being logged out.
const LEGACY_AUTH_TOKEN_KEY = 'auth_token';

// Sentinel expiry for tokens whose real lifetime is unknown (legacy migrations
// and SET_AUTH_TOKEN, which only ever carried an access token). The unified
// ApiClient refreshes reactively on 401, so proactive expiry gating is not
// required for these to remain usable.
const UNKNOWN_TOKEN_EXPIRY = Number.MAX_SAFE_INTEGER;

const DEFAULT_API_BASE_URL = 'ws://localhost:8080/api/v1';

export async function getAuthTokens(): Promise<AuthTokens | null> {
  return new Promise((resolve) => {
    chrome.storage.local.get(
      [STORAGE_KEYS.AUTH_TOKENS, LEGACY_AUTH_TOKEN_KEY],
      (result) => {
        const tokens = result[STORAGE_KEYS.AUTH_TOKENS] as AuthTokens | undefined;
        if (tokens) {
          resolve(tokens);
          return;
        }

        // No canonical tokens: migrate a legacy bare access token if present so
        // existing sessions survive the storage-shape unification.
        const legacy = result[LEGACY_AUTH_TOKEN_KEY] as string | undefined;
        if (legacy) {
          const migrated: AuthTokens = {
            accessToken: legacy,
            refreshToken: '',
            expiresAt: UNKNOWN_TOKEN_EXPIRY,
          };
          chrome.storage.local.set(
            { [STORAGE_KEYS.AUTH_TOKENS]: migrated },
            () => {
              chrome.storage.local.remove(LEGACY_AUTH_TOKEN_KEY, () => {
                resolve(migrated);
              });
            }
          );
          return;
        }

        resolve(null);
      }
    );
  });
}

export async function setAuthTokens(tokens: AuthTokens): Promise<void> {
  return new Promise((resolve) => {
    chrome.storage.local.set({ [STORAGE_KEYS.AUTH_TOKENS]: tokens }, () => {
      resolve();
    });
  });
}

/**
 * Persists a bare access token into the canonical `auth_tokens` shape,
 * preserving any existing refresh token. Backs the legacy SET_AUTH_TOKEN
 * message which only ever carried an access token.
 */
export async function saveAccessToken(accessToken: string): Promise<void> {
  const existing = await getAuthTokens();
  await setAuthTokens({
    accessToken,
    refreshToken: existing?.refreshToken ?? '',
    expiresAt: UNKNOWN_TOKEN_EXPIRY,
  });
}

export async function clearAuthTokens(): Promise<void> {
  return new Promise((resolve) => {
    chrome.storage.local.remove(
      [
        STORAGE_KEYS.AUTH_TOKENS,
        STORAGE_KEYS.USER_EMAIL,
        STORAGE_KEYS.REFRESH_TOKEN,
        LEGACY_AUTH_TOKEN_KEY,
      ],
      () => {
        resolve();
      }
    );
  });
}

export async function getRefreshToken(): Promise<string | null> {
  const tokens = await getAuthTokens();
  return tokens?.refreshToken || null;
}

export async function getUserEmail(): Promise<string | null> {
  return new Promise((resolve) => {
    chrome.storage.local.get([STORAGE_KEYS.USER_EMAIL], (result) => {
      resolve((result[STORAGE_KEYS.USER_EMAIL] as string) || null);
    });
  });
}

export async function setUserEmail(email: string): Promise<void> {
  return new Promise((resolve) => {
    chrome.storage.local.set({ [STORAGE_KEYS.USER_EMAIL]: email }, () => {
      resolve();
    });
  });
}

export async function getAccessToken(): Promise<string | null> {
  const tokens = await getAuthTokens();
  return tokens?.accessToken || null;
}

export async function getApiBaseUrl(): Promise<string> {
  return new Promise((resolve) => {
    chrome.storage.local.get([STORAGE_KEYS.API_BASE_URL], (result) => {
      resolve((result[STORAGE_KEYS.API_BASE_URL] as string) || DEFAULT_API_BASE_URL);
    });
  });
}

export async function setApiBaseUrl(url: string): Promise<void> {
  return new Promise((resolve) => {
    chrome.storage.local.set({ [STORAGE_KEYS.API_BASE_URL]: url }, () => {
      resolve();
    });
  });
}

export async function getNotificationsEnabled(): Promise<boolean> {
  return new Promise((resolve) => {
    chrome.storage.local.get([STORAGE_KEYS.NOTIFICATIONS_ENABLED], (result) => {
      // Default to true if not set
      const enabled = result[STORAGE_KEYS.NOTIFICATIONS_ENABLED];
      resolve(enabled !== false);
    });
  });
}

export async function setNotificationsEnabled(enabled: boolean): Promise<void> {
  return new Promise((resolve) => {
    chrome.storage.local.set({ [STORAGE_KEYS.NOTIFICATIONS_ENABLED]: enabled }, () => {
      resolve();
    });
  });
}
