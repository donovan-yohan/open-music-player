#!/usr/bin/env python3
"""Planner/privacy regressions. Pure source import: never runs a gate/network."""
from pathlib import Path
import importlib.machinery
import importlib.util
import sys
import unittest
ROOT = Path(__file__).resolve().parents[2]
loader = importlib.machinery.SourceFileLoader('repair_cycle', str(ROOT/'scripts/agentic-cycle'))
spec = importlib.util.spec_from_loader(loader.name, loader)
assert spec is not None
cycle = importlib.util.module_from_spec(spec)
sys.modules[loader.name] = cycle
loader.exec_module(cycle)


class Planner(unittest.TestCase):
    def test_each_affected_component_keeps_its_device_gate(self):
        for components in [{'client'}, {'native'}, {'native', 'client'}, {'native', 'client', 'backend'}]:
            for include in [False, True]:
                for required in [False, True]:
                    with self.subTest(components=components, include=include, required=required):
                        auto, manual = cycle.plan_gates(components, include_build=False, include_smoke=False,
                                                       include_device=include, requires_android_dogfood=required)
                        automatic = {g.command for g in auto}
                        held = {g.command for g in manual}
                        dogfood = ('scripts/dogfood-android', 'all')
                        flutter = 'client' in components
                        self.assertEqual(dogfood in automatic, flutter and include)
                        self.assertEqual(dogfood in held, flutter and required and not include)
                        self.assertEqual(('scripts/test', 'native') in automatic, 'native' in components)
                        if 'native' in components:
                            native = [g for g in manual if g.command == ('python3', 'scripts/native-client', 'all')]
                            self.assertEqual(len(native), 1)
                            self.assertIn('build/test only', native[0].reason)
                            self.assertIn('runtime', native[0].reason)

    def test_actual_mixed_audio_paths_classify_both(self):
        files = ['native/core/src/lib.rs', 'client/lib/core/audio/playback_state.dart']
        self.assertEqual(cycle.components_for(files), {'native', 'client'})
        self.assertTrue(cycle.needs_mobile_audio_device(files))


class PreviewDefaults(unittest.TestCase):
    def test_neutral_defaults_preserve_explicit_override(self):
        mac = (ROOT/'native/macos/Sources/main.swift').read_text()
        android = (ROOT/'native/android/app/build.gradle.kts').read_text()
        self.assertTrue('environment["OMP_API_BASE_URL"] ?? "http://127.0.0.1:8080/api/v1"' in mac, 'macOS neutral default with explicit override')
        self.assertTrue('providers.environmentVariable("OMP_API_BASE_URL").getOrElse("http://10.0.2.2:8080/api/v1")' in android, 'Android neutral default with explicit override')
        for text in [mac, android]:
            self.assertNotIn('.ts.net', text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
