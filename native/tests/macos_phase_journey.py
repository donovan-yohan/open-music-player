#!/usr/bin/env python3
"""Explicit-artifact macOS diagnostic launcher. Never builds/installs/resets.

Manifest v1: schema, source_commit, source_tree, build_mode, executable,
files [{path, sha256, role}]. files inventories EVERY regular bundle file after
packaging/signing. Roles: executable/core/resource/metadata. No symlinks.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
from typing import Any

MAX_JSON = 65_536
PHASES = ['populated-idle', 'audio-active-idle', 'audio-active-scripted-row-jumps']


class Refusal(Exception):
    pass


def require(value, code):
    if not value:
        raise Refusal(code)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def load_json(path) -> Any:
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= MAX_JSON, 'invalid-json')
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'invalid-json')
            result[key] = value
        return result
    def constant(_):
        raise Refusal('invalid-json')
    return json.loads(path.read_bytes(), object_pairs_hook=pairs, parse_constant=constant)


def canonical(path):
    require(path.is_absolute() and str(path) == str(path.resolve()), 'invalid-path')
    return path


def artifact(app, manifest_path):
    try:
        canonical(app); canonical(manifest_path)
        require(app.is_dir() and app.suffix == '.app', 'invalid-artifact')
        obj = load_json(manifest_path)
        require(type(obj) is dict and set(obj) == {'schema', 'source_commit', 'source_tree', 'build_mode', 'executable', 'files'}, 'invalid-artifact')
        require(obj['schema'] == 'soundq.macos.artifact.v1', 'invalid-artifact')
        for key in ('source_commit', 'source_tree'):
            require(type(obj[key]) is str and re.fullmatch('[a-f0-9]{40}', obj[key]), 'invalid-artifact')
        require(obj['build_mode'] in ('debug', 'release'), 'invalid-artifact')
        require(type(obj['files']) is list and 4 <= len(obj['files']) <= 2048, 'invalid-artifact')
        entries = {}
        roles = set()
        for item in obj['files']:
            require(type(item) is dict and set(item) == {'path', 'sha256', 'role'}, 'invalid-artifact')
            rel = item['path']
            require(type(rel) is str and len(rel) <= 512 and rel == str(PurePosixPath(rel)) and not rel.startswith('/') and '\\' not in rel and all(p not in ('.', '..') for p in rel.split('/')), 'invalid-artifact')
            require(type(item['sha256']) is str and re.fullmatch('[a-f0-9]{64}', item['sha256']), 'invalid-artifact')
            role = item['role']
            require(role in ('executable', 'core', 'resource', 'metadata') and rel not in entries, 'invalid-artifact')
            if role == 'executable':
                require(rel == obj['executable'] and rel.startswith('Contents/MacOS/'), 'invalid-artifact')
            if role == 'core':
                require(rel == 'Contents/Frameworks/libsoundq_core.dylib', 'invalid-artifact')
            if role == 'resource':
                require(rel.startswith('Contents/Resources/'), 'invalid-artifact')
            if role == 'metadata':
                require(rel == 'Contents/Info.plist' or rel.startswith('Contents/_CodeSignature/'), 'invalid-artifact')
            canonical(app/rel)
            require((app/rel).is_file() and digest(app/rel) == item['sha256'], 'invalid-artifact')
            entries[rel] = item['sha256']; roles.add(role)
        require(roles == {'executable', 'core', 'resource', 'metadata'}, 'invalid-artifact')
        require(sum(i['role'] == 'executable' for i in obj['files']) == 1 and sum(i['role'] == 'core' for i in obj['files']) == 1, 'invalid-artifact')
        actual = set()
        for root, dirs, files in os.walk(app, followlinks=False):
            for name in dirs + files:
                path = Path(root)/name
                require(not path.is_symlink(), 'invalid-artifact')
            for name in files:
                path = Path(root)/name
                require(stat.S_ISREG(path.stat().st_mode), 'invalid-artifact')
                actual.add(path.relative_to(app).as_posix())
        require(actual == set(entries), 'invalid-artifact')
        require(obj['executable'] in entries and os.access(app/obj['executable'], os.X_OK), 'invalid-artifact')
        return obj, digest(manifest_path)
    except (OSError, ValueError, KeyError, TypeError, Refusal):
        raise Refusal('invalid-artifact') from None


def validate_child(obj, pid, run_id, manifest, manifest_sha):
    require(type(obj) is dict and set(obj) == {'schema', 'run_id', 'pid', 'source_commit', 'source_tree', 'manifest_sha256', 'status', 'journey_passed', 'failure_codes', 'pending_phase', 'phases'}, 'invalid-child-report')
    require(obj['schema'] == 'soundq.macos.phase-diagnostic.v1' and type(obj['pid']) is int and obj['pid'] == pid and obj['run_id'] == run_id, 'child-identity-mismatch')
    require(obj['source_commit'] == manifest['source_commit'] and obj['source_tree'] == manifest['source_tree'] and obj['manifest_sha256'] == manifest_sha, 'child-identity-mismatch')
    require(obj['status'] in ('running', 'passed', 'failed'), 'invalid-child-report')
    require(type(obj['phases']) is list and len(obj['phases']) <= 3, 'invalid-child-report')
    # Accept only the recorder's small typed projection. No raw strings, paths,
    # credentials or account IDs from a corrupt/malicious child enter the receipt.
    codes = {'clock-read-failed','cpu-read-failed','rss-read-failed','report-write-failed','missing-phases','journey-failed','phase-interrupted','phase-rejected','phase-order-invalid','action-failed','unsettled-library','nonfinite-scroll','playback-failed','audio-not-ready','nonfinite-cursor','idle-has-decoder','playback-identity-changed','queue-changed','invalid-clock-delta','invalid-cpu-delta','invalid-rss-delta','cursor-progress-rejected','zero-scroll-displacement','termination'}
    def failures(value):
        require(type(value) is list and len(value) <= 24 and all(type(c) is str and c in codes for c in value), 'invalid-child-report')
    def number(value, integer=False, signed=False, maximum=None, minimum=None):
        if maximum is None:
            maximum = (2**63-1 if signed else 2**64-1) if integer else 1e18
        if minimum is None:
            minimum = (-2**63 if integer else -maximum) if signed else 0
        require(value is None or (type(value) is (int if integer else float) or (not integer and type(value) is int)) and (not isinstance(value, float) or math.isfinite(value)) and minimum <= value <= maximum, 'invalid-child-report')
    def boundary(value):
        require(type(value) is dict and set(value) == {'process','player_witness','item_witness','account_scope','epoch','session','occurrence','rows','settled','ready','failed','position_seconds','rate','scroll_y'}, 'invalid-child-report')
        p = value['process']
        require(type(p) is dict and set(p) == {'monotonic_ns','user_us','system_us','rss_bytes','failure_codes'}, 'invalid-child-report')
        for key in ('monotonic_ns','user_us','system_us','rss_bytes'):
            number(p[key], True)
        failures(p['failure_codes'])
        for key in ('account_scope','epoch','session','occurrence'):
            number(value[key], True)  # PlaybackStamp UInt64 identities; zero is legal.
        for key in ('player_witness','item_witness'):
            number(value[key], True, maximum=2**63-1, minimum=1)  # index+1, Swift Int
        number(value['rows'], True, True)  # Swift Int, not UInt64
        for key in ('settled','ready','failed'):
            require(type(value[key]) is bool, 'invalid-child-report')
        for key in ('position_seconds','rate','scroll_y'):
            number(value[key], signed=True)
    failures(obj['failure_codes'])
    require(obj['pending_phase'] is None or obj['pending_phase'] in PHASES, 'invalid-child-report')
    require(obj['journey_passed'] is None or type(obj['journey_passed']) is bool, 'invalid-child-report')
    names = []
    # All phases belong to this PID's one clock and cumulative CPU counters.
    # Keep the last available prior endpoint across unavailable failure fields;
    # an incomplete phase's start is still a known lower bound for a later start.
    previous = {}
    for phase in obj['phases']:
        require(type(phase) is dict and set(phase) == {'name','status','start','end','elapsed_ns','cpu_percent','rss_delta_bytes','cursor_delta_seconds','scroll_displacement','failure_codes'}, 'invalid-child-report')
        require(phase['name'] in PHASES and phase['name'] not in names and phase['status'] in ('passed','failed'), 'invalid-child-report')
        names.append(phase['name']); boundary(phase['start'])
        if phase['end'] is not None:
            boundary(phase['end'])
        for key in ('monotonic_ns','user_us','system_us'):
            known = [point['process'][key] for point in (phase['start'],phase['end']) if point is not None and point['process'][key] is not None]
            # Even when a failed phase lacks its start read, its known end
            # cannot precede an earlier phase. Internal failed deltas remain
            # diagnostic evidence, not successful arithmetic.
            require(key not in previous or all(value >= previous[key] for value in known), 'invalid-child-report')
            if known:
                previous[key] = max(known + ([previous[key]] if key in previous else []))
        failures(phase['failure_codes'])
        number(phase['elapsed_ns'], True); number(phase['rss_delta_bytes'], True, True)
        for key in ('cpu_percent','cursor_delta_seconds','scroll_displacement'):
            number(phase[key], signed=key != 'cpu_percent')
        if phase['status'] == 'passed':
            require(not phase['failure_codes'] and phase['end'] is not None and phase['elapsed_ns'] is not None and phase['elapsed_ns'] > 0 and phase['cpu_percent'] is not None and phase['rss_delta_bytes'] is not None, 'invalid-child-report')
            a, b = phase['start'], phase['end']
            ap, bp = a['process'], b['process']
            require(not ap['failure_codes'] and not bp['failure_codes'], 'invalid-child-report')
            require(all(ap[k] is not None and bp[k] is not None for k in ('monotonic_ns','user_us','system_us','rss_bytes')), 'invalid-child-report')
            # ProcessStamp RSS is UInt64, but the successful Int64 subtraction
            # is defined only when BOTH endpoints fit Int64 (recorder end()).
            require(ap['rss_bytes'] <= 2**63-1 and bp['rss_bytes'] <= 2**63-1, 'invalid-child-report')
            require(all(x[k] is not None for x in (a,b) for k in ('account_scope','epoch','session','rows')), 'invalid-child-report')
            require(bp['monotonic_ns'] > ap['monotonic_ns'] and phase['elapsed_ns'] == bp['monotonic_ns']-ap['monotonic_ns'], 'invalid-child-report')
            require(bp['user_us'] >= ap['user_us'] and bp['system_us'] >= ap['system_us'], 'invalid-child-report')
            cpu = ((bp['user_us']-ap['user_us'])+(bp['system_us']-ap['system_us']))*100_000/phase['elapsed_ns']
            require(math.isclose(cpu, phase['cpu_percent'], rel_tol=1e-12, abs_tol=1e-9) and phase['rss_delta_bytes'] == bp['rss_bytes']-ap['rss_bytes'], 'invalid-child-report')
            require(all(a[k] == b[k] for k in ('account_scope','epoch','session','occurrence','player_witness','item_witness')), 'invalid-child-report')
            require(all(x['rows'] == 500 and x['settled'] and not x['failed'] for x in (a,b)), 'invalid-child-report')
            require(all(x['scroll_y'] is not None for x in (a,b)) and phase['scroll_displacement'] == b['scroll_y']-a['scroll_y'], 'invalid-child-report')
            if phase['name'] != 'populated-idle':
                require(all(x['ready'] and x['rate'] is not None and x['rate'] > 0 and x['player_witness'] is not None and x['item_witness'] is not None and x['occurrence'] is not None and x['position_seconds'] is not None for x in (a,b)), 'invalid-child-report')
                progress = b['position_seconds']-a['position_seconds']
                expected = phase['elapsed_ns']/1e9*a['rate']
                require(a['rate'] == b['rate'] and progress > .001 and abs(progress-expected) <= max(.1,expected*.1) and phase['cursor_delta_seconds'] == progress, 'invalid-child-report')
            else:
                require(all(x['player_witness'] is None and x['item_witness'] is None for x in (a,b)), 'invalid-child-report')
            if phase['name'] == 'audio-active-scripted-row-jumps':
                require(phase['scroll_displacement'] > 0, 'invalid-child-report')
    if obj['status'] == 'passed':
        require(names == PHASES and obj['journey_passed'] is True and not obj['failure_codes'] and obj['pending_phase'] is None and all(p['status'] == 'passed' for p in obj['phases']), 'invalid-child-report')
    return obj


def run(args):
    # Output refusal never overwrites an earlier attempt.
    try:
        canonical(args.evidence)
        args.evidence.mkdir(mode=0o700)
    except (OSError, Refusal):
        return 2
    receipt = {'schema':'soundq.macos.phase-launch.v1', 'run_id':None, 'status':'failed', 'failure_codes':[], 'pid':None, 'exit_code':None, 'cleanup':'not-started', 'artifact_before':False, 'artifact_after':False, 'child_report':None}
    child = None
    manifest = None
    manifest_sha = None
    failures = receipt['failure_codes']
    child_report_path = args.evidence/'child-report.json'
    try:
        require(type(args.run_id) is str and re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.:-]{0,79}', args.run_id), 'invalid-run-id')
        receipt['run_id'] = args.run_id
        require(math.isfinite(args.timeout_seconds) and 0.05 <= args.timeout_seconds <= 300, 'invalid-timeout')
        manifest, manifest_sha = artifact(args.app, args.artifact_manifest)
        receipt.update(artifact_before=True, manifest_sha256=manifest_sha, source_commit=manifest['source_commit'], source_tree=manifest['source_tree'], build_mode=manifest['build_mode'])
        canonical(args.fixture_home)
        private = load_json(args.fixture_home/'credentials.json')
        require(type(private) is dict and all(type(private.get(k)) is str and 0 < len(private[k].encode()) <= limit for k,limit in [('email',320),('password',4096)]), 'invalid-credentials')
        require(args.fixture_home != args.evidence and not args.evidence.is_relative_to(args.app) and not args.evidence.is_relative_to(args.fixture_home), 'invalid-output')
        # Minimal environment; no inherited auth, DYLD injection, personal settings
        # or legacy journey output. TMPDIR/HOME/cache are owned output only.
        for directory in ('home','tmp','cache'):
            (args.evidence/directory).mkdir(mode=0o700)
        env = {'PATH':'/usr/bin:/bin', 'HOME':str(args.evidence/'home'), 'CFFIXED_USER_HOME':str(args.evidence/'home'), 'TMPDIR':str(args.evidence/'tmp'),
               'OMP_API_BASE_URL':'http://127.0.0.1:54761/api/v1', 'SOUNDQ_NATIVE_FIXTURE_HOME':str(args.fixture_home), 'SOUNDQ_NATIVE_CACHE_ROOT':str(args.evidence/'cache'),
               'SOUNDQ_PHASE_RUN_ID':args.run_id, 'SOUNDQ_PHASE_SOURCE_COMMIT':manifest['source_commit'], 'SOUNDQ_PHASE_SOURCE_TREE':manifest['source_tree'],
               'SOUNDQ_PHASE_MANIFEST_SHA256':manifest_sha, 'SOUNDQ_PHASE_REPORT':str(child_report_path)}
        child = subprocess.Popen([str(args.app/manifest['executable']), '--fixture-journey', '--measure-phases'], cwd=args.evidence, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        receipt.update(pid=child.pid, cleanup='pending')
        try:
            receipt['exit_code'] = child.wait(timeout=args.timeout_seconds)
        except subprocess.TimeoutExpired:
            failures.append('child-timeout')
    except Refusal as exc:
        failures.append(str(exc))
    except (OSError, ValueError, TypeError, RecursionError):
        failures.append('setup-failed' if child is None else 'launcher-failed')
    except KeyboardInterrupt:
        failures.append('launcher-interrupted')
    finally:
        if child is not None:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill(); child.wait(timeout=2)
            receipt['exit_code'] = child.returncode
            receipt['cleanup'] = 'reaped'
            try:
                require(child_report_path.exists(), 'missing-child-report')
                receipt['child_report'] = validate_child(load_json(child_report_path), child.pid, args.run_id, manifest, manifest_sha)
                if receipt['child_report']['status'] != 'passed':
                    failures.append('child-report-failed')
                if (child.returncode == 0) != (receipt['child_report']['status'] == 'passed'):
                    failures.append('child-exit-disagreement')
            except (Refusal, OSError, ValueError, TypeError, KeyError, RecursionError) as exc:
                failures.append(str(exc) if isinstance(exc, Refusal) else 'invalid-child-report')
            if child.returncode != 0:
                failures.append('child-exit-failed')
        if manifest is not None:
            try:
                final, final_sha = artifact(args.app, args.artifact_manifest)
                require(final == manifest and final_sha == manifest_sha, 'artifact-changed')
                receipt['artifact_after'] = True
            except (Refusal, OSError):
                failures.append('artifact-changed')
        # Child raw report is intentionally not retained: even malformed child
        # output cannot export arbitrary strings. Only validated projection stays.
        try:
            if child_report_path.is_file() or child_report_path.is_symlink():
                child_report_path.unlink()
            receipt['status'] = 'passed' if not failures else 'failed'
            (args.evidence/'report.json').write_text(json.dumps(receipt, sort_keys=True, allow_nan=False)+'\n')
        except (OSError, ValueError, TypeError):
            receipt['status'] = 'failed'
    return 0 if receipt['status'] == 'passed' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--artifact-manifest', required=True, type=Path)
    parser.add_argument('--fixture-home', required=True, type=Path)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--evidence', required=True, type=Path)
    parser.add_argument('--timeout-seconds', type=float, default=90)
    return run(parser.parse_args())


if __name__ == '__main__':
    raise SystemExit(main())
