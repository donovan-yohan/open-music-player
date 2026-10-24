#!/usr/bin/env python3
"""Synthetic loopback/ABI helpers for native corrective regressions.
No platform decoder, live endpoints, default endpoint access or raw reply logs.
"""
import ctypes
import json
import os
from pathlib import Path
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OUT = Path(os.environ['SOUNDQ_REPAIR_EVIDENCE'])
LIB = Path(os.environ['SOUNDQ_CORE_LIBRARY'])
C = ctypes.CDLL(str(LIB))
C.sq_core_open.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
C.sq_core_open.restype = ctypes.c_uint64
C.sq_core_execute.argtypes = [ctypes.c_uint64, ctypes.c_uint64, ctypes.c_char_p]
C.sq_core_execute.restype = ctypes.c_void_p
C.sq_core_revoke.argtypes = [ctypes.c_uint64]
C.sq_core_revoke.restype = ctypes.c_uint64
C.sq_core_close.argtypes = [ctypes.c_uint64]
C.sq_core_string_free.argtypes = [ctypes.c_void_p]


def take(pointer):
    assert pointer
    try:
        return json.loads(ctypes.string_at(pointer))
    finally:
        C.sq_core_string_free(pointer)


def call(h, epoch, command, **values):
    return take(C.sq_core_execute(h, epoch, json.dumps({'command':command, **values}).encode()))


def restore(h):
    # Dummy local-only session; never a private fixture/account.
    return call(h, 1, 'restore', access_token='synthetic-original-access',  # dummy loopback only
                refresh_token='synthetic-original-refresh', account_id='synthetic-account')


def library(h, epoch):
    return call(h, epoch, 'library', offset=0, query='', sort='title', order='asc')


def new_core(server, root):
    handle=C.sq_core_open(server.endpoint.encode(),os.fsencode(root))
    assert handle
    return handle


class Server:
    def __init__(self):
        self.refreshes=0
        self.downloads=0
        self.descriptors=0
        self.libraries=0
        self.logouts=0
        self.body=b'RIFF'+b'synthetic-reviewed-audio'*16
        self.want401=False
        self.hold_library=False
        self.entered=threading.Event()
        self.release=threading.Event()
        owner=self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass
            def respond(self,value,status=200):
                data=value if isinstance(value,bytes) else json.dumps(value).encode()
                self.send_response(status)
                self.send_header('Content-Length',str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            def do_POST(self):
                self.rfile.read(int(self.headers.get('Content-Length',0)))
                if self.path=='/api/v1/auth/refresh':
                    owner.refreshes+=1
                    self.respond({'accessToken':f'synthetic-access-{owner.refreshes}',
                                  'refreshToken':f'synthetic-refresh-{owner.refreshes}',
                                  'user':{'id':'synthetic-account'}})
                elif self.path=='/api/v1/auth/login':
                    self.respond({'accessToken':'synthetic-b-access',
                                  'refreshToken':'synthetic-b-refresh',
                                  'user':{'id':'synthetic-account-b'}})
                elif self.path=='/api/v1/playback/urls':
                    owner.descriptors+=1
                    self.respond({'urls':[{'trackId':1,'url':owner.endpoint.removesuffix('/api/v1')+'/asset.wav',
                                           'contentType':'audio/wav','sizeBytes':len(owner.body),'etag':'synthetic','storageKeyVersion':'v1'}]})
                elif self.path=='/api/v1/auth/logout':
                    owner.logouts+=1
                    self.respond({},204)
                else:
                    self.respond({},404)
            def do_GET(self):
                if self.path.startswith('/api/v1/library?'):
                    owner.libraries+=1
                    if owner.want401:
                        owner.want401=False
                        self.respond({},401)
                        return
                    if owner.hold_library:
                        owner.entered.set()
                        assert owner.release.wait(5)
                    self.respond({'tracks':[{'id':1,'title':'Synthetic Track','duration_ms':30000}],'total':1,'offset':0})
                elif self.path=='/asset.wav':
                    owner.downloads+=1
                    self.respond(owner.body)
                else:
                    self.respond({},404)
        self.http=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        self.endpoint=f'http://127.0.0.1:{self.http.server_port}/api/v1'
        self.thread=threading.Thread(target=self.http.serve_forever,daemon=True)
    def __enter__(self):
        self.thread.start()
        return self
    def __exit__(self,*args):
        self.release.set()
        self.http.shutdown()
        self.http.server_close()
        self.thread.join(3)
