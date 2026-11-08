#!/usr/bin/env python3
"""Source/export acceptance only; no Android compilation or UI acceptance.
Run python3 -B scripts/build_tokens.py then python3 -B scripts/test_tokens.py.
All negative cases are in memory; drift checks never modify generated files.
"""
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import re
import sys
import unittest
from typing import cast
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
import build_tokens as build

SOURCE = build.load_source()


def token(kind, value):
    return {'$type': kind, '$value': value}


def runtime(outputs):
    text = outputs['tokens.runtime.js']
    return json.loads(text.split('Object.freeze(', 1)[1].rsplit(');', 1)[0])


class TokenTests(unittest.TestCase):
    def test_canonical_source_and_aliases(self):
        resolved = build.resolve(SOURCE)
        self.assertGreater(len(resolved), 200)
        self.assertEqual(resolved['component.button.primaryBackground'], resolved['primitive.color.orange'])
        self.assertEqual(resolved['component.button.corner'][1], {'value': 0, 'unit': 'px'})
        self.assertEqual(resolved['component.button.targetMin'][1]['value'], 48)
        self.assertEqual(resolved['semantic.dimension.rhythm'][1]['value'], 4)
        self.assertIn('proposed', SOURCE['$extensions']['org.soundq']['fontsStatus'])
        def walk(group, path=''):
            for name, child in group.items():
                if name.startswith('$'):
                    continue
                child_path = path + '.' + name if path else name
                if '$value' in child:
                    if child_path.startswith(('semantic.', 'component.', 'motion.')):
                        self.assertRegex(child['$value'], r'^\{[^{}]+\}$', child_path)
                else:
                    walk(child, child_path)
        walk(SOURCE)

    def test_exact_runtime_contract(self):
        actual = runtime(build.render(SOURCE))
        expected = {
            'motion.duration.quick': 120, 'motion.duration.settle': 180,
            'motion.duration.sheet': 260, 'motion.duration.page': 280,
            'motion.duration.list': 180, 'motion.duration.exit': 160,
            'motion.duration.reduced': 0,
            'motion.easing.standard': [0.2, 0, 0, 1],
            'motion.easing.exit': [0.4, 0, 1, 1],
            'motion.gesture.slop': 8, 'motion.gesture.axisRatio': 1.25,
            'motion.row.reveal': 112, 'motion.row.commitProgress': 0.5,
            'motion.sheet.medium': 0.62, 'motion.sheet.full': 0.94,
            'motion.sheet.dismissProgress': 0.22,
            'motion.sheet.dismissVelocity': 0.6, 'motion.scrim.opacity': 0.64,
            'semantic.color.primary': '#FF5A00', 'semantic.color.focus': '#39C6B6',
            'semantic.font.family.display': 'Space Grotesk',
            'semantic.font.family.technical': 'IBM Plex Mono',
        }
        for path, value in expected.items():
            self.assertEqual(actual[path], value, path)
        self.assertNotRegex(json.dumps(actual), r'\{[A-Za-z][^}]*\}')
        self.assertEqual(set(actual), set(build.resolve(SOURCE)))

    def test_reference_palette_and_type_preserved(self):
        # Read-only check against the current reference, not the preserved checkpoint.
        css = (build.ROOT / 'reference/reference.css').read_text()
        source_vars = dict(re.findall(r'--([a-z-]+):(#\w+)', css))
        values = runtime(build.render(SOURCE))
        for key in ('bg', 'surface', 'raised', 'ink', 'muted', 'rule', 'input', 'orange', 'cyan', 'error'):
            self.assertEqual(values['primitive.color.' + key], source_vars[key].upper())
        # All opaque CSS hex literals, including secondary states, are collected.
        collected = {v for p, v in values.items() if p.startswith('primitive.color.')}
        for color in set(re.findall(r'#[0-9a-fA-F]{6}\b', css)):
            self.assertIn(color.upper(), collected)
        self.assertIn('SpaceGrotesk-Regular.ttf', css)
        self.assertIn('IBMPlexMono-Regular.ttf', css)
        self.assertEqual(values['semantic.fontSize.h1'], 32)
        self.assertAlmostEqual(values['semantic.fontSize.mono'], 11.52)

    def test_forward_multihop_alias_and_inheritance(self):
        doc = {'$type': 'number', 'a': {'$value': '{b}'}, 'b': {'$value': '{c}'}, 'c': {'$value': 7}}
        self.assertEqual(build.resolve(doc)['a'], ('number', 7))

    def test_alias_cycles(self):
        for doc in ({'a': token('number', '{a}')}, {'a': token('number', '{b}'), 'b': token('number', '{a}')}):
            with self.subTest(doc=doc), self.assertRaisesRegex(build.TokenError, 'alias cycle'):
                build.resolve(doc)

    def test_missing_and_mismatched_alias(self):
        for doc in ({'a': token('number', '{missing}')}, {'a': token('number', '{b}'), 'b': token('dimension', {'value': 8, 'unit': 'px'})}):
            with self.subTest(doc=doc), self.assertRaises(build.TokenError):
                build.resolve(doc)

    def test_invalid_type_values(self):
        cases = [('color', '#FF5A00'), ('color', {'colorSpace': 'display-p3', 'components': [1, 0, 0]}),
                 ('color', {'colorSpace': 'srgb', 'components': [2, 0, 0]}),
                 ('color', {'colorSpace': 'srgb', 'components': [1, 0, 0], 'alpha': -1}),
                 ('dimension', '8px'), ('dimension', {'value': 1, 'unit': 'em'}),
                 ('dimension', {'value': True, 'unit': 'px'}), ('duration', {'value': -1, 'unit': 'ms'}),
                 ('duration', {'value': 1, 'unit': 'minutes'}), ('number', True), ('number', float('nan')),
                 ('number', float('inf')), ('fontWeight', 1001), ('fontFamily', ''), ('fontFamily', 'x; y'),
                 ('cubicBezier', [0, 1, 2, 1]), ('cubicBezier', [0, 1, 1]), ('shadow', {})]
        for kind, value in cases:
            with self.subTest(kind=kind, value=value), self.assertRaises(build.TokenError):
                build.resolve({'bad': token(kind, value)})

    def test_invalid_structure_and_export_collisions(self):
        for doc in ([], {}, {'a': 3}, {'a.b': token('number', 1)},
                    {'a': {'$value': 1}}, {'a': {'$type': 'number', '$value': 1, 'child': {}}},
                    {'a': {'$extends': '{b}'}}, {'a': {'$ref': '#/b'}},
                    {'a': token('number', 1), '$mystery': True},
                    {'axisRatio': token('number', 1), 'axis-ratio': token('number', 2)}):
            with self.subTest(doc=doc), self.assertRaises(build.TokenError):
                build.resolve(doc)

    def test_unit_conversion_and_alpha_order(self):
        doc = {'delay': token('duration', {'value': 0.18, 'unit': 's'}),
               'size': token('dimension', {'value': 1.5, 'unit': 'rem'}),
               'tint': token('color', {'colorSpace': 'srgb', 'components': [1, 0, 0], 'alpha': 0.5})}
        outputs = build.render(doc)
        self.assertEqual(runtime(outputs), {'delay': 180, 'size': 24, 'tint': '#FF000080'})
        self.assertIn('#80FF0000', outputs['soundq_design_tokens.xml'])
        self.assertIn('0x80FF0000.toInt()', outputs['SoundQDesignTokens.kt'])

    def test_css_predictable_names_and_values(self):
        css = build.render(SOURCE)['tokens.css']
        self.assertIn('--motion-duration-settle: 180ms;', css)
        self.assertIn('--motion-row-commit-progress: 0.5;', css)
        self.assertIn('--motion-row-reveal: 112px;', css)
        self.assertIn('--motion-easing-standard: cubic-bezier(0.2, 0, 0, 1);', css)
        self.assertIn('--semantic-dimension-corner: 0px;', css)
        self.assertEqual(len(re.findall(r'^  --', css, re.M)), len(build.resolve(SOURCE)))

    def test_android_exports_are_complete_and_well_formed(self):
        outputs = build.render(SOURCE)
        xml = ET.fromstring(outputs['soundq_design_tokens.xml'])
        self.assertEqual(xml.tag, 'resources')
        self.assertEqual(len(xml), len(build.resolve(SOURCE)))
        names = [node.attrib['name'] for node in xml]
        self.assertEqual(len(names), len(set(names)))
        values = {node.attrib['name']: node.text for node in xml}
        self.assertEqual(values['soundq_motion_duration_settle'], '180')
        self.assertEqual(values['soundq_semantic_dimension_target_min'], '48dp')
        self.assertEqual(values['soundq_semantic_font_size_h1'], '32sp')
        self.assertEqual(values['soundq_semantic_color_primary'], '#FFFF5A00')
        kt = outputs['SoundQDesignTokens.kt']
        self.assertIn('object SoundQDesignTokens', kt)
        self.assertIn('MOTION_DURATION_SETTLE: Int = 180', kt)
        self.assertIn('SEMANTIC_COLOR_PRIMARY: Int = 0xFFFF5A00.toInt()', kt)
        self.assertEqual(len(re.findall(r'^    (?:const val|val) ', kt, re.M)), len(xml))

    def test_compose_semantic_mapping(self):
        text = build.render(SOURCE)['SoundQComposeTokens.kt']
        self.assertIn('package soundq.design.generated', text)
        self.assertIn('SEMANTIC_COLOR_PRIMARY = Color(0xFFFF5A00L)', text)
        self.assertIn('SEMANTIC_DIMENSION_TARGET_MIN = 48.dp', text)
        self.assertIn('SEMANTIC_FONT_SIZE_H1 = 32.sp', text)
        self.assertIn('MOTION_EASING_STANDARD = CubicBezierEasing(0.2f, 0.0f, 0.0f, 1.0f)', text)
        self.assertIn('MOTION_DURATION_SETTLE: Int = 180', text)
        self.assertIn('PRIMITIVE_LETTER_SPACING_HEADING = -1.28.sp', text)
        self.assertIn('SEMANTIC_LETTER_SPACING_BRAND = -0.8496.sp', text)
        self.assertNotRegex(text, r'LETTER_SPACING_[A-Z_]+ = [-0-9.]+\.dp')
        self.assertNotIn('android.view', text)
        self.assertNotIn('nativepreview', text)
        self.assertEqual(len(re.findall(r'^    (?:const val|val) ', text, re.M)), len(build.resolve(SOURCE)))

    def test_repeatable_generation_and_disk_drift(self):
        first = build.render(SOURCE)
        self.assertEqual(first, build.render(copy.deepcopy(SOURCE)))
        reversed_source = dict(reversed(list(SOURCE.items())))
        self.assertEqual(first, build.render(reversed_source))
        for name, text in first.items():
            self.assertEqual((build.OUTPUT / name).read_bytes(), text.encode(), name)
        changed = copy.deepcopy(SOURCE)
        changed['primitive']['duration']['ms180']['$value']['value'] = 181
        self.assertNotEqual(build.render(changed)['tokens.runtime.js'], first['tokens.runtime.js'])

    def test_cli_readonly_check_pass_and_drift_failure(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(build.main(['--check']), 0)
            with patch.object(Path, 'read_text', return_value='changed generated output'), patch.object(build, 'load_source', return_value=SOURCE):
                self.assertEqual(build.main(['--check']), 1)
        self.assertIn('generated drift:', err.getvalue())
        self.assertIn('"mode": "check"', out.getvalue())

    def test_json_duplicate_and_nonfinite_rejected(self):
        for text in ('{"x": 1, "x": 2}', '{"x": NaN}', '{"x": Infinity}'):
            with self.subTest(text=text), patch.object(Path, 'read_text', return_value=text), self.assertRaises(build.TokenError):
                build.load_source()


class RecordingResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.passed = []
    def addSuccess(self, test):
        super().addSuccess(test)
        self.passed.append(test.id().split('.')[-1])


if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TokenTests)
    result = cast(RecordingResult, unittest.TextTestRunner(verbosity=2, resultclass=RecordingResult).run(suite))
    outputs = build.render(SOURCE)
    report = {'status': 'passed' if result.wasSuccessful() else 'failed',
              'scope': 'DTCG bounded source validation and export tests only; no native compilation, browser/UI or production acceptance',
              'command': 'python3 -B scripts/test_tokens.py',
              'testsRun': result.testsRun, 'passed': result.passed,
              'failures': [{'test': str(t), 'detail': detail} for t, detail in result.failures],
              'errors': [{'test': str(t), 'detail': detail} for t, detail in result.errors],
              'tokenCount': len(build.resolve(SOURCE)),
              'source': str(build.SOURCE),
              'sourceSha256': hashlib.sha256(build.SOURCE.read_bytes()).hexdigest(),
              'outputs': {str(build.OUTPUT / name): {'bytes': len(text.encode()), 'sha256': hashlib.sha256(text.encode()).hexdigest()} for name, text in outputs.items()},
              'limitations': ['Not a complete DTCG schema validator: unsupported constructs are rejected.', 'Android dimensions intentionally map CSS px to dp; font-size maps to sp.', 'Android easing exported as float array / comma-separated string, not a compiled animator resource.', 'Font families are proposed; exported font names do not bundle or register fonts.']}
    path = build.ROOT / 'evidence/token-tests.json'
    path.parent.mkdir(exist_ok=True)
    path.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'status': report['status'], 'testsRun': result.testsRun, 'failures': len(result.failures), 'errors': len(result.errors), 'tokenCount': report['tokenCount'], 'evidence': str(path)}))
    sys.exit(0 if result.wasSuccessful() else 1)
