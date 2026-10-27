"""Shared-vector and held native adapter contracts for registration_regressions."""
import json
from pathlib import Path
from native_review_regressions import swift_block

def vectors():
    values=json.loads(Path(__file__).with_name('registration_vectors.json').read_text())
    for v in values:
        for key,repeat in [('username','usernameRepeat'),('password','passwordRepeat')]:
            if repeat in v:v[key]*=v[repeat]
        if 'emailLocalRepeat' in v:v['email']=v['email']*v['emailLocalRepeat']+v['emailSuffix']
        if v.get('confirmationSame'):v['confirmation']=v['password']
    return values

def kotlin_literal(value):return json.dumps(value,ensure_ascii=False).replace('$','\\$')
def swift_literal(value):
    import re
    return re.sub(r'\\u([0-9a-fA-F]{4})',lambda m:'\\u{'+m[1]+'}',json.dumps(value,ensure_ascii=False))

ANDROID_CASES=r'''
 fun registration()=PlaybackService().apply {authForm.changeMode(AuthFormState.Mode.REGISTER)}
 fun reply(a:PlaybackService,ok:Boolean=true,code:String="ok",credentials:Boolean=false)=JSONObject().put("ok",ok).put("code",code).put("snapshot",JSONObject().put("epoch",a.epoch).put("authenticated",ok)).apply {if(credentials)put("credentials",JSONObject().put("version",1L).put("access_token","synthetic-access").put("refresh_token","synthetic-refresh").put("account_id","synthetic-account"))}
 test("register-invalid-real-caller-no-dispatch") {
  val a=registration();a.submitAuth("a","bad","short","different");check(a.worker.tasks.isEmpty() && a.bridge.calls.isEmpty() && a.authForm.errors.keys==setOf("username","email","password","confirmation"))
 }
 test("register-held-exact-payload-and-ime-reentry") {
  val a=registration();a.submitAuth(" abc ","a@b.co"," password "," password ");val ticket=a.authForm.pending
  check(ticket!=null && !a.authForm.changeMode(AuthFormState.Mode.SIGN_IN))
  a.submitAuth("other","a@b.co","different","different");check(a.worker.tasks.size==1)
  a.bridge.replies.add(reply(a));a.worker.one();check(a.bridge.calls.size==1)
  val sent=a.bridge.calls.single();check(sent.values.keys==setOf("command","username","email","password","account_scope_v1"));check(sent.optString("command")=="register" && sent.optString("username")=="abc" && sent.optString("password")==" password " && sent.optLong("account_scope_v1")==a.credentialEpoch)
  a.main.drain();a.drain();check(a.authForm.pending==null && a.authForm.succeeded && a.libraryLoads==1)
 }
 for(code in listOf("authentication_refused","network_unavailable","invalid_auth_response","binding_failure")) test("register-terminal-$code") {
  val a=registration();a.submitAuth("abc","a@b.co","secret-123","secret-123");if(code=="binding_failure")a.bridge.malformed=true else a.bridge.replies.add(reply(a,false,code));a.drain()
  check(a.authForm.pending==null && !a.authForm.succeeded && a.libraryLoads==0 && a.bridge.calls.size==1)
  check(a.authForm.failure!!.contains(if(code=="authentication_refused") "refused" else "unconfirmed"))
 }
 test("register-submit-backpressure-no-owner-replacement") {
  val a=registration();a.busy=32;val epoch=a.epoch;val account=a.credentialEpoch;a.submitAuth("abc","a@b.co","secret-123","secret-123")
  check(a.authForm.pending==null && a.authForm.failure!!.contains("busy") && a.worker.tasks.isEmpty() && a.epoch==epoch && a.credentialEpoch==account)
 }
 for(kind in listOf("detach","edit","account")) test("register-retired-$kind-no-stale-publication") {
  val a=registration();a.submitAuth("abc","a@b.co","secret-123","secret-123");a.bridge.replies.add(reply(a,credentials=true));a.worker.one()
  if(kind=="account") {a.credentialEpoch++;a.epoch=a.bridge.revoke(a.core)} else if(kind=="edit") a.authForm.edited() else a.retireAuthPresentation()
  a.drain();check(a.authForm.pending==null && a.authForm.failure==null && !a.authForm.succeeded && a.libraryLoads==0 && !a.snapshot.optBoolean("authenticated"))
  check(a.storedCredentialVersion==if(kind=="account") 0L else 1L)
  check(a.bridge.calls.count {it.optString("command")=="acknowledge_credentials"}==if(kind=="account") 0 else 1)
 }
 test("register-account-replaced-by-publication-listener-terminal") {
  val a=registration();a.submitAuth("abc","a@b.co","secret-123","secret-123");a.bridge.replies.add(reply(a,credentials=true))
  a.listener={s,_->if(s.optBoolean("authenticated")){a.credentialEpoch++;a.epoch=a.bridge.revoke(a.core)}}
  a.drain();check(a.authForm.pending==null && a.libraryLoads==0 && a.storedCredentialVersion==0L){"retired listener stranded pending or delivered old credentials"}
 }
 test("register-secure-store-failure-no-ack-explicit-recovery") {
  val a=registration();a.prefs.save=false;a.submitAuth("abc","a@b.co","secret-123","secret-123");a.bridge.replies.add(reply(a,credentials=true));a.drain()
  check(a.storedCredentialVersion==0L && a.bridge.calls.none {it.optString("command")=="acknowledge_credentials"} && a.storageErrors==1)
  a.prefs.save=true;val credentials=JSONObject().put("version",1L).put("access_token","synthetic-access").put("refresh_token","synthetic-refresh").put("account_id","synthetic-account")
  a.saveCredentials(credentials);a.drain();check(a.storedCredentialVersion==1L && a.bridge.calls.count{it.optString("command")=="acknowledge_credentials"}==1 && a.prefs.data.isNotEmpty())
 }
'''

def android_full(harness,root):
    source=(root/'native/android/app/src/main/java/com/soundq/nativepreview/PlaybackService.kt').read_text()
    harness=harness.replace('import java.util.ArrayDeque','import java.util.ArrayDeque\nimport javax.crypto.Cipher\nimport javax.crypto.KeyGenerator\nimport javax.crypto.SecretKey')
    harness=harness.replace('var epoch=1L;val calls=', 'var malformed=false;var epoch=1L;val calls=')
    harness=harness.replace('calls.add(v);if(replies.isNotEmpty())', 'calls.add(v);if(malformed)return "malformed";if(replies.isNotEmpty())')
    harness=harness.replace('class Prefs {fun edit()=this;fun clear()=this;fun commit()=true}', 'class Prefs {var save=true;val data=mutableMapOf<String,String>();fun edit()=this;fun clear()=this;fun putString(k:String,v:String):Prefs{data[k]=v;return this};fun commit()=save}\nobject Base64 {const val NO_WRAP=0;fun encodeToString(b:ByteArray,flags:Int)=java.util.Base64.getEncoder().encodeToString(b)}')
    harness=harness.replace('val saved=mutableListOf<JSONObject>();fun getSharedPreferences(n:String,m:Int)=Prefs();fun saveCredentials(v:JSONObject){saved.add(v)};fun updateSession(){}', 'val prefs=Prefs();val endpoint="https://synthetic.invalid/api/v1";var storageErrors=0;fun getSharedPreferences(n:String,m:Int)=prefs;fun key():SecretKey=KeyGenerator.getInstance("AES").apply {init(128)}.generateKey();fun updateSession(){}\n'+swift_block(source,'private fun saveCredentials(').replace('private fun','fun'))
    harness=harness.replace('var listener:((JSONObject,String?)->Unit)?=null;', 'var listener:((JSONObject,String?)->Unit)?={_,error->if(error=="secure_storage_failed")storageErrors++};')
    # Compose the actual read owner/admission and publication setters. A method
    # invocation counter cannot witness a destination suppressed by busy/ACK.
    state=(root/'native/android/app/src/main/java/com/soundq/nativepreview/LibraryBrowseState.kt').read_text()
    state='\n'.join(line for line in state.splitlines() if not line.startswith(('package ', 'import '))).replace('internal class LibraryBrowseState','class LibraryBrowseState')
    harness=harness.replace('class JSONObject {',state+'\nclass JSONObject {',1)
    harness=harness.replace('fun optBoolean(k:String)','fun has(k:String)=values.containsKey(k);fun optInt(k:String)=optLong(k).toInt();fun optBoolean(k:String)')
    harness=harness.replace('class JSONArray(val rows:List<JSONObject> = emptyList()) {','class JSONArray(val rows:List<JSONObject> = emptyList()) {fun optLong(i:Int)=rows[i].optLong("value");')
    harness=harness.replace('var snapshot=JSONObject()','val libraryBrowse=LibraryBrowseState()\nvar snapshot=JSONObject()',1)
    epoch_setter=source[source.index('        private set(value) {'):source.index('    internal val libraryBrowse')].replace('private set(value)','set(value)')
    harness=harness.replace('val core=1L;var epoch=1L;','val core=1L;var epoch=1L\n'+epoch_setter+'\n',1)
    start=source.index('        private set(value) {',source.index('    var snapshot'))
    setter=source[start:source.index('    var listener:')].replace('private set(value)','set(value)')
    harness=harness.replace('var listener:((JSONObject,String?)->Unit)?=',setter+'\nvar listener:((JSONObject,String?)->Unit)?=',1)
    reads='\n'.join(swift_block(source,name) for name in ('fun library(', 'fun browseLibrary('))
    harness=harness.replace('fun library(){}','val libraryLoads get()=bridge.calls.count {it.optString("command")=="library"}\n'+reads)
    cases=ANDROID_CASES
    for v in vectors():
        args=','.join(kotlin_literal(v[k]) for k in ['username','email','password','confirmation'])
        expected='setOf('+','.join(kotlin_literal(k) for k in v['errors'])+')' if v['errors'] else 'emptySet<String>()'
        cases+='\n test("vector-'+v['name']+'") {check(AuthFormState.validate('+args+').keys=='+expected+');val owner=registration();owner.submitAuth('+args+');check(owner.worker.tasks.size=='+('1' if not v['errors'] else '0')+')} '
    return harness.replace(' check(failed==0){"$failed registration terminal failures"}', cases+'\n check(failed==0){"$failed registration terminal failures"}')

MAC_CASES=r'''
  func registration()->App {let a=App();_ = a.authForm.changeMode(.register);a.email.stringValue="a@b.co";a.password.stringValue="secret-123";a.loginArea.username.stringValue="abc";a.loginArea.confirmation.stringValue="secret-123";return a}
  func wire(_ a:App,_ ok:Bool=true,_ code:String="ok",credentials:Bool=false)->Data {
   let s=Snapshot(epoch:a.epoch,session:1,revision:1,authenticated:ok,library:[],library_unchanged:false,total:0,queue:[],queue_unchanged:false,selected_occurrence:nil,transport:"idle",position_ms:0,duration_ms:0,error:nil)
   var object:[String:Any] = ["ok":ok,"code":code,"snapshot":["epoch":s.epoch,"session":1,"revision":1,"authenticated":ok,"library":[],"library_unchanged":false,"total":0,"queue":[],"queue_unchanged":false,"transport":"idle","position_ms":0,"duration_ms":0]]
   if credentials {object["credentials"]=["version":1,"access_token":"synthetic-access","refresh_token":"synthetic-refresh","account_id":"synthetic-account"]}
   return try! JSONSerialization.data(withJSONObject:object)
  }
  func settle(_ a:App) async {while a.busy>0 {if a.bridge.pending != nil {break};await Task.yield()};for _ in 0..<20 {await Task.yield()}}
  let invalid=registration();invalid.loginArea.username.stringValue="a";invalid.email.stringValue="bad";invalid.password.stringValue="short";invalid.loginArea.confirmation.stringValue="different";invalid.signIn()
  check("register-invalid-real-caller-no-dispatch",invalid.bridge.sends==0 && Set(invalid.authForm.errors.keys)==Set(["username","email","password","confirmation"]))
  let exact=registration();exact.loginArea.username.stringValue=" abc ";exact.password.stringValue=" password ";exact.loginArea.confirmation.stringValue=" password ";exact.signIn();exact.signIn()
  let sent=exact.bridge.values[0]
  check("register-held-exact-payload-and-ime-reentry",exact.bridge.sends==1 && sent["command"] as? String=="register" && sent["username"] as? String=="abc" && sent["password"] as? String==" password " && sent["account_scope_v1"] as? UInt64==exact.accountScope && sent.count==5 && !exact.authForm.changeMode(.signIn))
  exact.bridge.release(wire(exact));await settle(exact)
  check("register-current-success-existing-library",exact.authForm.pending==nil && exact.authForm.succeeded && exact.libraryLoads==1 && exact.bridge.values.last?["command"] as? String=="library")
  let withCredentials=registration();withCredentials.signIn();withCredentials.bridge.release(wire(withCredentials,credentials:true));await settle(withCredentials)
  check("register-durable-success-actually-requests-library",withCredentials.storedCredentialVersion==1 && withCredentials.bridge.values.contains {$0["command"] as? String=="acknowledge_credentials"} && withCredentials.bridge.values.contains {$0["command"] as? String=="library"})
  for code in ["authentication_refused","network_unavailable","invalid_auth_response","binding_failure"] {
   let a=registration();a.signIn();a.bridge.release(code=="binding_failure" ? Data("malformed".utf8):wire(a,false,code));await settle(a)
   check("register-terminal-"+code,a.authForm.pending==nil && !a.authForm.succeeded && a.libraryLoads==0 && a.authForm.failure?.contains(code=="authentication_refused" ? "refused":"unconfirmed")==true)
  }
  let pressure=registration();pressure.busy=32;let owner=pressure.accountScope,epoch=pressure.epoch;pressure.signIn()
  check("register-submit-backpressure-no-owner-replacement",pressure.authForm.pending==nil && pressure.authForm.failure?.contains("busy")==true && pressure.bridge.sends==0 && pressure.epoch==epoch && pressure.accountScope==owner)
  for kind in ["detach","edit","account"] {
   let a=registration();a.signIn();a.authForm.retire();a.loginArea.update(a.authForm);check("retired-held-still-disabled-"+kind,a.loginArea.disabled)
   if kind=="account" {a.accountScope+=1;a.epoch+=1}
   a.bridge.release(wire(a,credentials:true));await settle(a)
   check("register-retired-"+kind+"-no-stale-publication",a.authForm.pending==nil && a.authForm.failure==nil && !a.authForm.succeeded && a.libraryLoads==0 && a.snapshot==nil && a.storedCredentialVersion==(kind=="account" ? 0:1))
   check("retired-terminal-reenables-form-"+kind,!a.loginArea.disabled)
  }
  let storage=registration();secureResult = -1;storage.signIn();storage.bridge.release(wire(storage,credentials:true));await settle(storage)
  check("register-secure-store-failure-no-ack",storage.storedCredentialVersion==0 && storage.bridge.values.allSatisfy {$0["command"] as? String != "acknowledge_credentials"} && storage.status.stringValue=="Could not save session")
  secureResult=0;storage.storeCredentials(Credentials(access_token:"synthetic-access",refresh_token:"synthetic-refresh",account_id:"synthetic-account",version:1),epoch:storage.epoch)
  check("register-secure-store-explicit-recovery-ack",storage.storedCredentialVersion==1 && storage.bridge.values.last?["command"] as? String=="acknowledge_credentials" && !durable.isEmpty)
'''

def mac_full(harness,root):
    source=(root/'native/macos/Sources/main.swift').read_text()
    harness=harness.replace('var pending:(@Sendable(Data)->Void)?;var sends=0','var pending:(@Sendable(Data)->Void)?;var sends=0;var values=[[String:Any]]()')
    harness=harness.replace('{sends+=1;pending=completion}','{sends+=1;values.append(try! JSONSerialization.jsonObject(with:data) as! [String:Any]);pending=completion}')
    harness=harness.replace('func loadLibrary(){}','var libraryLoads=0;func loadLibrary(){libraryLoads+=1}')
    # Real read admission, not merely a callback counter, must reach the bridge.
    load=swift_block(source,'func loadLibrary(')
    read=swift_block(source,'func readLibrary(')
    harness=harness.replace('var libraryLoads=0;func loadLibrary(){libraryLoads+=1}', 'var libraryLoads=0;var search=Label();var libraryReadSerial:UInt64=0;func updateLibraryAvailability(){}\n'+load.replace('{readLibrary','{libraryLoads+=1;readLibrary')+'\n'+read)
    harness=harness.replace('func storeCredentials(_ c:Credentials,epoch:UInt64){}',swift_block(source,'func storeCredentials(')+'\nfunc keychainQuery()->[String:Any] {[:]}')
    secure=r'''
let kSecValueData="value",kSecAttrAccessible="accessible",kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly="device-only"
let errSecSuccess:Int32=0,errSecDuplicateItem:Int32 = -25299
@MainActor var secureResult:Int32=0
@MainActor var durable=[Data]()
@MainActor func SecItemAdd(_ q:CFDictionary,_ out:UnsafeMutablePointer<CFTypeRef?>?)->Int32 {if secureResult==0 {durable.append((q as NSDictionary)["value"] as! Data)};return secureResult}
@MainActor func SecItemUpdate(_ q:CFDictionary,_ v:CFDictionary)->Int32 {secureResult}
'''
    cases=MAC_CASES
    for v in vectors():
        args=','.join(k+':'+swift_literal(v[k]) for k in ['username','email','password','confirmation'])
        expected='Set<String>(['+','.join(swift_literal(k) for k in v['errors'])+'])'
        assignments=';'.join('owner.'+field+'.stringValue='+swift_literal(v[key]) for field,key in [('loginArea.username','username'),('email','email'),('password','password'),('loginArea.confirmation','confirmation')])
        cases+='\n do {let owner=registration();'+assignments+';owner.signIn();check("vector-'+v['name']+'",Set(AuthFormState.validate('+args+').keys)=='+expected+' && owner.bridge.sends=='+('1' if not v['errors'] else '0')+')}'
    return harness.replace('@main struct Tests {',secure+'\n@main struct Tests {').replace('  exit(failed==0 ? 0:1)',cases+'\n  exit(failed==0 ? 0:1)')
