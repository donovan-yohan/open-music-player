// Build-time only. No runtime host switch can redirect an authenticated session.
function validateUrl(value, schemes = ['http:', 'https:']) {
  if (typeof value !== 'string' || !value || /[\s\\?#]/.test(value) ||
      !/^[a-z]+:\/\//.test(value)) throw new Error('Invalid explicit endpoint URL');
  const rawPath = value.replace(/^[a-z]+:\/\/[^/]+/, '');
  if (/\/\//.test(rawPath) || /%(?![0-9a-f]{2})/i.test(rawPath) ||
      /%(2f|5c|2e|0[0-9a-f]|1[0-9a-f]|7f)/i.test(rawPath) || rawPath.split('/').some(p => p === '.' || p === '..')) {
    throw new Error('Malformed endpoint path');
  }
  const url = new URL(value);
  if (!schemes.includes(url.protocol) || !url.hostname || url.hostname.includes('*') ||
      url.port === '0' || url.username || url.password ||
      /[@]|:$/.test(value.split('/')[2])) throw new Error('Invalid endpoint origin');
  return url.href;
}

function endpointBundle(env = {}) {
  const keys = ['OMP_API_BASE_URL', 'OMP_HEALTH_URL', 'OMP_WEB_LOGIN_URL', 'OMP_WS_URL'];
  const custom = keys.some(key => env[key] !== undefined);
  if (custom && keys.slice(0, 3).some(key => !env[key])) {
    throw new Error('Custom endpoints require OMP_API_BASE_URL, OMP_HEALTH_URL and OMP_WEB_LOGIN_URL');
  }
  return Object.freeze({
    apiBaseUrl: validateUrl(custom ? env.OMP_API_BASE_URL : 'http://localhost:8080/api/v1').replace(/\/$/, ''),
    healthUrl: validateUrl(custom ? env.OMP_HEALTH_URL : 'http://localhost:8080/health'),
    webLoginUrl: validateUrl(custom ? env.OMP_WEB_LOGIN_URL : 'http://localhost:8080/login'),
    wsUrl: env.OMP_WS_URL === undefined || env.OMP_WS_URL === '' ? null : validateUrl(env.OMP_WS_URL, ['ws:', 'wss:']),
  });
}

function hostPermissions(bundle) {
  return [...new Set([bundle.apiBaseUrl, bundle.healthUrl, bundle.webLoginUrl, bundle.wsUrl]
    .filter(Boolean).map(value => {
      const url = new URL(value);
      const scheme = url.protocol === 'wss:' ? 'https:' : url.protocol === 'ws:' ? 'http:' : url.protocol;
      return `${scheme}//${url.hostname}/*`;
    }))];
}

module.exports = { endpointBundle, hostPermissions, validateUrl };
