import { AppError, ErrorCodes } from '../src/errors';
import { ApiClient, fetchApi } from '../src/utils/api';

declare function require(name: string): any;
const { test } = require('node:test');
const assert = require('node:assert/strict');

const response = new Response(null, { status: 400 });

test('flat download errors preserve backend code, message, request ID and details', () => {
  const error = AppError.fromApiResponse(response, JSON.parse(JSON.stringify({
    code: 'INVALID_URL', message: 'unsupported source URL',
    request_id: 'request-flat', details: { field: 'url' },
  })));
  assert.equal(error.code, 'INVALID_URL');
  assert.equal(error.message, 'unsupported source URL');
  assert.equal(error.statusCode, 400);
  assert.equal(error.requestId, 'request-flat');
  assert.deepEqual(error.details, { field: 'url' });
});

test('nested errors preserve backend code, message, request ID and details', () => {
  const error = AppError.fromApiResponse(response, { error: {
    code: 'INVALID_REQUEST', message: 'invalid request body',
    request_id: 'request-nested', details: { field: 'url' },
  } });
  assert.equal(error.code, 'INVALID_REQUEST');
  assert.equal(error.message, 'invalid request body');
  assert.equal(error.requestId, 'request-nested');
  assert.deepEqual(error.details, { field: 'url' });
});

test('legacy string errors preserve their message and flat code', () => {
  const error = AppError.fromApiResponse(response, JSON.parse(JSON.stringify({
    code: 'INVALID_URL', error: 'unsupported source URL',
  })));
  assert.equal(error.code, 'INVALID_URL');
  assert.equal(error.message, 'unsupported source URL');
});

test('malformed error JSON has a stable fallback instead of undefined fields', () => {
  for (const body of [null, [], 'bad request', { error: {} }, { code: 3, message: {} },
    { error: true }, { error: { code: 7, message: ['bad'] } }]) {
    const error = AppError.fromApiResponse(response, JSON.parse(JSON.stringify(body)));
    assert.equal(error.code, ErrorCodes.INTERNAL_ERROR);
    assert.equal(error.message, 'API error: 400');
  }
});

test('real ApiClient and fetchApi preserve flat backend error responses', async () => {
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true, value: { onLine: true },
  });
  (globalThis as unknown as { chrome: unknown }).chrome = {
    storage: { local: { get(_keys: string[], callback: (value: unknown) => void): void {
      callback({});
    } } },
  };
  globalThis.fetch = async () => new Response(JSON.stringify({
    code: 'INVALID_URL', message: 'unsupported source URL',
  }), { status: 400 });
  const isBackendError = (error: unknown) => error instanceof AppError &&
    error.code === 'INVALID_URL' && error.message === 'unsupported source URL';
  await assert.rejects(new ApiClient().post('/api/v1/downloads', {}), isBackendError);
  await assert.rejects(fetchApi('/api/v1/downloads', { method: 'POST' }), isBackendError);
});
