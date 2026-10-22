import { ApiClient, fetchApi } from '../src/utils/api';
import { getApiBaseUrl } from '../src/storage';
import { DEFAULT_CONFIG } from '../src/types';

function assertEqual(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) {
    throw new Error(`${message}: expected ${String(expected)}, got ${String(actual)}`);
  }
}

async function main(): Promise<void> {
  (globalThis as unknown as { chrome: unknown }).chrome = {
    storage: {
      local: {
        get(_keys: string[], callback: (result: Record<string, unknown>) => void): void {
          callback({});
        },
      },
    },
  };
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: { onLine: true },
  });

  const requests: string[] = [];
  globalThis.fetch = async (input) => {
    requests.push(String(input));
    return new Response('{}', {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  };

  await new ApiClient().authorizedFetch('/api/v1/library');
  assertEqual(
    requests[0],
    'https://soundq.fish-rattlesnake.ts.net/api/v1/library',
    'authenticated requests should use the home-lab API with one version prefix'
  );

  await fetchApi('/api/v1/search/recordings', { skipRetry: true });
  assertEqual(
    requests[1],
    'https://soundq.fish-rattlesnake.ts.net/api/v1/search/recordings',
    'unauthenticated requests should use the home-lab API'
  );
  assertEqual(
    DEFAULT_CONFIG.API_BASE_URL,
    'https://soundq.fish-rattlesnake.ts.net',
    'host-relative API configuration should use the home-lab origin'
  );
  assertEqual(
    await getApiBaseUrl(),
    'wss://soundq.fish-rattlesnake.ts.net/api/v1',
    'WebSocket configuration should use secure home-lab transport'
  );
}

void main().then(() => {
  console.log('API destination regression tests passed');
});
