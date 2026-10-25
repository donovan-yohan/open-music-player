#!/usr/bin/env python3
"""Real Rust/Gson/extracted Android queue and storage-error composition.

Requires repair_support environment and test_toolchain discovery/overrides.
Only synthetic loopback IO and fake physical decoder/OS boundaries; no device.
"""
from pathlib import Path
import json
import os
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import repair_support as p
import native_review_regressions as probes
from test_toolchain import java_home, kotlin_compiler, gson_jar

ROOT = Path(os.environ.get('SOUNDQ_QUEUE_SOURCE_ROOT', Path(__file__).resolve().parents[2]))


def main():
    harness = probes.android_probe(ROOT, probes.swift_block)
    a = harness.index('class JSONObject {'); b = harness.index('class Queue ', a)
    harness = harness[:a] + '''class JSONObject {
val data:com.google.gson.JsonObject
constructor(){data=com.google.gson.JsonObject()};constructor(raw:String){data=com.google.gson.JsonParser.parseString(raw).asJsonObject}
fun put(k:String,v:Any):JSONObject{data.add(k,when(v){is JSONObject->v.data;is JSONArray->v.data;else->com.google.gson.Gson().toJsonTree(v)});return this}
fun optString(k:String):String=if(data[k]?.isJsonNull!=false)"" else data[k].asString
fun getString(k:String)=optString(k);fun optLong(k:String,d:Long=0L):Long=if(data[k]?.isJsonNull!=false)d else data[k].asLong;fun getLong(k:String)=optLong(k)
fun optBoolean(k:String):Boolean=if(data[k]?.isJsonNull!=false)false else data[k].asBoolean
fun optJSONObject(k:String):JSONObject?=if(data[k]?.isJsonObject==true)JSONObject(data[k].toString()) else null
fun optJSONArray(k:String):JSONArray?=if(data[k]?.isJsonArray==true)JSONArray(data[k].asJsonArray) else null
fun remove(k:String)=data.remove(k);override fun toString()=data.toString()
}
class JSONArray(val data:com.google.gson.JsonArray=com.google.gson.JsonArray()){fun length()=data.size();fun getJSONObject(i:Int)=JSONObject(data[i].toString());fun optJSONObject(i:Int):JSONObject?=if(i<data.size() && data[i].isJsonObject)JSONObject(data[i].toString()) else null}
''' + harness[b:]
    a = harness.index('class Bridge {'); b = harness.index('class PlaybackService {', a)
    harness = harness[:a] + '''fun wire(route:String,body:String="{}"):String {
val connection=java.net.URI(System.getenv("SOUNDQ_QUEUE_RELAY")+route).toURL().openConnection() as java.net.HttpURLConnection
connection.requestMethod="POST";connection.doOutput=true;connection.connectTimeout=3000;connection.readTimeout=10000
connection.outputStream.use{it.write(body.toByteArray())};return connection.inputStream.bufferedReader().use{it.readText()}
}
class Bridge {val calls=mutableListOf<JSONObject>();var last=JSONObject()
fun revoke(c:Long):Long=wire("/revoke").toLong()
fun execute(c:Long,e:Long,raw:String):String{calls.add(JSONObject(raw));val reply=wire("/execute",JSONObject().put("epoch",e).put("command",JSONObject(raw)).toString());last=JSONObject(reply);return reply}
}
''' + harness[b:]
    harness = harness[:harness.index('fun main(){')] + '''fun main(){
val a=PlaybackService();val errors=mutableListOf<String>();a.listener={_,code->if(code!=null)errors.add(code)}
a.command(JSONObject().put("command","restore").put("access_token","synthetic-access").put("refresh_token","synthetic-refresh").put("account_id","synthetic-account"));a.drain()
a.command(JSONObject().put("command","library").put("offset",0).put("query","").put("sort","title").put("order","asc"));a.drain()
a.select(1);a.drain();val first=a.player!!;first.prepared!!(first);a.drain();check(first.isPlaying)
val occurrence=a.snapshot.optLong("selected_occurrence");val session=a.snapshot.optLong("session")
a.queueAction("queue_append",1L);a.drain();val duplicate=a.snapshot.optJSONArray("queue")!!.getJSONObject(1).getLong("id")
check(duplicate!=occurrence && a.player===first && a.snapshot.optLong("session")==session)
a.queueAction("queue_move",duplicate,0);a.drain();check(a.selectedTrack()?.getLong("id")==1L && a.player===first)
a.queueAction("queue_move",duplicate,1);a.drain();first.isPlaying=false;val starts=events.count{it=="foreground-admission"}
val retained=first.completion!!;retained(first);a.drain();val second=a.player!!;second.prepared!!(second);a.drain()
check(a.snapshot.optLong("selected_occurrence")==duplicate && second!==first && first.released && second.isPlaying && a.foreground)
check(events.count{it=="foreground-admission"}==starts);retained(first);a.drain();check(a.snapshot.optLong("selected_occurrence")==duplicate)
println("PASS real-Rust-Android-duplicate-reorder-EOF-one-advance-admitted-foreground")
a.command(JSONObject().put("command","pause"));a.drain();a.queueAction("queue_remove",duplicate);a.drain();val replacement=a.player!!;replacement.prepared!!(replacement);a.drain()
check(a.snapshot.optLong("selected_occurrence")==occurrence && replacement.isPlaying && a.foreground)
println("PASS real-Rust-Android-selected-remove-foreground-before-load")
a.command(JSONObject().put("command","pause"));a.command(JSONObject().put("command","resume"));a.drain();check(replacement.isPlaying && a.foreground)
println("PASS real-Rust-Android-preserved-Pause-Resume-transport-intent")
wire("/corrupt")
a.queueAction("queue_play",occurrence);a.drain()
val reply=a.bridge.last;check(!reply.optBoolean("ok") && reply.optString("code")=="invalid_saved_queue")
check(reply.optJSONObject("audio")?.optString("action")=="load" && reply.optJSONObject("audio")?.optLong("session")==a.snapshot.optLong("session"))
val afterStorage=a.player!!;afterStorage.prepared!!(afterStorage);a.drain()
check(errors.contains("invalid_saved_queue") && a.snapshot.optString("error")=="invalid_saved_queue"){"storage failure was hidden"}
check(afterStorage.isPlaying && a.foreground && a.wantsPlayback && a.focusHeld && a.snapshot.optString("transport")=="playing"){"storage error suppressed explicit queue playback despite retained current load effect"}
println("PASS real-Rust-Android-visible-storage-error-retains-current-load-playing-foreground")
a.queueAction("queue_clear");a.drain();check(a.player==null && a.snapshot.optJSONArray("queue")!!.length()==0 && !a.foreground)
println("PASS real-Rust-Android-clear-stops-and-empties")
}
'''
    with tempfile.TemporaryDirectory(prefix='queue-composition-', dir=p.OUT/'tmp') as tmp, p.Server() as server:
        work = Path(tmp); kt = work/'QueueComposition.kt'; kt.write_text(harness)
        core = p.new_core(server, work/'cache')
        class Relay(BaseHTTPRequestHandler):
            def log_message(self, format, *args): pass
            def do_POST(self):
                raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                if self.path == '/revoke':
                    body = str(p.C.sq_core_revoke(core)).encode()
                elif self.path == '/execute':
                    value = json.loads(raw)
                    body = json.dumps(p.take(p.C.sq_core_execute(core, value['epoch'], json.dumps(value['command']).encode()))).encode()
                elif self.path == '/corrupt':
                    next((work/'cache').rglob('listening-queue-v1.json')).write_bytes(b'{broken'); body = b'{}'
                else:
                    self.send_error(404); return
                self.send_response(200); self.send_header('Content-Length', str(len(body)))
                self.end_headers(); self.wfile.write(body)
        relay = ThreadingHTTPServer(('127.0.0.1', 0), Relay)
        thread = threading.Thread(target=relay.serve_forever, daemon=True); thread.start()
        try:
            env = dict(os.environ, JAVA_HOME=str(java_home()), JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2', SOUNDQ_QUEUE_RELAY=f'http://127.0.0.1:{relay.server_port}')
            for argv in ([kotlin_compiler(), str(kt), '-classpath', str(gson_jar()), '-nowarn', '-include-runtime', '-d', str(work/'probe.jar')],
                         [str(java_home()/'bin/java'), '-cp', str(work/'probe.jar')+os.pathsep+str(gson_jar()), 'QueueCompositionKt']):
                result = subprocess.run(argv, env=env, timeout=120)
                assert result.returncode == 0, f'composition stage exit {result.returncode}'
            assert server.downloads == 1 and server.descriptors == 1
            assert next((work/'cache').rglob('listening-queue-v1.json')).read_bytes() == b'{broken'
            print('PASS real-Rust-Android-one-descriptor-download-and-rejected-bytes-preserved')
        finally:
            relay.shutdown(); relay.server_close(); thread.join(3); p.C.sq_core_close(core)


if __name__ == '__main__': main()
