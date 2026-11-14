"""HARNESS ONLY: tiny ZIP/tar/PNG fixtures, never native capture evidence."""
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock
import zipfile

sys.path.insert(0, str(Path(__file__).parents[1]))
import studio
import capture_contract as contract


def archive(files):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w') as out:
        for name, data in files.items():
            info = tarfile.TarInfo(name); info.size = len(data)
            out.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class TransportTest(unittest.TestCase):
    def test_native_host_skips_only_absent_opt_in_before_private_reads(self):
        # Source-contract regression; real Android runner controls are separate.
        source = (studio.ROOT/studio.NATIVE_HOST).read_text()
        self.assertIn('import org.junit.Assume.assumeTrue', source)
        arguments = 'val arguments = InstrumentationRegistry.getArguments()'
        guard = 'assumeTrue("Native studio capture requires explicit opt-in", arguments.containsKey("studioRequestFile"))'
        read = 'val requestFile = arguments.getString("studioRequestFile")'
        validate = 'require(requestFile == "studio-render-request.json")'
        private_read = 'File(instrumentation.context.filesDir, requestFile).readText(Charsets.UTF_8)'
        binding_read = 'instrumentation.context.assets.open("studio-build.json")'
        positions = [source.index(part) for part in (arguments, guard, read, validate, private_read, binding_read)]
        self.assertEqual(sorted(positions), positions)
        self.assertEqual(1, source.count('assumeTrue('))
        self.assertNotIn('catch (', source)
        self.assertNotIn('return', source)
        self.assertEqual(source, (studio.HOME/'pending/StudioNativeComponentTest.kt').read_text())

    def test_large_request_streams_exact_bytes_with_short_private_file_commands(self):
        import native_capture
        self.assertTrue(callable(getattr(native_capture, 'transfer_request', None)), 'private request transfer is missing')
        payload = json.dumps({'HARNESS ONLY': 'source identity \u00e9'*16000}, ensure_ascii=False).encode('utf-8')
        self.assertGreaterEqual(len(payload), 200000)
        adb = ['HARNESS-ADB', '-s', 'HARNESS-SERIAL']
        package = 'com.soundq.designsystem.test'
        calls = []
        def run(command, **kwargs):
            self.assertTrue(kwargs['check'])
            self.assertLess(len(' '.join(command)), 1024)
            calls.append(command)
            if 'dd' in command:
                self.assertEqual(payload, kwargs['stdin'].read())
                self.assertNotIn('input', kwargs)
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            request = Path(temp)/'HARNESS-ONLY-request.json'; request.write_bytes(payload)
            with mock.patch.object(native_capture.subprocess, 'run', side_effect=run), \
                    mock.patch.object(native_capture.subprocess, 'check_output', return_value=studio.digest(payload)+'  files/studio-render-request.json\n') as device_hash:
                marker = native_capture.transfer_request(adb, package, request)
            device_hash.assert_called_once_with(
                [*adb, 'shell', 'run-as', package, 'sha256sum', 'files/studio-render-request.json'], text=True)
        self.assertEqual('studio-render-request.json', marker)
        self.assertEqual([
            [*adb, 'shell', 'run-as', package, 'mkdir', '-p', 'files'],
            [*adb, 'shell', '-T', 'run-as', package, 'dd', 'of=files/studio-render-request.json'],
        ], calls)

    def test_transfer_errors_propagate_without_continuing(self):
        import native_capture
        import subprocess
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            request = Path(temp)/'HARNESS-ONLY-request.json'; request.write_bytes(b'{}')
            for failed_call in (1, 2):
                with self.subTest(failed_call=failed_call):
                    error = subprocess.CalledProcessError(1, ['HARNESS-ADB'])
                    with mock.patch.object(native_capture.subprocess, 'run', side_effect=[None]*(failed_call-1)+[error]) as run:
                        with self.assertRaises(subprocess.CalledProcessError) as caught:
                            native_capture.transfer_request(['HARNESS-ADB'], 'com.soundq.designsystem.test', request)
                    self.assertIs(error, caught.exception)
                    self.assertEqual(failed_call, run.call_count)
                    self.assertTrue(all(call.kwargs['check'] for call in run.call_args_list))

    def test_return_zero_short_transfer_is_rejected_before_instrumentation(self):
        import native_capture
        import subprocess
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            root = Path(temp); request = root/'HARNESS-ONLY-request.json'
            studio.save(request, {'sources':studio.identities(), 'HARNESS ONLY':'x'*200000})
            received = b''
            def run(command, **kwargs):
                nonlocal received
                self.assertNotIn('instrument', command)
                self.assertTrue(kwargs['check'])
                if 'dd' in command:
                    received = kwargs['stdin'].read()[:-475]
                return subprocess.CompletedProcess(command, 0)
            def output(command, **kwargs):
                self.assertTrue(kwargs['text'])
                if 'sha256sum' in command and 'run-as' in command:
                    return studio.digest(received)+'  files/studio-render-request.json\n'
                return {'install':'Success', 'shell':'package:/HARNESS.apk' if 'path' in command else 'HARNESS-HASH /HARNESS.apk'}[command[3]]
            argv = ['native_capture.py', 'run', '--adb', 'HARNESS-ADB', '--serial', 'HARNESS-SERIAL',
                '--apk', str(root/'HARNESS-ONLY.apk'), '--request', str(request), '--output', str(root/'output')]
            with mock.patch('builtins.print'), mock.patch.object(studio, 'require_native_host'), mock.patch.object(sys, 'argv', argv), \
                    mock.patch.object(contract, 'apk_binding', return_value={'apk_sha256':'HARNESS-HASH'}), \
                    mock.patch.object(native_capture.subprocess, 'check_output', side_effect=output), \
                    mock.patch.object(native_capture.subprocess, 'run', side_effect=run):
                with self.assertRaisesRegex(ValueError, 'request.*hash.*mismatch'):
                    native_capture.main()
            self.assertEqual(request.read_bytes()[:-475], received)
            self.assertFalse((root/'output').exists())

    def test_device_hash_command_failure_propagates(self):
        import native_capture
        import subprocess
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            request = Path(temp)/'HARNESS-ONLY-request.json'; request.write_bytes(b'{}')
            error = subprocess.CalledProcessError(1, ['HARNESS-ADB'])
            with mock.patch.object(native_capture.subprocess, 'run'), \
                    mock.patch.object(native_capture.subprocess, 'check_output', side_effect=error):
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    native_capture.transfer_request(['HARNESS-ADB'], 'com.soundq.designsystem.test', request)
            self.assertIs(error, caught.exception)

    def test_runner_passes_only_fixed_file_marker_to_instrumentation(self):
        import native_capture
        import subprocess
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            root = Path(temp); request = root/'HARNESS-ONLY-request.json'
            studio.save(request, {'sources':studio.identities(), 'HARNESS ONLY':'x'*200000})
            argv = ['native_capture.py', 'run', '--adb', 'HARNESS-ADB', '--serial', 'HARNESS-SERIAL',
                '--apk', str(root/'HARNESS-ONLY.apk'), '--request', str(request), '--output', str(root/'output')]
            with mock.patch('builtins.print'), mock.patch.object(studio, 'require_native_host'), mock.patch.object(sys, 'argv', argv), \
                    mock.patch.object(contract, 'apk_binding', return_value={'apk_sha256':'HARNESS-HASH'}), \
                    mock.patch.object(native_capture.subprocess, 'check_output', side_effect=['Success', 'package:/HARNESS.apk', 'HARNESS-HASH /HARNESS.apk']), \
                    mock.patch.object(native_capture, 'transfer_request', return_value='studio-render-request.json') as transfer, \
                    mock.patch.object(native_capture.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'OK (1 test)', '')) as run:
                native_capture.main()
            transfer.assert_called_once_with(['HARNESS-ADB', '-s', 'HARNESS-SERIAL'], 'com.soundq.designsystem.test', request)
            command = run.call_args.args[0]
            self.assertIn('studioRequestFile', command)
            self.assertEqual('studio-render-request.json', command[command.index('studioRequestFile')+1])
            self.assertNotIn('studioRequestBase64', command)
            self.assertLess(len(' '.join(command)), 1024)
            studio.require_native_host()
            self.assertIn(studio.NATIVE_HOST, studio.identities())
            source = (studio.ROOT/studio.NATIVE_HOST).read_text()
            self.assertNotIn('Base64', source)
            self.assertIn('getString("studioRequestFile")', source)
            self.assertIn('require(requestFile == "studio-render-request.json")', source)
            self.assertIn('File(instrumentation.context.filesDir, requestFile).readText(Charsets.UTF_8)', source)

    def test_missing_receipt_never_refreshes_previous_valid_harness_target(self):
        self.assertIsNotNone(contract, 'archive validation helper is missing')
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            root = Path(temp); out = root/'captures'; out.mkdir()
            image = out/'components-harness.png'
            studio.write_png(image, 1, 1, bytes([0, 0, 0, 255]))
            req = root/'request.json'
            env = {'sdk':1,'fingerprint':'HARNESS ONLY','model':'harness','density':2,'fontScale':1,'locale':'en-US','renderer':'harness-only','widthDp':360}
            studio.save(req, {'schema':1,'sources':studio.identities(),'environment':env,'cases':['components-harness']})
            receipt = {'schema':1,'kind':'harness-only','sources':studio.identities(),'environment':env,'cases':[{'id':'components-harness','file':image.name,'sha256':studio.digest(image.read_bytes())}]}
            studio.save(out/'receipt.json', receipt)
            studio.validate(out, req, harness=True)
            before = {p.name:p.read_bytes() for p in out.iterdir()}
            for files in ({}, {image.name:image.read_bytes()}, {'receipt.json':json.dumps(receipt).encode()}):
                with self.subTest(files=list(files)):
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        contract.collect_archive(archive(files), out, req, {}, harness=True)
                    self.assertEqual(before, {p.name:p.read_bytes() for p in out.iterdir()})
            (out/'stale.txt').write_text('not from this transfer')
            with self.assertRaisesRegex(ValueError, 'recognized collection'):
                contract.collect_archive(archive(before), out, req, {}, harness=True)
            self.assertEqual('not from this transfer', (out/'stale.txt').read_text())
            (out/'stale.txt').unlink()  # Remove only this test-owned sentinel.
            contract.collect_archive(archive(before), out, req, {}, harness=True)
            self.assertEqual(before, {p.name:p.read_bytes() for p in out.iterdir()})



class CollectionAdmissionTest(unittest.TestCase):
    """Real filesystem transactions, exclusively inside synthetic owned TMPDIRs."""
    maxDiff = None

    def fixture(self, root, native=False):
        repo = root/'repo'
        source = repo/'android/src/Widget.kt'
        source.parent.mkdir(parents=True)
        source.write_bytes('HARNESS ONLY source café'.encode('utf-8'))
        host = repo/studio.NATIVE_HOST
        host.parent.mkdir(parents=True)
        host.write_bytes(b'HARNESS ONLY host presence; no native execution')
        sources = studio.identities(repo)
        env = {'sdk':1,'fingerprint':'HARNESS ONLY','model':'harness','density':2,'fontScale':1,'locale':'en-US','renderer':'harness-only','widthDp':360}
        req = root/'inputs/request.json'
        ids = studio.CASE_IDS if native else ['components-harness']
        studio.save(req, {'schema':1,'sources':sources,'environment':env,'cases':ids})
        incoming = root/'incoming'; incoming.mkdir()
        cases = []
        for case_id in ids:
            image = incoming/(case_id+'.png')
            studio.write_png(image, 720 if native else 1, 100 if native else 1,
                             bytes([0,0,0,255])*(72000 if native else 1))
            cases.append({'id':case_id,'file':image.name,'sha256':studio.digest(image.read_bytes())})
        binding = {'schema':1,'build_mode':'isolated-source-snapshot','sources':sources}
        receipt = {'schema':1,'kind':'android-compose-native' if native else 'harness-only',
                   'sources':sources,'environment':env,'cases':cases}
        if native: receipt['build_binding'] = binding
        studio.save(incoming/'receipt.json', receipt)
        files = {p.name:p.read_bytes() for p in incoming.iterdir()}
        return repo, source, req, files, binding

    def hashes(self, paths):
        return {str(p):studio.digest(p.read_bytes()) if p.is_file() else None for p in paths}

    def test_request_source_and_symlink_ancestor_overlap_preserve_all_bytes(self):
        for target in ('request', 'source', 'symlink-request', 'symlink-source'):
            with self.subTest(target=target), tempfile.TemporaryDirectory(prefix='studio-owned-admission-') as temp:
                root = Path(temp).resolve()
                repo, source, req, files, _ = self.fixture(root)
                unrelated = root/'unrelated.bin'; unrelated.write_bytes(b'UNRELATED sentinel')
                apk = root/'supplied.apk'; apk.write_bytes(b'APK sentinel')
                out = req.parent if 'request' in target else repo
                if target.startswith('symlink'):
                    alias = root/'alias'; alias.symlink_to(out.parent, target_is_directory=True)
                    out = alias/out.name
                before = self.hashes([req, apk, source, unrelated])
                error = None
                with mock.patch.object(studio, 'ROOT', repo):
                    try: contract.collect_archive(archive(files), out, req, {}, harness=True)
                    except ValueError as caught: error = caught
                self.assertEqual(before, self.hashes([req, apk, source, unrelated]))
                self.assertIsNotNone(error, 'overlapping input must be refused')
                self.assertIn('overlap', str(error))

    def test_unowned_nonempty_directory_and_regular_file_are_not_deleted(self):
        for regular_file in (False, True):
            with self.subTest(regular_file=regular_file), tempfile.TemporaryDirectory(prefix='studio-owned-admission-') as temp:
                root = Path(temp).resolve()
                repo, source, req, files, _ = self.fixture(root)
                out = root/'unowned'
                if regular_file:
                    out.write_bytes(b'UNOWNED file'); sentinel = out
                else:
                    out.mkdir(); sentinel = out/'unrelated.bin'; sentinel.write_bytes(b'UNOWNED contents')
                before = self.hashes([req, source, sentinel])
                error = None
                with mock.patch.object(studio, 'ROOT', repo):
                    try: contract.collect_archive(archive(files), out, req, {}, harness=True)
                    except ValueError as caught: error = caught
                self.assertEqual(before, self.hashes([req, source, sentinel]))
                self.assertIsNotNone(error, 'unowned output must be refused')
                self.assertIn('recognized collection', str(error))

    def test_safe_collection_replacement_and_publish_failure_rollback(self):
        with tempfile.TemporaryDirectory(prefix='studio-owned-admission-') as temp:
            root = Path(temp).resolve()
            repo, source, req, files, _ = self.fixture(root)
            unrelated = root/'unrelated.bin'; unrelated.write_bytes(b'UNRELATED sentinel')
            apk = root/'supplied.apk'; apk.write_bytes(b'APK sentinel')
            out = root/'captures'
            before = self.hashes([req, apk, source, unrelated])
            with mock.patch.object(studio, 'ROOT', repo):
                contract.collect_archive(archive(files), out, req, {}, harness=True)
                # Historical sources are not a reason to delete unrelated files, nor
                # a reason to forbid replacing an otherwise intact owned collection.
                old = studio.load(out/'receipt.json'); old['sources'] = {'historical':'0'*64}
                studio.save(out/'receipt.json', old)
                previous = {p.name:p.read_bytes() for p in out.iterdir()}
                rename = Path.rename
                def fail_publish(path, target):
                    if path.name == 'captures' and path.parent.name.startswith('.native-transfer-'):
                        raise OSError('HARNESS forced publication failure')
                    return rename(path, target)
                with mock.patch.object(Path, 'rename', fail_publish):
                    with self.assertRaisesRegex(OSError, 'forced publication failure'):
                        contract.collect_archive(archive(files), out, req, {}, harness=True)
                self.assertEqual(previous, {p.name:p.read_bytes() for p in out.iterdir()})
                contract.collect_archive(archive(files), out, req, {}, harness=True)
                self.assertEqual(files, {p.name:p.read_bytes() for p in out.iterdir()})
            self.assertEqual(before, self.hashes([req, apk, source, unrelated]))
            self.assertEqual([], list(root.glob('.native-transfer-*')))

    def test_collect_caller_protects_actual_supplied_apk_through_symlink_ancestor(self):
        import native_capture
        for aliased in (False, True):
            with self.subTest(aliased=aliased), tempfile.TemporaryDirectory(prefix='studio-owned-admission-') as temp:
                root = Path(temp).resolve()
                repo, source, req, files, binding = self.fixture(root, native=True)
                out = root/'apk-input'; out.mkdir()
                apk = out/'supplied.apk'
                with zipfile.ZipFile(apk, 'w') as zipped:
                    zipped.writestr('assets/studio-build.json', json.dumps(binding))
                unrelated = root/'unrelated.bin'; unrelated.write_bytes(b'UNRELATED sentinel')
                before = self.hashes([req, apk, source, unrelated])
                if aliased:
                    alias = root/'alias'; alias.symlink_to(root, target_is_directory=True)
                    supplied = alias/'apk-input/supplied.apk'
                else: supplied = apk
                argv = ['native_capture.py','collect','--serial','HARNESS','--apk',str(supplied),
                        '--request',str(req),'--output',str(out)]
                def output(command, **kwargs):
                    if 'path' in command: return 'package:/HARNESS.apk'
                    if 'sha256sum' in command: return studio.digest(apk.read_bytes())+' /HARNESS.apk'
                    return archive(files)
                error = None
                with mock.patch.object(studio, 'ROOT', repo), mock.patch.object(sys, 'argv', argv), \
                        mock.patch.object(native_capture.subprocess, 'check_output', side_effect=output), mock.patch('builtins.print'):
                    try: native_capture.main()
                    except ValueError as caught: error = caught
                self.assertEqual(before, self.hashes([req, apk, source, unrelated]))
                self.assertIsNotNone(error, 'actual caller APK input must be protected')
                self.assertIn('overlap', str(error))


class BindingTest(unittest.TestCase):
    def test_run_and_collect_reject_old_embedded_sources_before_any_adb_call(self):
        import subprocess
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            root = Path(temp)
            sources = studio.identities()
            request = root/'HARNESS-ONLY-request.json'
            studio.save(request, {'schema':1, 'kind':'harness-only', 'sources':sources})
            old = dict(sources); old[next(iter(old))] = '0'*64
            apk = root/'HARNESS-ONLY.apk'
            with zipfile.ZipFile(apk, 'w') as out:
                out.writestr('assets/studio-build.json', json.dumps({'schema':1, 'build_mode':'isolated-source-snapshot', 'sources':old}))
            os.utime(apk, (4102444800, 4102444800))
            for action in ('run', 'collect'):
                result = subprocess.run([sys.executable, '-B', str(studio.HOME/'native_capture.py'), action,
                    '--adb', str(root/'NO-ADB-MUST-BE-CALLED'), '--serial', 'HARNESS-ONLY',
                    '--apk', str(apk), '--request', str(request), '--output', str(root/'captures')], capture_output=True, text=True)
                self.assertNotEqual(0, result.returncode)
                self.assertIn('embedded APK source identities mismatch', result.stderr)
                self.assertFalse((root/'captures').exists())

    def test_newer_equal_installed_old_apk_cannot_bind_to_new_manifest(self):
        self.assertTrue(callable(getattr(contract, 'apk_binding', None)), 'embedded APK binding is missing')
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            apk = Path(temp)/'harness-only.apk'
            old = {'HARNESS-ONLY-source':'a'*64}
            new = {'HARNESS-ONLY-source':'b'*64}
            asset = {'schema':1,'build_mode':'isolated-source-snapshot','sources':old}
            with zipfile.ZipFile(apk, 'w') as out:
                out.writestr('assets/studio-build.json', json.dumps(asset))
            os.utime(apk, (4102444800, 4102444800))
            installed_hash = studio.digest(apk.read_bytes())
            self.assertEqual(installed_hash, studio.digest(apk.read_bytes()))
            with self.assertRaisesRegex(ValueError, 'embedded.*source'):
                contract.apk_binding(apk, new, installed_hash)
            proof = contract.apk_binding(apk, old, installed_hash)
            studio.validate_build(proof, old)
            self.assertEqual('isolated-source-snapshot', proof['build_mode'])
            with self.assertRaisesRegex(ValueError, 'installed'):
                contract.apk_binding(apk, old, '0'*64)
            with zipfile.ZipFile(apk, 'w') as out:
                out.writestr('harness-only.txt', 'no embedded build asset')
            with self.assertRaisesRegex(ValueError, 'embedded'):
                contract.apk_binding(apk, old)


class SnapshotTest(unittest.TestCase):
    def test_private_snapshot_excludes_generated_and_secret_inputs_and_detects_edits(self):
        try:
            import build_capture
        except ImportError:
            self.fail('isolated-source build producer is missing')
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            root = Path(temp)/'HARNESS-ONLY'; root.mkdir()
            (root/'android').mkdir(); (root/'design-studio').mkdir()
            for name in ('studio.py', 'capture_contract.py', 'native_capture.py', 'build_capture.py'):
                (root/'design-studio'/name).write_bytes((studio.HOME/name).read_bytes())
            for name in ('src/Widget.kt', 'build/stale.apk', '.gradle/cache', 'local.properties', 'secret.jks', 'src/file.tmp', '.cxx/cache', '.git/config'):
                path = root/'android'/name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('HARNESS ONLY')
            with unittest.mock.patch.object(studio, 'ROOT', root):
                sources = studio.identities()
                self.assertIn('design-studio/build_capture.py', sources)
                self.assertIn('design-studio/capture_contract.py', sources)
                self.assertIn('android/src/Widget.kt', sources)
                self.assertEqual(5, len(sources))
                snapshot = Path(temp)/'private'; snapshot.mkdir(mode=0o700)
                build_capture.prepare_snapshot(root, snapshot, sources)
                self.assertEqual(sources, build_capture.snapshot_identities(snapshot))
                self.assertFalse((snapshot/'android/local.properties').exists())
                self.assertFalse((snapshot/'android/build').exists())
                stamp = studio.load(snapshot/'android/designsystem/src/androidTest/assets/studio-build.json')
                self.assertEqual(sources, stamp['sources'])
                build_capture.verify_sources(snapshot, sources)
                source = snapshot/'android/src/Widget.kt'; source.chmod(0o600); source.write_text('changed snapshot')
                with self.assertRaisesRegex(ValueError, 'snapshot'):
                    build_capture.verify_sources(snapshot, sources)
                source.write_text('HARNESS ONLY')
                (root/'android/src/Widget.kt').write_text('changed checkout')
                with self.assertRaisesRegex(ValueError, 'current'):
                    build_capture.verify_sources(snapshot, sources)


    def test_build_stamps_and_checks_catalog_before_only_library_task(self):
        import build_capture
        class HarnessStop(Exception): pass
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            env = dict(os.environ, JAVA_HOME=temp, ANDROID_HOME=temp, TMPDIR=temp, GRADLE_OPTS='HARNESS forbidden')
            calls = []
            def runner(command, *, cwd, env, check):
                calls.append(command)
                self.assertTrue(check)
                snapshot = Path(cwd) if command[0] == sys.executable else Path(cwd).parent
                self.assertEqual(0o700, snapshot.stat().st_mode & 0o777)
                self.assertNotIn('GRADLE_OPTS', env)
                self.assertTrue(env['GRADLE_USER_HOME'].startswith(str(snapshot)))
                stamp = studio.load(snapshot/studio.BUILD_ASSET)
                self.assertEqual(studio.identities(), stamp['sources'])
                if command[0] == sys.executable:
                    # Real canonical verifier/catalog in copied source, not a stub.
                    import subprocess
                    return subprocess.run(command, cwd=cwd, env=env, check=check, capture_output=True, text=True)
                self.assertEqual(':designsystem:assembleDebugAndroidTest', command[1])
                self.assertIn('--max-workers=2', command)
                self.assertEqual(stamp['sources'], studio.load(snapshot/'design-studio/generated/catalog.json')['identities'])
                raise HarnessStop('HARNESS ONLY: deliberately stop before any Gradle invocation')
            before = {str(p.relative_to(studio.HOME/'build')):p.read_bytes() for p in (studio.HOME/'build').rglob('*') if p.is_file()}
            with mock.patch.object(studio, 'require_native_host'), self.assertRaises(HarnessStop):
                build_capture.build(studio.HOME/'build', env, runner)
            self.assertEqual(2, len(calls))
            self.assertEqual(before, {str(p.relative_to(studio.HOME/'build')):p.read_bytes() for p in (studio.HOME/'build').rglob('*') if p.is_file()})



class PendingIntegrationTest(unittest.TestCase):
    def test_missing_native_host_refuses_build_before_subprocess_or_toolchain(self):
        import build_capture
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            with mock.patch.object(studio, 'ROOT', Path(temp)):
                runner = mock.Mock()
                with self.assertRaisesRegex(ValueError, 'pending integration'):
                    build_capture.build(Path(temp)/'build', {}, runner)
                runner.assert_not_called()

    def test_missing_native_host_refuses_run_and_collect_before_device_access(self):
        import native_capture
        with tempfile.TemporaryDirectory(prefix='studio-harness-') as temp:
            root=Path(temp); request=root/'HARNESS-request.json'
            with mock.patch.object(studio, 'ROOT', root):
                sources=studio.identities()
                studio.save(request, {'schema':1,'sources':sources})
                apk=root/'HARNESS.apk'
                with zipfile.ZipFile(apk, 'w') as out:
                    out.writestr('assets/studio-build.json', json.dumps({'schema':1,'build_mode':'isolated-source-snapshot','sources':sources}))
                for action in ('run','collect'):
                    argv=['native_capture.py',action,'--serial','HARNESS','--apk',str(apk),'--request',str(request),'--output',str(root/'output')]
                    with self.subTest(action=action), mock.patch.object(sys,'argv',argv), mock.patch.object(native_capture.subprocess,'run') as run, mock.patch.object(native_capture.subprocess,'check_output') as output:
                        with self.assertRaisesRegex(ValueError, 'pending integration'):
                            native_capture.main()
                        run.assert_not_called(); output.assert_not_called()
                self.assertFalse((root/'output').exists())


if __name__ == '__main__': unittest.main()
