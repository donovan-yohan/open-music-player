#!/usr/bin/env python3
"""Offline controls for the Compose-only staging contract."""
import hashlib
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

import compose_robolectric as compose


class StageTest(unittest.TestCase):
    def setUp(self):
        root = tempfile.TemporaryDirectory()
        self.addCleanup(root.cleanup)
        self.output = Path(root.name).resolve()
        self.good = b'trusted fixture'
        pins = [compose.Pin(f'org/robolectric/fixture/1/{n}', f'sdk/{n}', len(self.good),
                            hashlib.sha512(self.good).hexdigest()) for n in ('first.jar', 'last.jar')]
        self.pins = tuple(pins)
        pin_patch = patch.object(compose, 'PINS', self.pins)
        pin_patch.start()
        self.addCleanup(pin_patch.stop)
        self.requests = []

    def write(self, pin, output):
        self.requests.append(pin.path)
        output.write_bytes(self.good)

    def rejected(self, fetch, pattern):
        with self.assertRaisesRegex(compose.AdmissionError, pattern):
            compose.stage(self.output, fetch)
        self.assertEqual([], list(self.output.iterdir()))

    def test_positive_publishes_all_exact_read_only_files(self):
        staged = compose.stage(self.output, self.write)
        self.assertEqual([p.path for p in self.pins], self.requests)
        self.assertEqual([staged], list(self.output.iterdir()))
        for pin in self.pins:
            path = staged / pin.target
            self.assertEqual(self.good, path.read_bytes())
            self.assertEqual(0o400, path.stat().st_mode & 0o777)

    def test_last_digest_mismatch_does_not_publish_first(self):
        def corrupt(pin, output):
            self.write(pin, output)
            if pin is self.pins[-1]:
                output.write_bytes(b'X' + self.good[1:])
        self.rejected(corrupt, 'SHA-512 mismatch')
        self.assertEqual(2, len(self.requests))

    def test_missing_and_truncated_refuse(self):
        self.rejected(lambda *_: None, 'missing or unreadable')
        self.rejected(lambda _, out: out.write_bytes(self.good[:-1]), 'expected .* bytes')

    def test_cancellation_during_partial_stage_refuses_all(self):
        def cancel(pin, output):
            self.write(pin, output)
            if pin is self.pins[-1]:
                raise compose.Cancelled(15)
        with self.assertRaises(compose.Cancelled):
            compose.stage(self.output, cancel)
        self.assertEqual([], list(self.output.iterdir()))

    def test_duplicate_or_unsafe_output_never_fetches(self):
        for bad in (self.pins[:1] * 2, (self.pins[0]._replace(target='../unsafe'),)):
            with patch.object(compose, 'PINS', bad):
                self.rejected(self.write, 'duplicate|unsafe')
        (self.output / 'verified').mkdir()
        with self.assertRaisesRegex(compose.AdmissionError, 'fresh empty'):
            compose.stage(self.output, self.write)
        self.assertFalse(self.requests)

    def test_symlink_root_never_fetches(self):
        link = self.output / 'link'
        owned = self.output / 'owned'
        owned.mkdir()
        link.symlink_to(owned)
        with self.assertRaisesRegex(compose.AdmissionError, 'canonical'):
            compose.stage(link, self.write)
        self.assertFalse(self.requests)
        self.assertEqual([], list(owned.iterdir()))

    def test_signal_during_download_stops_child_without_publishing(self):
        self.check_step('transfer')

    def test_signal_after_verification_before_export_does_not_publish(self):
        self.check_step('verified')

    def test_success_leaves_stage_for_job_teardown(self):
        self.check_step('success')

    def check_step(self, case):
        report = self.output / 'transfer-ready'
        child_code = 'import os, pathlib, sys, time; pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); time.sleep(60)'
        parent_code = '''
import hashlib
import os
import signal
import sys
import compose_robolectric as stage

child, report, case = sys.argv[1:]
stage.PINS = tuple(stage.Pin(name, 'sdk/' + name, 7, hashlib.sha512(b'fixture').hexdigest())
                   for name in ('first.jar', 'last.jar'))

def download(children, pin, path):
    if case == 'transfer' and pin == stage.PINS[-1]:
        path.write_bytes(b'partial')
        children.run([sys.executable, '-c', child, report])
    path.write_bytes(b'fixture')

stage.download = download
if case == 'verified':
    original = stage.stage
    def interrupt(*args):
        ready = original(*args)
        assert len(list(ready.glob('sdk/*.jar'))) == 2
        os.kill(os.getpid(), signal.SIGINT)
        return ready
    stage.stage = interrupt
raise SystemExit(stage.main())
'''
        runner = self.output / 'runner'
        runner.mkdir()
        output_file = self.output / 'github-output'
        output_file.touch()
        p = subprocess.Popen([sys.executable, '-B', '-c', parent_code, child_code, str(report), case],
                             cwd=Path(compose.__file__).parent,
                             env=dict(os.environ, RUNNER_TEMP=str(runner), GITHUB_OUTPUT=str(output_file)),
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        child_pid = None
        try:
            if case == 'transfer':
                for _ in range(100):
                    try:
                        child_pid = int(report.read_text())
                        break
                    except (FileNotFoundError, ValueError):
                        threading.Event().wait(0.05)
                else:
                    self.fail('owned transfer never started')
                self.assertEqual('', output_file.read_text())
                self.assertEqual([], list(runner.glob('*/verified')))
                p.send_signal(signal.SIGTERM)
            out, err = p.communicate(timeout=8)
            self.assertEqual({'transfer': 143, 'verified': 130, 'success': 0}[case],
                             p.returncode, (out, err))
            if case == 'success':
                scratch, = runner.iterdir()
                ready = scratch / 'verified'
                self.assertEqual([ready], list(scratch.iterdir()))
                self.assertEqual(f'stage={ready}\n', output_file.read_text())
                self.assertEqual({'first.jar': b'fixture', 'last.jar': b'fixture'},
                                 {f.name: f.read_bytes() for f in (ready / 'sdk').iterdir()})
            else:
                self.assertIn('cancelled before publishing', err)
                self.assertEqual('', output_file.read_text())
                self.assertEqual([], list(runner.iterdir()))
                if child_pid is not None:
                    with self.assertRaises(ProcessLookupError):
                        os.kill(child_pid, 0)
        finally:
            if p.poll() is None:
                p.terminate()
                p.communicate(timeout=8)


if __name__ == '__main__':
    unittest.main()
