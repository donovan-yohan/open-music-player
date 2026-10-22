const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const crypto = require('node:crypto').webcrypto;
function boot() {
 const nodes=new Map();
 const node=()=>({textContent:'',hidden:false,disabled:false,value:'Listener',children:[],addEventListener(){},append(...x){this.children.push(...x)},replaceChildren(...x){this.children=x}});
 const document={visibilityState:'visible',getElementById(id){if(!nodes.has(id))nodes.set(id,node());return nodes.get(id)},createElement:node,addEventListener(){}};
 const calls=[],hist=[];const token=Buffer.alloc(32,1).toString('base64url');
 const context={document,crypto,URLSearchParams,TextEncoder,Uint8Array,AbortSignal,console,location:{hash:'#jamId=00000000-0000-4000-8000-000000000001&invite='+token,pathname:'/join'},history:{replaceState(...x){hist.push(x)}},setTimeout(){},clearTimeout(){},fetch:async(url,opt)=>{calls.push({url,opt});return {ok:true,status:201,json:async()=>({memberId:'m',memberExpiresAt:new Date(Date.now()+60000).toISOString(),snapshot:{version:1,state:'open',catalog:[{catalogItemId:'c',title:'<img onerror=alert(1)>',artist:'A'}],requests:[],nowPlaying:null}})}},btoa:s=>Buffer.from(s,'binary').toString('base64')};
 vm.createContext(context);vm.runInContext(fs.readFileSync(__dirname+'/app.js','utf8')+'\n;globalThis.testApi={join,render,requestTrack,poll};',context);return {context,calls,hist,nodes,token};
}
test('guest joins without account credentials and strips fragment',async()=>{const b=boot();await b.context.testApi.join();assert.equal(b.calls.length,1);assert.match(b.calls[0].url,/^\/api\/v1\/guest\/jams\//);assert.equal(b.calls[0].opt.credentials,'omit');assert.equal(b.calls[0].opt.headers.Authorization,undefined);const body=JSON.parse(b.calls[0].opt.body);assert.equal(Buffer.from(body.memberSecret,'base64url').length,32);assert.equal(body.joinToken,b.token);assert.equal(b.hist.at(-1)[2],'/join');assert.ok(!b.hist.at(-1)[2].includes(b.token));});
test('request uses member capability and opaque catalog identifier only',async()=>{const b=boot();await b.context.testApi.join();await b.context.testApi.requestTrack('c');assert.equal(b.calls.length,2);const c=b.calls[1];assert.match(c.url,/\/requests$/);assert.match(c.opt.headers.Authorization,/^Bearer /);assert.deepEqual(Object.keys(JSON.parse(c.opt.body)).sort(),['catalogItemId','expectedVersion','requestId']);});
test('catalog request is enabled after joining',async()=>{const b=boot();await b.context.testApi.join();const row=b.nodes.get('catalog').children[0];assert.equal(row.children[1].disabled,false);});
test('polling leaves request controls enabled',async()=>{const b=boot();await b.context.testApi.join();b.context.fetch=async()=>({ok:true,status:200,json:async()=>({version:1,state:'open',catalog:[{catalogItemId:'c',title:'T',artist:'A'}],requests:[],nowPlaying:null})});await b.context.testApi.poll();assert.equal(b.nodes.get('catalog').children[0].children[1].disabled,false);});
test('revoked capability disables request controls',async()=>{const b=boot();await b.context.testApi.join();b.context.fetch=async()=>({ok:false,status:403});await b.context.testApi.poll();assert.equal(b.nodes.get('catalog').children[0].children[1].disabled,true);});
test('source has no HTML injection, persistence, account client or audio',()=>{const s=fs.readFileSync(__dirname+'/app.js','utf8');for(const unsafe of ['innerHTML','localStorage','sessionStorage','/auth','/playback','new Audio','navigator.mediaDevices','document.cookie'])assert.ok(!s.includes(unsafe),unsafe);assert.match(s,/visibilityState/);assert.match(s,/30000/);assert.match(s,/textContent/);assert.match(s,/replaceState/);});
