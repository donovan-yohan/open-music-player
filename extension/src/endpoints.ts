export interface EndpointBundle {
  readonly apiBaseUrl: string;
  readonly healthUrl: string;
  readonly webLoginUrl: string;
  readonly wsUrl: string | null;
}

declare const __OMP_ENDPOINTS__: EndpointBundle;

// Webpack always injects a validated bundle. The fallback is for unbundled
// unit tests only; it preserves the known local development contract.
export const endpoints: EndpointBundle = Object.freeze(
  typeof __OMP_ENDPOINTS__ !== 'undefined' ? __OMP_ENDPOINTS__ : {
    apiBaseUrl: 'http://localhost:8080/api/v1',
    healthUrl: 'http://localhost:8080/health',
    webLoginUrl: 'http://localhost:8080/login',
    wsUrl: null,
  }
);

/** Existing extension callers pass /api/v1/...; retain that public contract. */
export function apiUrl(endpoint: string): string {
  if (!/^\/api\/v1(?:\/|\?|$)/.test(endpoint) || /[\\#\s]/.test(endpoint)) {
    throw new Error('Expected an /api/v1 API-relative endpoint');
  }
  return endpoints.apiBaseUrl + endpoint.slice('/api/v1'.length);
}
