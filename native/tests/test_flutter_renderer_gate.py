"""Synthetic raw reports exercised through the real CLI, never runtime data."""
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

CLI = Path(__file__).with_name('flutter_renderer_gate.py')
PHASE = 'populated-scroll-audio-unavailable'
METRICS = ('flutter_ui_us', 'flutter_raster_us', 'flutter_total_span_us', 'flutter_vsync_overhead_us')


def write(path, value):
    raw = json.dumps(value, allow_nan=False).encode()
    path.write_bytes(raw)
    return {'path': path.name, 'sha256': hashlib.sha256(raw).hexdigest()}


def child(n, factor=1) -> dict[str, Any]:
    def frame(i, start):
        ui, raster, overhead = 10*factor, 20*factor, 5*factor
        return dict(frameNumber=i, vsyncStart=start, buildStart=start+overhead,
                    buildFinish=start+overhead+ui, rasterStart=start+overhead+ui,
                    rasterFinish=start+overhead+ui+raster, rasterFinishWallTime=999999,
                    uiUs=ui, rasterUs=raster, totalSpanUs=overhead+ui+raster,
                    vsyncOverheadUs=overhead)
    idle = dict(name='populated-idle', clock='flutter-frame-timing', start=1,
                end=3200001, audio_active=False, cursor=None, scroll_start=0,
                scroll_end=0, scroll_max_extent=1000, scroll_distance=0,
                motion=False, frame_count=1)
    scroll = dict(idle, name=PHASE, start=3200001, end=11200001,
                  scroll_distance=4000, motion=True, frame_count=100)
    return dict(schema='soundq.flutter.actual-root.profile.v1', source_commit='a'*40,
        source_tree='b'*40, source_manifest_sha256='c'*64, run_id='synthetic-'+str(n),
        pid=100+n, build_mode='profile', entrypoint='production.main', route='/library',
        status='completed-diagnostic', hold='audio-native-readback-unavailable',
        preferences='ephemeral-plugin-adapter', storage='EPHEMERAL STORAGE',
        artwork='placeholder-only-memory-cache', excluded_operations=['disk','downloads','playback-cache','artwork-acquisition','audio'],
        audio='unavailable-native-readback-not-proven', full_app_accepted=False,
        framework_error_count=0, loaded_list_slots=500, witnessed_row_ids=[1,2,3],
        physical_viewport=[2880,1800], scale=2, clock='flutter-frame-timing',
        boundary_clock='SchedulerBinding.currentSystemFrameTimeStamp',
        boundary_frames_requested=True, windows=[idle,scroll],
        scroll_legs=[dict(target=1000 if i%2==0 else 0, offset=1000 if i%2==0 else 0,
                          elapsed_us=2000000, requested_us=2000000) for i in range(4)],
        rawFrames=[frame(1,100)]+[frame(i+2,3200100+i*70000) for i in range(100)])


def fixture(root, factor=1, *, seed=0) -> dict[str, Any]:
    from flutter_profile_launch import validate_report
    cohort: dict[str, Any] = dict(schema='soundq.flutter.renderer-cohort.v1', run_id='synthetic-only',
        source=dict(commit='a'*40,tree='b'*40), source_manifest_sha256='c'*64,
        artifact_manifest_sha256='d'*64, build_mode='profile',
        environment=dict(name='synthetic-only',platform='macos',device='synthetic',os='synthetic',
            renderer='flutter.engine',viewport=[1440,900],physical_viewport=[2880,1800],
            scale=2,refresh_hz=60,font_scale=1,fonts='synthetic',audio_route='none',power='ac',quiet=True),
        workload=dict(name='synthetic-library',dataset='e'*64,loaded_order=['row-'+str(i) for i in range(1,501)],
            queue_order=['not-playing'],selected='not-playing',
            cache='ephemeral',animation='normal',input='four-complete-scroll-legs',route='/library',
            storage='EPHEMERAL STORAGE',artwork='placeholder-only-memory-cache',audio='unavailable-native-readback-not-proven'),
        features=dict(name='synthetic',required=['library-scroll'],implemented=['library-scroll'],exercised=['library-scroll'],missing=[]),
        visible=dict(name='synthetic',columns=['title'],artwork='placeholder-only-memory-cache',actions=[],geometry='synthetic'),attempts=[])
    for n in range(5):
        c=child(seed*100+n,factor)
        report=dict(schema='soundq.flutter.profile-launch.v1',status='completed-diagnostic',
            run_id=c['run_id'],pid=c['pid'],process_start_wall_ns=1000000000+seed*100+n,
            failure_codes=[],artifact_before=True,artifact_after=True,cleanup='reaped',
            child_report=c,renderer=validate_report(c,c,c['pid']),full_app_accepted=False,
            limits=['renderer-not-physical-presentation','non-audio-ephemeral-storage-diagnostic','caller-provenance-not-compilation-proof'],
            artifact_manifest_sha256='d'*64,source={k:c[k] for k in ['source_commit','source_tree','source_manifest_sha256']},exit_code=-15)
        cohort['attempts'].append(dict(report=write(root/f'run-{n}.json',report),process_start='synthetic-start-'+str(seed)+'-'+str(n)))
    write(root/'cohort.json',cohort)
    return cohort


class RendererGate(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.root=Path(self.temp.name).resolve()
        self.base=self.root/'base';self.base.mkdir()
        self.new=self.root/'new';self.new.mkdir()
        self.a=fixture(self.base);self.b=fixture(self.new,seed=1);self.counter=0

    def tearDown(self):self.temp.cleanup()

    def invoke(self, compare=False, expected=0, directory=None):
        self.counter+=1
        out=self.root/f'output-{self.counter}'
        args=[sys.executable,'-B',str(CLI),'compare' if compare else 'baseline',
              '--cohort',str((directory or (self.new if compare else self.base))/'cohort.json'),'--evidence',str(out)]
        if compare:args+=['--baseline-cohort',str(self.base/'cohort.json'),'--policy',str(self.root/'policy.json')]
        r=subprocess.run(args,capture_output=True,timeout=10)
        self.assertEqual(r.returncode,expected,r.stderr.decode())
        self.assertEqual(r.stderr,b'')
        d=json.loads((out/'report.json').read_bytes())
        self.assertNotIn(str(self.root),json.dumps(d))
        return d,out

    def policy(self, relative=0, absolute=0):
        d,_=self.invoke()
        write(self.root/'policy.json',dict(schema='soundq.flutter.renderer-policy.v1',
            baseline_sha256=d['baseline_sha256'],reviewer='synthetic-not-runtime',
            calibration=dict(cohort_sha256=d['cohort_sha256'],rationale='synthetic-only-zero-noise'),
            budgets={PHASE:{m:{q:dict(relative_allowance=relative,absolute_allowance=absolute)
                for q in ['p95','max']} for m in METRICS}}))

    def mutate(self,n,fn):
        p=self.new/f'run-{n}.json';d=json.loads(p.read_bytes());fn(d)
        self.b['attempts'][n]['report']=write(p,d);write(self.new/'cohort.json',self.b)

    def test_baseline_compare_and_no_physical_claim(self):
        self.policy();d,_=self.invoke(True)
        self.assertEqual(d['status'],'passed');self.assertIsNone(d['comparison'])
        self.assertFalse(d['full_app_accepted'])
        stats=d['candidate']['failure_inclusive'][PHASE]['flutter_ui_us']['p95']
        self.assertEqual(stats['sample_count'],5);self.assertEqual(stats['p50'],10)

    def test_budget_breach_and_equality_allowances_do_not_ratchet(self):
        self.policy(relative=1);raw=(self.root/'policy.json').read_bytes()
        self.b=fixture(self.new,2,seed=1);d,_=self.invoke(True);self.assertEqual(d['status'],'passed')
        self.b=fixture(self.new,3,seed=1);d,_=self.invoke(True,1)
        self.assertIn('budget-breached',d['reasons']);self.assertTrue(d['breaches'])
        self.assertEqual((self.root/'policy.json').read_bytes(),raw)
        self.policy(absolute=35);self.b=fixture(self.new,2,seed=1);self.invoke(True)

    def test_mismatch_is_inconclusive_never_speedup(self):
        self.policy()
        for group,key,value in [('workload','cache','warm'),('environment','font_scale',2),('visible','geometry','different')]:
            with self.subTest(key=key):
                self.b=fixture(self.new,seed=1);self.b[group][key]=value;write(self.new/'cohort.json',self.b)
                d,_=self.invoke(True,1);self.assertEqual(d['status'],'inconclusive')
                self.assertIsNone(d['comparison'])

    def test_failed_completed_journey_preserves_raw_tails(self):
        self.policy()
        def fail(r):
            r.update(status='failed',failure_codes=['child-diagnostic-failed'])
            r['child_report'].update(status='failed',hold='journey-failed')
        self.mutate(4,fail);d,_=self.invoke(True,1)
        self.assertEqual(d['candidate']['failure_inclusive'][PHASE]['flutter_ui_us']['p95']['sample_count'],5)
        self.assertEqual(d['candidate']['admitted_only'][PHASE]['flutter_ui_us']['p95']['sample_count'],4)
        self.assertFalse(d['candidate']['attempts'][-1]['admitted'])

    def test_identity_tail_geometry_cleanup_and_raw_mutations(self):
        self.policy()
        mutations=[lambda r:r.update(pid=999),lambda r:r['source'].update(source_tree='f'*40),
            lambda r:r.update(cleanup='pending'),lambda r:r.update(artifact_after=False),
            lambda r:r.update(renderer={}),lambda r:r['child_report']['rawFrames'][-1].update(uiUs=999),
            lambda r:r['child_report'].update(physical_viewport=[1400,900]),
            lambda r:r['child_report']['windows'][-1].update(end=3200200),
            lambda r:r['child_report'].update(storage='personal'),
            lambda r:r['child_report'].update(framework_error_count=1)]
        for fn in mutations:
            with self.subTest(mutation=mutations.index(fn)):
                self.b=fixture(self.new,seed=1);self.mutate(4,fn);d,_=self.invoke(True,1)
                self.assertFalse(d['candidate']['attempts'][-1]['admitted'])

    def test_replay_missing_unqualified_and_undersampled(self):
        self.policy()
        self.b['attempts'][-1]=copy.deepcopy(self.b['attempts'][0]);write(self.new/'cohort.json',self.b)
        self.invoke(True,1)
        self.b=fixture(self.new,seed=1);(self.new/'run-4.json').unlink();d,_=self.invoke(True,1)
        self.assertEqual(len(d['candidate']['attempts']),5)
        for mutation in [lambda c:c['environment'].update(quiet=False),lambda c:c['environment'].update(refresh_hz=None),lambda c:c.update(attempts=c['attempts'][:4])]:
            self.a=fixture(self.base);mutation(self.a);write(self.base/'cohort.json',self.a)
            d,_=self.invoke(expected=1);self.assertEqual(d['status'],'unqualified')
        self.a=fixture(self.base)
        for n in range(5):
            p=self.base/f'run-{n}.json';r=json.loads(p.read_bytes());c=r['child_report'];c['rawFrames']=c['rawFrames'][:3];c['windows'][-1]['frame_count']=2
            from flutter_profile_launch import validate_report
            r['renderer']=validate_report(c,c,c['pid']);self.a['attempts'][n]['report']=write(p,r)
        write(self.base/'cohort.json',self.a);d,_=self.invoke(expected=1)
        self.assertIn('renderer-tail-underpopulated',d['attempts'][0]['reasons'])

    def test_malformed_oversize_pins_and_existing_output(self):
        self.policy();p=self.root/'policy.json';original=json.loads(p.read_bytes())
        for key,value in [('reviewer',''),('baseline_sha256','0'*64),('schema','unknown')]:
            d=copy.deepcopy(original);d[key]=value;write(p,d);self.invoke(True,1)
        for raw in [b'{',b'{"schema":1,"schema":2}',b'{"x":NaN}',b' '*(4194304+1)]:
            (self.base/'cohort.json').write_bytes(raw);d,_=self.invoke(expected=1);self.assertEqual(d['status'],'failed')
        out=self.root/'exists';out.mkdir();(out/'marker').write_text('keep')
        r=subprocess.run([sys.executable,str(CLI),'baseline','--cohort',str(self.new/'cohort.json'),'--evidence',str(out)],capture_output=True)
        self.assertEqual(r.returncode,2);self.assertEqual((out/'marker').read_text(),'keep')

    def test_observed_population_and_row_witnesses_bound_to_workload(self):
        self.policy()
        for key,value in [('loaded_list_slots',10000),('witnessed_row_ids',[99999])]:
            self.b=fixture(self.new,seed=1)
            self.mutate(4,lambda r:r['child_report'].update({key:value}))
            d,_=self.invoke(True,1)
            self.assertIn('observed-population-mismatch',d['candidate']['attempts'][-1]['reasons'])

    def test_rejected_readable_bytes_retained_under_actual_digest(self):
        self.policy()
        path=self.new/'run-4.json';raw=path.read_bytes()+b' '
        path.write_bytes(raw)
        d,out=self.invoke(True,1)
        self.assertIn('hash-mismatch',d['candidate']['attempts'][-1]['reasons'])
        retained=out/'bundle-0/inputs'/hashlib.sha256(raw).hexdigest()
        self.assertEqual(retained.read_bytes(),raw)

    def test_boolean_summary_and_reversed_frames_fail(self):
        self.policy()
        self.mutate(4,lambda r:r['renderer']['flutter_ui_us'].update(spread=False))
        self.invoke(True,1)
        self.b=fixture(self.new,seed=1)
        self.mutate(4,lambda r:r['child_report']['rawFrames'].reverse())
        self.invoke(True,1)


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

    def test_hash_refused_reencoded_report_preserves_known_launch_claims(self):
        self.policy()
        original=(self.base/'run-0.json').read_bytes()
        launch=json.loads(original)
        raw=json.dumps(launch,indent=2,allow_nan=False).encode()+b'\n'
        self.assertNotEqual(raw,original)
        (self.new/'reencoded.json').write_bytes(raw)
        self.b['attempts'].append(dict(report=dict(path='reencoded.json',sha256='0'*64),
            process_start='independent-hash-refused-label'))
        write(self.new/'cohort.json',self.b)
        d,out=self.invoke(True,1)
        row=d['candidate']['attempts'][-1]
        self.assertEqual(d['status'],'failed')
        self.assertEqual(row['reasons'],['hash-mismatch'])
        self.assertFalse(row['admitted']);self.assertIsNone(row['metrics'])
        digest=hashlib.sha256(raw).hexdigest()
        self.assertEqual(row['evidence_identity']['raw_sha256'],digest)
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertEqual(d['candidate']['failure_inclusive'][PHASE]['flutter_ui_us']['p95']['sample_count'],5)
        for key in ('run_id','process_start_wall_ns','pid'):
            self.assertEqual(row['evidence_identity'].get(key),launch[key])
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])

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
        self.assertIsNone(row['metrics']);self.assertFalse(row['admitted'])
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
        self.assertEqual(row['evidence_identity'].get('run_id'),json.loads(raw)['run_id'])
        self.assertIsNone(row['metrics']);self.assertFalse(row['admitted'])
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
        self.assertFalse(row['admitted']);self.assertIsNone(row['metrics'])
        self.assertEqual(row['evidence_identity'],dict(process_start=label))
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_supplied_start_label_alone_rejects_cross_cohort_reuse(self):
        self.policy()
        self.b['attempts'][4]['process_start']=self.a['attempts'][0]['process_start']
        write(self.new/'cohort.json',self.b)
        d,_=self.invoke(True,1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        self.assertTrue(all(r['admitted'] for r in d['candidate']['attempts']))


    def test_launch_run_alone_rejects_cross_cohort_reuse(self):
        self.policy()
        run=json.loads((self.base/'run-0.json').read_bytes())['run_id']
        def reuse_run(r):
            r['run_id']=run;r['child_report']['run_id']=run
        self.mutate(4,reuse_run)
        d,_=self.invoke(True,1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        self.assertTrue(all(r['admitted'] for r in d['candidate']['attempts']))


    def test_launch_wall_start_alone_rejects_cross_cohort_reuse(self):
        self.policy()
        start=json.loads((self.base/'run-0.json').read_bytes())['process_start_wall_ns']
        self.mutate(4,lambda r:r.update(process_start_wall_ns=start))
        d,_=self.invoke(True,1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        self.assertTrue(all(r['admitted'] for r in d['candidate']['attempts']))


if __name__=='__main__':unittest.main()
