#!/usr/bin/env python3
"""Explicit-artifact Flutter renderer diagnostic. Never builds or provisions.

The caller owns the disposable API at 127.0.0.1:54761. This runner owns only
its launched child and capability-authenticated report listener at :54762.
No physical presentation, audio activity, matched comparison or default budget.
"""
from __future__ import annotations
import argparse
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import socket
import subprocess
import threading
import time
from typing import Any, cast

from matched_performance import Invalid, keys, number, parse_flutter, quantiles, require, strict_json

MAX_REPORT = 16 * 1024 * 1024
IDENTITIES = ('source_commit', 'source_tree', 'source_manifest_sha256')
ENDPOINT = 'http://127.0.0.1:54761/api/v1'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(path):
    require(path.is_absolute() and path == path.resolve(), 'noncanonical-path')
    return path


def read(path, limit, private=False):
    canonical(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_size <= limit, 'invalid-input-file')
        require(not private or info.st_mode & 0o077 == 0, 'private-input-required')
        data = stream.read(limit + 1)
    require(len(data) <= limit, 'input-too-large')
    return data


def identity(value):
    for key in IDENTITIES:
        require(type(value[key]) is str and re.fullmatch('[0-9a-f]{'+('64' if key.endswith('sha256') else '40')+'}', value[key]), 'invalid-source-identity')


def relative(value):
    require(type(value) is str and len(value) <= 1024 and value == str(PurePosixPath(value))
            and not value.startswith('/') and '\\' not in value
            and all(p not in ('', '.', '..') for p in value.split('/')), 'invalid-bundle-path')
    return value


def inventory(app):
    canonical(app)
    require(app.is_dir() and app.suffix == '.app', 'invalid-app')
    rows = []
    def walk_error(error):
        raise Invalid('unreadable-bundle-subtree') from error
    for root, directories, files in os.walk(app, followlinks=False, onerror=walk_error):
        for name in sorted(directories + files):
            p = Path(root)/name
            rel = relative(p.relative_to(app).as_posix())
            if p.is_symlink():
                target = os.readlink(p)
                require(not os.path.isabs(target) and p.resolve().is_relative_to(app) and p.resolve().exists(), 'escaping-bundle-link')
                rows.append(dict(path=rel, kind='link', target=target))
            elif p.is_file():
                require(stat.S_ISREG(p.stat().st_mode), 'invalid-bundle-file')
                rows.append(dict(path=rel, kind='file', sha256=sha(p.read_bytes()), mode=oct(p.stat().st_mode & 0o777)))
            else:
                require(p.is_dir(), 'invalid-bundle-file')
    require(0 < len(rows) <= 10000, 'invalid-bundle-size')
    return sorted(rows, key=lambda r: r['path'])


def artifact(app, path):
    raw = read(path, 4*1024*1024)
    value = strict_json(raw)
    keys(value, ['schema', *IDENTITIES, 'build_mode', 'executable', 'files'])
    require(value['schema'] == 'soundq.flutter.profile-artifact.v1' and value['build_mode'] == 'profile', 'invalid-artifact-schema')
    identity(value)
    rel = relative(value['executable'])
    require(rel.startswith('Contents/MacOS/') and os.access(app/rel, os.X_OK), 'invalid-executable')
    require(value['files'] == inventory(app), 'artifact-changed')
    require(any(r['path'] == rel and r['kind'] == 'file' for r in value['files']), 'invalid-executable')
    return value, sha(raw)


def descriptor(path, manifest):
    raw = read(path, 16384, True)
    value = strict_json(raw)
    keys(value, ['schema', 'endpoint', 'email', 'password', 'run_id', 'report_token', *IDENTITIES])
    require(value['schema'] == 'soundq.flutter.fixture.process.v1' and value['endpoint'] == ENDPOINT, 'invalid-descriptor')
    identity(value)
    require(all(value[k] == manifest[k] for k in IDENTITIES), 'descriptor-source-mismatch')
    require(type(value['run_id']) is str and re.fullmatch('[A-Za-z0-9][A-Za-z0-9_.-]{0,79}',value['run_id']), 'invalid-run-id')
    require(type(value['report_token']) is str and re.fullmatch('[0-9a-f]{64}',value['report_token']), 'invalid-report-token')
    for key, limit in [('email',320),('password',4096)]:
        require(type(value[key]) is str and 0 < len(value[key].encode()) <= limit, 'invalid-credentials')
    return value, raw.decode()


def validate_report(value, request, pid):
    keys(value, ['schema', *IDENTITIES, 'run_id', 'pid', 'build_mode', 'entrypoint', 'route', 'status', 'hold',
                 'preferences','storage','artwork','excluded_operations','audio','full_app_accepted','framework_error_count','loaded_list_slots','witnessed_row_ids',
                 'physical_viewport','scale','clock','boundary_clock','boundary_frames_requested','windows','scroll_legs','rawFrames'])
    require(value['schema'] == 'soundq.flutter.actual-root.profile.v1', 'invalid-report-schema')
    require(all(value[k] == request[k] for k in IDENTITIES) and value['run_id'] == request['run_id']
            and type(value['pid']) is int and value['pid'] == pid, 'child-identity-mismatch')
    require(value['build_mode'] == 'profile' and value['entrypoint'] == 'production.main' and value['route'] == '/library', 'child-workload-mismatch')
    require(value['status'] in ('failed','completed-diagnostic') and value['hold'] in ('journey-failed','audio-native-readback-unavailable','renderer-population-unavailable','fixture-framework-error'), 'invalid-child-status')
    require(value['preferences'] == 'ephemeral-plugin-adapter' and value['audio'] == 'unavailable-native-readback-not-proven'
            and value['storage']=='EPHEMERAL STORAGE' and value['artwork']=='placeholder-only-memory-cache'
            and value['excluded_operations']==['disk','downloads','playback-cache','artwork-acquisition','audio']
            and value['full_app_accepted'] is False, 'unsupported-child-claim')
    require(type(value['framework_error_count']) is int and 0 <= value['framework_error_count'] <= 100000, 'invalid-error-count')
    require(type(value['loaded_list_slots']) is int and 0 <= value['loaded_list_slots'] <= 10000, 'invalid-row-count')
    require(type(value['witnessed_row_ids']) is list and len(value['witnessed_row_ids']) <= 10000
            and all(type(i) is int and 0 < i < 2**63 for i in value['witnessed_row_ids'])
            and len(set(value['witnessed_row_ids'])) == len(value['witnessed_row_ids']), 'invalid-row-witnesses')
    def numeric(v, positive=False):
        number(v, positive=positive)
    require(type(value['physical_viewport']) is list and len(value['physical_viewport']) == 2, 'invalid-viewport')
    for n in value['physical_viewport']: numeric(n, True)
    numeric(value['scale'], True)
    require(value['clock'] == 'flutter-frame-timing' and value['boundary_clock'] == 'SchedulerBinding.currentSystemFrameTimeStamp'
            and value['boundary_frames_requested'] is True, 'invalid-frame-clock')
    require(type(value['rawFrames']) is list and len(value['rawFrames']) <= 100000, 'invalid-raw-capacity')
    frames = parse_flutter({'rawFrames':value['rawFrames']}) if value['rawFrames'] else []
    require(type(value['windows']) is list and len(value['windows']) <= 2, 'invalid-windows')
    previous = -1
    measured = []
    names = []
    for window in value['windows']:
        keys(window,['name','clock','start','end','audio_active','cursor','scroll_start','scroll_end','scroll_max_extent','scroll_distance','motion','frame_count'])
        name=window['name'];names.append(name)
        require(name in ('populated-idle','populated-scroll-audio-unavailable') and names.count(name)==1, 'invalid-phase')
        require(window['clock']=='flutter-frame-timing' and type(window['start']) is int and type(window['end']) is int
                and 0 <= window['start'] < window['end'] < 2**63 and window['start'] >= previous, 'invalid-window-clock')
        previous=window['end']
        require(window['audio_active'] is False and window['cursor'] is None and window['motion'] is (name!='populated-idle'), 'unsupported-audio-claim')
        for key in ('scroll_start','scroll_end','scroll_max_extent','scroll_distance'):numeric(window[key])
        population=[f for f in frames if window['start'] < f.timestamp <= window['end']]
        require(type(window['frame_count']) is int and len(population)==window['frame_count'], 'frame-count-mismatch')
        if name!='populated-idle':require(window['scroll_distance']>0,'zero-scroll')
        measured.extend(population)
    require(type(value['scroll_legs']) is list and len(value['scroll_legs'])<=4, 'invalid-scroll-legs')
    for leg in value['scroll_legs']:
        keys(leg,['target','offset','elapsed_us','requested_us'])
        numeric(leg['target']);numeric(leg['offset'])
        require(type(leg['elapsed_us']) is int and type(leg['requested_us']) is int
                and 0 < leg['requested_us'] <= leg['elapsed_us'] < 2**63 and abs(leg['target']-leg['offset'])<=.5, 'incomplete-scroll-leg')
    if value['status']=='completed-diagnostic':
        require(value['framework_error_count']==0 and value['loaded_list_slots']>=500 and bool(value['witnessed_row_ids'])
                and value['hold']=='audio-native-readback-unavailable'
                and names==['populated-idle','populated-scroll-audio-unavailable'] and len(value['scroll_legs'])==4
                and all(w['frame_count']>0 for w in value['windows']), 'incomplete-workload')
        idle,scroll=value['windows']
        require(idle['scroll_distance']==0 and idle['scroll_start']==idle['scroll_end'], 'idle-moved')
        extent=scroll['scroll_max_extent']
        require(extent>0 and scroll['scroll_start']==0 and abs(scroll['scroll_end'])<=.5,'invalid-scroll-geometry')
        for index,leg in enumerate(value['scroll_legs']):
            require(leg['target']==(extent if index%2==0 else 0) and leg['requested_us']==2_000_000,'incomplete-scroll-leg')
        require(math.isclose(scroll['scroll_distance'],extent*4,rel_tol=1e-6,abs_tol=2),'scroll-distance-mismatch')
        # Scheduler frame timestamps bracket Stopwatch actions. This 100 ms
        # join tolerance is an admission ceiling, never a renderer budget.
        elapsed=sum(leg['elapsed_us'] for leg in value['scroll_legs'])
        require(abs((scroll['end']-scroll['start'])-elapsed)<=100_000
                and idle['end']-idle['start']>=3_100_000,'workload-clock-mismatch')
    metrics={}
    if measured:
        for metric in measured[0].metrics:
            numbers=[f.metrics[metric] for f in measured]
            metrics[metric]={**quantiles(numbers),'min':min(numbers),'spread':max(numbers)-min(numbers),'sample_count':len(numbers)}
    return metrics


def launch(args):
    try:
        canonical(args.evidence)
        require(not args.evidence.is_relative_to(args.app.absolute()),'output-inside-app')
        args.evidence.mkdir(mode=0o700)
    except (OSError,Invalid):return 2
    receipt: dict[str, Any]=dict(schema='soundq.flutter.profile-launch.v1',status='failed',run_id=None,pid=None,process_start_wall_ns=None,
                 failure_codes=[],artifact_before=False,artifact_after=False,cleanup='not-started',child_report=None,renderer=None,
                 full_app_accepted=False,limits=['renderer-not-physical-presentation','non-audio-ephemeral-storage-diagnostic','caller-provenance-not-compilation-proof'])
    def save():
        target=args.evidence/'report.json';temp=args.evidence/'report.new'
        temp.write_text(json.dumps(receipt,sort_keys=True,allow_nan=False)+'\n');temp.replace(target)
    save();child=None;server=None;manifest=None;private=None
    try:
        require(math.isfinite(args.timeout_seconds) and .1<=args.timeout_seconds<=300,'invalid-timeout')
        manifest,digest=artifact(args.app,args.manifest)
        receipt.update(artifact_before=True,artifact_manifest_sha256=digest,source={k:manifest[k] for k in IDENTITIES})
        private,raw=descriptor(args.descriptor,manifest);receipt['run_id']=private['run_id']
        require(not args.evidence.is_relative_to(args.app),'output-inside-app')
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,format,*args):pass
            def reply(self,code,value):
                body=json.dumps(value,separators=(',',':')).encode()
                self.send_response(code);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers()
                self.wfile.write(body)
            def do_POST(self):
                self.connection.settimeout(2)
                try:
                    require(self.path=='/report' and self.headers.get('Transfer-Encoding') is None,'invalid-report-request')
                    require(all(len(self.headers.get_all(name,[]))==1 for name in ('Authorization','Content-Length','Content-Type')),'duplicate-or-missing-header')
                    require(self.headers.get_content_type()=='application/json','invalid-content-type')
                    require(hmac.compare_digest(self.headers.get('Authorization',''),'Bearer '+private['report_token']),'report-auth-refused')
                    length=self.headers.get('Content-Length','')
                    require(re.fullmatch('[0-9]{1,9}',length) and 0<int(length)<=MAX_REPORT,'invalid-report-length')
                    data=self.rfile.read(int(length));require(len(data)==int(length),'short-report-body')
                    require(receipt['child_report'] is None,'duplicate-report')
                    if child is None:raise Invalid('child-not-started')
                    value=strict_json(data);metrics=validate_report(value,private,child.pid)
                    receipt.update(child_report=value,renderer=metrics)
                    save() # Persistence precedes ACK; fixed owned target only.
                    self.reply(200,dict(run_id=private['run_id'],sha256=sha(data),persisted=True))
                except (Invalid,OSError,ValueError,TypeError,KeyError,RecursionError):
                    receipt['failure_codes'].append('report-refused');save()
                    try:self.reply(400,{'status':'refused'})
                    except OSError:pass
        class Receiver(HTTPServer):
            def get_request(self):
                connection,address=super().get_request()
                connection.settimeout(2)
                return connection,address
            def process_request(self,request,client_address):
                def expire():
                    try:cast(socket.socket,request).shutdown(socket.SHUT_RDWR)
                    except OSError:pass
                timer=threading.Timer(max(.001,min(2,end-time.monotonic())),expire)
                timer.daemon=True;timer.start()
                try:super().process_request(request,client_address)
                finally:timer.cancel()
        server=Receiver(('127.0.0.1',54762),Handler);server.timeout=.2
        env={'PATH':'/usr/bin:/bin','TMPDIR':os.environ.get('TMPDIR',str(args.evidence)),
             'SOUNDQ_FIXTURE_DISPOSABLE':'1','SOUNDQ_FIXTURE_DESCRIPTOR':raw}
        child=subprocess.Popen([str(args.app/manifest['executable'])],cwd=args.evidence,env=env,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
        receipt.update(pid=child.pid,process_start_wall_ns=time.time_ns(),cleanup='pending');save()
        end=time.monotonic()+args.timeout_seconds
        while time.monotonic()<end and child.poll() is None and receipt['child_report'] is None and not receipt['failure_codes']:
            server.handle_request()
        require(receipt['child_report'] is not None,'missing-child-report')
        require(receipt['child_report']['status']=='completed-diagnostic','child-diagnostic-failed')
    except (Invalid,OSError,ValueError,TypeError,KeyError,RecursionError) as error:
        receipt['failure_codes'].append(str(error) if isinstance(error,Invalid) else 'launch-or-input-failed')
    except KeyboardInterrupt:
        receipt['failure_codes'].append('interrupted')
    finally:
        if server:server.server_close()
        if child:
            if child.poll() is None:child.terminate()
            try:child.wait(timeout=3)
            except subprocess.TimeoutExpired:child.kill();child.wait(timeout=3)
            receipt.update(cleanup='reaped',exit_code=child.returncode)
        if manifest:
            try:
                final,digest=artifact(args.app,args.manifest)
                require(final==manifest and digest==receipt['artifact_manifest_sha256'],'artifact-changed')
                receipt['artifact_after']=True
            except (Invalid,OSError,ValueError,TypeError):receipt['failure_codes'].append('artifact-changed')
        receipt['status']='completed-diagnostic' if not receipt['failure_codes'] else 'failed'
        save()
    return 0 if receipt['status']=='completed-diagnostic' else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__);subs=parser.add_subparsers(dest='command',required=True)
    create=subs.add_parser('manifest');create.add_argument('--app',type=Path,required=True);create.add_argument('--executable',required=True)
    for name in IDENTITIES:create.add_argument('--'+name.replace('_','-'),required=True)
    create.add_argument('--output',type=Path,required=True)
    run=subs.add_parser('run')
    for name in ('app','manifest','descriptor','evidence'):run.add_argument('--'+name,type=Path,required=True)
    run.add_argument('--timeout-seconds',type=float,default=100)
    args=parser.parse_args()
    if args.command=='run':return launch(args)
    try:
        value={k:getattr(args,k) for k in IDENTITIES};identity(value)
        value.update(schema='soundq.flutter.profile-artifact.v1',build_mode='profile',executable=relative(args.executable),files=inventory(args.app))
        require(args.executable.startswith('Contents/MacOS/') and os.access(args.app/args.executable,os.X_OK),'invalid-executable')
        canonical(args.output)
        with args.output.open('x') as stream:json.dump(value,stream,sort_keys=True,allow_nan=False)
        return 0
    except (OSError,Invalid,ValueError,TypeError):return 1


if __name__=='__main__':raise SystemExit(main())
