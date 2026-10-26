"""Real launcher CLI controls. Every child/frame byte here is synthetic."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
CLI = ROOT/'native/tests/flutter_profile_launch.py'


class Launch(unittest.TestCase):
    def exercise(self, mode='good', mutate=None, existing=False):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as temp:
            root = Path(temp).resolve()
            app = root/'Control.app'
            exe = app/'Contents/MacOS/Control'
            exe.parent.mkdir(parents=True)
            script = r'''#!__PYTHON__
import hashlib,json,os,time,urllib.request,socket
from pathlib import Path
v=json.loads(os.environ['SOUNDQ_FIXTURE_DESCRIPTOR'])
mode=__MODE__
if mode=='timeout':time.sleep(30)
if mode=='slow':
 s=socket.create_connection(('127.0.0.1',54762));s.sendall(b'POST /report HTTP/1.1\r\n')
 for _ in range(100):
  try:s.sendall(b'X-Drip: a\r\n');time.sleep(.1)
  except OSError:time.sleep(30)
f=dict(frameNumber=1,vsyncStart=100,buildStart=101,buildFinish=103,rasterStart=103,rasterFinish=105,rasterFinishWallTime=999,uiUs=2,rasterUs=2,totalSpanUs=5,vsyncOverheadUs=1)
r=dict(schema='soundq.flutter.actual-root.profile.v1',source_commit=v['source_commit'],source_tree=v['source_tree'],source_manifest_sha256=v['source_manifest_sha256'],run_id=v['run_id'],pid=os.getpid(),build_mode='profile',entrypoint='production.main',route='/library',status='completed-diagnostic',hold='audio-native-readback-unavailable',preferences='ephemeral-plugin-adapter',audio='unavailable-native-readback-not-proven',full_app_accepted=False,framework_error_count=0,loaded_list_slots=500,witnessed_row_ids=[1],physical_viewport=[1440,900],scale=1,clock='flutter-frame-timing',boundary_clock='SchedulerBinding.currentSystemFrameTimeStamp',boundary_frames_requested=True,windows=[dict(name='populated-idle',clock='flutter-frame-timing',start=99,end=106,audio_active=False,cursor=None,scroll_start=0,scroll_end=0,scroll_max_extent=1000,scroll_distance=0,motion=False,frame_count=1)],scroll_legs=[],rawFrames=[f])
r['windows'].append(dict(r['windows'][0],name='populated-scroll-audio-unavailable',start=106,end=120,scroll_end=0,scroll_distance=4000,motion=True))
r.update(storage='EPHEMERAL STORAGE',artwork='placeholder-only-memory-cache',excluded_operations=['disk','downloads','playback-cache','artwork-acquisition','audio'])
r['rawFrames'].append(dict(f,frameNumber=2,vsyncStart=110,buildStart=111,buildFinish=113,rasterStart=113,rasterFinish=115))
r['windows'][0].update(start=99,end=3200100)
r['windows'][1].update(start=3200100,end=11200100)
r['rawFrames'][1].update(vsyncStart=3200110,buildStart=3200111,buildFinish=3200113,rasterStart=3200113,rasterFinish=3200115)
r['scroll_legs']=[dict(target=1000 if n%2==0 else 0,offset=1000 if n%2==0 else 0,elapsed_us=2000000,requested_us=2000000) for n in range(4)]
if mode=='source':r['source_tree']='f'*40
if mode=='pid':r['pid']+=1
if mode=='unknown':r['password']='SECRET-MARKER'
if mode=='badframe':r['rawFrames'][0]['uiUs']=999
if mode=='bigint':r['scale']=10**1000
if mode=='leg':r['scroll_legs'][0]['elapsed_us']=1
if mode=='missing':r['windows']=r['windows'][:1]
if mode=='zero-legs':r['scroll_legs']=[dict(target=0,offset=0,elapsed_us=2000000,requested_us=2000000) for _ in range(4)]
if mode=='bad-hold':r['hold']='journey-failed'
if mode=='compressed':r['windows'][1]['end']=3200120
if mode=='oversize':r['rawFrames']=[{}]*100001
if mode=='failed':r['status']='failed';r['hold']='journey-failed'
if mode=='artifact':Path(__file__).write_text('changed')
b=json.dumps(r).encode()
token=v['report_token'] if mode!='token' else '0'*64
q=urllib.request.Request('http://127.0.0.1:54762/report',data=b,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'},method='POST')
try:
 with urllib.request.urlopen(q,timeout=3) as response:
  ack=json.load(response);assert ack==dict(run_id=v['run_id'],sha256=hashlib.sha256(b).hexdigest(),persisted=True)
except Exception:pass
'''.replace('__PYTHON__', sys.executable).replace('__MODE__', repr(mode))
            exe.write_text(script); exe.chmod(0o700)
            identity=dict(source_commit='a'*40,source_tree='b'*40,source_manifest_sha256='c'*64)
            manifest=root/'artifact.json'
            base=[sys.executable,'-B',str(CLI)]
            create=subprocess.run(base+['manifest','--app',str(app),'--executable','Contents/MacOS/Control','--source-commit',identity['source_commit'],'--source-tree',identity['source_tree'],'--source-manifest-sha256',identity['source_manifest_sha256'],'--output',str(manifest)],capture_output=True,timeout=10)
            self.assertEqual(create.returncode,0,create.stderr.decode())
            descriptor=root/'descriptor.json'
            d=dict(schema='soundq.flutter.fixture.process.v1',endpoint='http://127.0.0.1:54761/api/v1',email='SECRET-MARKER',password='SECRET-MARKER',run_id='control',report_token='d'*64,**identity)
            if mutate:mutate(d)
            descriptor.write_text(json.dumps(d));descriptor.chmod(0o600)
            if existing:
                (root/'out').mkdir();(root/'out/report.json').write_text('{"marker":true}')
            start=time.monotonic()
            result=subprocess.run(base+['run','--app',str(app),'--manifest',str(manifest),'--descriptor',str(descriptor),'--evidence',str(root/'out'),'--timeout-seconds','1'],capture_output=True,timeout=15)
            if mode=='slow':self.assertLess(time.monotonic()-start,5)
            report=json.loads((root/'out/report.json').read_bytes())
            all_output=result.stdout+result.stderr+(root/'out/report.json').read_bytes()
            self.assertNotIn(b'SECRET-MARKER',all_output)
            if report.get('pid') is not None:
                self.assertEqual(report['cleanup'],'reaped')
                self.assertNotEqual(subprocess.run(['ps','-p',str(report['pid']),'-o','comm='],capture_output=True).returncode,0)
            return result.returncode,report

    def test_completed_renderer_diagnostic_is_not_full_app_acceptance(self):
        code,r=self.exercise()
        self.assertEqual(code,0,r)
        self.assertEqual(r['status'],'completed-diagnostic')
        self.assertFalse(r['full_app_accepted'])
        self.assertTrue(r['artifact_before'] and r['artifact_after'])
        self.assertEqual(r['renderer']['flutter_ui_us']['p50'],2)

    def test_each_identity_privacy_frame_and_artifact_mutation_fails(self):
        for mode in ['source','pid','unknown','badframe','bigint','leg','missing','zero-legs','bad-hold','compressed','oversize','token','artifact','failed','timeout','slow']:
            with self.subTest(mode=mode):
                code,r=self.exercise(mode)
                self.assertEqual(code,1,r)
                self.assertEqual(r['status'],'failed')
                self.assertTrue(r['failure_codes'])

    def test_descriptor_mismatch_refuses_before_launch(self):
        for key,value in [('endpoint','https://personal.invalid/api/v1'),('source_tree','f'*40),('run_id','../bad'),('report_token','bad')]:
            with self.subTest(key=key):
                code,r=self.exercise(mutate=lambda d:d.update({key:value}))
                self.assertEqual(code,1)
                self.assertIsNone(r['pid'])

    def test_existing_output_is_not_overwritten(self):
        code,r=self.exercise(existing=True)
        self.assertEqual(code,2)
        self.assertEqual(r,{'marker':True})

    def test_unreadable_subtree_fails_inventory_not_silently_skipped(self):
        from flutter_profile_launch import inventory
        from matched_performance import Invalid
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
            app=Path(tmp).resolve()/'Control.app';app.mkdir()
            def denied(*args,**kwargs):
                kwargs['onerror'](PermissionError('private-path-must-not-export'))
                return iter([])
            with patch('flutter_profile_launch.os.walk',side_effect=denied):
                with self.assertRaisesRegex(Invalid,'unreadable-bundle-subtree'):
                    inventory(app)


if __name__=='__main__':
    unittest.main()
