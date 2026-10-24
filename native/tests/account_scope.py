#!/usr/bin/env python3
"""Auth-intent lifetime at real ABI. Legacy envelope fallback for causal RED.
An unsupported envelope is recorded as discovery, then the same dispatch is
retried without only that metadata so the predecessor's resurrection executes.
No HTTP mutation is repeated: invalid_command never enters the core.
"""
import os
import sys
import tempfile
import threading
import unittest
sys.path.insert(0, os.environ['SOUNDQ_REPAIR_PROBES'])
import repair_support as p


def scoped(h, epoch, scope, command, **values):
    result = p.call(h, epoch, command, account_scope_v1=scope, **values)
    if result.get('code') == 'invalid_command':
        return p.call(h, epoch, command, **values)
    return result


class AccountScope(unittest.TestCase):
    def test_held_a_rotation_cannot_reappear_after_actual_b_login(self):
        with p.Server() as s, tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            h=p.new_core(s,tmp)
            worker=None
            try:
                first=scoped(h,1,1,'restore',access_token='synthetic-access',refresh_token='synthetic-refresh',account_id='synthetic-account')
                self.assertTrue(first['ok'])
                s.want401=True;s.hold_library=True
                replies=[]
                worker=threading.Thread(target=lambda:replies.append(scoped(h,1,1,'library',offset=0,query='',sort='title',order='asc')))
                worker.start();self.assertTrue(s.entered.wait(3));self.assertEqual(s.refreshes,2)
                epoch=p.C.sq_core_revoke(h);s.release.set();worker.join(5)
                self.assertFalse(worker.is_alive())
                self.assertNotIn('credentials',replies[0])
                switched=scoped(h,epoch,2,'login',email='dummy@example.invalid',password='dummy')
                self.assertTrue(switched['ok'])
                self.assertEqual(switched['credentials']['account_id'],'synthetic-account-b')
                current=scoped(h,epoch,2,'credentials')
                self.assertEqual(current['credentials']['refresh_token'],'synthetic-b-refresh')
                stale=scoped(h,epoch,1,'credentials')
                self.assertNotIn('credentials',stale,'A cannot regain secrets after B login')
                self.assertEqual(scoped(h,epoch,2,'credentials')['credentials']['account_id'],'synthetic-account-b')
            finally:
                s.release.set()
                if worker:worker.join(5)
                p.C.sq_core_close(h)

    def test_scoped_logout_dispatches_exactly_one_best_effort_write(self):
        with p.Server() as s, tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            h=p.new_core(s,tmp)
            try:
                self.assertTrue(scoped(h,1,1,'restore',access_token='synthetic-access',refresh_token='synthetic-refresh',account_id='synthetic-account')['ok'])
                epoch=p.C.sq_core_revoke(h)
                result=scoped(h,epoch,2,'logout')
                self.assertTrue(result['ok'])
                self.assertEqual(s.logouts,1, 'scope retirement must not suppress the explicit logout write')
                self.assertNotIn('credentials', scoped(h,epoch,2,'snapshot'))
            finally:
                p.C.sq_core_close(h)

    def test_cancelled_queued_account_intent_cannot_revive_previous_account(self):
        with p.Server() as s, tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            h = p.new_core(s, tmp)
            try:
                first = scoped(h, 1, 1, 'restore', access_token='synthetic-old-access',  # dummy loopback only
                               refresh_token='synthetic-old-refresh', account_id='synthetic-account')
                self.assertTrue(first['ok'])
                # Auth switch captured scope 2 and epoch 2, but selection advances
                # playback before its queued login enters the core. No login IO.
                login_epoch = p.C.sq_core_revoke(h)
                selection_epoch = p.C.sq_core_revoke(h)
                cancelled = scoped(h, login_epoch, 2, 'login', email='dummy@example.invalid', password='dummy')
                self.assertEqual(cancelled['code'], 'cancelled')
                current = scoped(h, selection_epoch, 2, 'credentials')
                self.assertFalse(current['snapshot']['authenticated'], 'cancelled account intent must retire A')
                self.assertNotIn('credentials', current, 'same selection must never revive A credentials')
                # A late A consumer cannot publish secrets or retire the newer scope.
                stale = scoped(h, selection_epoch, 1, 'credentials')
                self.assertNotIn('credentials', stale)
            finally:
                p.C.sq_core_close(h)


if __name__ == '__main__':
    unittest.main(verbosity=2)
