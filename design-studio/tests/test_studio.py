import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('studio', Path(__file__).parents[1] / 'studio.py')
assert spec is not None and spec.loader is not None
studio = importlib.util.module_from_spec(spec)
if Path(__file__).parents[1].joinpath('studio.py').exists(): spec.loader.exec_module(studio)

class KotlinTest(unittest.TestCase):
    def test_catalog_derives_alias_token_roles(self):
        component=next(c for c in studio.catalog()['components'] if c['name']=='SoundQButton')
        self.assertIn('SoundQ.colors.primary',component['token_roles'])
    def test_comments_strings_do_not_trigger_policy(self):
        self.assertEqual([], studio.adoption_errors('/* Button( Color(0xff) */ val s="TextField( Color.Red"; SoundQButton("ok", {})'))
    def test_stock_and_alias_are_rejected(self):
        self.assertTrue(studio.adoption_errors('import androidx.compose.material3.Button as B\n B(onClick={}) {}'))
        self.assertTrue(studio.adoption_errors('TextField(value="", onValueChange={})'))
    def test_color_rejected_not_layout_literals(self):
        self.assertTrue(studio.adoption_errors('val c=Color(0xff123456)'))
        self.assertEqual([], studio.adoption_errors('Spacer(Modifier.height(24.dp)); Text("hello", color=SoundQ.colors.text)'))


    def test_repeated_import_names_preserve_every_stock_and_color_alias(self):
        for name, qualified, calls, diagnostic in (
                ('Button', 'androidx.compose.material3.Button', ('First(onClick={}) {}','Second(onClick={}) {}'), 'stock'),
                ('TextField', 'androidx.compose.material3.TextField', ('First(value="",onValueChange={})','Second(value="",onValueChange={})'), 'stock'),
                ('Color', 'androidx.compose.ui.graphics.Color', ('First(0xff123456)','Second.Red'), 'raw color;')):
            imports = f'import {qualified} as First\nimport {qualified} as Second\n'
            for call in calls:
                with self.subTest(import_name=name, call=call):
                    errors = studio.adoption_errors(imports+'SoundQButton("Apply", {}); '+call)
                    self.assertEqual(1, len(errors), errors)
                    self.assertIn(diagnostic, errors[0])
                    if diagnostic == 'stock':
                        self.assertIn('stock '+call.split('(')[0]+';', errors[0])
            with self.subTest(import_name=name, call='both'):
                self.assertEqual(2, len(studio.adoption_errors(imports+'SoundQButton("Apply", {}); '+'; '.join(calls))))


class HarnessTest(unittest.TestCase):
    def run_harness(self, mutation=None):
        import json
        import os
        import shutil
        import subprocess
        import sys
        import tempfile
        with tempfile.TemporaryDirectory(prefix='studio-harness-control-') as temp:
            root = Path(temp)
            home = root/'design-studio'; (home/'tests').mkdir(parents=True)
            for name in ('studio.py', 'harness.py', 'tests/test_visual.py'):
                shutil.copyfile(studio.HOME/name, home/name)
            if mutation:
                source = (home/'studio.py').read_text(encoding='utf-8')
                self.assertIn(mutation[0], source)
                (home/'studio.py').write_text(source.replace(*mutation), encoding='utf-8')
            result = subprocess.run([sys.executable,'-B',str(home/'harness.py'),'--output',str(root/'results')],
                                    capture_output=True, text=True, env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1'))
            data = json.loads((root/'results/results.json').read_text(encoding='utf-8')) if result.returncode == 0 else None
            return result, data

    def test_stock_fixture_failures_have_intended_diagnostics_not_missing_adoption(self):
        result, data = self.run_harness()
        self.assertEqual(0, result.returncode, result.stderr)
        assert data is not None
        checks = {r['label']:r for r in data['cli_checks']}
        self.assertEqual(17, len(checks))
        for label, diagnostic in (
                ('stock Button replacement rejected','stock Button;'),
                ('stock TextField alias rejected','stock Input;'),
                ('raw color rejected','raw color;')):
            with self.subTest(label=label):
                self.assertIn(diagnostic, checks[label]['stderr'])
                self.assertNotIn('no actual SoundQ component adoption', checks[label]['stderr'])

    def test_harness_fails_when_each_stock_or_color_detector_is_disabled(self):
        mutations = (
            ('for name in sorted(forbidden):', 'for name in []:', 'stock Button replacement rejected'),
            ('for name, alias in aliases if name in forbidden',
             'for name, alias in aliases if False', 'stock TextField alias rejected'),
            ('for name in colors:', 'for name in []:', 'raw color rejected'),
        )
        for before, after, label in mutations:
            with self.subTest(detector=label):
                result, _ = self.run_harness((before, after))
                self.assertNotEqual(0, result.returncode, 'harness falsely passed with disabled '+label)
                self.assertIn(label, result.stderr)


class TextEncodingTest(unittest.TestCase):
    def setUp(self):
        import io
        import tempfile
        from unittest import mock
        temp = tempfile.TemporaryDirectory(prefix='studio-text-codec-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        original_open = io.open
        # macOS has no CP1252 locale. Resolve only omitted/default encodings
        # to that real codec; explicit UTF-8 must pass through unchanged.
        def cp1252_open(file, mode='r', buffering=-1, encoding=None, errors=None, newline=None, closefd=True, opener=None):
            if 'b' not in mode and encoding in (None, 'locale'):
                encoding = 'cp1252'
            return original_open(file, mode, buffering, encoding, errors, newline, closefd, opener)
        patcher = mock.patch.object(io, 'open', cp1252_open)
        patcher.start(); self.addCleanup(patcher.stop)
        witness = self.root/'default-codec.txt'
        witness.write_text('café —')
        self.assertEqual('café —'.encode('cp1252'), witness.read_bytes())

    def test_json_reads_utf8_under_cp1252_default_io(self):
        path = self.root/'request.json'
        path.write_bytes('{"label":"café — <tag>"}'.encode('utf-8'))
        self.assertEqual({'label':'café — <tag>'}, studio.load(path))
        studio.save(path, {'label':'café — <tag>'})
        self.assertEqual({'label':'café — <tag>'}, studio.load(path))

    def test_catalog_cli_reads_kotlin_and_writes_checks_utf8_html(self):
        import contextlib
        import io
        import sys
        from unittest import mock
        home = self.root/'design-studio'; home.mkdir()
        authority = self.root/'android/scripts/check-design.py'
        authority.parent.mkdir(parents=True)
        authority.write_bytes(b'print("HARNESS ONLY authority")')
        component = self.root/'android/designsystem/src/main/kotlin/Components.kt'
        component.parent.mkdir(parents=True)
        component.write_bytes('@Composable fun SoundQButton(label: String = "café <tag>") {}\n'.encode('utf-8'))
        feature = self.root/'android/app/src/main/kotlin/Feature.kt'
        feature.parent.mkdir(parents=True)
        feature.write_bytes('SoundQButton("café", {})'.encode('utf-8'))
        output = home/'generated'
        with mock.patch.object(studio,'ROOT',self.root), mock.patch.object(studio,'HOME',home):
            data = studio.catalog()
            self.assertIn('café <tag>', data['components'][0]['signature'])
            for action in ('generate','check'):
                with mock.patch.object(sys,'argv',['studio.py','catalog',action,'--output',str(output)]), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(0, studio.main())
            rendered = (output/'index.html').read_bytes().decode('utf-8')
            self.assertIn('café &lt;tag&gt;', rendered)
            self.assertNotIn('<tag>', rendered)
            with mock.patch.object(sys,'argv',['studio.py','check','adoption','--catalog',str(output/'catalog.json'),'--source',str(feature.relative_to(self.root))]), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(0, studio.main())

    def test_report_writes_valid_utf8_nonascii_html_and_keeps_escaping(self):
        captures = self.root/'captures'; captures.mkdir()
        baselines = self.root/'baselines'; baselines.mkdir()
        studio.write_png(captures/'components-harness.png',1,1,bytes([0,0,0,255]))
        result = {'kind':'harness-only','status':'café <tag>', 'environment':{},'sources':{},
                  'cases':[{'id':'components-harness','sha256':studio.digest((captures/'components-harness.png').read_bytes())}]}
        output = self.root/'report'
        studio.report(output,result,captures,baselines)
        rendered = (output/'index.html').read_bytes().decode('utf-8')
        self.assertIn('HARNESS ONLY — synthetic pixel evidence', rendered)
        self.assertIn('café &lt;tag&gt;', rendered)
        self.assertNotIn('<tag>', rendered)

if __name__ == '__main__': unittest.main()
