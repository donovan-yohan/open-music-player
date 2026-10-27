#!/usr/bin/env python3
"""Compose actual Rust ABI/HTTP rotation with extracted Android storage caller.
Requires android_adapter_invariants.py to have freshly emitted its harness.
Uses only JDK JCE/HTTP and read-only Android SDK Gson; no production dependency.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from test_toolchain import java_home, gson_jar, kotlin_compiler
sys.path.insert(0, os.environ['SOUNDQ_REPAIR_PROBES'])
import repair_support as p
OUT=Path(os.environ['SOUNDQ_REPAIR_OUTPUT'])
WORK=Path(tempfile.mkdtemp(prefix='composed-credentials-',dir=os.environ['TMPDIR']))
JAVA=java_home()
GSON = gson_jar()
text=(OUT/'AdapterInvariants.kt').read_text()
a=text.index('class JSONObject {');b=text.index('object Base64 {',a)
text=text[:a]+'''class JSONObject {
    val data:com.google.gson.JsonObject
    constructor(){data=com.google.gson.JsonObject()}
    constructor(raw:String){data=com.google.gson.JsonParser.parseString(raw).asJsonObject}
    fun put(k:String,v:Any):JSONObject {data.add(k,when(v){is JSONObject->v.data;is JSONArray->v.data;else->com.google.gson.Gson().toJsonTree(v)});return this}
    fun optString(k:String):String=if(data[k]?.isJsonNull!=false) "" else data[k].asString
    fun optLong(k:String,d:Long=0L):Long=if(data[k]?.isJsonNull!=false) d else data[k].asLong
    fun optBoolean(k:String):Boolean=if(data[k]?.isJsonNull!=false) false else data[k].asBoolean
    fun optJSONObject(k:String):JSONObject?=if(data[k]?.isJsonObject==true) JSONObject(data[k].toString()) else null
    fun optJSONArray(k:String):JSONArray?=if(data[k]?.isJsonArray==true) JSONArray(data[k].asJsonArray) else null
    fun remove(k:String)=data.remove(k)
    override fun toString()=data.toString()
}
class JSONArray(val data:com.google.gson.JsonArray=com.google.gson.JsonArray()) {fun length()=data.size();fun getJSONObject(i:Int)=JSONObject(data[i].toString())}
'''+text[b:]
a=text.index('class Bridge {');b=text.index('class Adapter(',a)
text=text[:a]+'''fun wire(route:String,body:String="{}"):String {
    val connection=java.net.URI(System.getenv("REPAIR_RELAY")+route).toURL().openConnection() as java.net.HttpURLConnection
    connection.requestMethod="POST";connection.doOutput=true;connection.connectTimeout=3000;connection.readTimeout=10000
    connection.outputStream.use{it.write(body.toByteArray())}
    return connection.inputStream.bufferedReader().use{it.readText()}
}
class Bridge {
    val replies=ArrayDeque<JSONObject>()
    val calls=mutableListOf<JSONObject>()
    fun revoke(handle:Long):Long=wire("/revoke").toLong()
    fun execute(handle:Long,epoch:Long,raw:String):String {
        calls.add(JSONObject(raw))
        return wire("/execute",JSONObject().put("epoch",epoch).put("command",JSONObject(raw)).toString())
    }
}
'''+text[b:]
a=text.index('fun main() {')
text=text[:a]+'''fun main() {
    val a=Adapter()
    a.command(JSONObject().put("command","restore").put("account_id","synthetic-account").put("access_token","synthetic-original-access").put("refresh_token","synthetic-original-refresh"));a.runAll()
    a.command(JSONObject().put("command","library").put("offset",0).put("query","").put("sort","title").put("order","asc"));a.runAll()
    wire("/hold")
    a.command(JSONObject().put("command","library").put("offset",0).put("query","").put("sort","title").put("order","asc"))
    val read=Thread {a.worker.one()};read.start();wire("/wait")
    a.select(1);wire("/release");read.join(5000);check(!read.isAlive)
    a.main.drain()
    // Selection receives the pending rotation. Positively hold the adapter
    // before encryption, then change selection a second time.
    a.worker.one();a.main.one();a.select(1);a.runAll()
    val stored=Adapter(a.prefs).readSaved()
    check(stored?.optString("refresh_token")=="synthetic-refresh-2") {"composed core rotation was lost before secure storage"}
    check(a.bridge.calls.any{it.optString("command")=="acknowledge_credentials"}) {"durable storage never acknowledged"}
    println("PASS composed-held-HTTP-selection-encryption-restart-readback")
    a.logout();a.runAll();check(Adapter(a.prefs).readSaved()==null)
    println("PASS composed-logout-no-account-revival")
}
'''
with p.Server() as server, tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
    h=p.new_core(server,tmp)
    class Relay(BaseHTTPRequestHandler):
        def log_message(self,format,*args):pass
        def do_POST(self):
            raw=self.rfile.read(int(self.headers.get('Content-Length',0)))
            if self.path=='/execute':
                v=json.loads(raw);result=p.take(p.C.sq_core_execute(h,v['epoch'],json.dumps(v['command']).encode()))
                if result.get('code') == 'invalid_command' and 'account_scope_v1' in v['command']:
                    # Predecessor discovery adaptation only: invalid_command did
                    # not dispatch a mutation. Identical fallback in RED/GREEN.
                    v['command'].pop('account_scope_v1')
                    result=p.take(p.C.sq_core_execute(h,v['epoch'],json.dumps(v['command']).encode()))
                body=json.dumps(result).encode()
            elif self.path=='/revoke':body=str(p.C.sq_core_revoke(h)).encode()
            elif self.path=='/hold':server.want401=True;server.hold_library=True;body=b'{}'
            elif self.path=='/wait':
                assert server.entered.wait(5);assert server.refreshes==2;body=b'{}'
            elif self.path=='/release':server.hold_library=False;server.release.set();body=b'{}'
            else:raise AssertionError('unexpected relay route')
            self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
    relay=ThreadingHTTPServer(('127.0.0.1',0),Relay)
    thread=threading.Thread(target=relay.serve_forever,daemon=True);thread.start()
    try:
        kt=WORK/'Composed.kt';kt.write_text(text)
        env={'PATH':os.environ.get('PATH',os.defpath),'HOME':str(WORK),'JAVA_HOME':str(JAVA),'TMPDIR':str(WORK),'JAVA_TOOL_OPTIONS':'-XX:ActiveProcessorCount=2','REPAIR_RELAY':f'http://127.0.0.1:{relay.server_port}'}
        for name,argv in [('compile',[kotlin_compiler(),str(kt),'-classpath',str(GSON),'-nowarn','-include-runtime','-d',str(WORK/'composed.jar')]),('run',[str(JAVA/'bin/java'),'-cp',str(WORK/'composed.jar')+os.pathsep+str(GSON),'ComposedKt'])]:
            result=subprocess.run(argv,cwd=WORK,env=env,capture_output=True,text=True,timeout=120)
            (OUT/f'composed-{name}.log').write_text(result.stdout+result.stderr)
            print(result.stdout+result.stderr)
            if result.returncode:sys.exit(result.returncode)
        assert server.refreshes==2
        print('COMPOSED_PASS realRustABI=true realJCE=true refreshes=2 gsonSha256='+hashlib.sha256(GSON.read_bytes()).hexdigest())
    finally:
        server.release.set();relay.shutdown();relay.server_close();thread.join(3);p.C.sq_core_close(h)
