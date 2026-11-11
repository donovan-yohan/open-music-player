'use strict';
// Actual guest assets, fresh Chromium contexts, synthetic loopback HTTP only.
// This proves browser presentation/interaction, NOT Go/provider/native acceptance.
// Run: PLAYWRIGHT_MODULE=/path/to/playwright node app.browser.test.cjs REPORT_DIR
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const {chromium} = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const out = process.argv[2];
assert(out, 'explicit private report directory required');
fs.mkdirSync(out, {recursive: true});
const failures = [], checks = [], measurements = [], errors = [];
const jamId = '00000000-0000-4000-8000-000000000001';
const catalogId = '00000000-0000-4000-8000-000000000002';
const selectionId = '00000000-0000-4000-8000-000000000003';
const title = '夜明けの街 — Après la pluie (Live / versión extendida 2026)';
const artist = '宇多田ヒカル · Sigur Rós · فرقة الموسيقى';
const item = {catalogItemId: catalogId, title, artist, durationMs: 241000};
const source = {selectionSessionId: selectionId, candidateId: 'synthetic-candidate', title, artist, provider: 'youtube', sourceId: 'synthetic-exact-live', durationMs: 241000, expiresAt: '2099-01-01T00:00:00Z'};
function fixture() {
  return {state: 'open', requests: [], operations: [], lost: false, deny: false, searchFailure: false, expired: false, hold: null,
    snapshot() {return {jamId, version: 1, state: this.state, allowOutsideDiscovery: true, catalog: [item, {...item,catalogItemId: selectionId,title: 'Night Drive (radio edit)'}], requests: this.requests, nowPlaying: {title,artist,playing:false,durationMs:241000}};}};
}
let f = fixture();
const server = http.createServer(async (req,res) => {
  try {
    const url = new URL(req.url, 'http://127.0.0.1');
    res.setHeader('Cache-Control', 'no-store');
    if (url.pathname.startsWith('/api/v1/guest/jams/')) {
      let raw=''; for await (const chunk of req) raw += chunk;
      const body = raw ? JSON.parse(raw) : null;
      const route = url.pathname.slice(('/api/v1/guest/jams/'+jamId).length);
      f.operations.push({method:req.method,route,body});
      const json = (value, status=200) => {res.writeHead(status, {'Content-Type':'application/json'});res.end(JSON.stringify(value));};
      if(f.deny) return json({},403);
      if(route === '/members' && req.method === 'POST') return json({memberId:selectionId,memberExpiresAt:'2099-01-01T00:00:00Z',snapshot:f.snapshot()},201);
      if(route === '/search') {
        if(f.searchFailure) return json({},503);
        return json({selectionSessionId:selectionId,results:[{...source,expiresAt:f.expired?'2000-01-01T00:00:00Z':source.expiresAt}]});
      }
      if((route === '/requests' || route === '/source-requests') && req.method === 'POST') {
        if(f.lost) return json({},503); // Unknown to the guest; no browser connection-reset replay.
        const value={requestId:body.requestId,displayName:'Nori',status:'pending',...(route==='/requests'?{catalogItemId:body.catalogItemId}:{source})};
        if(!f.requests.some(r=>r.requestId===body.requestId)) f.requests.push(value);
        if(f.hold) await f.hold;
        return json(value,201);
      }
      if(route.startsWith('/requests/') && req.method==='DELETE') {
        const r=f.requests.find(r=>r.requestId===route.split('/').at(-1));if(r)r.status='withdrawn';res.writeHead(204);return res.end();
      }
      if(route==='/members/me' && req.method==='DELETE') {res.writeHead(204);return res.end();}
      if(route==='/members/me') return json({memberExpiresAt:'2099-01-01T00:00:00Z'});
      return json(f.snapshot());
    }
    const file = url.pathname === '/join' ? 'index.html' : url.pathname === '/join/app.css' ? 'app.css' : url.pathname === '/join/app.js' ? 'app.js' : null;
    if(!file) {res.writeHead(404);return res.end();}
    res.writeHead(200, {'Content-Type':file.endsWith('.css')?'text/css':file.endsWith('.js')?'text/javascript':'text/html'});
    res.end(fs.readFileSync(path.join(process.env.GUEST_ASSET_ROOT || __dirname,file)));
  } catch(e) {res.destroy(e);}
});
const check=(name, condition, detail)=>{checks.push(name);if(!condition)failures.push({name,detail});};
async function geometry(page, name, width) {
  const m=await page.evaluate(()=>({
    overflow:document.documentElement.scrollWidth>innerWidth,
    targets:[...document.querySelectorAll('button,input')].filter(n=>n.checkVisibility()).map(n=>{const r=n.getBoundingClientRect();return {id:n.id,label:n.getAttribute('aria-label')||n.textContent,w:r.width,h:r.height};}),
    rows:[...document.querySelectorAll('.track')].map(n=>{const r=n.getBoundingClientRect(),a=n.querySelector('.art').getBoundingClientRect();return {h:r.height,artH:a.height,artW:a.width,x:r.x,artX:a.x};}),
    search:document.querySelector('#query').getBoundingClientRect().width,
    requestRows:[...document.querySelectorAll('.request-row')].map(n=>({height:n.getBoundingClientRect().height,actionWidth:n.querySelector('button')?.getBoundingClientRect().width})),
    facts:[...document.querySelectorAll('.track small')].filter(n=>n.checkVisibility()).map(n=>({text:n.textContent,clipped:n.scrollWidth>n.clientWidth})),
    focus:document.activeElement?.getAttribute('aria-label'),
  }));
  measurements.push({width,name,...m});
  check(`${width} ${name}: no horizontal overflow`,!m.overflow,m);
  check(`${width} ${name}: 48px targets`,m.targets.every(t=>t.w>=48&&t.h>=48),m.targets);
  check(`${width} ${name}: square full-row artwork`,m.rows.every(r=>r.artH===r.artW&&r.h===r.artH&&r.x===r.artX),m.rows);
  if(name==='offered' || name==='source-review') check(`${width} ${name}: duration remains visible with long artist`,m.facts.some(x=>x.text.includes('4:01')&&!x.clipped),m.facts);
  if(name==='pending') check(`${width}: compact request action`,m.requestRows.every(r=>r.actionWidth===48),m.requestRows);
  return m;
}
async function shot(page,width,name){
  await page.screenshot({path:path.join(out,`${width}-${name}.png`),fullPage:true});
  // Real-time dwell for a readable recording, never a state/readiness barrier.
  if(width===390 && ['source-review','sending','pending','queued','uncertain-reload'].includes(name)) await page.waitForTimeout(900);
}
async function refresh(page){await page.reload();await page.locator('#state').filter({hasText:/Approval|offline|ended/}).waitFor();}
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const origin='http://127.0.0.1:'+server.address().port;
  const browser=await chromium.launch({headless:true});
  try {
    for(const width of [320,360,390]) {
      f=fixture();
      const context=await browser.newContext({viewport:{width,height:844},isMobile:true,hasTouch:true,colorScheme:'dark',...(width===390?{recordVideo:{dir:path.join(out,'video'),size:{width,height:844}}}:{})});
      try {
        await context.route('**/*',route=>new URL(route.request().url()).origin===origin?route.continue():route.abort());
        const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
        await page.goto(origin+'/join#jamId='+jamId+'&invite='+Buffer.alloc(32,1).toString('base64url'));
        await geometry(page,'join',width);await shot(page,width,'join');
        await page.locator('#name').fill('Nori');await page.locator('#name').press('Enter');await page.locator('#session').waitFor();
        check(`${width}: join strips invitation`,new URL(page.url()).hash==='');
        await geometry(page,'offered',width);await shot(page,width,'offered');
        // Keyboard activation, modal Escape, and return focus use actual controls.
        await page.locator('#filter').fill('Night Drive');check(`${width}: offered filter uses actual rows`,await page.locator('#catalog .track').count()===1);
        await page.locator('#filter').fill('');await page.locator('#filter').press('Tab');
        check(`${width}: Tab reaches row action`,await page.locator('#catalog button').first().evaluate(n=>n===document.activeElement));
        check(`${width}: keyboard focus has visible ink`,await page.locator('#catalog button').first().evaluate(n=>getComputedStyle(n).outlineStyle==='solid'&&getComputedStyle(n).outlineWidth==='3px'));
        await shot(page,width,'keyboard-focus');
        await page.keyboard.press('Enter');await page.locator('#review').waitFor();
        check(`${width}: exact offered facts in review`,(await page.locator('#review').textContent()).includes(title)&&(await page.locator('#review').textContent()).includes('4:01'));
        await geometry(page,'offered-review',width);await shot(page,width,'offered-review');await page.keyboard.press('Escape');
        check(`${width}: Escape restores action focus`,await page.locator('#catalog button').first().evaluate(n=>n===document.activeElement));
        // Ordinary 3s snapshot refresh must not drop a keyboard action's focus.
        await page.locator('#catalog button').first().focus();
        const gets=f.operations.filter(x=>x.method==='GET').length;
        await page.waitForFunction(()=>document.visibilityState==='visible');
        await new Promise((resolve,reject)=>{const start=Date.now();const tick=()=>f.operations.filter(x=>x.method==='GET').length>gets?resolve():Date.now()-start>6000?reject(Error('poll not observed')):setTimeout(tick,30);tick();});
        await page.waitForTimeout(100);
        check(`${width}: polling preserves keyboard row focus`,await page.locator('#catalog button').first().evaluate(n=>n===document.activeElement));
        await page.locator('#find-tab').click();await page.locator('#query').fill('Afterglow live');
        f.searchFailure=true;await page.locator('#search').click();await page.locator('#message').filter({hasText:'Search unavailable'}).waitFor();
        const searchBody=f.operations.filter(x=>x.route==='/search').at(-1).body;
        await geometry(page,'search-retry',width);await shot(page,width,'search-retry');
        const searchMeasure=measurements.at(-1);check(`${width}: usable search input beside compact action`,searchMeasure.search>=width-88,searchMeasure.search);
        f.searchFailure=false;await page.locator('#search').click();await page.locator('#results button').waitFor();
        check(`${width}: retry preserves search identity`,JSON.stringify(f.operations.filter(x=>x.route==='/search').at(-1).body)===JSON.stringify(searchBody));
        await page.locator('#results button').click();await page.locator('#review').waitFor();
        check(`${width}: full exact source facts`,(await page.locator('#review').textContent()).includes(title)&&(await page.locator('#review').textContent()).includes(source.sourceId));
        await geometry(page,'source-review',width);await shot(page,width,'source-review');
        await page.locator('#cancel-review').click();check(`${width}: cancel does not publish`,!f.operations.some(x=>x.route==='/source-requests'));
        await page.locator('#results button').click();
        let release;f.hold=new Promise(r=>release=r);await page.locator('#send-review').click();
        await page.locator('#pending-check').waitFor();check(`${width}: pending retry disabled while held`,await page.locator('#pending-check').isDisabled());await shot(page,width,'sending');
        release();f.hold=null;await page.locator('#message').filter({hasText:'Request sent.'}).waitFor();await page.locator('#requests .request-status').filter({hasText:'Waiting for host approval'}).waitFor();
        await geometry(page,'pending',width);await shot(page,width,'pending');
        for(const status of ['importing','ready','queued']) {
          f.requests[0].status=status;await refresh(page);
          await page.locator('#requests .request-status').filter({hasText:status==='queued'?'Added to host queue':status==='ready'?'Ready · waiting turn':'Importing'}).waitFor();
          await geometry(page,status,width);await shot(page,width,status);
        }
        check(`${width}: one explicit source publication`,f.operations.filter(x=>x.route==='/source-requests').length===1);
        check(`${width}: accepted reload retires checking caption`,!(await page.locator('#message').textContent()).includes('Checking your Jam'));
        f.requests=[];await refresh(page);await page.locator('#catalog button').first().click();f.lost=true;await page.locator('#send-review').click();
        await page.locator('#message').filter({hasText:'Request not confirmed'}).waitFor();
        const mutation=f.operations.filter(x=>x.route==='/requests'&&x.method==='POST').at(-1).body;
        await refresh(page);await page.locator('#pending-check').waitFor();
        check(`${width}: reload does not replay mutation`,f.operations.filter(x=>x.route==='/requests'&&x.method==='POST').length===1);
        await geometry(page,'uncertain-reload',width);await shot(page,width,'uncertain-reload');
        f.lost=false;await page.locator('#pending-check').click();await page.locator('#message').filter({hasText:'Request sent.'}).waitFor();
        check(`${width}: explicit retry uses exact mutation`,JSON.stringify(f.operations.filter(x=>x.route==='/requests'&&x.method==='POST').at(-1).body)===JSON.stringify(mutation));
        await page.locator('#requests button').first().click();await page.locator('#review').waitFor();await page.locator('#send-review').click();await page.locator('#requests .request-status').filter({hasText:'Withdrawn'}).waitFor();
        f.state='hostOffline';await refresh(page);check(`${width}: offline blocks request`,await page.locator('#catalog button').first().isDisabled());await shot(page,width,'offline');
        f.state='open';await refresh(page);await page.locator('#find-tab').click();f.expired=true;await page.locator('#query').fill('Expired recording');await page.locator('#search').click();await page.locator('#results button').waitFor();
        check(`${width}: expired source cannot submit`,await page.locator('#results button').isDisabled());await shot(page,width,'expired-source');
        f.state='ended';await refresh(page);check(`${width}: ended Jam blocks request`,await page.locator('#catalog button').first().isDisabled());await shot(page,width,'ended');
        f.deny=true;await page.reload();await page.locator('#message').filter({hasText:'Jam unavailable'}).waitFor();check(`${width}: revoked membership cleared`,await page.evaluate(()=>sessionStorage.getItem('soundq.jam.guest.v1')===null));await shot(page,width,'revoked');
        f=fixture();await page.goto(origin+'/join?fresh=1#jamId='+jamId+'&invite='+Buffer.alloc(32,1).toString('base64url'));f.deny=true;await page.locator('#join').click();await page.locator('#message').filter({hasText:'This invitation is unavailable'}).waitFor();await shot(page,width,'expired-invitation');
      } finally {await context.close();}
    }
  } finally {await browser.close();}
})().catch(e=>{failures.push({name:'runner',detail:e.stack});}).finally(()=>{
  server.close();check('no browser page errors',errors.length===0,errors);
  fs.writeFileSync(path.join(out,'result.json'),JSON.stringify({passed:failures.length===0,checks,failures,measurements,pageErrors:errors,boundary:'Current guest JS/CSS/HTML in fresh headless Chromium contexts with synthetic loopback HTTP fixture. Not Go, provider, native host, device, or production acceptance.'},null,2));
  console.log(JSON.stringify({passed:failures.length===0,checks:checks.length,failures},null,2));
  if(failures.length)process.exitCode=1;
});
