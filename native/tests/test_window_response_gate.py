"""Synthetic captured-pixel receipts through the real offline CLI, not runtime."""
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from typing import Any

CLI=Path(__file__).with_name('window_response_gate.py')
LIMITS=['captured-window-change-not-physical-presentation','any-roi-change-not-semantic-causality',
        'synthetic-os-event-submission-not-delivery','caller-must-exclude-progress-caret-and-unrelated-animation','no-audio-qualification']


def write(path,obj):
    raw=json.dumps(obj,allow_nan=False).encode();path.write_bytes(raw)
    return dict(path=path.name,sha256=hashlib.sha256(raw).hexdigest())


def fixture(root,latency=1000, *, seed=0):
    env=dict(name='synthetic',platform='macos',device='synthetic',os='synthetic',renderer='appkit',
        viewport=[1000,800],physical_viewport=[2000,1600],scale=2,refresh_hz=60,font_scale=1,
        fonts='synthetic',audio_route='none',power='ac',quiet=True)
    geometry=dict(content_rect=dict(X=0,Y=0,Width=1000,Height=800),content_scale=1,height_px=1600,
        scale=2,screen_rect=dict(X=0,Y=0,Width=1000,Height=800),width_px=2000)
    capture=dict(roi_px=[100,100,20,20],input_point_screen_points=[200,200],scroll_pixels=-300,
        threshold=2,input_route='cg-hid-foreground',geometry=geometry,capture_requested_interval=dict(value=1,timescale=60))
    cohort:dict[str,Any]=dict(schema='soundq.window-response.cohort.v1',run_id='synthetic-only',
        source=dict(commit='a'*40,tree='b'*40),executable_sha256='c'*64,application_id='synthetic.app',
        build_mode='release',environment=env,workload=dict(name='synthetic-scroll',dataset='d'*64,
        loaded_order=['row-1'],queue_order=['not-playing'],selected='not-playing',cache='synthetic',
        animation='normal',input='os-scroll',route='library'),features=dict(name='synthetic',
        required=['scroll'],implemented=['scroll'],exercised=['scroll'],missing=[]),
        visible=dict(name='synthetic',columns=['title'],actions=[],artwork='none',geometry='synthetic'),
        capture=capture,attempts=[])
    for n in range(5):
        baseline=100000000+(seed*100+n)*100000000;before=baseline+5000000;after=before+1;display=before+latency
        samples=[dict(sequence=0,status=0,callback_ticks=str(baseline+1),display_ticks=str(baseline),
            pixel_read_end_ticks=str(baseline+2),predicate='baseline',roi_sha256='1'*64),
            dict(sequence=1,status=0,callback_ticks=str(before-100),display_ticks=str(before-101),
            pixel_read_end_ticks=str(before-99),predicate='preinput-negative',roi_sha256='1'*64,
            mean_absolute_rgb_change_0_255=0),
            dict(sequence=2,status=0,callback_ticks=str(display+1),display_ticks=str(display),
            pixel_read_end_ticks=str(display+2),predicate='first-qualified-change',roi_sha256='2'*64,
            mean_absolute_rgb_change_0_255=10)]
        report=dict(schema='soundq.window-response.v1',status='observed',failure_codes=[],
            physical_presentation_available=False,fps=None,response_lower_ns=0,
            response_upper_ns=(latency*125+2)//3,detected_by_upper_ns=((latency+3)*125+2)//3,
            pid=100+seed*100+n,window_id=200+seed*100+n,application_id='synthetic.app',executable_sha256='c'*64,
            clock=dict(domain='mach-absolute-time',unit='tick',numer=125,denom=3),
            input_ticks=[str(before),str(after)],limits=LIMITS,samples=samples,**capture)
        cohort['attempts'].append(dict(report=write(root/f'run-{n}.json',report),process_start='synthetic-'+str(seed)+'-'+str(n)))
    write(root/'cohort.json',cohort);return cohort


class WindowGate(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'));self.root=Path(self.tmp.name).resolve()
        self.base=self.root/'base';self.base.mkdir();self.new=self.root/'new';self.new.mkdir()
        self.a=fixture(self.base);self.b=fixture(self.new,seed=1);self.counter=0
    def tearDown(self):self.tmp.cleanup()
    def invoke(self,compare=False,expected=0,directory=None):
        self.counter+=1;out=self.root/f'out-{self.counter}'
        args=[sys.executable,'-B',str(CLI),'compare' if compare else 'baseline','--cohort',str((directory or (self.new if compare else self.base))/'cohort.json'),'--evidence',str(out)]
        if compare:args+=['--baseline-cohort',str(self.base/'cohort.json'),'--policy',str(self.root/'policy.json')]
        r=subprocess.run(args,capture_output=True,timeout=10)
        self.assertEqual(r.returncode,expected,r.stderr.decode());self.assertEqual(r.stderr,b'')
        d=json.loads((out/'report.json').read_bytes());self.assertNotIn(str(self.root),json.dumps(d));return d,out
    def policy(self,relative=0,absolute=0):
        d,_=self.invoke();write(self.root/'policy.json',dict(schema='soundq.window-response.policy.v1',
            baseline_sha256=d['baseline_sha256'],reviewer='synthetic-not-runtime',
            calibration=dict(cohort_sha256=d['cohort_sha256'],rationale='synthetic-zero-noise'),
            budget=dict(relative_allowance=relative,absolute_allowance=absolute)))
    def mutate(self,n,fn):
        p=self.new/f'run-{n}.json';r=json.loads(p.read_bytes());fn(r);self.b['attempts'][n]['report']=write(p,r);write(self.new/'cohort.json',self.b)
    def test_success_recomputes_bounds_without_physical_claim(self):
        self.policy();d,_=self.invoke(True);self.assertEqual(d['status'],'passed');self.assertFalse(d['full_app_accepted']);self.assertIsNone(d['comparison'])
        self.assertEqual(d['candidate']['admitted_only']['p50'],41667)
        self.assertFalse(d['candidate']['attempts'][0]['detected_by_verified'])
    def test_budget_breach_equality_and_no_ratchet(self):
        self.policy(relative=1);raw=(self.root/'policy.json').read_bytes()
        self.b=fixture(self.new,2000,seed=1);self.invoke(True)
        self.b=fixture(self.new,3000,seed=1);d,_=self.invoke(True,1);self.assertIn('budget-breached',d['reasons'])
        self.assertEqual((self.root/'policy.json').read_bytes(),raw)
    def test_tick_tail_threshold_geometry_identity_mutations(self):
        self.policy()
        mutations=[lambda r:r.update(response_upper_ns=1),lambda r:r['samples'][-1].update(display_ticks=r['input_ticks'][0]),
            lambda r:r['samples'][-1].update(mean_absolute_rgb_change_0_255=0),lambda r:r['samples'][-1].update(roi_sha256='1'*64),
            lambda r:r['samples'][1].update(callback_ticks='1'),lambda r:r['clock'].update(denom=0),
            lambda r:r.update(physical_presentation_available=True),lambda r:r.update(executable_sha256='f'*64),
            lambda r:r['geometry'].update(scale=1),lambda r:r.update(input_point_screen_points=[9999,9999]),
            lambda r:r['samples'][-1].update(pixel_read_end_ticks='1'),lambda r:r.update(limits=[]),
            lambda r:r.update(response_upper_ns=True),lambda r:r['samples'][-1].update(predicate='negative')]
        for fn in mutations:
            self.b=fixture(self.new,seed=1);self.mutate(4,fn);d,_=self.invoke(True,1);self.assertFalse(d['candidate']['attempts'][-1]['admitted'])
    def test_failed_trial_retained_and_inconclusive_capture(self):
        self.policy();self.mutate(4,lambda r:r.update(status='failed',failure_codes=['capture-cleanup-failed']))
        d,_=self.invoke(True,1);self.assertEqual(d['candidate']['failure_inclusive']['sample_count'],5);self.assertEqual(d['candidate']['admitted_only']['sample_count'],4)
        self.b=fixture(self.new,seed=1);self.b['environment']['font_scale']=2;write(self.new/'cohort.json',self.b)
        d,_=self.invoke(True,1);self.assertEqual(d['status'],'inconclusive');self.assertIsNone(d['comparison'])
    def test_replay_missing_hash_mismatch_and_unqualified(self):
        self.policy();self.b['attempts'][-1]=copy.deepcopy(self.b['attempts'][0]);write(self.new/'cohort.json',self.b);self.invoke(True,1)
        self.b=fixture(self.new,seed=1);p=self.new/'run-4.json';raw=p.read_bytes()+b' ';p.write_bytes(raw);d,out=self.invoke(True,1)
        self.assertEqual((out/'bundle-0/inputs'/hashlib.sha256(raw).hexdigest()).read_bytes(),raw)
        self.b=fixture(self.new,seed=1);(self.new/'run-4.json').unlink();d,_=self.invoke(True,1);self.assertEqual(len(d['candidate']['attempts']),5)
        for mutation in [lambda c:c.update(attempts=c['attempts'][:1]),lambda c:c['environment'].update(quiet=False),lambda c:c['environment'].update(refresh_hz=None)]:
            self.a=fixture(self.base);mutation(self.a);write(self.base/'cohort.json',self.a);d,_=self.invoke(expected=1);self.assertEqual(d['status'],'unqualified')
    def test_unknown_duplicate_nonfinite_policy_and_output_refusals(self):
        self.policy();p=self.root/'policy.json';original=json.loads(p.read_bytes())
        for key,value in [('reviewer',''),('baseline_sha256','0'*64),('schema','unknown')]:
            d=copy.deepcopy(original);d[key]=value;write(p,d);self.invoke(True,1)
        for raw in [b'{',b'{"schema":1,"schema":2}',b'{"x":NaN}']:
            (self.base/'cohort.json').write_bytes(raw);d,_=self.invoke(expected=1);self.assertEqual(d['status'],'failed')
        out=self.root/'exists';out.mkdir();(out/'marker').write_text('keep')
        r=subprocess.run([sys.executable,str(CLI),'baseline','--cohort',str(self.new/'cohort.json'),'--evidence',str(out)],capture_output=True)
        self.assertEqual(r.returncode,2);self.assertEqual((out/'marker').read_text(),'keep')

    def test_terminal_statuses_and_any_postpositive_sample_refused(self):
        self.policy()
        def insert(report,status,after_positive=False):
            samples=report['samples']
            callback=int(samples[-1]['pixel_read_end_ticks'])+1 if after_positive else int(samples[-2]['pixel_read_end_ticks'])+1
            sample=dict(sequence=0,status=status,callback_ticks=str(callback))
            samples.insert(len(samples) if after_positive else len(samples)-1,sample)
            for i,s in enumerate(samples):s['sequence']=i
        for status in [2,3,5]:
            self.b=fixture(self.new,seed=1);self.mutate(4,lambda r:insert(r,status));d,_=self.invoke(True,1)
            self.assertFalse(d['candidate']['attempts'][-1]['admitted'])
        self.b=fixture(self.new,seed=1);self.mutate(4,lambda r:insert(r,1,True));self.invoke(True,1)


    def test_same_cohort_cannot_compare_against_itself(self):
        self.policy()
        d,_=self.invoke(True,1,directory=self.base)
        self.assertEqual(d['status'],'failed')
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_one_copied_renamed_report_rejects_partial_overlap(self):
        self.policy()
        raw=(self.base/'run-0.json').read_bytes()
        (self.new/'renamed.json').write_bytes(raw)
        self.b['attempts'][4]=dict(report=dict(path='renamed.json',sha256=hashlib.sha256(raw).hexdigest()),
            process_start='renamed-reference-not-a-new-observation')
        write(self.new/'cohort.json',self.b)
        before={p:p.read_bytes() for p in [*self.base.iterdir(),self.root/'policy.json']}
        d,_=self.invoke(True,1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        self.assertEqual(len(d['candidate']['attempts']),5)
        self.assertTrue(all(r['admitted'] for r in d['candidate']['attempts']))
        self.assertIsNotNone(d['candidate']['failure_inclusive'])
        self.assertEqual({p:p.read_bytes() for p in before},before)

    def test_overlap_hidden_in_failed_hash_attempt_is_retained(self):
        self.policy()
        raw=(self.base/'run-0.json').read_bytes()
        (self.new/'failed-copy.json').write_bytes(raw)
        self.b['attempts'].append(dict(report=dict(path='failed-copy.json',sha256='0'*64),
            process_start='failed-copy-distinct-label'))
        write(self.new/'cohort.json',self.b)
        d,out=self.invoke(True,1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        rows=d['candidate']['attempts']
        self.assertEqual(len(rows),6);self.assertFalse(rows[-1]['admitted'])
        self.assertIn('hash-mismatch',rows[-1]['reasons'])
        digest=hashlib.sha256(raw).hexdigest()
        self.assertEqual(rows[-1]['evidence_identity']['raw_sha256'],digest)
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertIsNotNone(d['candidate']['failure_inclusive'])

    def test_supplied_lifetime_reuse_survives_reencoding_and_failed_status(self):
        self.policy()
        old=json.loads((self.base/'run-0.json').read_bytes())
        old['status']='failed'
        old['failure_codes']=['synthetic-failure']
        self.b['attempts'][4]['process_start']=self.a['attempts'][0]['process_start']
        self.b['attempts'][4]['report']=write(self.new/'run-4.json',old)
        write(self.new/'cohort.json',self.b)
        d,_=self.invoke(True,1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        self.assertFalse(d['candidate']['attempts'][4]['admitted'])
        self.assertIsNotNone(d['candidate']['failure_inclusive'])

    def test_independent_equal_values_same_source_and_reused_pid_pass(self):
        self.policy()
        for n in range(5):
            pid=json.loads((self.base/f'run-{n}.json').read_bytes())['pid']
            def reuse_pid(r):
                r['pid']=pid
                if 'child_report' in r:r['child_report']['pid']=pid
            self.mutate(n,reuse_pid)
        # OS PIDs can be recycled: distinct supplied lifetimes are not replay.
        def recycle_within(r):
            r['pid']=100
            if 'child_report' in r:r['child_report']['pid']=100
        self.mutate(4,recycle_within)
        before={p:p.read_bytes() for p in [*self.base.iterdir(),self.root/'policy.json']}
        d,_=self.invoke(True)
        self.assertEqual(d['status'],'passed');self.assertIsNone(d['comparison'])
        self.assertFalse(d['full_app_accepted'])
        self.assertEqual({p:p.read_bytes() for p in before},before)

    def test_hash_mismatch_preserves_actual_raw_identity_and_bytes(self):
        self.policy()
        p=self.new/'run-4.json';raw=p.read_bytes()+b' '
        p.write_bytes(raw)
        d,out=self.invoke(True,1)
        row=d['candidate']['attempts'][4]
        self.assertIn('hash-mismatch',row['reasons']);self.assertFalse(row['admitted'])
        digest=hashlib.sha256(raw).hexdigest()
        self.assertEqual(row.get('evidence_identity',{}).get('raw_sha256'),digest)
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertNotIn('baseline-candidate-evidence-replay',d['reasons'])


    def test_invalid_json_preserves_known_start_label_and_parse_refusal(self):
        self.policy()
        raw=b'{"run_id":"incomplete-run",'
        (self.new/'broken.json').write_bytes(raw)
        digest=hashlib.sha256(raw).hexdigest()
        label=self.a['attempts'][0]['process_start']
        self.b['attempts'].append(dict(process_start=label,
            report=dict(path='broken.json',sha256=digest)))
        write(self.new/'cohort.json',self.b)
        d,out=self.invoke(True,1)
        row=d['candidate']['attempts'][-1]
        self.assertEqual(row['reasons'],['invalid-json'])
        self.assertEqual(row['evidence_identity'],dict(process_start=label,raw_sha256=digest))
        self.assertIsNone(row['response_upper_ns']);self.assertFalse(row['admitted'])
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_declared_baseline_digest_does_not_create_false_overlap(self):
        self.policy()
        path=self.new/'run-4.json';raw=path.read_bytes()
        declared=self.a['attempts'][0]['report']['sha256']
        digest=hashlib.sha256(raw).hexdigest();self.assertNotEqual(digest,declared)
        self.b['attempts'][4]['report']['sha256']=declared
        write(self.new/'cohort.json',self.b)
        d,out=self.invoke(True,1)
        row=d['candidate']['attempts'][4]
        self.assertEqual(row['reasons'],['hash-mismatch'])
        self.assertEqual(row['evidence_identity']['raw_sha256'],digest)
        self.assertNotIn('run_id',row['evidence_identity'])
        self.assertNotIn('process_start_wall_ns',row['evidence_identity'])
        self.assertIsNone(row['response_upper_ns']);self.assertFalse(row['admitted'])
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertNotIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_reencoded_hash_refusal_has_no_invented_launch_overlap(self):
        self.policy()
        original=(self.base/'run-0.json').read_bytes()
        raw=json.dumps(json.loads(original),indent=2,allow_nan=False).encode()+b'\n'
        self.assertNotEqual(raw,original)
        (self.new/'reencoded.json').write_bytes(raw)
        self.b['attempts'].append(dict(report=dict(path='reencoded.json',sha256='0'*64),
            process_start='independent-hash-refused-label'))
        write(self.new/'cohort.json',self.b)
        d,out=self.invoke(True,1)
        row=d['candidate']['attempts'][-1]
        self.assertEqual(row['reasons'],['hash-mismatch'])
        self.assertFalse(row['admitted']);self.assertIsNone(row['response_upper_ns'])
        digest=hashlib.sha256(raw).hexdigest()
        self.assertEqual(row['evidence_identity']['raw_sha256'],digest)
        self.assertNotIn('run_id',row['evidence_identity'])
        self.assertNotIn('process_start_wall_ns',row['evidence_identity'])
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertNotIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_unknown_attempt_key_preserves_known_start_label(self):
        self.policy()
        label=self.a['attempts'][0]['process_start']
        self.b['attempts'].append(dict(process_start=label,unknown=True,
            report=copy.deepcopy(self.b['attempts'][0]['report'])))
        write(self.new/'cohort.json',self.b)
        d,_=self.invoke(True,1)
        row=d['candidate']['attempts'][-1]
        self.assertEqual(d['status'],'failed')
        self.assertEqual(row['reasons'],['unknown-or-missing-key'])
        self.assertFalse(row['admitted']);self.assertIsNone(row['response_upper_ns'])
        self.assertEqual(row['evidence_identity'],dict(process_start=label))
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_supplied_start_label_alone_rejects_cross_cohort_reuse(self):
        self.policy()
        self.b['attempts'][4]['process_start']=self.a['attempts'][0]['process_start']
        write(self.new/'cohort.json',self.b)
        d,_=self.invoke(True,1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        self.assertTrue(all(r['admitted'] for r in d['candidate']['attempts']))


if __name__=='__main__':unittest.main()
