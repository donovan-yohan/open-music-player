#!/usr/bin/env python3
"""Finite POSIX lifecycle controls; no Gradle, SDK, network or native oracle.

Real helpers model a launcher, setsid daemon and separately grouped worker.
Failure injection only selects the existing spawn/wait/receipt boundaries.
"""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

RUNNER = Path(__file__).with_name('android_presentation_regressions.py')
HELPER = r'''
import json, os, pathlib, signal, subprocess, sys, time
role, record, mode = sys.argv[1:]
path = pathlib.Path(record)
with path.open('a') as f:
    f.write(json.dumps({'role':role,'pid':os.getpid(),'pgid':os.getpgrp()})+'\n')
child = None
def stop(signum, frame):
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
try:
    if role != 'worker':
        child = subprocess.Popen([sys.executable, __file__, 'daemon' if role == 'launcher' else 'worker', record, mode], start_new_session=True)
    if role == 'launcher' and mode == 'finish':
        deadline = time.monotonic()+5
        while len(path.read_text().splitlines()) < 3 and time.monotonic() < deadline:
            time.sleep(.01)
        # Model a detached daemon surviving a normally completed launcher.
        child = None
    else:
        time.sleep(15)
finally:
    if child is not None:
        child.terminate()
        try:
            child.wait(timeout=2)
        except subprocess.TimeoutExpired:
            child.kill(); child.wait(timeout=2)
'''


def load_runner(path=RUNNER):
    spec = importlib.util.spec_from_file_location('presentation_lifecycle_target', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='presentation-lifetime-')
        self.addCleanup(self.tmp.cleanup)
        self.work = Path(self.tmp.name)
        self.root = self.work / 'source'
        (self.root / 'native/android').mkdir(parents=True)
        self.helper = self.work / 'helper.py'
        self.helper.write_text(HELPER)
        self.record = self.work / 'identities.jsonl'
        self.runner = load_runner()
        self.real_popen = subprocess.Popen
        self.processes = []
        self.addCleanup(self.rescue)

    def rows(self):
        return [json.loads(line) for line in self.record.read_text().splitlines()] if self.record.exists() else []

    def ready(self):
        deadline = time.monotonic() + 5
        while len(self.rows()) < 3 and time.monotonic() < deadline:
            time.sleep(.01)
        self.assertEqual(len(self.rows()), 3, 'real detached topology must be reached')

    def rescue(self):
        # Exact fixture PIDs only; reclaim predecessor leaks after observing RED.
        for row in reversed(self.rows()):
            if alive(row['pid']):
                try:
                    os.kill(row['pid'], signal.SIGTERM)
                except ProcessLookupError:
                    pass
        for proc in self.processes:
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait(timeout=3)
        deadline = time.monotonic() + 3
        while any(alive(r['pid']) for r in self.rows()) and time.monotonic() < deadline:
            time.sleep(.02)
        evidence = os.environ.get('SOUNDQ_LIFECYCLE_EVIDENCE_DIR')
        if evidence:
            destination = Path(evidence)
            destination.mkdir(parents=True, exist_ok=True)
            releases = [json.loads(p.read_text()) for p in (self.work / 'output').glob('*/release.json')]
            (destination / (self._testMethodName + '.json')).write_text(json.dumps({
                'helpers': self.rows(), 'runner_releases': releases,
                'remaining_after_fixture_rescue': [r for r in self.rows() if alive(r['pid'])]}, indent=2)+'\n')

    def invoke(self, event='timeout', mode='hold'):
        def spawn(argv, **kwargs):
            if argv[0] != 'lifecycle-gradle':
                return self.real_popen(argv, **kwargs)
            proc = self.real_popen([sys.executable, str(self.helper), 'launcher', str(self.record), mode], **kwargs)
            self.processes.append(proc)
            self.ready()
            wait = proc.wait
            def bounded_wait(timeout=None):
                if timeout == 300 or timeout is not None and timeout <= .25:
                    if event == 'interrupt':
                        signal.raise_signal(signal.SIGINT)
                    return wait(timeout=.2)
                return wait(timeout=timeout)
            proc.wait = bounded_wait
            return proc
        with patch.object(self.runner, 'WAIT_SECONDS', .2, create=True), patch.object(self.runner.shutil, 'which', return_value='lifecycle-gradle'), patch.object(self.runner.subprocess, 'Popen', side_effect=spawn):
            return self.runner.run(self.root, self.work / 'output')

    def assert_released(self):
        rows = self.rows()
        self.assertEqual(len(rows), 3)
        self.assertEqual(len({r['pgid'] for r in rows}), 3, 'daemon and worker really detach')
        self.assertEqual([r['role'] for r in rows if alive(r['pid'])], [], 'owned detached processes must be absent synchronously')

    def test_timeout_drains_detached_daemon_and_worker(self):
        receipt = self.invoke()
        self.assertFalse(receipt['passed'])
        self.assertIn('TimeoutExpired', receipt['error'])
        self.assert_released()

    def test_process_receipt_refusal_drains_every_owned_process(self):
        write = Path.write_text
        def refuse(path, *args, **kwargs):
            if path.name == 'process.json':
                raise OSError('process receipt refusal')
            return write(path, *args, **kwargs)
        with patch.object(Path, 'write_text', refuse):
            receipt = self.invoke()
        self.assertIn('OSError: process receipt refusal', receipt['error'])
        self.assert_released()

    def test_keyboard_interrupt_drains_before_propagation(self):
        with self.assertRaises(KeyboardInterrupt):
            self.invoke(event='interrupt')
        self.assert_released()

    def test_normal_launcher_finish_drains_detached_survivors(self):
        # XML is deliberately absent: this control qualifies release, not JUnit.
        receipt = self.invoke(mode='finish')
        self.assertIn('exact nonempty', receipt['error'])
        self.assert_released()

    def test_unrelated_child_survives_owned_cleanup(self):
        other = self.real_popen([sys.executable, '-c', 'import time;time.sleep(15)'], start_new_session=True)
        self.addCleanup(lambda: (other.terminate(), other.wait(timeout=3)) if other.poll() is None else None)
        self.invoke()
        self.assert_released()
        self.assertIsNone(other.poll())

    def test_unavailable_cleanup_never_claims_release(self):
        with patch.object(self.runner, 'owned_processes', side_effect=OSError('enumeration refused')):
            receipt = self.invoke(mode='finish')
        self.assertFalse(receipt['passed'])
        self.assertIn('enumeration refused', receipt['error'])
        release = json.loads((self.work / 'output/green/release.json').read_text())
        self.assertFalse(release['released'])
        self.assertIsNone(release['remaining'])

    def test_hidden_ownership_environment_never_claims_release(self):
        original_drain = self.runner.drain_owned
        real_run = subprocess.run
        observed = []

        def hide_owner(argv, **kwargs):
            result = real_run(argv, **kwargs)
            if argv[0] == 'ps' and 'axeww' in argv:
                result.stdout = '\n'.join(' '.join(
                    word for word in line.split()
                    if not word.startswith(self.runner.OWNER_ENV + '='))
                    for line in result.stdout.splitlines())
            return result

        def hidden_drain(proc, owner, state):
            observed.extend(state['identities'])
            with patch.object(self.runner.subprocess, 'run', side_effect=hide_owner):
                return original_drain(proc, owner, state)

        with patch.object(self.runner, 'drain_owned', side_effect=hidden_drain):
            receipt = self.invoke(mode='finish')
        release = json.loads((self.work / 'output/green/release.json').read_text())
        self.assertTrue(observed, 'ownership must be positively observed before visibility loss')
        self.assertFalse(receipt['passed'])
        self.assertFalse(release['released'], 'hidden environments cannot prove recorded child absence')
        self.assertIn('ownership visibility unavailable', receipt['error'])
        self.assertTrue(any(alive(row['pid']) for row in self.rows()),
            'fixture rescue, not unverified signalling, owns hidden children')

    def test_malformed_token_row_is_not_an_empty_inventory(self):
        owner = 'fixture-owner'
        result = subprocess.CompletedProcess([], 0,
            stdout='unparseable ' + self.runner.OWNER_ENV + '=' + owner + '\n', stderr='')
        with patch.object(self.runner.subprocess, 'run', return_value=result):
            with self.assertRaisesRegex(RuntimeError, 'Unusable process enumeration'):
                self.runner.owned_processes(owner)

    def test_successful_output_without_environments_is_unavailable(self):
        real_run = subprocess.run

        def strip_environments(argv, **kwargs):
            result = real_run(argv, **kwargs)
            if argv[0] == 'ps':
                result.stdout = '\n'.join(' '.join(
                    word for word in line.split() if not word.startswith(
                        ('SOUNDQ_PRESENTATION_ENUMERATION=', self.runner.OWNER_ENV + '=')))
                    for line in result.stdout.splitlines())
            return result

        with patch.object(self.runner.subprocess, 'run', side_effect=strip_environments):
            with self.assertRaisesRegex(RuntimeError, 'Process environment visibility unavailable'):
                self.runner.owned_processes('unowned-fixture')

    def test_genuinely_empty_owned_inventory_releases(self):
        with tempfile.TemporaryFile() as log:
            proc = self.real_popen([sys.executable, '-c', 'pass'], stdout=log)
            proc.wait(timeout=3)
            state = {'released': False, 'identities': [], 'remaining': None}
            self.runner.drain_owned(proc, 'completed-unowned-fixture', state)
        self.assertTrue(state['released'])
        self.assertEqual(state['remaining'], [])

    def test_primary_exception_survives_terminal_writer_refusal(self):
        write = Path.write_text
        def refuse(path, *args, **kwargs):
            if path.name == 'process.json':
                raise OSError('primary process receipt refusal')
            if path.name in {'release.json', 'results.json'}:
                raise RuntimeError('secondary writer refusal')
            return write(path, *args, **kwargs)
        with patch.object(Path, 'write_text', refuse):
            with self.assertRaisesRegex(OSError, 'primary process receipt refusal'):
                self.invoke()
        self.assert_released()


    def test_primary_exception_survives_cleanup_failure(self):
        with patch.object(self.runner, 'drain_owned', side_effect=RuntimeError('cleanup refusal')):
            receipt = self.invoke()
        self.assertIn('TimeoutExpired', receipt['error'])
        self.assertIn('cleanup refusal', ' '.join(receipt['secondary_errors']))
        release = json.loads((self.work / 'output/green/release.json').read_text())
        self.assertFalse(release['released'])


def run_controls(output):
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(LifecycleTests)
    with (output / 'lifecycle-tests.log').open('w') as stream:
        result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    return {'passed': result.wasSuccessful(), 'tests': result.testsRun,
        'failures': len(result.failures), 'errors': len(result.errors),
        'skips': len(result.skipped)}


if __name__ == '__main__':
    unittest.main(verbosity=2)
