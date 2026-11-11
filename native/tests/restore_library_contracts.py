"""Source-bound restart continuation, JCE save and real Library read admission.

The core facade keeps rotated credentials in every reply until its version ACK,
as the Rust producer does. Worker/main queues are independently stepped; no
service, native app, network, personal store or device is started.
"""
from native_review_regressions import swift_block

CASES = r'''
 fun owner()=PlaybackService().apply {bridge.prefs=prefs}
 fun names(a:PlaybackService)=a.bridge.calls.map {it.optString("command")}
 fun loaded(a:PlaybackService) {
  check(a.libraryLoads==1){"automatic library dispatches=${a.libraryLoads}; commands=${names(a)}; feedback=${a.feedback}"}
  check(a.libraryBrowse.hasRead && !a.libraryBrowse.loading && a.libraryBrowse.failure==null && a.snapshot.optLong("total")==1L && a.snapshot.optJSONArray("library")!!.getJSONObject(0).optLong("id")==73L){"actual read was not acknowledged"}
  check(a.busy==0 && a.worker.tasks.isEmpty() && a.main.tasks.isEmpty())
  check(a.bridge.acks>0 && a.storedCredentialVersion==1L && a.prefs.commits>0)
  check("command_backpressure" !in a.feedback){"credential ACK blocked automatic destination"}
 }
 for(workerFirst in listOf(true,false)) test("restore-automatic-library-real-admission-$workerFirst") {
  val a=owner();a.startRestored();check(a.bridge.calls.isEmpty() && a.worker.tasks.size==1)
  if(workerFirst)a.drain() else {var n=0;while(a.worker.tasks.isNotEmpty()||a.main.tasks.isNotEmpty()){check(n++<100);if(a.worker.tasks.isNotEmpty())a.worker.one();if(a.main.tasks.isNotEmpty())a.main.one()}}
  loaded(a);check(names(a).count{it=="restore"}==1 && names(a).count{it=="queue_restore"}==1 && names(a).none{it=="login"||it=="register"})
 }
 for(kind in listOf("register","login")) test("auth-$kind-durable-library-real-admission") {
  val a=owner();if(kind=="register")a.authForm.changeMode(AuthFormState.Mode.REGISTER)
  a.submitAuth("abc","a@b.co","secret-123","secret-123");a.drain();loaded(a)
  check(names(a).count{it==kind}==1 && a.authForm.succeeded)
 }
 for(boundary in listOf("save-worker","continuation-main")) for(replacement in listOf("logout","login")) test("restore-retired-$boundary-$replacement") {
  val a=owner();a.startRestored();a.worker.one();a.main.one()
  // Either source ordering: hold the actual save or queue_restore completion.

  if(boundary=="continuation-main") {while(a.worker.tasks.isNotEmpty())a.worker.one()}
  val oldAccount=a.credentialEpoch
  a.command(JSONObject().put("command",replacement));a.drain()
  check(a.credentialEpoch!=oldAccount && a.libraryLoads==0){"old restoration loaded replacement: ${names(a)}"}
  check(a.bridge.calls.filter {it.optString("command")=="acknowledge_credentials"}.all {it.optLong("account_scope_v1")!=oldAccount})
 }
 test("restore-save-held-no-ack-before-durable-commit") {
  val a=owner();a.startRestored();a.worker.one();a.main.one()
  check(a.prefs.commits==0 && a.bridge.acks==0)
  a.worker.drain();check(a.prefs.commits==0 && a.bridge.acks==0)
  a.drain();loaded(a)
 }
 test("restore-secure-failure-visible-without-ack-or-auth-replay") {
  val a=owner();a.prefs.save=false;a.startRestored();a.drain()
  check(a.storageErrors>0 && a.storedCredentialVersion==0L && a.bridge.acks==0 && "secure_storage_failed" in a.feedback)
  check(names(a).count{it=="restore"}==1 && names(a).none{it=="login"||it=="register"})
  check(a.libraryLoads==1 && a.libraryBrowse.hasRead){"session read must not depend on durable ACK success"}
 }
 test("restore-refused-no-auth-replay-or-library-dispatch") {
  val a=owner();a.bridge.refuseRestore=true;a.startRestored();a.drain()
  check(a.libraryLoads==0 && !a.snapshot.optBoolean("authenticated") && "authentication_failed" in a.feedback)
  check(names(a).count{it=="restore"}==1 && names(a).none{it=="login"||it=="register"})
 }
 test("ordinary-busy-completion-does-not-trigger-library") {
  val a=owner();a.command(JSONObject().put("command","snapshot"));a.library();a.drain()
  check(a.libraryLoads==0 && "command_backpressure" in a.feedback)
 }
 test("credential-version-fence-no-older-save-or-ack") {
  val a=owner();a.credentialEpoch=2;a.storedCredentialVersion=2;a.saveCredentials(JSONObject().put("version",1L));a.drain()
  check(a.prefs.commits==0 && a.bridge.acks==0 && a.libraryLoads==0)
 }
 test("restore-continuation-reentrant-account-change-revokes-save") {
  val a=owner();var done=0
  a.command(JSONObject().put("command","restore"),done={done++;a.command(JSONObject().put("command","logout"))});a.drain()
  check(done==1 && a.prefs.data.isEmpty() && a.storedCredentialVersion==0L && a.bridge.acks==0 && a.libraryLoads==0)
 }
'''


def inventory():
    return (['restore-automatic-library-real-admission-'+v for v in ('true','false')]
            + ['auth-'+k+'-durable-library-real-admission' for k in ('register','login')]
            + ['restore-retired-'+b+'-'+r for b in ('save-worker','continuation-main') for r in ('logout','login')]
            + ['restore-save-held-no-ack-before-durable-commit',
               'restore-secure-failure-visible-without-ack-or-auth-replay',
               'restore-refused-no-auth-replay-or-library-dispatch',
               'ordinary-busy-completion-does-not-trigger-library',
               'credential-version-fence-no-older-save-or-ack',
               'restore-continuation-reentrant-account-change-revokes-save'])


def admits(passes):
    from collections import Counter
    return Counter(passes)==Counter(inventory())


def compose(harness, root):
    source=(root/'native/android/app/src/main/java/com/soundq/nativepreview/PlaybackService.kt').read_text()
    # Copy the complete production startup tail, not a parallel restore chain.
    startup=swift_block(source,'override fun onCreate(')
    startup=startup[startup.index('        val saved = loadCredentials()'):startup.rfind('}')]
    harness=harness.replace('fun startForTest(){startPlayer()}',
        'fun startRestored(){'+startup+'}\nfun loadCredentials():JSONObject?=JSONObject().put("version",4L).put("access_token","synthetic-old").put("refresh_token","synthetic-refresh").put("account_id","synthetic-account")\nfun startForTest(){startPlayer()}')
    # A durable store facade records successful commit separately from staged data.
    harness=harness.replace('class Prefs {var save=true;', 'class Prefs {var commits=0;var save=true;')
    harness=harness.replace('fun commit()=save}', 'fun commit():Boolean{if(save)commits++;return save}}')
    begin,end=harness.index('class Bridge {'),harness.index('class PlaybackService {')
    bridge=r'''class Bridge {
 var epoch=1L;val calls=mutableListOf<JSONObject>();var malformed=false;var reject=false;val replies=ArrayDeque<JSONObject>()
 var authenticated=false;var changed=false;var acks=0;var refuseRestore=false;var prefs:Prefs?=null;var libraryRead=false
 fun revoke(c:Long):Long{epoch++;return epoch}
 fun execute(c:Long,e:Long,raw:String):String {
  val v=JSONObject(raw);calls.add(v);val kind=v.optString("command")
  if(malformed)return "malformed"
  if(replies.isNotEmpty())return replies.removeFirst().toString()
  if(kind in listOf("restore","login","register")){authenticated= !(kind=="restore" && refuseRestore);changed=authenticated}
  if(kind=="logout"){authenticated=false;changed=false}
  if(kind=="acknowledge_credentials") {check(prefs!!.commits>0 && prefs!!.data.isNotEmpty()){"ACK preceded durable save"};check(v.optLong("version")==1L);changed=false;acks++}
  if(kind=="library")libraryRead=true
  val s=JSONObject().put("epoch",e).put("session",1L).put("authenticated",authenticated).put("library_revision",1L)
    .put("library",if(libraryRead)JSONArray(listOf(JSONObject().put("id",73L).put("title","Restored track")))else JSONArray()).put("total",if(libraryRead)1L else 0L)
  if(kind!="library")s.put("library_unchanged",true)
  val r=JSONObject().put("ok",!refuseRestore).put("code",if(refuseRestore)"authentication_failed" else "ok").put("snapshot",s)
  if(changed)r.put("credentials",JSONObject().put("version",1L).put("access_token","synthetic-access").put("refresh_token","synthetic-refresh").put("account_id","synthetic-account"))
  return r.toString()
 }
}
'''
    harness=harness[:begin]+bridge+harness[end:]
    harness=harness.replace('var storageErrors=0;', 'val feedback=mutableListOf<String>();var storageErrors=0;')
    harness=harness.replace('if(error=="secure_storage_failed")storageErrors++', 'if(error!=null)feedback.add(error);if(error=="secure_storage_failed")storageErrors++')
    harness=harness[:harness.index('fun main() {')]
    return harness+'''fun main() {
 var failed=0
 fun test(name:String,body:()->Unit) {try {body();println("PASS $name")} catch(e:Throwable){failed++;println("FAIL $name ${e.message}")}}
'''+CASES+'\n check(failed==0){"$failed restore Library failures"}\n}\n'


def run(root, output):
    import hashlib
    import json
    import os
    import subprocess
    from registration_regressions import android_terminal
    from registration_contracts import android_full
    from test_toolchain import kotlin_compiler, java_home
    output.mkdir(parents=True,exist_ok=False)
    generated=compose(android_full(android_terminal(root),root),root)
    path=output/'RestoreLibrary.kt';path.write_text(generated)
    env=dict(os.environ,JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2')
    if not env.get('TMPDIR'):raise RuntimeError('explicit TMPDIR required')
    argv=[kotlin_compiler(),str(path),'-nowarn','-include-runtime','-d',str(output/'probe.jar')]
    built=subprocess.run(argv,env=env,capture_output=True,timeout=120)
    (output/'compile.log').write_bytes(built.stdout+built.stderr)
    execute=[str(java_home()/'bin/java'),'-XX:ActiveProcessorCount=2','-jar',str(output/'probe.jar')]
    ran=subprocess.run(execute,env=env,capture_output=True,timeout=30) if built.returncode==0 else None
    (output/'run.log').write_bytes(ran.stdout+ran.stderr if ran else b'NOT RUN')
    lines=ran.stdout.decode().splitlines() if ran else []
    passes=[v[5:] for v in lines if v.startswith('PASS ')]
    assert admits(inventory()) and not admits([]) and not admits(inventory()[1:]) and not admits(inventory()+inventory()[:1])
    receipt=dict(passed=built.returncode==0 and ran is not None and ran.returncode==0 and admits(passes),
        expected=inventory(),passes=passes,failures=[v[5:] for v in lines if v.startswith('FAIL ')],compile_exit=built.returncode,run_exit=ran.returncode if ran else None,
        errors=int(built.returncode!=0),skips=0,argv=argv,execute=execute,TMPDIR=env['TMPDIR'],cwd=str(root),
        inventory_controls=['complete','early-zero-refused','missing-case-refused','duplicate-case-refused'],
        probe_sha256=hashlib.sha256(generated.encode()).hexdigest(),
        production_sha256=hashlib.sha256((root/'native/android/app/src/main/java/com/soundq/nativepreview/PlaybackService.kt').read_bytes()).hexdigest(),
        test_sha256=hashlib.sha256(__import__('pathlib').Path(__file__).read_bytes()).hexdigest())
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print((output/'compile.log').read_text());print((output/'run.log').read_text())
    return receipt['passed']


if __name__=='__main__':
    import argparse
    from pathlib import Path
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-root',type=Path,default=Path(__file__).resolve().parents[2]);p.add_argument('--output',required=True,type=Path)
    a=p.parse_args();raise SystemExit(0 if run(a.source_root,a.output) else 1)
