#!/usr/bin/env python3
"""Offline, fail-closed resource budgets for source-bound native phase runs.

No collector, physical-frame claim, automatic baseline update, or default budget.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import sys

from matched_performance import Inputs, Invalid, keys, manifests, number, require, sha, strict_json, token
from macos_phase_journey import PHASES, Refusal, validate_child

METRICS = ('cpu_percent', 'rss_end_bytes', 'rss_growth_bytes')
MAX_INPUT = 4_194_304


class BoundedInputs(Inputs):
    def read(self, ref):
        keys(ref, ['path', 'sha256'])
        sha(ref['sha256'])
        name = ref['path']
        require(type(name) is str and len(name) <= 4096
                and re.fullmatch(r'[A-Za-z0-9_./-]+', name), 'invalid-path')
        require(not Path(name).is_absolute()
                and all(part not in ('', '.', '..') for part in name.split('/')), 'path-escape')
        candidate = self.root / name
        data = bounded_read(candidate)
        require(hashlib.sha256(data).hexdigest() == ref['sha256'], 'hash-mismatch')
        require(candidate not in self.files or self.files[candidate] == data, 'input-changed')
        self.files[candidate] = data
        return data

    def verify(self):
        for path, original in self.files.items():
            require(bounded_read(path) == original, 'input-changed')


def bounded_read(path):
    path = path.absolute()
    # Open each directory relative to the previous descriptor. No check/open
    # symlink race or FIFO blocking at this untrusted evidence boundary.
    parent = os.open(path.anchor, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent); parent = child
        require(not path.is_symlink(), 'symlink-input')
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        with os.fdopen(descriptor, 'rb') as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode), 'regular-file-required')
            require(info.st_size <= MAX_INPUT, 'input-too-large')
            data = stream.read(MAX_INPUT + 1)
    finally:
        os.close(parent)
    require(len(data) <= MAX_INPUT, 'input-too-large')
    return data


def stats(values):
    ordered = sorted(values)
    require(bool(ordered), 'empty-population')
    return dict(sample_count=len(ordered), min=ordered[0], max=ordered[-1],
                spread=ordered[-1] - ordered[0],
                **{name: ordered[math.ceil(len(ordered) * q) - 1]
                   for name, q in [('p50', .5), ('p95', .95), ('p99', .99)]})


def load(path, inputs):
    data = bounded_read(path)
    inputs.files[path.resolve()] = data
    value = strict_json(data)
    return value, hashlib.sha256(data).hexdigest()


def read_cohort(obj, inputs):
    keys(obj, ['schema', 'run_id', 'source', 'manifest_sha256', 'build_mode',
               'environment', 'workload', 'features', 'visible', 'attempts'])
    require(obj['schema'] == 'soundq.phase-cohort.v1', 'unknown-cohort-version')
    token(obj['run_id'])
    keys(obj['source'], ['commit', 'tree'])
    for value in obj['source'].values():
        sha(value, 40)
    sha(obj['manifest_sha256'])
    require(obj['build_mode'] == 'release', 'production-build-required')
    manifests(obj)
    require(obj['environment']['platform'] == 'macos', 'unsupported-platform')
    require(type(obj['attempts']) is list and 0 < len(obj['attempts']) <= 200,
            'invalid-attempts')
    reasons, results, seen = [], [], set()
    for index, attempt in enumerate(obj['attempts']):
        result = {'input_index': index, 'admitted': False, 'reasons': [], 'metrics': None}
        try:
            keys(attempt, ['report', 'process_start'])
            token(attempt['process_start'])
            report = strict_json(inputs.read(attempt['report']))
            keys(report, ['schema', 'run_id', 'status', 'failure_codes', 'pid', 'exit_code',
                          'cleanup', 'artifact_before', 'artifact_after', 'child_report',
                          'manifest_sha256', 'source_commit', 'source_tree', 'build_mode'])
            require(report['schema'] == 'soundq.macos.phase-launch.v1', 'unknown-launch-version')
            token(report['run_id'])
            require(type(report['pid']) is int and 0 < report['pid'] < 2**31, 'invalid-pid')
            # Both launch ID and PID must be new. Supplied process-start labels
            # supplement the owned launch receipt; they do not authenticate it.
            identities = [('run', report['run_id']), ('pid', report['pid']),
                          ('start', attempt['process_start']), ('raw', attempt['report']['sha256'])]
            require(not any(identity in seen for identity in identities), 'reused-process-population')
            seen.update(identities)  # failed attempts reserve identities too
            require(report['source_commit'] == obj['source']['commit']
                    and report['source_tree'] == obj['source']['tree']
                    and report['manifest_sha256'] == obj['manifest_sha256']
                    and report['build_mode'] == obj['build_mode'], 'source-artifact-mismatch')
            manifest = dict(source_commit=obj['source']['commit'], source_tree=obj['source']['tree'])
            try:
                child = validate_child(report['child_report'], report['pid'], report['run_id'],
                                       manifest, obj['manifest_sha256'])
            except (Refusal, ValueError, TypeError, KeyError, OverflowError):
                raise Invalid('invalid-phase-evidence') from None
            result['metrics'] = {phase['name']: {
                'cpu_percent': phase['cpu_percent'],
                'rss_end_bytes': phase['end']['process']['rss_bytes'],
                'rss_growth_bytes': max(0, phase['rss_delta_bytes']),
            } for phase in child['phases'] if phase['status'] == 'passed'}
            require(child['status'] == 'passed', 'functional-audio-invariant-failed')
            require(report['status'] == 'passed' and report['failure_codes'] == []
                    and type(report['exit_code']) is int and report['exit_code'] == 0
                    and report['cleanup'] == 'reaped' and report['artifact_before'] is True
                    and report['artifact_after'] is True, 'launch-or-cleanup-failed')
            result['admitted'] = True
        except (Invalid, OSError, UnicodeError, RecursionError) as exc:
            result['reasons'].append(str(exc) if isinstance(exc, Invalid) else 'input-read-failed')
        results.append(result)
    if any(not result['admitted'] for result in results):
        reasons.append('failed-attempts-retained')
    if len(results) < 5:
        reasons.append('requires-five-independent-processes')
    env = obj['environment']
    if not env['quiet']:
        reasons.append('shared-host-not-qualified')
    if any(value is None or value == 'unavailable' for value in env.values()):
        reasons.append('environment-unavailable')
    if obj['features']['missing'] or not set(obj['features']['required']) <= set(obj['features']['exercised']):
        reasons.append('features-not-exercised')
    def aggregate(selected):
        return {phase: {metric: stats([r['metrics'][phase][metric] for r in selected
                                      if phase in r['metrics']])
                        for metric in METRICS}
                for phase in PHASES if any(phase in r['metrics'] for r in selected)} if selected else None
    known = [r for r in results if r['metrics'] is not None]
    return dict(qualified=not reasons, reasons=reasons, attempts=results,
                admitted_only=aggregate([r for r in known if r['admitted']]),
                failure_inclusive=aggregate(known))


def equivalence(obj):
    return {key: obj[key] for key in ('build_mode', 'environment', 'workload', 'features', 'visible')}


def baseline(obj, digest, reduced):
    return dict(schema='soundq.phase-baseline.v1', status='qualified' if reduced['qualified'] else 'unqualified',
                cohort_sha256=digest, source=obj['source'], manifest_sha256=obj['manifest_sha256'],
                equivalence=equivalence(obj), **reduced,
                estimator='nearest-rank', units={'cpu_percent': 'percent-one-core',
                'rss_end_bytes': 'bytes', 'rss_growth_bytes': 'bytes-positive-boundary-growth'},
                limits=['boundary-rss-not-peak-or-sustained-trend', 'endpoint-player-not-acoustic-output',
                        'supplied-provenance-not-compilation-proof', 'no-frame-or-speedup-claim'])


def policy(obj, baseline_sha):
    keys(obj, ['schema', 'baseline_sha256', 'reviewer', 'calibration', 'budgets'])
    require(obj['schema'] == 'soundq.phase-policy.v1', 'unknown-policy-version')
    sha(obj['baseline_sha256'])
    require(obj['baseline_sha256'] == baseline_sha, 'policy-baseline-mismatch')
    token(obj['reviewer'])
    keys(obj['calibration'], ['cohort_sha256', 'rationale'])
    sha(obj['calibration']['cohort_sha256'])
    token(obj['calibration']['rationale'])
    keys(obj['budgets'], PHASES)
    for metrics in obj['budgets'].values():
        keys(metrics, METRICS)
        for budget in metrics.values():
            keys(budget, ['relative_allowance', 'absolute_allowance'])
            for value in budget.values():
                number(value)
    return obj


def compare(base, base_sha, candidate, reduced, review):
    # Baseline reports are not trusted summaries. Reproduce them from retained
    # cohort inputs via the caller below before this boundary.
    require(base['qualified'], 'unqualified-baseline')
    require(review['calibration']['cohort_sha256'] == base['cohort_sha256'], 'calibration-mismatch')
    reasons = list(reduced['reasons'])
    if base['equivalence'] != equivalence(candidate):
        reasons.append('environment-workload-feature-mismatch')
    breaches = []
    for result in reduced['attempts']:
        if result['metrics'] is None:
            continue
        for phase, metrics in result['metrics'].items():
            for metric, value in metrics.items():
                budget = review['budgets'][phase][metric]
                limit = base['admitted_only'][phase][metric]['max'] * (1 + budget['relative_allowance']) + budget['absolute_allowance']
                require(math.isfinite(limit) and limit <= 2**53 - 1, 'invalid-budget-limit')
                if value > limit:
                    breaches.append(dict(input_index=result['input_index'], phase=phase,
                                         metric=metric, observed=value, limit=limit))
    if breaches:
        reasons.append('budget-breached')
    return dict(schema='soundq.phase-comparison.v1', status='failed' if reasons else 'passed',
                baseline_sha256=base_sha, candidate_source=candidate['source'],
                reasons=reasons, breaches=breaches, candidate=reduced,
                comparison=None, full_app_accepted=False)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest='command', required=True)
    for command in ('baseline', 'compare'):
        sub = subs.add_parser(command)
        sub.add_argument('--cohort', type=Path, required=True)
        sub.add_argument('--evidence', type=Path, required=True)
        if command == 'compare':
            sub.add_argument('--baseline-cohort', type=Path, required=True)
            sub.add_argument('--policy', type=Path, required=True)
    args = parser.parse_args(argv)
    out = args.evidence
    try:
        require(not any(p.is_symlink() for p in (out, *out.parents)), 'symlink-output')
        out.mkdir(mode=0o700)
    except (OSError, Invalid):
        print('evidence-directory-must-be-new', file=sys.stderr)
        return 2
    stores = []
    report = {'schema': 'soundq.phase-gate-failure.v1', 'status': 'failed', 'reasons': []}
    try:
        store = BoundedInputs(args.cohort.resolve().parent); stores.append(store)
        obj, digest = load(args.cohort, store)
        reduced = read_cohort(obj, store)
        if args.command == 'baseline':
            report = baseline(obj, digest, reduced)
        else:
            old = BoundedInputs(args.baseline_cohort.resolve().parent); stores.append(old)
            old_obj, old_digest = load(args.baseline_cohort, old)
            base = baseline(old_obj, old_digest, read_cohort(old_obj, old))
            # Policy pins the reproducible canonical baseline, not a mutable report file.
            base_sha = hashlib.sha256(json.dumps(base, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()
            policies = BoundedInputs(args.policy.resolve().parent); stores.append(policies)
            review, _ = load(args.policy, policies)
            report = compare(base, base_sha, obj, reduced, policy(review, base_sha))
        if args.command == 'baseline':
            report['baseline_sha256'] = hashlib.sha256(json.dumps(report, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()
    except (Invalid, OSError, UnicodeError, RecursionError) as exc:
        report = dict(schema='soundq.phase-gate-failure.v1', status='failed',
                      reasons=[str(exc) if isinstance(exc, Invalid) else 'input-read-failed'])
    try:
        for index, store in enumerate(stores):
            directory = out / ('bundle-' + str(index)); directory.mkdir()
            store.retain(directory)
    except (OSError, Invalid):
        report = dict(schema='soundq.phase-gate-failure.v1', status='failed', reasons=['input-retention-failed'])
    try:
        (out / 'report.json').write_text(json.dumps(report, indent=2, allow_nan=False) + '\n')
    except (OSError, ValueError):
        print('report-persistence-failed', file=sys.stderr)
        return 1
    print(report['status'])
    return 0 if report['status'] in ('passed', 'qualified') else 1


if __name__ == '__main__':
    sys.exit(main())
