"""Synthetic evidence controls. These are never application measurements."""
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

from macos_phase_journey import PHASES
from performance_gate import BoundedInputs, METRICS, Invalid, load, read_attempt

CLI = Path(__file__).with_name('performance_gate.py')


def write(path, obj):
    data = json.dumps(obj, allow_nan=False).encode()
    path.write_bytes(data)
    return dict(path=path.name, sha256=hashlib.sha256(data).hexdigest())


def synthetic(root, factor=1, *, seed=0):
    """Five independent synthetic process records, not replayed live evidence."""
    cohort: dict[str, Any] = dict(schema='soundq.phase-cohort.v1', run_id='synthetic-only',
        source=dict(commit='a'*40, tree='b'*40), manifest_sha256='c'*64,
        build_mode='release', environment=dict(name='synthetic', platform='macos',
        device='synthetic', os='synthetic', renderer='appkit', viewport=[1000,800],
        physical_viewport=[2000,1600], scale=2, refresh_hz=60, font_scale=1,
        fonts='synthetic', audio_route='synthetic', power='ac', quiet=True),
        workload=dict(name='synthetic', dataset='d'*64, loaded_order=['row-1'],
        queue_order=['occurrence-1'], selected='occurrence-1', cache='fresh',
        animation='normal', input='scripted-row-jumps', route='library'),
        features=dict(name='synthetic', required=['play'], implemented=['play'],
        exercised=['play'], missing=[]), visible=dict(name='synthetic', columns=['title'],
        artwork='none', actions=['play'], geometry='synthetic'), attempts=[])
    for n in range(5):
        def boundary(t, audio):
            return dict(process=dict(monotonic_ns=t*10**9, user_us=int(t*100000*factor),
                system_us=0, rss_bytes=int(1000000*factor), failure_codes=[]),
                player_witness=1 if audio else None, item_witness=2 if audio else None,
                account_scope=1, epoch=1, session=1, occurrence=1 if audio else None,
                rows=500, settled=True, ready=audio, failed=False,
                position_seconds=t if audio else None, rate=1 if audio else 0, scroll_y=t*100)
        phases = [dict(name=name, status='passed', start=boundary(i*2+1,i>0),
            end=boundary(i*2+2,i>0), elapsed_ns=10**9, cpu_percent=10*factor,
            rss_delta_bytes=0, cursor_delta_seconds=1 if i>0 else None,
            scroll_displacement=100, failure_codes=[]) for i,name in enumerate(PHASES)]
        child = dict(schema='soundq.macos.phase-diagnostic.v1', run_id='synthetic-'+str(seed)+'-'+str(n),
            pid=100+seed*100+n, source_commit='a'*40, source_tree='b'*40, manifest_sha256='c'*64,
            status='passed', journey_passed=True, failure_codes=[], pending_phase=None, phases=phases)
        report = dict(schema='soundq.macos.phase-launch.v1', run_id=child['run_id'],
            status='passed', failure_codes=[], pid=child['pid'], exit_code=0, cleanup='reaped',
            artifact_before=True, artifact_after=True, child_report=child,
            manifest_sha256='c'*64, source_commit='a'*40, source_tree='b'*40, build_mode='release')
        cohort['attempts'].append(dict(report=write(root/f'run-{n}.json', report), process_start='synthetic-start-'+str(seed)+'-'+str(n)))
    write(root/'cohort.json', cohort)
    return cohort


class Gate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.root = Path(self.tmp.name).resolve()
        self.base = self.root/'base'; self.base.mkdir()
        self.candidate = self.root/'candidate'; self.candidate.mkdir()
        self.old = synthetic(self.base); self.new = synthetic(self.candidate,seed=1)
        self.counter = 0

    def tearDown(self):
        self.tmp.cleanup()

    def invoke(self, command='baseline', expected=0, directory=None):
        self.counter += 1
        out = self.root/f'out-{self.counter}'
        args = [sys.executable,'-B',str(CLI),command,'--cohort',str((directory or (self.base if command=='baseline' else self.candidate))/'cohort.json'),'--evidence',str(out)]
        if command == 'compare':
            args += ['--baseline-cohort',str(self.base/'cohort.json'),'--policy',str(self.root/'policy.json')]
        result = subprocess.run(args,capture_output=True,timeout=10)
        self.assertEqual(result.returncode,expected,result.stderr.decode())
        self.assertEqual(result.stderr,b'')
        report = json.loads((out/'report.json').read_bytes())
        self.assertNotIn(str(self.root),json.dumps(report))
        return report,out

    def review(self):
        base,_ = self.invoke()
        write(self.root/'policy.json',dict(schema='soundq.phase-policy.v1',
            baseline_sha256=base['baseline_sha256'], reviewer='synthetic-reviewer-not-runtime',
            calibration=dict(cohort_sha256=base['cohort_sha256'], rationale='synthetic-zero-spread'),
            budgets={p:{m:dict(relative_allowance=0,absolute_allowance=0) for m in METRICS} for p in PHASES}))

    def mutate_report(self, n, mutate):
        path=self.candidate/f'run-{n}.json'; obj=json.loads(path.read_bytes()); mutate(obj)
        self.new['attempts'][n]['report']=write(path,obj)
        write(self.candidate/'cohort.json',self.new)

    def test_baseline_and_compare_real_cli(self):
        self.review()
        obj,_=self.invoke('compare'); self.assertEqual(obj['status'],'passed')
        self.assertIsNone(obj['comparison']); self.assertFalse(obj['full_app_accepted'])

    def test_budget_mutation_rejected_without_ratchet(self):
        self.review(); policy=(self.root/'policy.json').read_bytes()
        synthetic(self.candidate,2,seed=1)
        obj,_=self.invoke('compare',1)
        self.assertIn('budget-breached',obj['reasons']); self.assertTrue(obj['breaches'])
        self.assertEqual((self.root/'policy.json').read_bytes(),policy)

    def test_workload_and_environment_mismatch(self):
        self.review()
        for field,key,value in [('workload','cache','warm'),('environment','font_scale',2),('visible','artwork','images')]:
            with self.subTest(field=field):
                original=self.new[field][key]; self.new[field][key]=value
                write(self.candidate/'cohort.json',self.new)
                obj,_=self.invoke('compare',1)
                self.assertIn('environment-workload-feature-mismatch',obj['reasons'])
                self.new[field][key]=original

    def test_failed_tail_missing_cleanup_audio_identity(self):
        self.review()
        mutations=[lambda r:r.update(cleanup='pending'),lambda r:r.update(status='failed'),
            lambda r:r.update(artifact_after=False),lambda r:r.update(source_tree='f'*40),
            lambda r:r['child_report']['phases'][-1]['end'].update(session=9),
            lambda r:r['child_report']['phases'][-1]['end'].update(position_seconds=5),
            lambda r:r['child_report']['phases'][-1].update(cpu_percent=999)]
        for mutation in mutations:
            with self.subTest(mutation=mutations.index(mutation)):
                self.new=synthetic(self.candidate,seed=1); self.mutate_report(4,mutation)
                obj,_=self.invoke('compare',1)
                self.assertEqual(len(obj['candidate']['attempts']),5)
                self.assertFalse(obj['candidate']['attempts'][-1]['admitted'])
        self.new=synthetic(self.candidate,seed=1); (self.candidate/'run-4.json').unlink()
        obj,_=self.invoke('compare',1); self.assertEqual(len(obj['candidate']['attempts']),5)

    def test_reused_process_and_bad_hash(self):
        self.review()
        for key in ['process_start','report']:
            self.new=synthetic(self.candidate,seed=1)
            self.new['attempts'][-1][key]=copy.deepcopy(self.new['attempts'][0][key])
            write(self.candidate/'cohort.json',self.new)
            obj,_=self.invoke('compare',1)
            self.assertIn('reused-process-population',obj['candidate']['attempts'][-1]['reasons'])
        self.new=synthetic(self.candidate,seed=1)
        (self.candidate/'run-4.json').write_text('{}')
        self.invoke('compare',1)

    def test_noisy_or_insufficient_cohort_cannot_admit(self):
        for mutate in [lambda c:c['environment'].update(quiet=False),lambda c:c.update(attempts=c['attempts'][:4]),lambda c:c['features'].update(missing=['play'])]:
            self.old=synthetic(self.base); mutate(self.old); write(self.base/'cohort.json',self.old)
            obj,_=self.invoke(expected=1); self.assertEqual(obj['status'],'unqualified')

    def test_completed_phases_of_failed_journey_remain_diagnostic(self):
        self.review()
        def fail(r):
            r.update(status='failed', exit_code=1)
            r['child_report'].update(status='failed', journey_passed=False,
                                     failure_codes=['journey-failed'])
        self.mutate_report(4, fail)
        obj,_=self.invoke('compare',1)
        self.assertEqual(obj['candidate']['failure_inclusive'][PHASES[0]]['cpu_percent']['sample_count'],5)
        self.assertEqual(obj['candidate']['admitted_only'][PHASES[0]]['cpu_percent']['sample_count'],4)

    def test_oversized_document_and_reference_fail_before_parse(self):
        self.review()
        (self.candidate/'run-4.json').write_bytes(b' ' * (4_194_304+1))
        obj,_=self.invoke('compare',1)
        self.assertIn('input-too-large',obj['candidate']['attempts'][-1]['reasons'])
        (self.base/'cohort.json').write_bytes(b' ' * (4_194_304+1))
        obj,_=self.invoke(expected=1)
        self.assertEqual(obj['reasons'],['input-too-large'])

    def test_growth_before_retention_is_bounded_and_refused(self):
        store=BoundedInputs(self.base)
        path=self.base/'cohort.json'
        load(path,store)
        path.write_bytes(b' ' * (4_194_304+1))
        with self.assertRaisesRegex(Invalid,'input-too-large'):
            store.verify()
        linked=self.base/'linked.json';linked.symlink_to(path)
        with self.assertRaisesRegex(Invalid,'symlink-input'):
            load(linked,store)

    def test_output_refusal_diagnostics_preserve_targets(self):
        target = self.root/'output-target'; target.mkdir()
        marker = target/'marker'; marker.write_bytes(b'unchanged-output')
        leaf = self.root/'output-link'; leaf.symlink_to(target, target_is_directory=True)
        ancestor = self.root/'output-ancestor'; ancestor.symlink_to(target, target_is_directory=True)
        for out, diagnostic in [(target, b'evidence-directory-must-be-new\n'),
                                (leaf, b'symlink-output\n'),
                                (ancestor/'new-output', b'symlink-output\n')]:
            with self.subTest(diagnostic=diagnostic, leaf=out.name):
                result = subprocess.run([sys.executable, '-B', str(CLI), 'baseline',
                    '--cohort', str(self.base/'cohort.json'), '--evidence', str(out)],
                    capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, b'')
                self.assertEqual(result.stderr, diagnostic)
                self.assertEqual(list(target.iterdir()), [marker])
                self.assertEqual(marker.read_bytes(), b'unchanged-output')
                self.assertTrue(leaf.is_symlink()); self.assertTrue(ancestor.is_symlink())

    def test_input_aliases_refused_without_mutation(self):
        original = {p.name: p.read_bytes() for p in self.base.iterdir()}
        leaf = self.root/'cohort-link.json'; leaf.symlink_to(self.base/'cohort.json')
        ancestor = self.root/'input-ancestor'; ancestor.symlink_to(self.base, target_is_directory=True)
        for index, (path, reason) in enumerate([(self.base/'cohort.json', None),
                (leaf, 'symlink-input'), (ancestor/'cohort.json', 'input-read-failed')]):
            with self.subTest(reason=reason):
                out = self.root/f'alias-out-{index}'
                result = subprocess.run([sys.executable, '-B', str(CLI), 'baseline',
                    '--cohort', str(path), '--evidence', str(out)], capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0 if reason is None else 1)
                self.assertEqual(result.stderr, b'')
                self.assertEqual(result.stdout, b'qualified\n' if reason is None else b'failed\n')
                report = json.loads((out/'report.json').read_bytes())
                if reason is not None:
                    self.assertEqual(report['reasons'], [reason])
                self.assertNotIn(str(self.root), json.dumps(report))
                self.assertEqual({p.name: p.read_bytes() for p in self.base.iterdir()}, original)
                self.assertTrue(leaf.is_symlink()); self.assertTrue(ancestor.is_symlink())

    def test_review_required_and_pinned(self):
        self.review(); path=self.root/'policy.json'; obj=json.loads(path.read_bytes())
        for key,value in [('reviewer',''),('baseline_sha256','0'*64),('schema','unknown')]:
            changed=copy.deepcopy(obj); changed[key]=value; write(path,changed)
            self.invoke('compare',1)

    def test_malformed_unknown_duplicate_nonfinite_retained(self):
        for data in [b'{',b'{"schema":1,"schema":2}',b'{"value":NaN}']:
            (self.base/'cohort.json').write_bytes(data)
            obj,out=self.invoke(expected=1)
            self.assertEqual(obj['status'],'failed')
            self.assertTrue(any(p.read_bytes()==data for p in (out/'bundle-0/inputs').iterdir()))
        self.old=synthetic(self.base); self.old['unknown']=1; write(self.base/'cohort.json',self.old)
        self.invoke(expected=1)


    def test_same_cohort_cannot_compare_against_itself(self):
        self.review()
        d,_=self.invoke('compare',1,directory=self.base)
        self.assertEqual(d['status'],'failed')
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_one_copied_renamed_report_rejects_partial_overlap(self):
        self.review()
        raw=(self.base/'run-0.json').read_bytes()
        (self.candidate/'renamed.json').write_bytes(raw)
        self.new['attempts'][4]=dict(report=dict(path='renamed.json',sha256=hashlib.sha256(raw).hexdigest()),
            process_start='renamed-reference-not-a-new-observation')
        write(self.candidate/'cohort.json',self.new)
        before={p:p.read_bytes() for p in [*self.base.iterdir(),self.root/'policy.json']}
        d,_=self.invoke('compare',1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        self.assertEqual(len(d['candidate']['attempts']),5)
        self.assertTrue(all(r['admitted'] for r in d['candidate']['attempts']))
        self.assertIsNotNone(d['candidate']['failure_inclusive'])
        self.assertEqual({p:p.read_bytes() for p in before},before)

    def test_overlap_hidden_in_failed_hash_attempt_is_retained(self):
        self.review()
        raw=(self.base/'run-0.json').read_bytes()
        (self.candidate/'failed-copy.json').write_bytes(raw)
        self.new['attempts'].append(dict(report=dict(path='failed-copy.json',sha256='0'*64),
            process_start='failed-copy-distinct-label'))
        write(self.candidate/'cohort.json',self.new)
        d,out=self.invoke('compare',1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        rows=d['candidate']['attempts']
        self.assertEqual(len(rows),6);self.assertFalse(rows[-1]['admitted'])
        self.assertIn('hash-mismatch',rows[-1]['reasons'])
        digest=hashlib.sha256(raw).hexdigest()
        self.assertEqual(rows[-1]['evidence_identity']['raw_sha256'],digest)
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertIsNotNone(d['candidate']['failure_inclusive'])

    def test_hash_refused_reencoded_report_preserves_known_launch_claims(self):
        self.review()
        original=(self.base/'run-0.json').read_bytes()
        launch=json.loads(original)
        raw=json.dumps(launch,indent=2,allow_nan=False).encode()+b'\n'
        self.assertNotEqual(raw,original)
        (self.candidate/'reencoded.json').write_bytes(raw)
        self.new['attempts'].append(dict(report=dict(path='reencoded.json',sha256='0'*64),
            process_start='independent-hash-refused-label'))
        write(self.candidate/'cohort.json',self.new)
        d,out=self.invoke('compare',1)
        row=d['candidate']['attempts'][-1]
        self.assertEqual(d['status'],'failed')
        self.assertEqual(row['reasons'],['hash-mismatch'])
        self.assertFalse(row['admitted']);self.assertIsNone(row['metrics'])
        digest=hashlib.sha256(raw).hexdigest()
        self.assertEqual(row['evidence_identity']['raw_sha256'],digest)
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertEqual(d['candidate']['failure_inclusive'][PHASES[0]]['cpu_percent']['sample_count'],5)
        self.assertEqual(row['evidence_identity'].get('run_id'),launch['run_id'])
        self.assertEqual(row['evidence_identity'].get('pid'),launch['pid'])
        self.assertNotIn('process_start_wall_ns',row['evidence_identity'])
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_supplied_lifetime_reuse_survives_reencoding_and_failed_status(self):
        self.review()
        old=json.loads((self.base/'run-0.json').read_bytes())
        old['status']='failed'
        old['failure_codes']=['synthetic-failure']
        self.new['attempts'][4]['process_start']=self.old['attempts'][0]['process_start']
        self.new['attempts'][4]['report']=write(self.candidate/'run-4.json',old)
        write(self.candidate/'cohort.json',self.new)
        d,_=self.invoke('compare',1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        self.assertFalse(d['candidate']['attempts'][4]['admitted'])
        self.assertIsNotNone(d['candidate']['failure_inclusive'])

    def test_independent_equal_values_same_source_and_reused_pid_pass(self):
        self.review()
        for n in range(5):
            pid=json.loads((self.base/f'run-{n}.json').read_bytes())['pid']
            def reuse_pid(r):
                r['pid']=pid
                if 'child_report' in r:r['child_report']['pid']=pid
            self.mutate_report(n,reuse_pid)
        # OS PIDs can be recycled: distinct supplied lifetimes are not replay.
        def recycle_within(r):
            r['pid']=100
            if 'child_report' in r:r['child_report']['pid']=100
        self.mutate_report(4,recycle_within)
        before={p:p.read_bytes() for p in [*self.base.iterdir(),self.root/'policy.json']}
        d,_=self.invoke('compare')
        self.assertEqual(d['status'],'passed');self.assertIsNone(d['comparison'])
        self.assertFalse(d['full_app_accepted'])
        self.assertEqual({p:p.read_bytes() for p in before},before)

    def test_hash_mismatch_preserves_actual_raw_identity_and_bytes(self):
        self.review()
        p=self.candidate/'run-4.json';raw=p.read_bytes()+b' '
        p.write_bytes(raw)
        d,out=self.invoke('compare',1)
        row=d['candidate']['attempts'][4]
        self.assertIn('hash-mismatch',row['reasons']);self.assertFalse(row['admitted'])
        digest=hashlib.sha256(raw).hexdigest()
        self.assertEqual(row.get('evidence_identity',{}).get('raw_sha256'),digest)
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertNotIn('baseline-candidate-evidence-replay',d['reasons'])


    def test_invalid_json_preserves_known_start_label_and_parse_refusal(self):
        self.review()
        raw=b'{"run_id":"incomplete-run",'
        (self.candidate/'broken.json').write_bytes(raw)
        digest=hashlib.sha256(raw).hexdigest()
        label=self.old['attempts'][0]['process_start']
        self.new['attempts'].append(dict(process_start=label,
            report=dict(path='broken.json',sha256=digest)))
        write(self.candidate/'cohort.json',self.new)
        d,out=self.invoke('compare',1)
        row=d['candidate']['attempts'][-1]
        self.assertEqual(row['reasons'],['invalid-json'])
        self.assertEqual(row['evidence_identity'],dict(process_start=label,raw_sha256=digest))
        self.assertIsNone(row['metrics']);self.assertFalse(row['admitted'])
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_declared_baseline_digest_does_not_create_false_overlap(self):
        self.review()
        path=self.candidate/'run-4.json';raw=path.read_bytes()
        declared=self.old['attempts'][0]['report']['sha256']
        digest=hashlib.sha256(raw).hexdigest();self.assertNotEqual(digest,declared)
        self.new['attempts'][4]['report']['sha256']=declared
        write(self.candidate/'cohort.json',self.new)
        d,out=self.invoke('compare',1)
        row=d['candidate']['attempts'][4]
        self.assertEqual(row['reasons'],['hash-mismatch'])
        self.assertEqual(row['evidence_identity']['raw_sha256'],digest)
        self.assertEqual(row['evidence_identity'].get('run_id'),json.loads(raw)['run_id'])
        self.assertIsNone(row['metrics']);self.assertFalse(row['admitted'])
        self.assertEqual((out/'bundle-0/inputs'/digest).read_bytes(),raw)
        self.assertNotIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_unknown_attempt_key_preserves_known_start_label(self):
        self.review()
        label=self.old['attempts'][0]['process_start']
        self.new['attempts'].append(dict(process_start=label,unknown=True,
            report=copy.deepcopy(self.new['attempts'][0]['report'])))
        write(self.candidate/'cohort.json',self.new)
        d,_=self.invoke('compare',1)
        row=d['candidate']['attempts'][-1]
        self.assertEqual(d['status'],'failed')
        self.assertEqual(row['reasons'],['unknown-or-missing-key'])
        self.assertFalse(row['admitted']);self.assertIsNone(row['metrics'])
        self.assertEqual(row['evidence_identity'],dict(process_start=label))
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])

    def test_supplied_start_label_alone_rejects_cross_cohort_reuse(self):
        self.review()
        self.new['attempts'][4]['process_start']=self.old['attempts'][0]['process_start']
        write(self.candidate/'cohort.json',self.new)
        d,_=self.invoke('compare',1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        self.assertTrue(all(r['admitted'] for r in d['candidate']['attempts']))


    def test_sequential_rejected_attempts_do_not_inherit_read_identity(self):
        from flutter_renderer_gate import RendererInputs
        for store_type in (BoundedInputs,RendererInputs):
            with self.subTest(store=store_type.__name__):
                store=store_type(self.candidate)
                prior=copy.deepcopy(self.new['attempts'][0])
                for index,(attempt,reason,identity) in enumerate([
                    (dict(process_start='known-shape',report=prior['report'],extra=True),
                     'unknown-or-missing-key',dict(process_start='known-shape')),
                    (dict(process_start='known-missing-key'),
                     'unknown-or-missing-key',dict(process_start='known-missing-key')),
                    ([], 'expected-object', {}),
                    (None, 'expected-object', {}),
                    (dict(process_start='known-refusal',report=dict(path='../outside',sha256='0'*64)),
                     'path-refusal',dict(process_start='known-refusal')),
                    (dict(process_start='known-absent',report=dict(path='absent.json',sha256='0'*64)),
                     'missing-file',dict(process_start='known-absent')),
                    (dict(process_start='invalid label',report=prior['report'],extra=True),
                     'unknown-or-missing-key',{}),
                ]):
                    # Seed the actual same store before every rejected input.
                    read_attempt(prior,store,{},set())
                    row={};seen=set()
                    with self.assertRaises((Invalid,OSError)) as caught:
                        read_attempt(attempt,store,row,seen)
                    if reason not in ('path-refusal','missing-file'):
                        self.assertEqual(str(caught.exception),reason)
                    self.assertEqual(row['evidence_identity'],identity,(index,store_type))
                    self.assertEqual(seen,{('process_start',v) for v in identity.values()})
                # A safely read hash refusal must not contaminate the next absent read either.
                rejected=copy.deepcopy(prior);rejected['report']['sha256']='0'*64
                with self.assertRaisesRegex(Invalid,'hash-mismatch'):
                    read_attempt(rejected,store,{},set())
                row={}
                with self.assertRaises(OSError):
                    read_attempt(dict(process_start='after-hash-refusal',
                        report=dict(path='still-absent.json',sha256='0'*64)),store,row,set())
                self.assertEqual(row['evidence_identity'],dict(process_start='after-hash-refusal'))

    def test_malformed_envelope_never_reads_its_report(self):
        from flutter_renderer_gate import RendererInputs
        ref=write(self.candidate/'unread.json',dict(run_id='must-not-collect',
            pid=7,process_start_wall_ns=11))
        for store_type in (BoundedInputs,RendererInputs):
            store=store_type(self.candidate);row={};seen=set()
            with self.assertRaisesRegex(Invalid,'unknown-or-missing-key'):
                read_attempt(dict(process_start='known-shape',report=ref,extra=True),
                    store,row,seen)
            self.assertEqual(store.files,{})
            self.assertEqual(row['evidence_identity'],dict(process_start='known-shape'))
            self.assertEqual(seen,{('process_start','known-shape')})

    def test_hash_refused_launch_claims_reserve_later_population_without_masking_error(self):
        from flutter_renderer_gate import RendererInputs
        ref=write(self.candidate/'reserved.json',dict(run_id='reserved-run',
            pid=7,process_start_wall_ns=11))
        for store_type in (BoundedInputs,RendererInputs):
            store=store_type(self.candidate);row={};seen={('run_id','reserved-run')}
            bad=dict(ref,sha256='0'*64)
            with self.assertRaisesRegex(Invalid,'hash-mismatch'):
                read_attempt(dict(process_start='failed-label',report=bad),store,row,seen)
            self.assertIn(('process_start_wall_ns',11),seen)
            self.assertIn(('run_id','reserved-run'),seen)
            # Reencoding removes raw equality, so only the reserved launch claims overlap.
            new=write(self.candidate/'later.json',dict(run_id='reserved-run',
                pid=8,process_start_wall_ns=11,unused='reencoded'))
            with self.assertRaisesRegex(Invalid,'reused-process-population'):
                read_attempt(dict(process_start='later-label',report=new),store,{},seen)

    def test_hash_refusal_uses_only_usable_claims_from_actual_bytes(self):
        from flutter_renderer_gate import RendererInputs
        for store_type in (BoundedInputs,RendererInputs):
            for run,pid,start,expected in [
                ('actual-run',7,11,dict(run_id='actual-run',pid=7,process_start_wall_ns=11)),
                ('invalid run',True,False,{}),
                (None,0,-1,{}),
                ([],2**31,2**63,{}),
                ({},1.0,1.0,{}),
            ]:
                with self.subTest(store=store_type.__name__,run=run,pid=pid,start=start):
                    path=self.candidate/'claims.json'
                    actual=write(path,dict(run_id=run,pid=pid,process_start_wall_ns=start,
                        arbitrary='not-an-identity',metrics=dict(cpu_percent=0)))
                    declared=self.old['attempts'][0]['report']['sha256']
                    self.assertNotEqual(actual['sha256'],declared)
                    store=store_type(self.candidate);row={};seen=set()
                    with self.assertRaisesRegex(Invalid,'hash-mismatch'):
                        read_attempt(dict(process_start='actual-label',report=dict(
                            path=path.name,sha256=declared)),store,row,seen)
                    identity=dict(process_start='actual-label',raw_sha256=actual['sha256'],**expected)
                    self.assertEqual(row['evidence_identity'],identity)
                    self.assertNotIn(('raw_sha256',declared),seen)
                    self.assertEqual(store.files[path],path.read_bytes())

    def test_best_effort_claim_parse_never_weakens_strict_json_or_primary_refusal(self):
        from flutter_renderer_gate import RendererInputs
        for store_type in (BoundedInputs,RendererInputs):
            for raw,parse_reason in [
                (b'{"run_id":"apparent-run",','invalid-json'),
                (b'{"run_id":"one","run_id":"two"}','duplicate-json-key'),
                (b'{"run_id":"apparent-run","x":NaN}','nonfinite-json'),
                (b'\xff','invalid-json'),(b'[]',None),(b'null',None),
            ]:
                for bad_hash in (False,True):
                    with self.subTest(store=store_type.__name__,raw=raw,bad_hash=bad_hash):
                        path=self.candidate/'strict.json';path.write_bytes(raw)
                        digest=hashlib.sha256(raw).hexdigest()
                        row={};store=store_type(self.candidate)
                        attempt=dict(process_start='known-parse-label',report=dict(
                            path=path.name,sha256='0'*64 if bad_hash else digest))
                        reason='hash-mismatch' if bad_hash else parse_reason
                        if reason:
                            with self.assertRaisesRegex(Invalid,reason):
                                read_attempt(attempt,store,row,set())
                        else:
                            read_attempt(attempt,store,row,set())
                        self.assertEqual(row['evidence_identity'],dict(
                            process_start='known-parse-label',raw_sha256=digest))
                        self.assertEqual(store.files[path],raw)

    def test_launch_run_alone_rejects_cross_cohort_reuse(self):
        self.review()
        run=json.loads((self.base/'run-0.json').read_bytes())['run_id']
        def reuse_run(r):
            r['run_id']=run;r['child_report']['run_id']=run
        self.mutate_report(4,reuse_run)
        d,_=self.invoke('compare',1)
        self.assertIn('baseline-candidate-evidence-replay',d['reasons'])
        self.assertTrue(all(r['admitted'] for r in d['candidate']['attempts']))


if __name__ == '__main__':
    unittest.main()
