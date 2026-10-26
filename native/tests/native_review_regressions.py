#!/usr/bin/env python3
"""Device-free #500 regressions with explicitly separated tool boundaries.

Default: Python-only packaging/JDK probes (no compiler, SDK, device or network).
--compiled: additionally run real SwiftPM linking with Cargo metadata and a tiny
C ABI library, plus extracted production Swift/Kotlin probes; requires an
explicitly allocated build lane and SOUNDQ_RUST_BIN. No app packaging/launch.
This is NOT Android OS/decoder acceptance or a full platform build.
"""
import argparse
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


class BuildProvenance(unittest.TestCase):
    def exercise(self, platform, target_kind, java=None, override=None, resources=True):
        with tempfile.TemporaryDirectory(prefix="native-review-", dir=os.environ.get("TMPDIR")) as tmp:
            root = Path(tmp) / "source with spaces"
            root.mkdir()
            native = root / "native"
            core = native / "core"
            core.mkdir(parents=True)
            (core / "Cargo.toml").write_text("[package]\nname='facade-only'\n")
            target = {"default": core / "target", "absolute": Path(tmp) / "absolute target", "relative": root / "relative target", "configured": root / "config target"}[target_kind]
            suffix = "release/libsoundq_core.dylib" if platform == "macos" else "aarch64-linux-android/release/libsoundq_core.so"
            stale = core / "target" / suffix
            stale.parent.mkdir(parents=True)
            stale.write_bytes(b"POISON-OLD-CORE")
            calls = []
            owned = native / "artifacts/SoundQ Native Preview.app/Contents/Resources/SoundQNative_SoundQNative.bundle"
            owned.mkdir(parents=True)
            (owned / "stale.txt").write_bytes(b"STALE-REMOVED-RESOURCE")
            (owned.parent / "unrelated.txt").write_bytes(b"UNRELATED-RESOURCE")
            environment = {"PATH": os.defpath, "HOME": str(root), "SOUNDQ_RUST_BIN": str(root / "rust"), "SOUNDQ_GRADLE": "fake-gradle"}
            if target_kind in ("absolute", "relative"):
                environment["CARGO_TARGET_DIR"] = str(target) if target_kind == "absolute" else "relative target"
            if target_kind == "configured":
                (root / ".cargo").mkdir()
                (root / ".cargo/config.toml").write_text('[build]\ntarget-dir = "config target"\n')
            if java is not None:
                environment["JAVA_HOME"] = java
            if override is not None:
                environment["SOUNDQ_JAVA_HOME"] = override

            def command(argv, **kwargs):
                argv = [str(a) for a in argv]
                calls.append((argv, dict(kwargs.get("env", {})), str(kwargs.get("cwd"))))
                if Path(argv[0]).name == "cargo":
                    self.assertEqual(kwargs["cwd"], root)
                    self.assertIn(str(core / "Cargo.toml"), argv)
                    if "metadata" in argv:
                        self.assertIn("--no-deps", argv)
                        return subprocess.CompletedProcess(argv, 0, json.dumps({"target_directory": str(target)}).encode())
                    if "build" in argv:
                        fresh = target / suffix
                        fresh.parent.mkdir(parents=True, exist_ok=True)
                        fresh.write_bytes(b"FRESH-CURRENT-CORE")
                if Path(argv[0]).name == "swift":
                    binary = native / "macos/.build/release/SoundQNative"
                    binary.parent.mkdir(parents=True)
                    binary.write_bytes(b"FACADE-SWIFT-EXECUTABLE")
                    if resources:
                        resource = binary.parent / "SoundQNative_SoundQNative.bundle/Resources/probe.txt"
                        resource.parent.mkdir(parents=True)
                        resource.write_bytes(b"FRESH-RESOURCES")
                return subprocess.CompletedProcess(argv, 0, b"")

            module = runpy.run_path(str(ROOT / "scripts/native-client"), run_name="native_client_under_test")
            module["main"].__globals__.update(ROOT=root, NATIVE=native)
            with patch.dict(os.environ, environment, clear=True), patch.object(sys, "platform", "darwin"), patch.object(sys, "argv", ["native-client", platform, "--evidence", str(root / "receipts")]), patch.object(Path, "home", return_value=root), patch.object(subprocess, "run", side_effect=command), patch.object(subprocess, "check_output", return_value="facade:\n\told/libsoundq_core.dylib (compatibility version 0.0.0)\n"):
                if platform == "macos" and not resources:
                    with self.assertRaisesRegex(SystemExit, "missing required SwiftPM"):
                        module["main"]()
                    self.assertFalse(any(Path(a[0]).name == "codesign" for a, _, _ in calls))
                    return
                module["main"]()
            packaged = native / ("artifacts/SoundQ Native Preview.app/Contents/Frameworks/libsoundq_core.dylib" if platform == "macos" else "android/app/src/main/jniLibs/arm64-v8a/libsoundq_core.so")
            self.assertEqual(packaged.read_bytes(), b"FRESH-CURRENT-CORE", "packaged stale default-target library")
            if platform == "macos":
                resource = native / "artifacts/SoundQ Native Preview.app/Contents/Resources/SoundQNative_SoundQNative.bundle/Resources/probe.txt"
                self.assertTrue(resource.is_file(), "packaged app omitted its required resource bundle")
                self.assertEqual(resource.read_bytes(), b"FRESH-RESOURCES")
                self.assertFalse((owned / "stale.txt").exists(), "removed resource survived incremental package")
                self.assertEqual((owned.parent / "unrelated.txt").read_bytes(), b"UNRELATED-RESOURCE")
            receipts = list((root / "receipts").glob("*.json"))
            self.assertTrue(receipts)
            self.assertTrue(all(json.loads(p.read_text())["exitCode"] == 0 for p in receipts))
            if platform == "macos":
                swift = next(argv for argv, _, _ in calls if Path(argv[0]).name == "swift")
                if target_kind != "default":
                    self.assertIn("-L" + str(target / "release"), swift, "Swift must search the effective Cargo library output")
                for tool in ("install_name_tool", "codesign"):
                    self.assertTrue(any(Path(a[0]).name == tool for a, _, _ in calls))
            else:
                actual_java = next(env["JAVA_HOME"] for argv, env, _ in calls if argv[0] == "fake-gradle")
                expected_java = override or java or "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
                self.assertEqual(actual_java, expected_java, "explicit JDK was overwritten")

    def test_effective_output_macos(self):
        for kind in ("default", "absolute", "relative", "configured"):
            with self.subTest(target=kind):
                self.exercise("macos", kind)

    def test_missing_resources_refuses_before_signing(self):
        self.exercise("macos", "default", resources=False)

    def test_effective_output_android(self):
        for kind in ("default", "absolute", "relative", "configured"):
            with self.subTest(target=kind):
                self.exercise("android", kind)

    def test_jdk_precedence(self):
        for java, override in ((None, None), ("/explicit JDK", None), ("/explicit JDK", "/SoundQ JDK"), (None, "/SoundQ JDK")):
            with self.subTest(java=java, override=override):
                self.exercise("android", "default", java, override)


def swift_block(source, start):
    begin = source.index(start)
    opening = source.index("{", begin)
    depth = 0
    for index in range(opening, len(source)):
        depth += (source[index] == "{") - (source[index] == "}")
        if depth == 0:
            return source[begin:index + 1]
    raise AssertionError("unclosed production block")


class SwiftCoreLink(unittest.TestCase):
    def test_real_manifest_links_effective_core_across_cached_target_switches(self):
        """Real Cargo metadata/SwiftPM/linker; only the Rust ABI producer is tiny C.

        Stop the production wrapper before app packaging. Inspect and execute the
        linked CLI, so copying a fresh dylib cannot hide linking an old one.
        """
        import shutil
        rust = Path(os.environ["SOUNDQ_RUST_BIN"])
        with tempfile.TemporaryDirectory(prefix="native-review-link-", dir=os.environ.get("TMPDIR")) as tmp:
            root = Path(tmp).resolve() / "source with spaces"
            core = root / "native/core"
            package = root / "native/macos"
            (core / "include").mkdir(parents=True)
            (package / "Sources").mkdir(parents=True)
            shutil.copytree(ROOT / "native/macos/CBridge", package / "CBridge")
            shutil.copy2(ROOT / "native/macos/Package.swift", package / "Package.swift")
            shutil.copytree(ROOT / "native/macos/Sources/Resources", package / "Sources/Resources")
            shutil.copy2(ROOT / "native/core/include/soundq_core.h", core / "include/soundq_core.h")
            (core / "src").mkdir()
            (core / "src/lib.rs").write_text("pub fn metadata_only() {}\n")
            (core / "Cargo.toml").write_text('[package]\nname="link-probe"\nversion="0.1.0"\nedition="2021"\n')
            (core / "Cargo.lock").write_text('version = 4\n[[package]]\nname = "link-probe"\nversion = "0.1.0"\n')
            (package / "Sources/main.swift").write_text('import SoundQCore\nprint(sq_core_abi_version())\n')
            cargo_home = Path(tmp) / "cargo home"
            cargo_home.mkdir()
            env = {"PATH": str(rust) + os.pathsep + os.defpath, "HOME": str(Path(tmp)),
                   "TMPDIR": tmp, "CARGO_HOME": str(cargo_home), "CARGO_NET_OFFLINE": "true",
                   "SOUNDQ_RUST_BIN": str(rust), "CARGO_BUILD_JOBS": "2"}
            real_run = subprocess.run
            binary = package / ".build/release/SoundQNative"
            default = core / "target"
            module = runpy.run_path(str(ROOT / "scripts/native-client"), run_name="link_wrapper_under_test")
            module["main"].__globals__.update(ROOT=root, NATIVE=root / "native")

            def invoke(argv, child_env=env, cwd=root):
                result = real_run([str(a) for a in argv], env=child_env, cwd=cwd, capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result.stdout

            def library(target, value):
                dest = target / "release/libsoundq_core.dylib"
                dest.parent.mkdir(parents=True, exist_ok=True)
                c = Path(tmp) / "core.c"
                c.write_text(f'#include <stdint.h>\nuint32_t sq_core_abi_version(void) {{ return {value}; }}\n')
                invoke(["/usr/bin/clang", "-dynamiclib", c, "-Wl,-install_name," + str(dest), "-o", dest])
                return dest

            def verify(expected, value, kind):
                linked = invoke(["/usr/bin/otool", "-L", binary])
                self.assertIn(str(expected), linked, f"{kind}: linked stale core:\n{linked}")
                self.assertEqual(invoke([binary]).strip(), str(value), f"{kind}: executed stale ABI")
                print(f"PASS real-swift-link-{kind} abi={value}")

            # Manual SwiftPM builds retain the original relative default contract.
            manual = library(default, 101)
            invoke(["/usr/bin/swift", "build", "--package-path", package, "-c", "release", "--jobs", "2",
                    "-Xswiftc", "-num-threads", "-Xswiftc", "2"])
            verify(manual, 101, "manual-default")
            # The next wrapper build is cold; all subsequent changes reuse .build
            # and the manifest cache, with identical manifest/source bytes.
            shutil.rmtree(package / ".build")
            config = root / ".cargo/config.toml"
            for index, kind in enumerate(("absolute-cold", "absolute-switch", "relative", "configured", "default"), 201):
                with self.subTest(target=kind):
                    child_env = dict(env)
                    if config.exists():
                        config.unlink()
                    if kind.startswith("absolute"):
                        selected = Path(tmp).resolve() / (kind + " target")
                        child_env["CARGO_TARGET_DIR"] = str(selected)
                    elif kind == "relative":
                        selected = root / "relative target"
                        child_env["CARGO_TARGET_DIR"] = "relative target"
                    elif kind == "configured":
                        selected = root / "configured target"
                        config.parent.mkdir(exist_ok=True)
                        config.write_text('[build]\ntarget-dir = "configured target"\n')
                    else:
                        selected = default
                    library(default, 999)
                    expected = selected / "release/libsoundq_core.dylib"
                    reached = []

                    class LinkedBeforePackaging(Exception):
                        pass

                    def command(argv, **kwargs):
                        if Path(str(argv[0])).name == "cargo" and "build" in argv:
                            library(selected, index)
                            return subprocess.CompletedProcess(argv, 0, b"")
                        if Path(str(argv[0])).name == "swift":
                            reached.append(dict(kwargs["env"]))
                            # Run SwiftPM itself, including the real manifest and
                            # environment supplied by the production wrapper.
                            limited = [*argv, "-Xswiftc", "-num-threads", "-Xswiftc", "2"]
                            result = real_run(limited, **kwargs)
                            self.assertEqual(result.returncode, 0, result.stdout.decode())
                            verify(expected, index, kind)
                            raise LinkedBeforePackaging()
                        return real_run(argv, **kwargs)

                    with patch.dict(os.environ, child_env, clear=True), patch.object(sys, "argv", ["native-client", "macos"]), patch.object(subprocess, "run", side_effect=command):
                        with self.assertRaises(LinkedBeforePackaging):
                            module["main"]()
                    self.assertEqual(len(reached), 1)


class SwiftReporting(unittest.TestCase):
    def compile_run(self, source, args=(), expected=0):
        with tempfile.TemporaryDirectory(prefix="native-review-swift-", dir=os.environ.get("TMPDIR")) as tmp:
            path = Path(tmp)
            (path / "main.swift").write_text(source)
            built = subprocess.run(["/usr/bin/swiftc", "-j", "2", "-num-threads", "2", str(path / "main.swift"), "-o", str(path / "probe")], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(path / "probe"), *args], capture_output=True, text=True)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            return result.stdout

    def test_busy_failure_survives_next_tick_and_stale_item_retires(self):
        source = (ROOT / "native/macos/Sources/main.swift").read_text()
        report = swift_block(source, "func report(state:")
        harness = r'''import Foundation
struct Clock { var seconds: Double }
enum Status {case failed, readyToPlay}
class Item {var status:Status = .readyToPlay;var duration=Clock(seconds:30)}
class Player {var currentItem:Item?=Item();var error:String?;var rate:Float=0;var time=Clock(seconds:1);func currentTime()->Clock {time}}
struct Snapshot {var queue=[1];var session:UInt64=1;var position_ms:UInt64=800;var duration_ms:UInt64=30000;var transport="playing"}
class MPNowPlayingInfoCenter {enum State {case playing,paused};var playbackState:State = .paused;static let shared=MPNowPlayingInfoCenter();static func `default`()->MPNowPlayingInfoCenter{shared}}
class App {
var player:Player?=Player();var snapshot:Snapshot?=Snapshot();var reportPending=false;var busy=0;var epoch:UInt64=1
var reports=[[String:Any]]()
func command(_ value:[String:Any],completion:(()->Void)?=nil){reports.append(value);completion?()}
__REPORT__
}
func require(_ value:Bool,_ message:String){if !value {print(message);exit(1)}}
let a=App();a.busy=1;a.player!.currentItem!.status = .failed;a.report(state:"failed")
require(a.reports.isEmpty,"busy report was not coalesced");a.busy=0;a.reportPending=true;a.report(state:"failed");require(a.reports.isEmpty,"pending report was not coalesced");a.reportPending=false;a.report()
require(a.reports.last?["state"] as? String == "failed","failed item silently became paused on next tick")
a.player=Player();a.snapshot!.session=2;a.report()
require(a.reports.last?["state"] as? String == "paused","retired item failure crossed selection")
a.player!.currentItem!.status = .failed;a.player!.time.seconds = .nan;a.player!.currentItem!.duration.seconds = .nan;a.report()
require(a.reports.last?["state"] as? String == "failed","nonfinite failed item was dropped")
require(a.reports.last?["position_ms"] as? UInt64 == 800,"failure lost last valid position")
a.player!.time.seconds = .infinity;a.player!.currentItem!.duration.seconds = .infinity;a.report();require(a.reports.last?["state"] as? String == "failed","infinite failure was dropped")
print("PASS busy-item-failure next-tick stale-selection nonfinite-failure")
'''.replace("__REPORT__", report)
        self.compile_run(harness)

    def test_queue_selection_intent_and_noncurrent_decoder_identity(self):
        source = (ROOT / 'native/macos/Sources/main.swift').read_text()
        queue = swift_block(source, 'func queueCommand(')
        command = swift_block(source, 'func command(')
        intent = command[command.index('        if ["select"'):command.index('        var scopedValue')]
        harness = r'''import Foundation
struct Occurrence {let id:UInt64}
struct Snapshot {var queue=[Occurrence(id:11),Occurrence(id:12)];var selected_occurrence:UInt64?=11}
class Player {var retired=false;func pause(){};func replaceCurrentItem(with:Any?){retired=true}}
class Bridge {var epoch:UInt64=1;func revoke()->UInt64{epoch+=1;return epoch}}
class App {var snapshot:Snapshot?=Snapshot();var player:Player?=Player();var observation:Int?;var epoch:UInt64=1;var bridge=Bridge();var wantsPlayback=false;var sent=[[String:Any]]()
func closeQueueName(){};func retireLibraryDetails(){}
func command(_ value:[String:Any]) {let kind=value["command"] as? String ?? ""
__INTENT__
sent.append(value)}
__QUEUE__
}
let a=App();let old=a.player!;a.queueCommand("queue_remove",id:11)
precondition(a.wantsPlayback && old.retired && a.player==nil && a.epoch==2,"selected removal did not establish explicit playback intent")
let b=App();let current=b.player!;b.queueCommand("queue_move",id:12,index:0);b.queueCommand("queue_remove",id:12)
precondition(b.player===current && !current.retired && b.epoch==1,"noncurrent edit retired decoder")
print("PASS Swift-selected-remove-intent noncurrent-decoder-identity")
'''.replace('__INTENT__', intent).replace('__QUEUE__', queue)
        self.compile_run(harness)

    def test_fixture_completion_process_status_and_cleanup(self):
        source = (ROOT / "native/macos/Sources/FixtureJourney.swift").read_text()
        tail = source[source.index('            self.player?.pause();self.observation = nil;'):]
        tail = tail[:tail.rfind('\n        }')]
        harness = r'''import Foundation
import Darwin
class Player {func pause(){print("PAUSE")};func replaceCurrentItem(with:Any?){print("RETIRE")}}
class Bridge {func revoke()->UInt64 {print("REVOKE");return 2};deinit{print("CLOSE")}}
class Application {func terminate(_ value:Any?){print("TERMINATE");exit(0)}}
let NSApp=Application()
class App {
var player:Player?=Player();var observation:Int?=1;var bridge:Bridge?=Bridge();var timer:Timer?
func finishPhaseMeasurement(passed:Bool,code:String? = nil)->Bool {passed}
func applicationWillTerminate(_ notification:Notification){timer?.invalidate();player?.pause();observation=nil;player?.replaceCurrentItem(with:nil);player=nil;_ = bridge?.revoke()}
func finish(){
let samples=[[String:Any]]();let checks=["synthetic"];let started=ProcessInfo.processInfo.systemUptime
var outcome=CommandLine.arguments[1];let failure:String?=outcome == "failed" ? "synthetic assertion" : nil
__TAIL__
}
}
App().finish()
'''.replace("__TAIL__", tail)
        for outcome, expected in (("passed", 0), ("failed", 1)):
            with self.subTest(outcome=outcome):
                text = self.compile_run(harness, [outcome], expected)
                self.assertIn("PAUSE", text)
                self.assertIn("RETIRE", text)
                if "self.bridge = nil" in tail:
                    self.assertIn("REVOKE", text)
                    self.assertIn("CLOSE", text)
        with tempfile.TemporaryDirectory(prefix="native-review-report-", dir=os.environ.get("TMPDIR")) as tmp:
            with patch.dict(os.environ, {"SOUNDQ_NATIVE_JOURNEY_REPORT": str(Path(tmp) / "missing/report.json")}):
                self.compile_run(harness, ["passed"], 1)


def android_probe(root, extract):
    source = (root / 'native/android/app/src/main/java/com/soundq/nativepreview/PlaybackService.kt').read_text()
    methods = '\n'.join(extract(source, start) for start in [
        'fun command(', 'fun select(', 'private fun applyAudio(', 'private fun startPlayer(',
        'private fun abandonFocus(', 'private fun retireAudio(', 'private fun report(',
        *[name for name in ('fun selectedTrack(', 'fun queueAction(', 'private fun stopPlaybackService(', 'private fun failPlayback(') if name in source],
        'private fun showNotification(', 'override fun onStartCommand('])
    methods = methods.replace('org.json.JSONArray()', 'JSONArray()').replace('override fun onStartCommand', 'fun onStartCommand')
    harness = r'''import java.util.ArrayDeque
class JSONObject {
val values=linkedMapOf<String,Any>();constructor();constructor(text:String){values.putAll(registry.getValue(text))}
fun put(k:String,v:Any):JSONObject{values[k]=v;return this};fun remove(k:String)=values.remove(k)
fun optString(k:String)=values[k] as? String ?: "";fun getString(k:String)=optString(k)
fun optLong(k:String,d:Long=0L)=(values[k] as? Number)?.toLong() ?: d;fun getLong(k:String)=optLong(k)
fun optBoolean(k:String)=values[k] as? Boolean ?: false
fun optJSONObject(k:String)=values[k] as? JSONObject;fun optJSONArray(k:String)=values[k] as? JSONArray
fun optJSONObject(i:Int):JSONObject?=null
 override fun toString():String{val key=values.toString();registry[key]=LinkedHashMap(values);return key}
companion object{val registry=mutableMapOf<String,Map<String,Any>>()}}
class JSONArray(val rows:List<JSONObject> = emptyList()) {fun length()=rows.size;fun getJSONObject(i:Int)=rows[i];fun optJSONObject(i:Int):JSONObject?=rows.getOrNull(i)}
class Queue {val tasks=ArrayDeque<()->Unit>();fun execute(f:()->Unit){tasks.add(f)};fun post(f:()->Unit){tasks.add(f)};fun one(){check(tasks.isNotEmpty());tasks.removeFirst()()};fun drain(){var n=0;while(tasks.isNotEmpty()){check(n++<100);one()}}}
val events=mutableListOf<String>()
object AudioManager {const val AUDIOFOCUS_REQUEST_GRANTED=1}
class Audio {var grant=true;fun requestAudioFocus(f:Int):Int{events.add("focus");return if(grant)1 else 0};fun abandonAudioFocusRequest(f:Int){events.add("abandon")}}
class AudioAttributes {class Builder {fun setUsage(x:Int)=this;fun setContentType(x:Int)=this;fun build()=AudioAttributes()};companion object{const val USAGE_MEDIA=1;const val CONTENT_TYPE_MUSIC=1}}
class MediaPlayer {
var isPlaying=false;var duration=30000;var currentPosition=0;var released=false
var prepared:((MediaPlayer)->Unit)?=null;var error:((MediaPlayer,Int,Int)->Boolean)?=null;var completion:((MediaPlayer)->Unit)?=null;var seek:((MediaPlayer)->Unit)?=null
fun start(){check(!released);events.add("decoder-start");isPlaying=true};fun pause(){events.add("pause");isPlaying=false};fun release(){events.add("release");released=true;isPlaying=false}
fun setOnPreparedListener(f:((MediaPlayer)->Unit)?){prepared=f};fun setOnErrorListener(f:((MediaPlayer,Int,Int)->Boolean)?){error=f}
fun setOnCompletionListener(f:((MediaPlayer)->Unit)?){completion=f};fun setOnSeekCompleteListener(f:((MediaPlayer)->Unit)?){seek=f}
fun setAudioAttributes(a:AudioAttributes){};fun seekTo(p:Long,m:Int){currentPosition=p.toInt()};fun setDataSource(p:String){};fun prepareAsync(){}
companion object{const val SEEK_CLOSEST=1}}
class Intent {var action:String?=null;constructor(a:Any,b:Class<*>);fun setAction(s:String):Intent{action=s;return this}}
class MainActivity
class PendingIntent {companion object{const val FLAG_UPDATE_CURRENT=1;const val FLAG_IMMUTABLE=2;fun getService(a:Any,b:Int,c:Intent,d:Int)=PendingIntent();fun getForegroundService(a:Any,b:Int,c:Intent,d:Int)=PendingIntent();fun getActivity(a:Any,b:Int,c:Intent,d:Int)=PendingIntent()}}
object android {object R {object drawable {const val ic_media_play=1;const val ic_media_pause=2}}}
class Notification {class Builder(a:Any,b:String){fun setSmallIcon(v:Int)=this;fun setContentTitle(v:String)=this;fun setContentText(v:String)=this;fun setContentIntent(v:PendingIntent)=this;fun setOngoing(v:Boolean)=this;fun addAction(v:Action)=this;fun setStyle(v:MediaStyle)=this;fun build()=Notification()};class Action{class Builder(a:Int,b:String,c:PendingIntent){fun build()=Action()}};class MediaStyle{fun setMediaSession(v:Int)=this;fun setShowActionsInCompactView(v:Int)=this}}
class Session {val sessionToken=1}
class Prefs {fun edit()=this;fun clear()=this;fun commit()=true}
class Bridge {var epoch=1L;val calls=mutableListOf<JSONObject>();var reject=false;val replies=ArrayDeque<JSONObject>()
fun revoke(c:Long):Long{epoch++;return epoch}
fun execute(c:Long,e:Long,raw:String):String{val v=JSONObject(raw);calls.add(v);if(replies.isNotEmpty())return replies.removeFirst().toString();val result=JSONObject().put("ok",!reject).put("code",if(reject)"synthetic_refusal" else "ok").put("snapshot",JSONObject().put("epoch",e).put("session",1L));val action=when(v.optString("command")){"select","retry"->"load";"pause"->"pause";"resume"->"play";"seek"->"seek";else->null};if(!reject && action!=null)result.put("audio",JSONObject().put("action",action).put("epoch",e).put("session",1L).put("path","synthetic").put("position_ms",v.optLong("position_ms")));return result.toString()}}
class PlaybackService {
val worker=Queue();val main=Queue();val bridge=Bridge();val core=1L;var epoch=1L;var credentialEpoch=1L;var storedCredentialVersion=0L;var transportIntent=0L
var snapshot=JSONObject().put("epoch",1L).put("session",1L).put("position_ms",40L).put("duration_ms",30000L)
var listener:((JSONObject,String?)->Unit)?=null;var wantsPlayback=false;var busy=0;var pendingReports=false
var player:MediaPlayer?=MediaPlayer();var playerReady=true;var pendingSeekMs:Long?=null;var nativeTerminalState:String?=null
__TERMINAL_FIELDS__
val session=Session();val audio=Audio();val focus=1;var focusHeld=false;var foreground=false;var notificationIdentity="";var lastEffectCached=false;var lastSeekCompleted=0L
var denyAdmission=false;var denyNotification=false;val MODE_PRIVATE=0;val START_NOT_STICKY=2;val STOP_FOREGROUND_REMOVE=1
fun startService(i:Intent){events.add("service-start");if(denyAdmission)throw IllegalStateException("denied")}
fun startForegroundService(i:Intent){events.add("foreground-admission");if(denyAdmission)throw IllegalStateException("denied")}
fun startForeground(id:Int,n:Notification){events.add("notification");if(denyNotification)throw SecurityException("denied")}
fun stopForeground(mode:Int){events.add("foreground-stop")};fun stopSelf(){events.add("service-stop")}
val saved=mutableListOf<JSONObject>();fun getSharedPreferences(n:String,m:Int)=Prefs();fun saveCredentials(v:JSONObject){saved.add(v)};fun updateSession(){}
fun nativePositionMs()=player?.currentPosition?.toLong() ?: 0L
fun drain(){var n=0;while(worker.tasks.isNotEmpty()||main.tasks.isNotEmpty()){check(n++<100);worker.drain();main.drain()}}
fun startForTest(){startPlayer()};fun tick(){report()};fun effect(v:JSONObject){applyAudio(v)}
__METHODS__
}
fun main(){var failed=0;fun test(name:String,f:()->Unit){events.clear();try{f();println("PASS $name")}catch(e:Throwable){failed++;println("FAIL $name ${e.message}")}}
for(kind in listOf("select","resume","retry")) test("early-admission-$kind-before-worker"){
val a=PlaybackService();a.command(JSONObject().put("command",kind));check("notification" in events){"no notification before asynchronous work"};check(a.bridge.calls.isEmpty());check(a.foreground)}
test("notification-before-decoder-and-focus") {val a=PlaybackService();a.command(JSONObject().put("command","resume"));a.startForTest();check(events.indexOf("notification")<events.indexOf("focus"));check(events.indexOf("notification")<events.indexOf("decoder-start"))}
for(denial in listOf("admission","notification")) test("denied-$denial-no-decoder-no-focus-sticky-failure") {
val a=PlaybackService();a.denyAdmission=denial=="admission";a.denyNotification=denial=="notification";a.command(JSONObject().put("command","resume"));a.drain();a.tick();a.drain();check(!a.wantsPlayback && !a.focusHeld && !a.foreground);check(a.player?.isPlaying!=true);check(a.bridge.calls.any{it.optString("state")=="failed"});check("decoder-start" !in events);val count=events.count{it=="foreground-admission"};a.tick();a.drain();check(events.count{it=="foreground-admission"}==count)}
test("late-notification-refusal-retires-decoder") {val a=PlaybackService();a.command(JSONObject().put("command","resume"));a.drain();a.denyNotification=true;a.startForTest();a.drain();check(!a.focusHeld && !a.wantsPlayback && a.player?.isPlaying!=true && !a.foreground)}
test("focus-refusal-releases-foreground") {val a=PlaybackService();a.audio.grant=false;a.command(JSONObject().put("command","resume"));a.startForTest();a.drain();check(!a.focusHeld && !a.foreground && !a.wantsPlayback)}
for(kind in listOf("pause","logout","login")) test("cancel-$kind-stops-before-held-worker") {val a=PlaybackService();a.command(JSONObject().put("command","resume"));a.startForTest();a.busy=32;a.command(JSONObject().put("command",kind));check(!a.foreground && !a.focusHeld && !a.wantsPlayback && a.player?.isPlaying!=true)}
test("load-keeps-early-foreground-pause-fences-prepared") {val a=PlaybackService();a.select(4);a.drain();a.effect(JSONObject().put("action","load").put("epoch",a.epoch).put("session",1L).put("path","synthetic"));check(a.foreground);val next=a.player!!;a.command(JSONObject().put("command","pause"));next.prepared!!(next);check(!a.foreground && !next.isPlaying)}
test("service-play-action-admits-before-worker") {val a=PlaybackService();check(a.onStartCommand(Intent(a,PlaybackService::class.java).setAction("play"),0,1)==2);check(a.foreground && a.bridge.calls.isEmpty())}
test("late-empty-start-does-not-revive-cancelled-intent") {val a=PlaybackService();a.command(JSONObject().put("command","resume"));a.command(JSONObject().put("command","pause"));a.onStartCommand(Intent(a,PlaybackService::class.java),0,1);check(!a.foreground && !a.wantsPlayback && "service-stop" in events)}
test("selection-backpressure-retires-old-intent") {val a=PlaybackService();a.command(JSONObject().put("command","resume"));a.busy=32;a.select(5);check(!a.wantsPlayback && !a.foreground && !a.focusHeld)}
test("failed-selection-releases-foreground") {val a=PlaybackService();a.bridge.reject=true;a.select(4);a.drain();check(!a.foreground && !a.wantsPlayback && !a.focusHeld)}
for(heldMain in listOf(false,true)) test("new-resume-owns-foreground-after-old-pause-$heldMain") {
val a=PlaybackService();a.command(JSONObject().put("command","resume"));a.drain();check(a.player!!.isPlaying)
a.command(JSONObject().put("command","pause"));if(heldMain)a.worker.one();a.command(JSONObject().put("command","resume"));a.drain()
check(a.wantsPlayback && a.foreground && a.focusHeld && a.player!!.isPlaying){"older pause retired newer resume"}}
for(kind in listOf("select","resume","retry")) test("stale-core-failure-cannot-retire-new-resume-$kind") {
val a=PlaybackService();a.command(JSONObject().put("command",kind));a.bridge.reject=true;a.worker.one();a.bridge.reject=false
a.command(JSONObject().put("command","resume"));a.drain();check(a.wantsPlayback && a.foreground && a.player!!.isPlaying)}
test("reentrant-resume-revokes-old-pause-effect-without-losing-cleanup") {
val a=PlaybackService();a.command(JSONObject().put("command","resume"));a.drain();var once=true;var done=false
a.listener={_,_->if(once){once=false;a.command(JSONObject().put("command","resume"))}}
a.command(JSONObject().put("command","pause")){done=true};a.drain();check(done && a.busy==0 && a.foreground && a.player!!.isPlaying)}
for(heldMain in listOf(false,true)) test("held-load-cannot-erase-later-notification-failure-$heldMain") {
val a=PlaybackService();a.select(4);if(heldMain)a.worker.one();a.denyNotification=true;a.command(JSONObject().put("command","retry"));check(a.nativeTerminalState=="failed")
a.denyNotification=false;a.drain();a.player?.let{it.prepared?.invoke(it)};a.drain();a.tick();a.drain()
check(!a.wantsPlayback && !a.foreground && !a.focusHeld && a.player?.isPlaying!=true)
check(a.nativeTerminalState=="failed" && a.bridge.calls.last{it.optString("command")=="audio_report"}.optString("state")=="failed"){"older preparation erased newer failure"}}
test("held-load-cannot-erase-later-focus-refusal") {
val a=PlaybackService();a.command(JSONObject().put("command","retry"));a.command(JSONObject().put("command","resume"));a.audio.grant=false;a.startForTest();check(a.nativeTerminalState=="failed")
a.drain();a.player?.let{it.prepared?.invoke(it)};a.drain();a.tick();a.drain();check(a.nativeTerminalState=="failed" && !a.foreground && !a.focusHeld && a.player?.isPlaying!=true)
check(a.bridge.calls.last{it.optString("command")=="audio_report"}.optString("state")=="failed")}
test("pause-allows-current-selection-preparation-without-replay") {
val a=PlaybackService();a.select(4);a.command(JSONObject().put("command","pause"));a.drain();val p=a.player!!;p.prepared!!(p);a.drain()
check(a.playerReady && !p.isPlaying && !a.foreground && !a.focusHeld && a.nativeTerminalState==null)
a.command(JSONObject().put("command","resume"));a.drain();check(a.player===p && p.isPlaying && a.foreground)}
for(kind in listOf("resume","retry","select")) test("new-explicit-intent-retires-failure-$kind") {
val a=PlaybackService();a.denyNotification=true;a.command(JSONObject().put("command","resume"));a.drain();check(a.nativeTerminalState=="failed")
a.denyNotification=false;if(kind=="select")a.select(5) else a.command(JSONObject().put("command",kind));a.drain();a.player?.let{it.prepared?.invoke(it)};a.drain()
check(a.nativeTerminalState==null && a.wantsPlayback && a.foreground && a.player!!.isPlaying)}
test("stale-transport-result-still-delivers-account-credentials-and-done") {
val a=PlaybackService();var done=false;a.bridge.replies.add(JSONObject().put("ok",true).put("snapshot",JSONObject().put("epoch",a.epoch).put("session",1L)).put("credentials",JSONObject().put("version",9L)).put("audio",JSONObject().put("action","pause").put("epoch",a.epoch)))
a.command(JSONObject().put("command","pause")){done=true};a.worker.one();a.command(JSONObject().put("command","resume"));a.drain()
check(done && a.busy==0 && a.saved.single().optLong("version")==9L && a.foreground && a.player!!.isPlaying)}
test("seek-cannot-clear-newest-failure") {
val a=PlaybackService();a.denyNotification=true;a.command(JSONObject().put("command","resume"));a.drain();a.denyNotification=false
a.command(JSONObject().put("command","seek").put("position_ms",700L));a.drain();a.tick();a.drain();check(a.nativeTerminalState=="failed" && !a.foreground)
check(a.bridge.calls.last{it.optString("command")=="audio_report"}.optString("state")=="failed")}
test("seek-after-end-retires-ended-without-replay") {
val a=PlaybackService();a.nativeTerminalState="ended";a.command(JSONObject().put("command","seek").put("position_ms",700L));a.drain()
check(a.nativeTerminalState==null && a.player!!.currentPosition==700 && !a.wantsPlayback && !a.foreground)}
test("retained-completion-after-refusal-cannot-replace-failure") {
val a=PlaybackService();a.select(1);a.drain();val p=a.player!!;p.prepared!!(p);a.drain();val completion=p.completion!!
a.denyNotification=true;a.command(JSONObject().put("command","retry"));a.drain();completion(p);a.tick();a.drain();check(a.nativeTerminalState=="failed" && !a.foreground && !a.wantsPlayback)}
test("retired-report-cleans-only-its-own-pending-not-new-account-done") {
val a=PlaybackService();a.command(JSONObject().put("command","resume"));a.drain();a.tick();check(a.pendingReports);a.select(2);a.drain();check(!a.pendingReports && a.busy==0)
var oldDone=false;a.command(JSONObject().put("command","snapshot")){oldDone=true};a.command(JSONObject().put("command","logout"));a.drain();check(!oldDone)}
test("old-selection-callbacks-cannot-revive-new-player") {
val a=PlaybackService();a.select(1);a.drain();val old=a.player!!;val prepared=old.prepared!!;val error=old.error!!;val complete=old.completion!!;val seek=old.seek!!
a.select(2);a.drain();val current=a.player!!;current.prepared!!(current);a.drain();prepared(old);error(old,1,1);complete(old);seek(old);a.drain()
check(old.released && a.player===current && current.isPlaying && a.foreground && a.nativeTerminalState==null)}
test("account-intent-retires-failure-without-resuming") {
val a=PlaybackService();a.denyNotification=true;a.command(JSONObject().put("command","resume"));a.drain();a.command(JSONObject().put("command","restore"));a.drain()
check(a.nativeTerminalState==null && !a.wantsPlayback && !a.foreground && !a.focusHeld)}
for(action in listOf("play","seek","stop")) test("stale-effect-cannot-mutate-new-pause-$action") {
val a=PlaybackService();a.bridge.replies.add(JSONObject().put("ok",true).put("snapshot",JSONObject().put("epoch",a.epoch).put("session",1L)).put("audio",JSONObject().put("action",action).put("epoch",a.epoch).put("position_ms",900L)))
a.command(JSONObject().put("command","seek").put("position_ms",900L));a.worker.one();val p=a.player!!;a.command(JSONObject().put("command","pause"));a.drain()
check(a.player===p && p.currentPosition==0 && !p.isPlaying && !a.foreground && !a.focusHeld)}
test("reentrant-new-resume-survives-core-refusal") {
val a=PlaybackService();a.command(JSONObject().put("command","retry"));a.bridge.reject=true;a.worker.one();a.bridge.reject=false;var once=true
a.listener={_,_->if(once){once=false;a.command(JSONObject().put("command","resume"))}};a.drain();check(a.foreground && a.wantsPlayback && a.player!!.isPlaying)}
test("reentrant-selection-does-not-strand-pending-report") {
val a=PlaybackService();a.command(JSONObject().put("command","resume"));a.drain();var once=true
a.listener={_,_->if(once){once=false;a.select(2)}};a.tick();a.drain();check(!a.pendingReports && a.busy==0)
val p=a.player!!;p.prepared!!(p);a.drain();check(!a.pendingReports && a.bridge.calls.last().optString("command")=="audio_report")}
test("queue-selected-remove-admits-new-foreground-before-worker") {
val a=PlaybackService();a.snapshot.put("selected_occurrence",11L).put("queue",JSONArray(listOf(JSONObject().put("id",11L),JSONObject().put("id",12L))))
a.queueAction("queue_remove",11L);check(a.foreground && a.wantsPlayback && a.bridge.calls.isEmpty())}
for(kind in listOf("queue_play","next","previous")) test("queue-early-admission-$kind") {
val a=PlaybackService();a.command(JSONObject().put("command",kind));check(a.foreground && a.wantsPlayback && a.bridge.calls.isEmpty())}
test("queue-noncurrent-edit-retains-decoder-and-intent") {
val a=PlaybackService();a.command(JSONObject().put("command","resume"));a.drain();val p=a.player;val e=a.epoch;val intent=a.transportIntent
a.snapshot.put("selected_occurrence",11L);a.queueAction("queue_remove",12L);a.queueAction("queue_move",12L,0);a.queueAction("queue_append",3L);a.drain()
check(a.player===p && a.epoch==e && a.transportIntent==intent && a.foreground && a.player!!.isPlaying)}
test("queue-eof-continues-admitted-foreground-without-new-service-start") {
val a=PlaybackService();a.select(1);a.drain();val p=a.player!!;p.prepared!!(p);a.drain();p.isPlaying=false
val starts=events.count{it=="foreground-admission"}
a.bridge.replies.add(JSONObject().put("ok",true).put("snapshot",JSONObject().put("epoch",a.epoch).put("session",2L)).put("audio",JSONObject().put("action","load").put("epoch",a.epoch).put("session",2L).put("path","synthetic")))
p.completion!!(p);a.drain();val next=a.player!!;check(p!==next && p.released);next.prepared!!(next);a.drain()
check(next.isPlaying && a.foreground && a.wantsPlayback && a.nativeTerminalState==null && events.count{it=="foreground-admission"}==starts)}
test("queue-held-eof-load-cannot-revive-later-pause") {
val a=PlaybackService();a.select(1);a.drain();val p=a.player!!;p.prepared!!(p);a.drain();p.isPlaying=false
a.bridge.replies.add(JSONObject().put("ok",true).put("snapshot",JSONObject().put("epoch",a.epoch).put("session",2L)).put("audio",JSONObject().put("action","load").put("epoch",a.epoch).put("session",2L).put("path","synthetic")))
p.completion!!(p);a.worker.one();a.command(JSONObject().put("command","pause"));a.drain();val next=a.player!!;next.prepared!!(next);a.drain()
check(!next.isPlaying && !a.foreground && !a.wantsPlayback && !a.focusHeld)}
for(code in listOf("invalid_saved_queue","queue_storage_failed","cache_io")) test("queue-storage-current-load-retains-admitted-playback-$code") {
val a=PlaybackService();var visible=false;var done=false
a.listener={_,error->if(error==code)visible=true}
a.bridge.replies.add(JSONObject().put("ok",false).put("code",code).put("snapshot",JSONObject().put("epoch",a.epoch).put("session",2L).put("selected_occurrence",11L).put("transport","preparing")).put("audio",JSONObject().put("action","load").put("epoch",a.epoch).put("session",2L).put("path","synthetic")))
a.command(JSONObject().put("command","retry")){done=true};a.drain();val next=a.player!!;next.prepared!!(next);a.drain()
check(visible && done && a.busy==0 && a.wantsPlayback && a.foreground && a.focusHeld && next.isPlaying)}
for(defect in listOf("no-effect","wrong-session","wrong-epoch","wrong-snapshot","binding","core-refusal","missing-path","failed-state")) test("queue-storage-invalid-effect-retires-$defect") {
val a=PlaybackService();val old=a.player;val snap=JSONObject().put("epoch",if(defect=="wrong-snapshot")99L else a.epoch).put("session",2L).put("selected_occurrence",11L).put("transport",if(defect=="failed-state")"failed" else "preparing")
val result=JSONObject().put("ok",false).put("code",when(defect){"binding"->"binding_failure";"core-refusal"->"api_refused";else->"invalid_saved_queue"}).put("snapshot",snap).put("credentials",JSONObject().put("version",9L))
if(defect!="no-effect")result.put("audio",JSONObject().put("action","load").put("epoch",if(defect=="wrong-epoch")99L else a.epoch).put("session",if(defect=="wrong-session")99L else 2L).put("path",if(defect=="missing-path")"" else "synthetic"))
a.bridge.replies.add(result);var done=false;a.command(JSONObject().put("command","retry")){done=true};a.drain()
check(!a.foreground && !a.wantsPlayback && !a.focusHeld && a.player===old && a.player?.isPlaying!=true && done && a.busy==0 && a.saved.single().optLong("version")==9L)}
test("queue-selected-metadata-is-not-first-recording") {
val a=PlaybackService();a.snapshot.put("selected_occurrence",12L).put("queue",JSONArray(listOf(JSONObject().put("id",11L).put("track",JSONObject().put("id",1L)),JSONObject().put("id",12L).put("track",JSONObject().put("id",2L)))))
check(a.selectedTrack()?.optLong("id")==2L)}
check(failed==0){"$failed Android service regressions"}}
'''.replace('__METHODS__', methods).replace('__TERMINAL_FIELDS__', '\n'.join(
        line.strip().removeprefix('private ') for line in source.splitlines()
        if line.strip().startswith('private var endedReportAcknowledged =')))
    return harness


class AndroidService(unittest.TestCase):
    def test_production_service_admission_and_retirement(self):
        from test_toolchain import java_home, kotlin_compiler
        java = java_home()
        with tempfile.TemporaryDirectory(prefix='native-review-kotlin-', dir=os.environ.get('TMPDIR')) as tmp:
            work = Path(tmp)
            source = work / 'ServiceProbe.kt'
            source.write_text(android_probe(ROOT, swift_block))
            env = dict(os.environ, JAVA_HOME=str(java), JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2')
            built = subprocess.run([kotlin_compiler(), str(source), '-nowarn', '-include-runtime', '-d', str(work/'probe.jar')], env=env, capture_output=True, text=True, timeout=120)
            self.assertEqual(built.returncode, 0, built.stdout+built.stderr)
            result = subprocess.run([str(java/'bin/java'), '-jar', str(work/'probe.jar')], env=env, capture_output=True, text=True, timeout=30)
            print(result.stdout)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiled", action="store_true")
    parser.add_argument("--phase-only", action="store_true", help="Window-free Swift phase recorder and controlled launcher only; no SwiftPM/core/Android build")
    parser.add_argument("--source-root", type=Path, default=ROOT, help="Replay identical tests against a preserved production snapshot")
    args, rest = parser.parse_known_args()
    ROOT = args.source_root.resolve()
    suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(BuildProvenance)])
    if args.compiled and args.phase_only:
        parser.error("--compiled and --phase-only are mutually exclusive")
    if args.phase_only:
        os.environ['SOUNDQ_PHASE_COMPILED'] = '1'
        import test_macos_phase_journey as phases
        phases.ROOT = ROOT
        phases.RECORDER = ROOT / 'native/macos/Sources/FixturePhaseMeasurement.swift'
        phases.LAUNCHER = ROOT / 'native/tests/macos_phase_journey.py'
        suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(phases))
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(SwiftReporting))
    if args.compiled:
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(SwiftCoreLink))
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(SwiftReporting))
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(AndroidService))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
