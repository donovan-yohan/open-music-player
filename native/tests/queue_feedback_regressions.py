#!/usr/bin/env python3
"""Deterministic #505 feedback seams; no device, GUI, audio or private account.

--rust instruments only a private core copy at actual persist_queue boundaries,
then exercises execute, real filesystem writes, revocation and current readback.
--macos compiles exact production report/command/apply and Decodable types with
physical-player/UI/worker facades against the freshly built real core C ABI.
Set SOUNDQ_CORE_LIBRARY for --macos. --source-root supports identical-test replay.
All compiler inputs, commands and outputs are retained under --output.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from native_review_regressions import swift_block

ROOT = Path(__file__).resolve().parents[2]
RUST = r'''
#[cfg(test)]
mod queue_feedback {
    use super::*;
    use std::cell::RefCell;
    type Hook = Box<dyn FnOnce(&Core)>;
    thread_local! { static HOOK: RefCell<Option<(&'static str, Hook)>> = RefCell::new(None); }
    fn arm(stage: &'static str, action: impl FnOnce(&Core) + 'static) {
        HOOK.with(|h| { assert!(h.borrow().is_none()); *h.borrow_mut() = Some((stage, Box::new(action))); });
    }
    pub(super) fn hit(c: &Core, stage: &'static str) {
        let action = HOOK.with(|h| {
            if h.borrow().as_ref().is_some_and(|(s, _)| *s == stage) { h.borrow_mut().take() } else { None }
        });
        if let Some((_, action)) = action { action(c); }
    }
    fn prepared() -> (Core, PathBuf) {
        let c = tests::populated_queue_core();
        assert!(c.execute(Command::Select { track_id: 3 }).ok);
        let target = c.account_dir(&c.state.lock().unwrap()).unwrap().join("listening-queue-v1.json");
        (c, target)
    }
    fn report(c: &Core, state: AudioState) -> Reply {
        let session = c.state.lock().unwrap().snapshot.session;
        c.execute(Command::AudioReport { epoch: c.epoch.load(Ordering::SeqCst), session, state, position_ms: 123, duration_ms: 30000 })
    }
    fn cancelled_persist(stage: &'static str) {
        {
            let (c, target) = prepared();
            let before = fs::read(&target).unwrap();
            arm(stage, |c| { c.revoke(); });
            let cancelled = c.execute(Command::Pause {});
            assert_eq!(cancelled.code, "cancelled");
            assert!(cancelled.audio.is_none());
            assert_eq!(fs::read(&target).unwrap(), before);
            let current = c.execute(Command::Snapshot {});
            assert!(current.ok);
            assert_eq!(current.snapshot.error, None, "{stage}: stale cancelled error escaped through current snapshot");
            assert!(report(&c, AudioState::Playing).ok);
            assert_eq!(report(&c, AudioState::Playing).snapshot.error, None);
            assert!(fs::read_dir(target.parent().unwrap()).unwrap().all(|p| !p.unwrap().path().extension().is_some_and(|s| s == "pending")));
            fs::remove_dir_all(&c.root).unwrap();
        }
    }
    #[test]
    fn cancelled_persist_before_write_keeps_current_feedback_clean() { cancelled_persist("entered"); }
    #[test]
    fn cancelled_persist_after_sync_keeps_current_feedback_clean() { cancelled_persist("synced"); }
    fn cancelled_selection(stage: &'static str) {
        {
            let (c, target) = prepared();
            {
                let mut s = c.state.lock().unwrap();
                s.credential_version = 17;
                s.credentials.as_mut().unwrap().version = 17;
                s.credentials_changed = true;
            }
            let before = c.state.lock().unwrap().clone();
            let bytes = fs::read(&target).unwrap();
            arm(stage, |c| { c.revoke(); });
            let cancelled = c.execute(Command::Select { track_id: 6 });
            assert_eq!(cancelled.code, "cancelled");
            assert!(cancelled.audio.is_none());
            let after = c.state.lock().unwrap().clone();
            assert_eq!(after.snapshot.selected_occurrence, before.snapshot.selected_occurrence, "{stage}: never-delivered replacement retained selection");
            assert_eq!(serde_json::to_value(&after.snapshot.queue).unwrap(), serde_json::to_value(&before.snapshot.queue).unwrap());
            assert_eq!(after.snapshot.session, before.snapshot.session);
            assert_eq!(after.snapshot.position_ms, before.snapshot.position_ms);
            assert_eq!(after.current_path, before.current_path);
            assert_eq!(after.next_occurrence, before.next_occurrence);
            assert_eq!(after.retry_target, before.retry_target);
            assert_eq!(after.persisted_position, before.persisted_position);
            assert_eq!(after.snapshot.error, before.snapshot.error);
            assert_eq!(fs::read(&target).unwrap(), bytes);
            let current = c.execute(Command::Snapshot {});
            assert_eq!(current.snapshot.selected_occurrence, before.snapshot.selected_occurrence);
            assert_eq!(current.snapshot.error, None);
            assert_eq!(current.credentials.unwrap().version, 17);
            assert!(c.state.lock().unwrap().credentials_changed);
            assert!(c.execute(Command::AcknowledgeCredentials { version: 17 }).ok);
            assert!(!c.state.lock().unwrap().credentials_changed);
            fs::remove_dir_all(&c.root).unwrap();
        }
    }
    #[test]
    fn cancelled_selection_before_write_restores_provisional_owners() { cancelled_selection("entered"); }
    #[test]
    fn cancelled_selection_after_sync_restores_provisional_owners() { cancelled_selection("synced"); }
    #[test]
    fn revocation_after_committed_write_keeps_durable_selection_without_stale_error() {
        let (c, target) = prepared();
        arm("committed", |c| { c.revoke(); });
        let cancelled = c.execute(Command::Select { track_id: 6 });
        assert_eq!(cancelled.code, "cancelled");
        assert!(cancelled.audio.is_none());
        let saved = c.read_saved_queue(&target).unwrap().unwrap();
        let current = c.execute(Command::Snapshot {});
        assert_eq!(current.snapshot.selected_occurrence, saved.selected);
        assert_eq!(current.snapshot.queue[5].track.id, 6);
        assert_eq!(current.snapshot.error, None);
        assert_eq!(c.state.lock().unwrap().persisted_position, Some((saved.selected, saved.position_ms)));
        fs::remove_dir_all(&c.root).unwrap();
    }
    #[test]
    fn genuine_persistence_faults_keep_feedback_and_valid_load_effect() {
        for (stage, expected) in [("invalid", "invalid_saved_queue"), ("storage", "queue_storage_failed"), ("cache", "cache_io")] {
            let (c, target) = prepared();
            if stage == "invalid" { fs::write(&target, b"{broken").unwrap(); }
            if stage == "storage" { let path = target.clone(); arm("synced", move |_| { fs::remove_file(&path).unwrap(); fs::create_dir(&path).unwrap(); }); }
            if stage == "cache" { let dir = target.parent().unwrap().to_owned(); arm("entered", move |_| {
                let next = NEXT_CACHE_TEMPORARY.load(Ordering::Relaxed);
                for serial in next..next+128 { fs::write(dir.join(format!("listening-queue-v1-{}-{serial}.pending", std::process::id())), b"foreign-owner").unwrap(); }
            }); }
            let selected = c.execute(Command::Select { track_id: 6 });
            assert!(!selected.ok);
            assert_eq!(selected.code, expected);
            assert_eq!(selected.snapshot.error.as_deref(), Some(expected));
            let effect = selected.audio.unwrap();
            assert_eq!(effect.action, "load");
            assert_eq!(effect.epoch, selected.snapshot.epoch);
            assert_eq!(effect.session, selected.snapshot.session);
            assert!(effect.path.as_ref().unwrap().is_file());
            assert_eq!(selected.snapshot.queue.iter().find(|o| Some(o.id) == selected.snapshot.selected_occurrence).unwrap().track.id, 6);
            assert_eq!(c.execute(Command::Snapshot {}).snapshot.error.as_deref(), Some(expected));
            assert_eq!(report(&c, AudioState::Playing).snapshot.error.as_deref(), Some(expected));
            if stage == "invalid" { assert_eq!(fs::read(&target).unwrap(), b"{broken"); }
            fs::remove_dir_all(&c.root).unwrap();
        }
    }
    #[test]
    fn current_unrevoked_selection_write_and_audio_owners_are_unchanged() {
        let (c, target) = prepared();
        let selected = c.execute(Command::Select { track_id: 6 });
        assert!(selected.ok);
        let effect = selected.audio.unwrap();
        assert_eq!(effect.action, "load");
        assert_eq!(effect.epoch, selected.snapshot.epoch);
        assert_eq!(effect.session, selected.snapshot.session);
        assert_eq!(c.read_saved_queue(&target).unwrap().unwrap().selected, selected.snapshot.selected_occurrence);
        assert_eq!(selected.snapshot.error, None);
        fs::remove_dir_all(&c.root).unwrap();
    }
    #[test]
    fn revoked_before_dispatch_never_enters_persist_or_changes_current_owners() {
        let (c, target) = prepared();
        let before = c.state.lock().unwrap().clone();
        let bytes = fs::read(&target).unwrap();
        let epoch = c.epoch.load(Ordering::SeqCst);
        c.revoke();
        let cancelled = c.execute_at(Command::Select { track_id: 6 }, epoch);
        assert_eq!(cancelled.code, "cancelled");
        assert!(cancelled.audio.is_none());
        let after = c.state.lock().unwrap().clone();
        assert_eq!(serde_json::to_value(&after.snapshot).unwrap(), serde_json::to_value(&before.snapshot).unwrap());
        assert_eq!(after.current_path, before.current_path);
        assert_eq!(after.next_occurrence, before.next_occurrence);
        assert_eq!(after.persisted_position, before.persisted_position);
        assert_eq!(fs::read(&target).unwrap(), bytes);
        fs::remove_dir_all(&c.root).unwrap();
    }
}
'''

SWIFT = r'''
import Foundation
import SoundQCore
__TYPES__
struct Clock {var seconds:Double}
enum ItemStatus {case failed,readyToPlay}
@MainActor class Item {var status=ItemStatus.readyToPlay;var duration=Clock(seconds:30)}
@MainActor class Player {
 var error:String?;var rate:Float=1;var time=Clock(seconds:0);var currentItem:Item?=Item()
 func currentTime()->Clock {time};func pause(){rate=0}
}
@MainActor class Field {var stringValue="";var isHidden=false;var title="";var isEnabled=true;var maxValue:Double=1;var doubleValue:Double=0;func reloadData(){}}
@MainActor class MPNowPlayingInfoCenter {enum State {case playing,paused};var playbackState=State.paused;static let shared=MPNowPlayingInfoCenter();static func `default`()->MPNowPlayingInfoCenter {shared}}
@MainActor class Bridge {
 let handle:UInt64
 var calls=[[String:Any]]();var replies=[Reply]();var pending=[(@Sendable (Data)->Void,Data)]();var refuse=false
 init(_ endpoint:String,_ root:String){handle=endpoint.withCString {e in root.withCString {sq_core_open(e,$0)}};precondition(handle != 0)}
 func revoke()->UInt64 {sq_core_revoke(handle)}
 func send(_ data:Data,epoch:UInt64,completion:@escaping @Sendable (Data)->Void){
  calls.append(try! JSONSerialization.jsonObject(with:data) as! [String:Any])
  let result:Data
  if refuse {refuse=false;result=Data(#"{"ok":false,"code":"binding_failure"}"#.utf8)}
  else {let text=String(data:data,encoding:.utf8)!;let raw=text.withCString {sq_core_execute(handle,epoch,$0)}!;result=Data(bytes:raw,count:strlen(raw));sq_core_string_free(raw)}
  replies.append(try! JSONDecoder().decode(Reply.self,from:result));pending.append((completion,result))
 }
 func deliver(){let (completion,data)=pending.removeFirst();completion(data)}
 func close(){sq_core_close(handle)}
}
@MainActor class App {
 var bridge:Bridge!;var snapshot:Snapshot?;var epoch:UInt64=1;var player:Player?;var reportPending=false
 var busy=0 {didSet {if busy<oldValue {settled?();settled=nil}}};var settled:(()->Void)?
 var accountScope:UInt64=1;var storedCredentialVersion:UInt64=0;var wantsPlayback=false
 var status=Field();var loginArea=Field();var libraryArea=Field();var logout=Field();var titleLabel=Field();var transportLabel=Field();var play=Field();var slider=Field();var table=Field()
 var effects=[AudioEffect]()
 func closeQueueName(){};func reconcileQueueName(_ s:Snapshot){};func deleteCredentials(){};func storeCredentials(_ c:Credentials,epoch:UInt64){fatalError("unexpected credential storage")}
 func applyAudio(_ effect:AudioEffect){effects.append(effect);if effect.action=="load" {player=Player()};if effect.action=="pause" {player?.pause()};if effect.action=="play" {player?.rate=1};if effect.action=="seek" {player?.time.seconds=Double(effect.position_ms)/1000};if effect.action=="stop" {player=nil}}
 __METHODS__
 func drain() async {while !bridge.pending.isEmpty {await withCheckedContinuation {continuation in settled={continuation.resume()};bridge.deliver()}};precondition(busy==0)}
 func send(_ command:String,_ values:[String:Any]=[:]) async {var v=values;v["command"]=command;self.command(v);await drain()}
 func eof() async {player!.rate=0;player!.time.seconds=30;report();await drain()}
}
@MainActor func require(_ value:Bool,_ message:String){if !value {fatalError(message)}}
@main enum Probe {
 @MainActor static func main() async {
  let endpoint=CommandLine.arguments[1];let root=CommandLine.arguments[2];var passes=0
  func test(_ name:String,_ body:() async -> Void) async {await body();passes+=1;print("PASS \(name)")}
  func ready(_ track:Int=1) async -> App {
   let a=App();let path=root+"/"+UUID().uuidString;a.bridge=Bridge(endpoint,path)
   await a.send("restore",["access_token":"synthetic-access","refresh_token":"synthetic-refresh","account_id":"feedback-account"])
   await a.send("library",["offset":0,"query":"","sort":"title","order":"asc"])
   await a.send("select",["track_id":track]);a.report();await a.drain()
   require(a.snapshot?.transport=="playing" && a.snapshot?.error==nil,"ready precondition");return a
  }
  func repeats(_ a:App) async {let n=a.bridge.calls.count;for _ in 0..<4 {a.report();await a.drain()};require(a.bridge.calls.count==n,"acknowledged terminal observation resubmitted; status=\(a.status.stringValue)")}
  await test("ordinary-final-EOF-accepted-once-next-timer-clean") {
   let a=await ready(2);let session=a.snapshot!.session;let selected=a.snapshot!.selected_occurrence
   await a.eof();require(a.bridge.replies.last!.ok && a.snapshot!.transport=="ended","initial EOF refused")
   await repeats(a);require(a.snapshot!.session==session && a.snapshot!.selected_occurrence==selected && a.snapshot!.error==nil && !a.status.stringValue.contains("stale"),"visible final EOF feedback");a.bridge.close()
  }
  await test("nonfinal-EOF-loads-successor-once-and-new-session-reports") {
   let a=await ready();let old=a.player;let session=a.snapshot!.session;await a.eof()
   require(a.snapshot!.session != session && a.player !== old && a.snapshot!.queue[1].id==a.snapshot!.selected_occurrence && a.effects.last!.action=="load","successor ownership lost")
   a.report();await a.drain();require(a.snapshot!.transport=="playing","new session report refused");await a.eof();await repeats(a);a.bridge.close()
  }
  await test("busy-and-pending-do-not-consume-undelivered-EOF") {
   let a=await ready(2);a.busy=1;a.player!.rate=0;a.player!.time.seconds=30;let n=a.bridge.calls.count;a.report();require(a.bridge.calls.count==n,"busy not coalesced");a.busy=0;a.report();await a.drain();require(a.snapshot!.transport=="ended","busy EOF lost");await repeats(a);a.bridge.close()
   let b=await ready(2);b.report();require(b.reportPending,"no pending report");b.player!.rate=0;b.player!.time.seconds=30;b.report();await b.drain();require(b.snapshot!.transport=="playing","pending changed EOF early");b.report();await b.drain();require(b.snapshot!.transport=="ended","pending EOF lost");await repeats(b);b.bridge.close()
  }
  await test("binding-refusal-retries-initial-EOF-and-failure-precedes-ended") {
   let a=await ready(2);a.bridge.refuse=true;await a.eof();require(a.status.stringValue=="binding failure" && a.snapshot!.transport=="playing" && !a.reportPending,"refusal hidden");a.report();await a.drain();require(a.snapshot!.transport=="ended","refused delivery was acknowledged");await repeats(a)
   a.player!.currentItem!.status = .failed;a.player!.time.seconds = .nan;a.report();await a.drain();require(a.snapshot!.transport=="failed" && a.status.stringValue=="native playback failed","genuine failure hidden by terminal dedup");a.bridge.close()
  }
  await test("ended-valid-seek-paused-then-resume-permits-new-EOF") {
   let a=await ready(2);await a.eof();let session=a.snapshot!.session;await a.send("seek",["position_ms":700]);a.report();await a.drain();require(a.snapshot!.transport=="paused" && a.snapshot!.position_ms==700,"seek paused report lost");await a.send("resume");a.report();await a.drain();await a.eof();require(a.snapshot!.session==session && a.snapshot!.transport=="ended" && a.snapshot!.error==nil,"same-session EOF lost");await repeats(a);a.bridge.close()
  }
  await test("rejected-seek-keeps-ended-and-genuine-error") {
   let a=await ready(2);await a.eof();await a.send("seek",["position_ms":40000]);require(a.status.stringValue=="invalid seek","genuine seek refusal hidden");await repeats(a);require(a.snapshot!.transport=="ended" && a.status.stringValue=="invalid seek","timer overwrote seek error");a.bridge.close()
  }
  await test("explicit-pause-at-EOF-does-not-submit-ineligible-ended") {
   let a=await ready(2);await a.eof();await a.send("pause");await repeats(a);require(a.snapshot!.transport=="paused" && a.snapshot!.error==nil,"pause replaced by false terminal error");a.bridge.close()
  }
  await test("storage-fault-terminal-truth-stays-visible-without-duplicate-diagnostic") {
   let a=await ready(2)
   let paths=FileManager.default.enumerator(atPath:root)!.allObjects.compactMap {$0 as? String}.filter {$0.hasSuffix("listening-queue-v1.json")}
   require(!paths.isEmpty,"writer never reached");for p in paths {try! Data("{broken".utf8).write(to:URL(fileURLWithPath:root+"/"+p))}
   await a.eof();require(a.snapshot!.transport=="ended" && a.status.stringValue=="invalid saved queue" && a.bridge.replies.last!.code=="invalid_saved_queue","persistence truth hidden");await repeats(a);require(a.status.stringValue=="invalid saved queue","duplicate overwrote storage feedback");a.bridge.close()
  }
  await test("revoked-held-terminal-publication-does-not-poison-new-selection") {
   let a=await ready(2);a.player!.rate=0;a.player!.time.seconds=30;a.report();a.player=nil;a.epoch=a.bridge.revoke();a.command(["command":"select","track_id":1]);await a.drain();require(!a.reportPending && a.snapshot!.epoch==a.epoch && a.snapshot!.transport=="preparing" && a.snapshot!.error==nil,"retired terminal crossed replacement");a.report();await a.drain();require(a.snapshot!.transport=="playing","replacement report lost");a.bridge.close()
  }
  print("QUEUE_FEEDBACK_MAC_PASS \(passes) failures=0")
 }
}
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run(argv, cwd, output, name, env=None):
    try:
        result = subprocess.run([str(a) for a in argv], cwd=cwd, env=env, capture_output=True, timeout=240)
    except subprocess.TimeoutExpired as error:
        (output / (name + '.stdout')).write_bytes(error.stdout or b'')
        (output / (name + '.stderr')).write_bytes(error.stderr or b'')
        (output / (name + '.json')).write_text(json.dumps({'argv': [str(a) for a in argv], 'cwd': str(cwd), 'timedOut': True, 'exitCode': None}, indent=2) + '\n')
        raise
    (output / (name + '.stdout')).write_bytes(result.stdout)
    (output / (name + '.stderr')).write_bytes(result.stderr)
    (output / (name + '.json')).write_text(json.dumps({'argv': [str(a) for a in argv], 'cwd': str(cwd), 'exitCode': result.returncode}, indent=2) + '\n')
    print(result.stdout.decode(errors='replace'), end='')
    if result.returncode:
        print(result.stderr.decode(errors='replace'), end='')
    return result.returncode


def rust(root, output):
    private = output / 'instrumented-core'
    shutil.copytree(root / 'native/core', private, ignore=shutil.ignore_patterns('target'))
    path = private / 'src/lib.rs'
    source = path.read_text()
    edits = [
        ('fn persist_queue(&self, s: &mut State, epoch: u64) -> Result<()> {', 'fn persist_queue(&self, s: &mut State, epoch: u64) -> Result<()> {\n        #[cfg(test)] queue_feedback::hit(self, "entered");'),
        ('file.sync_all().map_err(|_| "queue_storage_failed")?;', 'file.sync_all().map_err(|_| "queue_storage_failed")?;\n        #[cfg(test)] queue_feedback::hit(self, "synced");'),
        ('s.persisted_position = Some((s.snapshot.selected_occurrence, s.snapshot.position_ms));', 's.persisted_position = Some((s.snapshot.selected_occurrence, s.snapshot.position_ms));\n        #[cfg(test)] queue_feedback::hit(self, "committed");'),
        ('fn populated_queue_core() -> Core {', 'pub(super) fn populated_queue_core() -> Core {'),
    ]
    for old, new in edits:
        assert source.count(old) == 1, old
        source = source.replace(old, new)
    path.write_text(source + RUST)
    (output / 'instrumentation.json').write_text(json.dumps({'productionSha256': sha((root / 'native/core/src/lib.rs').read_bytes()), 'instrumentedSha256': sha(path.read_bytes()), 'testSha256': sha(RUST.encode()), 'edits': edits}, indent=2) + '\n')
    cargo = Path(os.environ['SOUNDQ_RUST_BIN']) / 'cargo'
    return run([cargo, 'test', '--locked', '--offline', '--jobs', '2', '--manifest-path', private / 'Cargo.toml', 'queue_feedback::', '--', '--nocapture', '--test-threads=1'], root, output, 'rust')


def macos(root, output):
    source = (root / 'native/macos/Sources/main.swift').read_text()
    signatures = ['struct Track:', 'struct Occurrence:', 'struct Snapshot:', 'struct AudioEffect:', 'struct Credentials:', 'struct Reply:', 'func report(state:', 'func command(', 'func apply(_ incoming: Snapshot)']
    blocks = {s: swift_block(source, s) for s in signatures}
    generated = SWIFT.replace('__TYPES__', '\n'.join(blocks[s] for s in signatures[:6])).replace('__METHODS__', '\n'.join(blocks[s] for s in signatures[6:]))
    path = output / 'Probe.swift'
    path.write_text(generated)
    library = Path(os.environ['SOUNDQ_CORE_LIBRARY']).resolve()
    (output / 'extraction.json').write_text(json.dumps({'blocks': {s: sha(b.encode()) for s, b in blocks.items()}, 'probeSha256': sha(path.read_bytes()), 'coreSha256': sha(library.read_bytes())}, indent=2) + '\n')
    code = run(['/usr/bin/swiftc', '-parse-as-library', '-swift-version', '6', '-j', '2', '-num-threads', '2', '-I', root / 'native/macos/CBridge', '-L', library.parent, '-lsoundq_core', '-Xlinker', '-rpath', '-Xlinker', library.parent, path, '-o', output / 'probe'], root, output, 'compile')
    if code:
        return code
    port = 0
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args): pass
        def do_POST(self):
            data = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or '{}')
            if self.path == '/api/v1/auth/refresh':
                value = {'accessToken': 'synthetic-access', 'refreshToken': 'synthetic-refresh', 'user': {'id': 'feedback-account'}}
            else:
                value = {'urls': [{'trackId': i, 'url': f'http://127.0.0.1:{port}/asset.wav', 'contentType': 'audio/wav', 'sizeBytes': 12} for i in data['trackIds']]}
            self.respond(value)
        def do_GET(self):
            self.respond({'tracks': [{'id': i, 'title': f'Feedback {i}', 'duration_ms': 30000} for i in (1, 2)], 'total': 2, 'offset': 0} if self.path.startswith('/api/v1/library?') else b'RIFFfeedback')
        def respond(self, value):
            data = value if isinstance(value, bytes) else json.dumps(value).encode()
            self.send_response(200);self.send_header('Content-Length', str(len(data)));self.end_headers();self.wfile.write(data)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    port = server.server_port
    thread = threading.Thread(target=server.serve_forever, daemon=True);thread.start()
    try:
        return run([output / 'probe', f'http://127.0.0.1:{server.server_port}/api/v1', output / 'state'], root, output, 'macos', env=dict(os.environ, SOUNDQ_NATIVE_FIXTURE_HOME='synthetic-device-free'))
    finally:
        server.shutdown();server.server_close();thread.join(3)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--rust', action='store_true');mode.add_argument('--macos', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    raise SystemExit((rust if args.rust else macos)(args.source_root.resolve(), args.output.resolve()))
