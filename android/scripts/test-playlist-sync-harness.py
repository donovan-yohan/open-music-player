#!/usr/bin/env python3
"""Actual sync runner/JUnit and launcher failure boundaries; SDK-free, local only."""
import argparse
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import unittest
from unittest import mock
import uuid

p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--cache',type=Path,required=True)
p.add_argument('--out',type=Path,required=True)
a,remaining=p.parse_known_args()
r=Path(__file__).resolve().parents[1]
a.out.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',TMPDIR=str(a.out),JAVA_TOOL_OPTIONS='-Xmx512m -XX:ActiveProcessorCount=1')

def call(name,argv,extra=None):
    e=dict(env)
    for key,value in (extra or {}).items():
        if value is None:e.pop(key,None)
        else:e[key]=value
    q=subprocess.run(list(map(str,argv)),env=e,stdin=subprocess.DEVNULL,capture_output=True,text=True,timeout=90)
    (a.out/(name+'.log')).write_text(q.stdout+q.stderr)
    (a.out/(name+'.json')).write_text(json.dumps({'argv':list(map(str,argv)),'exit':q.returncode,'python_optimize_env':e.get('PYTHONOPTIMIZE')},indent=2))
    return q

def jar(group,artifact,version):
    matches=list((a.cache/'modules-2/files-2.1'/group/artifact/version).glob('*/*.jar'))
    if len(matches)!=1:raise RuntimeError((group,artifact,version,matches))
    return str(matches[0])

class Harness(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cp=os.pathsep.join([jar(*x) for x in [('junit','junit','4.13.2'),('org.hamcrest','hamcrest-core','1.3'),('org.jetbrains.kotlinx','kotlinx-serialization-json-jvm','1.12.0'),('org.jetbrains.kotlinx','kotlinx-serialization-core-jvm','1.12.0')]])
        fixture=a.out/'RunnerCases.kt'
        fixture.write_text('''package runnercontrols
import org.junit.*
class BeforeFailure {companion object {@JvmStatic @BeforeClass fun before(){error("expected suite failure")}};@Test fun unreachable(){error("unreachable")}}
class Cases {
 @Test fun ordinaryPass(){}
 @Test fun ordinaryFailure(){Assert.fail("expected leaf failure")}
 @Test fun assumed(){Assume.assumeTrue("expected assumption",false);error("unreachable")}
 @Ignore @Test fun ignored(){error("unreachable")}
}
''')
        q=call('runner-compile',['kotlinc','-J-Xmx512m','-J-XX:ActiveProcessorCount=1',r/'scripts/host-tests/PlaylistSyncNamedRunner.kt',fixture,'-cp',cls.cp,'-include-runtime','-d',a.out/'runner.jar'])
        if q.returncode:raise RuntimeError(q.stdout+q.stderr)
        cls.events=a.out/('runner-events-'+uuid.uuid4().hex+'.jsonl')
        cls.execution=call('runner-execute',['java','-Xmx512m','-XX:ActiveProcessorCount=1','-Dsoundq.tests.events='+str(cls.events),'-cp',str(a.out/'runner.jar')+os.pathsep+cls.cp,'com.soundq.android.data.PlaylistSyncNamedRunner','runnercontrols.BeforeFailure','runnercontrols.Cases'])
        if not cls.events.is_file():raise RuntimeError('JUnit invocation produced no fresh terminal events')
        cls.rows=[json.loads(line) for line in cls.events.read_text().splitlines() if line.strip()]

    def test_actual_class_and_leaf_failures_are_both_recorded_once(self):
        self.assertNotEqual(0,self.execution.returncode)
        fails=[x['test'] for x in self.rows if x['status']=='fail']
        self.assertEqual(['runnercontrols.BeforeFailure#null','runnercontrols.Cases#ordinaryFailure'],sorted(fails))
        self.assertEqual(len(self.rows),len({x['test'] for x in self.rows}))
        self.assertIn({'test':'runnercontrols.Cases#ordinaryPass','status':'pass'},self.rows)

    def test_actual_assumption_and_ignore_events_are_skips_not_passes(self):
        statuses={x['test']:x['status'] for x in self.rows}
        self.assertEqual('skip',statuses['runnercontrols.Cases#assumed'])
        self.assertEqual('skip',statuses['runnercontrols.Cases#ignored'])

    def test_actual_launcher_excludes_stale_sources_and_refuses_failed_compile_under_optimization(self):
        for optimize in (False,True):
            for failure in (False,True):
                with self.subTest(optimize=optimize,failure=failure):
                    out=a.out/f'launcher-{optimize}-{failure}';out.mkdir(exist_ok=True)
                    stale=out/'Unrelated.kt';stale.write_text('not Kotlin; must never be compiled')
                    oldjar=out/'tests.jar';oldjar.write_bytes(b'retained stale jar')
                    tools=out/'tools';tools.mkdir(exist_ok=True)
                    compiler=tools/'kotlinc';java=tools/'java'
                    compiler.write_text('#!'+sys.executable+'\nimport os,sys,json\nfrom pathlib import Path\na=sys.argv[1:]\nPath(os.environ["COMPILER_ARGS"]).write_text(json.dumps(a))\nif os.environ["FAIL_COMPILE"]=="1":sys.exit(23)\nif any(x.endswith("Unrelated.kt") for x in a):sys.exit(41)\nPath(a[a.index("-d")+1]).write_bytes(b"new compiled boundary jar")\n')
                    java.write_text('#!'+sys.executable+'\nimport os\nfrom pathlib import Path\nPath(os.environ["JAVA_CALLED"]).write_text("called")\n')
                    compiler.chmod(0o755);java.chmod(0o755)
                    marker=out/('java-called-'+uuid.uuid4().hex);argv=[sys.executable]+(['-O'] if optimize else [])+[r/'scripts/test-playlist-source-sync.py','--cache',a.cache,'--out',out]
                    extra={'PATH':str(tools)+os.pathsep+os.environ['PATH'],'COMPILER_ARGS':str(out/'compiler-args.json'),'JAVA_CALLED':str(marker),'FAIL_COMPILE':'1' if failure else '0','PYTHONOPTIMIZE':None}
                    mode=call(f'python-mode-{optimize}-{failure}',[sys.executable]+(['-O'] if optimize else [])+['-c','import sys; print(sys.flags.optimize)'],extra)
                    self.assertEqual(0,mode.returncode);self.assertEqual(int(optimize),int(mode.stdout.strip()))
                    q=call(f'launcher-{optimize}-{failure}',argv,extra)
                    if failure:
                        self.assertEqual(23,q.returncode,q.stdout+q.stderr);self.assertFalse(marker.exists());self.assertEqual(b'retained stale jar',oldjar.read_bytes())
                    else:
                        self.assertEqual(0,q.returncode,q.stdout+q.stderr);self.assertTrue(marker.is_file());self.assertEqual(b'new compiled boundary jar',oldjar.read_bytes())
                    self.assertNotIn(str(stale),json.loads((out/'compiler-args.json').read_text()))

    def generated_product(self,name,edit):
        src=r/'app/src/main/kotlin/com/soundq/android';root=a.out/name
        (root/'product/playlists').mkdir(parents=True,exist_ok=True)
        product=edit((src/'product/ProductApp.kt').read_text())
        (root/'product/ProductApp.kt').write_text(product)
        (root/'product/playlists/PlaylistSourceSyncControls.kt').write_bytes((src/'product/playlists/PlaylistSourceSyncControls.kt').read_bytes())
        out=root/'generated';out.mkdir(exist_ok=True)
        runpy.run_path(str(r/'scripts/host-tests/generate_playlist_sync_probes.py'))['generate'](root,out)
        return (out/'ProductSyncLifecycleProbe.kt').read_text()

    def test_generator_backtick_brace_identifier_keeps_callback(self):
        text=self.generated_product('backtick',lambda s:s.replace('fun sync() {','fun sync() {\n val `}` = 1\n',1))
        self.assertIn('if(!foreground)model.graph.playlistSync.retire()',text)
        self.assertIn('blendForeground=foreground',text)

    def test_generator_ignores_commented_sync_declaration(self):
        text=self.generated_product('commented-declaration',lambda s:s.replace('fun sync() {','// fun sync() {}\n        fun sync() {',1))
        self.assertIn('if(!foreground)model.graph.playlistSync.retire()',text)
        self.assertIn('blendForeground=foreground',text)

    def test_generator_does_not_reexpand_markers_in_inserted_code(self):
        literal='val labels=listOf("POLL","DISPOSE","KEYS","VISIBLE","CALLBACK")'
        text=self.generated_product('literal-markers',lambda s:s.replace('fun sync() {','fun sync() {\n '+literal+'\n',1))
        self.assertIn(literal,text)

    def test_generator_ignores_comment_string_and_character_braces(self):
        src=r/'app/src/main/kotlin/com/soundq/android'
        root=a.out/'lexical-input';(root/'product/playlists').mkdir(parents=True,exist_ok=True)
        product=(src/'product/ProductApp.kt').read_text().replace('fun sync() {','fun sync() {\n // }\n /* nested /* } */ } */\n val brace=\'}\'\n val raw=""" } { """\n',1)
        controls=(src/'product/playlists/PlaylistSourceSyncControls.kt').read_text().replace('Column {','Column {\n // }\n',1).replace('"Reading source…"','"Reading } source…"')
        (root/'product/ProductApp.kt').write_text(product);(root/'product/playlists/PlaylistSourceSyncControls.kt').write_text(controls)
        out=a.out/'lexical-output';out.mkdir(exist_ok=True)
        runpy.run_path(str(r/'scripts/host-tests/generate_playlist_sync_probes.py'))['generate'](root,out)
        lifecycle=(out/'ProductSyncLifecycleProbe.kt').read_text();render=(out/'SourceSyncControlProbe.kt').read_text()
        self.assertIn('if(!foreground)model.graph.playlistSync.retire()',lifecycle)
        self.assertIn('blendForeground=foreground',lifecycle)
        self.assertIn('source.operation?.let',render)
        self.assertIn('SoundQButton("Read sync status",onRead',render)
        # Legitimate string edits retain the exact source span; malformed input
        # is refused, not silently returned as a truncated successful body.
        extractor=runpy.run_path(str(r/'scripts/host-tests/generate_playlist_sync_probes.py'))['block']
        sample='fun f() { val s="${ if(true) "}" else "{" }"; /* } /* { */ */ val c=\'}\'; val r=""" } """; done() }'
        self.assertEqual(sample[sample.index('{')+1:-1],extractor(sample,0))
        with self.assertRaises(ValueError):extractor('fun f() { /* unterminated',0)

class Freshness(unittest.TestCase):
    def test_aborted_actual_java_cannot_reuse_previous_junit_events(self):
        out=a.out/'aborted-runner';out.mkdir(exist_ok=True)
        with mock.patch.object(a,'out',out):
            Harness.setUpClass()
            previous=Harness.events.read_bytes()
            real_call=call
            def abort(name,argv,extra=None):
                if name=='runner-execute':argv=[argv[0],'-XX:SoundQDeliberatelyInvalidOption=1',*argv[1:]]
                return real_call(name,argv,extra)
            with mock.patch.dict(globals(),{'call':abort}):
                with self.assertRaises((RuntimeError,FileNotFoundError)):
                    Harness.setUpClass()
            self.assertTrue(any(f.read_bytes()==previous for f in out.glob('*events*.jsonl')))

    def test_stale_java_marker_cannot_hide_missing_current_dispatch(self):
        out=a.out/'stale-marker';out.mkdir(exist_ok=True)
        scripts=out/'fault-input/scripts';(scripts/'host-tests').mkdir(parents=True,exist_ok=True)
        source=(r/'scripts/test-playlist-source-sync.py').read_text()
        head,tail=source.split("cmd=['java'",1)
        tail=tail.replace('subprocess.run(cmd,capture_output=True,text=True,env=env)',"subprocess.CompletedProcess(cmd,0,'','')",1)
        faulty=scripts/'test-playlist-source-sync.py';faulty.write_text(head+"cmd=['java'"+tail)
        for name in ['PlaylistSyncLifecycleTest.kt','PlaylistSyncNamedRunner.kt','generate_playlist_sync_probes.py']:
            (scripts/'host-tests'/name).write_bytes((r/'scripts/host-tests'/name).read_bytes())
        for optimize in (False,True):
            case=out/f'launcher-{optimize}-False';case.mkdir(exist_ok=True);(case/'java-called').write_text('old invocation')
        real_call=call
        def omit(name,argv,extra=None):
            argv=[str(faulty) if str(x)==str(r/'scripts/test-playlist-source-sync.py') else x for x in argv]
            if str(faulty) in argv:argv=[*argv,'--source-root',r,'--tests-root',r]
            return real_call(name,argv,extra)
        with mock.patch.object(a,'out',out),mock.patch.dict(globals(),{'call':omit}),mock.patch.dict(env,{'PYTHONOPTIMIZE':''}):
            with self.assertRaises(AssertionError):
                Harness('test_actual_launcher_excludes_stale_sources_and_refuses_failed_compile_under_optimization').test_actual_launcher_excludes_stale_sources_and_refuses_failed_compile_under_optimization()

if __name__=='__main__':
    unittest.main(argv=[__file__,*remaining])
