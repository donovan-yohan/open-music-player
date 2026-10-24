#!/usr/bin/env python3
"""Core C-ABI credential delivery/ack regression; synthetic loopback only.
Run with SOUNDQ_REPAIR_PROBES pointing to the isolated reviewer helper directory.
No app, platform store, private account or automatic endpoint access.
"""
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
sys.path.insert(0, os.environ['SOUNDQ_REPAIR_PROBES'])
import repair_support as p


class CredentialDelivery(unittest.TestCase):
    def test_delivery_is_not_durable_ack_and_stale_ack_cannot_clear_rotation(self):
        with p.Server() as s, tempfile.TemporaryDirectory(dir=p.OUT / 'tmp') as tmp:
            h = p.new_core(s, tmp)
            try:
                first = p.restore(h)
                again = p.call(h, 1, 'snapshot')
                self.assertIn('credentials', again, 'delivery is not a durable storage acknowledgement')
                version = again['credentials']['version']
                self.assertEqual(first['credentials']['version'], version)
                ack = p.call(h, 1, 'acknowledge_credentials', version=version)
                self.assertTrue(ack['ok'])
                self.assertNotIn('credentials', p.call(h, 1, 'snapshot'))
                self.assertTrue(p.library(h, 1)['ok'])
                s.want401 = True
                self.assertTrue(p.library(h, 1)['ok'])
                rotated = p.call(h, 1, 'snapshot')['credentials']
                self.assertGreater(rotated['version'], version)
                p.call(h, 1, 'acknowledge_credentials', version=version)
                self.assertEqual(p.call(h, 1, 'snapshot')['credentials'], rotated)
                p.call(h, 1, 'acknowledge_credentials', version=rotated['version'])
                self.assertNotIn('credentials', p.call(h, 1, 'snapshot'))
            finally:
                p.C.sq_core_close(h)

    def test_pending_rotation_retires_on_logout_and_cannot_revive_after_restore(self):
        with p.Server() as s, tempfile.TemporaryDirectory(dir=p.OUT / 'tmp') as tmp:
            h = p.new_core(s, tmp)
            try:
                first = p.restore(h)['credentials']
                epoch = p.C.sq_core_revoke(h)
                self.assertTrue(p.call(h, epoch, 'logout')['ok'])
                self.assertNotIn('credentials', p.call(h, epoch, 'snapshot'))
                restored = p.call(h, epoch, 'restore', access_token='synthetic-access',
                                  refresh_token='synthetic-refresh', account_id='synthetic-account')
                new = restored['credentials']
                self.assertTrue('version' in new, 'new credential lifetime must have a durable acknowledgement identity')
                self.assertGreater(new['version'], first['version'])
                p.call(h, epoch, 'acknowledge_credentials', version=first['version'])
                self.assertEqual(p.call(h, epoch, 'snapshot')['credentials'], new)
            finally:
                p.C.sq_core_close(h)


if __name__ == '__main__':
    unittest.main(verbosity=2)
