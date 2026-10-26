#!/usr/bin/env python3
"""Offline Flutter renderer-tail budgets. Not physical presentation or audio.

Consumes actual-root profile-launch reports, not arbitrary claimed summaries.
No collection, numeric budget defaults, baseline ratchet or cross-renderer ratio.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
from typing import Any

from flutter_profile_launch import validate_report
from matched_performance import Invalid, keys, manifests, number, parse_flutter, quantiles, require, sha, strict_json, token
from performance_gate import BoundedInputs, bounded_read, evidence_overlap, load, read_attempt, stats

PHASE = 'populated-scroll-audio-unavailable'
METRICS = ('flutter_ui_us', 'flutter_raster_us', 'flutter_total_span_us', 'flutter_vsync_overhead_us')
ESTIMATES = ('p95', 'max')
# Five observations in the upper 5% of a run, not a timing or FPS target.
MIN_TAIL_FRAMES = 100
LIMITS = ['renderer-not-physical-presentation', 'non-audio-ephemeral-storage-diagnostic',
          'caller-provenance-not-compilation-proof']
WORKLOAD_EXTRA = ('storage', 'artwork', 'audio')


class RendererInputs(BoundedInputs):
    """Retain safely read rejected bytes as well as admitted references."""
    def read(self, ref):
        keys(ref, ['path', 'sha256']);sha(ref['sha256'])
        name = ref['path']
        require(type(name) is str and len(name) <= 4096
                and re.fullmatch(r'[A-Za-z0-9_./-]+', name)
                and not Path(name).is_absolute()
                and all(p not in ('', '.', '..') for p in name.split('/')), 'invalid-path')
        path = self.root/name
        data = bounded_read(path)
        self.last_read_data = data
        self.last_read_sha256 = hashlib.sha256(data).hexdigest()
        require(path not in self.files or self.files[path] == data, 'input-changed')
        self.files[path] = data
        require(self.last_read_sha256 == ref['sha256'], 'hash-mismatch')
        return data


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'),
                                    allow_nan=False).encode()).hexdigest()


def cohort_shape(obj):
    keys(obj, ['schema', 'run_id', 'source', 'source_manifest_sha256',
               'artifact_manifest_sha256', 'build_mode', 'environment', 'workload',
               'features', 'visible', 'attempts'])
    require(obj['schema'] == 'soundq.flutter.renderer-cohort.v1', 'unknown-cohort-version')
    token(obj['run_id'])
    keys(obj['source'], ['commit', 'tree'])
    for value in obj['source'].values():sha(value, 40)
    for key in ('source_manifest_sha256', 'artifact_manifest_sha256'):sha(obj[key])
    require(obj['build_mode'] == 'profile', 'profile-build-required')
    workload = obj['workload']
    keys(workload, ['name', 'dataset', 'loaded_order', 'queue_order', 'selected',
                    'cache', 'animation', 'input', 'route', *WORKLOAD_EXTRA])
    # Reuse shared schema rather than duplicating its numeric/token arithmetic.
    projection = dict(obj, workload={k: v for k, v in workload.items() if k not in WORKLOAD_EXTRA})
    projection['workload']['route'] = 'library'
    manifests(projection)
    require(obj['environment']['platform'] == 'macos'
            and obj['environment']['renderer'] == 'flutter.engine', 'unsupported-domain')
    require(workload['storage'] == 'EPHEMERAL STORAGE'
            and workload['artwork'] == 'placeholder-only-memory-cache'
            and workload['audio'] == 'unavailable-native-readback-not-proven'
            and workload['route'] == '/library', 'unsupported-workload')
    require(obj['visible']['artwork'] == workload['artwork'], 'artwork-mismatch')
    require(all(re.fullmatch(r'row-[1-9][0-9]*', value) for value in workload['loaded_order']),
            'invalid-loaded-row-identity')
    require(type(obj['attempts']) is list and 0 < len(obj['attempts']) <= 200, 'invalid-attempts')


def reduce_cohort(obj, inputs):
    cohort_shape(obj)
    attempts, seen = [], set()
    for index, attempt in enumerate(obj['attempts']):
        row: dict[str, Any] = dict(input_index=index, admitted=False, reasons=[], metrics=None,
                   phase_sample_count=None)
        try:
            report = read_attempt(attempt, inputs, row, seen)
            keys(report, ['schema', 'status', 'run_id', 'pid', 'process_start_wall_ns',
                          'failure_codes', 'artifact_before', 'artifact_after', 'cleanup',
                          'child_report', 'renderer', 'full_app_accepted', 'limits'],
                 ['artifact_manifest_sha256', 'source', 'exit_code'])
            require(report['schema'] == 'soundq.flutter.profile-launch.v1', 'unknown-launch-version')
            token(report['run_id'])
            require(type(report['pid']) is int and 0 < report['pid'] < 2**31, 'invalid-pid')
            require(type(report['process_start_wall_ns']) is int
                    and 0 < report['process_start_wall_ns'] < 2**63, 'invalid-process-start')
            expected = dict(source_commit=obj['source']['commit'], source_tree=obj['source']['tree'],
                            source_manifest_sha256=obj['source_manifest_sha256'])
            require(report.get('source') == expected
                    and report.get('artifact_manifest_sha256') == obj['artifact_manifest_sha256'],
                    'source-artifact-mismatch')
            child = report['child_report']
            request = dict(expected, run_id=report['run_id'])
            recalculated = validate_report(child, request, report['pid'])
            require(canonical_hash(report['renderer']) == canonical_hash(recalculated), 'renderer-summary-mismatch')
            declared = {int(value[4:]) for value in obj['workload']['loaded_order']}
            require(child['loaded_list_slots'] == len(declared)
                    and set(child['witnessed_row_ids']) <= declared, 'observed-population-mismatch')
            frames = parse_flutter({'rawFrames': child['rawFrames']})
            require(all(b.identity > a.identity and b.timestamp > a.timestamp
                        for a, b in zip(frames, frames[1:])), 'frame-order-invalid')
            env = obj['environment']
            require(child['physical_viewport'] == env['physical_viewport']
                    and child['scale'] == env['scale'], 'viewport-mismatch')
            require(env['viewport'] is not None and env['scale'] is not None
                    and all(math.isclose(p / child['scale'], logical, rel_tol=0, abs_tol=1e-6)
                            for p, logical in zip(child['physical_viewport'], env['viewport'])),
                    'logical-viewport-mismatch')
            measured, counts = {}, {}
            for window in child['windows']:
                population = [f for f in frames if window['start'] < f.timestamp <= window['end']]
                counts[window['name']] = len(population)
                if population:
                    measured[window['name']] = {m: quantiles([f.metrics[m] for f in population])
                                                for m in METRICS}
            # Valid failed journeys retain their observed phase tails. Admission
            # is separate, and no valid completed phase is quietly dropped.
            row.update(metrics=measured, phase_sample_count=counts)
            require(counts.get(PHASE, 0) >= MIN_TAIL_FRAMES, 'renderer-tail-underpopulated')
            require(child['status'] == 'completed-diagnostic' and child['framework_error_count'] == 0,
                    'functional-invariant-failed')
            require(report['status'] == 'completed-diagnostic' and report['failure_codes'] == []
                    and report['artifact_before'] is True and report['artifact_after'] is True
                    and report['cleanup'] == 'reaped' and report['full_app_accepted'] is False
                    and report['limits'] == LIMITS and type(report.get('exit_code')) is int
                    and report['exit_code'] in (0, -15), 'launch-or-cleanup-failed')
            row['admitted'] = True
        except (Invalid, OSError, UnicodeError, ValueError, TypeError, KeyError, OverflowError, RecursionError) as exc:
            row['reasons'].append(str(exc) if isinstance(exc, Invalid) else 'invalid-report-evidence')
        attempts.append(row)
    reasons = []
    if any(not r['admitted'] for r in attempts):reasons.append('failed-attempts-retained')
    if len(attempts) < 5:reasons.append('requires-five-independent-processes')
    env = obj['environment']
    if not env['quiet']:reasons.append('shared-host-not-qualified')
    if any(v is None or v == 'unavailable' for v in env.values()):reasons.append('environment-unavailable')
    feature = obj['features']
    if feature['missing'] or not set(feature['required']) <= set(feature['exercised']):
        reasons.append('features-not-exercised')
    def aggregate(rows):
        names = sorted({name for r in rows if r['metrics'] is not None for name in r['metrics']})
        return {name: {m: {q: stats([r['metrics'][name][m][q] for r in rows
                                         if r['metrics'] is not None and name in r['metrics']])
                          for q in ESTIMATES} for m in METRICS} for name in names} or None
    return dict(qualified=not reasons, reasons=reasons, attempts=attempts,
                admitted_only=aggregate([r for r in attempts if r['admitted']]),
                failure_inclusive=aggregate(attempts))


def equivalence(obj):
    return {k: obj[k] for k in ('build_mode', 'environment', 'workload', 'features', 'visible')}


def baseline(obj, digest, reduced):
    return dict(schema='soundq.flutter.renderer-baseline.v1',
                status='qualified' if reduced['qualified'] else 'unqualified',
                cohort_sha256=digest, source=obj['source'],
                source_manifest_sha256=obj['source_manifest_sha256'],
                artifact_manifest_sha256=obj['artifact_manifest_sha256'],
                equivalence=equivalence(obj), **reduced,
                units='microseconds', clock='flutter-frame-timing', estimator='nearest-rank',
                enforced_phase=PHASE, enforced_estimates=list(ESTIMATES),
                minimum_tail_frames=MIN_TAIL_FRAMES,
                limits=[*LIMITS, 'process-percentiles-not-pooled-frames',
                        'small-process-population-tail-estimates-limited',
                        'idle-population-diagnostic-only', 'no-calibration-implied-by-schema'])


def reviewed_policy(obj, base_sha, cohort_sha):
    keys(obj, ['schema', 'baseline_sha256', 'reviewer', 'calibration', 'budgets'])
    require(obj['schema'] == 'soundq.flutter.renderer-policy.v1', 'unknown-policy-version')
    sha(obj['baseline_sha256']);token(obj['reviewer'])
    require(obj['baseline_sha256'] == base_sha, 'policy-baseline-mismatch')
    keys(obj['calibration'], ['cohort_sha256', 'rationale'])
    sha(obj['calibration']['cohort_sha256']);token(obj['calibration']['rationale'])
    require(obj['calibration']['cohort_sha256'] == cohort_sha, 'calibration-mismatch')
    keys(obj['budgets'], [PHASE])
    keys(obj['budgets'][PHASE], METRICS)
    for estimates in obj['budgets'][PHASE].values():
        keys(estimates, ESTIMATES)
        for budget in estimates.values():
            keys(budget, ['relative_allowance', 'absolute_allowance'])
            for value in budget.values():number(value)
    return obj


def compare(base, base_sha, candidate, reduced, review):
    require(base['qualified'], 'unqualified-baseline')
    mismatch = base['equivalence'] != equivalence(candidate)
    reasons = list(reduced['reasons'])
    if evidence_overlap(base, reduced):
        reasons.append('baseline-candidate-evidence-replay')
    if mismatch:reasons.append('environment-workload-feature-mismatch')
    breaches = []
    # Do not compute a budget verdict across incompatible workloads.
    if not mismatch:
        for row in reduced['attempts']:
            if row['metrics'] is None or PHASE not in row['metrics']:continue
            for metric in METRICS:
                for estimate in ESTIMATES:
                    budget = review['budgets'][PHASE][metric][estimate]
                    threshold = base['admitted_only'][PHASE][metric][estimate]['max'] * (1 + budget['relative_allowance']) + budget['absolute_allowance']
                    require(math.isfinite(threshold) and threshold <= 2**53-1, 'invalid-budget-limit')
                    value = row['metrics'][PHASE][metric][estimate]
                    if value > threshold:
                        breaches.append(dict(input_index=row['input_index'],phase=PHASE,metric=metric,
                                             estimate=estimate,observed=value,limit=threshold))
    if breaches:reasons.append('budget-breached')
    return dict(schema='soundq.flutter.renderer-comparison.v1',
                status='inconclusive' if mismatch else 'failed' if reasons else 'passed',
                baseline_sha256=base_sha, candidate_source=candidate['source'],
                candidate=reduced, reasons=reasons, breaches=breaches,
                comparison=None, full_app_accepted=False)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('baseline', 'compare'):
        cmd = sub.add_parser(name)
        cmd.add_argument('--cohort', type=Path, required=True)
        cmd.add_argument('--evidence', type=Path, required=True)
        if name == 'compare':
            cmd.add_argument('--baseline-cohort', type=Path, required=True)
            cmd.add_argument('--policy', type=Path, required=True)
    args = parser.parse_args(argv)
    out = args.evidence
    try:
        require(not any(p.is_symlink() for p in (out, *out.parents)), 'symlink-output')
        out.mkdir(mode=0o700)
    except (OSError, Invalid):return 2
    stores = []
    failure = lambda code: dict(schema='soundq.flutter.renderer-gate-failure.v1',status='failed',reasons=[code])
    try:
        store = RendererInputs(args.cohort.resolve().parent);stores.append(store)
        obj, digest = load(args.cohort, store)
        reduced = reduce_cohort(obj, store)
        if args.command == 'baseline':
            report = baseline(obj, digest, reduced)
            report['baseline_sha256'] = canonical_hash(report)
        else:
            old = RendererInputs(args.baseline_cohort.resolve().parent);stores.append(old)
            prior, prior_sha = load(args.baseline_cohort, old)
            base = baseline(prior, prior_sha, reduce_cohort(prior, old));base_sha = canonical_hash(base)
            policies = RendererInputs(args.policy.resolve().parent);stores.append(policies)
            policy, _ = load(args.policy, policies)
            review = reviewed_policy(policy, base_sha, prior_sha)
            report = compare(base, base_sha, obj, reduced, review)
    except (Invalid, OSError, UnicodeError, ValueError, TypeError, KeyError, OverflowError, RecursionError) as exc:
        report = failure(str(exc) if isinstance(exc, Invalid) else 'invalid-input-evidence')
    try:
        for index, store in enumerate(stores):
            directory = out/f'bundle-{index}';directory.mkdir(mode=0o700);store.retain(directory)
    except (OSError, Invalid):report = failure('input-retention-failed')
    try:
        raw = json.dumps(report, indent=2, allow_nan=False)+'\n'
        temporary = out/'report.new';temporary.write_text(raw);os.replace(temporary,out/'report.json')
    except (OSError, ValueError, TypeError):
        print('report-write-failed', file=sys.stderr);return 1
    print(report['status'])
    return 0 if report['status'] in ('qualified', 'passed') else 1


if __name__ == '__main__':raise SystemExit(main())
