#!/usr/bin/env python3
"""Additive envelope must retain the strict command boundary; no network."""
import os
import sys
import tempfile
import unittest
sys.path.insert(0, os.environ['SOUNDQ_REPAIR_PROBES'])
import repair_support as p


class Envelope(unittest.TestCase):
    def test_duplicate_command_fields_remain_rejected(self):
        with tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            h=p.C.sq_core_open(b'http://127.0.0.1:1/api/v1',os.fsencode(tmp))
            try:
                for raw in [b'{"command":"pause","command":"snapshot"}',
                            b'{"command":"pause","account_scope_v1":1,"account_scope_v1":2}',
                            b'{"command":"acknowledge_credentials","version":1,"version":2}']:
                    with self.subTest(raw=raw):
                        self.assertEqual(p.take(p.C.sq_core_execute(h,1,raw))['code'],'invalid_command')
                for scope in [0,-1,1.5,True,None,'1']:
                    self.assertEqual(p.call(h,1,'snapshot',account_scope_v1=scope)['code'],'invalid_command')
                self.assertTrue(p.call(h,1,'snapshot',account_scope_v1=1)['ok'])
            finally:
                p.C.sq_core_close(h)


if __name__=='__main__':
    unittest.main(verbosity=2)
