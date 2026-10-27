#!/usr/bin/env python3
"""Cheap fail-closed extraction controls; no compiler, device or network."""
import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import queue_restore_cursor_regressions as cursor

ROOT = Path(__file__).resolve().parents[2]
# Frozen composed Library command observer/favorite-topic publication plus the
# unchanged journey/cursor getters. All missing/duplicate anchor controls remain.
VALID_PROBE_SHA256 = '91e285f7de9f6f53eb5d891e823279ac4bb12accb66f684d1655dcae267a6927'
FACADE_ANCHORS = {
    'decoder_seek': 'fun seekTo(p:Long,m:Int){currentPosition=p.toInt()}',
    'position_facade': 'fun nativePositionMs()=player?.currentPosition?.toLong() ?: 0L',
    'json_array': 'fun optJSONObject(i:Int):JSONObject?=null',
}


class CursorExtraction(unittest.TestCase):
    def test_valid_generated_probe_unchanged(self):
        text, _ = cursor.probe(ROOT)
        self.assertEqual(hashlib.sha256(text.encode()).hexdigest(), VALID_PROBE_SHA256)

    def test_real_getters_preserved_once_and_adjacent(self):
        source = (ROOT / cursor.SERVICE).read_text()
        getters = [next(line.strip().removeprefix('internal ') for line in source.splitlines()
                        if 'internal fun ' + name + '()' in line)
                   for name in ('nativePlaying', 'nativePositionMs')]
        text, _ = cursor.probe(ROOT)
        for getter in getters:
            self.assertEqual(text.count(getter), 1)
        self.assertIn('\n'.join(getters), text)

    def assert_facade_refused(self, anchor, duplicate):
        original = cursor.service.android_probe

        def changed(*args):
            text = original(*args)
            self.assertEqual(text.count(anchor), 1)
            return text.replace(anchor, anchor + ';' + anchor if duplicate else '/* missing facade anchor */')

        with patch.object(cursor.service, 'android_probe', side_effect=changed):
            with self.assertRaisesRegex(AssertionError, 'anchor.*(0|2)'):
                cursor.probe(ROOT)

    def assert_inserted_position_anchor_refused(self, duplicate):
        original = Path.read_text

        def changed(path, *args, **kwargs):
            text = original(path, *args, **kwargs)
            if path == ROOT / cursor.SERVICE:
                anchor = 'fun nativePositionMs(): Long'
                self.assertEqual(text.count(anchor), 1)
                replacement = anchor + ' /* ' + anchor + ' */' if duplicate else 'fun nativePositionMs(): kotlin.Long'
                return text.replace(anchor, replacement)
            return text

        with patch.object(Path, 'read_text', changed):
            with self.assertRaisesRegex(AssertionError, 'anchor.*(0|2)'):
                cursor.probe(ROOT)

    def test_inserted_position_anchor_missing(self):
        self.assert_inserted_position_anchor_refused(False)

    def test_inserted_position_anchor_duplicate(self):
        self.assert_inserted_position_anchor_refused(True)

    def assert_getter_refused(self, name, duplicate):
        # Only a private input copy is modified; the real producer stays untouched.
        with tempfile.TemporaryDirectory(prefix='cursor-anchor-', dir=os.environ.get('TMPDIR')) as tmp:
            root = Path(tmp)
            for relative in (cursor.JOURNEY, cursor.SERVICE):
                dest = root / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes((ROOT / relative).read_bytes())
            path = root / cursor.SERVICE
            text = path.read_text()
            line, = [line for line in text.splitlines() if 'internal fun ' + name + '()' in line]
            text = text.replace(line, line + '\n' + line if duplicate else '')
            path.write_text(text)
            with self.assertRaisesRegex(AssertionError, 'anchor.*(0|2)'):
                cursor.probe(root)


def facade_case(anchor, duplicate):
    def test(self):
        self.assert_facade_refused(anchor, duplicate)
    return test


def getter_case(name, duplicate):
    def test(self):
        self.assert_getter_refused(name, duplicate)
    return test


for label, anchor in FACADE_ANCHORS.items():
    for duplicate in (False, True):
        setattr(CursorExtraction, 'test_' + label + ('_duplicate' if duplicate else '_missing'), facade_case(anchor, duplicate))
for name in ('nativePositionMs', 'nativePlaying'):
    for duplicate in (False, True):
        setattr(CursorExtraction, 'test_' + name + ('_duplicate' if duplicate else '_missing'), getter_case(name, duplicate))


if __name__ == '__main__':
    unittest.main(verbosity=2)
