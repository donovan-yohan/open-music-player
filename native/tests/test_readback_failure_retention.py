#!/usr/bin/env python3
"""Offline retention contract; failure tools are synthetic, never native runtime."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CONTRACTS = (
    ('.github/workflows/ci.yml', 'native-readback-method',
     'native-readback-method', 'client-native-readback-method'),
    ('.github/workflows/native-clients.yml', 'flutter-native-readback',
     'flutter-native-readback', 'native-macos-flutter-native-readback'),
)


def steps(workflow):
    # Read the actual step blocks without a non-stdlib YAML dependency.
    text = (ROOT / workflow).read_text()
    return re.findall(r'^      - .*?(?=^      - |^  \w|\Z)', text, re.M | re.S)


def field(block, key):
    match = re.search(r'^\s+' + re.escape(key) + r': (.+)$', block, re.M)
    return match.group(1).strip() if match else None


class FailureEvidenceRetention(unittest.TestCase):
    def upload(self, contract):
        workflow, step_id, directory, artifact = contract
        blocks = steps(workflow)
        producer = next(b for b in blocks if '--output "$RUNNER_TEMP/' + directory + '"' in b)
        self.assertNotIn('continue-on-error:', producer)
        uploads = [b for b in blocks if field(b, 'name') == artifact]
        self.assertEqual(len(uploads), 1, 'executed failures need a retained diagnostic artifact')
        upload = uploads[0]
        self.assertEqual(field(producer, 'id'), step_id)
        self.assertGreater(blocks.index(upload), blocks.index(producer))
        self.assertEqual(field(upload, 'uses'), 'actions/upload-artifact@v4')
        self.assertEqual(field(upload, 'if'),
                         "always() && (steps." + step_id + ".outcome == 'success' || steps." + step_id + ".outcome == 'failure')")
        self.assertEqual(field(upload, 'retention-days'), '7')
        self.assertEqual(field(upload, 'if-no-files-found'), 'error')
        self.assertEqual(field(upload, 'include-hidden-files'), 'false')
        self.assertNotIn('continue-on-error:', upload)
        match = re.search(r'^          path: \|\n((?:            .+\n)+)', upload, re.M)
        self.assertIsNotNone(match)
        assert match is not None
        patterns = [x.strip() for x in match.group(1).splitlines()]
        prefix = '${{ runner.temp }}/' + directory + '/'
        self.assertEqual(patterns, [prefix + '*.log', prefix + 'receipt.json'])
        return patterns

    def test_workflow_failure_and_prerequisite_skip_policy(self):
        for contract in CONTRACTS:
            with self.subTest(workflow=contract[0]):
                self.upload(contract)
                # The explicit outcomes exclude skipped/never-run prerequisites,
                # while retaining both failed and successful executed steps.
                self.assertNotIn('skipped', ('success', 'failure'))
                self.assertNotIn('', ('success', 'failure'))

    def failure_inventory(self, contract, mode):
        patterns = self.upload(contract)
        with tempfile.TemporaryDirectory(prefix='readback-retention-') as temporary:
            root = Path(temporary)
            tools = root / 'tools'
            tools.mkdir()
            output = root / contract[2]
            if mode == 'dart':
                tool = tools / 'flutter'
                tool.write_text('#!' + sys.executable + '\nimport sys\nprint("synthetic dart failure stdout")\nprint("synthetic dart failure stderr", file=sys.stderr)\nsys.exit(17)\n')
                script = ROOT / 'client/test/just_audio_native_readback_contracts.py'
                expected_exit = 17
                expected_logs = {'run.log'}
                markers = ['synthetic dart failure stdout', 'synthetic dart failure stderr']
            else:
                tool = tools / 'clang'
                if mode == 'compile':
                    tool.write_text('#!' + sys.executable + '\nimport sys\nprint("synthetic compile failure stdout")\nprint("synthetic compile failure stderr", file=sys.stderr)\nsys.exit(19)\n')
                    expected_logs = {'compile.log'}
                    markers = ['synthetic compile failure stdout', 'synthetic compile failure stderr']
                else:
                    tool.write_text('#!' + sys.executable + '\nimport pathlib,sys\np=pathlib.Path(sys.argv[sys.argv.index("-o")+1])\np.write_text(' + repr('#!' + sys.executable + '\nimport sys\nprint("synthetic case failure " + sys.argv[1])\nsys.exit(23)\n') + ')\np.chmod(0o700)\n')
                    expected_logs = None
                    markers = ['synthetic case failure positive']
                script = ROOT / 'native/tests/flutter_native_readback_regressions.py'
                expected_exit = 1
            tool.chmod(0o700)
            env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ.get('PATH', ''))
            result = subprocess.run([sys.executable, '-B', str(script), '--output', str(output)],
                                    env=env, capture_output=True, timeout=30)
            self.assertEqual(result.returncode, expected_exit, result.stderr.decode())
            inventory = {p.name: p.read_bytes() for pattern in patterns
                         for p in root.glob(pattern.replace('${{ runner.temp }}/', ''))}
            receipt = json.loads(inventory['receipt.json'])
            self.assertTrue(receipt['executed'])
            if mode == 'cases':
                expected_logs = {'compile.log'} | {case['name'] + '.log' for case in receipt['cases']}
                self.assertEqual(len(receipt['cases']), 21)
                self.assertTrue(all(case['exit'] == 23 for case in receipt['cases']))
            assert expected_logs is not None
            self.assertEqual(set(inventory), expected_logs | {'receipt.json'})
            combined = b'\n'.join(inventory.values())
            for marker in markers:
                self.assertIn(marker.encode(), combined)
            self.assertNotIn(b'SOUNDQ_NATIVE_PLAYER_READBACK_TOKEN=', combined)
            self.assertNotIn('probe', inventory)
            self.assertFalse(any(name.startswith('.') for name in inventory))

    def test_dart_failure_logs_and_exit_survive_upload_inventory(self):
        self.failure_inventory(CONTRACTS[0], 'dart')

    def test_native_compile_failure_logs_survive_upload_inventory(self):
        self.failure_inventory(CONTRACTS[1], 'compile')

    def test_all_native_failed_case_logs_survive_upload_inventory(self):
        self.failure_inventory(CONTRACTS[1], 'cases')


if __name__ == '__main__':
    unittest.main()
