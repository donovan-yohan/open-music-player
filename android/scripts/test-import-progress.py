#!/usr/bin/env python3
"""Exact-owner / dock source-host checks. No SDK, Gradle or network.

Platform/transport facades are explicit. This is not mounted Compose evidence.
Supply an existing dependency directory containing serialization, coroutines,
OkHttp and Okio jars. All outputs belong to --out.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[2])
p.add_argument('--out', type=Path, required=True)
p.add_argument('--dependencies', type=Path)
p.add_argument('--dock-source', type=Path, help='Optional preserved ProductApp source for causal root-wiring replay')
p.add_argument('--case', choices=['root', 'owner'], default='owner')
a = p.parse_args()
b = a.source / 'android/app/src/main/kotlin/com/soundq/android'
o = a.out.resolve()
o.mkdir(parents=True, exist_ok=True)
dock_path = a.dock_source or b / 'product/ProductApp.kt'
root = dock_path.read_text()
if a.case == 'root':
    dock = root[root.index('                    SoundQCompactPlayer('):root.index('                    SoundQBottomNavigation(')]
    preceding = root[:root.index('                    SoundQCompactPlayer(')]
    assert preceding.rstrip().endswith('ImportProgressStrip(model,::openImports)'), 'root dock has no compact current-batch strip above Now playing'
    assert root.count('ImportProgressStrip(model,::openImports)') == 1
    assert 'ImportProgressLifecycle(model)' in root
    print('PASS one root strip immediately above the shared player; independent lifecycle binding')
    raise SystemExit(0)
if not a.dependencies:
    p.error('--dependencies required for owner checks')

def emit(name, text):
    (o / name).write_text(text)

def block(text, anchor):
    start = text.index(anchor)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

fixtures = Path(__file__).parent / 'fixtures/import-progress'
for name in ['Data.kt', 'Discovery.kt', 'Playlists.kt', 'Journey.kt', 'CompositionChecks.kt']:
    emit(name, (fixtures / name).read_text())
import runpy
for name, text in runpy.run_path(str(fixtures / 'facades.py'))['FACADES'].items():
    emit(name, text)
vm = (b / 'product/ProductViewModel.kt').read_text()
selected = vm[vm.index('    val imports='):vm.index('    val playlists=')]
emit('ProductViewModel.kt', '''package com.soundq.android.product
import com.soundq.android.data.*
import com.soundq.android.data.imports.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
class Acquisition {val state=MutableStateFlow(0)}
class Graph(val session:AccountSession,val imports:ImportRepository) {val acquisition=Acquisition()}
class Controller {fun toggle(){}}
class Projection {val title:String?=null;val artist="";val isPlaying=false;val canPlay=false;val preparing=false}
fun compactSongTiming(p:Projection)=Any()
// Only dispatcher mapping: deterministic worker admission, unchanged production collector body.
object Dispatchers {val IO=kotlinx.coroutines.Dispatchers.Unconfined}
class ProductViewModel(val graph:Graph,val viewModelScope:CoroutineScope) {
 val controller=Controller()
''' + selected + '\n}\n')
anchor = '                    ImportProgressStrip(model,::openImports)' if '                    ImportProgressStrip(model,::openImports)' in root else '                    SoundQCompactPlayer('
dock = root[root.index(anchor):root.index('                    SoundQBottomNavigation(')]
emit('Dock.kt', '''package com.soundq.android.product
import com.soundq.android.product.imports.*
import com.soundq.designsystem.*
import androidx.compose.ui.unit.dp
fun renderDock(model:ProductViewModel,destination:String,onOpen:()->Unit={}) {
 val playback=Projection();var panel:String?=null;var transportReturn:String?=null
 val compactEntry=java.util.concurrent.atomic.AtomicBoolean(true)
 fun openImports(){onOpen()}
''' + dock + '\n}\n')
paths = ['data/AccountSession.kt', 'data/Contracts.kt', 'data/imports/Imports.kt',
         'data/imports/ImportRepository.kt', 'data/imports/ImportProgress.kt',
         'data/acquisition/IntakeReceipts.kt', 'product/imports/ImportProgressStrip.kt']
sources = [b / path for path in paths]
jars = sorted(a.dependencies.glob('*.jar'))
assert jars, 'existing copied dependencies are required'
cp = os.pathsep.join(map(str, jars))
env = dict(os.environ, TMPDIR=str(o), JAVA_OPTS='-Xmx512m -XX:ActiveProcessorCount=2 -Djava.io.tmpdir=' + str(o))
cmd = ['kotlinc', '-J-Xmx512m', '-J-XX:ActiveProcessorCount=2', *map(str, sources),
       *map(str, o.glob('*.kt')), '-cp', cp, '-include-runtime', '-d', str(o / 'checks.jar')]
c = subprocess.run(cmd, env=env, capture_output=True, text=True)
(o / 'compile.log').write_text(c.stdout + c.stderr)
if c.returncode:
    print(c.stdout + c.stderr)
    raise SystemExit(c.returncode)
r = subprocess.run(['java', '-Xmx512m', '-XX:ActiveProcessorCount=2', '-Djava.io.tmpdir=' + str(o),
                    '-cp', str(o / 'checks.jar') + os.pathsep + cp, 'com.soundq.android.data.JourneyKt'],
                   env=env, capture_output=True, text=True)
(o / 'run.log').write_text(r.stdout + r.stderr)
(o / 'receipt.json').write_text(json.dumps({'exit': r.returncode,
    'sources': {str(s): hashlib.sha256(s.read_bytes()).hexdigest() for s in sources + list(o.glob('*.kt'))},
    'dock_source': str(dock_path), 'dock_sha256': hashlib.sha256(dock_path.read_bytes()).hexdigest(),
    'dependencies': {s.name: hashlib.sha256(s.read_bytes()).hexdigest() for s in jars}}, indent=2))
print(r.stdout + r.stderr)
raise SystemExit(r.returncode)
