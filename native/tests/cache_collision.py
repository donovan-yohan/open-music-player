#!/usr/bin/env python3
"""Immutable-cache C ABI regressions; synthetic loopback, never a decoder."""
import os
import sys
import tempfile
import unittest
sys.path.insert(0, os.environ['SOUNDQ_REPAIR_PROBES'])
import repair_support as p


class CacheCollision(unittest.TestCase):
    def exercise(self, retry=False, intact=False):
        with p.Server() as s, tempfile.TemporaryDirectory(dir=p.OUT / 'tmp') as tmp:
            h = p.new_core(s, tmp)
            try:
                self.assertTrue(p.restore(h)['ok'])
                self.assertTrue(p.library(h, 1)['ok'])
                first = p.call(h, 1, 'select', track_id=1)
                path = p.Path(first['audio']['path'])
                before = s.body if intact else b'X' * len(s.body)
                path.write_bytes(before)
                # Force a descriptor transfer even when an identical immutable
                # destination already exists, independently of a valid warm row.
                if intact:
                    path.with_name('1.json').unlink()
                inode = path.stat().st_ino
                result = p.call(h, 1, 'retry') if retry else p.call(h, 1, 'select', track_id=1)
                self.assertEqual(s.downloads, 2, 'must reach actual second asset transfer')
                self.assertEqual(s.descriptors, 2)
                self.assertEqual(path.read_bytes(), before, 'possibly leased old bytes must survive')
                self.assertEqual(path.stat().st_ino, inode, 'never replace a leased inode')
                self.assertEqual(list(path.parent.glob('*.partial')), [])
                if intact:
                    self.assertTrue(result['ok'])
                    self.assertEqual(p.Path(result['audio']['path']), path)
                    self.assertEqual(path.read_bytes(), s.body)
                    warm = p.call(h, 1, 'select', track_id=1)
                    self.assertTrue(warm['audio']['cached'])
                    self.assertEqual(s.downloads, 2)
                elif result['ok']:
                    self.assertEqual(p.Path(result['audio']['path']).read_bytes(), s.body,
                                     'ok/load must never return corrupted bytes')
                    self.assertNotEqual(p.Path(result['audio']['path']), path)
                else:
                    self.assertNotIn('audio', result)
            finally:
                p.C.sq_core_close(h)

    def test_corrupt_collision_refuses_or_delivers_new_verified_immutable_path(self):
        self.exercise()

    def test_retry_revalidates_potentially_corrupt_delivered_path(self):
        self.exercise(retry=True)

    def test_identical_destination_can_be_shared_without_replacement(self):
        self.exercise(intact=True)


if __name__ == '__main__':
    unittest.main(verbosity=2)
