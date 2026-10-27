#!/usr/bin/env python3
"""Android Library production-source contracts and opt-in Kotlin behavior gate.

--source-only never invokes a compiler. Missing-seam failures are API/source
tracers, NOT behavioral RED. --compiled requires the parent's compiler admission.
Platform rendering, TalkBack, IME, audio and device acceptance remain separate.
The compiled lane also requires the registered native Android presentation gate
and its independent mutation witnesses (without a device or PlaybackService).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path('native/android/app/src/main/java/com/soundq/nativepreview')
RES = Path('native/android/app/src/main/res')


class SourceContracts(unittest.TestCase):
    def test_service_has_acknowledged_browse_entrypoint(self):
        source = (ROOT / PACKAGE / 'PlaybackService.kt').read_text()
        self.assertIn('fun browseLibrary(', source, 'missing acknowledged Library production entrypoint')
        self.assertIn('fun favoriteLibraryTrack(', source)
        self.assertIn('next.put("favorite_track_ids",snapshot.optJSONArray("favorite_track_ids")', source)

    def test_mounted_mobile_shell_and_real_controls(self):
        source = (ROOT / PACKAGE / 'MainActivity.kt').read_text()
        for seam in ('SoundQViews', 'browseLibrary(', 'favoriteLibraryTrack(', 'showQueue()', 'WindowInsets', 'library_unchanged'):
            self.assertIn(seam, source)
        self.assertNotIn('Native preview · Rust ABI', source)
        self.assertNotIn('Color.rgb(13, 20, 28)', source)
        self.assertIn('if(service === row.serviceOwner)', source)

    def test_semantic_tokens_and_local_asset_identity(self):
        self.assertTrue((ROOT / RES / 'values/soundq_colors.xml').is_file(), 'missing SoundQ token mapping')
        colors = {node.attrib['name']: node.text for node in ET.parse(ROOT / RES / 'values/soundq_colors.xml').getroot()}
        for name, value in {'soundq_background':'#050505', 'soundq_surface':'#14110D', 'soundq_surface_raised':'#211A13', 'soundq_text_primary':'#F4EDDC', 'soundq_text_secondary':'#A89F90', 'soundq_outline':'#32281F', 'soundq_orange':'#FF5A00', 'soundq_accent':'#39C6B6'}.items():
            self.assertEqual(colors.get(name), value)
        manifest = json.loads((ROOT / RES / 'raw/soundq_asset_manifest.json').read_text())
        self.assertGreaterEqual(len(manifest['files']), 6)
        for entry in manifest['files']:
            self.assertEqual(hashlib.sha256((ROOT / RES / entry['path']).read_bytes()).hexdigest(), entry['sha256'])

    def test_resource_references_resolve_and_xml_parses(self):
        import re
        resources = set()
        for file in (ROOT / RES).rglob('*'):
            if not file.is_file():
                continue
            kind = file.parent.name.split('-')[0]
            if file.suffix == '.xml':
                document = ET.parse(file).getroot()
                if kind == 'values':
                    resources.update((node.tag,node.attrib['name']) for node in document if 'name' in node.attrib)
                else:
                    resources.add((kind,file.stem))
            else:
                resources.add((kind,file.stem))
        for file in (ROOT / PACKAGE).glob('*.kt'):
            for kind, name in re.findall(r'(?<!android\.)\bR\.(\w+)\.(\w+)',file.read_text()):
                self.assertIn((kind,name),resources,f'unresolved {file.name}: R.{kind}.{name}')

    def test_existing_queue_disclosure_bytes_preserved(self):
        source = (ROOT / PACKAGE / 'MainActivity.kt').read_text()
        start = source.index('    private fun dismissQueueActions()')
        end = source.index('    override fun onDestroy()',start)
        queue = source[start:end]
        # Immutable predecessor method pair, not a gate for the new layout.
        self.assertEqual(hashlib.sha256(queue.encode()).hexdigest(),'4385b2dc7c180511005d150b505acb36c50f71f5c591e6742885f54de98e0e3f')


BEHAVIOR = r'''
fun main() {
 baselineControls()
 var failed=0
 fun test(name:String, body:()->Unit) {try {body();println("PASS library-$name")}catch(e:Throwable){failed++;println("FAIL library-$name ${e.message}")}}
 fun row(id:Long)=JSONObject().put("id",id).put("title","Recording $id")
 fun snap(epoch:Long=1,rev:Long=1)=JSONObject().put("authenticated",true).put("epoch",epoch).put("session",1L).put("library_revision",rev)
   .put("library",JSONArray(listOf(row(1),row(2)))).put("favorite_track_ids",JSONArray()).put("total",40L).put("offset",0)
 fun reply(s:JSONObject,ok:Boolean=true,code:String="ok")=JSONObject().put("ok",ok).put("code",code).put("snapshot",s)
 fun adapter()=PlaybackService().apply {snapshot=snap()}
 test("pending-liked-keeps-acknowledged-all-and-queue") {
  val a=adapter();val queue=JSONArray(listOf(row(11)));a.snapshot.put("queue",queue);val player=a.player
  a.browseLibrary(liked=true);check(a.libraryBrowse.loading && !a.libraryBrowse.liked);check(a.snapshot.optJSONArray("queue")===queue && a.player===player)
  a.selectLibraryTrack(1);a.favoriteLibraryTrack(1,false);check(a.worker.tasks.size==1)
  a.bridge.replies.add(reply(snap(rev=2).put("queue_unchanged",true)));a.drain()
  check(a.libraryBrowse.liked && !a.libraryBrowse.loading && a.snapshot.optJSONArray("queue")===queue)
  check(a.bridge.calls.single().optString("command")=="library_liked")
 }
 test("refused-liked-keeps-rows-mode-and-actionable-failure") {
  val a=adapter();val old=a.snapshot.optJSONArray("library");a.browseLibrary(query="x".repeat(513),liked=true)
  a.bridge.replies.add(reply(snap().put("library",old!!),false,"invalid_query"));a.drain()
  check(!a.libraryBrowse.liked && !a.libraryBrowse.loading && a.snapshot.optJSONArray("library")===old)
  check(a.libraryBrowse.failure!!.contains("Shorten"))
 }
 test("accepted-empty-is-not-loading-or-failure") {
  val a=adapter();a.browseLibrary(liked=true);a.bridge.replies.add(reply(snap(rev=2).put("library",JSONArray()).put("total",0L)));a.drain()
  check(a.libraryBrowse.liked && !a.libraryBrowse.loading && a.libraryBrowse.failure==null && a.snapshot.optJSONArray("library")!!.length()==0)
 }
 test("paging-exact-acknowledged-query-and-mode") {
  val a=adapter();a.browseLibrary(query="音楽",liked=true);a.bridge.replies.add(reply(snap(rev=2)));a.drain()
  a.browseLibrary(offset=20,query="音楽",liked=true);a.bridge.replies.add(reply(snap(rev=3)));a.drain();check(a.bridge.calls.last().optLong("offset")==20L)
  a.browseLibrary(offset=20,query="other",liked=true);check(a.libraryBrowse.pending!!.offset==0)
 }
 test("favorite-is-desired-state-no-optimistic-heart-or-double-write") {
  val a=adapter();a.favoriteLibraryTrack(1,false);a.favoriteLibraryTrack(1,false)
  check(a.libraryBrowse.favoritePending && !LibraryBrowseState.favorite(a.snapshot,1) && a.worker.tasks.size==1)
  a.bridge.replies.add(reply(snap().put("favorite_track_ids",JSONArray(longs=listOf(1L)))));a.drain()
  check(!a.libraryBrowse.favoritePending && LibraryBrowseState.favorite(a.snapshot,1))
  check(a.bridge.calls.single().optString("command")=="set_favorite" && a.bridge.calls.single().optBoolean("liked"))
 }
 test("transport-topic-keeps-favorites") {
  val a=adapter();a.snapshot.put("favorite_track_ids",JSONArray(longs=listOf(1L)))
  a.bridge.replies.add(reply(snap().put("library_unchanged",true)));a.command(JSONObject().put("command","snapshot"));a.drain()
  check(LibraryBrowseState.favorite(a.snapshot,1))
 }
 test("uncertain-favorite-refuses-toggle-until-explicit-read") {
  val a=adapter();a.favoriteLibraryTrack(1,false);a.bridge.replies.add(reply(snap(),false,"favorite_uncertain"));a.drain()
  check(a.libraryBrowse.invalid && a.libraryBrowse.failure!!.contains("Refresh"));val count=a.bridge.calls.size
  a.favoriteLibraryTrack(1,false);check(a.bridge.calls.size==count && a.worker.tasks.isEmpty())
  a.browseLibrary();a.bridge.replies.add(reply(snap(rev=2)));a.drain();check(!a.libraryBrowse.invalid)
 }
 test("held-read-retired-by-new-selection-does-not-adopt-mode") {
  val a=adapter();a.browseLibrary(liked=true);a.bridge.replies.add(reply(snap(rev=2)));a.worker.one()
  a.select(2);a.bridge.replies.add(reply(snap(a.epoch,2)));a.drain();check(!a.libraryBrowse.liked && !a.libraryBrowse.loading)
 }
 test("retired-read-inherited-by-sibling-keeps-display-but-refuses-selection") {
  val a=adapter();val old=a.snapshot.optJSONArray("library");a.browseLibrary(liked=true)
  a.bridge.replies.add(reply(snap(rev=2)));a.worker.one();a.select(2);a.bridge.replies.add(reply(snap(a.epoch,2)));a.drain()
  a.snapshot=snap(a.epoch,2).put("library",JSONArray(listOf(row(99))))
  check(a.snapshot.optJSONArray("library")===old && a.libraryBrowse.invalid && !a.libraryBrowse.canUseRows(a.snapshot,a.epoch))
 }
 test("account-retirement-clears-browse-identity") {
  val a=adapter();a.browseLibrary(liked=true);a.bridge.replies.add(reply(snap(rev=2)));a.drain();check(a.libraryBrowse.liked)
  a.command(JSONObject().put("command","logout"));a.drain();check(!a.libraryBrowse.liked && !a.libraryBrowse.hasRead)
 }
 test("retained-row-owner-cannot-write-after-refresh-or-account-epoch") {
  val a=adapter();val owner=a.libraryBrowse.rowOwner(a.snapshot)
  a.browseLibrary();a.bridge.replies.add(reply(snap(rev=2)));a.drain()
  a.favoriteLibraryTrack(1,false,owner);a.selectLibraryTrack(1,owner);check(a.worker.tasks.isEmpty())
  val fresh=a.libraryBrowse.rowOwner(a.snapshot);a.epoch++;a.snapshot=snap(a.epoch,2)
  a.favoriteLibraryTrack(1,false,fresh);check(a.worker.tasks.isEmpty())
 }
 test("unlike-liked-invalidates-append-without-losing-acknowledged-rows") {
  val a=adapter();a.browseLibrary(liked=true);a.bridge.replies.add(reply(snap(rev=2).put("favorite_track_ids",JSONArray(longs=listOf(1L)))));a.drain()
  val accepted=a.snapshot.optJSONArray("library")
  a.favoriteLibraryTrack(1,true);a.bridge.replies.add(reply(snap(rev=2)));a.drain()
  check(a.libraryBrowse.liked && a.snapshot.optJSONArray("library")!!.length()==2 && !LibraryBrowseState.favorite(a.snapshot,1))
  a.browseLibrary(offset=2);a.bridge.replies.add(reply(snap(rev=3)));a.drain()
  check(a.bridge.calls.last().optLong("offset")==0L){"successful unlike sent stale append offset"}
 }
 test("invalid-page-feedback-is-refresh-not-search-length") {
  val a=adapter();a.browseLibrary(liked=true);a.bridge.replies.add(reply(snap(rev=2)));a.drain()
  a.browseLibrary(offset=2);a.bridge.replies.add(reply(snap(rev=2),false,"invalid_query"));a.drain()
  check(a.libraryBrowse.failure!!.contains("Refresh") && !a.libraryBrowse.failure!!.contains("too long"))
  a.browseLibrary(offset=2);check(a.libraryBrowse.pending!!.offset==0)
 }
 test("initial-authenticated-publication-and-reconnect-preserve-row-authority") {
  val a=adapter();check(a.libraryBrowse.canUseRows(a.snapshot,a.epoch)){"initial authenticated rows disabled"}
  val owner=a.libraryBrowse.rowOwner(a.snapshot)
  a.snapshot=snap();check(a.libraryBrowse.canUseRows(a.snapshot,a.epoch) && a.libraryBrowse.owns(a.snapshot,owner))
  a.favoriteLibraryTrack(1,false,owner);check(a.worker.tasks.size==1)
 }
 test("long-search-feedback-uses-core-utf8-bound") {
  val a=adapter();a.browseLibrary(query="音".repeat(171));a.bridge.replies.add(reply(snap(),false,"invalid_query"));a.drain()
  check(a.libraryBrowse.failure!!.contains("Shorten"))
 }
 test("transport-remains-admitted-while-library-read-held") {
  val a=adapter();a.browseLibrary(liked=true);check(a.libraryBrowse.loading)
  a.command(JSONObject().put("command","resume"));check(a.foreground && a.wantsPlayback)
  a.bridge.replies.add(reply(snap(rev=2)));a.drain();check(a.player!!.isPlaying && !a.libraryBrowse.loading && a.busy==0)
 }
 check(failed==0){"$failed Android Library behavioral failures"}
}
'''


def prepare_harness():
    """Prepare without compiling: real command/media methods plus browse owner."""
    from native_review_regressions import android_probe, swift_block
    source = (ROOT / PACKAGE / 'PlaybackService.kt').read_text()
    state = (ROOT / PACKAGE / 'LibraryBrowseState.kt').read_text()
    state = '\n'.join(line for line in state.splitlines() if not line.startswith(('package ', 'import '))).replace('internal class LibraryBrowseState', 'class LibraryBrowseState')
    harness = android_probe(ROOT, swift_block).replace('fun main(){var failed=0;', 'fun baselineControls(){var failed=0;')
    harness = harness.replace('fun optBoolean(k:String)', 'fun has(k:String)=values.containsKey(k);fun optInt(k:String)=optLong(k).toInt();fun optBoolean(k:String)')
    harness = harness.replace('class JSONArray(val rows:List<JSONObject> = emptyList()) {', 'class JSONArray(val rows:List<JSONObject> = emptyList(),val longs:List<Long> = emptyList()) {fun optLong(i:Int)=longs[i];')
    harness = harness.replace('fun length()=rows.size;', 'fun length()=rows.size+longs.size;')
    harness = harness.replace('var snapshot=JSONObject()', 'val libraryBrowse=LibraryBrowseState()\nvar snapshot=JSONObject()', 1)
    epoch_setter = source[source.index('        private set(value) {'):source.index('    internal val libraryBrowse')].replace('private set(value)', 'set(value)')
    harness = harness.replace('val core=1L;var epoch=1L;', 'val core=1L;var epoch=1L\n'+epoch_setter+'\n', 1)
    # Install the exact production setter, not a copy of publication policy.
    setter_start = source.index('        private set(value) {',source.index('    var snapshot'))
    setter = source[setter_start:source.index('    var listener:')].replace('private set(value)', 'set(value)')
    harness = harness.replace('var listener:((JSONObject,String?)->Unit)?=null;', setter+'\nvar listener:((JSONObject,String?)->Unit)?=null;', 1)
    methods = '\n'.join(swift_block(source, name) for name in ('fun library(', 'fun browseLibrary(', 'fun favoriteLibraryTrack(', 'fun selectLibraryTrack('))

    harness = harness.replace('fun startForTest(){startPlayer()}',methods+'\nfun startForTest(){startPlayer()}')
    harness += '\n'+state+'\n'+BEHAVIOR
    assert harness.count('fun main()') == 1
    assert 'field = libraryBrowse.reconcile' in harness
    assert 'if (field != value) libraryBrowse.retire()' in harness
    assert '__METHODS__' not in harness and '__TERMINAL_FIELDS__' not in harness
    return harness


def compiled(output):
    """Opt-in only after compiler custody admission; no device/audio/network."""
    from test_toolchain import java_home, kotlin_compiler
    harness = prepare_harness()
    java = java_home()
    env = dict(os.environ, JAVA_HOME=str(java), JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2')
    with tempfile.TemporaryDirectory(prefix='android-library-',dir=os.environ['TMPDIR']) as tmp:
        work = Path(tmp)
        path = work / 'LibraryProbe.kt'; path.write_text(harness)
        (output / 'LibraryProbe.kt').write_text(harness)
        build = subprocess.run([kotlin_compiler(),str(path),'-nowarn','-include-runtime','-d',str(work/'probe.jar')],env=env,capture_output=True,text=True,timeout=120)
        (output/'compiler.log').write_text(build.stdout+build.stderr)
        ran = None
        if build.returncode == 0:
            ran = subprocess.run([str(java/'bin/java'),'-jar',str(work/'probe.jar')],env=env,capture_output=True,text=True,timeout=30)
        (output/'behavior.log').write_text(ran.stdout+ran.stderr if ran else 'NOT RUN\n')
        return {'compile_exit':build.returncode,'exit_code':build.returncode or (ran.returncode if ran else 1),'pass_names':[line[5:] for line in ran.stdout.splitlines() if line.startswith('PASS ')] if ran else [],'failures':[line[5:] for line in ran.stdout.splitlines() if line.startswith('FAIL ')] if ran else []}


def prepare_queue_harness(source_root=None):
    """Keep the existing queue cases on the unchanged production disclosure.

    The shell here is a boundary facade, not the new production onCreate. The
    older full-Activity facade predates ImageButtons/fonts/insets and must not
    be mistaken for a real-SDK compilation gate for the new shell.
    """
    from queue_dialog_regressions import FACADES, PROBE
    source = ((source_root or ROOT)/PACKAGE/'MainActivity.kt').read_text()
    queue = source[source.index('    private fun dismissQueueActions()'):source.index('    override fun onDestroy()')]
    publication = source[source.index('        val selected = if(snapshot.isNull'):source.index('        val authenticated = snapshot.optBoolean')]
    wrapper = '''package com.soundq.nativepreview
import android.app.*
import android.content.*
import android.os.*
import android.widget.*
import android.view.*
class MainActivity:Activity() {
 private var service:PlaybackService?=null
 private var queueListDialog:AlertDialog?=null
 private var queueListSelection:Long?=null
 private var queueActionDialog:AlertDialog?=null
 private var queueNameDialog:AlertDialog?=null
 private var queueActions:ArrayAdapter<String>?=null
 private val connection=object:ServiceConnection {
  override fun onServiceConnected(name:ComponentName,binder:IBinder){dismissQueueActions();service=(binder as PlaybackService.LocalBinder).service;service?.listener={snapshot,_->render(snapshot)};service?.let{render(it.snapshot)}}
  override fun onServiceDisconnected(name:ComponentName){dismissQueueActions();service=null}
 }
 override fun onCreate(state:Bundle?){setContentView(Button(this).apply{text="Queue";setOnClickListener{showQueue()}})}
 private fun render(snapshot:org.json.JSONObject){PUBLICATION}
 QUEUE
 override fun onDestroy(){dismissQueueActions();service?.listener=null;super.onDestroy()}
}
'''.replace('PUBLICATION',publication).replace('QUEUE',queue)
    return {**FACADES,'Probe.kt':PROBE,'MainActivity.kt':wrapper}


def queue_compiled(output):
    from test_toolchain import java_home, kotlin_compiler
    java=java_home()
    env=dict(os.environ,JAVA_HOME=str(java),JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2')
    with tempfile.TemporaryDirectory(prefix='android-library-queue-',dir=os.environ['TMPDIR']) as tmp:
        work=Path(tmp);sources=[]
        for name,text in prepare_queue_harness().items():
            path=work/name;path.write_text(text);sources.append(str(path))
        build=subprocess.run([kotlin_compiler(),*sources,'-nowarn','-include-runtime','-d',str(work/'probe.jar')],env=env,capture_output=True,text=True,timeout=120)
        (output/'queue-compiler.log').write_text(build.stdout+build.stderr)
        ran=None
        if build.returncode==0:
            ran=subprocess.run([str(java/'bin/java'),'-jar',str(work/'probe.jar')],env=env,capture_output=True,text=True,timeout=30)
        (output/'queue-behavior.log').write_text(ran.stdout+ran.stderr if ran else 'NOT RUN\n')
        return {'compile_exit':build.returncode,'exit_code':build.returncode or (ran.returncode if ran else 1),'pass_names':[line[5:] for line in ran.stdout.splitlines() if line.startswith('PASS ')] if ran else [],'evidence_class':'unchanged-production-queue-disclosure-with-shell-boundary-facade'}


def main():
    global ROOT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root',type=Path,default=ROOT)
    parser.add_argument('--source-only', action='store_true')
    parser.add_argument('--compiled', action='store_true')
    parser.add_argument('--prepare', action='store_true', help='Emit production-bound Kotlin probe without invoking compiler')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    ROOT = args.source_root.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(SourceContracts)
    with (args.output / 'source-tests.log').open('w') as stream:
        result = unittest.TextTestRunner(stream=stream, verbosity=2).run(suite)
    receipt = {'evidence_class':'source-contract-tracers-not-behavior', 'tests':result.testsRun, 'failures':len(result.failures), 'errors':len(result.errors), 'compiler_run':False, 'device_run':False}
    if args.prepare:
        harness = prepare_harness()
        (args.output/'LibraryProbe.kt').write_text(harness)
        receipt['prepared_probe_sha256'] = hashlib.sha256(harness.encode()).hexdigest()
        queue=prepare_queue_harness()
        (args.output/'queue-probe-sources.json').write_text(json.dumps(queue,indent=2)+'\n')
    if args.compiled:
        from android_presentation_lifecycle_tests import run_controls
        receipt['presentation_lifecycle'] = run_controls(args.output)
        if not receipt['presentation_lifecycle']['passed']:
            (args.output / 'results.json').write_text(json.dumps(receipt, indent=2)+'\n')
            return 1
        receipt['compiler_run'] = True
        receipt['behavior'] = compiled(args.output)
        receipt['queue_behavior'] = queue_compiled(args.output)
        from android_presentation_regressions import run as presentation
        receipt['presentation'] = presentation(ROOT, args.output / 'presentation')
    receipt['source_sha256'] = {str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted((ROOT/PACKAGE).glob('*.kt'))}
    receipt['test_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    (args.output / 'results.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps(receipt, sort_keys=True))
    return 0 if result.wasSuccessful() and (not args.compiled or receipt['behavior']['exit_code'] == 0 and receipt['queue_behavior']['exit_code'] == 0 and receipt['presentation']['passed']) else 1


if __name__ == '__main__':
    raise SystemExit(main())
