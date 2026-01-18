import type { AuthTokens } from '../types';

const STORAGE_KEYS = {
  AUTH_TOKENS: 'auth_tokens',
  API_BASE_URL: 'api_base_url',
  NOTIFICATIONS_ENABLED: 'notifications_enabled',
} as const;

const DEFAULT_API_BASE_URL = 'ws://localhost:8080/api/v1';

export async function getAuthTokens(): Promise<AuthTokens | null> {
  return new Promise((resolve) => {
    chrome.storage.local.get([STORAGE_KEYS.AUTH_TOKENS], (result) => {
      const tokens = result[STORAGE_KEYS.AUTH_TOKENS] as AuthTokens | undefined;
      if (tokens && tokens.expiresAt > Date.now()) {
        resolve(tokens);
      } else {
        resolve(null);
      }
    });
  });
}

export async function setAuthTokens(tokens: AuthTokens): Promise<void> {
  return new Promise((resolve) => {
    chrome.storage.local.set({ [STORAGE_KEYS.AUTH_TOKENS]: tokens }, () => {
      resolve();
    });
  });
}

export async function clearAuthTokens(): Promise<void> {
  return new Promise((resolve) => {
    chrome.storage.local.remove([STORAGE_KEYS.AUTH_TOKENS], () => {
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
