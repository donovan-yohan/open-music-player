// Compile the real popup without importing it into Node's global DOM.
import type {} from '../src/popup/popup';
import type { AddToLibraryResponse } from '../src/types';

declare function require(name: string): any;
declare const __dirname: string;
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const vm = require('node:vm');

class Element {
  textContent = '';
  value = '';
  disabled = false;
  title = '';
  style = {};
  src = '';
  private classes = new Set<string>(['hidden']);
  classList = {
    add: (name: string) => this.classes.add(name),
    remove: (name: string) => this.classes.delete(name),
    contains: (name: string) => this.classes.has(name),
  };
  listeners: Record<string, Array<(event: unknown) => unknown>> = {};
  children: Record<string, Element> = {};
  addEventListener(type: string, callback: (event: unknown) => unknown): void {
    (this.listeners[type] ??= []).push(callback);
  }
  querySelector(selector: string): Element {
    return this.children[selector] ??= new Element();
  }
  async dispatch(type: string): Promise<void> {
    for (const callback of this.listeners[type] ?? []) {
      await callback({ preventDefault(): void {} });
    }
    // Event listeners may launch a promise without returning it.
    for (let i = 0; i < 10; i++) await Promise.resolve();
  }
}

interface AddResult {
  response?: AddToLibraryResponse;
  runtimeError?: string;
  deferred?: boolean;
}

async function loadPopup(result: AddToLibraryResponse | AddResult[]): Promise<{
  nodes: Record<string, Element>; sent: Array<{ type: string }>; context: any;
  settleNext: () => void;
}> {
  const nodes: Record<string, Element> = {};
  const sent: Array<{ type: string }> = [];
  const results = Array.isArray(result) ? [...result] : [{ response: result }];
  const pending: Array<() => void> = [];
  const runtime: {
    lastError?: { message: string };
    sendMessage: (message: { type: string }, callback: (value: unknown) => void) => void;
  } = {
    sendMessage(message, callback): void {
      sent.push(message);
      if (message.type === 'CHECK_AUTH') {
        callback({ isLoggedIn: true });
        return;
      }
      assert.equal(message.type, 'ADD_TO_LIBRARY', 'unexpected popup mutation');
      const next = results.shift();
      if (!next) throw new Error('popup must not send more mutations than the scenario permits');
      const finish = (): void => {
        runtime.lastError = next.runtimeError ? { message: next.runtimeError } : undefined;
        try {
          callback(next.response);
        } finally {
          runtime.lastError = undefined;
        }
      };
      if (next.deferred) pending.push(finish);
      else finish();
    },
  };
  let init: (() => Promise<void>) | undefined;
  const context = vm.createContext({
    exports: {},
    require: (name: string) => require(join(__dirname, '../src/popup', name)),
    console,
    navigator: { onLine: true },
    window: { addEventListener(): void {}, removeEventListener(): void {} },
    document: {
      body: new Element(),
      getElementById: (id: string) => nodes[id] ??= new Element(),
      addEventListener: (_type: string, callback: () => Promise<void>) => { init = callback; },
    },
    chrome: {
      tabs: {
        query: async () => [{ id: 1 }],
        sendMessage: (_id: number, _message: unknown, callback: (value: unknown) => void) => callback({
          type: 'PAGE_METADATA', url: 'https://www.youtube.com/watch?v=test',
          sourceType: 'youtube', supported: true, metadata: { title: 'Test', artist: 'Artist' },
        }),
        create(): void {},
      },
      runtime,
    },
  });
  const modules = new Map<string, { exports: unknown }>();
  const loadModule = (name: string, directory: string): unknown => {
    const filename = require('node:module').createRequire(join(directory, 'loader.js')).resolve(name);
    if (modules.has(filename)) return modules.get(filename)!.exports;
    const module = { exports: {} };
    modules.set(filename, module);
    const run = vm.runInContext(`(function(require, module, exports) {\n${readFileSync(filename, 'utf8')}\n})`, context);
    run((dependency: string) => loadModule(dependency, require('node:path').dirname(filename)), module, module.exports);
    return module.exports;
  };
  context.require = (name: string) => loadModule(name, join(__dirname, '../src/popup'));
  vm.runInContext(readFileSync(join(__dirname, '../src/popup/popup.js'), 'utf8'), context);
  assert.ok(init, 'real popup should register its DOMContentLoaded initializer');
  await init!();
  return {
    nodes, sent, context,
    settleNext(): void {
      const finish = pending.shift();
      assert.ok(finish, 'expected a pending runtime callback');
      finish!();
    },
  };
}

function assertAddButtonIdle(nodes: Record<string, Element>, context: any): void {
  assert.equal(vm.runInContext('state.isAdding', context), false, 'settled request must release in-flight state');
  assert.equal(nodes['add-btn'].disabled, false, 'settled request must enable Add');
  assert.equal(nodes['add-btn'].querySelector('.btn-text').classList.contains('hidden'), false);
  assert.equal(nodes['add-btn'].querySelector('.btn-loading').classList.contains('hidden'), true);
}

test('popup Retry sends exactly one fresh add after a transient refresh failure settles', async () => {
  const { nodes, sent, context, settleNext } = await loadPopup([
    { deferred: true, response: {
      type: 'ADD_TO_LIBRARY_RESULT', success: false,
      error: 'Authentication refresh temporarily unavailable. Please try again.', errorCode: 'NETWORK_ERROR',
    } },
    { deferred: true, response: {
      type: 'ADD_TO_LIBRARY_RESULT', success: true, jobId: 'job-after-user-retry',
    } },
  ]);
  const addCount = (): number => sent.filter(message => message.type === 'ADD_TO_LIBRARY').length;
  const first = nodes['add-btn'].dispatch('click');
  assert.equal(addCount(), 1);
  assert.equal(vm.runInContext('state.isAdding', context), true);
  assert.equal(nodes['add-btn'].disabled, true);
  await nodes['add-btn'].dispatch('click');
  await nodes['retry-btn'].dispatch('click');
  assert.equal(addCount(), 1, 'duplicate clicks must not overlap a pending add');
  settleNext();
  await first;
  assert.equal(nodes['error'].classList.contains('hidden'), false);
  assert.equal(nodes['retry-btn'].classList.contains('hidden'), false);
  assert.equal(nodes['not-logged-in'].classList.contains('hidden'), true);
  assertAddButtonIdle(nodes, context);
  assert.equal(addCount(), 1, 'failure must not automatically replay the mutation');

  const retry = nodes['retry-btn'].dispatch('click');
  assert.equal(addCount(), 2, 'explicit Retry must dispatch a fresh ADD_TO_LIBRARY after settlement');
  assert.equal(JSON.stringify(sent[1]), JSON.stringify(sent[2]), 'retry must retain the original URL and metadata');
  assert.equal(nodes['error'].classList.contains('hidden'), true, 'stale error must clear when retry begins');
  assert.equal(vm.runInContext('lastError', context), null);
  await nodes['retry-btn'].dispatch('click');
  await nodes['add-btn'].dispatch('click');
  assert.equal(addCount(), 2, 'duplicate clicks must not overlap the pending retry');
  settleNext();
  await retry;
  assertAddButtonIdle(nodes, context);
  assert.equal(nodes['success'].classList.contains('hidden'), false);
  assert.equal(nodes['job-status'].textContent, 'Job ID: job-after-user-retry');
  assert.equal(vm.runInContext('state.jobId', context), 'job-after-user-retry');
  assert.equal(vm.runInContext('state.trackId', context), undefined);
  assert.equal(vm.runInContext('lastError', context), null);
  await nodes['retry-btn'].dispatch('click');
  assert.equal(addCount(), 2, 'consumed Retry intent must not replay a successful job');
  assert.equal(nodes['success'].classList.contains('hidden'), false, 'stale Retry must not replace success');
});

test('popup Retry recovers from a runtime messaging failure without automatic replay', async () => {
  const { nodes, sent, context, settleNext } = await loadPopup([
    { deferred: true, runtimeError: 'The message port closed before a response was received.' },
    { deferred: true, response: {
      type: 'ADD_TO_LIBRARY_RESULT', success: true, jobId: 'job-after-runtime-retry',
    } },
  ]);
  const addCount = (): number => sent.filter(message => message.type === 'ADD_TO_LIBRARY').length;
  const first = nodes['add-btn'].dispatch('click');
  await nodes['add-btn'].dispatch('click');
  assert.equal(addCount(), 1, 'a runtime request must stay single-flight until its callback settles');
  settleNext();
  await first;
  assertAddButtonIdle(nodes, context);
  assert.equal(nodes['error'].classList.contains('hidden'), false);
  assert.equal(nodes['retry-btn'].classList.contains('hidden'), false, 'runtime transport failure needs explicit Retry');
  assert.equal(nodes['error-title'].textContent, 'Connection Error');
  assert.equal(addCount(), 1, 'runtime failure must not automatically replay the mutation');

  const retry = nodes['retry-btn'].dispatch('click');
  assert.equal(addCount(), 2, 'explicit Retry must send a fresh add after runtime failure');
  await nodes['retry-btn'].dispatch('click');
  await nodes['add-btn'].dispatch('click');
  assert.equal(addCount(), 2, 'repeated clicks must not duplicate a pending runtime retry');
  settleNext();
  await retry;
  assertAddButtonIdle(nodes, context);
  assert.equal(nodes['success'].classList.contains('hidden'), false);
  assert.equal(nodes['job-status'].textContent, 'Job ID: job-after-runtime-retry');
  assert.equal(vm.runInContext('state.jobId', context), 'job-after-runtime-retry');
  assert.equal(vm.runInContext('lastError', context), null);
  await nodes['retry-btn'].dispatch('click');
  assert.equal(addCount(), 2, 'a successful runtime retry must consume the failed operation');
});

for (const outcome of [
  { error: 'already_added', section: 'already-added' },
  { error: 'not_logged_in', section: 'not-logged-in' },
  { error: 'invalid access token', errorCode: 'INVALID_TOKEN', section: 'not-logged-in' },
  { error: 'Invalid URL', errorCode: 'VALIDATION_ERROR', section: 'error' },
]) {
  test(`popup clears stale network Retry intent after ${outcome.error} followup`, async () => {
    const { nodes, sent, context } = await loadPopup([
      { response: {
        type: 'ADD_TO_LIBRARY_RESULT', success: false,
        error: 'backend_unavailable', errorCode: 'NETWORK_ERROR',
      } },
      { response: {
        type: 'ADD_TO_LIBRARY_RESULT', success: false,
        error: outcome.error, errorCode: outcome.errorCode,
      } },
    ]);
    await nodes['add-btn'].dispatch('click');
    assertAddButtonIdle(nodes, context);
    assert.equal(nodes['retry-btn'].classList.contains('hidden'), false);
    assert.equal(sent.filter(message => message.type === 'ADD_TO_LIBRARY').length, 1);
    await nodes['retry-btn'].dispatch('click');
    assertAddButtonIdle(nodes, context);
    assert.equal(nodes[outcome.section].classList.contains('hidden'), false);
    assert.equal(nodes['retry-btn'].classList.contains('hidden'), true, 'nonretryable followup must revoke stale Retry');
    assert.equal(vm.runInContext('state.jobId', context), null);
    await nodes['retry-btn'].dispatch('click');
    assert.equal(sent.filter(message => message.type === 'ADD_TO_LIBRARY').length, 2,
      'stale network error must not authorize retry of a later terminal result');
    assert.equal(nodes[outcome.section].classList.contains('hidden'), false);
  });
}

test('popup keeps a queued job identity separate from a track identity', async () => {
  const { nodes, context } = await loadPopup({
    type: 'ADD_TO_LIBRARY_RESULT', success: true, jobId: 'job-not-track-123',
  });
  await nodes['add-btn'].dispatch('click');
  assertAddButtonIdle(nodes, context);
  assert.equal(nodes['success'].classList.contains('hidden'), false);
  assert.equal(nodes['success'].querySelector('.message').textContent, 'Download queued. Follow its progress in the Sound Q app.');
  assert.equal(nodes['job-status'].textContent, 'Job ID: job-not-track-123');
  assert.notEqual(vm.runInContext('state.trackId', context), 'job-not-track-123',
    'a download job must never become a track ID');
  assert.equal(vm.runInContext('state.jobId', context), 'job-not-track-123');
});

test('unsupported popup actions are disabled and explain their limitation', async () => {
  const { nodes } = await loadPopup({ type: 'ADD_TO_LIBRARY_RESULT', success: true, jobId: 'job-1' });
  for (const id of ['edit-btn', 'edit-existing-btn', 'merge-btn', 'keep-separate-btn', 'edit-save-btn']) {
    assert.equal(nodes[id].disabled, true, `${id} should be unavailable`);
    assert.match(nodes[id].title, /not supported|unavailable/i, `${id} should explain why`);
  }
});

test('popup preserves backend auth error codes returned by the background', async () => {
  const { nodes, context } = await loadPopup(JSON.parse(JSON.stringify({
    type: 'ADD_TO_LIBRARY_RESULT', success: false, error: 'invalid access token',
    errorCode: 'INVALID_TOKEN',
  })));
  await nodes['add-btn'].dispatch('click');
  assertAddButtonIdle(nodes, context);
  assert.equal(nodes['not-logged-in'].classList.contains('hidden'), false,
    'structured auth errors must not become unclassified text errors');
});

test('popup cannot submit a job ID to unsupported metadata or merge messages', async () => {
  const { nodes, sent } = await loadPopup({
    type: 'ADD_TO_LIBRARY_RESULT', success: true, jobId: 'job-not-track-123',
  });
  await nodes['add-btn'].dispatch('click');
  await nodes['edit-btn'].dispatch('click');
  nodes['edit-title'].value = 'New title';
  nodes['edit-artist'].value = 'New artist';
  await nodes['edit-form'].dispatch('submit');
  await nodes['merge-btn'].dispatch('click');
  await nodes['keep-separate-btn'].dispatch('click');
  assert.equal(nodes['edit-modal'].classList.contains('hidden'), true);
  assert.equal(sent.filter(message => ['UPDATE_METADATA', 'MERGE_TRACKS'].includes(message.type)).length, 0);
});
