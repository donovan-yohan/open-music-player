#!/usr/bin/env python3
"""Replay the actual NativeJourney restore seam with extracted service producers.

Only decoder scheduling, disk/core boundary and clock are deterministic facades.
No backend, device or real audio is used; synthetic observations are not runtime
proof. The unchanged production applyAudio seek-complete callback, report,
command/publication and native cursor getters run. Requires installed JDK/kotlinc.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

import native_review_regressions as service
from test_toolchain import java_home, kotlin_compiler

ROOT = Path(__file__).resolve().parents[2]
JOURNEY = 'native/android/app/src/androidTest/java/com/soundq/nativepreview/NativeJourney.kt'
SERVICE = 'native/android/app/src/main/java/com/soundq/nativepreview/PlaybackService.kt'


def replace_once(text, anchor, replacement):
    count = text.count(anchor)
    if count != 1:
        raise AssertionError(f'expected one cursor probe anchor {anchor!r}, found {count}')
    return text.replace(anchor, replacement, 1)


def native_getter(source, name):
    anchor = 'internal fun ' + name + '()'
    lines = [line.strip().removeprefix('internal ') for line in source.splitlines() if anchor in line]
    count = source.count(anchor)
    if count != 1:
        raise AssertionError(f'expected one service getter anchor {anchor!r}, found {count}')
    return lines[0]


def probe(root):
    journey = (root / JOURNEY).read_text()
    begin = journey.index('\n', journey.index('waitFor("final native pause")')) + 1
    end = journey.index('            controller.transportControls.play()', begin)
    seam = journey[begin:end]
    harness = service.android_probe(root, service.swift_block)
    harness = harness[:harness.index('fun main(){')]
    # This is a core/durable boundary facade, not an invented production receipt.
    start, end = harness.index('class Bridge {'), harness.index('class PlaybackService {')
    harness = harness[:start] + r'''class Bridge {
 var epoch=1L;val calls=mutableListOf<JSONObject>();var saved=40L;var position=40L;var revision=1L
 fun revoke(c:Long):Long{epoch++;return epoch}
 fun execute(c:Long,e:Long,raw:String):String {
  val v=JSONObject(raw);calls.add(v);val kind=v.optString("command")
  when(kind){"seek"->position=v.optLong("position_ms");"audio_report"->position=v.optLong("position_ms");"queue_restore"->position=saved+restoreDelta}
  if(kind=="seek" || kind=="audio_report")saved=position
  persisted.writeText(JSONObject().put("position_ms",saved).put("selected",12L).toString())
  val snapshot=JSONObject().put("epoch",e).put("session",1L).put("revision",++revision).put("transport","paused").put("position_ms",position).put("selected_occurrence",12L).put("queue",JSONArray(List(500){JSONObject().put("id",it.toLong()+1)}))
  val result=JSONObject().put("ok",true).put("snapshot",snapshot)
  if(kind=="seek")result.put("audio",JSONObject().put("action","seek").put("epoch",e).put("session",1L).put("position_ms",position))
  if(kind=="queue_restore")result.put("audio",JSONObject().put("action","stop").put("epoch",e).put("session",1L))
  return result.toString()
 }
}
''' + harness[end:]
    # Model asynchronous decoder completion independently from the command reply.
    harness = replace_once(harness, 'fun seekTo(p:Long,m:Int){currentPosition=p.toInt()}', 'var seekPending=false;fun seekTo(p:Long,m:Int){seekPending=true}')
    source = (root / SERVICE).read_text()
    getters = {name: native_getter(source, name) for name in ['nativePositionMs', 'nativePlaying']}
    harness = replace_once(harness, 'fun nativePositionMs()=player?.currentPosition?.toLong() ?: 0L', getters['nativePositionMs'])
    # Intentionally match the newly inserted real getter, exactly once, to keep
    # nativePlaying adjacent without changing either production getter's bytes.
    harness = replace_once(harness, 'fun nativePositionMs(): Long', getters['nativePlaying'] + '\nfun nativePositionMs(): Long')
    harness = replace_once(harness, 'fun optJSONObject(i:Int):JSONObject?=null', 'fun getJSONArray(k:String)=optJSONArray(k)!!\nfun optJSONObject(i:Int):JSONObject?=null')
    # The exact journey block uses normal File reads and real private-field probes.
    harness = harness.replace('import java.util.ArrayDeque\n', '')
    prefix = r'''import java.io.File
import java.util.ArrayDeque
val root=File(System.getenv("SOUNDQ_CURSOR_WORK"))
val credentials=JSONObject().put("account_id","synthetic-account")
object BuildConfig {const val API_BASE="http://127.0.0.1:54761/api/v1"}
val accountKey=java.security.MessageDigest.getInstance("SHA-256").digest((BuildConfig.API_BASE+"\u0000"+credentials.getString("account_id")).toByteArray(Charsets.UTF_8)).joinToString("") {"%02x".format(it)}
val persisted=File(root,"client-data-v1/$accountKey/listening-queue-v1.json").also{it.parentFile.mkdirs()}
var nativeCursor=5984
var restoreDelta=0L
var scheduledDrift=false
var omitCompletion=false
var stages=0
var scheduled=0
var checks=mutableListOf<String>()
var service:PlaybackService?=null
fun onMain(action:()->Unit){action()}
fun advance() {
 val s=service!!;val p=s.player
 if(p?.seekPending==true){p.seekPending=false;p.currentPosition=nativeCursor;if(!omitCompletion)p.seek!!(p);stages++;return}
 if(s.worker.tasks.isNotEmpty() || s.main.tasks.isNotEmpty()){s.drain();stages++;return}
 if(p!=null){if(scheduledDrift && scheduled>0)p.currentPosition++;s.tick();scheduled++;stages++}
}
fun waitFor(name:String,predicate:(PlaybackService)->Boolean) {
 repeat(16){if(predicate(service!!)){checks.add(name);return};advance()}
 error("$name: native=${service!!.nativePositionMs()} canonical=${service!!.snapshot.optLong("position_ms")} saved=${service!!.bridge.saved}")
}
class Context {val filesDir=root}
val context=Context()
val result=JSONObject()
'''
    tail = r'''
fun main(){var failures=0
 fun test(name:String,body:()->Unit){try{body();println("PASS $name")}catch(t:Throwable){failures++;println("FAIL $name: ${t.message}")}}
 fun runSeam(cursor:Int):PlaybackService {
  nativeCursor=cursor;stages=0;scheduled=0;checks.clear();service=PlaybackService()
  val s=service!!
  // Install actual production seek-completion listener through its load path.
  s.effect(JSONObject().put("action","load").put("epoch",1L).put("session",1L).put("path","synthetic"));s.player!!.prepared!!(s.player!!);s.drain()
__SEAM__
  return s
 }
 for(cursor in listOf(5984,6000,6048))test("journey-exact-settled-restore-$cursor") {
  restoreDelta=0;scheduledDrift=false;omitCompletion=false
  val s=runSeam(cursor)
  check(s.snapshot.optLong("position_ms")==cursor.toLong() && s.bridge.saved==cursor.toLong()){"restore did not preserve exact observed cursor"}
  check(s.player==null && !s.nativePlaying()){"restored decoder was not retired"}
  if(cursor!=6000)check(scheduled>=2){"settled baseline did not observe two scheduled reports"}
  check(s.bridge.calls.count{it.optString("command")=="queue_restore"}==1)
 }
 for(defect in listOf("restore-off-by-one","scheduled-cursor-drift","no-seek-completion"))test("journey-refuses-$defect") {
  restoreDelta=if(defect=="restore-off-by-one")1 else 0
  scheduledDrift=defect=="scheduled-cursor-drift";omitCompletion=defect=="no-seek-completion"
  var failure:Throwable?=null
  try{runSeam(5984)}catch(t:Throwable){failure=t}
  check(failure!=null){"unsupported restore baseline accepted"}
  val expected=when(defect){"restore-off-by-one"->"restored queue paused";"scheduled-cursor-drift"->"scheduled paused cursor publication";else->"saved paused cursor acknowledged"}
  check(failure!!.message?.contains(expected)==true){"wrong refusal: ${failure!!.message}"}
 }
 check(failures==0){"$failures journey restore regressions"}
}
'''.replace('__SEAM__', seam)
    return prefix + harness + tail, seam


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root, out = args.source_root.resolve(), args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    text, seam = probe(root)
    source = out / 'CursorProbe.kt'
    source.write_text(text)
    java = java_home()
    env = dict(os.environ, JAVA_HOME=str(java), JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2')
    commands = []
    with tempfile.TemporaryDirectory(prefix='queue-cursor-', dir=os.environ.get('TMPDIR')) as tmp:
        env['SOUNDQ_CURSOR_WORK'] = tmp
        jar = Path(tmp) / 'probe.jar'
        for name, argv in [('compile', [kotlin_compiler(), str(source), '-nowarn', '-include-runtime', '-d', str(jar)]), ('runtime', [str(java/'bin/java'), '-jar', str(jar)])]:
            run = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=120)
            (out/(name+'.log')).write_text(run.stdout + run.stderr)
            commands.append(dict(name=name, argv=argv, exitCode=run.returncode))
            print(run.stdout+run.stderr, end='')
            if run.returncode:
                break
    sha = lambda b: hashlib.sha256(b).hexdigest()
    logs = {p.name: sha(p.read_bytes()) for p in out.glob('*.log')}
    lines = (out/'runtime.log').read_text().splitlines() if (out/'runtime.log').exists() else []
    receipt = dict(evidenceClass='device-free synthetic core/disk/decoder scheduling; actual extracted journey and service producers', commands=commands,
                   testSha256=sha(Path(__file__).read_bytes()), probeSha256=sha(text.encode()), seamSha256=sha(seam.encode()),
                   sourceSha256={p: sha((root/p).read_bytes()) for p in [JOURNEY, SERVICE]}, logSha256=logs,
                   passNames=[s[5:] for s in lines if s.startswith('PASS ')], failures=[s[5:] for s in lines if s.startswith('FAIL ')])
    (out/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    raise SystemExit(commands[-1]['exitCode'])


if __name__ == '__main__':
    main()
