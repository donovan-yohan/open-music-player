'use strict';
// Only a short-lived party capability is retained in this tab. No account client
// or playback transport exists here; the server remains the authority on expiry.
const $ = id => document.getElementById(id);
const fragment = new URLSearchParams(location.hash.slice(1));
let jamId = fragment.get('jamId') || '';
let invite = fragment.get('invite') || '';
const linkJamId = jamId, linkInvite = invite;
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
let leaving = false;
let memberExpiresAt = '';
let ownRequestIds = [];
let withdrawal = null;
let searchAttempt = null;
let searchReply = null;
let searchQuery = '';
let mode = 'offered';
let review = null;
let rowFocusKey = null; // Presentation only: survive the disabled/readback render pair.
const activeStatuses = new Set(['pending', 'approved', 'importing', 'ready', 'uncertain']);
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const secretPattern = /^[A-Za-z0-9_-]{43}$/;
const journalKey = 'soundq.jam.guest.v1';
function persist() {
  const value = JSON.stringify({version: 1, jamId, invite, joining, memberSecret, memberExpiresAt, pending, sequence, leaving, ownRequestIds, withdrawal, searchAttempt, searchReply, searchQuery, savedAt: Date.now()});
  if (value.length > 16384) throw new Error('Guest receipt limit');
  sessionStorage.setItem(journalKey, value);
  if (sessionStorage.getItem(journalKey) !== value) throw new Error('Guest receipt unavailable');
}
function forget() {
  memberSecret = ''; pending = null; joining = null; invite = ''; leaving = false;
  ownRequestIds = []; withdrawal = null; searchAttempt = null; searchReply = null;
  review = null; $('review').close();
  $('session').hidden = true; $('pending-check').hidden = true;
  $('search').disabled = true; $('send-review').disabled = true;
  try { sessionStorage.removeItem(journalKey); } catch (_) { /* Server expiry/revocation still fences retained bytes. */ }
}
function restore() {
  try {
    const raw = sessionStorage.getItem(journalKey);
    if (!raw || raw.length > 16384) return;
    const value = JSON.parse(raw);
    if (value.version !== 1 || !uuidPattern.test(value.jamId) || !Number.isSafeInteger(value.sequence) || value.sequence < 0 ||
        !Number.isFinite(value.savedAt) || Date.now() - value.savedAt > 86400000) return;
    if (value.memberSecret && !secretPattern.test(value.memberSecret)) return;
    if (value.joining && (!uuidPattern.test(value.joining.requestId) || !secretPattern.test(value.joining.memberSecret) || !secretPattern.test(value.joining.joinToken))) return;
    if (value.pending && (!uuidPattern.test(value.pending.requestId) || !Number.isSafeInteger(value.pending.expectedVersion) || value.pending.expectedVersion < 1)) return;
    if (value.pending?.kind === 'source' && (!uuidPattern.test(value.pending.selectionSessionId) || typeof value.pending.candidateId !== 'string' || value.pending.candidateId.length > 512)) return;
    if (value.ownRequestIds && (!Array.isArray(value.ownRequestIds) || value.ownRequestIds.length > 50 || !value.ownRequestIds.every(id => uuidPattern.test(id)))) return;
    if (value.withdrawal && (!uuidPattern.test(value.withdrawal.requestId) || !Number.isSafeInteger(value.withdrawal.expectedVersion) || value.withdrawal.expectedVersion < 1)) return;
    if (value.searchAttempt && (!uuidPattern.test(value.searchAttempt.searchId) || typeof value.searchAttempt.query !== 'string' || new TextEncoder().encode(value.searchAttempt.query).length > 160)) return;
    // A new invitation does not silently abandon another party's held intent.
    jamId = value.jamId; invite = value.invite || ''; joining = value.joining || null;
    memberSecret = value.memberSecret || ''; memberExpiresAt = value.memberExpiresAt || '';
    pending = value.pending || null; sequence = value.sequence; leaving = value.leaving === true;
    ownRequestIds = value.ownRequestIds || []; withdrawal = value.withdrawal || null;
    searchAttempt = value.searchAttempt || null;
    // Older receipts could retain A after B reserved a new backend identity.
    searchReply = !searchAttempt && value.searchReply?.results?.length <= 5 ? value.searchReply : null;
    searchQuery = searchAttempt?.query || (typeof value.searchQuery === 'string' ? value.searchQuery.slice(0, 160) : '');
    $('query').value = searchQuery;
    heartbeatAt = Date.now() + 15000;
    if (joining) $('name').value = joining.displayName;
  } catch (_) { /* An unreadable tab receipt never grants authority or replays a write. */ }
}
restore();
// A fresh invitation link is only offered while a join for another invitation
// is held: that join's response may have been lost, so a 403 alone does not
// prove it failed. Switching is the guest's explicit choice.
let offeredInvite = null;
if (!memberSecret && uuidPattern.test(linkJamId) && secretPattern.test(linkInvite) && (linkJamId !== jamId || linkInvite !== invite)) {
  if (joining) offeredInvite = {jamId: linkJamId, invite: linkInvite};
  else { jamId = linkJamId; invite = linkInvite; }
}
function useOfferedInvite() {
  if (busy || memberSecret || !offeredInvite) return;
  jamId = offeredInvite.jamId; invite = offeredInvite.invite; joining = null; offeredInvite = null;
  persist(); $('use-invite').hidden = true; $('join').disabled = false;
  message('Using the new invitation. Join when ready.');
}
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
  // Snapshot publication rebuilds rows, not their keyboard/navigation identity.
  const focusKey = document.activeElement?.getAttribute('data-focus-key') ||
    (document.activeElement === document.body ? rowFocusKey : null);
  rowFocusKey = null;
  $('state').textContent = value.state === 'open' ? 'Approval on' : value.state === 'hostOffline' ? 'Host offline · Requests paused' : 'Jam ended';
  const playing = value.nowPlaying;
  $('playing').textContent = playing ? playing.title + ' · ' + playing.artist + (playing.playing ? ' — Playing' : ' — Paused') : 'Waiting for host';
  $('catalog').replaceChildren();
  const filter = $('filter').value.trim().toLocaleLowerCase();
  for (const item of value.catalog.filter(item => (item.title + ' ' + item.artist).toLocaleLowerCase().includes(filter))) {
    const duplicate = value.requests.some(r => r.catalogItemId === item.catalogItemId && (activeStatuses.has(r.status) || r.status === 'queued'));
    $('catalog').append(trackRow(item, duplicate ? 'Already requested' : 'Request ' + item.title,
      !canRequest() || duplicate, () => openReview({kind: 'catalog', item})));
  }
  $('catalog-empty').hidden = $('catalog').children.length > 0;
  $('pending-check').hidden = !pending;
  $('pending-check').disabled = busy || leaving || !memberSecret || value.state !== 'open';
  $('find-tab').hidden = !value.allowOutsideDiscovery;
  if (!value.allowOutsideDiscovery) mode = 'offered';
  $('offered-panel').hidden = mode !== 'offered'; $('find-panel').hidden = mode !== 'find';
  $('offered-tab').setAttribute('aria-pressed', String(mode === 'offered'));
  $('find-tab').setAttribute('aria-pressed', String(mode === 'find'));
  renderSearch();
  $('requests').replaceChildren();
  for (const request of value.requests) {
    const item = value.catalog.find(c => c.catalogItemId === request.catalogItemId);
    const row = document.createElement('li'); row.className = 'request-row';
    const details = document.createElement('div');
    const title = document.createElement('strong'); title.textContent = request.source?.title || item?.title || 'Track';
    const facts = document.createElement('small'); facts.textContent = request.source ? sourceFacts(request.source) : item?.artist || '';
    const status = document.createElement('span'); status.className = 'request-status';
    status.textContent = request.displayName + ' · ' + ({pending: 'Waiting for host approval', approved: 'Approved', importing: 'Importing', ready: 'Ready · waiting turn', queued: 'Added to host queue', declined: 'Declined', uncertain: 'Host is checking', withdrawn: 'Withdrawn', failed: 'Import failed', duplicate: 'Already requested'}[request.status] || 'Checking');
    details.append(title, facts, status); row.append(details);
    if (ownRequestIds.includes(request.requestId) && activeStatuses.has(request.status)) {
      const button = document.createElement('button'); button.type = 'button'; button.className = 'quiet request-action';
      button.setAttribute('data-focus-key', 'withdraw:' + request.requestId);
      button.textContent = withdrawal?.requestId === request.requestId ? 'Check withdrawal' : 'Withdraw';
      button.disabled = busy || leaving || !memberSecret || value.state !== 'open' || (!!withdrawal && withdrawal.requestId !== request.requestId);
      button.addEventListener('click', () => withdrawal ? withdrawRequest(request.requestId) : openReview({kind: 'withdraw', request, item: request.source || item})); row.append(button);
    }
    $('requests').append(row);
  }
  $('requests-empty').hidden = value.requests.length > 0;
  if (review) $('send-review').disabled = review.kind === 'withdraw' ? busy || leaving || !memberSecret || value.state !== 'open' : !canRequest() || (review.kind === 'source' && Date.parse(review.item.expiresAt) <= Date.now());
  if (focusKey) {
    const replacement = Array.from(document.querySelectorAll('[data-focus-key]')).find(node => node.getAttribute('data-focus-key') === focusKey);
    if (replacement && !replacement.disabled) replacement.focus({preventScroll: true});
    else if (replacement && busy) rowFocusKey = focusKey;
  }
}
function duration(ms) { return Number.isFinite(ms) && ms > 0 ? Math.floor(ms / 60000) + ':' + String(Math.floor(ms / 1000) % 60).padStart(2, '0') : ''; }
function sourceFacts(item) { return [item.artist, item.provider === 'youtube' ? 'YouTube' : item.provider === 'soundcloud' ? 'SoundCloud' : item.provider, duration(item.durationMs)].filter(Boolean).join(' · '); }
function canRequest() { return !!memberSecret && !busy && !leaving && !pending && !withdrawal && snapshot?.state === 'open' && !snapshot.requests.some(r => ownRequestIds.includes(r.requestId) && activeStatuses.has(r.status)); }
function trackRow(item, label, disabled, action) {
  const row = document.createElement('div'); row.className = 'track';
  const art = document.createElement('span'); art.className = 'art'; art.textContent = '♪'; art.setAttribute('aria-hidden', 'true');
  const details = document.createElement('div'); details.className = 'track-details';
  const title = document.createElement('strong'); title.textContent = item.title;
  const artist = document.createElement('small'); artist.textContent = item.artist;
  const facts = document.createElement('small'); facts.textContent = sourceFacts({...item, artist: ''}); details.append(title, artist, facts);
  const button = document.createElement('button'); button.type = 'button'; button.className = 'icon'; button.textContent = '+';
  button.setAttribute('aria-label', label);
  button.setAttribute('data-focus-key', item.catalogItemId ? 'catalog:' + item.catalogItemId : 'source:' + item.selectionSessionId + ':' + item.candidateId);
  button.disabled = disabled; button.addEventListener('click', action);
  row.append(art, details, button); return row;
}
function renderSearch() {
  // A replacement search would invalidate the selection an unresolved source
  // request still names, so its exact retry could no longer succeed.
  $('search').disabled = busy || leaving || !memberSecret || snapshot?.state !== 'open' || !snapshot?.allowOutsideDiscovery || pending?.kind === 'source';
  $('search').textContent = searchAttempt ? searchAttempt.restart ? 'Search again' : 'Retry search' : 'Search';
  $('search-summary').textContent = searchReply ? searchReply.results.length ? 'Results for “' + searchQuery + '”' : 'No matches. Try another search.' : '';
  $('results').replaceChildren();
  for (const item of searchReply?.results || []) {
    const duplicate = snapshot?.requests.some(r => r.source?.provider === item.provider && r.source?.sourceId === item.sourceId && (activeStatuses.has(r.status) || r.status === 'queued'));
    $('results').append(trackRow(item, duplicate ? 'Already requested' : 'Request ' + item.title,
      !canRequest() || duplicate || Date.parse(item.expiresAt) <= Date.now(), () => openReview({kind: 'source', item})));
  }
}
function currentSource(item) {
  return !searchAttempt && !!searchReply?.results.some(result => result.selectionSessionId === item.selectionSessionId && result.candidateId === item.candidateId);
}
function retireSourceResults() {
  searchReply = null;
  if (review?.kind === 'source') { review = null; $('review').close(); }
}
function openReview(choice) {
  if (choice.kind !== 'withdraw' && !canRequest()) return;
  if (choice.kind === 'source' && !currentSource(choice.item)) { message('Source changed. Search again.'); return; }
  review = choice;
  $('review-title').textContent = choice.kind === 'withdraw' ? 'Withdraw request?' : 'Request this song?';
  $('review-song').textContent = choice.item?.title || 'Track';
  $('review-facts').textContent = choice.item ? sourceFacts(choice.item) : '';
  $('review-source').textContent = choice.kind === 'source' ? choice.item.provider + ' · ' + choice.item.sourceId : '';
  $('review-note').textContent = choice.kind === 'withdraw' ? 'Songs already added stay.' : 'Host approval required';
  $('send-review').textContent = choice.kind === 'withdraw' ? 'Withdraw request' : 'Send request';
  render(snapshot); $('review').showModal();
}
async function sendReview() {
  const choice = review;
  if (!choice) return;
  if (choice.kind !== 'withdraw' && !canRequest()) return;
  if (choice.kind === 'source' && !currentSource(choice.item)) { review = null; $('review').close(); message('Source changed. Search again.'); return; }
  if (choice.kind === 'source' && Date.parse(choice.item.expiresAt) <= Date.now()) { message('Source expired. Search again.'); return; }
  review = null; $('review').close();
  if (choice.kind === 'withdraw') return withdrawRequest(choice.request.requestId);
  if (choice.kind === 'catalog') return requestTrack(choice.item.catalogItemId);
  pending = {kind: 'source', requestId: crypto.randomUUID(), selectionSessionId: choice.item.selectionSessionId, candidateId: choice.item.candidateId, expectedVersion: snapshot.version};
  return sendPending();
}
async function searchMusic() {
  if (busy || leaving || !memberSecret || !snapshot?.allowOutsideDiscovery || snapshot.state !== 'open') return;
  if (pending?.kind === 'source') { message('Check your song request before searching again.'); return; }
  const query = $('query').value.trim();
  if (!query || new TextEncoder().encode(query).length > 160) { message('Enter a song or artist, up to 160 bytes.'); return; }
  if (!searchAttempt || searchAttempt.query !== query || searchAttempt.restart) {
    searchAttempt = {searchId: crypto.randomUUID(), query};
    searchQuery = query; retireSourceResults();
  }
  busy = true; render(snapshot); message('Searching…');
  try {
    persist();
    const result = await api('/search', 'POST', {searchId: searchAttempt.searchId, query: searchAttempt.query});
    searchQuery = query; searchReply = result; searchAttempt = null; persist(); message('');
  } catch (error) {
    if (error.status === 403) { message('Search not confirmed. Checking Jam…'); schedule(50); }
    else if (error.status === 409) { searchAttempt.restart = true; persist(); message('Search not confirmed. Search again.'); }
    else message(error.status === 429 ? 'Search limit reached. Try again later.' : 'Search unavailable. Retry the same search.');
  } finally { busy = false; render(snapshot); }
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
    persist(); // Capture before sending, including a join whose response is lost.
    const result = await api('/members', 'POST', joining, '');
    memberSecret = joining.memberSecret; memberExpiresAt = result.memberExpiresAt; joining = null; invite = '';
    persist();
    history.replaceState(null, '', location.pathname);
    $('join-form').hidden = true; $('session').hidden = false; message('');
    heartbeatAt = Date.now() + 15000; render(result.snapshot); schedule(3000);
  } catch (error) { message(error.status === 403 ? (offeredInvite ? 'This invitation is unavailable. Use the new invitation, or ask the host.' : 'This invitation is unavailable. Ask the host for a new one.') : error.status === 429 ? 'Too many attempts. Try again in a minute.' : 'Could not join. Retry uses the same invitation.'); }
  finally { busy = false; $('join').disabled = false; if (snapshot) render(snapshot); }
}
async function requestTrack(catalogItemId) {
  if (busy || leaving || !snapshot || snapshot.state !== 'open') return;
  if (pending && pending.catalogItemId !== catalogItemId) return;
  if (!pending && !canRequest()) return;
  if (!pending) pending = {requestId: crypto.randomUUID(), catalogItemId, expectedVersion: snapshot.version};
  return sendPending();
}
async function sendPending() {
  if (busy || leaving || !pending || !memberSecret || snapshot?.state !== 'open') return;
  if (!ownRequestIds.includes(pending.requestId)) {
    if (ownRequestIds.length >= 50) { message('Request limit reached.'); return; }
    ownRequestIds.push(pending.requestId);
  }
  busy = true; render(snapshot);
  try {
    persist(); // A reload must retain the SAME request ID/payload, not create a new request.
    const body = pending.kind === 'source'
      ? {requestId: pending.requestId, selectionSessionId: pending.selectionSessionId, candidateId: pending.candidateId, expectedVersion: pending.expectedVersion}
      : {requestId: pending.requestId, catalogItemId: pending.catalogItemId, expectedVersion: pending.expectedVersion};
    const result = await api(pending.kind === 'source' ? '/source-requests' : '/requests', 'POST', body);
    if (result?.requestId && !snapshot.requests.some(r => r.requestId === result.requestId)) snapshot.requests.push(result);
    pending = null; persist(); message('Request sent.');
    // Refresh separately: a failed read must not turn accepted write into retry.
    schedule(50);
  } catch (error) {
    // A source-binding denial is not proof that the member capability retired.
    // Keep the journal until the scoped member read confirms acceptance/rejection.
    if (error.status === 409 || error.status === 400 || error.status === 403) {
      if (error.status === 403 && pending.kind === 'source') retireSourceResults();
      pending.rejected = true; persist(); message('Checking the same request…'); schedule(50);
    }
    else message(error.status === 429 ? 'Request limit reached. Wait a minute, then retry.' : 'Request not confirmed. Check the same request.');
  } finally { busy = false; if (snapshot) render(snapshot); }
}
async function withdrawRequest(requestId) {
  if (busy || leaving || !memberSecret || snapshot?.state !== 'open' || !ownRequestIds.includes(requestId)) return;
  if (withdrawal && withdrawal.requestId !== requestId) return;
  if (!withdrawal) withdrawal = {requestId, expectedVersion: snapshot.version};
  busy = true; render(snapshot);
  try {
    persist();
    await api('/requests/' + requestId, 'DELETE', {expectedVersion: withdrawal.expectedVersion});
    withdrawal = null; persist(); message('Request withdrawn.'); schedule(50);
  } catch (error) {
    if (error.status === 409 || error.status === 403) { withdrawal.rejected = true; persist(); }
    message('Withdrawal not confirmed. Checking…'); schedule(50);
  } finally { busy = false; if (snapshot) render(snapshot); }
}
function schedule(delay) { clearTimeout(timer); timer = setTimeout(poll, delay); }
async function poll() {
  if (!memberSecret) return;
  if (document.visibilityState !== 'visible' || busy) { schedule(3000); return; }
  if (leaving) { await leave(); return; }
  busy = true;
  try {
    // One in-flight operation. Heartbeat then bounded full snapshot, no WS.
    if (Date.now() >= heartbeatAt) {
      sequence++; persist();
      const beat = await api('/members/me', 'PUT', {sequence});
      memberExpiresAt = beat.memberExpiresAt; heartbeatAt = Date.now() + 15000;
    }
    const value = await api('');
    if (pending && value.requests.some(request => request.requestId === pending.requestId)) {
      pending = null; message('Request confirmed.');
    } else if (pending?.rejected && value.version >= pending.expectedVersion) {
      pending = null; message('Request changed. Choose again.');
    }
    if (withdrawal) {
      const request = value.requests.find(r => r.requestId === withdrawal.requestId);
      if (request?.status === 'withdrawn') { withdrawal = null; message('Request withdrawn.'); }
      else if (withdrawal.rejected) { withdrawal = null; message(request?.status === 'queued' ? 'Already added to host queue.' : 'Request changed. Check its status.'); }
    }
    // The snapshot lists every request in the Jam. Keep only IDs it confirms
    // or that are still unresolved here, so rejected IDs cannot fill the receipt.
    const present = new Set(value.requests.map(request => request.requestId));
    ownRequestIds = ownRequestIds.filter(id => present.has(id) || id === pending?.requestId || id === withdrawal?.requestId);
    if (['Checking your Jam…', 'Connection interrupted. Reconnecting…'].includes($('message').textContent)) {
      message(pending ? 'Request not confirmed. Check the same request.' : '');
    }
    persist(); render(value); failureDelay = 3000;
  } catch (error) {
    if (error.status === 403) { forget(); message('Jam unavailable. Open a fresh invitation from the host.'); return; }
    failureDelay = error.status === 429 ? 30000 : Math.min(30000, failureDelay * 2);
    message('Connection interrupted. Reconnecting…');
  } finally { busy = false; if (snapshot) render(snapshot); }
  schedule(failureDelay + Math.floor(Math.random() * 400));
}
$('join-form').addEventListener('submit', event => { event.preventDefault(); join(); });
async function leave() {
  if (busy || !memberSecret) return;
  busy = true; leaving = true;
  try {
    persist();
    await api('/members/me', 'DELETE');
    forget(); clearTimeout(timer); $('session').hidden = true; message('You left the Jam.');
  } catch (error) {
    if (error.status === 403) {
      forget(); clearTimeout(timer); $('session').hidden = true; message('Jam access ended.');
    } else {
      message('Leave not confirmed. Checking…'); schedule(3000);
    }
  } finally { busy = false; if (snapshot) render(snapshot); }
}
$('leave').addEventListener('click', leave);
$('use-invite').addEventListener('click', useOfferedInvite);
$('search-form').addEventListener('submit', event => { event.preventDefault(); searchMusic(); });
$('filter').addEventListener('input', () => { if (snapshot) render(snapshot); });
$('offered-tab').addEventListener('click', () => { mode = 'offered'; if (snapshot) render(snapshot); });
$('find-tab').addEventListener('click', () => { mode = 'find'; if (snapshot) render(snapshot); });
$('pending-check').addEventListener('click', sendPending);
$('send-review').addEventListener('click', sendReview);
$('cancel-review').addEventListener('click', () => { review = null; $('review').close(); });
$('review').addEventListener('cancel', () => { review = null; });
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && memberSecret) schedule(0); });
if (memberSecret) {
  history.replaceState(null, '', location.pathname);
  $('join-form').hidden = true; $('session').hidden = false;
  message(leaving ? 'Leave not confirmed. Checking…' : 'Checking your Jam…'); schedule(0);
} else if (offeredInvite) {
  $('use-invite').hidden = false;
  message('Your earlier join is not confirmed. Retry it, or use the new invitation.');
} else if (!uuidPattern.test(jamId) || !secretPattern.test(invite)) {
  $('join').disabled = true; message('Open a fresh invitation from the host.');
}
