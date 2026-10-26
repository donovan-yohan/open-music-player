"""Window-free diagnostic controls, not AVPlayer/runtime measurements."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LAUNCHER = ROOT / 'native/tests/macos_phase_journey.py'
RECORDER = ROOT / 'native/macos/Sources/FixturePhaseMeasurement.swift'


class Launcher(unittest.TestCase):
    def test_optin_validation_precedes_application_and_default_loop_unchanged(self):
        main=(ROOT/'native/macos/Sources/main.swift').read_text()
        self.assertLess(main.index('FixturePhaseConfiguration.prepare'), main.index('let application = NSApplication.shared'))
        self.assertLess(main.index('if let configuration = phaseConfiguration'), main.index('if let saved = loadCredentials()'))
        journey=(ROOT/'native/macos/Sources/FixtureJourney.swift').read_text()
        self.assertIn('for row in stride(from:0,to:500,by:7) {self.table.scrollRowToVisible(row);try await Task.sleep(for:.milliseconds(20))}',journey)
        self.assertLess(journey.index('recorder.begin(.populatedIdle'),journey.index('"command":"clear_cache"'))

    def test_missing_app_retains_private_fixed_failure(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
            p = Path(tmp).resolve(strict=True)
            result = subprocess.run([sys.executable, '-B', str(LAUNCHER), '--app', str(p/'SECRET-MARKER.app'),
                                     '--artifact-manifest', str(p/'manifest.json'), '--fixture-home', str(p/'home'),
                                     '--run-id', 'control', '--evidence', str(p/'out')], capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            receipt = json.loads((p/'out/report.json').read_text())
            self.assertEqual(receipt['status'], 'failed')
            self.assertEqual(receipt['failure_codes'], ['invalid-artifact'])
            self.assertNotIn('SECRET-MARKER', (p/'out/report.json').read_text())
            self.assertEqual(result.stdout + result.stderr, b'')


class ControlledLauncher(unittest.TestCase):
    def exercise(self, mode='pass', timeout: float = 3, alter=None):
        from contextlib import nullcontext
        output = os.environ.get('SOUNDQ_PHASE_CONTROL_OUTPUT')
        if output:
            parent = Path(output); parent.mkdir(parents=True, exist_ok=True)
            context = nullcontext(tempfile.mkdtemp(prefix=mode+'-', dir=parent))
        else:
            context = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        with context as tmp:
            p = Path(tmp).resolve(strict=True)
            app = p/'Control.app'
            home = p/'fixture'; home.mkdir()
            (home/'credentials.json').write_text(json.dumps({'email':'SECRET-MARKER','password':'SECRET-MARKER'}))
            executable = app/'Contents/MacOS/control'
            executable.parent.mkdir(parents=True)
            # A controlled Python child, never an app/decoder or measured cohort.
            script = '''#!__PYTHON__
import json,os,time
from pathlib import Path
mode = __MODE__
assert __import__('sys').argv[1:] == ['--fixture-journey','--measure-phases']
assert 'DYLD_INSERT_LIBRARIES' not in os.environ
assert 'SOUNDQ_NATIVE_JOURNEY_REPORT' not in os.environ
if mode == 'timeout': time.sleep(30)
if mode == 'crash': raise SystemExit(7)
def boundary(t, audio):
 return dict(process=dict(monotonic_ns=t*1000000000,user_us=t*100000,system_us=t*100000,rss_bytes=t*100,failure_codes=[]),player_witness=1 if audio else None,item_witness=2 if audio else None,account_scope=2,epoch=2,session=1,occurrence=1 if audio else None,rows=500,settled=True,ready=audio,failed=False,position_seconds=t if audio else None,rate=1 if audio else 0,scroll_y=t*100)
phases=[]
for index,name in enumerate(['populated-idle','audio-active-idle','audio-active-scripted-row-jumps']):
 phases.append(dict(name=name,status='passed',start=boundary(index*2+1,index>0),end=boundary(index*2+2,index>0),elapsed_ns=1000000000,cpu_percent=20,rss_delta_bytes=100,cursor_delta_seconds=1 if index>0 else None,scroll_displacement=100,failure_codes=[]))
obj=dict(schema='soundq.macos.phase-diagnostic.v1',run_id=os.environ['SOUNDQ_PHASE_RUN_ID'],pid=os.getpid(),source_commit=os.environ['SOUNDQ_PHASE_SOURCE_COMMIT'],source_tree=os.environ['SOUNDQ_PHASE_SOURCE_TREE'],manifest_sha256=os.environ['SOUNDQ_PHASE_MANIFEST_SHA256'],status='passed',journey_passed=True,failure_codes=[],pending_phase=None,phases=phases)
if mode == 'pid': obj['pid']+=1
if mode == 'run': obj['run_id']='different'
if mode == 'source': obj['source_tree']='f'*40
if mode == 'secret': obj['failure_codes']=['SECRET-MARKER']
if mode == 'partial': obj.update(status='failed',journey_passed=False,failure_codes=['journey-failed'])
if mode == 'pending': obj.update(status='running',journey_passed=None,phases=phases[:1],pending_phase='audio-active-idle')
if mode == 'nonfinite': obj['phases'][0]['cpu_percent']=float('inf')
if mode == 'oversize': obj['failure_codes']=['SECRET-MARKER'*10000]
if mode == 'identity': obj['phases'][1]['end']['session']=9
if mode == 'stalled': obj['phases'][1]['end']['position_seconds']=3
if mode == 'cpu': obj['phases'][0]['cpu_percent']=999
# Each named mode changes only the report contract, not the launcher API.
fields = ['account_scope','epoch','session','occurrence','player_witness','item_witness','rows','rate','scroll_y','position_seconds']
for field in fields:
 if mode in ('null-'+field,'idle-null-'+field):
  for p in (phases[:1] if mode.startswith('idle-') else phases[1:]):
   for b in (p['start'],p['end']): b[field]=None
for field in ['account_scope','epoch','session','occurrence','player_witness','item_witness','rows']:
 for label,value in [('negative',-1),('bool',True),('float',1.0),('overflow',2**64)]:
  if mode == label+'-'+field:
   for p in phases[1:]:
    for b in (p['start'],p['end']): b[field]=value
for field in ['player_witness','item_witness']:
 if mode in ('zero-'+field,'int-overflow-'+field):
  for p in phases[1:]:
   for b in (p['start'],p['end']): b[field]=0 if mode.startswith('zero-') else 2**63
if mode == 'int-overflow-rows': phases[0]['start']['rows']=2**63
if mode in ('rss-outside-int64','rss-overflow-uint64','rss-negative','rss-bool','rss-float'):
 for p in phases:
  for b in (p['start'],p['end']):
   b['process']['rss_bytes']={'rss-outside-int64':2**63,'rss-overflow-uint64':2**64,'rss-negative':-1,'rss-bool':True,'rss-float':1.0}[mode]
  p['rss_delta_bytes']=0
if mode in ('rss-delta-outside-int64','rss-delta-below-int64','failed-rss-delta-outside-int64','failed-rss-delta-below-int64'):
 phases[0]['rss_delta_bytes']=-2**63-1 if mode.endswith('below-int64') else 2**63
 if mode.startswith('failed-'):
  phases[0].update(status='failed',failure_codes=['invalid-rss-delta'])
  obj.update(status='failed',journey_passed=False,failure_codes=['phase-rejected'])
if mode == 'failed-rss-uint64':
 p=phases[-1];p.update(status='failed',rss_delta_bytes=None,failure_codes=['invalid-rss-delta'])
 for b in (p['start'],p['end']): b['process']['rss_bytes']=2**64-1
 obj.update(status='failed',journey_passed=False,failure_codes=['phase-rejected'])
if mode in ('boundary-extremes','boundary-extremes-negative-rss'):
 for p in phases:
  for b in (p['start'],p['end']):
   for field in ['account_scope','epoch','session']: b[field]=2**64-1
   if p['name'] != 'populated-idle': b.update(occurrence=2**64-1,player_witness=2**63-1,item_witness=2**63-2)
   b['process'].update(user_us=2**64-1,system_us=2**64-1)
  p['cpu_percent']=0
  p['start']['process']['rss_bytes']=0 if mode == 'boundary-extremes' else 2**63-1
  p['end']['process']['rss_bytes']=2**63-1 if mode == 'boundary-extremes' else 0
  p['rss_delta_bytes']=p['end']['process']['rss_bytes']-p['start']['process']['rss_bytes']
 # UInt64 clock endpoints remain legal, independent of the signed RSS domain.
 for index,p in enumerate(phases):
  p['start']['process']['monotonic_ns']=2**64-1-(5-index*2)*1000000000
  p['end']['process']['monotonic_ns']=2**64-1-(4-index*2)*1000000000
if mode == 'zero-uint64-identities':
 for p in phases:
  for b in (p['start'],p['end']):
   b.update(account_scope=0,epoch=0,session=0)
   if p['name'] != 'populated-idle': b['occurrence']=0
if mode in ('overlapping-phases','reversed-phases','partial-overlap','adjacent-phases','gapped-phases','cpu-user-gap-reversal','cpu-system-gap-reversal','interrupted-gap-reversal','failed-counter-reversal'):
 for index,p in enumerate(phases):
  t={'overlapping-phases':1,'reversed-phases':5-index*2,'partial-overlap':1+index*.5,'adjacent-phases':1+index,'gapped-phases':1+index*3}.get(mode,1+index*3)
  for b,n in ((p['start'],t),(p['end'],t+1)):
   b['process'].update(monotonic_ns=int(n*1000000000),user_us=int(n*100000),system_us=int(n*100000))
 if mode in ('cpu-user-gap-reversal','cpu-system-gap-reversal','failed-counter-reversal'):
  field='system_us' if mode == 'cpu-system-gap-reversal' else 'user_us'
  for b in (phases[1]['start'],phases[1]['end']): b['process'][field]-=300000
 if mode == 'failed-counter-reversal':
  phases[1].update(status='failed',failure_codes=['action-failed'])
  obj.update(status='failed',journey_passed=False,failure_codes=['phase-rejected'])
 if mode == 'interrupted-gap-reversal':
  p=phases[1];p.update(status='failed',end=None,elapsed_ns=None,cpu_percent=None,rss_delta_bytes=None,cursor_delta_seconds=None,scroll_displacement=None,failure_codes=['phase-interrupted'])
  p['start']['process']['monotonic_ns']=500000000
  obj.update(status='failed',journey_passed=False,phases=phases[:2],failure_codes=['termination','missing-phases'])
if mode in ('null-failed','null-interrupted','null-running'):
 p=phases[1];p.update(status='failed',elapsed_ns=None,cpu_percent=None,rss_delta_bytes=None,cursor_delta_seconds=None,scroll_displacement=None,failure_codes=['phase-interrupted'] if mode == 'null-interrupted' else ['clock-read-failed','cpu-read-failed','rss-read-failed'])
 if mode == 'null-interrupted': p['end']=None
 for b in (p['start'],p['end']):
  if b is not None:
   for field in ['monotonic_ns','user_us','system_us','rss_bytes']: b['process'][field]=None
   b['process']['failure_codes']=['clock-read-failed','cpu-read-failed','rss-read-failed']
   for field in fields: b[field]=None
 obj.update(status='running' if mode == 'null-running' else 'failed',journey_passed=None if mode == 'null-running' else False,phases=phases[:2],failure_codes=[] if mode == 'null-running' else ['journey-failed'],pending_phase='audio-active-scripted-row-jumps' if mode == 'null-running' else None)
if mode == 'null-start-gap-reversal':
 p=phases[1];p.update(status='failed',failure_codes=['clock-read-failed'])
 p['start']['process']['monotonic_ns']=None
 p['end']['process']['monotonic_ns']=500000000
 obj.update(status='failed',journey_passed=False,failure_codes=['phase-rejected'])
if mode == 'failed-secret-boundary':
 phases[-1].update(status='failed',failure_codes=['action-failed'])
 phases[-1]['start']['account_scope']='SECRET-MARKER'
 obj.update(status='failed',journey_passed=False,failure_codes=['journey-failed'])
if mode == 'mutate': Path(__file__).write_text('SECRET-MARKER')
Path(os.environ['SOUNDQ_PHASE_REPORT']).write_text(json.dumps(obj))
if mode == 'disagree': raise SystemExit(3)
if mode == 'partial': raise SystemExit(1)
'''.replace('__PYTHON__', sys.executable).replace('__MODE__', repr(mode))
            executable.write_text(script); executable.chmod(0o700)
            paths = [('Contents/MacOS/control','executable'), ('Contents/Frameworks/libsoundq_core.dylib','core'), ('Contents/Resources/control.txt','resource'), ('Contents/Info.plist','metadata')]
            for rel,role in paths[1:]:
                dest = app/rel; dest.parent.mkdir(parents=True, exist_ok=True); dest.write_text('controlled-only')
            manifest = dict(schema='soundq.macos.artifact.v1',source_commit='a'*40,source_tree='b'*40,build_mode='release',executable=paths[0][0],files=[dict(path=rel,sha256=hashlib.sha256((app/rel).read_bytes()).hexdigest(),role=role) for rel,role in paths])
            if alter: alter(manifest,app,home)
            mf = p/'manifest.json'; mf.write_text(json.dumps(manifest))
            argv = [sys.executable,'-B',str(LAUNCHER),'--app',str(app),'--artifact-manifest',str(mf),'--fixture-home',str(home),'--run-id','control','--evidence',str(p/'out'),'--timeout-seconds',str(timeout)]
            result = subprocess.run(argv, capture_output=True, timeout=15)
            if output:
                (p/'stdout.log').write_bytes(result.stdout); (p/'stderr.log').write_bytes(result.stderr)
                (p/'execution.json').write_text(json.dumps(dict(mode=mode,argv=argv,cwd=str(Path.cwd()),exit_code=result.returncode,launcher_sha256=hashlib.sha256(LAUNCHER.read_bytes()).hexdigest(),tests_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),child_sha256=hashlib.sha256(script.encode()).hexdigest()),sort_keys=True)+'\n')
            self.assertEqual(result.stdout+result.stderr,b'')
            text = (p/'out/report.json').read_text()
            self.assertNotIn('SECRET-MARKER',text)
            self.assertNotIn(str(p),text)
            self.assertFalse((p/'out/child-report.json').exists())
            self.assertTrue((home/'credentials.json').exists())
            return result.returncode,json.loads(text)

    def test_controlled_success(self):
        for mode in ('pass','adjacent-phases','gapped-phases','boundary-extremes','boundary-extremes-negative-rss','zero-uint64-identities','idle-null-rate'):
            with self.subTest(mode=mode):
                code,obj=self.exercise(mode); self.assertEqual(code,0); self.assertEqual(obj['status'],'passed')
                self.assertEqual(obj['cleanup'],'reaped'); self.assertTrue(obj['artifact_after'])

    def test_child_failures_retained_and_reaped(self):
        expected={'pid':'child-identity-mismatch','run':'child-identity-mismatch','source':'child-identity-mismatch','crash':'missing-child-report','disagree':'child-exit-disagreement','partial':'child-report-failed','pending':'child-report-failed','secret':'invalid-child-report','nonfinite':'invalid-json','oversize':'invalid-json','mutate':'artifact-changed','identity':'invalid-child-report','stalled':'invalid-child-report','cpu':'invalid-child-report'}
        fields = ('account_scope','epoch','session','occurrence','player_witness','item_witness','rows')
        invalid = ['null-'+field for field in (*fields,'rate','scroll_y','position_seconds')]
        invalid += [label+'-'+field for field in fields for label in ('negative','bool','float','overflow')]
        invalid += ['idle-null-'+field for field in ('account_scope','epoch','session','rows','scroll_y')]
        invalid += ['failed-rss-delta-outside-int64','failed-rss-delta-below-int64','null-start-gap-reversal']
        invalid += ['zero-player_witness','zero-item_witness','int-overflow-player_witness','int-overflow-item_witness','int-overflow-rows','rss-outside-int64','rss-overflow-uint64','rss-negative','rss-bool','rss-float','rss-delta-outside-int64','rss-delta-below-int64','overlapping-phases','reversed-phases','partial-overlap','cpu-user-gap-reversal','cpu-system-gap-reversal','interrupted-gap-reversal','failed-counter-reversal','failed-secret-boundary']
        expected.update({mode:'invalid-child-report' for mode in invalid})
        retained = ('null-failed','null-interrupted','null-running','failed-rss-uint64')
        expected.update({mode:'child-report-failed' for mode in retained})
        for mode,failure in expected.items():
            with self.subTest(mode=mode):
                code,obj=self.exercise(mode); self.assertEqual(code,1); self.assertIn(failure,obj['failure_codes']); self.assertEqual(obj['cleanup'],'reaped')
                with self.assertRaises(ProcessLookupError): os.kill(obj['pid'],0)
                if mode in ('partial','pending',*retained):
                    self.assertEqual(obj['child_report']['phases'][0]['status'],'passed')
                if mode in retained:
                    phase=obj['child_report']['phases'][-1]
                    self.assertEqual(phase['status'],'failed'); self.assertIsNone(phase['rss_delta_bytes'])
                    if mode != 'failed-rss-uint64':
                        self.assertIsNone(phase['start']['process']['monotonic_ns'])
                        self.assertIsNone(phase['start']['session'])
                if mode in invalid:
                    self.assertIsNone(obj['child_report'])

    def test_timeout_reaps_only_owned_child(self):
        code,obj=self.exercise('timeout',timeout=.1); self.assertEqual(code,1)
        self.assertIn('child-timeout',obj['failure_codes']); self.assertEqual(obj['cleanup'],'reaped')
        with self.assertRaises(ProcessLookupError): os.kill(obj['pid'],0)

    def test_output_and_identity_refusals(self):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
            p=Path(tmp).resolve(strict=True)
            base=[sys.executable,'-B',str(LAUNCHER),'--app',str(p/'absent.app'),'--artifact-manifest',str(p/'absent.json'),'--fixture-home',str(p/'home'),'--run-id','control']
            existing=p/'existing';existing.mkdir()
            result=subprocess.run(base+['--evidence',str(existing)],capture_output=True,timeout=10)
            self.assertEqual(result.returncode,2);self.assertEqual(list(existing.iterdir()),[])
            for name,extra,code in [('timeout',['--timeout-seconds','nan'],'invalid-timeout'),('run',['--run-id','SECRET/MARKER'],'invalid-run-id')]:
                result=subprocess.run(base+extra+['--evidence',str(p/name)],capture_output=True,timeout=10)
                self.assertEqual(result.returncode,1)
                report=(p/name/'report.json').read_text();self.assertNotIn('SECRET/MARKER',report)
                self.assertEqual(json.loads(report)['failure_codes'],[code])

    def test_prelaunch_refusals_have_no_child(self):
        controls=[lambda m,a,h:m.update(source_commit='A'*40),lambda m,a,h:m['files'][0].update(sha256='0'*64),lambda m,a,h:(a/'extra').write_text('extra'),lambda m,a,h:(h/'credentials.json').write_text('{}'),lambda m,a,h:(a/'link').symlink_to(a/'Contents/Info.plist')]
        for control in controls:
            with self.subTest(control=controls.index(control)):
                code,obj=self.exercise(alter=control); self.assertEqual(code,1); self.assertIsNone(obj['pid'])


class Recorder(unittest.TestCase):
    @unittest.skipUnless(os.environ.get('SOUNDQ_PHASE_COMPILED') == '1', 'explicit compiler lane required')
    def test_real_recorder_injected_boundaries(self):
        self.assertTrue(RECORDER.is_file(), 'phase recorder missing')
        harness = r'''import Foundation
import Darwin
@main struct Probe {
static func main() throws {
    let p = NSObject(), i = NSObject()
    func playback(_ time: Double) -> PlaybackStamp {
        PlaybackStamp(player:p,item:i,account:1,epoch:2,session:3,occurrence:4,queue:[4],rows:500,settled:true,ready:true,failed:false,positionSeconds:time,rate:1,scrollY:time*100)
    }
    var tick:UInt64 = 0
    let recorder = FixturePhaseMeasurement(runID:"control",sourceCommit:String(repeating:"a",count:40),sourceTree:String(repeating:"b",count:40),manifestSHA256:String(repeating:"c",count:64),read:{
        tick += 1
        return ProcessStamp(monotonicNS:tick*1_000_000_000,userUS:tick*300_000,systemUS:tick*200_000,rssBytes:tick*100,errors:[])
    },write:{_ in})
    try recorder.begin(.audioIdle,playback:playback(1))
    try recorder.end(playback:playback(2))
    let result = recorder.phases[0]
    precondition(result.status == "passed")
    precondition(result.cpuPercent == 50 && result.rssDeltaBytes == 100)
    precondition(result.cursorDeltaSeconds == 1)
    try recorder.finish(journeyPassed:false,code:"journey-failed")
    precondition(recorder.phases[0].status == "passed")
    precondition(recorder.status == "failed")
    print("PASS recorder-cpu-rss-cursor partial-tail")
    let all = FixturePhaseMeasurement(runID:"all",sourceCommit:String(repeating:"a",count:40),sourceTree:String(repeating:"b",count:40),manifestSHA256:String(repeating:"c",count:64),read:{tick += 1;return ProcessStamp(monotonicNS:tick*1_000_000_000,userUS:tick*600_000,systemUS:tick*600_000,rssBytes:100,errors:[])},write:{_ in})
    let idle = PlaybackStamp(player:nil,item:nil,account:1,epoch:2,session:0,occurrence:nil,queue:[],rows:500,settled:true,ready:false,failed:false,positionSeconds:nil,rate:0,scrollY:0)
    try all.begin(.populatedIdle,playback:idle);try all.end(playback:idle)
    try all.begin(.audioIdle,playback:playback(1));try all.end(playback:playback(2))
    try all.begin(.audioScroll,playback:playback(1));try all.end(playback:playback(2))
    try all.finish(journeyPassed:true)
    precondition(all.status == "passed" && all.phases.count == 3 && all.phases[0].cpuPercent! > 100)
    let action = FixturePhaseMeasurement(runID:"control",sourceCommit:"a",sourceTree:"b",manifestSHA256:"c",read:{tick += 1;return ProcessStamp(monotonicNS:tick*1_000_000_000,userUS:tick,systemUS:tick,rssBytes:100,errors:[])},write:{_ in})
    try action.begin(.audioIdle,playback:playback(1))
    do {try action.end(playback:playback(2),code:"action-failed");preconditionFailure("action admitted")} catch {}
    precondition(action.phases[0].errors == ["action-failed"])
    var writes = 0
    let order = FixturePhaseMeasurement(runID:"control",sourceCommit:"a",sourceTree:"b",manifestSHA256:"c",read:{ProcessStamp.live()},write:{_ in writes += 1})
    func afterCheckpoint() -> PlaybackStamp {precondition(writes == 1);return idle}
    try order.begin(.populatedIdle,playback:afterCheckpoint())
    try order.finish(journeyPassed:false,code:"termination")
    precondition(order.phases[0].end == nil)
    print("PASS three-phases >100-percent-cpu action-failure checkpoint-order")
    var controls = 0
    func reject(_ label:String,_ first:PlaybackStamp,_ last:PlaybackStamp,_ stamp:ProcessStamp? = nil,_ phase:FixturePhase = .audioIdle) throws {
        var n:UInt64 = 0
        let r = FixturePhaseMeasurement(runID:"control",sourceCommit:"a",sourceTree:"b",manifestSHA256:"c",read:{n += 1;return stamp ?? ProcessStamp(monotonicNS:n*1_000_000_000,userUS:n*100,systemUS:n*100,rssBytes:100,errors:[])},write:{_ in})
        do {try r.begin(phase,playback:first);try r.end(playback:last);preconditionFailure("accepted \(label)")}
        catch {precondition(r.phases.count == 1 && r.phases[0].status == "failed",label)}
        controls += 1
    }
    func changed(_ time:Double = 2,player:AnyObject? = nil,item:AnyObject? = nil,account:UInt64 = 1,epoch:UInt64 = 2,session:UInt64 = 3,occurrence:UInt64? = 4,queue:[UInt64] = [4],rows:Int = 500,settled:Bool = true,ready:Bool = true,failed:Bool = false,rate:Double = 1,y:Double = 200) -> PlaybackStamp {
        PlaybackStamp(player:player ?? p,item:item ?? i,account:account,epoch:epoch,session:session,occurrence:occurrence,queue:queue,rows:rows,settled:settled,ready:ready,failed:failed,positionSeconds:time,rate:rate,scrollY:y)
    }
    try reject("stalled",playback(1),playback(1))
    try reject("nonfinite",playback(1),changed(.nan))
    try reject("seek",playback(1),playback(9))
    try reject("player",playback(1),changed(player:NSObject()))
    try reject("item",playback(1),changed(item:NSObject()))
    try reject("account",playback(1),changed(account:9))
    try reject("epoch",playback(1),changed(epoch:9))
    try reject("session",playback(1),changed(session:9))
    try reject("occurrence",playback(1),changed(occurrence:9))
    try reject("queue",playback(1),changed(queue:[4,5]))
    try reject("rows",playback(1),changed(rows:499))
    try reject("settled",playback(1),changed(settled:false))
    try reject("ready",playback(1),changed(ready:false))
    try reject("failed",playback(1),changed(failed:true))
    try reject("rate",playback(1),changed(rate:0))
    try reject("zero displacement",playback(1),changed(y:100),nil,.audioScroll)
    try reject("displacement overflow",changed(1,y: -Double.greatestFiniteMagnitude),changed(y:Double.greatestFiniteMagnitude),nil,.audioScroll)
    try reject("syscall",playback(1),playback(2),ProcessStamp(monotonicNS:nil,userUS:nil,systemUS:nil,rssBytes:nil,errors:["clock-read-failed","cpu-read-failed","rss-read-failed"]))
    try reject("clock",playback(1),playback(2),ProcessStamp(monotonicNS:1,userUS:1,systemUS:1,rssBytes:1,errors:[]))
    let interrupted = FixturePhaseMeasurement(runID:"control",sourceCommit:"a",sourceTree:"b",manifestSHA256:"c",read:{ProcessStamp.live()},write:{_ in})
    try interrupted.begin(.audioIdle,playback:playback(1))
    try interrupted.finish(journeyPassed:false,code:"termination")
    precondition(interrupted.phases[0].errors == ["phase-interrupted"] && interrupted.phases[0].end == nil)
    let writeFail = FixturePhaseMeasurement(runID:"control",sourceCommit:"a",sourceTree:"b",manifestSHA256:"c",write:{_ in throw PhaseFailure(code:"SECRET-MARKER")})
    do {try writeFail.begin(.audioIdle,playback:playback(1));preconditionFailure("write failure accepted")}
    catch let failure as PhaseFailure {precondition(failure.code == "report-write-failed")}
    let live = ProcessStamp.live()
    precondition(live.errors.isEmpty && live.monotonicNS! > 0 && live.rssBytes! > 0)
    let optOut = try FixturePhaseConfiguration.prepare(arguments:["probe"],environment:["SOUNDQ_NATIVE_FIXTURE_HOME":"/unread/SECRET-MARKER"])
    precondition(optOut == nil)
    for arguments in [["probe","--measure-phases"],["probe","--fixture-journey","--measure-phases=bad"],["probe","--fixture-journey","--measure-phases","--abi-smoke"]] {
        do {_ = try FixturePhaseConfiguration.prepare(arguments:arguments,environment:[:]);preconditionFailure("flags admitted")}
        catch let failure as PhaseFailure {precondition(failure.code == "invalid-flags")}
    }
    func testSetup(_ environment:[String:String],_ expected:String) {
        do {_ = try FixturePhaseConfiguration.prepare(arguments:["probe","--fixture-journey","--measure-phases"],environment:environment);preconditionFailure("setup admitted")}
        catch let failure as PhaseFailure {precondition(failure.code == expected,"expected \(expected), received \(failure.code)")}
        catch {preconditionFailure("untyped setup error")}
    }
    let base:[String:String] = ["SOUNDQ_PHASE_RUN_ID":"control","SOUNDQ_PHASE_SOURCE_COMMIT":String(repeating:"a",count:40),"SOUNDQ_PHASE_SOURCE_TREE":String(repeating:"b",count:40),"SOUNDQ_PHASE_MANIFEST_SHA256":String(repeating:"c",count:64),"OMP_API_BASE_URL":"http://127.0.0.1:54761/api/v1"]
    testSetup(base,"invalid-output")
    var bad = base;bad["OMP_API_BASE_URL"] = "https://SECRET-MARKER.invalid";testSetup(bad,"invalid-endpoint")
    bad = base;bad["SOUNDQ_PHASE_SOURCE_COMMIT"] = String(repeating:"A",count:40);testSetup(bad,"invalid-identity")
    // Read-only canonical system ancestor: no credential read or output write.
    precondition(!FileManager.default.fileExists(atPath:"/private/var/credentials.json"))
    var privateHome = base
    privateHome["SOUNDQ_NATIVE_FIXTURE_HOME"] = "/private/var"
    let root = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
    let home = root.appendingPathComponent("fixture"),out = root.appendingPathComponent("out")
    try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
    try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
    var configured = base
    configured["SOUNDQ_NATIVE_FIXTURE_HOME"] = home.path
    configured["SOUNDQ_NATIVE_CACHE_ROOT"] = out.appendingPathComponent("cache").path
    configured["SOUNDQ_PHASE_REPORT"] = out.appendingPathComponent("report.json").path
    privateHome["SOUNDQ_NATIVE_CACHE_ROOT"] = configured["SOUNDQ_NATIVE_CACHE_ROOT"]
    privateHome["SOUNDQ_PHASE_REPORT"] = configured["SOUNDQ_PHASE_REPORT"]
    testSetup(privateHome,"invalid-credentials")
    privateHome["SOUNDQ_NATIVE_FIXTURE_HOME"] = "/var";testSetup(privateHome,"invalid-output")
    testSetup(configured,"invalid-credentials")
    try Data("{}".utf8).write(to:home.appendingPathComponent("credentials.json"));testSetup(configured,"invalid-credentials")
    try Data(#"{"email":"SECRET-MARKER","password":"SECRET-MARKER"}"#.utf8).write(to:home.appendingPathComponent("credentials.json"))
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:root)
    let credential = home.appendingPathComponent("credentials.json")
    let saved = home.appendingPathComponent("saved.json")
    try FileManager.default.moveItem(at:credential,to:saved)
    try FileManager.default.createSymbolicLink(at:credential,withDestinationURL:saved)
    testSetup(configured,"invalid-credentials")
    try FileManager.default.removeItem(at:credential)
    try FileManager.default.moveItem(at:saved,to:credential)
    for key in ["SOUNDQ_NATIVE_FIXTURE_HOME","SOUNDQ_NATIVE_CACHE_ROOT","SOUNDQ_PHASE_REPORT"] {
        let original = configured[key]!
        for value in ["relative",original+"/.",original+"/..",original+"/",original+"\0suffix",original.replacingOccurrences(of:root.path,with:alias.path),original.replacingOccurrences(of:root.path,with:root.path+"/missing"),original.replacingOccurrences(of:root.path,with:root.path+"/")] {
            bad = configured;bad[key] = value;testSetup(bad,"invalid-output")
        }
    }
    let report = out.appendingPathComponent("report.json")
    try FileManager.default.createSymbolicLink(at:report,withDestinationURL:out.appendingPathComponent("missing"))
    testSetup(configured,"invalid-output")
    try FileManager.default.removeItem(at:report)
    let cache = out.appendingPathComponent("cache")
    try FileManager.default.createSymbolicLink(at:cache,withDestinationURL:home)
    testSetup(configured,"invalid-output")
    try FileManager.default.removeItem(at:cache)
    // Existing cache and missing report leaf are the launcher's real contract.
    try FileManager.default.createDirectory(at:cache,withIntermediateDirectories:false)
    let config = try FixturePhaseConfiguration.prepare(arguments:["probe","--fixture-journey","--measure-phases"],environment:configured)!
    let checkpoint = try String(contentsOf:out.appendingPathComponent("report.json"),encoding:.utf8)
    precondition(!checkpoint.contains("SECRET-MARKER") && !checkpoint.contains(home.path))
    testSetup(configured,"invalid-output")
    try FileManager.default.removeItem(at:report)
    try FileManager.default.removeItem(at:cache)
    _ = try FixturePhaseConfiguration.prepare(arguments:["probe","--fixture-journey","--measure-phases"],environment:configured)!
    precondition(FileManager.default.fileExists(atPath:report.path) && !FileManager.default.fileExists(atPath:cache.path))
    try FileManager.default.removeItem(at:root)
    _ = config
    print("PASS recorder-rejected-controls=\(controls) cancellation write-failure live-self-read opt-out invalid-flags setup-privacy")
}
}
'''
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
            p = Path(tmp).resolve(strict=True)
            source = p/'Probe.swift'
            source.write_text(harness)
            argv = ['/usr/bin/swiftc', '-swift-version', '6', '-target', 'arm64-apple-macosx14.0', '-j', '2', '-num-threads', '2', '-module-cache-path', str(p/'modules'), str(RECORDER), str(source), '-o', str(p/'probe')]
            result = subprocess.run(argv, capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            probe_environment = dict(os.environ)
            probe_environment.pop('TMPDIR', None)
            result = subprocess.run([str(p/'probe'), str(p)], env=probe_environment, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            print(result.stdout.strip())
            if os.environ.get('SOUNDQ_PHASE_PROBE_OUTPUT'):
                import shutil
                output = Path(os.environ['SOUNDQ_PHASE_PROBE_OUTPUT'])
                output.mkdir(exist_ok=False)
                for path in (source,p/'probe',RECORDER): shutil.copy2(path, output/path.name)
                (output/'compile-argv.json').write_text(json.dumps(argv,indent=2))
                (output/'run.log').write_text(result.stdout+result.stderr)
                for name,command in [('dependencies',['/usr/bin/otool','-L',str(p/'probe')]),('macho',['/usr/bin/file',str(p/'probe')]),('compiler',['/usr/bin/swiftc','--version'])]:
                    check = subprocess.run(command,capture_output=True,text=True,timeout=20)
                    self.assertEqual(check.returncode,0)
                    (output/(name+'.log')).write_text(check.stdout+check.stderr)


if __name__ == '__main__':
    unittest.main()
