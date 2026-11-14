#!/usr/bin/env python3
"""Executable negative CLI checks. All fixture pixels/Kotlin are HARNESS ONLY."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys

import importlib.util
spec=importlib.util.spec_from_file_location('harness_test_visual',Path(__file__).parent/'tests/test_visual.py')
assert spec and spec.loader
fixture_module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture_module)
fixture_png, s=fixture_module.fixture_png,fixture_module.s

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True, help='New, empty owned directory for synthetic test results')
out=Path(parser.parse_args().output).resolve()
if out.exists() and any(out.iterdir()):
    raise SystemExit('--output must be empty; refusing to overwrite retained artifacts')
out.mkdir(parents=True, exist_ok=True)
repo=out/'fixture-repo'
cli=repo/'design-studio/studio.py'
cli.parent.mkdir(parents=True,exist_ok=True)
shutil.copyfile(s.HOME/'studio.py',cli)
authority=repo/'android/scripts/check-design.py'
authority.parent.mkdir(parents=True,exist_ok=True)
authority.write_text('print("HARNESS ONLY canonical fixture authority; not production token proof")\n', encoding='utf-8')
components=repo/'android/designsystem/src/main/kotlin/Components.kt'
components.parent.mkdir(parents=True,exist_ok=True)
components.write_text('@Composable fun SoundQButton(label: String, onClick: () -> Unit) {}\n', encoding='utf-8')
feature=repo/'android/app/src/main/kotlin/StudioHarnessFeature.kt'
feature.parent.mkdir(parents=True,exist_ok=True)
results=[]
def run(label,args,expected, script=cli, diagnostic=None):
    if args[:2] == ['check', 'adoption']:
        args=[*args, '--catalog', str(repo/'design-studio/generated/catalog.json'), '--source', str(feature.relative_to(repo))]
    p=subprocess.run([sys.executable, '-B',str(script),*args],text=True,capture_output=True)
    results.append({'label':label,'exit':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip()})
    if p.returncode!=expected: raise AssertionError(results[-1])
    if diagnostic is not None and (diagnostic not in p.stderr or 'no actual SoundQ component adoption' in p.stderr):
        raise AssertionError(results[-1])

feature.write_text('SoundQButton("Apply", {}) // Button( Color.Red\nval label="TextField( Color(0xff)"\n', encoding='utf-8')
run('generate fixture catalog',['catalog','generate'],0)
run('valid adoption with harmless strings/comments',['check','adoption'],0)
run('fresh catalog check',['catalog','check'],0)
run('source traversal refused',['check','adoption','--source','../outside.kt'],2)
run('missing source refused',['check','adoption','--source','missing.kt'],2)
feature.write_text('SoundQButton("Apply", {}); Button(onClick={}) {}\n', encoding='utf-8')
run('stale source fails before adoption',['check','adoption'],2)
run('refresh fixture catalog',['catalog','generate'],0)
run('stock Button replacement rejected',['check','adoption'],2, diagnostic='stock Button;')
feature.write_text('import androidx.compose.material3.TextField as Input\nSoundQButton("Apply", {}); Input(value="",onValueChange={})\n', encoding='utf-8')
run('refresh alias fixture catalog',['catalog','generate'],0)
run('stock TextField alias rejected',['check','adoption'],2, diagnostic='stock Input;')
feature.write_text('SoundQButton("Apply", {}); val bad=Color(0xff123456)\n', encoding='utf-8')
run('refresh raw color catalog',['catalog','generate'],0)
run('raw color rejected',['check','adoption'],2, diagnostic='raw color;')
feature.write_text('SoundQUnknown("Apply", {})\n', encoding='utf-8')
run('refresh unknown component catalog',['catalog','generate'],0)
run('unknown component rejected',['check','adoption'],2)
authority.write_text('raise SystemExit(1) # HARNESS ONLY canonical verification refusal\n', encoding='utf-8')
run('canonical verification failure propagates',['catalog','generate'],2)
run('missing native captures refused',['visual','verify','--captures',str(out/'missing'),'--request',str(out/'missing.json')],2, s.HOME/'studio.py')
run('accept without reviewer/rationale refused',['visual','accept','--case','components-light-default','--sha256','0'*64],2,s.HOME/'studio.py')
# Real PNG decode/compare exercise, deliberately 2x1 synthetic harness images.
fixture_png(out/'before-HARNESS.png')
fixture_png(out/'after-HARNESS.png',True)
comparison=s.compare(out/'before-HARNESS.png',out/'after-HARNESS.png')
assert comparison['status']=='diff' and comparison['changed_pixels']==1 and comparison['max_channel_delta']==255
pixel_captures=out/'pixel-captures';pixel_baselines=out/'pixel-baselines'
pixel_captures.mkdir(exist_ok=True);pixel_baselines.mkdir(exist_ok=True)
shutil.copyfile(out/'before-HARNESS.png',pixel_captures/'harness-only.png')
shutil.copyfile(out/'before-HARNESS.png',pixel_baselines/'harness-only.png')
for label in ('pass','diff'):
    if label=='diff':shutil.copyfile(out/'after-HARNESS.png',pixel_captures/'harness-only.png')
    measured=s.compare(pixel_baselines/'harness-only.png',pixel_captures/'harness-only.png')
    s.report(out/('pixel-report-'+label),{'kind':'harness-only','status':measured['status'],'environment':{'label':'HARNESS ONLY — tiny synthetic PNG, not Android output'},'sources':{},'cases':[{'id':'harness-only','sha256':s.digest((pixel_captures/'harness-only.png').read_bytes()),**measured}]},pixel_captures,pixel_baselines)
s.save(out/'results.json',{'kind':'harness-only','cli_checks':results,'actual_png_difference':comparison})
print(json.dumps({'kind':'harness-only','cli_checks':len(results),'actual_png_difference':comparison,'artifacts':str(out)},indent=2))
