#!/usr/bin/env python3
"""Exercise the Android product harness's actual temporary-root precondition."""
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

HARNESS = Path(__file__).resolve().with_name('android-product')
MODULE = runpy.run_path(str(HARNESS), run_name='android_product_test')
CHECK = MODULE['checked_temp_directory']


class ProductTemporaryDirectoryTest(unittest.TestCase):
    def setUp(self):
        base = CHECK(os.environ['TMPDIR'])
        self.scope = tempfile.TemporaryDirectory(prefix='android-harness-', dir=base)
        self.addCleanup(self.scope.cleanup)
        self.root = Path(self.scope.name)

    def test_gradle_options_do_not_duplicate_caller_worker_limit(self):
        self.assertEqual(['--max-workers=1', '--no-daemon'], MODULE['gradle_options']([]))
        self.assertEqual(['--max-workers=1', '--no-daemon'], MODULE['gradle_options'](['--max-workers=1', '--no-daemon']))
        self.assertEqual(['--no-daemon', '--max-workers', '1'], MODULE['gradle_options'](['--max-workers', '1']))

    def test_canonical_owned_directory_is_preserved(self):
        self.assertEqual(str(self.root), CHECK(str(self.root)))

    def test_relative_missing_and_file_paths_are_rejected(self):
        file = self.root / 'not-a-directory'
        file.write_text('fixture')
        for value in ['relative', str(self.root / 'missing'), str(file)]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                CHECK(value)

    def test_alias_and_alias_ancestor_are_not_silently_normalized(self):
        target = self.root / 'target'
        child = target / 'child'
        child.mkdir(parents=True)
        alias = self.root / 'alias'
        alias.symlink_to(target, target_is_directory=True)
        for value in [alias, alias / 'child']:
            with self.subTest(value=str(value)), self.assertRaises(ValueError):
                CHECK(str(value))
        self.assertTrue(child.is_dir())

    def test_check_wires_real_tasks_and_fixture_environment(self):
        # This is a launcher boundary test, not a compiled SDK/audio-runtime pass.
        from unittest.mock import patch
        calls = []
        jdk = self.root / 'jdk'
        (jdk / 'include').mkdir(parents=True)
        (jdk / 'include/jni.h').write_text('synthetic prerequisite')
        android = self.root / 'android'
        android.mkdir()
        env = dict(os.environ, TMPDIR=str(self.root), JAVA_HOME=str(jdk),
                   ANDROID_HOME=str(self.root), GRADLE_USER_HOME=str(self.root),
                   OMP_API_BASE_URL='https://fixture.invalid/api/v1',
                   OMP_SOURCE_REF='synthetic-launcher', OMP_BUILD_ID='synthetic-launcher',
                   SOUNDQ_HOST_JAVA_HOME=str(jdk))
        def record(argv, environment):
            calls.append((list(map(str, argv)), dict(environment)))
        with patch.dict(os.environ, env, clear=True), \
                patch.dict(MODULE['main'].__globals__, ANDROID=android, run=record), \
                patch('sys.argv', [str(HARNESS), 'check']), \
                patch('shutil.which', return_value='synthetic-tool'), \
                patch('shutil.copyfile'), patch('subprocess.run') as guard:
            MODULE['main']()
        self.assertEqual(1, guard.call_count)  # Checked privacy subprocess.
        self.assertTrue(guard.call_args.kwargs['check'])
        gradle, forwarded = calls[-1]
        for task in [':app:testDebugUnitTest', ':designsystem:testDebugUnitTest',
                     ':app:assembleDebug', ':app:assembleDebugAndroidTest',
                     ':app:lintDebug', ':designsystem:lintDebug']:
            self.assertIn(task, gradle)
        self.assertEqual('./gradlew', gradle[0])
        for key in ['SOUNDQ_MIX_HOST_LIBRARY', 'SOUNDQ_MIX_FIXTURE',
                    'SOUNDQ_LISTENING_FIXTURE', 'SOUNDQ_LISTENING_OUTPUT']:
            self.assertTrue(forwarded[key].startswith(str(android / 'build')))
        self.assertTrue(any('scripts/test-native-mix.py' in call for call, _ in calls))
        self.assertFalse(any('install' in arg.lower() for call, _ in calls for arg in call))

    def test_design_failure_stops_before_host_or_gradle(self):
        from unittest.mock import patch
        env = dict(os.environ, TMPDIR=str(self.root), JAVA_HOME=str(self.root),
                   ANDROID_HOME=str(self.root), GRADLE_USER_HOME=str(self.root),
                   OMP_API_BASE_URL='https://fixture.invalid/api/v1',
                   OMP_SOURCE_REF='synthetic-launcher', OMP_BUILD_ID='synthetic-launcher')
        with patch.dict(os.environ, env, clear=True), \
                patch('sys.argv', [str(HARNESS), 'build']), \
                patch('subprocess.run', side_effect=subprocess.CalledProcessError(9, ['design'])) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                MODULE['main']()
        self.assertEqual(1, run.call_count)
        self.assertIn('scripts/check-design.py', run.call_args.args[0])
        self.assertTrue(run.call_args.kwargs['check'])

    def test_cli_rejects_before_any_build_tool_with_invalid_root(self):
        env = dict(os.environ, TMPDIR=str(self.root / 'missing'), JAVA_HOME='unused-fixture-jdk', ANDROID_HOME='unused-fixture-sdk', GRADLE_USER_HOME=str(self.root), OMP_API_BASE_URL='https://fixture.invalid/api/v1', OMP_SOURCE_REF='synthetic-harness-test', OMP_BUILD_ID='synthetic-harness-test')
        result = subprocess.run([sys.executable, str(HARNESS), 'build'], env=env, capture_output=True, text=True, check=False)
        self.assertEqual(2, result.returncode)
        self.assertIn('TMPDIR must be an existing canonical directory', result.stderr)
        self.assertNotIn('Traceback', result.stderr)
        self.assertFalse((self.root / 'missing').exists())


if __name__ == '__main__':
    unittest.main()
