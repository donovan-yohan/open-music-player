import { ApiClient } from '../src/utils/api';
import { getAuthTokens, getRefreshToken } from '../src/storage';
import type { AuthTokens } from '../src/types';

type StorageValues = Record<string, unknown>;

const store: StorageValues = {};

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

function assertEqual<T>(actual: T, expected: T, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${String(expected)}, got ${String(actual)}`);
  }
}

function installChromeStorage(): void {
  (globalThis as unknown as { chrome: unknown }).chrome = {
    storage: {
      local: {
        get(keys: string[], callback: (result: StorageValues) => void): void {
          const result: StorageValues = {};
          for (const key of keys) {
            if (Object.prototype.hasOwnProperty.call(store, key)) {
              result[key] = store[key];
            }
          }
          callback(result);
        },
        set(values: StorageValues, callback?: () => void): void {
          Object.assign(store, values);
          callback?.();
        },
        remove(keys: string | string[], callback?: () => void): void {
          const list = Array.isArray(keys) ? keys : [keys];
          for (const key of list) {
            delete store[key];
          }
          callback?.();
        },
      },
    },
  };
}

function resetTokens(tokens: AuthTokens): void {
  for (const key of Object.keys(store)) {
    delete store[key];
  }
  store.auth_tokens = tokens;
}

function installNavigatorOnline(): void {
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: { onLine: true },
  });
}

function installFetch(replies: Array<Response | Error>): void {
  let call = 0;
  (globalThis as unknown as { fetch: typeof fetch }).fetch = async () => {
    const reply = replies[call++];
    if (!reply) {
      throw new Error(`unexpected fetch call ${call}`);
    }
    if (reply instanceof Error) {
      throw reply;
    }
    return reply;
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

async function expiredCanonicalTokensRemainReadableForRefresh(): Promise<void> {
  resetTokens({
    accessToken: 'expired-access-token',
    refreshToken: 'valid-refresh-token',
    expiresAt: Date.now() - 60_000,
  });

  const tokens = await getAuthTokens();
  assert(tokens, 'expired canonical tokens should still be readable');
  assertEqual(tokens.refreshToken, 'valid-refresh-token', 'refresh token should be readable');
  assertEqual(await getRefreshToken(), 'valid-refresh-token', 'getRefreshToken should not depend on access-token freshness');
}

async function refreshServerFailurePreservesTokens(): Promise<void> {
  resetTokens({
    accessToken: 'expired-access-token',
    refreshToken: 'valid-refresh-token',
    expiresAt: Date.now() - 60_000,
  });
  installFetch([
    jsonResponse({ error: { message: 'expired' } }, 401),
    jsonResponse({ error: { message: 'temporarily unavailable' } }, 503),
  ]);

  await new ApiClient().authorizedFetch('/api/v1/library');

  const tokens = await getAuthTokens();
  assert(tokens, 'tokens should be preserved after refresh 5xx');
  assertEqual(tokens.refreshToken, 'valid-refresh-token', 'refresh 5xx should not clear refresh token');
}

async function refreshNetworkFailurePreservesTokens(): Promise<void> {
  resetTokens({
    accessToken: 'expired-access-token',
    refreshToken: 'valid-refresh-token',
    expiresAt: Date.now() - 60_000,
  });
  installFetch([
    jsonResponse({ error: { message: 'expired' } }, 401),
    new TypeError('offline'),
  ]);

  await new ApiClient().authorizedFetch('/api/v1/library');

  const tokens = await getAuthTokens();
  assert(tokens, 'tokens should be preserved after refresh network failure');
  assertEqual(tokens.refreshToken, 'valid-refresh-token', 'refresh network failure should not clear refresh token');
}

async function refreshClientRejectionClearsTokens(): Promise<void> {
  resetTokens({
    accessToken: 'expired-access-token',
    refreshToken: 'revoked-refresh-token',
    expiresAt: Date.now() - 60_000,
  });
  installFetch([
    jsonResponse({ error: { message: 'expired' } }, 401),
    jsonResponse({ error: { message: 'revoked' } }, 401),
  ]);

  await new ApiClient().authorizedFetch('/api/v1/library');

  assertEqual(await getAuthTokens(), null, 'refresh 401 should clear tokens');
}

async function main(): Promise<void> {
  installChromeStorage();
  installNavigatorOnline();

  await expiredCanonicalTokensRemainReadableForRefresh();
  await refreshServerFailurePreservesTokens();
  await refreshNetworkFailurePreservesTokens();
  await refreshClientRejectionClearsTokens();
}

void main().then(() => {
  console.log('auth refresh regression tests passed');
});
