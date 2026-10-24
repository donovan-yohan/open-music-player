#!/usr/bin/env python3
"""Causal shared-root cache invariants through real C ABI and loopback HTTP.
Positive created-file observations gate transfers; no decoder or native launch.
"""
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.environ['SOUNDQ_REPAIR_PROBES'])
import repair_support as p

A = b'A' * 4096
B = b'B' * 4096


def observe_partial(root, before, prefix=A[:64]):
    deadline = time.monotonic() + 3
    while True:
        for path in set(Path(root).rglob('*.partial')) - before:
            try:
                if path.stat().st_size == 64 and path.read_bytes() == prefix:
                    return path, path.stat().st_ino
            except FileNotFoundError:
                pass
        assert time.monotonic() < deadline, 'positive production first 64-byte write not observed'
        time.sleep(.005)  # Bounded positive filesystem observation only.


class Transfers:
    def __init__(self, same=False, fail=False, hold_b=False):
        self.release = threading.Event()
        self.release_b = threading.Event()
        self.entered_b = threading.Event()
        self.hold_b = hold_b
        self.entered = threading.Event()
        self.descriptors = 0
        self.assets = 0
        self.same = same
        self.fail = fail
        self.errors = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def respond(self, value):
                data = json.dumps(value).encode()
                self.send_response(200)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                if self.path.endswith('/refresh'):
                    self.respond({'accessToken': 'dummy-a', 'refreshToken': 'dummy-r',
                                  'user': {'id': 'synthetic-account'}})
                elif self.path.endswith('/playback/urls'):
                    owner.descriptors += 1
                    asset = 'a' if owner.descriptors == 1 else 'b'
                    self.respond({'urls': [{'trackId': 1,
                        'url': owner.endpoint.removesuffix('/api/v1') + f'/asset-{asset}.wav',
                        'contentType': 'audio/wav', 'sizeBytes': len(A),
                        'etag': asset, 'storageKeyVersion': 'v1'}]})
                else:
                    raise AssertionError('unexpected POST')

            def do_GET(self):
                if self.path.startswith('/api/v1/library?'):
                    self.respond({'tracks': [{'id': 1, 'title': 'Synthetic', 'duration_ms': 30000}],
                                  'total': 1, 'offset': 0})
                    return
                assert self.path in ['/asset-a.wav', '/asset-b.wav']
                owner.assets += 1
                self.send_response(200)
                self.send_header('Content-Length', str(len(A)))
                self.end_headers()
                if self.path == '/asset-a.wav':
                    self.wfile.write(A[:64])
                    self.wfile.flush()
                    owner.entered.set()
                    if not owner.release.wait(8):
                        owner.errors.append('held transport deadline')
                        return
                    if owner.fail:
                        self.close_connection = True
                        return
                    self.wfile.write(A[64:])
                else:
                    body = A if owner.same else B
                    if owner.hold_b:
                        self.wfile.write(body[:64])
                        self.wfile.flush()
                        owner.entered_b.set()
                        if not owner.release_b.wait(8):
                            owner.errors.append('peer held transport deadline')
                            return
                        self.wfile.write(body[64:])
                    else:
                        self.wfile.write(body)
                self.wfile.flush()

        self.http = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.endpoint = f'http://127.0.0.1:{self.http.server_port}/api/v1'
        self.server = threading.Thread(target=self.http.serve_forever, daemon=True)

    def __enter__(self):
        self.server.start()
        return self

    def __exit__(self, *args):
        self.release.set()
        self.release_b.set()
        self.http.shutdown()
        self.http.server_close()
        self.server.join(3)


def open_core(endpoint, root):
    h = p.C.sq_core_open(endpoint.encode(), os.fsencode(root))
    assert h
    assert p.restore(h)['ok'] and p.library(h, 1)['ok']
    return h


def process_select(endpoint, root):
    h = open_core(endpoint, root)
    try:
        print(json.dumps(p.call(h, 1, 'select', track_id=1)), flush=True)
    finally:
        p.C.sq_core_close(h)


class CacheStageOwnership(unittest.TestCase):
    def exercise(self, same=False, cancel=False, fail=False, child=False):
        with Transfers(same=same, fail=fail) as s, tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            handles = []
            worker = None
            proc = None
            replies = []
            try:
                # Same endpoint/account/root, two independent epoch-1 owners.
                handles.append(open_core(s.endpoint, tmp))
                if not child:
                    handles.append(open_core(s.endpoint, tmp))
                before = set(Path(tmp).rglob('*.partial'))
                worker = threading.Thread(target=lambda: replies.append(p.call(handles[0], 1, 'select', track_id=1)))
                worker.start()
                self.assertTrue(s.entered.wait(3))
                stage, stage_inode = observe_partial(tmp, before)
                if child:
                    proc = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                             '--select', s.endpoint, tmp], env=dict(os.environ),
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                    stdout, stderr = proc.communicate(timeout=5)
                    self.assertEqual(proc.returncode, 0, stderr)
                    delivered = json.loads(stdout)
                else:
                    delivered = p.call(handles[1], 1, 'select', track_id=1)
                self.assertTrue(delivered['ok'], delivered['code'])
                self.assertEqual(delivered['audio']['action'], 'load')
                path = Path(delivered['audio']['path'])
                expected = A if same else B
                inode = path.stat().st_ino
                self.assertEqual(path.read_bytes(), expected, 'B initially receives verified bytes')
                if cancel:
                    self.assertEqual(p.C.sq_core_revoke(handles[0]), 2)
                s.release.set()
                worker.join(5)
                self.assertFalse(worker.is_alive())
                after = path.read_bytes()
                result = {'case': {'same': same, 'cancel': cancel, 'fail': fail, 'child': child},
                          'first_reply': replies[0]['code'], 'second_reply': delivered['code'],
                          'audio_action': delivered['audio']['action'], 'first_partial_bytes': 64,
                          'first_stage_inode': stage_inode, 'delivered_inode': inode,
                          'delivered_inode_stable': path.stat().st_ino == inode,
                          'delivered_bytes_stable': after == expected,
                          'descriptors': s.descriptors, 'assets': s.assets}
                print(json.dumps(result, sort_keys=True), flush=True)
                # First causal assertion: identical test fails here on round1.
                self.assertEqual(after, expected, 'CACHE-STAGE-1: later writer mutated delivered bytes')
                self.assertEqual(path.stat().st_ino, inode)
                self.assertNotEqual(stage_inode, inode, 'separate live transfers must not share a writable inode')
                self.assertEqual((s.descriptors, s.assets), (2, 2))
                self.assertEqual(s.errors, [])
                if cancel or fail:
                    self.assertFalse(replies[0]['ok'])
                    self.assertNotIn('audio', replies[0])
                    self.assertEqual(replies[0]['code'], 'cancelled' if cancel else 'download_failed')
                else:
                    self.assertTrue(replies[0]['ok'], replies[0]['code'])
                    first_path = Path(replies[0]['audio']['path'])
                    self.assertEqual(first_path.read_bytes(), A)
                    self.assertEqual(first_path == path, same)
                self.assertFalse(list(Path(tmp).rglob('*.partial')))
                self.assertFalse(list(Path(tmp).rglob('*.pending')))
                index = json.loads(path.with_name('1.json').read_text())
                indexed = path.parent/index['name']
                self.assertEqual(hashlib.sha256(indexed.read_bytes()).hexdigest(), index['sha256'])
                self.assertEqual(indexed.read_bytes(), expected if cancel or fail else A)
            finally:
                s.release.set()
                if worker:
                    worker.join(5)
                    assert not worker.is_alive()
                if proc and proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=3)
                for h in handles:
                    p.C.sq_core_close(h)

    def test_index_publication_failure_cleans_only_owned_temporaries(self):
        with p.Server() as s, tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            h = open_core(s.endpoint, tmp)
            try:
                account = hashlib.sha256((s.endpoint+'\0synthetic-account').encode()).hexdigest()
                directory = Path(tmp)/account
                directory.mkdir(exist_ok=True)
                (directory/'1.json').mkdir()  # Force rename failure after verified audio publication.
                foreign = directory/'foreign.json.pending'
                foreign.write_bytes(b'foreign-owned-stale-bytes')
                inode = foreign.stat().st_ino
                result = p.call(h, 1, 'select', track_id=1)
                self.assertEqual(result['code'], 'cache_io')
                self.assertNotIn('audio', result)
                self.assertEqual((s.downloads, s.descriptors), (1, 1))
                self.assertEqual(foreign.read_bytes(), b'foreign-owned-stale-bytes')
                self.assertEqual(foreign.stat().st_ino, inode)
                self.assertEqual(list(directory.glob('*.pending')), [foreign])
                self.assertFalse(list(directory.glob('*.partial')))
                final = directory/f'1-{hashlib.sha256(s.body).hexdigest()}.wav'
                self.assertEqual(final.read_bytes(), s.body, 'failed index publication must not unlink immutable audio')
            finally:
                p.C.sq_core_close(h)

    def test_cancelled_transfer_cleanup_preserves_peer_live_stage(self):
        with Transfers(hold_b=True) as s, tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            handles = []
            workers = []
            replies = [[], []]
            try:
                handles = [open_core(s.endpoint, tmp), open_core(s.endpoint, tmp)]
                initial = set(Path(tmp).rglob('*.partial'))
                observed = []
                for i in range(2):
                    worker = threading.Thread(target=lambda i=i: replies[i].append(p.call(handles[i], 1, 'select', track_id=1)))
                    workers.append(worker)
                    worker.start()
                    self.assertTrue((s.entered if i == 0 else s.entered_b).wait(3))
                    observed.append(observe_partial(tmp, initial, A[:64] if i == 0 else B[:64]))
                (stage_a, inode_a), (stage_b, inode_b) = observed
                self.assertEqual(p.C.sq_core_revoke(handles[0]), 2)
                s.release.set()
                workers[0].join(5)
                self.assertFalse(workers[0].is_alive())
                self.assertEqual(replies[0][0]['code'], 'cancelled')
                self.assertTrue(stage_b.exists(), 'A cleanup must not unlink a live peer stage')
                self.assertEqual(stage_b.stat().st_ino, inode_b)
                self.assertEqual(stage_b.read_bytes(), B[:64], 'A must not write into peer stage')
                self.assertNotEqual(inode_a, inode_b)
                self.assertFalse(stage_a.exists())
                s.release_b.set()
                workers[1].join(5)
                self.assertFalse(workers[1].is_alive())
                self.assertTrue(replies[1][0]['ok'])
                self.assertEqual(Path(replies[1][0]['audio']['path']).read_bytes(), B)
                self.assertEqual((s.descriptors, s.assets), (2, 2))
                self.assertFalse(list(Path(tmp).rglob('*.partial')))
                self.assertFalse(list(Path(tmp).rglob('*.pending')))
                self.assertEqual(s.errors, [])
            finally:
                s.release.set()
                s.release_b.set()
                for worker in workers:
                    worker.join(5)
                    assert not worker.is_alive()
                for h in handles:
                    p.C.sq_core_close(h)

    def test_foreign_stale_stage_and_index_temporaries_survive_exclusive_allocation(self):
        with p.Server() as s, tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            proc = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
                                     '--foreign-select', s.endpoint, tmp], env=dict(os.environ),
                                    stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True)
            try:
                assert proc.stdout is not None
                with selectors.DefaultSelector() as ready_selector:
                    ready_selector.register(proc.stdout, selectors.EVENT_READ)
                    self.assertTrue(ready_selector.select(timeout=3), 'child readiness deadline')
                    ready = json.loads(proc.stdout.readline())
                account = hashlib.sha256((s.endpoint+'\0synthetic-account').encode()).hexdigest()
                directory = Path(tmp)/account
                directory.mkdir(exist_ok=True)
                # Fresh subprocess starts its allocator at zero. Seed exact
                # candidates plus the rejected shared legacy temporary names.
                names = ['1-1.partial', '1.json.pending',
                         f'1-1-{ready["pid"]}-0.partial',
                         f'1-1-{ready["pid"]}-2.json.pending']
                foreign = {}
                for name in names:
                    path = directory/name
                    path.write_bytes(b'foreign-owned-stale-bytes')
                    foreign[path] = (path.read_bytes(), path.stat().st_ino)
                stdout, stderr = proc.communicate('continue\n', timeout=5)
                self.assertEqual(proc.returncode, 0, stderr)
                delivered = json.loads(stdout)
                self.assertTrue(delivered['ok'], delivered['code'])
                self.assertEqual(Path(delivered['audio']['path']).read_bytes(), s.body)
                for path, (data, inode) in foreign.items():
                    self.assertTrue(path.exists(), 'another owner temporary must survive cleanup')
                    self.assertEqual(path.read_bytes(), data)
                    self.assertEqual(path.stat().st_ino, inode)
                self.assertEqual(set(directory.glob('*.partial')) | set(directory.glob('*.pending')), set(foreign))
                index = json.loads((directory/'1.json').read_text())
                self.assertEqual(hashlib.sha256((directory/index['name']).read_bytes()).hexdigest(), index['sha256'])
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=3)

    def test_two_handles_different_versions_keep_delivered_bytes_immutable(self):
        self.exercise()

    def test_two_processes_different_versions_keep_delivered_bytes_immutable(self):
        self.exercise(child=True)

    def test_same_content_concurrent_transfers_share_verified_immutable_destination(self):
        self.exercise(same=True)

    def test_cancelled_transfer_cannot_mutate_or_remove_peer_delivery(self):
        self.exercise(cancel=True)

    def test_failed_transfer_cannot_mutate_or_remove_peer_delivery(self):
        self.exercise(fail=True)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--select':
        process_select(sys.argv[2], sys.argv[3])
    elif len(sys.argv) > 1 and sys.argv[1] == '--foreign-select':
        h = open_core(sys.argv[2], sys.argv[3])
        try:
            print(json.dumps({'pid': os.getpid()}), flush=True)
            assert sys.stdin.readline() == 'continue\n'
            print(json.dumps(p.call(h, 1, 'select', track_id=1)), flush=True)
        finally:
            p.C.sq_core_close(h)
    else:
        unittest.main(verbosity=2)
