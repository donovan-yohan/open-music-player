import { ApiClient, fetchApi } from '../src/utils/api';
import { endpoints } from '../src/endpoints';

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
    endpoints.apiBaseUrl + '/library',
    'authenticated requests should use the immutable API with one version prefix'
  );

  await fetchApi('/api/v1/search/recordings', { skipRetry: true });
  assertEqual(
    requests[1],
    endpoints.apiBaseUrl + '/search/recordings',
    'unauthenticated requests should use the same immutable API'
  );
}

void main().then(() => {
  console.log('API destination regression tests passed');
});
