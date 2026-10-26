#!/usr/bin/env python3
"""Offline captured-window response bounds. Not physical or semantic latency."""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys
from typing import Any, cast

from flutter_renderer_gate import RendererInputs, canonical_hash
from matched_performance import Invalid, keys, manifests, number, require, sha, strict_json, token
from performance_gate import load, stats

LIMITS = ['captured-window-change-not-physical-presentation', 'any-roi-change-not-semantic-causality',
          'synthetic-os-event-submission-not-delivery', 'caller-must-exclude-progress-caret-and-unrelated-animation',
          'no-audio-qualification']
CAPTURE = ('roi_px', 'input_point_screen_points', 'scroll_pixels', 'threshold',
           'input_route', 'geometry', 'capture_requested_interval')


def integer(value, minimum=0, maximum=2**64-1) -> int:
    require(type(value) is int and minimum <= value <= maximum, 'invalid-integer')
    return value


def tick(value):
    require(type(value) is str and re.fullmatch(r'[0-9]{1,20}', value), 'invalid-tick')
    return integer(int(value), 1)


def upper_ns(end, start, numer, denom):
    require(end >= start and (end-start)*numer <= 2**64-1, 'invalid-clock-delta')
    return ((end-start)*numer + denom-1)//denom


def rect(value):
    keys(value, ['X', 'Y', 'Width', 'Height'])
    for key,v in value.items():
        require(type(v) in (float,int) and math.isfinite(v) and abs(v)<=100000, 'invalid-geometry')
        if key in ('Width','Height'):require(v>0, 'invalid-geometry')


def capture_shape(value: dict[str, Any]):
    keys(value, CAPTURE)
    roi: Any=value['roi_px'];point: Any=value['input_point_screen_points']
    require(type(roi) is list and len(roi)==4, 'invalid-roi')
    for n in roi:integer(n,0,32768)
    x,y,w,h=[integer(n,0,32768) for n in roi]
    require(0<w<=512 and 0<h<=512, 'invalid-roi')
    require(type(point) is list and len(point)==2
            and all(type(n) in (int,float) and math.isfinite(n) and abs(n)<100000 for n in point), 'invalid-point')
    integer(value['scroll_pixels'],-2000,2000);require(value['scroll_pixels']!=0, 'invalid-scroll')
    number(value['threshold'],minimum=1);require(value['threshold']<=255, 'invalid-threshold')
    require(value['input_route'] in ('cg-hid-foreground','cg-post-to-pid'), 'invalid-input-domain')
    keys(value['capture_requested_interval'], ['value','timescale'])
    require(canonical_hash(value['capture_requested_interval'])==canonical_hash(dict(value=1,timescale=60)), 'invalid-capture-interval')
    g=value['geometry'];keys(g,['content_rect','content_scale','height_px','scale','screen_rect','width_px'])
    rect(g['content_rect']);rect(g['screen_rect'])
    integer(g['width_px'],1,16384);integer(g['height_px'],1,16384)
    number(g['scale'],positive=True);number(g['content_scale'],positive=True)
    require(x+w<=g['width_px'] and y+h<=g['height_px'], 'invalid-roi')
    r=g['screen_rect']
    require(r['X']<=point[0]<r['X']+r['Width'] and r['Y']<=point[1]<r['Y']+r['Height'], 'point-outside-target')


def parse_report(report, cohort):
    keys(report,['schema','status','failure_codes','physical_presentation_available','fps','response_lower_ns'],
         ['response_upper_ns','detected_by_upper_ns','pid','window_id','application_id','executable_sha256',
          'clock','input_ticks','samples','limits',*CAPTURE])
    require(report['schema']=='soundq.window-response.v1', 'unknown-report-version')
    require(report['status'] in ('observed','failed','running'), 'invalid-status')
    require(type(report['failure_codes']) is list, 'invalid-failure-codes')
    for code in report['failure_codes']:token(code)
    require(report['physical_presentation_available'] is False and report['fps'] is None
            and type(report['response_lower_ns']) is int and report['response_lower_ns']==0, 'unsupported-presentation-claim')
    integer(report.get('pid'),1,2**31-1);integer(report.get('window_id'),1,2**32-1)
    require(report.get('application_id')==cohort['application_id']
            and report.get('executable_sha256')==cohort['executable_sha256'], 'target-artifact-mismatch')
    require(report.get('limits')==LIMITS, 'unsupported-collector-claim')
    observed={k:report.get(k) for k in CAPTURE};capture_shape(observed)
    require(canonical_hash(observed)==canonical_hash(cohort['capture']), 'capture-mismatch')
    clock=report.get('clock');keys(clock,['domain','unit','numer','denom'])
    require(clock['domain']=='mach-absolute-time' and clock['unit']=='tick', 'invalid-clock-domain')
    numer=integer(clock['numer'],1,2**32-1);denom=integer(clock['denom'],1,2**32-1)
    inputs=report.get('input_ticks');require(type(inputs) is list and len(inputs)==2, 'missing-input-bracket')
    before,after=map(tick,inputs);require(after>=before, 'invalid-input-bracket')
    samples=report.get('samples');require(type(samples) is list and 0<len(samples)<=2000, 'invalid-samples')
    last_callback=last_display=last_pixel=0;baseline=None;positive=None
    for index,s in enumerate(samples):
        require(positive is None, 'sample-after-qualified-change')
        keys(s,['sequence','callback_ticks','status'],['display_ticks','roi_sha256','pixel_read_end_ticks','predicate','mean_absolute_rgb_change_0_255'])
        require(type(s['sequence']) is int and s['sequence']==index, 'sample-sequence-invalid')
        status=integer(s['status'],0,5);callback=tick(s['callback_ticks'])
        require(callback>last_callback and callback>=last_pixel, 'sample-clock-reversed');last_callback=callback
        if status!=0:
            require(set(s)=={'sequence','callback_ticks','status'}, 'invalid-nonimage-sample')
            # Public SCFrameStatus: complete0 idle1 blank2 suspended3 started4 stopped5.
            require(status in (1,4), 'capture-unavailable')
            continue
        display=tick(s.get('display_ticks'));pixel=tick(s.get('pixel_read_end_ticks'))
        require(last_display<display<=callback<=pixel, 'sample-clock-reversed')
        last_display=display;last_pixel=pixel
        sha(s.get('roi_sha256'));predicate=s.get('predicate')
        if baseline is None:
            require(predicate=='baseline' and 'mean_absolute_rgb_change_0_255' not in s and pixel<=before, 'invalid-baseline')
            baseline=s
            require(upper_ns(before,callback,numer,denom)>=200000000, 'baseline-dwell-too-short')
            continue
        change=s.get('mean_absolute_rgb_change_0_255');number(change);require(change<=255, 'invalid-pixel-distance')
        if predicate=='preinput-negative':
            require(pixel<=before and change<=.25, 'unstable-preinput-baseline')
        elif predicate=='negative':
            require(pixel>=before and (display<after or change<cohort['capture']['threshold']), 'missed-qualified-change')
        elif predicate=='first-qualified-change':
            require(display>=after and change>=cohort['capture']['threshold']
                    and s['roi_sha256']!=baseline['roi_sha256'], 'unqualified-change')
            positive=s
        else:raise Invalid('invalid-sample-predicate')
    require(positive is not None and baseline is not None, 'no-qualified-captured-change')
    positive = cast(dict[str, Any], positive)
    response=upper_ns(tick(positive['display_ticks']),before,numer,denom)
    require(type(report.get('response_upper_ns')) is int and report['response_upper_ns']==response, 'forged-response-bound')
    # Current producer omits its final detected tick. This value can be bounded
    # for shape only, never independently reconstructed or budgeted.
    detection=integer(report.get('detected_by_upper_ns'))
    require(detection>=upper_ns(tick(positive['pixel_read_end_ticks']),before,numer,denom), 'invalid-detection-bound')
    return response


def shape(obj):
    keys(obj,['schema','run_id','source','executable_sha256','application_id','build_mode',
              'environment','workload','features','visible','capture','attempts'])
    require(obj['schema']=='soundq.window-response.cohort.v1','unknown-cohort-version');token(obj['run_id'])
    keys(obj['source'],['commit','tree'])
    for v in obj['source'].values():sha(v,40)
    sha(obj['executable_sha256']);token(obj['application_id'])
    require(obj['build_mode'] in ('profile','release'), 'production-build-required')
    manifests(obj);capture_shape(obj['capture'])
    require(obj['environment']['platform']=='macos','unsupported-platform')
    require(type(obj['attempts']) is list and 0<len(obj['attempts'])<=200,'invalid-attempts')


def reduce_cohort(obj,inputs):
    shape(obj);attempts=[];seen=set()
    for index,attempt in enumerate(obj['attempts']):
        row:dict[str,Any]=dict(input_index=index,admitted=False,reasons=[],response_upper_ns=None,detected_by_verified=False)
        try:
            keys(attempt,['report','process_start']);token(attempt['process_start'])
            report=strict_json(inputs.read(attempt['report']))
            # Failed/malformed populations reserve usable identity claims too.
            pid=report.get('pid') if type(report) is dict else None
            integer(pid,1,2**31-1)
            identities=[('pid',pid),('start',attempt['process_start']),('raw',attempt['report']['sha256'])]
            require(not any(i in seen for i in identities),'reused-process-population');seen.update(identities)
            row['response_upper_ns']=parse_report(report,obj)
            require(report['status']=='observed' and report['failure_codes']==[], 'collector-attempt-failed')
            row['admitted']=True
        except (Invalid,OSError,UnicodeError,ValueError,TypeError,KeyError,OverflowError,RecursionError) as exc:
            row['reasons'].append(str(exc) if isinstance(exc,Invalid) else 'invalid-report-evidence')
        attempts.append(row)
    reasons=[]
    if any(not r['admitted'] for r in attempts):reasons.append('failed-attempts-retained')
    if len(attempts)<5:reasons.append('requires-five-independent-processes')
    env=obj['environment']
    if not env['quiet']:reasons.append('shared-host-not-qualified')
    if any(v is None or v=='unavailable' for v in env.values()):reasons.append('environment-unavailable')
    f=obj['features']
    if f['missing'] or not set(f['required'])<=set(f['exercised']):reasons.append('features-not-exercised')
    def aggregate(rows):
        values=[r['response_upper_ns'] for r in rows if r['response_upper_ns'] is not None]
        return stats(values) if values else None
    return dict(qualified=not reasons,reasons=reasons,attempts=attempts,
        admitted_only=aggregate([r for r in attempts if r['admitted']]),failure_inclusive=aggregate(attempts))


def equivalence(obj):return {k:obj[k] for k in ['application_id','build_mode','environment','workload','features','visible','capture']}


def baseline(obj,digest,reduced):
    return dict(schema='soundq.window-response.baseline.v1',status='qualified' if reduced['qualified'] else 'unqualified',
        cohort_sha256=digest,source=obj['source'],executable_sha256=obj['executable_sha256'],
        equivalence=equivalence(obj),**reduced,units='nanoseconds',clock='mach-absolute-time',
        estimator='nearest-rank',limits=[*LIMITS,'detection-tick-unavailable-not-budgeted','source-and-start-labels-caller-supplied',
            'single-trial-per-process-small-tail-population','captured-response-upper-bound-not-semantic-latency'])


def compare(base,base_sha,obj,reduced,policy):
    keys(policy,['schema','baseline_sha256','reviewer','calibration','budget'])
    require(policy['schema']=='soundq.window-response.policy.v1','unknown-policy-version')
    sha(policy['baseline_sha256']);token(policy['reviewer']);keys(policy['calibration'],['cohort_sha256','rationale'])
    sha(policy['calibration']['cohort_sha256']);token(policy['calibration']['rationale'])
    require(policy['baseline_sha256']==base_sha,'policy-baseline-mismatch')
    require(policy['calibration']['cohort_sha256']==base['cohort_sha256'],'calibration-mismatch')
    keys(policy['budget'],['relative_allowance','absolute_allowance'])
    for v in policy['budget'].values():number(v)
    require(base['qualified'],'unqualified-baseline')
    mismatch=base['equivalence']!=equivalence(obj);reasons=list(reduced['reasons']);breaches=[]
    if mismatch:reasons.append('environment-workload-capture-mismatch')
    else:
        b=policy['budget'];threshold=base['admitted_only']['max']*(1+b['relative_allowance'])+b['absolute_allowance']
        require(math.isfinite(threshold) and threshold<=2**53-1,'invalid-budget-limit')
        for row in reduced['attempts']:
            value=row['response_upper_ns']
            if value is not None and value>threshold:breaches.append(dict(input_index=row['input_index'],observed=value,limit=threshold))
    if breaches:reasons.append('budget-breached')
    return dict(schema='soundq.window-response.comparison.v1',status='inconclusive' if mismatch else 'failed' if reasons else 'passed',
        baseline_sha256=base_sha,candidate_source=obj['source'],candidate=reduced,reasons=reasons,breaches=breaches,
        comparison=None,full_app_accepted=False)


def main(argv=None):
    parser=argparse.ArgumentParser(description=__doc__);subs=parser.add_subparsers(dest='command',required=True)
    for name in ['baseline','compare']:
        cmd=subs.add_parser(name);cmd.add_argument('--cohort',type=Path,required=True);cmd.add_argument('--evidence',type=Path,required=True)
        if name=='compare':cmd.add_argument('--baseline-cohort',type=Path,required=True);cmd.add_argument('--policy',type=Path,required=True)
    args=parser.parse_args(argv);out=args.evidence
    try:
        require(not any(p.is_symlink() for p in (out,*out.parents)),'symlink-output');out.mkdir(mode=0o700)
    except (Invalid,OSError):return 2
    stores=[]
    def failure(code):return dict(schema='soundq.window-response.failure.v1',status='failed',reasons=[code])
    try:
        store=RendererInputs(args.cohort.resolve().parent);stores.append(store);obj,digest=load(args.cohort,store);reduced=reduce_cohort(obj,store)
        if args.command=='baseline':
            report=baseline(obj,digest,reduced);report['baseline_sha256']=canonical_hash(report)
        else:
            old=RendererInputs(args.baseline_cohort.resolve().parent);stores.append(old);prior,prior_sha=load(args.baseline_cohort,old)
            base=baseline(prior,prior_sha,reduce_cohort(prior,old));base_sha=canonical_hash(base)
            policies=RendererInputs(args.policy.resolve().parent);stores.append(policies);policy,_=load(args.policy,policies)
            report=compare(base,base_sha,obj,reduced,policy)
    except (Invalid,OSError,UnicodeError,ValueError,TypeError,KeyError,OverflowError,RecursionError) as exc:
        report=failure(str(exc) if isinstance(exc,Invalid) else 'invalid-input-evidence')
    try:
        for index,store in enumerate(stores):
            d=out/f'bundle-{index}';d.mkdir(mode=0o700);store.retain(d)
    except (Invalid,OSError):report=failure('input-retention-failed')
    try:
        p=out/'report.new';p.write_text(json.dumps(report,indent=2,allow_nan=False)+'\n');os.replace(p,out/'report.json')
    except (OSError,ValueError,TypeError):print('report-write-failed',file=sys.stderr);return 1
    print(report['status']);return 0 if report['status'] in ('qualified','passed') else 1


if __name__=='__main__':raise SystemExit(main())
