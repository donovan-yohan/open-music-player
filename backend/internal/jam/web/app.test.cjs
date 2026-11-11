const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto').webcrypto;
function boot(options={}) {
 const nodes=new Map();
 const node=()=>({textContent:'',hidden:false,disabled:false,value:'',children:[],events:{},addEventListener(name,callback){this.events[name]=callback},append(...x){this.children.push(...x)},replaceChildren(...x){this.children=x},setAttribute(){},focus(){},showModal(){this.open=true},close(){this.open=false}});
 const document={visibilityState:'visible',getElementById(id){if(!nodes.has(id)){nodes.set(id,node());if(id==='name')nodes.get(id).value='Listener'}return nodes.get(id)},createElement:node,addEventListener(){}};
 for(const id of fs.readFileSync(__dirname+'/index.html','utf8').matchAll(/id="([^"]+)"/g))document.getElementById(id[1]);
 const calls=[],hist=[];const token=Buffer.alloc(32,1).toString('base64url');
 const storage=options.storage||new Map();
 const context={document,crypto,URLSearchParams,TextEncoder,Uint8Array,AbortSignal,console,location:{hash:options.hash===undefined?'#jamId=00000000-0000-4000-8000-000000000001&invite='+token:options.hash,pathname:'/join'},history:{replaceState(...x){hist.push(x)}},sessionStorage:{getItem(k){return storage.get(k)||null},setItem(k,v){storage.set(k,v)},removeItem(k){storage.delete(k)}},setTimeout(){},clearTimeout(){},fetch:async(url,opt)=>{calls.push({url,opt});return {ok:true,status:201,json:async()=>({memberId:'00000000-0000-4000-8000-000000000003',memberExpiresAt:new Date(Date.now()+60000).toISOString(),snapshot:{version:1,state:'open',catalog:[{catalogItemId:'c',title:'<img onerror=alert(1)>',artist:'A'}],requests:[],nowPlaying:null}})}},btoa:s=>Buffer.from(s,'binary').toString('base64')};
 if(options.now)context.Date=class extends Date {static now(){return options.now}};
 vm.createContext(context);vm.runInContext(fs.readFileSync(__dirname+'/app.js','utf8')+'\n;globalThis.testApi={join,render,requestTrack,poll,searchMusic,openReview,sendReview,sendPending,withdrawRequest};',context);return {context,calls,hist,nodes,token,storage};
}
test('guest joins without account credentials and strips fragment',async()=>{const b=boot();await b.context.testApi.join();assert.equal(b.calls.length,1);assert.match(b.calls[0].url,/^\/api\/v1\/guest\/jams\//);assert.equal(b.calls[0].opt.credentials,'omit');assert.equal(b.calls[0].opt.headers.Authorization,undefined);const body=JSON.parse(b.calls[0].opt.body);assert.equal(Buffer.from(body.memberSecret,'base64url').length,32);assert.equal(body.joinToken,b.token);assert.equal(b.hist.at(-1)[2],'/join');assert.ok(!b.hist.at(-1)[2].includes(b.token));});
test('request uses member capability and opaque catalog identifier only',async()=>{const b=boot();await b.context.testApi.join();await b.context.testApi.requestTrack('c');assert.equal(b.calls.length,2);const c=b.calls[1];assert.match(c.url,/\/requests$/);assert.match(c.opt.headers.Authorization,/^Bearer /);assert.deepEqual(Object.keys(JSON.parse(c.opt.body)).sort(),['catalogItemId','expectedVersion','requestId']);});
test('catalog request is enabled after joining',async()=>{const b=boot();await b.context.testApi.join();const row=b.nodes.get('catalog').children[0];assert.equal(row.children.at(-1).disabled,false);});
test('polling leaves request controls enabled',async()=>{const b=boot();await b.context.testApi.join();b.context.fetch=async()=>({ok:true,status:200,json:async()=>({version:1,state:'open',catalog:[{catalogItemId:'c',title:'T',artist:'A'}],requests:[],nowPlaying:null})});await b.context.testApi.poll();assert.equal(b.nodes.get('catalog').children[0].children.at(-1).disabled,false);});
test('revoked capability disables request controls',async()=>{const b=boot();await b.context.testApi.join();b.context.fetch=async()=>({ok:false,status:403});await b.context.testApi.poll();assert.equal(b.nodes.get('catalog').children[0].children.at(-1).disabled,true);});
test('source has no HTML injection, durable origin-wide storage, account client or audio',()=>{const s=fs.readFileSync(__dirname+'/app.js','utf8');for(const unsafe of ['innerHTML','localStorage','/auth','/playback','new Audio','navigator.mediaDevices','document.cookie'])assert.ok(!s.includes(unsafe),unsafe);assert.match(s,/visibilityState/);assert.match(s,/30000/);assert.match(s,/textContent/);assert.match(s,/replaceState/);});
test('reload restores scoped membership without another join or invitation',async()=>{const first=boot();await first.context.testApi.join();const second=boot({storage:first.storage,hash:''});second.context.fetch=async(url,opt)=>{second.calls.push({url,opt});return {ok:true,status:200,json:async()=>({version:1,state:'open',catalog:[],requests:[],nowPlaying:null})}};await second.context.testApi.poll();assert.equal(second.calls.length,1);assert.equal(second.calls[0].opt.method,'GET');assert.match(second.calls[0].opt.headers.Authorization,/^Bearer /);assert.ok(!second.calls.some(c=>c.url.endsWith('/members')));});
test('lost Leave reply never claims confirmed departure',async()=>{const b=boot();await b.context.testApi.join();b.context.fetch=async()=>{throw new Error('response lost')};await b.nodes.get('leave').events.click();assert.notEqual(b.nodes.get('message').textContent,'You left the Jam.');assert.match(b.nodes.get('message').textContent,/checking|confirmed|leaving/i);});
test('definitive stale rejection releases only after an authoritative absent read',async()=>{
 const b=boot();await b.context.testApi.join();
 b.context.fetch=async()=>({ok:false,status:409});
 await b.context.testApi.requestTrack('c');
 b.context.fetch=async()=>({ok:true,status:200,json:async()=>({version:2,state:'open',catalog:[{catalogItemId:'c',title:'T',artist:'A'}],requests:[],nowPlaying:null})});
 await b.context.testApi.poll();
 const receipt=JSON.parse(b.storage.get('soundq.jam.guest.v1'));
 assert.equal(receipt.pending,null,'a definitive rejected request must not trap the tab in an impossible exact retry');
});
test('actual Go producer source readiness is visible but never called queued',()=>{
 const b=boot();const value=JSON.parse(fs.readFileSync(__dirname+'/../../api/testdata/jam-producer/guest-ready.json','utf8'));
 b.context.testApi.render(value);
 const flatten=n=>[n.textContent,...n.children.flatMap(flatten)].join(' ');
 const text=flatten(b.nodes.get('requests'));
 assert.match(text,/Afterglow \(live, synthetic\)/);
 assert.match(text,/Ready.*waiting turn/i);
 assert.doesNotMatch(text,/Added to host queue|Added on host/);
});
const producer=name=>JSON.parse(fs.readFileSync(__dirname+'/../../api/testdata/jam-producer/'+name+'.json','utf8'));
async function outsideResults(b) {
 b.nodes.get('query').value='Afterglow live';
 b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});return {ok:true,status:200,json:async()=>producer('search')}};
 await b.context.testApi.searchMusic();
}
test('outside search uses server capture and explicit exact-song review, not an import or catalog ID',async()=>{
 const b=boot({now:Date.parse(producer('guest-ready').serverTime)});await b.context.testApi.join();
 b.context.testApi.render({...producer('guest-ready'),requests:[]});b.nodes.get('query').value='Afterglow live';
 b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});return {ok:true,status:200,json:async()=>producer('search')}};
 await b.context.testApi.searchMusic();
 const search=b.calls.at(-1);assert.match(search.url,/\/search$/);assert.deepEqual(Object.keys(JSON.parse(search.opt.body)).sort(),['query','searchId']);
 const before=b.calls.length;await b.nodes.get('results').children[0].children.at(-1).events.click();
 assert.equal(b.calls.length,before,'review must not submit or acquire');assert.equal(b.nodes.get('review').open,true);
 assert.match(b.nodes.get('review-song').textContent,/Afterglow \(live, synthetic\)/);assert.match(b.nodes.get('review-facts').textContent,/YouTube.*3:01/);
 b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});throw new Error('lost reply')};
 await b.context.testApi.sendReview();
 const request=b.calls.at(-1);assert.match(request.url,/\/source-requests$/);
 const body=JSON.parse(request.opt.body),choice=producer('search').results[0];
 assert.deepEqual(Object.keys(body).sort(),['candidateId','expectedVersion','requestId','selectionSessionId']);
 assert.equal(body.candidateId,choice.candidateId);assert.equal(body.selectionSessionId,choice.selectionSessionId);
 assert.ok(!request.opt.body.includes('sourceUrl'));assert.ok(!b.calls.some(c=>/approval|download/.test(c.url)));
});
test('lost outside response survives reload with identical mutation, not provider replay',async()=>{
 const now=Date.parse(producer('guest-ready').serverTime),first=boot({now});await first.context.testApi.join();
 first.context.testApi.render({...producer('guest-ready'),requests:[]});await outsideResults(first);first.context.testApi.openReview({kind:'source',item:producer('search').results[0]});
 first.context.fetch=async(url,opt)=>{first.calls.push({url,opt});throw new Error('lost reply')};await first.context.testApi.sendReview();
 const original=first.calls.at(-1);const second=boot({now,storage:first.storage,hash:''});
 second.context.fetch=async(url,opt)=>{second.calls.push({url,opt});return {ok:true,status:200,json:async()=>({...producer('guest-ready'),requests:[]})}};
 await second.context.testApi.poll();assert.equal(second.calls.length,1);assert.equal(second.calls[0].opt.method,'GET');
 assert.ok(JSON.parse(second.storage.get('soundq.jam.guest.v1')).pending,'an absent read after an UNKNOWN write must not permit a new request');
 second.context.fetch=async(url,opt)=>{second.calls.push({url,opt});throw new Error('lost again')};await second.context.testApi.sendPending();
 assert.equal(second.calls.at(-1).url,original.url);assert.equal(second.calls.at(-1).opt.body,original.opt.body);
 assert.ok(!second.calls.some(c=>c.url.endsWith('/members')||c.url.endsWith('/search')));
});
test('search timeout retries the same identity; incomplete reservation needs another explicit search',async()=>{
 const b=boot();await b.context.testApi.join();b.context.testApi.render({...producer('guest-ready'),requests:[]});b.nodes.get('query').value='Afterglow';
 b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});throw new Error('lost')};await b.context.testApi.searchMusic();const first=b.calls.at(-1).opt.body;
 b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});return {ok:false,status:409}};await b.context.testApi.searchMusic();assert.equal(b.calls.at(-1).opt.body,first);
 const count=b.calls.length;assert.match(b.nodes.get('message').textContent,/Search again/);assert.equal(b.calls.length,count);
 await b.context.testApi.searchMusic();assert.notEqual(b.calls.at(-1).opt.body,first);
});
test('only a retained own request has withdrawal, and unknown DELETE retains exact identity after reload',async()=>{
 const b=boot();await b.context.testApi.join();await b.context.testApi.requestTrack('c');const requestId=JSON.parse(b.calls.at(-1).opt.body).requestId;
 const value={version:2,state:'open',catalog:[{catalogItemId:'c',title:'T',artist:'A'}],requests:[{requestId,catalogItemId:'c',displayName:'Me',status:'pending'},{requestId:'00000000-0000-4000-8000-000000000099',catalogItemId:'c',displayName:'Other',status:'pending'}],nowPlaying:null};
 b.context.testApi.render(value);assert.equal(b.nodes.get('requests').children[0].children.at(-1).textContent,'Withdraw');assert.equal(b.nodes.get('requests').children[1].children.length,1);
 b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});throw new Error('lost DELETE')};await b.context.testApi.withdrawRequest(requestId);
 const sent=b.calls.at(-1);assert.equal(sent.opt.method,'DELETE');assert.deepEqual(JSON.parse(sent.opt.body),{expectedVersion:2});
 const restored=boot({storage:b.storage,hash:''});restored.context.fetch=async()=>({ok:true,status:200,json:async()=>value});await restored.context.testApi.poll();
 restored.context.fetch=async(url,opt)=>{restored.calls.push({url,opt});throw new Error('lost again')};await restored.context.testApi.withdrawRequest(requestId);
 assert.equal(restored.calls.at(-1).url,sent.url);assert.equal(restored.calls.at(-1).opt.body,sent.opt.body);
});
test('expired source or offline host cannot submit a new source request',async()=>{
 const b=boot({now:Date.parse(producer('search').expiresAt)+1});await b.context.testApi.join();b.context.testApi.render({...producer('guest-ready'),requests:[]});
 await outsideResults(b);
 b.context.testApi.openReview({kind:'source',item:producer('search').results[0]});const n=b.calls.length;await b.context.testApi.sendReview();assert.equal(b.calls.length,n);assert.match(b.nodes.get('message').textContent,/expired/i);
 b.context.testApi.render({...producer('guest-ready'),state:'hostOffline',requests:[]});assert.equal(b.nodes.get('search').disabled,true);await b.context.testApi.sendReview();assert.equal(b.calls.length,n);
});
for(const failure of ['unavailable','lost'])test(`replacement search ${failure} retires old results/review before dispatch and reload retains exact B`,async()=>{
 const now=Date.parse(producer('guest-ready').serverTime),b=boot({now});await b.context.testApi.join();
 const value={...producer('guest-ready'),requests:[]};b.context.testApi.render(value);await outsideResults(b);
 const staleAction=b.nodes.get('results').children[0].children.at(-1).events.click;
 staleAction();assert.equal(b.nodes.get('review').open,true);
 b.nodes.get('query').value='Different recording';let release,fail;
 b.context.fetch=(url,opt)=>{b.calls.push({url,opt});return new Promise((resolve,reject)=>{release=resolve;fail=reject})};
 const work=b.context.testApi.searchMusic();
 const sent=b.calls.at(-1),saved=JSON.parse(b.storage.get('soundq.jam.guest.v1'));
 assert.equal(b.nodes.get('results').children.length,0,'A must retire as soon as B is allocated, before provider response');
 assert.equal(b.nodes.get('review').open,false,'held A review must retire with its search');
 assert.equal(saved.searchReply,null);assert.deepEqual(saved.searchAttempt,JSON.parse(sent.opt.body));
 if(failure==='lost')fail(new Error('B response lost'));else release({ok:false,status:503});
 await work;staleAction();await b.context.testApi.sendReview();
 assert.equal(b.nodes.get('review').open,false);assert.ok(!b.calls.some(c=>c.url.endsWith('/source-requests')));
 const retained=JSON.parse(b.storage.get('soundq.jam.guest.v1'));assert.equal(retained.memberSecret,saved.memberSecret);
 assert.deepEqual(retained.searchAttempt,saved.searchAttempt);assert.equal(retained.searchReply,null);
 // Also quarantine an old-version tab receipt that retained A alongside B.
 const legacyStorage=new Map(b.storage),legacy={...retained,searchReply:producer('search'),searchQuery:'Afterglow live'};
 legacyStorage.set('soundq.jam.guest.v1',JSON.stringify(legacy));
 const restored=boot({now,storage:legacyStorage,hash:''});restored.context.testApi.render(value);
 assert.equal(restored.nodes.get('results').children.length,0);assert.equal(restored.nodes.get('query').value,'Different recording');
 restored.context.fetch=async(url,opt)=>{restored.calls.push({url,opt});return {ok:false,status:503}};
 await restored.context.testApi.searchMusic();assert.equal(restored.calls.at(-1).opt.body,sent.opt.body);
 assert.ok(!restored.calls.some(c=>c.url.endsWith('/members')||c.url.endsWith('/source-requests')));
});
for(const revoked of [false,true])test(`source binding 403 waits for authoritative membership read; revoked=${revoked}`,async()=>{
 const now=Date.parse(producer('guest-ready').serverTime),b=boot({now});await b.context.testApi.join();
 const value={...producer('guest-ready'),requests:[]};b.context.testApi.render(value);await outsideResults(b);
 b.context.testApi.openReview({kind:'source',item:producer('search').results[0]});
 b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});return {ok:false,status:403}};
 await b.context.testApi.sendReview();const sent=b.calls.at(-1),raw=b.storage.get('soundq.jam.guest.v1');
 assert.ok(raw,'a source rejection alone does not establish capability retirement');
 const saved=JSON.parse(raw);assert.equal(saved.pending.rejected,true);assert.equal(saved.searchReply,null);
 const restored=boot({now,storage:b.storage,hash:''});
 restored.context.fetch=async()=>{throw new Error('membership read unavailable')};await restored.context.testApi.poll();
 assert.deepEqual(JSON.parse(restored.storage.get('soundq.jam.guest.v1')).pending,saved.pending);
 restored.context.fetch=async(url,opt)=>{restored.calls.push({url,opt});return revoked?{ok:false,status:403}:{ok:true,status:200,json:async()=>value}};
 await restored.context.testApi.poll();assert.equal(restored.calls.length,1);assert.equal(restored.calls[0].opt.method,'GET');
 assert.ok(!restored.calls.some(c=>c.url.endsWith('/source-requests')||c.url.endsWith('/members')));
 if(revoked){assert.equal(restored.storage.has('soundq.jam.guest.v1'),false);assert.equal(restored.nodes.get('search').disabled,true)}
 else {const confirmed=JSON.parse(restored.storage.get('soundq.jam.guest.v1'));assert.equal(confirmed.memberSecret,saved.memberSecret);assert.equal(confirmed.pending,null);
  // The definitive rejection was confirmed absent, so its ID no longer occupies the receipt.
  assert.equal(confirmed.ownRequestIds.includes(JSON.parse(sent.opt.body).requestId),false)}
});
test('search denial while host offline does not retire valid membership or exact retry',async()=>{
 const now=Date.parse(producer('guest-ready').serverTime),b=boot({now});await b.context.testApi.join();
 const value={...producer('guest-ready'),requests:[]};b.context.testApi.render(value);await outsideResults(b);
 b.nodes.get('query').value='Different recording';b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});return {ok:false,status:403}};
 await b.context.testApi.searchMusic();const sent=b.calls.at(-1),saved=JSON.parse(b.storage.get('soundq.jam.guest.v1'));
 assert.ok(saved.memberSecret);assert.equal(saved.searchReply,null);
 b.context.fetch=async()=>({ok:true,status:200,json:async()=>({...value,state:'hostOffline'})});await b.context.testApi.poll();
 assert.equal(JSON.parse(b.storage.get('soundq.jam.guest.v1')).memberSecret,saved.memberSecret);assert.equal(b.nodes.get('search').disabled,true);
 b.context.testApi.render(value);b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});return {ok:false,status:503}};
 await b.context.testApi.searchMusic();assert.equal(b.calls.at(-1).opt.body,sent.opt.body);
});
test('withdrawal denial reconciles member validity without erasing a valid tab',async()=>{
 const b=boot();await b.context.testApi.join();await b.context.testApi.requestTrack('c');const requestId=JSON.parse(b.calls.at(-1).opt.body).requestId;
 const value={version:2,state:'open',catalog:[],requests:[{requestId,displayName:'Me',status:'queued'}],nowPlaying:null};b.context.testApi.render(value);
 b.context.fetch=async()=>({ok:false,status:403});await b.context.testApi.withdrawRequest(requestId);
 assert.ok(b.storage.has('soundq.jam.guest.v1'));b.context.fetch=async()=>({ok:true,status:200,json:async()=>value});await b.context.testApi.poll();
 const saved=JSON.parse(b.storage.get('soundq.jam.guest.v1'));assert.ok(saved.memberSecret);assert.equal(saved.withdrawal,null);
 assert.match(b.nodes.get('message').textContent,/Already added/);
});
test('acknowledged request feedback does not contradict later approval import readiness or canonical queue status',async()=>{
 const b=boot();await b.context.testApi.join();await b.context.testApi.requestTrack('c');
 const requestId=JSON.parse(b.calls.at(-1).opt.body).requestId;
 assert.equal(b.nodes.get('message').textContent,'Request sent.');
 for(const status of ['approved','importing','ready','queued']) {
  b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});return {ok:true,status:200,json:async()=>({version:2,state:'open',catalog:[{catalogItemId:'c',title:'T',artist:'A'}],requests:[{requestId,catalogItemId:'c',displayName:'Me',status}],nowPlaying:null})}};
  await b.context.testApi.poll();
  assert.doesNotMatch(b.nodes.get('message').textContent,/waiting for host approval/i,status);
  assert.equal(b.calls.filter(c=>c.url.endsWith('/requests')&&c.opt.method==='POST').length,1);
 }
});
test('accepted membership read retires stale startup or reconnect paint without changing neutral request feedback',async()=>{
 const b=boot();await b.context.testApi.join();
 b.context.fetch=async()=>({ok:true,status:200,json:async()=>({version:2,state:'open',catalog:[],requests:[],nowPlaying:null})});
 for(const caption of ['Checking your Jam…','Connection interrupted. Reconnecting…']) {
  b.nodes.get('message').textContent=caption;await b.context.testApi.poll();assert.equal(b.nodes.get('message').textContent,'');
 }
 b.nodes.get('message').textContent='Request sent.';await b.context.testApi.poll();assert.equal(b.nodes.get('message').textContent,'Request sent.');
});
test('a denied held join offers a fresh invitation without replaying or discarding it implicitly',async()=>{
 const first=boot();first.context.fetch=async(url,opt)=>{first.calls.push({url,opt});return {ok:false,status:403}};
 await first.context.testApi.join();const held=JSON.parse(first.calls.at(-1).opt.body);
 const fresh=Buffer.alloc(32,2).toString('base64url'),freshJam='00000000-0000-4000-8000-000000000002';
 const second=boot({storage:first.storage,hash:'#jamId='+freshJam+'&invite='+fresh});
 assert.equal(second.nodes.get('use-invite').hidden,false,'the fresh invitation must be offered');
 assert.match(second.nodes.get('message').textContent,/new invitation/);
 second.context.fetch=async(url,opt)=>{second.calls.push({url,opt});return {ok:false,status:403}};
 await second.context.testApi.join();
 assert.equal(second.calls.at(-1).opt.body,first.calls.at(-1).opt.body,'Join still retries the exact held payload');
 assert.match(second.calls.at(-1).url,/000000000001\/members$/);
 await second.nodes.get('use-invite').events.click();
 assert.equal(second.nodes.get('use-invite').hidden,true);
 await second.context.testApi.join();
 const switched=JSON.parse(second.calls.at(-1).opt.body);
 assert.match(second.calls.at(-1).url,new RegExp(freshJam+'/members$'));
 assert.equal(switched.joinToken,fresh);assert.notEqual(switched.requestId,held.requestId);
});
test('an unresolved source request blocks a replacement search until it is reconciled',async()=>{
 const now=Date.parse(producer('guest-ready').serverTime),b=boot({now});await b.context.testApi.join();
 b.context.testApi.render({...producer('guest-ready'),requests:[]});await outsideResults(b);
 b.context.testApi.openReview({kind:'source',item:producer('search').results[0]});
 b.context.fetch=async(url,opt)=>{b.calls.push({url,opt});throw new Error('lost reply')};await b.context.testApi.sendReview();
 assert.equal(JSON.parse(b.storage.get('soundq.jam.guest.v1')).pending.kind,'source');
 assert.equal(b.nodes.get('search').disabled,true,'search control stays disabled');
 b.nodes.get('query').value='Different recording';const before=b.calls.length;
 await b.context.testApi.searchMusic();
 assert.equal(b.calls.length,before,'no replacement search may be reserved');
 assert.equal(JSON.parse(b.storage.get('soundq.jam.guest.v1')).searchAttempt,null);
});
test('IDs a membership read shows absent are retired before the receipt limit applies',async()=>{
 const first=boot();await first.context.testApi.join();
 const receipt=JSON.parse(first.storage.get('soundq.jam.guest.v1'));
 receipt.ownRequestIds=Array.from({length:50},(_,i)=>'00000000-0000-4000-8000-'+String(i).padStart(12,'0'));
 first.storage.set('soundq.jam.guest.v1',JSON.stringify(receipt));
 const value={version:3,state:'open',catalog:[{catalogItemId:'c',title:'T',artist:'A'}],requests:[{requestId:receipt.ownRequestIds[7],catalogItemId:'c',displayName:'Me',status:'declined'}],nowPlaying:null};
 const second=boot({storage:first.storage,hash:''});
 second.context.fetch=async(url,opt)=>{second.calls.push({url,opt});return {ok:true,status:200,json:async()=>value}};
 await second.context.testApi.poll();
 assert.deepEqual(JSON.parse(second.storage.get('soundq.jam.guest.v1')).ownRequestIds,[receipt.ownRequestIds[7]]);
 await second.context.testApi.requestTrack('c');
 assert.match(second.calls.at(-1).url,/\/requests$/,'a valid request must still be sent');
});
