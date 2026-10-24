// Non-routable fixture URLs: no network calls leave this process.
const fixture = {
  apiBaseUrl: 'https://api.example.test:9443/music/api/v1',
  healthUrl: 'https://probe.example.test:8443/ready',
  webLoginUrl: 'https://ui.example.test:7443/app/sign-in/',
  wsUrl: 'wss://api.example.test:9443/events',
};
Object.assign(globalThis, { __OMP_ENDPOINTS__: fixture });
const store: Record<string, unknown> = {};
const calls: string[] = [];
let listener: (message: { type: string }, sender: unknown, reply: (value: unknown) => void) => boolean;
Object.assign(globalThis, { chrome: {
  storage: { local: {
    get(keys: string[], callback: (value: unknown) => void) {
      callback(Object.fromEntries(keys.filter(k => k in store).map(k => [k, store[k]])));
    },
    set(values: Record<string, unknown>, callback: () => void) { Object.assign(store, values); callback(); },
    remove(keys: string | string[], callback: () => void) {
      for (const key of Array.isArray(keys) ? keys : [keys]) delete store[key]; callback();
    },
  } },
  runtime: { onInstalled: { addListener() {} }, onMessage: { addListener(fn: typeof listener) { listener = fn; } } },
  contextMenus: { onClicked: { addListener() {} } }, commands: { onCommand: { addListener() {} } },
} });
Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { onLine: true } });
function equal(actual: unknown, expected: unknown): void {
  if (actual !== expected) throw new Error(`expected ${String(expected)}, got ${String(actual)}`);
}
async function main(): Promise<void> {
  const { ApiClient, fetchApi } = await import('../src/utils/api');
  const { setAuthTokens, getAuthTokens } = await import('../src/storage');
  await setAuthTokens({ accessToken: 'old', refreshToken: 'refresh', expiresAt: 1 });
  let step = 0;
  globalThis.fetch = async (url, options) => {
    calls.push(String(url));
    step++;
    if (step === 1) { equal(new Headers(options?.headers).get('Authorization'), 'Bearer old'); return new Response('{}', { status: 401 }); }
    if (step === 2) return Response.json({ accessToken: 'new', refreshToken: 'rotated' });
    if (step === 3) equal(new Headers(options?.headers).get('Authorization'), 'Bearer new');
    return Response.json({});
  };
  await new ApiClient().authorizedFetch('/api/v1/library?limit=2');
  equal(calls[0], fixture.apiBaseUrl + '/library?limit=2');
  equal(calls[1], fixture.apiBaseUrl + '/auth/refresh');
  equal(calls[2], calls[0]);
  await fetchApi('/api/v1/tracks/7', { skipRetry: true });
  equal(calls[3], fixture.apiBaseUrl + '/tracks/7');
  await import('../src/background');
  await new Promise(resolve => listener({ type: 'CHECK_BACKEND' }, {}, resolve));
  equal(calls[4], fixture.healthUrl);
  // Persisted tokens from another build/host must never reach this endpoint.
  store.auth_endpoint = 'https://other.example.test/api/v1';
  equal(await getAuthTokens(), null);
  delete store.auth_endpoint;
  equal(await getAuthTokens(), null); // Custom bundles cannot adopt unbound legacy credentials.
  const elements = new Map<string, { addEventListener: (event: string, fn: () => void) => void; classList: { add(): void; remove(): void } }>();
  const events = new Map<string, () => void>();
  let initialize: () => Promise<void>;
  Object.assign(globalThis, {
    document: {
      getElementById(id: string) {
        if (!elements.has(id)) elements.set(id, {
          addEventListener(event: string, fn: () => void) { events.set(id + ':' + event, fn); },
          classList: { add() {}, remove() {} },
        });
        return elements.get(id);
      },
      addEventListener(_event: string, fn: typeof initialize) { initialize = fn; },
    },
    window: { addEventListener() {}, removeEventListener() {} },
  });
  Object.assign(chrome, { tabs: {
    create({ url }: { url: string }) { equal(url, fixture.webLoginUrl); },
    async query() { return []; },
  } });
  await import('../src/popup/popup');
  await initialize!();
  events.get('login-btn:click')!();
  console.log('endpoint runtime regression passed');
}
void main();
export {};
