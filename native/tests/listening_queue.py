#!/usr/bin/env python3
"""Occurrence-owned queue through the real Rust C ABI and synthetic loopback IO.
No decoder, device, private account or shared fixture. Run with repair_support env.
"""
import hashlib
import argparse
import json
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import repair_support as p


def main():
    body = b'RIFF' + b'synthetic-queue-bytes' * 16
    tracks = [{'id': i, 'title': f'Queue {i}', 'duration_ms': 30000} for i in range(1, 9)]
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def respond(self, value):
            data = value if isinstance(value, bytes) else json.dumps(value).encode()
            self.send_response(200); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data)
        def do_POST(self):
            value = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or '{}')
            if self.path == '/api/v1/auth/refresh':
                self.respond({'accessToken':'synthetic-access', 'refreshToken':'synthetic-refresh', 'user':{'id':'queue-account'}})
            elif self.path == '/api/v1/playback/urls':
                self.respond({'urls':[{'trackId':i, 'url':f'http://127.0.0.1:{self.server.server_port}/asset.wav', 'contentType':'audio/wav', 'sizeBytes':len(body)} for i in value['trackIds']]})
            else: self.respond({})
        def do_GET(self):
            self.respond({'tracks': tracks, 'total':len(tracks), 'offset':0} if self.path.startswith('/api/v1/library?') else body)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
    endpoint = f'http://127.0.0.1:{server.server_port}/api/v1'
    checks = []
    def check(name, condition):
        assert condition, name
        checks.append(name); print('PASS', name, flush=True)
    try:
        with tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            root = Path(tmp)
            h = p.C.sq_core_open(endpoint.encode(), bytes(root)); epoch = 1
            def call(command, **values):
                return p.take(p.C.sq_core_execute(h, epoch, json.dumps({'command':command, **values}).encode()))
            def snapshot(): return call('snapshot')['snapshot']
            def auth(account='queue-account'):
                return call('restore', access_token='synthetic-access', refresh_token='synthetic-refresh', account_id=account)
            try:
                assert auth()['ok']; assert p.library(h, epoch)['ok']
                selected = call('select', track_id=3)
                check('visible-list-selection-all-eight-not-four', selected['ok'] and len(selected['snapshot']['queue']) == 8)
                s = selected['snapshot']; occurrence = s['selected_occurrence']; session = s['session']
                check('tapped-row-is-explicit-selected-occurrence', s['queue'][2]['id'] == occurrence)
                call('audio_report', epoch=epoch, session=session, state='playing', position_ms=6000, duration_ms=30000)
                appended = call('queue_append', track_id=3); duplicate = appended['snapshot']['queue'][-1]['id']
                check('duplicate-recording-independent-occurrence', duplicate != occurrence)
                for command, values in [('queue_move', {'occurrence_id':duplicate, 'to_index':0}), ('queue_remove', {'occurrence_id':duplicate})]:
                    r = call(command, **values)
                    check(command+'-noncurrent-keeps-session-cursor-no-effect', r['ok'] and r['snapshot']['session']==session and r['snapshot']['selected_occurrence']==occurrence and r['snapshot']['position_ms']==6000 and 'audio' not in r)
                before = snapshot()['queue']
                invalid = call('queue_move', occurrence_id=occurrence, to_index=999)
                check('invalid-move-atomic', invalid['code']=='invalid_queue_index' and snapshot()['queue']==before)
                call('pause')
                delayed=call('audio_report', epoch=epoch, session=session, state='ended', position_ms=30000, duration_ms=30000)
                check('pause-retires-delayed-same-session-eof', delayed['code']=='stale_audio_report' and snapshot()['selected_occurrence']==occurrence)
                call('resume')
                ended = call('audio_report', epoch=epoch, session=session, state='ended', position_ms=30000, duration_ms=30000)
                check('eof-advances-one-occurrence', ended['ok'] and ended['snapshot']['selected_occurrence']==before[3]['id'] and ended['audio']['action']=='load')
                late = call('audio_report', epoch=epoch, session=session, state='ended', position_ms=30000, duration_ms=30000)
                check('stale-eof-cannot-advance-twice', late['code']=='stale_audio_report' and snapshot()['selected_occurrence']==before[3]['id'])
                check('previous-through-owner', call('previous')['snapshot']['selected_occurrence']==occurrence)
                check('next-through-owner', call('next')['snapshot']['selected_occurrence']==before[3]['id'])
                removed = call('queue_remove', occurrence_id=before[3]['id'])
                check('selected-remove-picks-successor-at-zero', removed['snapshot']['selected_occurrence']==before[4]['id'] and removed['audio']['position_ms']==0)
                call('seek', position_ms=6000)
                paused = call('pause')
                check('transport-topics-omit-queue', paused['snapshot']['queue_unchanged'] and paused['snapshot']['queue']==[])
                saved = list(root.rglob('listening-queue-v1.json'))
                check('durable-account-file-has-no-credentials-or-paths', len(saved)==1 and all(x not in saved[0].read_text() for x in ['token','synthetic-access','asset.wav',str(root)]))
                p.C.sq_core_close(h); h=p.C.sq_core_open(endpoint.encode(), bytes(root)); epoch=1
                check('restart-requires-account', call('queue_restore')['code']=='unauthenticated')
                assert auth()['ok']; restored=call('queue_restore')
                check('restart-restores-paused-selection-cursor', restored['ok'] and restored['snapshot']['transport']=='paused' and restored['snapshot']['position_ms']==6000 and restored['snapshot']['selected_occurrence']==before[4]['id'] and restored['audio']['action']=='stop')
                retried=call('retry')
                check('restored-selection-remains-explicitly-retryable', retried['ok'] and retried['audio']['action']=='load')
                assert call('queue_restore')['ok']
                resumed=call('resume')
                check('explicit-resume-loads-verified-cache-at-saved-cursor', resumed['ok'] and resumed['audio']['cached'] and resumed['audio']['position_ms']==6000)
                def restored_other(other_endpoint=endpoint, account='queue-account'):
                    other=p.C.sq_core_open(other_endpoint.encode(), bytes(root))
                    try:
                        p.call(other,1,'restore',access_token='synthetic-access',refresh_token='synthetic-refresh',account_id=account)
                        return p.call(other,1,'queue_restore')
                    finally: p.C.sq_core_close(other)
                # A transient restore on an unrelated loopback endpoint still
                # establishes its own account scope, never the original queue.
                check('endpoint-scope-does-not-restore-other-queue', restored_other('http://127.0.0.1:1/api/v1')['snapshot']['queue']==[])
                check('account-mismatch-does-not-restore-queue', restored_other(account='other-account')['snapshot']['queue']==[])
                saved[0].write_bytes(b'{broken')
                selected_before=snapshot()['selected_occurrence']
                check('corrupt-restore-does-not-replace-live-queue', call('queue_restore')['code']=='invalid_saved_queue' and snapshot()['selected_occurrence']==selected_before)
                call('clear_cache')
                check('cache-clear-preserves-corrupt-queue-bytes', saved[0].read_bytes()==b'{broken')
                assert p.library(h, epoch)['ok']
                mutation=call('queue_append', track_id=3)
                check('rejected-queue-file-not-overwritten-by-mutation', mutation['code']=='invalid_saved_queue' and saved[0].read_bytes()==b'{broken')
                cleared=call('queue_clear')
                check('clear-stops-empty-selection', cleared['code']=='invalid_saved_queue' and cleared['snapshot']['queue']==[] and cleared['snapshot']['selected_occurrence'] is None and cleared['audio']['action']=='stop')
            finally: p.C.sq_core_close(h)
    finally:
        server.shutdown(); server.server_close(); thread.join(3)
    print('QUEUE_ABI_PASS', len(checks))


def storage_budget(case=None):
    """Reach the serialized envelope using only ordinary authenticated commands."""
    for title in ('t' * 16000, '\x00' * 16000):
        if case and case != ('escaped' if title[0] == '\x00' else 'ordinary'): continue
        body = b'RIFF' + b'synthetic-budget-audio' * 16
        tracks = [{'id': 1, 'title': title, 'duration_ms': 30000}]
        counts = {'descriptor': 0, 'download': 0}
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args): pass
            def respond(self, value):
                data = value if isinstance(value, bytes) else json.dumps(value).encode()
                self.send_response(200); self.send_header('Content-Length', str(len(data)))
                self.end_headers(); self.wfile.write(data)
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                if self.path.endswith('/refresh'):
                    self.respond({'accessToken':'synthetic-access', 'refreshToken':'synthetic-refresh', 'user':{'id':'synthetic-account'}})
                else:
                    counts['descriptor'] += 1
                    self.respond({'urls':[{'trackId':1, 'url':f'http://127.0.0.1:{self.server.server_port}/asset.wav', 'contentType':'audio/wav', 'sizeBytes':len(body)}]})
            def do_GET(self):
                if '/library?' in self.path:
                    from urllib.parse import urlparse, parse_qs
                    offset = int(parse_qs(urlparse(self.path).query)['offset'][0])
                    self.respond({'tracks':tracks, 'total':100, 'offset':offset})
                else:
                    counts['download'] += 1; self.respond(body)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            with tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
                root = Path(tmp); endpoint = f'http://127.0.0.1:{server.server_port}/api/v1'
                h = p.C.sq_core_open(endpoint.encode(), bytes(root))
                def call(command, **values): return p.call(h, 1, command, **values)
                try:
                    assert p.restore(h)['ok'] and p.library(h, 1)['ok']
                    assert call('select', track_id=1)['ok']
                    target = next(root.rglob('listening-queue-v1.json'))
                    for _ in range(1000):
                        before = call('snapshot')['snapshot']; durable = target.read_bytes(); io = dict(counts)
                        result = call('queue_append', track_id=1)
                        assert target.stat().st_size <= 4 * 1024 * 1024, 'writer exceeded reader envelope through legal ordinary append'
                        if not result['ok']:
                            assert result['code'] == 'queue_full' and 'audio' not in result
                            after = call('snapshot')['snapshot']
                            for key in ('queue','selected_occurrence','session','position_ms','transport'):
                                assert after[key] == before[key], ('oversize admission changed live truth', key)
                            assert target.read_bytes() == durable and counts == io
                            break
                    else: raise AssertionError('missing finite serialized budget')
                    saved = json.loads(durable)
                    other = p.C.sq_core_open(endpoint.encode(), bytes(root))
                    try:
                        assert p.restore(other)['ok']; restored = p.call(other, 1, 'queue_restore')
                        assert restored['ok'] and restored['snapshot']['queue'] == before['queue'] and restored['snapshot']['transport'] == 'paused'
                    finally: p.C.sq_core_close(other)
                    removed = call('queue_remove', occurrence_id=before['queue'][-1]['id']); assert removed['ok']
                    appended = call('queue_append', track_id=1)
                    assert appended['ok'] and appended['snapshot']['queue'][-1]['id'] == saved['next_occurrence'], 'rejected candidate consumed next occurrence ID'
                    assert call('queue_clear')['ok'] and json.loads(target.read_bytes())['queue'] == []
                    print('PASS complete-serialized-budget-refusal-live-durable-next-ID-restore-remove-clear', 'escaped' if title[0] == '\x00' else 'ordinary', flush=True)
                    # Accumulate legal backend pages whose combined visible list
                    # cannot fit in a saved queue. Select must refuse before IO.
                    for page in range(3):
                        tracks[:] = [{'id':2 + page * 50 + i, 'title':'valid', 'artist':'a' * 40000} for i in range(50)]
                        assert call('library', offset=page * 50, query='', sort='title', order='asc')['ok']
                    before = call('snapshot')['snapshot']; durable = target.read_bytes(); io = dict(counts)
                    revoked = p.C.sq_core_revoke(h)
                    result = p.call(h, revoked, 'select', track_id=2)
                    assert result['code'] == 'queue_full' and 'audio' not in result, 'oversize Select admitted decoder work'
                    after = result['snapshot']
                    assert all(after[k] == before[k] for k in ('queue','selected_occurrence','session','position_ms','transport'))
                    assert target.read_bytes() == durable and counts == io
                    print('PASS complete-serialized-select-refused-before-descriptor-download', flush=True)
                finally: p.C.sq_core_close(h)
        finally:
            server.shutdown(); server.server_close(); thread.join(3)


def eof_durability(case=None):
    for mode in ('held', 'prepared', 'failed'):
        if case and case != mode: continue
        entered = threading.Event(); release = threading.Event(); fail = [False]
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args): pass
            def respond(self, value, status=200):
                data = value if isinstance(value, bytes) else json.dumps(value).encode()
                self.send_response(status); self.send_header('Content-Length', str(len(data)))
                self.end_headers(); self.wfile.write(data)
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length', 0)))
                if self.path.endswith('/refresh'):
                    self.respond({'accessToken':'synthetic-access', 'refreshToken':'synthetic-refresh', 'user':{'id':'synthetic-account'}})
                else:
                    entered.set(); assert release.wait(5), 'preparation gate not released'
                    if fail[0]: self.respond({}, 503)
                    else: self.respond({'urls':[{'trackId':1, 'url':f'http://127.0.0.1:{server.server_port}/asset.wav', 'contentType':'audio/wav', 'sizeBytes':8}]})
            def do_GET(self):
                self.respond({'tracks':[{'id':1,'title':'EOF','duration_ms':30000}], 'total':1,'offset':0} if '/library?' in self.path else b'RIFFtest')
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            with tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
                endpoint = f'http://127.0.0.1:{server.server_port}/api/v1'; root = Path(tmp)
                h = p.C.sq_core_open(endpoint.encode(), bytes(root)); pending = None
                try:
                    release.set(); assert p.restore(h)['ok'] and p.library(h,1)['ok']
                    assert p.call(h,1,'select',track_id=1)['ok']
                    appended = p.call(h,1,'queue_append',track_id=1)['snapshot']
                    old = appended['selected_occurrence']; new = appended['queue'][1]['id']; session = appended['session']
                    target = next(root.rglob('listening-queue-v1.json'))
                    assert json.loads(target.read_bytes())['position_ms'] == 0
                    def report(state, report_session=session):
                        return p.take(p.C.sq_core_execute(h,1,json.dumps({'command':'audio_report','epoch':1,'session':report_session,'state':state,'position_ms':30000 if state=='ended' else 0,'duration_ms':30000}).encode()))
                    assert report('playing')['ok']
                    # Close/reopen decoder delivery ownership and remove the
                    # disposable cached asset so EOF reaches real preparation IO.
                    for asset in root.rglob('*.wav'): asset.unlink()
                    entered.clear(); release.clear(); fail[0] = mode == 'failed'
                    result = []
                    pending = threading.Thread(target=lambda: result.append(report('ended'))); pending.start()
                    assert entered.wait(5), 'EOF did not enter successor preparation'
                    def restart():
                        other = p.C.sq_core_open(endpoint.encode(), bytes(root))
                        try:
                            assert p.restore(other)['ok']; restored = p.call(other,1,'queue_restore')
                            assert restored['ok'] and restored['snapshot']['selected_occurrence'] == new and restored['snapshot']['position_ms'] == 0 and restored['snapshot']['transport'] == 'paused' and restored['audio']['action'] == 'stop', 'EOF successor selection not durable at equal zero cursors'
                        finally: p.C.sq_core_close(other)
                    if mode == 'held': restart()
                    release.set(); pending.join(5); assert not pending.is_alive()
                    eof = result[0]
                    assert eof['snapshot']['selected_occurrence'] == new
                    if mode == 'failed': assert not eof['ok'] and eof['snapshot']['transport'] == 'failed' and 'audio' not in eof
                    else:
                        assert eof['ok'] and eof['audio']['action'] == 'load'
                        if mode == 'prepared': assert report('playing', eof['snapshot']['session'])['ok']
                    restart()
                    late = report('ended')
                    assert late['code'] == 'stale_audio_report' and p.call(h,1,'snapshot')['snapshot']['selected_occurrence'] == new
                    p.call(h,1,'pause'); late = report('ended', eof['snapshot']['session'])
                    assert late['code'] == 'stale_audio_report'
                    print('PASS EOF-selection-equal-zero-durable-restart-paused-' + mode, flush=True)
                finally:
                    release.set()
                    if pending: pending.join(5)
                    p.C.sq_core_close(h)
        finally:
            release.set(); server.shutdown(); server.server_close(); thread.join(3)


def unsupported_saved(case=None):
    with p.Server() as server, tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
        h = p.new_core(server, tmp)
        try:
            assert p.restore(h)['ok'] and p.library(h,1)['ok']
            assert p.call(h,1,'select',track_id=1)['ok']
            target = next(Path(tmp).rglob('listening-queue-v1.json')); known = target.read_bytes()
            for mode in ('occurrence', 'track', 'version', 'corrupt', 'oversized'):
                if case and case != mode: continue
                saved = json.loads(known)
                if mode == 'occurrence': saved['queue'][0]['future_occurrence_policy'] = {'repeat':True}
                if mode == 'track': saved['queue'][0]['track']['future_source_binding'] = 'unknown'
                if mode == 'version': saved['version'] = 2
                data = b'{broken' if mode == 'corrupt' else b' ' * (4 * 1024 * 1024 + 1) if mode == 'oversized' else json.dumps(saved).encode()
                target.write_bytes(data); before = p.call(h,1,'snapshot')['snapshot']
                restored = p.call(h,1,'queue_restore')
                assert restored['code'] == 'invalid_saved_queue', 'unsupported nested saved semantics accepted: ' + mode
                after = p.call(h,1,'snapshot')['snapshot']
                assert all(after[k] == before[k] for k in ('queue','selected_occurrence','session','position_ms','transport'))
                for command, values in [('queue_append',{'track_id':1}), ('queue_move',{'occurrence_id':before['queue'][0]['id'],'to_index':0}), ('queue_remove',{'occurrence_id':before['queue'][0]['id']}), ('queue_clear',{})]:
                    result = p.call(h,1,command,**values)
                    assert result['code'] == 'invalid_saved_queue' and target.read_bytes() == data
                target.write_bytes(known); assert p.call(h,1,'queue_restore')['ok']
                print('PASS unsupported-saved-refused-live-truth-and-bytes-preserved-' + mode, flush=True)
            assert p.call(h,1,'queue_append',track_id=1)['ok']
            print('PASS known-saved-v1-remains-writable', flush=True)
        finally: p.C.sq_core_close(h)
    # Remote Track JSON intentionally remains additive, unlike saved semantics.
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args): pass
        def respond(self, value):
            data = json.dumps(value).encode(); self.send_response(200)
            self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
        def do_POST(self):
            self.rfile.read(int(self.headers.get('Content-Length',0)))
            self.respond({'accessToken':'synthetic-access','refreshToken':'synthetic-refresh','user':{'id':'synthetic-account'}})
        def do_GET(self): self.respond({'tracks':[{'id':1,'title':'Additive','future_source_binding':{'server':'extra'}}],'total':1,'offset':0})
    server = ThreadingHTTPServer(('127.0.0.1',0), Handler)
    thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
    try:
        with tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
            h = p.C.sq_core_open(f'http://127.0.0.1:{server.server_port}/api/v1'.encode(), bytes(Path(tmp)))
            try:
                assert p.restore(h)['ok']; result = p.library(h,1)
                assert result['ok'] and result['snapshot']['library'][0]['title'] == 'Additive'
                print('PASS additive-server-Library-Track-field-compatible', flush=True)
            finally: p.C.sq_core_close(h)
    finally: server.shutdown(); server.server_close(); thread.join(3)


def transport_budget():
    """Admission budgets future scalars, never ordinary current transport truth."""
    import time
    from urllib.parse import urlparse, parse_qs
    limit = 4 * 1024 * 1024
    maximum = (1 << 64) - 1
    compact = lambda v: json.dumps(v, separators=(',', ':')).encode()
    tracks = []
    counts = {'descriptor': 0, 'download': 0}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def respond(self, value):
            data = value if isinstance(value, bytes) else compact(value)
            self.send_response(200); self.send_header('Content-Length', str(len(data)))
            self.end_headers(); self.wfile.write(data)
        def do_POST(self):
            value = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or '{}')
            if self.path.endswith('/refresh'):
                self.respond({'accessToken':'synthetic-access', 'refreshToken':'synthetic-refresh', 'user':{'id':'synthetic-account'}})
            else:
                counts['descriptor'] += 1
                self.respond({'urls':[{'trackId':i, 'url':f'http://127.0.0.1:{self.server.server_port}/asset.wav', 'contentType':'audio/wav', 'sizeBytes':8} for i in value['trackIds']]})
        def do_GET(self):
            if '/library?' in self.path:
                offset = int(parse_qs(urlparse(self.path).query)['offset'][0])
                self.respond({'tracks':tracks[offset:offset+50], 'total':len(tracks), 'offset':offset})
            else: counts['download'] += 1; self.respond(b'RIFFtest')
    server = ThreadingHTTPServer(('127.0.0.1',0), Handler)
    thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
    try:
        for escaped in (False, True):
            # Exact byte envelopes derived independently from the documented v1
            # wire shape; all input comes through legal ordinary Library pages.
            title = '\x00' * 16000 if escaped else 't' * 16000
            size = 44 if escaped else 261
            tracks[:] = [dict(id=i, title=title, artist=None, album=None, duration_ms=maximum) for i in range(1,size+1)]
            shape = dict(version=1, queue=[dict(id=i,track=t) for i,t in enumerate(tracks,1)], selected=1, position_ms=0, next_occurrence=size+1)
            delta = limit - len(compact(shape))
            # Escaped NUL consumes six bytes. A literal suffix covers remainder.
            if escaped:
                desired = len(title) * 6 + delta
                tracks[-1]['title'] = '\x00' * (desired // 6) + 't' * (desired % 6)
            else: tracks[-1]['title'] = 't' * (len(title) + delta)
            assert all(len(t['title'].encode()) <= 16000 for t in tracks)
            assert len(compact(shape)) == limit
            for mode in ('exact-refused', 'exact-append-refused', 'future-accepted'):
                # Max future cursor + selected + next counter, regardless of
                # their current widths. Fixed occurrence IDs already count.
                future = dict(shape, selected=maximum, position_ms=maximum, next_occurrence=maximum)
                reserve = len(compact(future)) - len(compact(shape))
                original = tracks[-1]['title']
                if mode == 'future-accepted':
                    # Remove exactly reserve encoded bytes, including escaping.
                    while len(compact(future)) > limit:
                        tracks[-1]['title'] = tracks[-1]['title'][:-1]
                    assert len(compact(future)) <= limit and limit-len(compact(shape)) < reserve+6
                with tempfile.TemporaryDirectory(dir=p.OUT/'tmp') as tmp:
                    root=Path(tmp); endpoint=f'http://127.0.0.1:{server.server_port}/api/v1'
                    h=p.C.sq_core_open(endpoint.encode(),bytes(root)); epoch=1
                    def call(command, **kw):
                        return p.take(p.C.sq_core_execute(h,epoch,json.dumps(dict(command=command,**kw)).encode()))
                    def reopen():
                        nonlocal h,epoch
                        p.C.sq_core_close(h); h=p.C.sq_core_open(endpoint.encode(),bytes(root)); epoch=1
                        assert p.restore(h)['ok']
                        return call('queue_restore')
                    try:
                        assert p.restore(h)['ok']
                        # Persist an ordinary empty queue so refusal verifies
                        # byte preservation as well as absence of decoder IO.
                        assert call('queue_clear')['ok']
                        target=next(root.rglob('listening-queue-v1.json'))
                        last = tracks.pop() if mode == 'exact-append-refused' else None
                        for offset in range(0,len(tracks),50): assert call('library',offset=offset,query='',sort='title',order='asc')['ok']
                        if last is not None:
                            assert call('select',track_id=1)['ok']
                            tracks.append(last)
                            # Updating the Library does not change queued metadata.
                            assert call('library',offset=0,query='',sort='title',order='asc')['ok']
                            offset=(len(tracks)-1)//50*50
                            assert call('library',offset=offset,query='',sort='title',order='asc')['ok']
                        before=call('snapshot')['snapshot']; durable=target.read_bytes(); io=dict(counts)
                        epoch=p.C.sq_core_revoke(h)
                        r=call('queue_append',track_id=size) if last is not None else call('select',track_id=1)
                        if mode != 'future-accepted':
                            assert r['code']=='queue_full' and 'audio' not in r, 'exact-cap Select without future headroom admitted decoder work'
                            after=r['snapshot']
                            assert all(after[k]==before[k] for k in ('queue','selected_occurrence','session','position_ms','transport'))
                            assert counts==io and target.read_bytes()==durable
                            # Rejected Select has not consumed even one ID.
                            appended=None
                            if last is not None:
                                # A smaller visible metadata update can append
                                # using the exact still-unconsumed occurrence ID.
                                title_before=tracks[0]['title']; tracks[0]['title']='small'
                                assert call('library',offset=0,query='',sort='title',order='asc')['ok']
                                appended=call('queue_append',track_id=1)
                                tracks[0]['title']=title_before
                            else: appended=call('queue_append',track_id=1)
                            assert appended['ok'] and appended['snapshot']['queue'][-1]['id']==json.loads(durable)['next_occurrence']
                            print('PASS exact-cap-content-refusal-epoch-live-bytes-IO-next-ID', mode, escaped, flush=True)
                        else:
                            assert r['ok'] and len(r['snapshot']['queue'])==size, 'headroom-safe populated queue was not accepted'
                            session=r['snapshot']['session']; samples=[]
                            for state in ('playing','preparing'):
                                for pos in (9,10,999,1000,maximum):
                                    started=time.perf_counter()
                                    report=call('audio_report',epoch=epoch,session=session,state=state,position_ms=pos,duration_ms=maximum)
                                    samples.append((time.perf_counter()-started)*1000)
                                    assert report['ok'] and report['snapshot']['position_ms']==pos and report['snapshot']['transport']==state
                                    assert report['snapshot']['queue_unchanged'] and report['snapshot']['queue']==[]
                            failed=call('audio_report',epoch=epoch,session=session,state='failed',position_ms=maximum,duration_ms=maximum)
                            assert failed['ok'] and failed['snapshot']['transport']=='failed' and failed['snapshot']['error']=='native_playback_failed'
                            assert call('seek',position_ms=maximum)['ok']
                            assert call('pause')['ok'] and target.stat().st_size<=limit
                            restored=reopen()
                            assert restored['ok'] and restored['snapshot']['transport']=='paused' and restored['snapshot']['position_ms']==maximum
                            resumed=call('resume'); assert resumed['ok'] and resumed['audio']['position_ms']==maximum
                            session=resumed['snapshot']['session']
                            ended=call('audio_report',epoch=epoch,session=session,state='ended',position_ms=maximum,duration_ms=maximum)
                            assert ended['ok'] and ended['snapshot']['selected_occurrence']==2 and ended['audio']['position_ms']==0
                            # Selection digit growth is admitted by the envelope.
                            played=call('queue_play',occurrence_id=size)
                            assert played['ok'] and played['snapshot']['selected_occurrence']==size
                            assert target.stat().st_size<=limit and reopen()['ok']
                            print('PASS accepted-near-cap-playing-preparing-max-failed-Seek-Pause-Resume-EOF-selection-restart', escaped, 'bytes',target.stat().st_size,'report-ms',samples,flush=True)
                    finally: p.C.sq_core_close(h)
                tracks[-1]['title']=original
    finally: server.shutdown(); server.server_close(); thread.join(3)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('--finding', choices=['budget', 'eof', 'unsupported', 'transport'])
    parser.add_argument('--case', choices=['ordinary','escaped','held','prepared','failed','occurrence','track','version','corrupt','oversized'])
    args = parser.parse_args()
    if args.finding == 'transport': transport_budget()
    elif args.finding == 'budget': storage_budget(args.case)
    elif args.finding == 'eof': eof_durability(args.case)
    elif args.finding == 'unsupported': unsupported_saved(args.case)
    else: main()
