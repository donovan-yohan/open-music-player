"""Explicitly synthetic, offline tests; never a measured application cohort."""
import importlib.util
import json
import subprocess
import tempfile
import hashlib
from copy import deepcopy
from pathlib import Path
import sys
import unittest

TOOL = Path(__file__).with_name('matched_performance.py')


class FrameTests(unittest.TestCase):
    def test_hwui_raw_deadline_and_tail(self):
        self.assertTrue(TOOL.is_file(), 'offline reducer is not implemented')
        spec = importlib.util.spec_from_file_location('matched_performance', TOOL)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        raw = ('** Graphics info for pid 42 [example.native] **\n'
               'Window: example.native/Main\n---PROFILEDATA---\n'
               'Flags,FrameTimelineVsyncId,IntendedVsync,FrameCompleted,FrameDeadline,\n'
               '0,1,100,110,120,\n0,2,200,900,220,\n---PROFILEDATA---\n')
        frames = module.parse_hwui(raw, 42, 'example.native', 'example.native/Main')
        self.assertEqual([f.metrics['hwui_span_ns'] for f in frames], [10, 700])
        self.assertEqual([f.deadline_missed for f in frames], [False, True])
        summary = module.distribution(frames)
        self.assertEqual(summary['metrics']['hwui_span_ns']['max'], 700)
        self.assertEqual(summary['deadline_misses'], 1)

    def test_hwui_incomplete_tail_is_retained_without_negative_metric(self):
        spec = importlib.util.spec_from_file_location('matched_performance', TOOL)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        raw = ('** Graphics info for pid 42 [example.native] **\n'
               'Window: example.native/Main\n---PROFILEDATA---\n'
               'Flags,FrameTimelineVsyncId,IntendedVsync,FrameCompleted,FrameDeadline,\n'
               '0,1,100,110,120,\n0,2,200,90,220,\n---PROFILEDATA---\n')
        frames = module.parse_hwui(raw, 42, 'example.native', 'example.native/Main')
        summary = module.distribution(frames)
        self.assertEqual(summary['sample_count'], 2)
        self.assertEqual(summary['invalid_count'], 1)
        self.assertEqual(summary['metric_sample_count']['hwui_span_ns'], 1)
        self.assertEqual(summary['metrics']['hwui_span_ns']['max'], 10)

    def test_flutter_uses_raw_phases_not_claimed_summary(self):
        self.assertTrue(TOOL.is_file())
        spec = importlib.util.spec_from_file_location('matched_performance', TOOL)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        self.assertTrue(hasattr(module, 'parse_flutter'), 'raw Flutter parser missing')
        f = {'frameNumber': 1, 'vsyncStart': 100, 'buildStart': 110,
             'buildFinish': 120, 'rasterStart': 130, 'rasterFinish': 150,
             'rasterFinishWallTime': 1000150, 'uiUs': 10, 'rasterUs': 20,
             'totalSpanUs': 50, 'vsyncOverheadUs': 10}
        frames = module.parse_flutter({'rawFrames': [f]})
        self.assertEqual(frames[0].metrics['flutter_total_span_us'], 50)
        self.assertIsNone(frames[0].deadline_missed)
        f['totalSpanUs'] = 1
        with self.assertRaises(module.Invalid):
            module.parse_flutter({'rawFrames': [f]})

    def test_flutter_rejects_duplicate_missing_and_bad_phase_fields(self):
        spec = importlib.util.spec_from_file_location('matched_performance', TOOL)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        f = {'frameNumber': 1, 'vsyncStart': 100, 'buildStart': 110,
             'buildFinish': 120, 'rasterStart': 130, 'rasterFinish': 150,
             'rasterFinishWallTime': 1000150, 'uiUs': 10, 'rasterUs': 20,
             'totalSpanUs': 50, 'vsyncOverheadUs': 10}
        variants = [[f, f], [dict(f, rasterStart=90)], [dict(f, uiUs=-1)],
                    [dict(f, rasterUs=True)], [{k: v for k, v in f.items() if k != 'vsyncStart'}],
                    [dict(f, fps=120)], []]
        for frames in variants:
            with self.subTest(frames=frames):
                with self.assertRaises(module.Invalid):
                    module.parse_flutter({'rawFrames': frames})

    def test_unconsumed_flutter_report_fields_are_not_a_schema_backdoor(self):
        spec = importlib.util.spec_from_file_location('matched_performance', TOOL)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        f = {'frameNumber': 1, 'vsyncStart': 100, 'buildStart': 110,
             'buildFinish': 120, 'rasterStart': 130, 'rasterFinish': 150,
             'rasterFinishWallTime': 1000150, 'uiUs': 10, 'rasterUs': 20,
             'totalSpanUs': 50, 'vsyncOverheadUs': 10}
        with self.assertRaises(module.Invalid):
            module.parse_flutter({'rawFrames': [f], 'aggregate': {'invented': 1}})

    def test_hwui_without_frame_deadline_never_infers_misses(self):
        spec = importlib.util.spec_from_file_location('matched_performance', TOOL)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        raw = ('** Graphics info for pid 42 [example.native] **\n'
               'Window: example.native/Main\n---PROFILEDATA---\n'
               'Flags,FrameTimelineVsyncId,IntendedVsync,FrameCompleted,\n'
               '0,1,100,1000000,\n---PROFILEDATA---\n')
        summary = module.distribution(module.parse_hwui(raw, 42, 'example.native', 'example.native/Main'))
        self.assertIsNone(summary['deadline_misses'])
        self.assertEqual(summary['deadline_sample_count'], 0)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def synthetic_bundle(root):
    """Independent synthetic process captures, not relabeled repeated observations."""
    def blob(name, data):
        encoded = json.dumps(data).encode() if not isinstance(data, bytes) else data
        (root / name).write_bytes(encoded)
        return {'path': name, 'sha256': digest(encoded)}
    source = blob('source.json', {'commit': 'a' * 40, 'tree': 'b' * 40})
    artifact = blob('app.bin', b'SYNTHETIC-NOT-AN-APPLICATION')
    env = {'name': 'synthetic-emulator', 'platform': 'android', 'device': 'synthetic',
           'os': 'test', 'renderer': 'test', 'viewport': [400, 800],
           'physical_viewport': [800, 1600], 'scale': 2, 'refresh_hz': 60,
           'font_scale': 1, 'fonts': 'test-fonts', 'audio_route': 'test-route',
           'power': 'test-power', 'quiet': True}
    workload = {'name': 'synthetic-scroll', 'dataset': 'c' * 64,
                'loaded_order': ['row1', 'row2'], 'queue_order': ['occ1', 'occ2'],
                'selected': 'occ1', 'cache': 'warm', 'animation': 'normal-240-180',
                'input': 'synthetic-pointer', 'route': 'library'}
    features = {'name': 'synthetic-subset', 'required': ['library'],
                'implemented': ['library'], 'exercised': ['library'], 'missing': []}
    visible = {'name': 'synthetic-visible', 'columns': ['title'], 'artwork': 'none',
               'actions': ['play'], 'geometry': 'synthetic-geometry'}
    sides = []
    for side in ['native', 'flutter']:
        sides.append({'name': side, 'source': source, 'artifacts': [artifact],
                      'application_id': 'example.' + side, 'build_mode': 'profile',
                      'optimization': 'optimized', 'entrypoint': 'actual-app',
                      'environment': deepcopy(env), 'workload': deepcopy(workload),
                      'features': deepcopy(features), 'visible': deepcopy(visible)})
    plan = {'schema': 'soundq.performance.plan.v1', 'run_id': 'synthetic-only',
            'scope': 'synthetic-ordinary-listening-subset', 'exclusions': ['full-app', 'acoustics'],
            'sides': sides, 'phases': [{'name': 'scroll', 'audio_active': True, 'motion': True}]}
    plan_ref = blob('plan.json', plan)
    attempts = []
    for repetition in range(1, 6):
        for side in sides:
            name = side['name']
            process_start = f'synthetic-start-{repetition}'
            process = {'pid': 42, 'process_start': process_start,
                       'application_id': side['application_id'],
                       'artifact_sha256': artifact['sha256'],
                       'source_commit': 'a' * 40, 'source_tree': 'b' * 40, 'build_mode': 'profile'}
            process_ref = blob(f'{name}-{repetition}-process.json', process)
            if name == 'native':
                raw = (f'** Graphics info for pid 42 [{side["application_id"]}] **\n'
                       f'Window: {side["application_id"]}/Main\n---PROFILEDATA---\n'
                       'Flags,FrameTimelineVsyncId,IntendedVsync,FrameCompleted,FrameDeadline,\n'
                       f'0,{2 * repetition - 1},100,110,120,\n'
                       f'0,{2 * repetition},200,900,220,\n---PROFILEDATA---\n').encode()
                fmt, clock, unit = 'android.hwui', 'android-system-nanoTime', 'ns'
            else:
                raw = {'rawFrames': [{'frameNumber': i, 'vsyncStart': t,
                       'buildStart': t + 10, 'buildFinish': t + 20, 'rasterStart': t + 30,
                       'rasterFinish': t + 50, 'rasterFinishWallTime': t + 1000000,
                       'uiUs': 10, 'rasterUs': 20, 'totalSpanUs': 50, 'vsyncOverheadUs': 10}
                      for i, t in [(2 * repetition - 1, 100), (2 * repetition, 200)]]}
                fmt, clock, unit = 'flutter.engine', 'flutter-frame-timing', 'us'
            raw_ref = blob(f'{name}-{repetition}-frames.raw', raw)
            cursor = {'kind': 'native-direct', 'session': 'session1', 'occurrence': 'occ1',
                      'start_position_ms': 10, 'end_position_ms': 20,
                      'before': 0, 'after': 1000, 'clock': clock, 'ready': True,
                      'pending_seek': False, 'discontinuities': 0, 'resolution_ms': 1}
            attempts.append({'attempt_id': f'{name}-{repetition}', 'run_id': plan['run_id'],
                'side': name, 'repetition': repetition, 'process': process_ref,
                'observed': {k: deepcopy(side[k]) for k in ['environment', 'workload', 'features', 'visible']},
                'raw': {**raw_ref, 'format': fmt, 'clock': clock, 'unit': unit,
                        'pid': 42, 'process_start': process_start,
                        'surface': side['application_id'] + '/Main' if name == 'native' else None},
                'windows': [{'name': 'scroll', 'clock': clock, 'start': 0, 'end': 1000,
                             'cursor': cursor, 'displacement': 100}],
                'functional': 'passed', 'app': 'passed', 'collector': 'passed',
                'cleanup': 'passed', 'noise': False, 'complete': True})
    receipts = {'schema': 'soundq.performance.receipts.v1', 'plan': plan_ref, 'attempts': attempts}
    blob('receipts.json', receipts)
    return plan, receipts


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='matched-performance-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.plan, self.receipts = synthetic_bundle(self.root)

    def cli(self, command, name='out'):
        input_path = self.root / ('plan.json' if command == 'validate' else 'receipts.json')
        result = subprocess.run([sys.executable, '-B', str(TOOL), command,
                '--plan' if command == 'validate' else '--receipts', str(input_path),
                '--evidence', str(self.root / name)], capture_output=True, text=True, timeout=5)
        report_path = self.root / name / 'report.json'
        self.assertTrue(report_path.is_file(), result.stdout + result.stderr)
        return result.returncode, json.loads(report_path.read_text())

    def save(self):
        (self.root / 'plan.json').write_text(json.dumps(self.plan))
        self.receipts['plan']['sha256'] = digest((self.root / 'plan.json').read_bytes())
        (self.root / 'receipts.json').write_text(json.dumps(self.receipts))

    def test_validate_and_distinct_domains_never_produce_ratio(self):
        code, report = self.cli('validate', 'validated')
        self.assertEqual(code, 0)
        self.assertEqual(report['status'], 'validated')
        code, report = self.cli('reduce')
        self.assertEqual(code, 0)
        self.assertEqual(report['status'], 'separate-unmatched-baselines')
        self.assertIsNone(report['comparison'])
        self.assertEqual(len(report['attempts']), 10)
        self.assertEqual(report['attempts'][0]['run']['metrics']['hwui_span_ns']['max'], 700)

    def test_huge_plan_numbers_fail_safely_and_retain_original_bytes(self):
        for index, value in enumerate([10**400, 1e300]):
            with self.subTest(value_type=type(value).__name__):
                self.plan['sides'][0]['environment']['refresh_hz'] = value
                self.save()
                for command in ['validate', 'reduce']:
                    name = f'huge-plan-{index}-{command}'
                    code, report = self.cli(command, name)
                    self.assertEqual(code, 1)
                    self.assertEqual(report['status'], 'failed')
                    self.assertEqual(report['reasons'], ['invalid-number'])
                    for filename in ['plan.json'] + (['receipts.json'] if command == 'reduce' else []):
                        data = (self.root / filename).read_bytes()
                        self.assertEqual((self.root / name / 'inputs' / digest(data)).read_bytes(), data)

    def test_huge_attempt_number_preserves_other_attempts_and_inputs(self):
        self.receipts['attempts'][0]['windows'][0]['displacement'] = 10**400
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertEqual(len(report['attempts']), 10)
        self.assertEqual(report['attempts'][0]['reasons'], ['invalid-number'])
        self.assertTrue(all(a['admitted'] for a in report['attempts'][1:]))
        for filename in ['receipts.json', self.receipts['attempts'][0]['raw']['path']]:
            data = (self.root / filename).read_bytes()
            self.assertEqual((self.root / 'out' / 'inputs' / digest(data)).read_bytes(), data)

    def test_overlong_json_integer_has_safe_failure_and_original_bytes(self):
        for command, filename in [('validate', 'plan.json'), ('reduce', 'receipts.json')]:
            path = self.root / filename
            # Write literal JSON, without depending on the test interpreter's int digit limit.
            data = path.read_bytes().replace(b'{', b'{"overlong":' + b'9' * 5000 + b',', 1)
            path.write_bytes(data)
            code, report = self.cli(command, command)
            self.assertEqual(code, 1)
            self.assertEqual(report['status'], 'failed')
            self.assertIsNone(report['comparison'])
            self.assertFalse(report['full_app_accepted'])
            self.assertNotIn(str(self.root), json.dumps(report))
            self.assertEqual((self.root / command / 'inputs' / digest(data)).read_bytes(), data)

    def test_numeric_ranges_are_bounded_without_rejecting_ordinary_values(self):
        original = deepcopy(self.receipts)
        for index, value in enumerate([1e300, -1e300, 2**53, float('inf'), float('nan')]):
            with self.subTest(index=index):
                self.receipts = deepcopy(original)
                self.receipts['attempts'][0]['windows'][0]['displacement'] = value
                self.save()
                code, report = self.cli('reduce', f'numeric-{index}')
                self.assertEqual(code, 1)
                # Nonfinite JSON invalidates the document; finite oversized fields
                # fail only their attempt, keeping all other slots available.
                if index < 3:
                    self.assertEqual(len(report['attempts']), 10)
                    self.assertTrue(all(a['admitted'] for a in report['attempts'][1:]))
        self.receipts = deepcopy(original)
        for a in self.receipts['attempts']:
            a['windows'][0]['displacement'] = 0.5
            a['windows'][0]['cursor']['resolution_ms'] = 0.25
        self.save()
        code, report = self.cli('reduce', 'ordinary-fractions')
        self.assertEqual(code, 0)
        self.assertTrue(all(a['admitted'] for a in report['attempts']))
        self.receipts['attempts'][0]['windows'][0]['start'] = 10**400
        self.save()
        code, report = self.cli('reduce', 'oversized-clock')
        self.assertEqual(code, 1)
        self.assertEqual(report['attempts'][0]['reasons'], ['invalid-integer'])
        self.assertEqual(len(report['attempts']), 10)

    def test_overlong_referenced_numbers_keep_unaffected_attempts(self):
        first = self.receipts['attempts'][0]
        for variant in ['process-json', 'hwui-csv']:
            ref = first['process'] if variant == 'process-json' else first['raw']
            path = self.root / ref['path']
            original = path.read_bytes()
            data = (original.replace(b'"pid": 42', b'"pid": ' + b'9' * 5000)
                    if variant == 'process-json' else
                    original.replace(b'0,1,100,110,120,', b'0,1,' + b'9' * 5000 + b',110,120,'))
            path.write_bytes(data)
            ref['sha256'] = digest(data)
            self.save()
            code, report = self.cli('reduce', variant)
            self.assertEqual(code, 1)
            self.assertEqual(len(report['attempts']), 10)
            self.assertFalse(report['attempts'][0]['admitted'])
            self.assertTrue(all(a['admitted'] for a in report['attempts'][1:]))
            self.assertEqual((self.root / variant / 'inputs' / digest(data)).read_bytes(), data)
            path.write_bytes(original)
            ref['sha256'] = digest(original)

    def test_relabelled_replay_cannot_count_repetitions_or_duplicate_unions(self):
        original = deepcopy(self.receipts)
        for variant in ['native', 'both', 'path-aliases', 'reencoded-aliases', 'failed-first']:
            with self.subTest(variant=variant):
                self.receipts = deepcopy(original)
                targets = ['native', 'flutter'] if variant == 'both' else ['native']
                for side in targets:
                    first = next(a for a in self.receipts['attempts'] if a['side'] == side)
                    for a in self.receipts['attempts']:
                        if a['side'] != side or a is first:
                            continue
                        a['process'] = deepcopy(first['process'])
                        a['raw'] = deepcopy(first['raw'])
                        if variant in ['path-aliases', 'reencoded-aliases']:
                            for ref in [a['process'], a['raw']]:
                                data = (self.root / ref['path']).read_bytes()
                                if variant == 'reencoded-aliases':
                                    # Different bytes/hashes, same supplied process and frames.
                                    data += b'\n'
                                    ref['sha256'] = digest(data)
                                ref['path'] = a['attempt_id'] + '-alias-' + ref['path']
                                (self.root / ref['path']).write_bytes(data)
                    if variant == 'failed-first':
                        first['collector'] = 'failed'
                self.save()
                code, report = self.cli('reduce', variant)
                self.assertEqual(code, 1)
                self.assertEqual(report['status'], 'failed')
                self.assertEqual(len(report['attempts']), 10)
                self.assertIsNone(report['comparison'])
                self.assertFalse(report['full_app_accepted'])
                for side in targets:
                    rows = [a for a in report['attempts'] if a['side'] == side]
                    self.assertEqual(report['valid_repetitions'][side], 0 if variant == 'failed-first' else 1)
                    for row in rows[1:]:
                        self.assertFalse(row['admitted'])
                        self.assertIn('reused-observation-population', row['reasons'])
                        self.assertEqual(row['run']['sample_count'], 2)
                        self.assertEqual(row['reused_sample_count'], 2)
                    domain = 'android.hwui' if side == 'native' else 'flutter.engine'
                    self.assertEqual(report['baselines_including_parsed_failed_attempts'][side][domain]['sample_count'], 2)
                    if variant == 'failed-first':
                        self.assertEqual(report['baselines_admitted_only'][side], {})
                    else:
                        self.assertEqual(report['baselines_admitted_only'][side][domain]['sample_count'], 2)
                data = (self.root / self.receipts['attempts'][2]['raw']['path']).read_bytes()
                self.assertEqual((self.root / variant / 'inputs' / digest(data)).read_bytes(), data)

    def test_numeric_failed_capture_reserves_population_before_retry(self):
        original = deepcopy(self.receipts)
        for side, domain in [('native', 'android.hwui'), ('flutter', 'flutter.engine')]:
            for collector in ['failed', 'passed']:
                with self.subTest(side=side, collector=collector):
                    self.receipts = deepcopy(original)
                    first = next(a for a in self.receipts['attempts'] if a['side'] == side)
                    retry = deepcopy(first)
                    retry.update(attempt_id=side + '-retry', repetition=6)
                    first['collector'] = collector
                    first['windows'][0]['displacement'] = 10**400
                    self.receipts['attempts'].append(retry)
                    self.save()
                    name = side + '-' + collector
                    code, report = self.cli('reduce', name)
                    self.assertEqual(code, 1)
                    self.assertEqual(len(report['attempts']), 11)
                    self.assertFalse(report['attempts'][-1]['admitted'])
                    self.assertEqual(report['attempts'][-1]['reused_sample_count'], 2)
                    self.assertIn('reused-observation-population', report['attempts'][-1]['reasons'])
                    failed = next(a for a in report['attempts'] if a.get('side') == side)
                    self.assertEqual(failed['outcomes']['collector'], collector)
                    self.assertIn('invalid-number', failed['reasons'])
                    if collector == 'failed':
                        self.assertIn('collector-not-passed', failed['reasons'])
                    self.assertEqual(failed['run']['sample_count'], 2)
                    self.assertEqual(failed['raw_sample_count'], 2)
                    self.assertEqual(failed['outside_window_count'], 0)
                    self.assertEqual(failed['windows'][0]['sample_count'], 2)
                    self.assertEqual(report['valid_repetitions'][side], 4)
                    first_index = original['attempts'].index(next(a for a in original['attempts'] if a['side'] == side))
                    self.assertTrue(all(a['admitted'] for i, a in enumerate(report['attempts'][:-1])
                                        if i != first_index))
                    diagnostic = report['baselines_including_parsed_failed_attempts'][side][domain]
                    admitted = report['baselines_admitted_only'][side][domain]
                    self.assertEqual(diagnostic['sample_count'], 10)
                    self.assertEqual(admitted['sample_count'], 8)
                    self.assertIsNone(report['comparison'])
                    self.assertFalse(report['full_app_accepted'])
                    for filename in ['receipts.json', first['raw']['path']]:
                        data = (self.root / filename).read_bytes()
                        self.assertEqual((self.root / name / 'inputs' / digest(data)).read_bytes(), data)

    def test_collector_and_numeric_failed_first_replay_has_no_admitted_pool(self):
        first = self.receipts['attempts'][0]
        retry = deepcopy(first)
        retry.update(attempt_id='native-retry', repetition=2)
        first['collector'] = 'failed'
        first['windows'][0]['displacement'] = 10**400
        self.receipts['attempts'] = [first, retry]
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertEqual(report['status'], 'failed')
        failed, replay = report['attempts']
        self.assertFalse(replay['admitted'])
        self.assertEqual(replay['reused_sample_count'], 2)
        self.assertEqual(report['valid_repetitions']['native'], 0)
        self.assertEqual(report['baselines_admitted_only']['native'], {})
        self.assertEqual(failed['outcomes']['collector'], 'failed')
        self.assertEqual(failed['reasons'], ['collector-not-passed', 'invalid-number'])
        self.assertEqual(failed['run'], replay['run'])
        self.assertEqual(report['baselines_including_parsed_failed_attempts']['native']['android.hwui'], failed['run'])
        self.assertIsNone(report['comparison'])
        self.assertFalse(report['full_app_accepted'])

    def test_window_admission_failure_keeps_only_established_populations(self):
        original_plan, original = deepcopy(self.plan), deepcopy(self.receipts)
        variants = {
            'cursor-object': ('expected-object', lambda a: a['windows'][0].update(cursor=[])),
            'cursor-number': ('invalid-number', lambda a: a['windows'][0]['cursor'].update(resolution_ms=10**400)),
            'missing-cursor': ('unknown-or-missing-key', lambda a: a['windows'][0].pop('cursor')),
            'missing-displacement': ('unknown-or-missing-key', lambda a: a['windows'][0].pop('displacement')),
            'later-clock': ('window-clock-mismatch', lambda a: a['windows'][1].update(clock='wall-clock')),
            'later-clock-number': ('invalid-integer', lambda a: a['windows'][1].update(start=10**400)),
            'later-name': ('wrong-or-duplicate-window', lambda a: a['windows'][1].update(name=[])),
            'later-cursor': ('expected-object', lambda a: a['windows'][1].update(cursor=[])),
            'later-displacement': ('invalid-number', lambda a: a['windows'][1].update(displacement=10**400)),
            'missing-phase': ('missing-window', lambda a: a['windows'].pop()),
        }
        for name, (reason, mutate) in variants.items():
            with self.subTest(name=name):
                self.plan, self.receipts = deepcopy(original_plan), deepcopy(original)
                self.plan['phases'].append({'name': 'second', 'audio_active': False, 'motion': False})
                for a in self.receipts['attempts']:
                    a['windows'][0]['end'] = 100
                    second = deepcopy(a['windows'][0])
                    second.update(name='second', start=100, end=200)
                    a['windows'].append(second)
                first = self.receipts['attempts'][0]
                retry = deepcopy(first)
                retry.update(attempt_id='native-retry', repetition=6)
                first['collector'] = 'failed'
                mutate(first)
                self.receipts['attempts'].append(retry)
                self.save()
                code, report = self.cli('reduce', name)
                self.assertEqual(code, 1)
                failed, replay = report['attempts'][0], report['attempts'][-1]
                self.assertFalse(replay['admitted'])
                established = 2 if name in ['later-cursor', 'later-displacement'] else 1
                self.assertEqual(replay['reused_sample_count'], established)
                self.assertEqual(failed['run']['sample_count'], established)
                self.assertEqual(len(failed['windows']), established)
                self.assertEqual(failed['raw_sample_count'], 2)
                self.assertEqual(failed['outside_window_count'], 2 - established)
                self.assertEqual(failed['outcomes']['collector'], 'failed')
                self.assertIn('collector-not-passed', failed['reasons'])
                self.assertIn(reason, failed['reasons'])
                if name in ['cursor-object', 'cursor-number']:
                    self.assertNotIn('cursor', failed['windows'][0])
                self.assertTrue(all(a['admitted'] for a in report['attempts'][1:-1]))
                self.assertEqual(report['valid_repetitions']['native'], 4)
                self.assertEqual(report['baselines_including_parsed_failed_attempts']['native']['android.hwui']['sample_count'], 10)
                self.assertEqual(report['baselines_admitted_only']['native']['android.hwui']['sample_count'], 8)
                self.assertIsNone(report['comparison'])
                self.assertFalse(report['full_app_accepted'])

    def test_unestablished_population_is_not_invented_or_reserved(self):
        original = deepcopy(self.receipts)
        variants = {
            'raw-unparseable': ('missing-or-ambiguous-surface', None),
            'window-list': ('invalid-windows', lambda a: a.update(windows=None)),
            'window-clock': ('window-clock-mismatch', lambda a: a['windows'][0].update(clock='wall-clock')),
            'window-number': ('invalid-integer', lambda a: a['windows'][0].update(start=10**400)),
            'window-empty': ('empty-window-frames', lambda a: a['windows'][0].update(start=901)),
        }
        for name, (reason, mutate) in variants.items():
            with self.subTest(name=name):
                self.receipts = deepcopy(original)
                first = self.receipts['attempts'][0]
                retry = deepcopy(first)
                retry.update(attempt_id='native-retry', repetition=6)
                first['collector'] = 'failed'
                if mutate:
                    mutate(first)
                else:
                    data = b'** Graphics info for pid 42 [example.native] **\n'
                    path = 'unparseable.raw'
                    (self.root / path).write_bytes(data)
                    first['raw'].update(path=path, sha256=digest(data))
                self.receipts['attempts'].append(retry)
                self.save()
                code, report = self.cli('reduce', name)
                self.assertEqual(code, 1)
                failed, replay = report['attempts'][0], report['attempts'][-1]
                self.assertIn(reason, failed['reasons'])
                self.assertNotIn('run', failed)
                if mutate:
                    self.assertEqual(failed['windows'], [])
                    self.assertEqual(failed['raw_sample_count'], 2)
                    self.assertEqual(failed['outside_window_count'], 2)
                    self.assertEqual(failed['outcomes']['collector'], 'failed')
                    self.assertIn('collector-not-passed', failed['reasons'])
                else:
                    self.assertNotIn('windows', failed)
                    self.assertNotIn('raw_sample_count', failed)
                self.assertTrue(replay['admitted'])
                self.assertEqual(replay['reused_sample_count'], 0)
                self.assertEqual(report['baselines_including_parsed_failed_attempts']['native']['android.hwui']['sample_count'], 10)
                self.assertTrue(all(a['admitted'] for a in report['attempts'][1:]))

    def test_failed_window_does_not_reserve_disjoint_raw_capture_frames(self):
        for index in [0, 1]:
            first, second = self.receipts['attempts'][index], self.receipts['attempts'][index + 2]
            second['process'] = deepcopy(first['process'])
            second['raw'] = deepcopy(first['raw'])
            first['windows'][0].update(end=100, displacement=10**400)
            first['collector'] = 'failed'
            second['windows'][0].update(start=100, end=200)
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        for index, (side, domain) in enumerate([('native', 'android.hwui'), ('flutter', 'flutter.engine')]):
            failed, adjacent = report['attempts'][index], report['attempts'][index + 2]
            self.assertEqual(failed['run']['sample_count'], 1)
            self.assertEqual(failed['outside_window_count'], 1)
            self.assertTrue(adjacent['admitted'])
            self.assertEqual(adjacent['reused_sample_count'], 0)
            self.assertEqual(report['valid_repetitions'][side], 4)
            self.assertEqual(report['baselines_including_parsed_failed_attempts'][side][domain]['sample_count'], 8)
            self.assertEqual(report['baselines_admitted_only'][side][domain]['sample_count'], 7)

    def test_failed_metadata_retains_interval_and_first_union_ownership(self):
        first, second = self.receipts['attempts'][0], self.receipts['attempts'][2]
        second['process'] = deepcopy(first['process'])
        second['raw']['process_start'] = first['raw']['process_start']
        # Same interval, new IDs: interval ownership must survive metadata failure.
        first['collector'] = 'failed'
        first['windows'][0]['displacement'] = 10**400
        # Rejected second population owns its new IDs for a later disjoint replay.
        third = deepcopy(second)
        third.update(attempt_id='native-third', repetition=6)
        data = (self.root / second['raw']['path']).read_bytes().replace(
            b'0,3,100,110,120,', b'0,3,1100,1115,1120,').replace(
            b'0,4,200,900,220,', b'0,4,1200,1900,1220,')
        (self.root / 'changed-third.raw').write_bytes(data)
        third['raw'].update(path='changed-third.raw', sha256=digest(data))
        third['windows'][0].update(start=1000, end=2000)
        third['windows'][0]['cursor']['after'] = 2000
        self.receipts['attempts'].append(third)
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertFalse(report['attempts'][2]['admitted'])
        self.assertEqual(report['attempts'][2]['reused_sample_count'], 0)
        self.assertIn('reused-observation-population', report['attempts'][2]['reasons'])
        self.assertFalse(report['attempts'][-1]['admitted'])
        self.assertEqual(report['attempts'][-1]['reused_sample_count'], 2)
        self.assertEqual(report['attempts'][-1]['run']['metrics']['hwui_span_ns']['p50'], 15)
        diagnostic = report['baselines_including_parsed_failed_attempts']['native']['android.hwui']
        self.assertEqual(diagnostic['sample_count'], 10)
        self.assertEqual(diagnostic['metrics']['hwui_span_ns']['p50'], 10)
        self.assertEqual(report['baselines_admitted_only']['native']['android.hwui']['sample_count'], 6)
        self.assertEqual(report['valid_repetitions']['native'], 3)

    def test_partial_shared_population_is_not_an_independent_repetition(self):
        first, second = self.receipts['attempts'][0], self.receipts['attempts'][2]
        second['process'] = deepcopy(first['process'])
        second['raw'] = deepcopy(first['raw'])
        data = (self.root / first['raw']['path']).read_bytes().replace(
            b'0,1,100,110,120,', b'0,3,300,310,320,')
        second['raw']['path'] = 'partial-copy.raw'
        second['raw']['sha256'] = digest(data)
        (self.root / second['raw']['path']).write_bytes(data)
        second['windows'][0].update(start=100, end=300)
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertIn('reused-observation-population', report['attempts'][2]['reasons'])
        self.assertEqual(report['valid_repetitions']['native'], 4)
        self.assertEqual(report['attempts'][2]['run']['sample_count'], 2)
        self.assertEqual(report['baselines_including_parsed_failed_attempts']['native']['android.hwui']['sample_count'], 9)
        self.assertEqual(report['baselines_admitted_only']['native']['android.hwui']['sample_count'], 8)

    def test_same_process_overlapping_windows_fail_even_without_shared_frame_ids(self):
        first, second = self.receipts['attempts'][0], self.receipts['attempts'][2]
        second['process'] = deepcopy(first['process'])
        second['raw']['process_start'] = first['raw']['process_start']
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertIn('reused-observation-population', report['attempts'][2]['reasons'])
        self.assertEqual(report['valid_repetitions']['native'], 4)

    def test_reused_frame_id_cannot_be_hidden_by_changed_timestamps_or_values(self):
        first, second = self.receipts['attempts'][0], self.receipts['attempts'][2]
        second['process'] = deepcopy(first['process'])
        second['raw'] = deepcopy(first['raw'])
        data = (self.root / first['raw']['path']).read_bytes().replace(
            b'0,1,100,110,120,', b'0,1,1100,1115,1120,').replace(
            b'0,2,200,900,220,', b'0,2,1200,1900,1220,')
        second['raw'].update(path='changed-values.raw', sha256=digest(data))
        (self.root / second['raw']['path']).write_bytes(data)
        second['windows'][0].update(start=1000, end=2000)
        second['windows'][0]['cursor']['after'] = 2000
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertEqual(report['attempts'][2]['reused_sample_count'], 2)
        self.assertEqual(report['attempts'][2]['run']['metrics']['hwui_span_ns']['p50'], 15)
        self.assertEqual(report['baselines_including_parsed_failed_attempts']['native']['android.hwui']['sample_count'], 8)
        self.assertEqual(report['baselines_admitted_only']['native']['android.hwui']['sample_count'], 8)

    def test_same_process_nonoverlapping_windows_can_share_capture_file(self):
        for index in [0, 1]:
            first, second = self.receipts['attempts'][index], self.receipts['attempts'][index + 2]
            second['process'] = deepcopy(first['process'])
            second['raw'] = deepcopy(first['raw'])
            first['windows'][0].update(end=100)
            second['windows'][0].update(start=100, end=200)
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 0)
        self.assertEqual(report['valid_repetitions'], {'native': 5, 'flutter': 5})
        for side, domain in [('native', 'android.hwui'), ('flutter', 'flutter.engine')]:
            self.assertEqual(report['baselines_admitted_only'][side][domain]['sample_count'], 8)

    def test_distinct_process_starts_can_repeat_raw_bytes_and_measurements(self):
        for side in ['native', 'flutter']:
            rows = [a for a in self.receipts['attempts'] if a['side'] == side]
            first = rows[0]
            for a in rows[1:]:
                start = a['raw']['process_start']
                a['raw'] = deepcopy(first['raw'])
                a['raw']['process_start'] = start
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 0)
        self.assertEqual(report['valid_repetitions'], {'native': 5, 'flutter': 5})
        self.assertEqual(report['baselines_admitted_only']['native']['android.hwui']['sample_count'], 10)

    def test_mutation_matrix_is_fail_closed(self):
        cases = {
            'raw-hash': lambda a: a['raw'].update(sha256='d' * 64),
            'bad-literal-hash': lambda a: a['raw'].update(sha256='A' * 64),
            'wrong-run': lambda a: a.update(run_id='other'),
            'wrong-pid': lambda a: a['raw'].update(pid=43),
            'wrong-process': lambda a: a['raw'].update(process_start='reused-pid'),
            'wrong-unit': lambda a: a['raw'].update(unit='ms'),
            'wrong-clock': lambda a: a['windows'][0].update(clock='wall-clock'),
            'empty-window': lambda a: a['windows'][0].update(end=0),
            'no-window-frames': lambda a: a['windows'][0].update(start=901),
            'optimistic-cursor': lambda a: a['windows'][0]['cursor'].update(kind='extrapolated'),
            'missing-cursor': lambda a: a['windows'][0].update(cursor=None),
            'pending-seek': lambda a: a['windows'][0]['cursor'].update(pending_seek=True),
            'wrong-occurrence': lambda a: a['windows'][0]['cursor'].update(occurrence='occ2'),
            'cursor-not-progressing': lambda a: a['windows'][0]['cursor'].update(end_position_ms=10),
            'unbracketed-cursor': lambda a: a['windows'][0]['cursor'].update(before=1),
            'no-motion': lambda a: a['windows'][0].update(displacement=0),
            'functional-failure': lambda a: a.update(functional='failed'),
            'app-failure': lambda a: a.update(app='failed'),
            'collector-failure': lambda a: a.update(collector='failed'),
            'cleanup-failure': lambda a: a.update(cleanup='failed'),
            'cleanup-omission': lambda a: a.pop('cleanup'),
            'noise': lambda a: a.update(noise=True),
            'incomplete': lambda a: a.update(complete=False),
            'unknown-field': lambda a: a.update(optimistic_summary=1),
            'bad-raw-format-type': lambda a: a['raw'].update(format=[]),
        }
        original = deepcopy(self.receipts)
        for index, (name, mutate) in enumerate(cases.items()):
            with self.subTest(name=name):
                self.receipts = deepcopy(original)
                mutate(self.receipts['attempts'][0])
                self.save()
                code, report = self.cli('reduce', f'mutation-{index}')
                self.assertEqual(code, 1)
                self.assertEqual(report['status'], 'failed')
                self.assertIsNone(report['comparison'])
                self.assertEqual(len(report['attempts']), 10)
                self.assertFalse(report['attempts'][0]['admitted'])

    def test_observed_manifests_must_match(self):
        mutations = [('environment', 'refresh_hz', 120), ('environment', 'viewport', [401, 800]),
            ('environment', 'physical_viewport', [802, 1600]), ('environment', 'font_scale', 1.5),
            ('environment', 'scale', 3), ('environment', 'fonts', 'other-fonts'),
            ('environment', 'audio_route', 'other-route'), ('environment', 'quiet', False),
            ('workload', 'cache', 'cold'), ('workload', 'animation', 'disabled'),
            ('workload', 'loaded_order', ['row2', 'row1']), ('workload', 'queue_order', ['occ2', 'occ1']),
            ('workload', 'dataset', 'd' * 64), ('features', 'name', 'other-features'),
            ('visible', 'artwork', 'images')]
        original = deepcopy(self.receipts)
        for index, (manifest, field, value) in enumerate(mutations):
            with self.subTest(manifest=manifest, field=field):
                self.receipts = deepcopy(original)
                self.receipts['attempts'][0]['observed'][manifest][field] = value
                self.save()
                code, report = self.cli('reduce', f'observed-{index}')
                self.assertEqual(code, 1)
                self.assertIn('observed-' + manifest + '-mismatch', report['attempts'][0]['reasons'])
                self.assertEqual(report['attempts'][0]['run']['metrics']['hwui_span_ns']['max'], 700)

    def test_missing_five_alternating_pair_repetitions_is_inconclusive(self):
        original = deepcopy(self.receipts)
        variants = {
            'missing-side': [a for a in original['attempts'] if a['side'] == 'native'],
            'four-pairs': original['attempts'][:8],
            'not-alternating': sorted(original['attempts'], key=lambda a: a['side']),
            'empty': [],
            'mismatched-repetition': deepcopy(original['attempts']),
        }
        variants['mismatched-repetition'][-1]['repetition'] = 6
        for name, attempts in variants.items():
            with self.subTest(name=name):
                self.receipts['attempts'] = attempts
                self.save()
                code, report = self.cli('reduce', name)
                self.assertEqual(code, 0)
                self.assertEqual(report['status'], 'inconclusive')
                self.assertIsNone(report['comparison'])

    def test_failure_preserves_tail_and_all_retry_attempts(self):
        a = self.receipts['attempts'][0]
        a['collector'] = 'failed'
        retry = deepcopy(a)
        retry.update(attempt_id='native-retry', collector='passed')
        self.receipts['attempts'].append(retry)
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertEqual(len(report['attempts']), 11)
        self.assertEqual(report['attempts'][0]['run']['metrics']['hwui_span_ns']['p99'], 700)
        raw = (self.root / a['raw']['path']).read_bytes()
        self.assertEqual((self.root / 'out' / 'inputs' / digest(raw)).read_bytes(), raw)

    def test_duplicate_attempt_ids_rejected(self):
        self.receipts['attempts'][-1]['attempt_id'] = self.receipts['attempts'][0]['attempt_id']
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertEqual(report['attempts'][-1]['reasons'], ['duplicate-attempt-id'])

    def test_plan_identity_and_unknown_duplicate_keys(self):
        for index, field in enumerate(['source', 'artifacts']):
            original = deepcopy(self.plan)
            ref = self.plan['sides'][0][field]
            if isinstance(ref, list):
                ref = ref[0]
            ref['sha256'] = 'd' * 64
            self.save()
            code, report = self.cli('validate', f'wrong-plan-{index}')
            self.assertEqual(code, 1)
            self.plan = original
        self.save()
        path = self.root / 'plan.json'
        path.write_text(path.read_text().replace('{', '{"schema":"bad",', 1))
        code, report = self.cli('validate', 'duplicate')
        self.assertEqual(code, 1)
        self.assertEqual(report['reasons'], ['duplicate-json-key'])

    def test_same_domain_labels_do_not_grant_cross_app_comparison(self):
        for a in self.receipts['attempts']:
            if a['side'] != 'flutter':
                continue
            native = self.receipts['attempts'][0]
            raw_path = self.root / native['raw']['path']
            raw = raw_path.read_bytes().replace(b'example.native', b'example.flutter')
            dest = self.root / a['raw']['path']
            dest.write_bytes(raw)
            a['raw'].update(format='android.hwui', clock='android-system-nanoTime', unit='ns',
                            surface='example.flutter/Main', sha256=digest(raw))
            a['windows'][0]['clock'] = a['raw']['clock']
            a['windows'][0]['cursor']['clock'] = a['raw']['clock']
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 0)
        self.assertIsNone(report['comparison'])
        self.assertEqual(report['status'], 'separate-unmatched-baselines')

    def test_windows_are_open_closed_not_inclusive(self):
        for a in self.receipts['attempts']:
            a['windows'][0]['start'] = 100
            a['windows'][0]['end'] = 200
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 0)
        for a in report['attempts']:
            self.assertEqual(a['run']['sample_count'], 1)
            self.assertEqual(a['outside_window_count'], 1)

    def test_path_escape_symlink_and_overwrite_refused(self):
        for index, path in enumerate(['../source.json', '/source.json', './source.json']):
            self.plan['sides'][0]['source']['path'] = path
            self.save()
            code, report = self.cli('validate', f'escape-{index}')
            self.assertEqual(code, 1)
        synthetic_bundle(self.root)
        (self.root / 'alias').symlink_to(self.root / 'source.json')
        self.plan, self.receipts = synthetic_bundle(self.root)
        self.plan['sides'][0]['source']['path'] = 'alias'
        self.save()
        code, report = self.cli('validate', 'symlink')
        self.assertEqual(code, 1)
        before = (self.root / 'symlink' / 'report.json').read_bytes()
        code, report = self.cli('validate', 'symlink')
        self.assertEqual(code, 2)
        self.assertEqual((self.root / 'symlink' / 'report.json').read_bytes(), before)

    def test_process_readback_cannot_be_relabelled(self):
        ref = self.receipts['attempts'][0]['process']
        path = self.root / ref['path']
        process = json.loads(path.read_text())
        process['build_mode'] = 'debug'
        path.write_text(json.dumps(process))
        ref['sha256'] = digest(path.read_bytes())
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertEqual(report['attempts'][0]['reasons'], ['process-identity-mismatch'])

    def test_parser_and_window_corruption_is_retained_as_failure(self):
        original_plan, original_receipts = deepcopy(self.plan), deepcopy(self.receipts)
        raw_path = self.root / self.receipts['attempts'][0]['raw']['path']
        original_raw = raw_path.read_bytes()
        corruptions = {
            'duplicate-frame': original_raw.replace(b'0,2,200,900,220,', b'0,1,200,900,220,'),
            'missing-field': original_raw.replace(b'0,2,200,900,220,', b'0,2,200,900,'),
            'bad-tail': original_raw.replace(b'0,2,200,900,220,', b'0,2,200,0,220,'),
            'missing-raw': b'Total frames rendered: 500\n95th percentile: 1ms\n',
            'flagged-tail': original_raw.replace(b'0,2,200,900,220,', b'1,2,200,900,220,'),
            'wrong-raw-pid': original_raw.replace(b'pid 42', b'pid 43'),
        }
        for name, data in corruptions.items():
            with self.subTest(name=name):
                self.receipts = deepcopy(original_receipts)
                raw_path.write_bytes(data)
                self.receipts['attempts'][0]['raw']['sha256'] = digest(data)
                self.save()
                code, report = self.cli('reduce', name)
                self.assertEqual(code, 1)
                self.assertEqual(len(report['attempts']), 10)
                self.assertEqual((self.root / name / 'inputs' / digest(data)).read_bytes(), data)
        raw_path.write_bytes(original_raw)
        self.receipts = deepcopy(original_receipts)
        self.plan = deepcopy(original_plan)
        self.plan['phases'].append({'name': 'second', 'audio_active': False, 'motion': False})
        self.receipts['attempts'][0]['windows'].append({'name': 'second',
            'clock': 'android-system-nanoTime', 'start': 150, 'end': 1001,
            'cursor': None, 'displacement': 0})
        self.save()
        code, report = self.cli('reduce', 'overlap')
        self.assertEqual(code, 1)
        self.assertEqual(report['attempts'][0]['reasons'], ['empty-or-overlapping-window'])

    def test_historical_missing_process_can_reduce_but_never_pass(self):
        self.receipts['attempts'][0]['process'] = None
        self.receipts['attempts'][0]['raw']['process_start'] = None
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertIn('process-identity-unavailable', report['attempts'][0]['reasons'])
        self.assertEqual(report['attempts'][0]['run']['sample_count'], 2)

    def test_unavailable_environment_is_not_zero_or_admission(self):
        for side in self.plan['sides']:
            side['environment']['refresh_hz'] = None
        for attempt in self.receipts['attempts']:
            attempt['observed']['environment']['refresh_hz'] = None
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertIn('environment-unavailable', report['attempts'][0]['reasons'])
        self.assertIsNone(report['comparison'])

    def test_bad_input_types_do_not_crash_or_leak_input(self):
        original = deepcopy(self.receipts)
        for index, (field, value) in enumerate([('side', []), ('raw', None),
                ('observed', []), ('windows', [None]), ('process', []), ('run_id', 'credential=private')]):
            self.receipts = deepcopy(original)
            self.receipts['attempts'][0][field] = value
            self.save()
            code, report = self.cli('reduce', f'bad-type-{index}')
            self.assertEqual(code, 1)
            self.assertEqual(len(report['attempts']), 10)
            self.assertNotIn('credential=private', json.dumps(report))

    def test_failed_attempts_not_pooled_into_admitted_baselines(self):
        self.receipts['attempts'][0]['noise'] = True
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertEqual(report['baselines_admitted_only']['native']['android.hwui']['sample_count'], 8)
        self.assertEqual(report['attempts'][0]['run']['sample_count'], 2)

    def test_bad_window_name_type_is_a_failed_attempt(self):
        self.receipts['attempts'][0]['windows'][0]['name'] = []
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 1)
        self.assertEqual(len(report['attempts']), 10)

    def test_actual_plan_feature_mismatch_remains_separate(self):
        self.plan['sides'][0]['visible']['artwork'] = 'none-native-preview'
        for a in self.receipts['attempts']:
            if a['side'] == 'native':
                a['observed']['visible']['artwork'] = 'none-native-preview'
        self.plan['scope'] = 'full-app'
        self.save()
        code, report = self.cli('reduce')
        self.assertEqual(code, 0)
        self.assertEqual(report['status'], 'separate-unmatched-baselines')
        self.assertFalse(report['full_app_accepted'])
        self.assertIn('feature-environment-workload-build-equivalence-not-established', report['reasons'])


if __name__ == '__main__':
    unittest.main()
