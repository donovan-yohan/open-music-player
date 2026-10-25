#!/usr/bin/env python3
"""Pure offline benchmark validation/reduction. No application or device driver."""
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
import hashlib
import json
import math
from pathlib import Path
import re
import sys


class Invalid(ValueError):
    """Unusable evidence; messages contain codes, never input values/paths."""


@dataclass(frozen=True)
class Frame:
    identity: int
    timestamp: int
    metrics: dict[str, int]
    deadline_missed: bool | None
    flagged: bool = False
    invalid: bool = False


@dataclass(frozen=True)
class RawSpec:
    domain: str
    clock: str
    unit: str


RAW_SPECS = {
    'android.hwui': RawSpec('android.hwui', 'android-system-nanoTime', 'ns'),
    'flutter.engine': RawSpec('flutter.engine', 'flutter-frame-timing', 'us'),
}


@dataclass(frozen=True)
class Window:
    name: str
    start: int
    end: int


def require(condition, code):
    if not condition:
        raise Invalid(code)


def integer(value, minimum=0):
    require(type(value) is int and minimum <= value < 2**63, 'invalid-integer')
    return value


def keys(value, required, optional=()):
    require(type(value) is dict, 'expected-object')
    require(set(required) <= value.keys() <= set(required) | set(optional), 'unknown-or-missing-key')


def parse_hwui(text, pid, application_id, surface):
    """dumpsys gfxinfo PROFILEDATA: timestamps/durations are nanoseconds.

    Select exactly one window; never infer frames from summary/histogram text.
    Retain flagged frames in distributions and disqualify their attempt later.
    """
    identities = re.findall(r'\*\* Graphics info for pid (\d+) \[([^\]]+)\] \*\*', text)
    require(identities == [(str(pid), application_id)], 'hwui-process-mismatch')
    current = None
    sections = []
    active = None
    for line in text.splitlines():
        if line.startswith('Window: '):
            current = line[len('Window: '):]
        elif line == '---PROFILEDATA---':
            if active is None:
                active = []
            else:
                sections.append((current, active))
                active = None
        elif active is not None and line.strip():
            active.append(line)
    require(active is None, 'truncated-profiledata')
    chosen = [rows for name, rows in sections if name == surface]
    require(len(chosen) == 1, 'missing-or-ambiguous-surface')
    rows = list(csv.reader(chosen[0]))
    require(len(rows) >= 2, 'missing-frames')
    header = rows[0]
    if header[-1] == '':
        header = header[:-1]
    required = {'Flags', 'FrameTimelineVsyncId', 'IntendedVsync', 'FrameCompleted'}
    require(len(header) == len(set(header)) and required <= set(header), 'invalid-hwui-header')
    frames = []
    seen = set()
    for row in rows[1:]:
        if row and row[-1] == '':
            row = row[:-1]
        require(len(row) == len(header), 'invalid-hwui-row')
        require(all(re.fullmatch(r'-?\d+', item) for item in row), 'invalid-hwui-number')
        try:
            values = dict(zip(header, map(int, row)))
        except ValueError:
            raise Invalid('invalid-hwui-number') from None
        identity = integer(values['FrameTimelineVsyncId'], 1)
        require(identity not in seen, 'duplicate-frame')
        seen.add(identity)
        start, end = values['IntendedVsync'], values['FrameCompleted']
        require(0 < start < 2**63 - 1, 'invalid-hwui-timing')
        deadline = values.get('FrameDeadline')
        require(deadline is None or start < deadline < 2**63 - 1, 'invalid-frame-deadline')
        integer(values['Flags'])
        invalid = not start <= end < 2**63 - 1
        frames.append(Frame(identity, start, {} if invalid else {'hwui_span_ns': end - start},
                            end > deadline if deadline is not None and not invalid else None,
                            values['Flags'] != 0, invalid))
    return frames


def parse_flutter(data):
    """Raw FrameTiming maps emitted by desktop_scroll_profile_test.dart.

    rasterFinishWallTime is a different (wall) clock and is never joined.
    Enclosing legacy report summaries are not accepted as raw measurements.
    Export only its rawFrames member without changing the frame maps.
    """
    keys(data, ['rawFrames'])
    require(type(data['rawFrames']) is list and bool(data['rawFrames']), 'missing-frames')
    fields = {'frameNumber', 'vsyncStart', 'buildStart', 'buildFinish', 'rasterStart',
              'rasterFinish', 'rasterFinishWallTime', 'uiUs', 'rasterUs',
              'totalSpanUs', 'vsyncOverheadUs'}
    frames = []
    seen = set()
    for f in data['rawFrames']:
        keys(f, fields)
        for value in f.values():
            integer(value)
        identity = f['frameNumber']
        require(identity not in seen, 'duplicate-frame')
        seen.add(identity)
        require(0 < f['vsyncStart'] <= f['buildStart'] <= f['buildFinish']
                <= f['rasterStart'] <= f['rasterFinish'], 'invalid-flutter-timing')
        expected = {'uiUs': f['buildFinish'] - f['buildStart'],
                    'rasterUs': f['rasterFinish'] - f['rasterStart'],
                    'totalSpanUs': f['rasterFinish'] - f['vsyncStart'],
                    'vsyncOverheadUs': f['buildStart'] - f['vsyncStart']}
        require(all(f[k] == v for k, v in expected.items()), 'forged-flutter-duration')
        metrics = dict(zip(['flutter_ui_us', 'flutter_raster_us', 'flutter_total_span_us',
                            'flutter_vsync_overhead_us'], expected.values()))
        frames.append(Frame(identity, f['vsyncStart'], metrics, None))
    return frames


def quantiles(values):
    ordered = sorted(values)
    require(bool(ordered), 'missing-frames')
    return {**{key: ordered[math.ceil(len(ordered) * q) - 1]
               for key, q in [('p50', .5), ('p95', .95), ('p99', .99)]},
            'max': ordered[-1]}


def distribution(frames):
    require(bool(frames), 'missing-frames')
    deadlines = [f.deadline_missed for f in frames]
    metric_names = sorted({metric for f in frames for metric in f.metrics})
    return {'sample_count': len(frames),
            'metric_sample_count': {metric: sum(metric in f.metrics for f in frames)
                                    for metric in metric_names},
            'metrics': {metric: quantiles([f.metrics[metric] for f in frames if metric in f.metrics])
                        for metric in metric_names},
            'invalid_count': sum(f.invalid for f in frames),
            'invalid_frame_ids': [f.identity for f in frames if f.invalid],
            'deadline_sample_count': sum(v is not None for v in deadlines),
            'deadline_misses': (sum(v is True for v in deadlines)
                                if all(v is not None for v in deadlines) else None),
            'flagged_count': sum(f.flagged for f in frames)}


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate-json-key')
            result[key] = value
        return result
    def constant(_):
        raise Invalid('nonfinite-json')
    try:
        return json.loads(data, object_pairs_hook=pairs, parse_constant=constant)
    except Invalid:
        raise
    except (UnicodeError, ValueError, RecursionError):
        raise Invalid('invalid-json') from None


def token(value):
    require(type(value) is str and bool(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,159}', value)),
            'invalid-token')
    return value


def tokens(values, nonempty=False):
    require(type(values) is list and (bool(values) or not nonempty), 'invalid-list')
    for value in values:
        token(value)
    require(len(values) == len(set(values)), 'duplicate-list-id')


def sha(value, length=64):
    require(type(value) is str and bool(re.fullmatch('[0-9a-f]{' + str(length) + '}', value)),
            'invalid-hash')


def number(value, minimum=0, positive=False):
    # Bound before any float conversion; arbitrary JSON integers can overflow it.
    # Non-clock quantities use the exactly representable integer magnitude range.
    require(type(value) in (int, float) and value <= 2**53 - 1
            and (value > minimum if positive else value >= minimum), 'invalid-number')


class Inputs:
    """Contained immutable reads and content-addressed snapshots; no supplied paths in reports."""
    def __init__(self, root):
        self.root = root.resolve()
        self.files = {}

    def read(self, ref):
        keys(ref, ['path', 'sha256'])
        sha(ref['sha256'])
        name = ref['path']
        require(type(name) is str and bool(re.fullmatch(r'[A-Za-z0-9_./-]+', name)), 'invalid-path')
        path = Path(name)
        require(not path.is_absolute() and all(p not in ('.', '..') for p in name.split('/')),
                'path-escape')
        current = self.root
        for part in path.parts:
            current = current / part
            require(not current.is_symlink(), 'symlink-input')
        path = current.resolve()
        require(path.is_relative_to(self.root) and path.is_file(), 'missing-contained-input')
        data = path.read_bytes()
        require(hashlib.sha256(data).hexdigest() == ref['sha256'], 'hash-mismatch')
        require(path not in self.files or self.files[path] == data, 'input-changed')
        self.files[path] = data
        return data

    def verify(self):
        require(all(p.read_bytes() == data for p, data in self.files.items()), 'input-changed')

    def retain(self, out):
        self.verify()
        raw = out / 'inputs'
        raw.mkdir()
        for data in self.files.values():
            target = raw / hashlib.sha256(data).hexdigest()
            if not target.exists():
                with target.open('xb') as stream:
                    stream.write(data)
        self.verify()


def manifests(side):
    env = side['environment']
    keys(env, ['name', 'platform', 'device', 'os', 'renderer', 'viewport',
               'physical_viewport', 'scale', 'refresh_hz', 'font_scale', 'fonts',
               'audio_route', 'power', 'quiet'])
    for field in ['name', 'platform', 'device', 'os', 'renderer', 'fonts', 'audio_route', 'power']:
        token(env[field])
    require(env['platform'] in ('android', 'macos', 'windows'), 'invalid-platform')
    for field in ['scale', 'refresh_hz', 'font_scale']:
        if env[field] is not None:
            number(env[field], positive=True)
    for field in ['viewport', 'physical_viewport']:
        if env[field] is None:
            continue
        require(type(env[field]) is list and len(env[field]) == 2, 'invalid-viewport')
        for value in env[field]:
            number(value, positive=True)
    require(type(env['quiet']) is bool, 'invalid-quiet')
    w = side['workload']
    keys(w, ['name', 'dataset', 'loaded_order', 'queue_order', 'selected', 'cache',
             'animation', 'input', 'route'])
    sha(w['dataset'])
    for field in ['name', 'selected', 'cache', 'animation', 'input', 'route']:
        token(w[field])
    tokens(w['loaded_order'], True)
    tokens(w['queue_order'], True)
    require(w['selected'] in w['queue_order'], 'selected-not-queued')
    f = side['features']
    keys(f, ['name', 'required', 'implemented', 'exercised', 'missing'])
    token(f['name'])
    for field in ['required', 'implemented', 'exercised', 'missing']:
        tokens(f[field], field == 'required')
    require(set(f['exercised']) <= set(f['implemented']), 'unimplemented-feature')
    v = side['visible']
    keys(v, ['name', 'columns', 'artwork', 'actions', 'geometry'])
    for field in ['name', 'artwork', 'geometry']:
        token(v[field])
    tokens(v['columns'], True)
    tokens(v['actions'])


def validate_plan(plan, inputs):
    keys(plan, ['schema', 'run_id', 'scope', 'exclusions', 'sides', 'phases'])
    require(plan['schema'] == 'soundq.performance.plan.v1', 'unknown-plan-version')
    token(plan['run_id'])
    token(plan['scope'])
    tokens(plan['exclusions'], True)
    require(type(plan['sides']) is list and 1 <= len(plan['sides']) <= 2, 'invalid-sides')
    names = []
    for side in plan['sides']:
        keys(side, ['name', 'source', 'artifacts', 'application_id', 'build_mode',
                    'optimization', 'entrypoint', 'environment', 'workload', 'features', 'visible'])
        require(side['name'] in ('native', 'flutter'), 'invalid-side')
        names.append(side['name'])
        for field in ['application_id', 'optimization', 'entrypoint']:
            token(side[field])
        require(side['build_mode'] in ('debug', 'profile', 'release'), 'invalid-build-mode')
        source = strict_json(inputs.read(side['source']))
        keys(source, ['commit', 'tree'])
        sha(source['commit'], 40)
        sha(source['tree'], 40)
        require(type(side['artifacts']) is list and bool(side['artifacts']), 'missing-artifacts')
        artifact_paths = []
        for artifact in side['artifacts']:
            inputs.read(artifact)
            artifact_paths.append(artifact['path'])
        require(len(set(artifact_paths)) == len(artifact_paths), 'duplicate-artifact')
        manifests(side)
    require(len(set(names)) == len(names), 'duplicate-side')
    require(type(plan['phases']) is list and bool(plan['phases']), 'missing-phases')
    names = []
    for phase in plan['phases']:
        keys(phase, ['name', 'audio_active', 'motion'])
        names.append(token(phase['name']))
        require(type(phase['audio_active']) is bool and type(phase['motion']) is bool, 'invalid-phase')
    require(len(set(names)) == len(names), 'duplicate-phase')


def cursor_status(cursor, window, selected):
    if cursor is None:
        return 'unavailable'
    keys(cursor, ['kind', 'session', 'occurrence', 'start_position_ms', 'end_position_ms',
                  'before', 'after', 'clock', 'ready', 'pending_seek', 'discontinuities', 'resolution_ms'])
    token(cursor['session'])
    token(cursor['occurrence'])
    for field in ['start_position_ms', 'end_position_ms', 'before', 'after', 'discontinuities']:
        integer(cursor[field])
    number(cursor['resolution_ms'], positive=True)
    require(type(cursor['ready']) is bool and type(cursor['pending_seek']) is bool, 'invalid-cursor')
    admitted = (cursor['kind'] in ('native-direct', 'native-pause-refresh')
                and cursor['clock'] == window['clock']
                and cursor['before'] <= window['start'] < window['end'] <= cursor['after']
                and cursor['ready'] and not cursor['pending_seek']
                and cursor['discontinuities'] == 0 and cursor['occurrence'] == selected
                and cursor['end_position_ms'] > cursor['start_position_ms'])
    return 'admitted' if admitted else 'rejected'


def reduce_attempt(attempt, plan, inputs):
    keys(attempt, ['attempt_id', 'run_id', 'side', 'repetition', 'process', 'observed', 'raw',
                   'windows', 'functional', 'app', 'collector', 'cleanup', 'noise', 'complete'])
    token(attempt['attempt_id'])
    require(attempt['run_id'] == plan['run_id'], 'wrong-run-id')
    integer(attempt['repetition'], 1)
    sides = {s['name']: s for s in plan['sides']}
    require(type(attempt['side']) is str and attempt['side'] in sides, 'unknown-side')
    side = sides[attempt['side']]
    for field in ['functional', 'app', 'collector', 'cleanup']:
        require(attempt[field] in ('passed', 'failed', 'unavailable'), 'invalid-outcome')
    for field in ['noise', 'complete']:
        require(type(attempt[field]) is bool, 'invalid-outcome')
    reasons = [field + '-not-passed' for field in ['functional', 'app', 'collector', 'cleanup']
               if attempt[field] != 'passed']
    if attempt['noise'] or not attempt['complete']:
        reasons.append('noisy-or-incomplete')
    observed = attempt['observed']
    keys(observed, ['environment', 'workload', 'features', 'visible'])
    manifests(observed)
    for field in observed:
        if observed[field] != side[field]:
            reasons.append('observed-' + field + '-mismatch')
    if any(v is None or v == 'unavailable' for v in observed['environment'].values()):
        reasons.append('environment-unavailable')
    raw = attempt['raw']
    keys(raw, ['path', 'sha256', 'format', 'clock', 'unit', 'pid', 'process_start', 'surface'])
    source = strict_json(inputs.read(side['source']))
    if attempt['process'] is None:
        # Historical raw remains reducible without inventing absent start/artifact readback.
        reasons.append('process-identity-unavailable')
        process = {'pid': raw['pid'], 'process_start': None,
                   'application_id': side['application_id']}
    else:
        process = strict_json(inputs.read(attempt['process']))
        keys(process, ['pid', 'process_start', 'application_id', 'artifact_sha256',
                       'source_commit', 'source_tree', 'build_mode'])
        integer(process['pid'], 1)
        token(process['process_start'])
        sha(process['artifact_sha256'])
        sha(process['source_commit'], 40)
        sha(process['source_tree'], 40)
        require(process['application_id'] == side['application_id']
                and process['source_commit'] == source['commit'] and process['source_tree'] == source['tree']
                and process['artifact_sha256'] == side['artifacts'][0]['sha256']
                and process['build_mode'] == side['build_mode'], 'process-identity-mismatch')
    require(type(raw['format']) is str and raw['format'] in RAW_SPECS, 'unsupported-frame-domain')
    spec = RAW_SPECS[raw['format']]
    require((raw['clock'], raw['unit']) == (spec.clock, spec.unit), 'wrong-frame-clock-or-unit')
    require(type(raw['pid']) is int and raw['pid'] == process['pid']
            and raw['process_start'] == process['process_start'], 'collector-process-mismatch')
    data = inputs.read({k: raw[k] for k in ('path', 'sha256')})
    if spec.domain == 'android.hwui':
        require(type(raw['surface']) is str, 'missing-surface')
        frames = parse_hwui(data.decode('utf-8'), raw['pid'], process['application_id'], raw['surface'])
    else:
        require(raw['surface'] is None, 'invalid-flutter-surface')
        frames = parse_flutter(strict_json(data))
    phases = {p['name']: p for p in plan['phases']}
    windows, combined, names = [], [], []
    previous = -1
    # Retain only established measured populations, never every raw capture frame.
    # Later admission metadata cannot erase their diagnostics or replay ownership.
    try:
        require(type(attempt['windows']) is list, 'invalid-windows')
        for item in attempt['windows']:
            keys(item, ['name', 'clock', 'start', 'end'], ['cursor', 'displacement'])
            require(type(item['name']) is str and item['name'] in phases
                    and item['name'] not in names, 'wrong-or-duplicate-window')
            names.append(item['name'])
            require(item['clock'] == spec.clock, 'window-clock-mismatch')
            start, end = integer(item['start']), integer(item['end'])
            require(previous <= start < end, 'empty-or-overlapping-window')
            previous = end
            window = Window(item['name'], start, end)
            population = [f for f in frames if window.start < f.timestamp <= window.end]
            require(bool(population), 'empty-window-frames')
            summary = {'name': window.name, 'start': start, 'end': end, 'clock': spec.clock,
                       **distribution(population)}
            windows.append(summary)
            combined.extend(population)
            keys(item, ['name', 'clock', 'start', 'end', 'cursor', 'displacement'])
            status = cursor_status(item['cursor'], item, observed['workload']['selected'])
            summary['cursor'] = status
            if phases[item['name']]['audio_active'] and status != 'admitted':
                reasons.append('audio-cursor-' + status)
            number(item['displacement'])
            if phases[item['name']]['motion'] and item['displacement'] <= 0:
                reasons.append('motion-not-observed')
        require(set(names) == set(phases), 'missing-window')
    except Invalid as exc:
        # Raw/process parsing above must succeed before this bounded recovery seam.
        reasons.append(str(exc))
    if any(f.invalid for f in frames):
        reasons.append('invalid-hwui-frames-retained')
    if any(f.flagged for f in frames):
        reasons.append('flagged-hwui-frames')
    # Observation identity uses supplied process/source/artifact facts, not receipt
    # labels, reference paths/hashes, measurement values or repetition numbers.
    scope = (observed['environment']['platform'], observed['environment']['device'],
             process['application_id'], source['commit'], source['tree'],
             side['artifacts'][0]['sha256'], process['pid'], process['process_start'],
             spec.domain, raw['surface'], spec.clock)
    return {'attempt_id': attempt['attempt_id'], 'side': attempt['side'],
            'repetition': attempt['repetition'], 'domain': spec.domain,
            'admitted': not reasons, 'reasons': reasons, 'windows': windows,
            'raw_sample_count': len(frames), 'outside_window_count': len(frames) - len(combined),
            **({'run': distribution(combined)} if combined else {})}, combined, scope


def reduce_receipts(receipts, inputs):
    keys(receipts, ['schema', 'plan', 'attempts'])
    require(receipts['schema'] == 'soundq.performance.receipts.v1', 'unknown-receipt-version')
    plan = strict_json(inputs.read(receipts['plan']))
    validate_plan(plan, inputs)
    require(type(receipts['attempts']) is list, 'invalid-attempts')
    results = []
    seen = set()
    populations = {'native': {}, 'flutter': {}}
    admitted_populations = {'native': {}, 'flutter': {}}
    observed_frames, observed_windows = {}, {}
    for attempt in receipts['attempts']:
        try:
            require(type(attempt) is dict, 'invalid-attempt')
            identity = token(attempt.get('attempt_id'))
            require(identity not in seen, 'duplicate-attempt-id')
            seen.add(identity)
            result, frames, scope = reduce_attempt(attempt, plan, inputs)
            known = observed_frames.setdefault(scope, set())
            intervals = observed_windows.setdefault(scope, [])
            reused = sum(f.identity in known for f in frames)
            overlap = any(max(w['start'], start) < min(w['end'], end)
                          for w in result['windows'] for start, end in intervals)
            result['reused_sample_count'] = reused
            if reused or overlap:
                result['admitted'] = False
                result['reasons'].append('reused-observation-population')
            # Failed attempts reserve their identities too: a relabeled retry
            # cannot launder known failed observations into an independent run.
            known.update(f.identity for f in frames)
            intervals.extend((w['start'], w['end']) for w in result['windows'])
            # Keep every parsed tail, including functional/noisy failures; never pool as matched.
            result['outcomes'] = {k: attempt[k] for k in ['functional', 'app', 'collector', 'cleanup', 'noise', 'complete']}
            for population in ([populations] + ([admitted_populations] if result['admitted'] else [])
                               if frames else []):
                union = population[result['side']].setdefault(result['domain'], {})
                for frame in frames:
                    union.setdefault((scope, frame.identity), frame)
        except (Invalid, OSError, UnicodeError) as exc:
            result = {'input_index': len(results), 'admitted': False,
                      'reasons': [str(exc) if isinstance(exc, Invalid) else 'input-read-failed']}
        results.append(result)
    reasons = []
    sides = {s['name']: s for s in plan['sides']}
    valid = [r for r in results if r['admitted']]
    failed = len(valid) != len(results)
    if failed:
        reasons.append('failed-attempts-retained')
    schedule_ok = set(sides) == {'native', 'flutter'}
    counts = {}
    for side in ('native', 'flutter'):
        reps = [r['repetition'] for r in valid if r['side'] == side]
        counts[side] = len(set(reps))
        schedule_ok &= len(reps) == len(set(reps)) and len(reps) >= 5
    schedule_ok &= all(a['side'] != b['side'] for a, b in zip(valid, valid[1:]))
    native_reps = [r['repetition'] for r in valid if r['side'] == 'native']
    flutter_reps = [r['repetition'] for r in valid if r['side'] == 'flutter']
    schedule_ok &= native_reps == flutter_reps and native_reps == sorted(native_reps)
    if not schedule_ok:
        reasons.append('requires-five-distinct-alternating-complete-repetitions-per-side')
    equivalence = False
    if len(sides) == 2:
        a, b = sides['native'], sides['flutter']
        equivalence = all(a[field] == b[field] for field in
                          ['environment', 'workload', 'features', 'visible', 'build_mode', 'optimization'])
        equivalence &= all(s['entrypoint'] == 'actual-app' and s['build_mode'] != 'debug'
                           and s['environment']['quiet'] and not s['features']['missing']
                           and set(s['features']['required']) <= set(s['features']['exercised'])
                           for s in sides.values())
    if not equivalence:
        reasons.append('feature-environment-workload-build-equivalence-not-established')
    def aggregate(population):
        return {side: {domain: distribution(list(frames.values()))
                       for domain, frames in sorted(domains.items())}
                for side, domains in population.items()}
    baseline = aggregate(populations)
    admitted_baseline = aggregate(admitted_populations)
    # HWUI describes an Android View pipeline, never Flutter engine rendering.
    # Neither currently supported domain is a cross-application presentation metric.
    reasons.append('no-supported-common-renderer-neutral-collector-domain')
    status = ('failed' if failed else 'inconclusive' if not schedule_ok
              else 'separate-unmatched-baselines')
    return {'schema': 'soundq.performance.report.v1', 'status': status,
            'scope': plan['scope'], 'exclusions': plan['exclusions'],
            'run_id': plan['run_id'], 'comparison': None, 'full_app_accepted': False,
            'reasons': reasons, 'valid_repetitions': counts, 'attempts': results,
            'baselines_including_parsed_failed_attempts': baseline,
            'baselines_admitted_only': admitted_baseline,
            'unavailable': ['cpu', 'rss', 'time-to-first-native-progress', 'acoustic-onset'],
            'estimator': 'nearest-rank', 'window_convention': '(start,end]'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name, option in [('validate', '--plan'), ('reduce', '--receipts')]:
        sub = commands.add_parser(name)
        sub.add_argument(option, type=Path, required=True)
        sub.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args(argv)
    out = args.evidence
    # mkdir without exist_ok is the no-overwrite gate, including symlinks/empty dirs.
    try:
        require(not any(p.is_symlink() for p in [out, *out.parents]), 'symlink-output')
        out.mkdir(mode=0o700)
    except (OSError, Invalid):
        print('evidence-directory-must-be-new', file=sys.stderr)
        return 2
    inputs = None
    try:
        path = args.plan if args.command == 'validate' else args.receipts
        require(not path.is_symlink(), 'symlink-input')
        inputs = Inputs(path.resolve().parent)
        data = path.read_bytes()
        inputs.files[path.resolve()] = data
        value = strict_json(data)
        if args.command == 'validate':
            validate_plan(value, inputs)
            report = {'schema': 'soundq.performance.report.v1', 'status': 'validated',
                      'scope': value['scope'], 'exclusions': value['exclusions'],
                      'comparison': None, 'full_app_accepted': False}
        else:
            report = reduce_receipts(value, inputs)
    except (Invalid, OSError, UnicodeError) as exc:
        report = {'schema': 'soundq.performance.report.v1', 'status': 'failed',
                  'comparison': None, 'full_app_accepted': False,
                  'reasons': [str(exc) if isinstance(exc, Invalid) else 'input-read-failed']}
    # Validation failures still retain every original byte successfully read.
    if inputs is not None:
        try:
            inputs.retain(out)
        except (Invalid, OSError):
            report = {'schema': 'soundq.performance.report.v1', 'status': 'failed',
                      'comparison': None, 'full_app_accepted': False,
                      'reasons': ['input-retention-failed']}
    with (out / 'report.json').open('x') as stream:
        json.dump(report, stream, indent=2, allow_nan=False)
        stream.write('\n')
    print(report['status'])
    return 1 if report['status'] == 'failed' else 0


if __name__ == '__main__':
    sys.exit(main())
