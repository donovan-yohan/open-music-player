'use strict';
// This page has no account client, persistent identity or playback transport.
const $ = id => document.getElementById(id);
const fragment = new URLSearchParams(location.hash.slice(1));
let jamId = fragment.get('jamId') || '';
let invite = fragment.get('invite') || '';
fragment.delete('invite');
let memberSecret = '';
let snapshot = null;
let joining = null;
let pending = null;
let busy = false;
let sequence = 0;
let heartbeatAt = 0;
let failureDelay = 3000;
let timer = null;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const secretPattern = /^[A-Za-z0-9_-]{43}$/;
const base = () => '/api/v1/guest/jams/' + jamId;
function message(text) { $('message').textContent = text; }
function secret() { const bytes = crypto.getRandomValues(new Uint8Array(32)); return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
async function api(path, method = 'GET', body, token = memberSecret) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = 'Bearer ' + token;
  const response = await fetch(base() + path, { method, headers, credentials: 'omit', cache: 'no-store', referrerPolicy: 'no-referrer', redirect: 'error', signal: AbortSignal.timeout(10000), ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
  if (!response.ok) { const error = new Error('Jam request failed'); error.status = response.status; throw error; }
  return response.status === 204 ? null : response.json();
}
function render(value) {
  snapshot = value;
  $('state').textContent = value.state === 'open' ? 'Jam is open' : value.state === 'hostOffline' ? 'Host is offline' : 'Jam ended';
  const playing = value.nowPlaying;
  $('playing').textContent = playing ? playing.title + ' · ' + playing.artist + (playing.playing ? ' — Playing' : ' — Paused') : 'Waiting for host';
  $('catalog').replaceChildren();
  for (const item of value.catalog) {
    const row = document.createElement('div'); row.className = 'track';
    const details = document.createElement('div');
    const title = document.createElement('strong'); title.textContent = item.title;
    const artist = document.createElement('small'); artist.textContent = item.artist;
    details.append(title, artist);
    const button = document.createElement('button'); button.type = 'button';
    button.textContent = pending && pending.catalogItemId === item.catalogItemId ? 'Retry request' : 'Request';
    button.disabled = !memberSecret || value.state !== 'open' || busy || (!!pending && pending.catalogItemId !== item.catalogItemId);
    button.addEventListener('click', () => requestTrack(item.catalogItemId)); row.append(details, button); $('catalog').append(row);
  }
  $('requests').replaceChildren();
  for (const request of value.requests) {
    const item = value.catalog.find(c => c.catalogItemId === request.catalogItemId);
    const row = document.createElement('li');
    const status = {pending: 'Waiting for host approval', queued: 'Added on host', declined: 'Declined', uncertain: 'Host is checking'}[request.status] || 'Waiting for host';
    row.textContent = (item ? item.title : 'Track') + ' · ' + request.displayName + ' — ' + status;
    $('requests').append(row);
  }
}
async function join() {
  if (busy) return;
  if (!uuidPattern.test(jamId) || !secretPattern.test(invite)) { message('Open a fresh invitation from the host.'); return; }
  const name = $('name').value.trim();
  if (!name || new TextEncoder().encode(name).length > 32) { message('Use a name of 32 bytes or fewer.'); return; }
  busy = true; $('join').disabled = true;
  // Retain the exact payload after timeout: retries cannot create a new member.
  if (!joining) joining = {joinToken: invite, requestId: crypto.randomUUID(), displayName: name, memberSecret: secret()};
  try {
    const result = await api('/members', 'POST', joining, '');
    memberSecret = joining.memberSecret; joining = null; invite = '';
    history.replaceState(null, '', location.pathname);
    $('join-form').hidden = true; $('session').hidden = false; message('');
    heartbeatAt = Date.now() + 15000; render(result.snapshot); schedule(3000);
  } catch (error) { message(error.status === 403 ? 'This invitation is unavailable. Ask the host for a new one.' : error.status === 429 ? 'Too many attempts. Try again in a minute.' : 'Could not join. Retry uses the same invitation.'); }
  finally { busy = false; $('join').disabled = false; if (snapshot) render(snapshot); }
}
async function requestTrack(catalogItemId) {
  if (busy || !snapshot || snapshot.state !== 'open') return;
  if (pending && pending.catalogItemId !== catalogItemId) return;
  if (!pending) pending = {requestId: crypto.randomUUID(), catalogItemId, expectedVersion: snapshot.version};
  busy = true; render(snapshot);
  try {
    await api('/requests', 'POST', pending);
    pending = null; message('Request sent. Waiting for host approval.');
    // Refresh separately: a failed read must not turn accepted write into retry.
    schedule(50);
  } catch (error) {
    if (error.status === 409) { pending = null; message('The Jam changed. Refreshing before you request again.'); schedule(50); }
    else if (error.status === 403) { pending = null; message('Jam unavailable. Ask the host for a new invitation.'); }
    else message(error.status === 429 ? 'Request limit reached. Wait a minute, then retry.' : 'Not confirmed. Tap Retry request to check the same request.');
  } finally { busy = false; if (snapshot) render(snapshot); }
}
function schedule(delay) { clearTimeout(timer); timer = setTimeout(poll, delay); }
async function poll() {
  if (!memberSecret) return;
  if (document.visibilityState !== 'visible' || busy) { schedule(3000); return; }
  busy = true;
  try {
    // One in-flight operation. Heartbeat then bounded full snapshot, no WS.
    if (Date.now() >= heartbeatAt) { await api('/members/me', 'PUT', {sequence: ++sequence}); heartbeatAt = Date.now() + 15000; }
    const value = await api(''); render(value); failureDelay = 3000;
  } catch (error) {
    if (error.status === 403) { memberSecret = ''; pending = null; message('Jam unavailable. Open a fresh invitation from the host.'); return; }
    failureDelay = error.status === 429 ? 30000 : Math.min(30000, failureDelay * 2);
    message('Connection interrupted. Reconnecting…');
  } finally { busy = false; if (snapshot) render(snapshot); }
  schedule(failureDelay + Math.floor(Math.random() * 400));
}
$('join-form').addEventListener('submit', event => { event.preventDefault(); join(); });
$('leave').addEventListener('click', async () => { if (busy) return; busy = true; try { await api('/members/me', 'DELETE'); } catch (_) { /* lease expires without further heartbeats */ } finally { memberSecret = ''; pending = null; clearTimeout(timer); $('session').hidden = true; message('You left the Jam.'); busy = false; } });
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && memberSecret) schedule(0); });
if (!uuidPattern.test(jamId) || !secretPattern.test(invite)) { $('join').disabled = true; message('Open a fresh invitation from the host.'); }
