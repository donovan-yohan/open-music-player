#!/usr/bin/env python3
"""Source-extracted Android credential lifetime regression, not device proof.
Freshly compiles actual command/save/load/login/logout/select/startPlayer and
focus listener. Hardware/Android/JSON transport boundary stubs only; actual JCE
AES/GCM encryption/decryption and restart-shaped preference readback execute.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import subprocess
import sys
from test_toolchain import java_home, android_jar, kotlin_compiler

ROOT = Path(__file__).resolve().parents[2]
OUT = Path(os.environ['SOUNDQ_REPAIR_OUTPUT'])
WORK = Path(os.environ['TMPDIR']) / 'android-adapter'
WORK.mkdir(parents=True, exist_ok=True)
JAVA = java_home()
SDK = android_jar()
source = (ROOT / 'native/android/app/src/main/java/com/soundq/nativepreview/PlaybackService.kt').read_text()

def block(start):
    a = source.index(start)
    opening = source.index('{', a)
    depth = 0
    for i in range(opening, len(source)):
        if source[i] == '{':
            depth += 1
        elif source[i] == '}':
            depth -= 1
            if depth == 0:
                result = source[a:i + 1]
                if start == 'private fun loadCredentials(':
                    result += ' catch (_: Exception) { null }'
                return result
    raise AssertionError('unclosed block')

j = subprocess.run([str(JAVA/'bin/javap'), '-constants', '-classpath', str(SDK), 'android.media.AudioManager'], capture_output=True, text=True, check=True)
constants = {k: int(v) for k, v in re.findall(r'public static final int (AUDIOFOCUS_(?:LOSS(?:_TRANSIENT(?:_CAN_DUCK)?)?|GAIN|REQUEST_GRANTED)) = (-?\d+);', j.stdout)}
assert constants['AUDIOFOCUS_LOSS'] == -1 and constants['AUDIOFOCUS_LOSS_TRANSIENT'] == -2 and constants['AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK'] == -3
start = source.index('.setOnAudioFocusChangeListener({ change ->')
end = source.index('}, main).build()', start)
focus = source[start:end].split('change ->', 1)[1]
methods = '\n'.join(block(x) for x in ['fun command(', 'fun login(', 'fun logout(', 'fun select(', 'private fun saveCredentials(', 'private fun loadCredentials(', 'private fun startPlayer(', 'private fun abandonFocus(', 'private fun stopPlaybackService(', 'private fun failPlayback(', 'private fun showNotification('])
# JSONObject is a typed transport stub: strings are registered in-memory rather
# than parsed; identical credential bytes pass through real encryption/readback.
harness = r'''import java.util.ArrayDeque
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import javax.crypto.spec.GCMParameterSpec
import java.util.Base64 as JBase64
class JSONObject {
    val values = linkedMapOf<String,Any>()
    constructor()
    constructor(text:String) { values.putAll(registry.getValue(text)) }
    fun put(k:String,v:Any):JSONObject {values[k]=v;return this}
    fun optString(k:String):String = values[k] as? String ?: ""
    fun optLong(k:String):Long = (values[k] as? Number)?.toLong() ?: 0L
    fun optBoolean(k:String):Boolean = values[k] as? Boolean ?: false
    fun optJSONObject(k:String):JSONObject? = values[k] as? JSONObject
    fun optJSONArray(k:String):JSONArray? = values[k] as? JSONArray
    fun remove(k:String):Any? = values.remove(k)
    override fun toString():String {val text=values.toString();registry[text]=LinkedHashMap(values);return text}
    companion object {val registry=mutableMapOf<String,Map<String,Any>>()}
}
class JSONArray
object Base64 {
    const val NO_WRAP=2
    fun encodeToString(b:ByteArray,f:Int):String=JBase64.getEncoder().encodeToString(b)
    fun decode(s:String,f:Int):ByteArray=JBase64.getDecoder().decode(s)
}
class ManualQueue {
    val tasks=ArrayDeque<() -> Unit>()
    fun execute(f:() -> Unit) {tasks.add(f)}
    fun post(f:() -> Unit) {tasks.add(f)}
    fun one() {check(tasks.isNotEmpty());tasks.removeFirst().invoke()}
    fun drain() {var n=0;while(tasks.isNotEmpty()) {check(n++<100);one()}}
}
class Preferences {
    val stored=mutableMapOf<String,String>()
    var commits=0
    var fail=false
    fun getString(k:String,d:String?):String?=stored[k] ?: d
    fun edit()=Editor(this)
    class Editor(val prefs:Preferences) {
        val pending=mutableMapOf<String,String>();var cleared=false
        fun clear():Editor {cleared=true;return this}
        fun putString(k:String,v:String):Editor {pending[k]=v;return this}
        fun commit():Boolean {if(prefs.fail)return false;if(cleared)prefs.stored.clear();prefs.stored.putAll(pending);prefs.commits++;return true}
    }
}
object AudioManager {__CONSTANTS__}
class Audio {
    var requests=0
    fun requestAudioFocus(focus:Int):Int {requests++;return AudioManager.AUDIOFOCUS_REQUEST_GRANTED}
    fun abandonAudioFocusRequest(focus:Int) {}
}
class Player {var isPlaying=false;fun pause(){isPlaying=false};fun start(){isPlaying=true}}
// Only Android platform boundaries are facades. Foreground ownership, failure
// retirement and notification policy below are extracted production methods.
fun JSONArray.optJSONObject(i:Int):JSONObject?=null
class PlaybackService
class MainActivity
class Intent(a:Any,b:Class<*>) {fun setAction(s:String)=this}
class PendingIntent {companion object {const val FLAG_UPDATE_CURRENT=1;const val FLAG_IMMUTABLE=2;fun getService(a:Any,b:Int,c:Intent,d:Int)=PendingIntent();fun getForegroundService(a:Any,b:Int,c:Intent,d:Int)=PendingIntent();fun getActivity(a:Any,b:Int,c:Intent,d:Int)=PendingIntent()}}
object android {object R {object drawable {const val ic_media_play=1;const val ic_media_pause=2}}}
class Notification {class Builder(a:Any,b:String){fun setSmallIcon(v:Int)=this;fun setContentTitle(v:String)=this;fun setContentText(v:String)=this;fun setContentIntent(v:PendingIntent)=this;fun setOngoing(v:Boolean)=this;fun addAction(v:Action)=this;fun setStyle(v:MediaStyle)=this;fun build()=Notification()};class Action{class Builder(a:Int,b:String,c:PendingIntent){fun build()=Action()}};class MediaStyle{fun setMediaSession(v:Int)=this;fun setShowActionsInCompactView(v:Int)=this}}
class Session {val sessionToken=1}
class Bridge {
    var current=1L
    val calls=mutableListOf<JSONObject>()
    val replies=ArrayDeque<JSONObject>()
    fun revoke(handle:Long):Long {current++;return current}
    fun execute(handle:Long,epoch:Long,raw:String):String {
        calls.add(JSONObject(raw))
        if(replies.isNotEmpty()) return replies.removeFirst().toString()
        return JSONObject().put("ok",true).put("snapshot",JSONObject().put("epoch",epoch)).toString()
    }
}
class Adapter(val prefs:Preferences=Preferences()) {
    val worker=ManualQueue();val main=ManualQueue();val bridge=Bridge();val core=1L
    var epoch=1L;var credentialEpoch=1L;var storedCredentialVersion=0L;var transportIntent=0L
    var busy=0;var wantsPlayback=false;var playerReady=true;var player:Player?=Player()
    var pendingReports=false;var snapshot=JSONObject();var listener:((JSONObject,String?)->Unit)?=null
    var focusHeld=true;var nativeTerminalState:String?=null;val audio=Audio();val focus=1
    var foreground=false;var notificationIdentity="";val session=Session()
    val STOP_FOREGROUND_REMOVE=1;var admissions=0;var notifications=0;var stops=0
    var denyAdmission=false;var denyNotification=false;val reports=mutableListOf<String?>()
    fun startForegroundService(i:Intent){admissions++;if(denyAdmission)throw IllegalStateException("synthetic refusal")}
    fun startForeground(id:Int,n:Notification){notifications++;if(denyNotification)throw SecurityException("synthetic refusal")}
    fun stopForeground(mode:Int){}
    fun stopSelf(){stops++}
    val endpoint="synthetic-endpoint";val MODE_PRIVATE=0;var errors=0
    fun getSharedPreferences(n:String,m:Int)=prefs
    fun key()=SecretKeySpec(ByteArray(16){7},"AES")
    fun retireAudio(){wantsPlayback=false}
    fun library(){}
    fun applyAudio(e:JSONObject){}
    fun updateSession(){}
    fun report(s:String?=null){reports.add(s)}
    fun deliver(version:Long=1,account:String="A") {
        val credentials=JSONObject().put("version",version).put("account_id",account).put("access_token","synthetic-access-$version").put("refresh_token","synthetic-refresh-$version")
        bridge.replies.add(JSONObject().put("ok",true).put("snapshot",JSONObject().put("epoch",epoch)).put("credentials",credentials))
        command(JSONObject().put("command","snapshot"));worker.one();main.one()
    }
    fun runAll(){var n=0;while(worker.tasks.isNotEmpty()||main.tasks.isNotEmpty()){check(n++<100);worker.drain();main.drain()}}
    fun readSaved()=loadCredentials()
    fun focusChange(change:Int) {__FOCUS__}
    __METHODS__
}
fun case(name:String,f:()->Unit):Boolean = try {f();println("PASS $name");true} catch(e:Throwable){println("FAIL $name ${e.javaClass.simpleName}");false}
fun main() {
    var failed=0
    fun test(n:String,f:()->Unit) {if(!case(n,f))failed++}
    test("uninterrupted-restart-store-readback") {
        val a=Adapter();a.deliver();a.runAll();val restart=Adapter(a.prefs)
        check(restart.readSaved()?.optString("refresh_token")=="synthetic-refresh-1")
    }
    test("selection-before-encryption-keeps-rotation") {
        val a=Adapter();a.deliver();a.select(42);a.runAll()
        check(Adapter(a.prefs).readSaved()?.optString("refresh_token")=="synthetic-refresh-1")
    }
    test("selection-after-encryption-held-main-keeps-rotation") {
        val a=Adapter();a.deliver();a.worker.drain();a.select(42);a.runAll()
        check(Adapter(a.prefs).readSaved()?.optString("refresh_token")=="synthetic-refresh-1")
    }
    for(after in listOf(false,true)) {
        test("logout-retires-store-$after") {
            val a=Adapter();a.deliver();if(after)a.worker.drain();a.logout();a.runAll()
            check(Adapter(a.prefs).readSaved()==null)
        }
        test("account-switch-retires-store-$after") {
            val a=Adapter();a.deliver();if(after)a.worker.drain();a.login("synthetic","dummy");a.runAll()
            check(Adapter(a.prefs).readSaved()==null)
            a.deliver(2,"B");a.runAll();check(Adapter(a.prefs).readSaved()?.optString("account_id")=="B")
        }
    }
    test("restart-restore-does-not-forward-private-version-as-command-field") {
        val a=Adapter();a.deliver();a.runAll();val restart=Adapter(a.prefs)
        restart.command(restart.readSaved()!!.put("command","restore"));restart.runAll()
        check(restart.bridge.calls.first().optLong("version")==0L)
    }
    test("serial-newest-rotation-wins-and-durable-ack") {
        val a=Adapter();a.deliver(1);a.runAll();a.deliver(2);a.runAll()
        check(Adapter(a.prefs).readSaved()?.optLong("version")==2L)
        check(a.bridge.calls.filter{it.optString("command")=="acknowledge_credentials"}.map{it.optLong("version")}==listOf(1L,2L))
    }
    test("failed-store-never-acknowledged-and-redelivery-recovers") {
        val a=Adapter();a.prefs.fail=true;a.deliver();a.runAll()
        check(a.bridge.calls.none{it.optString("command")=="acknowledge_credentials"})
        a.prefs.fail=false;a.deliver();a.runAll()
        check(Adapter(a.prefs).readSaved()!=null)
    }
    test("reentrant-account-change-during-snapshot-listener") {
        val a=Adapter();var once=true;a.listener={_,_->if(once){once=false;a.login("synthetic","dummy")}}
        a.deliver();a.runAll();check(Adapter(a.prefs).readSaved()==null)
    }
    test("focus-loss-still-pauses-local-player-under-command-backpressure") {
        val a=Adapter();a.busy=32;a.wantsPlayback=true;a.player!!.start()
        a.focusChange(AudioManager.AUDIOFOCUS_LOSS)
        check(!a.wantsPlayback && !a.player!!.isPlaying && !a.focusHeld)
    }
    for(loss in listOf(AudioManager.AUDIOFOCUS_LOSS,AudioManager.AUDIOFOCUS_LOSS_TRANSIENT,AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK)) {
        test("focus-loss-$loss-pauses-retires-focus-explicit-resume") {
            val a=Adapter();a.wantsPlayback=true;a.player!!.start();a.focusChange(loss)
            check(!a.focusHeld && !a.wantsPlayback && !a.player!!.isPlaying)
            a.runAll();check(a.bridge.calls.count{it.optString("command")=="pause"}==1)
            a.focusChange(AudioManager.AUDIOFOCUS_GAIN);a.runAll()
            check(!a.wantsPlayback && !a.player!!.isPlaying)
            a.command(JSONObject().put("command","resume"));a.startForTest()
            check(a.audio.requests==1 && a.player!!.isPlaying)
        }
    }
    test("production-lifecycle-admits-notification-and-retires-on-pause") {
        val a=Adapter();a.command(JSONObject().put("command","resume"));a.startForTest()
        check(a.admissions==1 && a.notifications==2 && a.foreground && a.player!!.isPlaying)
        a.command(JSONObject().put("command","pause"))
        check(!a.foreground && !a.focusHeld && !a.player!!.isPlaying && a.stops>0)
    }
    for(denial in listOf("admission","notification")) test("platform-refusal-$denial-reaches-production-failure-retirement") {
        val a=Adapter();a.denyAdmission=denial=="admission";a.denyNotification=denial=="notification"
        a.command(JSONObject().put("command","resume"));a.startForTest();a.runAll()
        check(a.admissions==1 && a.notifications==(if(denial=="notification")1 else 0))
        check(!a.foreground && !a.focusHeld && !a.wantsPlayback && !a.player!!.isPlaying)
        check(a.audio.requests==0 && a.stops==1 && a.reports==listOf("failed") && a.bridge.calls.isEmpty())
    }
    for(after in listOf(false,true)) test("transport-cancellation-keeps-account-rotation-$after") {
        val a=Adapter();a.deliver();if(after)a.worker.drain()
        a.command(JSONObject().put("command","pause"));a.command(JSONObject().put("command","resume"));a.runAll()
        check(Adapter(a.prefs).readSaved()?.optString("refresh_token")=="synthetic-refresh-1")
        check(a.bridge.calls.any{it.optString("command")=="acknowledge_credentials"})
    }
    test("transport-refusal-keeps-account-rotation") {
        val a=Adapter();a.deliver();a.denyNotification=true;a.command(JSONObject().put("command","resume"));a.runAll()
        check(Adapter(a.prefs).readSaved()?.optString("refresh_token")=="synthetic-refresh-1")
        check(a.bridge.calls.any{it.optString("command")=="acknowledge_credentials"})
    }
    check(failed==0){"$failed invariant cases failed"}
}
'''
# Only package qualifier adaptation, identical for RED/GREEN.
methods = methods.replace('org.json.JSONArray()', 'JSONArray()')
harness = harness.replace('__CONSTANTS__', '\n'.join(f'const val {k}={v}' for k,v in constants.items())).replace('__FOCUS__',focus).replace('__METHODS__',methods+'\nfun startForTest(){startPlayer()}')
kt=WORK/'AdapterInvariants.kt';kt.write_text(harness)
env={'PATH':os.environ.get('PATH',os.defpath),'HOME':str(WORK),'JAVA_HOME':str(JAVA),'TMPDIR':str(WORK),'JAVA_TOOL_OPTIONS':'-XX:ActiveProcessorCount=2'}
for name,argv in [('compile',[kotlin_compiler(),str(kt),'-nowarn','-include-runtime','-d',str(WORK/'adapter.jar')]),('run',[str(JAVA/'bin/java'),'-jar',str(WORK/'adapter.jar')])]:
    p=subprocess.run(argv,cwd=WORK,env=env,capture_output=True,text=True,timeout=120)
    (OUT/f'android-{name}.log').write_text(p.stdout+p.stderr)
    print(p.stdout+p.stderr)
    if p.returncode:
        sys.exit(p.returncode)
print('BOUNDED_ANDROID_INVARIANTS_PASS sourceSha256='+hashlib.sha256(source.encode()).hexdigest())
