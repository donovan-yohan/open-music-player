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
from performance_gate import BoundedInputs, METRICS, Invalid, load

CLI = Path(__file__).with_name('performance_gate.py')


def write(path, obj):
    data = json.dumps(obj, allow_nan=False).encode()
    path.write_bytes(data)
    return dict(path=path.name, sha256=hashlib.sha256(data).hexdigest())


def synthetic(root, factor=1):
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
        child = dict(schema='soundq.macos.phase-diagnostic.v1', run_id='synthetic-'+str(n),
            pid=100+n, source_commit='a'*40, source_tree='b'*40, manifest_sha256='c'*64,
            status='passed', journey_passed=True, failure_codes=[], pending_phase=None, phases=phases)
        report = dict(schema='soundq.macos.phase-launch.v1', run_id=child['run_id'],
            status='passed', failure_codes=[], pid=child['pid'], exit_code=0, cleanup='reaped',
            artifact_before=True, artifact_after=True, child_report=child,
            manifest_sha256='c'*64, source_commit='a'*40, source_tree='b'*40, build_mode='release')
        cohort['attempts'].append(dict(report=write(root/f'run-{n}.json', report), process_start='synthetic-start-'+str(n)))
    write(root/'cohort.json', cohort)
    return cohort


class Gate(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR'))
        self.root = Path(self.tmp.name).resolve()
        self.base = self.root/'base'; self.base.mkdir()
        self.candidate = self.root/'candidate'; self.candidate.mkdir()
        self.old = synthetic(self.base); self.new = synthetic(self.candidate)
        self.counter = 0

    def tearDown(self):
        self.tmp.cleanup()

    def invoke(self, command='baseline', expected=0):
        self.counter += 1
        out = self.root/f'out-{self.counter}'
        args = [sys.executable,'-B',str(CLI),command,'--cohort',str((self.base if command=='baseline' else self.candidate)/'cohort.json'),'--evidence',str(out)]
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
        synthetic(self.candidate,2)
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
                self.new=synthetic(self.candidate); self.mutate_report(4,mutation)
                obj,_=self.invoke('compare',1)
                self.assertEqual(len(obj['candidate']['attempts']),5)
                self.assertFalse(obj['candidate']['attempts'][-1]['admitted'])
        self.new=synthetic(self.candidate); (self.candidate/'run-4.json').unlink()
        obj,_=self.invoke('compare',1); self.assertEqual(len(obj['candidate']['attempts']),5)

    def test_reused_process_and_bad_hash(self):
        self.review()
        for key in ['process_start','report']:
            self.new=synthetic(self.candidate)
            self.new['attempts'][-1][key]=copy.deepcopy(self.new['attempts'][0][key])
            write(self.candidate/'cohort.json',self.new)
            obj,_=self.invoke('compare',1)
            self.assertIn('reused-process-population',obj['candidate']['attempts'][-1]['reasons'])
        self.new=synthetic(self.candidate)
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


if __name__ == '__main__':
    unittest.main()
