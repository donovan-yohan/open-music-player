#!/usr/bin/env python3
"""Held refresh-response account lifetime at real ABI; synthetic HTTP only."""
import json
import os
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, os.environ['SOUNDQ_REPAIR_PROBES'])
import repair_support as p


class RefreshResponse(unittest.TestCase):
    def test_selection_while_existing_account_refresh_response_is_held(self):
        entered = threading.Event()
        release = threading.Event()
        refreshes = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                refreshes.append(True)
                if len(refreshes) == 2:
                    entered.set()
                    assert release.wait(5)
                data = json.dumps({'accessToken':f'synthetic-access-{len(refreshes)}',
                                   'refreshToken':f'synthetic-refresh-{len(refreshes)}',
                                   'user':{'id':'synthetic-account'}}).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def do_GET(self):
                data = b'{"tracks":[],"total":0,"offset":0}'
                status = 401 if len(refreshes) == 1 else 200
                self.send_response(status)
                self.send_header('Content-Length',str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        http = ThreadingHTTPServer(('127.0.0.1',0),Handler)
        server = threading.Thread(target=http.serve_forever,daemon=True)
        server.start()
        with tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            h = p.C.sq_core_open(f'http://127.0.0.1:{http.server_port}/api/v1'.encode(),os.fsencode(tmp))
            worker = None
            try:
                self.assertTrue(p.restore(h)['ok'])
                replies=[]
                worker=threading.Thread(target=lambda: replies.append(p.library(h,1)))
                worker.start()
                self.assertTrue(entered.wait(3))
                epoch=p.C.sq_core_revoke(h)
                release.set();worker.join(5)
                self.assertEqual(replies[0]['code'],'cancelled')
                self.assertNotIn('credentials',replies[0])
                current=p.call(h,epoch,'snapshot')
                self.assertEqual(current.get('credentials',{}).get('refresh_token'),'synthetic-refresh-2',
                                 'existing-account rotation survives selection during refresh response')
            finally:
                release.set()
                if worker:worker.join(5)
                p.C.sq_core_close(h)
                http.shutdown();http.server_close();server.join(3)


if __name__=='__main__':
    unittest.main(verbosity=2)
