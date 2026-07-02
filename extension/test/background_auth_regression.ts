import { getAuthTokens } from '../src/storage';
import { ErrorCodes } from '../src/errors';
import type { AuthTokens } from '../src/types';

type StorageValues = Record<string, unknown>;
type SendResponse = (response: unknown) => void;
type RuntimeMessage = { type: string; [key: string]: unknown };
type RuntimeListener = (
  message: RuntimeMessage,
  sender: unknown,
  sendResponse: SendResponse
) => boolean;

const store: StorageValues = {};
let runtimeListener: RuntimeListener | null = null;

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

function installChromeMocks(): void {
  (globalThis as unknown as { chrome: unknown }).chrome = {
    runtime: {
      lastError: undefined,
      onInstalled: { addListener(): void {} },
      onMessage: {
        addListener(listener: RuntimeListener): void {
          runtimeListener = listener;
        },
      },
    },
    contextMenus: {
      create(): void {},
      onClicked: { addListener(): void {} },
    },
    commands: { onCommand: { addListener(): void {} } },
    tabs: {
      query(): void {},
      sendMessage(): void {},
    },
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

function installNavigatorOnline(): void {
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: { onLine: true },
  });
}

function installStableClock(): void {
  Date.now = () => 1;
}

function resetTokens(): void {
  for (const key of Object.keys(store)) {
    delete store[key];
  }
  store.auth_tokens = {
    accessToken: 'expired-access-token',
    refreshToken: 'valid-refresh-token',
    expiresAt: Date.now() - 60_000,
  } satisfies AuthTokens;
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

function expiredAccessResponse(): Response {
  return jsonResponse(
    { error: { code: ErrorCodes.TOKEN_EXPIRED, message: 'expired access token' } },
    401
  );
}

function transientRefreshResponse(): Response {
  return jsonResponse(
    { error: { code: ErrorCodes.INTERNAL_ERROR, message: 'temporarily unavailable' } },
    503
  );
}

function refreshRejectedResponse(): Response {
  return jsonResponse(
    { error: { code: ErrorCodes.INVALID_TOKEN, message: 'revoked refresh token' } },
    401
  );
}

async function sendBackgroundMessage<T>(message: RuntimeMessage): Promise<T> {
  assert(runtimeListener, 'background runtime listener should be registered');

  return new Promise((resolve) => {
    const keepsPortOpen = runtimeListener?.(message, {}, (response) => {
      resolve(response as T);
    });
    assertEqual(keepsPortOpen, true, `${message.type} should be handled asynchronously`);
  });
}

async function assertTokensPreserved(flow: string): Promise<void> {
  const tokens = await getAuthTokens();
  assert(tokens, `${flow} should preserve tokens after transient refresh failure`);
  assertEqual(
    tokens.refreshToken,
    'valid-refresh-token',
    `${flow} should keep the refresh token after transient refresh failure`
  );
}

async function addToLibraryTransientRefreshKeepsTokens(): Promise<void> {
  resetTokens();
  installFetch([
    expiredAccessResponse(),
    transientRefreshResponse(),
  ]);

  const result = await sendBackgroundMessage<{ success: boolean; error?: string }>({
    type: 'ADD_TO_LIBRARY',
    url: 'https://www.youtube.com/watch?v=test',
    sourceType: 'youtube',
    metadata: { title: 'test video' },
  });

  assertEqual(result.success, false, 'ADD_TO_LIBRARY should fail when refresh is transiently unavailable');
  assert(result.error !== 'not_logged_in', 'ADD_TO_LIBRARY should not report not_logged_in for refresh 5xx');
  await assertTokensPreserved('ADD_TO_LIBRARY');
}

async function updateMetadataTransientRefreshKeepsTokens(): Promise<void> {
  resetTokens();
  installFetch([expiredAccessResponse(), transientRefreshResponse()]);

  const result = await sendBackgroundMessage<{ success: boolean; error?: string }>({
    type: 'UPDATE_METADATA',
    trackId: 'track-1',
    metadata: { title: 'new title', artist: 'artist' },
  });

  assertEqual(result.success, false, 'UPDATE_METADATA should fail when refresh is transiently unavailable');
  assert(result.error !== 'not_logged_in', 'UPDATE_METADATA should not report not_logged_in for refresh 5xx');
  await assertTokensPreserved('UPDATE_METADATA');
}

async function mergeTracksTransientRefreshKeepsTokens(): Promise<void> {
  resetTokens();
  installFetch([expiredAccessResponse(), transientRefreshResponse()]);

  const result = await sendBackgroundMessage<{ success: boolean; error?: string }>({
    type: 'MERGE_TRACKS',
    sourceTrackId: 'source-track',
    targetTrackId: 'target-track',
  });

  assertEqual(result.success, false, 'MERGE_TRACKS should fail when refresh is transiently unavailable');
  assert(result.error !== 'not_logged_in', 'MERGE_TRACKS should not report not_logged_in for refresh 5xx');
  await assertTokensPreserved('MERGE_TRACKS');
}

async function explicitRefreshRejectionStillClearsTokens(): Promise<void> {
  resetTokens();
  installFetch([expiredAccessResponse(), refreshRejectedResponse()]);

  const result = await sendBackgroundMessage<{ success: boolean; error?: string }>({
    type: 'ADD_TO_LIBRARY',
    url: 'https://www.youtube.com/watch?v=test',
    sourceType: 'youtube',
    metadata: { title: 'test video' },
  });

  assertEqual(result.success, false, 'ADD_TO_LIBRARY should fail after rejected refresh token');
  assertEqual(result.error, 'not_logged_in', 'rejected refresh token should report not_logged_in');
  assertEqual(await getAuthTokens(), null, 'rejected refresh token should clear tokens');
}

async function main(): Promise<void> {
  installChromeMocks();
  installNavigatorOnline();
  installStableClock();
  await import('../src/background');

  await addToLibraryTransientRefreshKeepsTokens();
  await updateMetadataTransientRefreshKeepsTokens();
  await mergeTracksTransientRefreshKeepsTokens();
  await explicitRefreshRejectionStillClearsTokens();
}

void main().then(() => {
  console.log('background auth regression tests passed');
});
