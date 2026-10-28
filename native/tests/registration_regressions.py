#!/usr/bin/env python3
"""Account registration through real native submit/command/store owners.

No service, app/window, network, decoder or personal secure store. Platform
boundaries are held queues and disposable store functions; production methods
are extracted verbatim. Missing APIs are discovery tracers, not behavioral RED.
"""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess
from native_review_regressions import swift_block, android_probe

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = Path('native/android/app/src/main/java/com/soundq/nativepreview')

ANDROID_TERMINAL = r'''
fun main() {
 var failed=0
 fun test(name:String,body:()->Unit) {try {body();println("PASS $name")} catch(e:Throwable){failed++;println("FAIL $name ${e.message}")}}
 test("register-backpressure-terminal-once") {
  val a=PlaybackService();a.busy=32;var observed=0;var done=0
  a.command(JSONObject().put("command","register"),observe={check(it.optString("code")=="command_backpressure");observed++},done={done++})
  check(observed==1 && done==1){"observed=$observed done=$done"};check(a.bridge.calls.isEmpty() && a.worker.tasks.isEmpty())
 }
 test("register-backpressure-preserves-account-owner") {
  val a=PlaybackService();a.busy=32;val account=a.credentialEpoch
  a.command(JSONObject().put("command","register"))
  check(a.credentialEpoch==account){"refused dispatch replaced account scope"}
 }
 test("login-owner-held-response-no-duplicate") {
  val a=PlaybackService();a.login("test@example.test","synthetic-password");a.login("test@example.test","synthetic-password")
  check(a.worker.tasks.size==1){"duplicate login operations=${a.worker.tasks.size}"}
 }
 check(failed==0){"$failed registration terminal failures"}
}
'''

MAC_TERMINAL = r'''
@main struct Tests {
 @MainActor static func main() async {
  var failed=0
  func check(_ name:String,_ value:Bool) {if value {print("PASS",name)} else {failed+=1;print("FAIL",name)}}
  let a=App();var results=0,done=0
  _ = a.command(["command":"register"],result:{reply in if !reply.ok {results+=1}},completion:{done+=1})
  a.bridge.release(Data("malformed".utf8))
  while a.busy>0 {await Task.yield()}
  check("register-malformed-terminal-once",results==1 && done==1)
  let b=App();b.busy=32;let account=b.accountScope
  let admitted=b.command(["command":"register"],result:nil)
  check("register-backpressure-preserves-account-owner",!admitted && b.accountScope==account && b.bridge.pending==nil)
  let c=App();c.email.stringValue="test@example.test";c.password.stringValue="synthetic-password"
  c.signIn();c.signIn()
  check("login-owner-held-response-no-duplicate",c.bridge.sends==1)
  exit(failed==0 ? 0:1)
 }
}
'''

def mac_terminal(root):
    source=(root/'native/macos/Sources/main.swift').read_text()
    types='\n'.join(swift_block(source,n) for n in ['struct Track:', 'struct Occurrence:', 'struct Snapshot:', 'struct AudioEffect:', 'struct Credentials:', 'struct Reply:', 'struct LibraryReadIdentity:', 'struct LibraryReadIntent:'])
    facade=r'''
final class Bridge:@unchecked Sendable {
 var pending:(@Sendable(Data)->Void)?;var sends=0
 func revoke()->UInt64 {2}
 func send(_ data:Data,epoch:UInt64,completion:@escaping @Sendable(Data)->Void){sends+=1;pending=completion}
 func release(_ data:Data){let f=pending;pending=nil;f?(data)}
}
@MainActor class Label {var stringValue=""}
@MainActor class Player {func pause(){};func replaceCurrentItem(with:Any?){}}
@MainActor final class App:NSObject {
 var email=Label();var password=Label();func loadLibrary(){}
 @discardableResult func command(_ value:[String:Any],completion:(@MainActor ()->Void)?=nil)->Bool {command(value,result:nil,completion:completion)}
 __SIGNIN__
 var bridge=Bridge();var busy=0;var epoch:UInt64=1;var accountScope:UInt64=1;var storedCredentialVersion:UInt64=0
 var snapshot:Snapshot?;var pendingLibraryRead:LibraryReadIntent?;var libraryReadInvalid=false;var libraryLiked=false
 var acknowledgedLibraryRead:LibraryReadIdentity?;var libraryReadFailure:String?;var libraryRevision:UInt64?
 var libraryReadRetired=Set<UInt64>();var reportPending=false;var status=Label();var wantsPlayback=false;var player:Player?
 func retireLibraryRead(){};func updateLibraryReadPresentation(){};func closeQueueName(){};func retireLibraryDetails(){}
 func deleteCredentials(){};func storeCredentials(_ c:Credentials,epoch:UInt64){};func finishLibraryRead(_ i:LibraryReadIntent,reply:Reply?){}
 func apply(_ s:Snapshot){snapshot=s};func applyAudio(_ e:AudioEffect){}
 __COMMAND__
}
'''
    helper=root/'native/macos/Sources/AuthForm.swift'
    extra=''
    if 'func retireLinkImport()' in source:
        facade=facade.replace('func deleteCredentials(){};', 'func retireLinkImport(){};func drainImportLibraryRefresh(){};func deleteCredentials(){};')
    if helper.exists():
        extra=swift_block(helper.read_text(),'struct AuthFormState')
        facade=facade.replace('var email=Label();','var authForm=AuthFormState();var loginArea=Form();var email=Label();')
        facade=facade.replace('@MainActor final class App:NSObject {','@MainActor class Form {var username=Label();var confirmation=Label();var disabled=false;func clearSecrets(){};func update(_ state:AuthFormState){disabled=state.pending != nil}}\n@MainActor final class App:NSObject {')
    return 'import Foundation\n'+types+'\n'+extra+'\n'+facade.replace('__SIGNIN__',swift_block(source,'@objc func signIn(')).replace('__COMMAND__',swift_block(source,'func command('))+'\n'+MAC_TERMINAL


def android_terminal(root):
    source=(root/PACKAGE/'PlaybackService.kt').read_text()
    harness=android_probe(root,swift_block)
    extra=swift_block(source,'fun login(')
    helper=root/PACKAGE/'AuthFormState.kt'
    if helper.exists():
        extra+='\n'+swift_block(source,'fun submitAuth(')+'\n'+swift_block(source,'fun retireAuthPresentation(')
    harness=harness.replace('fun startForTest(){startPlayer()}',extra+'\nfun library(){}\nfun startForTest(){startPlayer()}')
    return harness[:harness.index('fun main(){')]+ANDROID_TERMINAL


def run(root, output, platform, terminal_only=False):
    output.mkdir(parents=True,exist_ok=False)
    env=dict(os.environ, JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2')
    if not env.get('TMPDIR'):raise RuntimeError('explicit TMPDIR required')
    from registration_contracts import android_full, mac_full
    if platform=='macos':
        generated=mac_terminal(root)
        if not terminal_only:generated=mac_full(generated,root)
        source=output/'main.swift';source.write_text(generated)
        argv=['swiftc','-parse-as-library','-swift-version','6','-num-threads','2',str(source),'-o',str(output/'probe')]
        execute=[str(output/'probe')]
    else:
        from test_toolchain import kotlin_compiler,java_home
        generated=android_terminal(root)
        if not terminal_only:generated=android_full(generated,root)
        source=output/'main.kt';source.write_text(generated)
        argv=[kotlin_compiler(),str(source),'-include-runtime','-d',str(output/'probe.jar')]
        execute=[str(java_home()/'bin/java'),'-XX:ActiveProcessorCount=2','-jar',str(output/'probe.jar')]
    built=subprocess.run(argv,env=env,capture_output=True,timeout=120)
    (output/'compile.log').write_bytes(built.stdout+built.stderr)
    ran=subprocess.run(execute,env=env,capture_output=True,timeout=30) if built.returncode==0 else None
    (output/'run.log').write_bytes(ran.stdout+ran.stderr if ran else b'NOT RUN')
    lines=ran.stdout.decode().splitlines() if ran else []
    names=(['register-malformed-terminal-once','register-backpressure-preserves-account-owner','login-owner-held-response-no-duplicate'] if platform=='macos' else ['register-backpressure-terminal-once','register-backpressure-preserves-account-owner','login-owner-held-response-no-duplicate'])
    if not terminal_only:
        from registration_contracts import vectors
        names+=['register-invalid-real-caller-no-dispatch','register-held-exact-payload-and-ime-reentry']
        if platform=='macos':names+=['register-current-success-existing-library','register-durable-success-actually-requests-library']
        names+=['register-terminal-'+code for code in ['authentication_refused','network_unavailable','invalid_auth_response','binding_failure']]
        names+=['register-submit-backpressure-no-owner-replacement']+['register-retired-'+kind+'-no-stale-publication' for kind in ['detach','edit','account']]
        names+=(['register-secure-store-failure-no-ack','register-secure-store-explicit-recovery-ack'] if platform=='macos' else ['register-account-replaced-by-publication-listener-terminal','register-secure-store-failure-no-ack-explicit-recovery'])
        if platform=='macos':names += [prefix+kind for kind in ['detach','edit','account'] for prefix in ['retired-held-still-disabled-','retired-terminal-reenables-form-']]
        names+=['vector-'+v['name'] for v in vectors()]
    passes=[x[5:] for x in lines if x.startswith('PASS ')]
    receipt=dict(passed=built.returncode==0 and ran is not None and ran.returncode==0 and Counter(passes)==Counter(names),platform=platform,compile_exit=built.returncode,run_exit=ran.returncode if ran else None,passes=passes,failures=[x[5:] for x in lines if x.startswith('FAIL ')],expected=names,errors=0 if built.returncode==0 else 1,skips=0,argv=argv,execute=execute,cwd=str(root),TMPDIR=env['TMPDIR'],probe_sha256=hashlib.sha256(generated.encode()).hexdigest(),test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),production_sha256=hashlib.sha256((root/('native/macos/Sources/main.swift' if platform=='macos' else PACKAGE/'PlaybackService.kt')).read_bytes()).hexdigest())
    if platform=='android' and not terminal_only:
        from restore_library_contracts import run as restore_library
        receipt['restore_library_passed']=restore_library(root,output/'restore-library')
        receipt['passed']=receipt['passed'] and receipt['restore_library_passed']
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print((output/'compile.log').read_text());print((output/'run.log').read_text());return receipt['passed']

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--source-root',type=Path,default=ROOT);p.add_argument('--output',type=Path,required=True);p.add_argument('--platform',choices=['macos','android'],required=True);p.add_argument('--terminal-only',action='store_true');a=p.parse_args()
    raise SystemExit(0 if run(a.source_root,a.output,a.platform,a.terminal_only) else 1)
