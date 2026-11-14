#!/usr/bin/env python3
"""SoundQ local evidence workbench. No browser facsimiles, automatic approvals or token copies."""
import argparse
import hashlib
import html
import json
import re
import shutil
import struct
import subprocess
import sys
import zlib
from pathlib import Path

HOME = Path(__file__).resolve().parent
ROOT = HOME.parent
DS = 'android/designsystem/src/'
CASE_IDS = [f'components-{mode}-{state}' for mode in ('light', 'dark') for state in ('default', 'disabled', 'focused', 'large-text')]
NATIVE_HOST = 'android/designsystem/src/androidTest/kotlin/com/soundq/designsystem/StudioNativeComponentTest.kt'


def digest(data):
    return hashlib.sha256(data).hexdigest()


def load(path):
    return json.loads(Path(path).read_text())


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def mask(text, strings=True):
    """Preserve positions/newlines; support nested Kotlin comments and raw strings."""
    out = list(text)
    i = 0
    while i < len(text):
        start = i
        if text.startswith('//', i):
            i = text.find('\n', i)
            if i < 0: i = len(text)
        elif text.startswith('/*', i):
            i += 2
            depth = 1
            while i < len(text) and depth:
                if text.startswith('/*', i): depth += 1; i += 2
                elif text.startswith('*/', i): depth -= 1; i += 2
                else: i += 1
        elif text[i] in '\"\'':
            delimiter = '\"\"\"' if text.startswith('\"\"\"', i) else text[i]
            i += len(delimiter)
            while i < len(text) and not text.startswith(delimiter, i):
                i += 2 if text[i] == '\\' and len(delimiter) == 1 else 1
            i = min(len(text), i + len(delimiter))
            if not strings: continue
        else:
            i += 1
            continue
        for n in range(start, i):
            if out[n] != '\n': out[n] = ' '
    return ''.join(out)


def adoption_errors(text):
    code = mask(text)
    forbidden = {'Button', 'OutlinedButton', 'TextButton', 'IconButton', 'TextField', 'OutlinedTextField', 'BasicTextField'}
    aliases = dict(re.findall(r'import\s+[\w.]+\.(\w+)\s+as\s+(\w+)', code))
    forbidden |= {alias for name, alias in aliases.items() if name in forbidden}
    colors = {'Color'} | {alias for name, alias in aliases.items() if name == 'Color'}
    errors = []
    for name in sorted(forbidden):
        for m in re.finditer(r'\b' + re.escape(name) + r'\s*\(', code):
            errors.append(f'line {code[:m.start()].count(chr(10))+1}: stock {name}; use a catalog component')
    for name in colors:
        for m in re.finditer(r'\b' + name + r'\s*(?:\(|\.\s*(?:Red|Blue|Green|Black|White|Gray|Transparent|Yellow|Cyan|Magenta)\b)', code):
            errors.append(f'line {code[:m.start()].count(chr(10))+1}: raw color; use SoundQ.colors role')
    return errors


SOURCE_EXCLUDED_DIRS = {'build', '.gradle', '.kotlin', '.cxx', '.git', '.idea', '.vscode', '.android', '__pycache__', '.cache', 'cache', 'caches', 'node_modules', 'credentials', '.gradle-user-home'}
BUILD_ASSET = 'android/designsystem/src/androidTest/assets/studio-build.json'
STUDIO_PRODUCERS = ('studio.py', 'native_capture.py', 'capture_contract.py', 'build_capture.py', 'pending/StudioNativeComponentTest.kt')


def require_native_host():
    if not (ROOT / NATIVE_HOST).is_file():
        raise ValueError('native capture host is pending integration; see design-studio/README.md')


def source_files(root=None):
    """All Android build inputs plus the evidence producers; never transient outputs/secrets."""
    import os
    root = Path(root or ROOT).resolve()
    paths = []
    for folder, dirs, files in os.walk(root/'android', followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in SOURCE_EXCLUDED_DIRS and not d.startswith('.tmp'))
        if any((Path(folder)/d).is_symlink() for d in dirs):
            raise ValueError('source directory symlinks are not supported: '+str(folder))
        for name in sorted(files):
            if (name.startswith(('.env', '.tmp', '.DS_Store')) or name in {'local.properties', 'keystore.properties', 'credentials.json'}
                    or name.endswith(('.tmp', '.pyc', '.log', '.jks', '.keystore', '.p12', '.pem', '.key', '~'))):
                continue
            path = Path(folder)/name
            if str(path.relative_to(root)) != BUILD_ASSET:
                paths.append(path)
    paths.extend(root/'design-studio'/name for name in STUDIO_PRODUCERS if (root/'design-studio'/name).exists())
    for path in paths:
        if path.is_symlink() or any(p.is_symlink() for p in path.parents if p != root.parent):
            raise ValueError('source symlinks are not supported: '+str(path))
    return sorted(paths)


def identities(root=None):
    root = Path(root or ROOT).resolve()
    return {str(p.relative_to(root)): digest(p.read_bytes()) for p in source_files(root)}


def catalog():
    all_kt = [(p, text, mask(text)) for p in (ROOT / 'android').glob('**/src/**/*.kt') if '/build/' not in str(p) for text in (p.read_text(),)]
    entries = []
    for p, text, code in all_kt:
        if not str(p.relative_to(ROOT)).startswith(DS + 'main/'): continue
        # Balanced argument scan keeps nested function types/default lambdas intact.
        for m in re.finditer(r'@Composable\s+(?:(public|private|internal)\s+)?fun\s+(\w+)\s*\(', code):
            if m.group(1) in ('private', 'internal'): continue
            start = m.end() - 1
            end = start + 1
            depth = 1
            while end < len(code) and depth:
                depth += (code[end] == '(') - (code[end] == ')')
                end += 1
            body_start = code.find('{', end)
            body_end = body_start + 1
            body_depth = 1
            while body_end < len(code) and body_depth:
                body_depth += (code[body_end] == '{') - (code[body_end] == '}')
                body_end += 1
            body = code[body_start:body_end]
            roles = set(re.findall(r'SoundQ\.(?:colors|spacing|sizes|typography)\.\w+', body))
            for alias, group in re.findall(r'\bval\s+(\w+)\s*=\s*SoundQ\.(colors|spacing|sizes|typography)\b', body):
                roles.update('SoundQ.'+group+'.'+role for role in re.findall(r'\b'+alias+r'\.(\w+)',body))
            name = m.group(2)
            refs = {'callers': [], 'tests': [], 'previews': []}
            for q, qt, qc in all_kt:
                for hit in re.finditer(r'\b' + name + r'\s*\(', qc):
                    if q == p and hit.start() <= end and hit.start() >= m.start(): continue
                    kind = 'tests' if '/androidTest/' in str(q) or '/test/' in str(q) else 'callers'
                    refs[kind].append({'file': str(q.relative_to(ROOT)), 'line': qc[:hit.start()].count('\n') + 1})
                    if '@Preview' in qc[:hit.start()] and q == p:
                        refs['previews'].append(refs[kind][-1])
            entries.append({'name': name, 'signature': text[code.find('fun', m.start()):end], 'file': str(p.relative_to(ROOT)), 'line': text[:m.start()].count('\n')+1, 'source_sha256': digest(p.read_bytes()), 'token_roles': sorted(roles), **refs})
    return {'schema': 1, 'components': sorted(entries, key=lambda x: (x['name'], x['file'])), 'identities': identities()}


def png(path):
    """Decode native Android 8-bit RGB/RGBA PNG, all five PNG row filters, stdlib only."""
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n': raise ValueError('not a PNG')
    pos, packed, header, ended = 8, bytearray(), None, False
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos+4])[0]
        kind = data[pos+4:pos+8]
        chunk = data[pos+8:pos+8+length]
        crc = struct.unpack('>I', data[pos+8+length:pos+12+length])[0]
        if zlib.crc32(kind+chunk) & 0xffffffff != crc: raise ValueError('PNG CRC mismatch')
        if kind == b'IHDR': header = struct.unpack('>IIBBBBB', chunk)
        if kind == b'IDAT': packed.extend(chunk)
        if kind == b'IEND': ended = True; break
        pos += length + 12
    if not header or not ended: raise ValueError('incomplete PNG')
    w, h, bits, color, comp, filt, interlace = header
    if bits != 8 or color not in (2, 6) or comp or filt or interlace: raise ValueError('requires noninterlaced RGB/RGBA 8-bit PNG')
    if not 0 < w*h <= 20_000_000: raise ValueError('PNG size limit')
    channels = 4 if color == 6 else 3
    raw = zlib.decompress(packed)
    stride = w*channels
    if len(raw) != h*(stride+1): raise ValueError('invalid PNG scanline size')
    previous = bytearray(stride)
    pixels = bytearray()
    for y in range(h):
        offset = y*(stride+1)
        filter_type = raw[offset]
        row = bytearray(raw[offset+1:offset+1+stride])
        if filter_type > 4: raise ValueError('unknown PNG filter')
        for x in range(stride):
            a = row[x-channels] if x >= channels else 0
            b = previous[x]
            c = previous[x-channels] if x >= channels else 0
            p = a+b-c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            predictor = (0, a, b, (a+b)//2, a if pa <= pb and pa <= pc else b if pb <= pc else c)[filter_type]
            row[x] = (row[x]+predictor) & 255
        if channels == 4: pixels.extend(row)
        else:
            for x in range(0, stride, 3): pixels.extend(row[x:x+3] + b'\xff')
        previous = row
    return w, h, bytes(pixels)


def compare(a, b, tolerance=0, max_changed=0):
    wa, ha, pa = png(a)
    wb, hb, pb = png(b)
    if (wa,ha) != (wb,hb): return {'status': 'diff', 'reason': 'dimensions changed'}
    deltas = [max(abs(pa[i+j]-pb[i+j]) for j in range(4)) for i in range(0,len(pa),4)]
    changed = sum(d > tolerance for d in deltas)
    return {'status': 'pass' if changed <= max_changed else 'diff', 'changed_pixels': changed, 'pixels': wa*ha, 'max_channel_delta': max(deltas), 'channel_tolerance': tolerance, 'max_changed_pixels': max_changed}


def validate_build(proof, sources):
    apk = proof.get('apk_sha256', '')
    binding = proof.get('embedded_binding', {})
    if (proof.get('build_mode') != 'isolated-source-snapshot'
            or binding.get('schema') != 1 or binding.get('build_mode') != proof.get('build_mode')
            or binding.get('sources') != sources
            or not re.fullmatch(r'[0-9a-f]{64}', proof.get('embedded_asset_sha256', ''))):
        raise ValueError('missing/mismatched embedded build source binding; use build_capture.py')
    if proof.get('producer') != 'design-studio/native_capture.py collect' or not re.fullmatch(r'[0-9a-f]{64}',apk) or proof.get('installed_apk_sha256') != apk or proof.get('source_identity_sha256') != digest(json.dumps(sources,sort_keys=True).encode()):
        raise ValueError('missing/mismatched native build provenance; use native_capture.py collect with fresh installed APK')


def validate(captures, request, harness=False):
    req = load(request)
    receipt = load(Path(captures) / 'receipt.json')
    if req.get('schema') != 1 or receipt.get('schema') != 1: raise ValueError('receipt schema mismatch')
    if req['sources'] != identities(): raise ValueError('stale request: source/token identities changed')
    if receipt.get('sources') != req['sources']: raise ValueError('render source identities mismatch')
    env = req.get('environment', {})
    required = {'sdk', 'fingerprint', 'model', 'density', 'fontScale', 'locale', 'renderer', 'widthDp'}
    if not required <= env.keys() or any(v is None or v == '' for v in env.values()): raise ValueError('missing environment')
    if env != receipt.get('environment'): raise ValueError('render environment mismatch')
    if env['density'] != 2 or env['widthDp'] != 360 or env['fontScale'] != 1: raise ValueError('expected 360dp at density 2 and base fontScale 1')
    if receipt.get('kind') != ('harness-only' if harness else 'android-compose-native'): raise ValueError('not native production evidence')
    if not harness:
        validate_build(receipt.get('build_provenance', {}), req['sources'])
        if receipt.get('build_binding') != receipt['build_provenance']['embedded_binding']:
            raise ValueError('native packaged build binding differs from host embedded APK binding')
    expected = req.get('cases')
    if not harness and expected != CASE_IDS: raise ValueError('unexpected requested case set')
    cases = receipt.get('cases', [])
    if sorted(c['id'] for c in cases) != sorted(expected) or len(set(c['id'] for c in cases)) != len(cases): raise ValueError('missing/duplicate/unexpected cases')
    for case in cases:
        if not re.fullmatch(r'[a-z0-9-]+', case['id']): raise ValueError('invalid case id')
        if case.get('file') != case['id']+'.png': raise ValueError('case filename mismatch')
        path = Path(captures) / case['file']
        w,h,pixels = png(path)
        if digest(path.read_bytes()) != case.get('sha256'): raise ValueError('image hash mismatch')
        if not harness and (w != 720 or h < 100): raise ValueError('invalid native capture dimensions')
        if not pixels: raise ValueError('empty capture')
    return req, receipt


def verify(captures, request, baselines, harness=False):
    req, receipt = validate(captures, request, harness)
    results = []
    for c in receipt['cases']:
        meta = Path(baselines)/ (c['id']+'.json')
        entry = {'id': c['id'], 'sha256': c['sha256']}
        if not meta.exists(): entry.update(status='unaccepted')
        else:
            base = load(meta)
            image = Path(baselines)/(c['id']+'.png')
            if base['environment'] != req['environment']: raise ValueError('baseline environment mismatch')
            if base['image_sha256'] != digest(image.read_bytes()): raise ValueError('baseline image modified')
            # Sources may intentionally evolve; current receipt must be current; baseline is historical.
            entry.update(compare(image, Path(captures)/c['file']))
        results.append(entry)
    return {'schema': 1, 'kind': receipt['kind'], 'status': 'pass' if all(x['status']=='pass' for x in results) else 'failed', 'policy': {'channel_tolerance': 0, 'max_changed_pixels': 0}, 'environment': req['environment'], 'sources': req['sources'], 'build_provenance': receipt.get('build_provenance', {'build_mode':'harness-only'}), 'cases': results}


def accept(captures, request, baselines, case_id, expected_hash, reviewer, reviewer_kind, rationale, harness=False):
    if not all((case_id, expected_hash, reviewer, reviewer_kind, rationale)) or not reviewer.strip() or not rationale.strip():
        raise ValueError('accept requires named case, exact sha256, reviewer, reviewer-kind and nonempty rationale')
    if reviewer_kind not in ('human', 'agent'): raise ValueError('reviewer-kind must be human or agent')
    req, receipt = validate(captures, request, harness)
    case = next((c for c in receipt['cases'] if c['id'] == case_id), None)
    if not case or case['sha256'] != expected_hash: raise ValueError('expected exact image hash mismatch or case missing')
    base = Path(baselines)
    base.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(Path(captures)/case['file'], base/case['file'])
    save(base/(case_id+'.json'), {'case':case_id,'kind':receipt['kind'],'image_sha256':expected_hash,'reviewer':reviewer,'reviewer_kind':reviewer_kind,'rationale':rationale,'approval_claim':'explicit baseline selection by '+reviewer_kind+'; not independent human approval','environment':req['environment'],'sources':req['sources']})


def write_png(path, width, height, pixels):
    def chunk(kind, data):
        return struct.pack('>I', len(data))+kind+data+struct.pack('>I', zlib.crc32(kind+data)&0xffffffff)
    raw = b''.join(b'\x00'+pixels[y*width*4:(y+1)*width*4] for y in range(height))
    Path(path).write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',width,height,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b''))


def report(output, result, captures, baselines):
    output = Path(output).resolve()
    for protected in (Path(baselines).resolve(), Path(captures).resolve()):
        if output == protected or output in protected.parents or protected in output.parents:
            raise ValueError('report output must not overlap captures or baselines')
    output.mkdir(parents=True, exist_ok=True)
    save(output/'result.json', result)
    cards = []
    for case in result['cases']:
        image = case['id']+'.png'
        shutil.copyfile(Path(captures)/image, output/image)
        panels = f'<h3>Current</h3><img src="{image}" alt="Current native capture">'
        baseline = Path(baselines)/image
        if baseline.exists():
            base_name = case['id']+'-baseline.png'
            shutil.copyfile(baseline, output/base_name)
            panels += f'<h3>Accepted baseline</h3><img src="{base_name}" alt="Historical baseline">'
            w,h,current = png(Path(captures)/image)
            bw,bh,old = png(baseline)
            if (w,h)==(bw,bh):
                diff = bytearray()
                for i in range(0,len(current),4):
                    diff.extend(bytes((255,0,100,255)) if current[i:i+4]!=old[i:i+4] else bytes((0,0,0,255)))
                diff_name = case['id']+'-diff.png'
                write_png(output/diff_name,w,h,bytes(diff))
                panels += f'<h3>Difference (pink = changed pixel)</h3><img src="{diff_name}" alt="Pixel difference map">'
        cards.append(f'<article><h2>{html.escape(case["id"])}</h2><pre>{html.escape(json.dumps(case,indent=2))}</pre>{panels}</article>')
    heading = 'HARNESS ONLY — synthetic pixel evidence' if result.get('kind') == 'harness-only' else 'Native evidence'
    (output/'index.html').write_text('<!doctype html><meta charset="utf-8"><title>'+heading+'</title><style>body{font:16px system-ui;background:#151719;color:#eee;margin:32px}article{display:inline-block;vertical-align:top;width:380px}img{max-width:360px}pre{white-space:pre-wrap}</style><h1>'+heading+' — '+html.escape(result['status'])+'</h1><p>No human approval implied. Exact pixels; zero tolerated changes.</p>'+''.join(cards)+'<h2>Environment and source identities</h2><pre>'+html.escape(json.dumps({'environment':result['environment'],'sources':result['sources'],'build_provenance':result.get('build_provenance', {})},indent=2))+'</pre>')


def catalog_html(data):
    cards=[]
    evidence = '<p>Native capture images pending; browser markup is not rendering proof.</p>'
    cards.append(evidence)
    for c in data['components']:
        link=c['file']
        cards.append('<article><h2>'+html.escape(c['name'])+'</h2><code>'+html.escape(link)+':'+str(c['line'])+'</code><pre>'+html.escape(c['signature'])+'</pre><pre>'+html.escape(json.dumps({k:v for k,v in c.items() if k not in ('name','signature')},indent=2))+'</pre></article>')
    return '<!doctype html><meta charset="utf-8"><title>SoundQ component API evidence</title><style>body{font:16px system-ui;margin:32px;max-width:1000px;background:#151719;color:#eee}a{color:#9fc9ff}article{border-top:1px solid #777}pre{white-space:pre-wrap}</style><h1>SoundQ native component catalog</h1><p>Generated from production Kotlin. No HTML component simulations. Visual reports are generated separately from explicit capture inputs.</p><input aria-label="Search components" placeholder="Search name, API, role, caller, test" oninput="document.querySelectorAll(\'article\').forEach(x=>x.hidden=!x.textContent.toLowerCase().includes(this.value.toLowerCase()))">'+''.join(cards)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    cat=sub.add_parser('catalog'); cat.add_argument('action',choices=['generate','check']); cat.add_argument('--output', default=str(HOME/'generated'))
    check=sub.add_parser('check'); check.add_argument('action',choices=['adoption']); check.add_argument('--catalog', required=True); check.add_argument('--source', action='append', required=True, help='Repository-relative Kotlin file; repeat for a bounded adoption check')
    visual=sub.add_parser('visual'); visual.add_argument('action',choices=['request','verify','report','accept'])
    visual.add_argument('--captures',default=str(HOME/'captures')); visual.add_argument('--request',default=str(HOME/'render-request.json')); visual.add_argument('--environment'); visual.add_argument('--baselines',default=str(HOME/'baselines')); visual.add_argument('--output',default=str(HOME/'evidence')); visual.add_argument('--case'); visual.add_argument('--sha256'); visual.add_argument('--reviewer'); visual.add_argument('--reviewer-kind',choices=['human','agent']); visual.add_argument('--rationale')
    args=parser.parse_args()
    try:
        authority = ROOT/'android/scripts/check-design.py'
        checked = subprocess.run([sys.executable, '-B', str(authority)], capture_output=True, text=True)
        if checked.returncode: raise ValueError('canonical design verification failed: '+checked.stdout+checked.stderr)
        if args.command=='catalog':
            data=catalog(); index=catalog_html(data)
            output=Path(args.output)
            if args.action=='generate': save(output/'catalog.json',data); (output/'index.html').write_text(index)
            elif load(output/'catalog.json') != data or (output/'index.html').read_text()!=index: raise ValueError('catalog stale; regenerate')
            print(json.dumps({'status':'ok','components':len(data['components'])})); return 0
        if args.command=='check':
            old=load(args.catalog)
            if old['identities'] != identities(): raise ValueError('catalog source/token identity stale; regenerate after review')
            targets=[]
            for name in args.source:
                relative=Path(name)
                if relative.is_absolute() or '..' in relative.parts or relative.suffix != '.kt':
                    raise ValueError('--source must be a repository-relative Kotlin file')
                path=ROOT/relative
                if path.is_symlink() or not path.resolve().is_relative_to(ROOT):
                    raise ValueError('--source must not escape the repository')
                if not path.is_file(): raise ValueError('adoption source missing: '+name)
                targets.append(path)
            errors=[f'{p.relative_to(ROOT)}: {e}' for p in targets for e in adoption_errors(p.read_text())]
            calls=set(re.findall(r'\bSoundQ\w+(?=\s*\()', '\n'.join(mask(p.read_text()) for p in targets)))
            known={c['name'] for c in old['components']}
            errors += ['unknown component: '+c for c in calls-known]
            if not calls: errors.append('no actual SoundQ component adoption')
            if errors: raise ValueError('\n'.join(errors))
            print(json.dumps({'status':'ok','files':[str(p.relative_to(ROOT)) for p in targets],'components':sorted(calls)})); return 0
        if args.action=='request':
            if not args.environment: raise ValueError('--environment JSON required (actual pinned device contract)')
            save(args.request,{'schema':1,'environment':load(args.environment),'sources':identities(),'cases':CASE_IDS})
            print('render request written; not render evidence'); return 0
        if args.action=='accept':
            accept(args.captures,args.request,args.baselines,args.case,args.sha256,args.reviewer,args.reviewer_kind,args.rationale)
            print('accepted '+args.case+' by '+args.reviewer_kind+' '+args.reviewer); return 0
        result=verify(args.captures,args.request,args.baselines)
        report(args.output,result,args.captures,args.baselines)
        print(json.dumps({'status':result['status'],'cases':len(result['cases']),'report':str(Path(args.output)/'index.html')}))
        return 0 if result['status']=='pass' else 1
    except (ValueError,KeyError,OSError,StopIteration,struct.error,zlib.error) as e:
        print('ERROR: '+str(e),file=sys.stderr); return 2

if __name__=='__main__': sys.exit(main())
