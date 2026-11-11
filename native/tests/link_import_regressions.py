#!/usr/bin/env python3
"""Window-free actual App command/import owners; held native boundary."""
import argparse,hashlib,json,os,subprocess
from pathlib import Path
from registration_regressions import mac_terminal
ROOT=Path(__file__).resolve().parents[2]
IMPORT_METHODS=['@objc func openLinkImport()', '@objc func closeLinkImport()', 'func retireLinkImport()', 'func updateLinkImport()', '@objc func submitLink()', '@objc func checkLinkImport()', '@objc func recentLinkImports()', 'func readLinkImport(', 'func receiveLinkImport(', '@objc func chooseLinkImport(', '@objc func openImportLibrary()', 'func drainImportLibraryRefresh()']
IMPORT_METHODS.append('@objc func newLinkImport()')
COMPOSITION=r'''
@MainActor var passes=[String](),failures=[String]()
@MainActor func check(_ n:String,_ v:Bool){print(v ? "PASS":"FAIL",n);if v {passes.append(n)} else {failures.append(n)};fflush(nil)}
@MainActor func settle(_ a:App) async {
 let limit=Date().addingTimeInterval(3)
 while a.busy != a.bridge.held.count-a.bridge.released && Date()<limit {await Task.yield()}
 precondition(a.busy == a.bridge.held.count-a.bridge.released)
}
@main struct ImportTests {
 @MainActor static func main() async throws {
  let assets=try NativeAssets.load(root:URL(fileURLWithPath:CommandLine.arguments[1]))
  func ready()->App {
   let a=App();a.mountLibraryDock(in:NSView(frame:NSRect(x:0,y:0,width:960,height:760)),assets:assets)
   let auth=try! JSONDecoder().decode(Reply.self,from:a.bridge.execute(["command":"restore","access_token":"old","refresh_token":"old-r","account_id":"projection-synthetic-account"]))
   _ = a.bridge.execute(["command":"acknowledge_credentials","version":auth.credentials!.version!])
   let page=try! JSONDecoder().decode(Reply.self,from:a.bridge.execute(["command":"library","offset":0,"query":"","sort":"added_at","order":"desc"]))
   a.apply(page.snapshot!);return a
  }
  func release(_ a:App,_ i:Int) async {a.bridge.release(i);await settle(a)}
  let a=ready();a.linkImport.draft="https://youtu.be/dQw4w9WgXcQ"
  a.submitLink();a.submitLink();let pending=a.linkImport.pending;a.closeLinkImport();a.submitLink()
  check("held-duplicate-close-reentry-one-post",a.bridge.held.count==1 && a.linkImport.pending==pending && a.bridge.revokes==0)
  await release(a,0)
  check("accepted-hidden-panel-retained",a.linkImport.pending==nil && a.linkImport.outcome=="accepted" && a.linkImport.jobID != nil)
  let queue=a.snapshot!.queue.map{$0.id},session=a.snapshot!.session
  a.libraryLiked=true;a.search.stringValue="kept";a.checkLinkImport();await release(a,1)
  check("complete-hidden-panel-stores-before-ack",durable.count==1 && a.bridge.held.count==3 && a.bridge.value(2)["command"] as? String=="acknowledge_credentials" && a.linkImport.deferredLibrary != nil)
  await release(a,2)
  check("completion-drains-real-library-after-ack",a.bridge.held.count==4 && a.bridge.value(3)["command"] as? String=="library_liked" && a.bridge.value(3)["query"] as? String=="kept" && a.bridge.value(3)["offset"] as? Int==0)
  if a.bridge.held.count>3 {await release(a,3)}
  check("completion-no-queue-or-session-mutation",a.snapshot!.queue.map{$0.id}==queue && a.snapshot!.session==session && a.bridge.revokes==0 && a.effects.isEmpty)
  let count=a.bridge.held.count;a.checkLinkImport();await release(a,count)
  check("repeat-complete-one-shot-library",a.bridge.held.count==count+1 && a.linkImport.deferredLibrary==nil)
  a.openImportLibrary();let opened=a.bridge.held.count-1
  check("explicit-open-all-empty-query-read",a.bridge.value(opened)["command"] as? String=="library" && a.bridge.value(opened)["query"] as? String=="" && a.bridge.value(opened)["offset"] as? Int==0)
  await release(a,opened)
  check("acknowledged-library-enables-ordinary-row",!a.libraryReadInvalid && a.snapshot!.library.contains{$0.id==7} && !a.libraryLiked && a.table.selectedRow==1)
  a.bridge.seedCache([7,8]);a.selectTrack();let play=a.bridge.held.count-1;await release(a,play)
  check("explicit-play-existing-select-only",a.bridge.value(play)["command"] as? String=="select" && a.bridge.response(play).ok && a.effects.last?.action=="load" && a.bridge.revokes==1)
  let b=ready();b.readLibrary(liked:false);b.linkImport.jobID="12345678-1234-4234-8234-123456789abc";b.checkLinkImport();await release(b,1)
  check("positive-existing-library-read-holds-import-intent",b.pendingLibraryRead != nil && b.linkImport.deferredLibrary != nil && b.bridge.held.count==2)
  await release(b,0)
  check("deferred-intent-eventually-drained",b.linkImport.deferredLibrary==nil && b.bridge.held.count==3 && b.bridge.value(2)["command"] as? String=="library")
  if b.bridge.held.count>2 {await release(b,2)}
  let c=ready();c.linkImport.draft="https://youtu.be/dQw4w9WgXcQ";c.submitLink();c.command(["command":"logout"]);await release(c,0)
  check("account-replacement-retires-import",c.linkImport.pending==nil && c.linkImport.jobID==nil && c.linkImport.draft.isEmpty)
  while c.busy>0 {await release(c,c.bridge.held.count-1)}
  let d=ready();d.linkImport.jobID="12345678-1234-4234-8234-123456789abc";d.checkLinkImport();d.bridge.release(0);await settle(d)
  let library=d.bridge.held.count-1
  if library>0 {await release(d,library)}
  let prior=d.linkImport.jobID
  d.checkLinkImport()
  let bad=d.bridge.held.count-1
  d.bridge.held[bad].completion(Data("malformed".utf8));d.bridge.released+=1;await settle(d)
  check("failed-read-retains-known-job",d.linkImport.jobID==prior && d.linkImport.job?.track_id==7)
  let e=ready();e.linkImport.draft="https://youtu.be/dQw4w9WgXcQ";e.submitLink();let stale=e.bridge.held.count-1
  e.epoch=e.bridge.revoke();_ = e.bridge.execute(["command":"snapshot"],epoch:e.epoch);e.apply(try! JSONDecoder().decode(Reply.self,from:e.bridge.execute(["command":"snapshot"],epoch:e.epoch)).snapshot!)
  await release(e,stale);check("epoch-suppression-settles-uncertain-latch",e.linkImport.pending==nil && e.linkImport.outcome=="uncertain")
  e.checkLinkImport();await release(e,e.bridge.held.count-1)
  check("current-read-recovers-suppressed-accepted-receipt",e.linkImport.outcome=="accepted" && e.linkImport.jobID != nil)
  let f=ready();f.linkImport.draft="https://youtu.be/dQw4w9WgXcQ";f.submitLink();await release(f,0)
  f.newLinkImport();f.linkImport.draft="https://youtu.be/dQw4w9WgXcQ";f.submitLink();if f.bridge.held.count>1 {await release(f,1)}
  check("explicit-another-import-new-operation",f.bridge.held.count==2 && f.bridge.value(1)["operation_id"] as? UInt64==2 && f.linkImport.outcome=="accepted")
  // Fresh account recovery A must not own the newly admitted operation B.
  func drain(_ app:App) async {while app.busy>0 {let next=(0..<app.bridge.held.count).first{!app.bridge.delivered.contains($0)}!;await release(app,next)}}
  let oldID="42345678-1234-4234-8234-123456789abc",newID="32345678-1234-4234-8234-123456789abc"
  let g=ready();let originalQueue=g.snapshot!.queue.map{$0.id},originalSession=g.snapshot!.session
  g.recentLinkImports();await drain(g)
  let choices=NSPopUpButton(frame:.zero,pullsDown:false);choices.addItems(withTitles:g.linkImport.jobs.map{$0.job_id});choices.selectItem(at:0)
  g.chooseLinkImport(choices);await drain(g)
  check("recovered-A-before-new-submission",g.linkImport.jobID==oldID && g.linkImport.job?.track_id==7 && g.linkImport.outcome=="draft")
  g.linkImport.draft="https://youtu.be/BBBBBBBBBBB";let newPost=g.bridge.held.count;g.submitLink();await drain(g)
  check("new-B-ACK-retires-A-projection",g.bridge.value(newPost)["command"] as? String=="import_link" && g.linkImport.jobID==newID && g.linkImport.job==nil)
  let statusB=g.bridge.held.count;g.checkLinkImport();await drain(g)
  check("check-status-targets-new-B",g.bridge.value(statusB)["job_id"] as? String==newID && g.linkImport.job?.track_id==9)
  g.openImportLibrary();await drain(g)
  check("B-completion-acknowledged-library-selection",g.table.selectedRow>=0 && g.snapshot!.library[g.table.selectedRow].id==9 && g.pendingLibraryRead==nil && !g.libraryReadInvalid)
  check("B-completion-no-autoplay-queue-mutation",g.snapshot!.queue.map{$0.id}==originalQueue && g.snapshot!.session==originalSession && g.effects.isEmpty && g.bridge.revokes==0)
  choices.selectItem(at:0);g.chooseLinkImport(choices);await drain(g)
  let statusA=g.bridge.held.count;g.checkLinkImport();await drain(g)
  check("explicit-recovery-A-survives-unrelated-B-receipt",g.linkImport.jobs.contains{$0.job_id==oldID} && g.bridge.value(statusA)["job_id"] as? String==oldID && g.linkImport.jobID==oldID && g.linkImport.job?.track_id==7)
  for uncertain in [false,true] {
   let h=ready(),tag=uncertain ? "uncertain":"accepted"
   h.linkImport.draft=uncertain ? "https://youtu.be/UUUUUUUUUUU":"https://youtu.be/dQw4w9WgXcQ"
   h.submitLink();await drain(h);let old=h.linkImport.operation
   check("active-"+tag+"-initial-receipt",h.linkImport.outcome==tag && old==1)
   h.openLinkImport();await drain(h);h.closeLinkImport();h.openLinkImport();await drain(h)
   check("active-"+tag+"-ordinary-reopen-recovers",h.linkImport.outcome==tag && h.linkImport.operation==old && h.importWindow.begins==2 && h.importWindow.ends==1)
   h.newLinkImport();h.linkImportView!.url.stringValue="https://youtu.be/BBBBBBBBBBB";h.linkImportView!.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
   let read=h.bridge.held.count;h.checkLinkImport();await drain(h)
   check("another-"+tag+"-check-keeps-editable-draft",h.linkImport.outcome=="draft" && h.linkImport.draft=="https://youtu.be/BBBBBBBBBBB" && h.linkImport.jobID==nil && h.linkImportView!.submit.isEnabled)
   check("another-"+tag+"-core-retains-no-replay-receipt",h.bridge.response(read).import_result?.receipt?.operation_id==old && h.bridge.response(read).import_result?.receipt?.outcome==tag)
   let replay=try! JSONDecoder().decode(Reply.self,from:h.bridge.execute(["command":"import_link","operation_id":old,"url":h.linkImport.draft]))
   check("another-"+tag+"-retired-operation-replay-refused",!replay.ok && replay.code=="import_duplicate" && replay.import_result?.receipt?.operation_id==old)
   h.recentLinkImports();await drain(h)
   check("another-"+tag+"-recent-keeps-editable-draft",h.linkImport.outcome=="draft" && h.linkImport.jobID==nil && h.linkImportView!.submit.isEnabled && !h.linkImport.jobs.isEmpty)
   h.closeLinkImport();h.openLinkImport();await drain(h)
   check("another-"+tag+"-close-reopen-keeps-draft",h.linkImport.outcome=="draft" && h.linkImportView!.url.stringValue=="https://youtu.be/BBBBBBBBBBB" && h.linkImportView!.submit.isEnabled && h.linkImport.operation==old)
   let before=h.bridge.held.count;h.submitLink();h.submitLink();await drain(h)
   check("another-"+tag+"-one-explicit-next-post",h.bridge.held.count==before+1 && h.bridge.value(before)["operation_id"] as? UInt64==old+1 && h.linkImport.jobID==newID && h.linkImport.outcome=="accepted")
   let posts=h.bridge.held.filter{(try! JSONSerialization.jsonObject(with:$0.value) as! [String:Any])["command"] as? String=="import_link"}.count
   check("another-"+tag+"-exactly-two-user-posts",posts==2 && h.effects.isEmpty && h.bridge.revokes==0)
   h.closeLinkImport();h.retireLinkImport()
   check("another-"+tag+"-account-retirement-clears-state",h.linkImport.operation==0 && h.linkImport.jobID==nil && h.linkImport.jobs.isEmpty && h.linkImport.draft.isEmpty)
  }
  // Current request feedback must not be inferred from an unrelated old receipt.
  let unsent="Link was not sent. Use an HTTPS YouTube video or SoundCloud track link."
  let refused="Link was not accepted. Check the link or sign in, then try again."
  let unknown="Submission is unconfirmed. Check recent jobs and choose an import; a matching link is not a confirmed match."
  let readFailure="Could not confirm import status. Check status or recent jobs."
  func feedback(_ app:App,_ text:String)->Bool {app.linkImport.feedback==text && app.linkImportView?.feedback.stringValue==text}
  func observed()->App {let app=ready();app.linkImportView=LinkImportView(target:app,scale:1);app.updateLinkImport();return app}
  let scenarios=[("validation","not-a-link","not_sent",unsent),
                 ("http400","https://youtu.be/44444444444","rejected",refused),
                 ("http401","https://youtu.be/11111111111","rejected",refused),
                 ("http503","https://youtu.be/55555555555","uncertain",unknown),
                 ("dropped","https://youtu.be/DDDDDDDDDDD","uncertain",unknown),
                 ("malformed-ack","https://youtu.be/MMMMMMMMMMM","uncertain",unknown)]
  let readControl=URL(fileURLWithPath:CommandLine.arguments[3]).appendingPathComponent("read-failure.json")
  for (name,url,outcome,message) in scenarios {
   let app=observed();app.linkImport.draft=url;let before=app.snapshot!
   app.submitLink();await drain(app)
   check("feedback-"+name+"-current-submission",app.bridge.response(0).import_result?.receipt?.outcome==outcome && app.linkImport.outcome==outcome && feedback(app,message))
   check("feedback-"+name+"-matching-latch-and-ownership",app.linkImport.pending==nil && app.linkImport.reading==nil && app.busy==0 && app.bridge.held.count==1 && app.effects.isEmpty && app.bridge.revokes==0 && app.snapshot!.queue.map{$0.id}==before.queue.map{$0.id} && app.snapshot!.session==before.session && app.linkImportView!.submit.isEnabled == (outcome != "uncertain"))
   // Real failed safe GET carries the core's old submission evidence unchanged.
   try Data("{}".utf8).write(to:readControl)
   app.checkLinkImport();let read=app.bridge.held.count-1;await drain(app)
   try FileManager.default.removeItem(at:readControl)
   check("feedback-"+name+"-failed-GET-not-old-submission",!app.bridge.response(read).ok && app.bridge.response(read).import_result?.receipt?.outcome==outcome && app.linkImport.outcome==outcome && feedback(app,readFailure) && app.linkImport.reading==nil && app.linkImport.pending==nil && app.bridge.held.count==2)
  }
  for cancelled in [false,true] {
   let app=observed(),tag=cancelled ? "cancelled":"malformed-native"
   app.linkImport.draft="https://youtu.be/CCCCCCCCCCC";app.submitLink()
   check("feedback-"+tag+"-real-core-accepted-before-delivery",app.bridge.response(0).ok && app.bridge.response(0).import_result?.receipt?.outcome=="accepted")
   if cancelled {
    app.epoch=app.bridge.revoke();app.apply(try! JSONDecoder().decode(Reply.self,from:app.bridge.execute(["command":"snapshot"],epoch:app.epoch)).snapshot!)
    await release(app,0)
   } else {app.bridge.held[0].completion(Data("malformed".utf8));app.bridge.delivered.insert(0);app.bridge.released+=1;await settle(app)}
   check("feedback-"+tag+"-uncertain-not-status-read",app.linkImport.pending==nil && app.busy==0 && app.linkImport.outcome=="uncertain" && feedback(app,unknown) && !app.linkImportView!.submit.isEnabled)
   try Data("{}".utf8).write(to:readControl);app.checkLinkImport();let failedRead=app.bridge.held.count-1;await drain(app);try FileManager.default.removeItem(at:readControl)
   check("feedback-"+tag+"-failed-read-cannot-adopt-old-accepted-receipt",!app.bridge.response(failedRead).ok && app.bridge.response(failedRead).import_result?.receipt?.outcome=="accepted" && app.linkImport.outcome=="uncertain" && app.linkImport.jobID==nil && feedback(app,readFailure) && app.linkImport.reading==nil && app.bridge.held.count==2)
   app.checkLinkImport();await drain(app)
   check("feedback-"+tag+"-explicit-read-recovers",app.linkImport.outcome=="accepted" && app.linkImport.jobID != nil && app.linkImport.pending==nil && app.linkImport.reading==nil && app.effects.isEmpty)
  }
  let known=observed();known.linkImport.draft="https://youtu.be/KKKKKKKKKKK";known.submitLink();await drain(known);known.checkLinkImport();await drain(known)
  let knownJob=known.linkImport.jobID,knownTrack=known.linkImport.job?.track_id,knownOperation=known.linkImport.operation,knownCommands=known.bridge.held.count
  check("feedback-failed-read-positive-known-job",knownJob != nil && knownTrack==7 && known.linkImport.outcome=="accepted")
  try Data("{}".utf8).write(to:readControl);known.checkLinkImport();await drain(known);try FileManager.default.removeItem(at:readControl)
  check("feedback-failed-read-retains-accepted-identity",known.linkImport.jobID==knownJob && known.linkImport.job?.track_id==knownTrack && known.linkImport.operation==knownOperation && known.linkImport.outcome=="accepted" && feedback(known,readFailure) && known.linkImport.reading==nil && known.bridge.held.count==knownCommands+1)
  known.newLinkImport();known.linkImport.draft="https://youtu.be/BBBBBBBBBBB"
  try Data("{}".utf8).write(to:readControl);known.recentLinkImports();await drain(known);try FileManager.default.removeItem(at:readControl)
  check("feedback-failed-read-retired-receipt-stays-draft",known.linkImport.jobID==nil && known.linkImport.job==nil && known.linkImport.outcome=="draft" && known.linkImport.draft=="https://youtu.be/BBBBBBBBBBB" && feedback(known,readFailure) && known.linkImportView!.submit.isEnabled)
  // Deliver an actual earlier refused envelope to the next operation's callback.
  let mismatch=observed();mismatch.linkImport.draft="https://youtu.be/44444444444";mismatch.submitLink();await drain(mismatch)
  mismatch.newLinkImport();mismatch.linkImport.draft="https://youtu.be/CCCCCCCCCCC";mismatch.submitLink()
  mismatch.bridge.held[1].completion(mismatch.bridge.held[0].response);mismatch.bridge.delivered.insert(1);mismatch.bridge.released+=1;await settle(mismatch)
  check("feedback-mismatched-receipt-cannot-diagnose-current-submit",mismatch.linkImport.operation==2 && mismatch.linkImport.outcome=="uncertain" && feedback(mismatch,unknown) && mismatch.linkImport.pending==nil && mismatch.linkImport.jobID==nil)
  print("IMPORT_SUMMARY passes=\(passes.count) failures=\(failures.count)");exit(failures.isEmpty ? 0:1)
 }
}
'''

def composition(root,out,lib):
 import socket,threading,urllib.parse
 from library_projection_regressions import header,BRIDGE
 from library_dock_presentation import FILES
 from native_review_regressions import swift_block
 out.mkdir(parents=True,exist_ok=False);text=(root/'native/macos/Sources/main.swift').read_text();h,blocks=header(root)
 for s in ['@objc func openLinkImport(){};','func retireLinkImport(){};','func drainImportLibraryRefresh(){};']:h=h.replace(s,'')
 methods='\n'.join(swift_block(text,s) for s in IMPORT_METHODS)
 if 'enum LinkImportRequest' in text:methods=swift_block(text,'enum LinkImportRequest')+'\n'+methods
 # Only the OS window surface is substituted: execute the complete production
 # open/close methods, renderer edit callback and automatic read without windows.
 for sig in ['@objc func openLinkImport()', '@objc func closeLinkImport()']:
  original=swift_block(text,sig)
  methods=methods.replace(original,original.replace('window.','importWindow.').replace('NSWindow(','ImportWindow('))
 h=h.replace(' var window:NSWindow!;', ' var linkImport=LinkImportState();var importWindow=ImportWindow();var linkImportSheet:ImportWindow?;var linkImportView:LinkImportView?\n'+methods+'\n var window:NSWindow!;')
 state=swift_block((root/'native/macos/Sources/LinkImport.swift').read_text(),'struct LinkImportState')
 # Compile the actual renderer too; App selectors resolve against the extracted owner.
 helper=(root/'native/macos/Sources/LinkImport.swift').read_text()
 view=helper.replace('import AppKit','').replace(state,'')
 window_surface=r'''
@MainActor final class ImportWindow {
 var frame=NSRect(x:0,y:0,width:960,height:760),attachedSheet:ImportWindow?,contentView:NSView?,title="",begins=0,ends=0
 init(){}
 init(contentRect:NSRect,styleMask:NSWindow.StyleMask,backing:NSWindow.BackingStoreType,defer:Bool){frame=contentRect}
 func beginSheet(_ sheet:ImportWindow){attachedSheet=sheet;begins+=1}
 func endSheet(_ sheet:ImportWindow){precondition(attachedSheet === sheet);attachedSheet=nil;ends+=1}
 func orderOut(_ sender:Any?){}
 @discardableResult func makeFirstResponder(_ view:NSView?)->Bool {true}
}
'''
 source='import AVFoundation\nimport CryptoKit\nimport SoundQCore\n'+BRIDGE+'\n'+window_surface+'\n'+state+'\n'+h+'\n'+view+'\n'+COMPOSITION
 p=out/'main.swift';p.write_text(source)
 deps=[root/'native/macos/Sources'/n for n in FILES+['LibraryMetadataDisclosure.swift','LibraryFavoriteMenu.swift']]
 argv=['swiftc','-parse-as-library','-swift-version','6','-num-threads','2','-I',str(root/'native/core/include'),*[str(d) for d in deps],str(p),str(lib),'-Xlinker','-rpath','-Xlinker',str(lib.parent),'-o',str(out/'probe')]
 built=subprocess.run(argv,capture_output=True,timeout=180);(out/'compile.log').write_bytes(built.stdout+built.stderr)
 listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen();listener.settimeout(.2);stop=threading.Event();seen=[];errors=[];rotated=False
 def server():
  nonlocal rotated
  try:
   while not stop.is_set():
    try:conn,_=listener.accept()
    except socket.timeout:continue
    with conn:
     conn.settimeout(3);raw=b''
     while b'\r\n\r\n' not in raw:raw+=conn.recv(8192)
     head,body=raw.split(b'\r\n\r\n',1);verb,path,_=head.split(b'\r\n',1)[0].decode().split(' ');u=urllib.parse.urlparse(path);q=urllib.parse.parse_qs(u.query,keep_blank_values=True)
     length=next((int(l.split(b':',1)[1]) for l in head.split(b'\r\n') if l.lower().startswith(b'content-length:')),0)
     while len(body)<length:body+=conn.recv(8192)
     status='200 OK';drop=False
     if verb=='GET' and u.path.startswith('/api/v1/downloads') and (out/'read-failure.json').exists():status='503 Service Unavailable';result={}
     elif u.path=='/api/v1/auth/refresh':result=dict(accessToken='test-access',refreshToken='test-refresh',user=dict(id='projection-synthetic-account'))
     elif u.path=='/api/v1/auth/logout':result={}
     elif u.path=='/api/v1/downloads' and verb=='POST':
      payload=json.loads(body);assert payload['source_type']=='youtube';assert payload['url'] in ['https://youtu.be/'+s for s in ['dQw4w9WgXcQ','BBBBBBBBBBB','UUUUUUUUUUU','44444444444','11111111111','55555555555','DDDDDDDDDDD','MMMMMMMMMMM','CCCCCCCCCCC','KKKKKKKKKKK']];status='201 Created';result=dict(job_id='32345678-1234-4234-8234-123456789abc' if payload['url'].endswith('BBBBBBBBBBB') else '12345678-1234-4234-8234-123456789abc',status='queued',sourceDecisionId='22345678-1234-4234-8234-123456789abc')
      if payload['url'].endswith('UUUUUUUUUUU'):status='503 Service Unavailable';result={}
      for suffix,code in [('44444444444','400 Bad Request'),('11111111111','401 Unauthorized'),('55555555555','503 Service Unavailable')]:
       if payload['url'].endswith(suffix):status=code;result={}
      if payload['url'].endswith('DDDDDDDDDDD'):drop=True
      if payload['url'].endswith('MMMMMMMMMMM'):result={'job_id':'malformed'}
     elif u.path.startswith('/api/v1/downloads/'):
      if not rotated:rotated=True;status='401 Unauthorized';result={}
      else:result=dict(job_id=u.path.rsplit('/',1)[1],status='complete',progress=100,url='https://youtu.be/dQw4w9WgXcQ',source_type='youtube',track_id=9 if u.path.endswith('32345678-1234-4234-8234-123456789abc') else 7,created_at='2026-10-27T12:00:00Z')
     elif u.path=='/api/v1/downloads':result=dict(jobs=[dict(job_id='42345678-1234-4234-8234-123456789abc',status='complete',progress=100,url='https://youtu.be/dQw4w9WgXcQ',source_type='youtube',track_id=7,created_at='2026-10-27T12:00:00Z')])
     elif u.path=='/api/v1/library':result=dict(tracks=[] if q['q']==['kept'] else [dict(id=i,title=f'Track {i}',duration_ms=30000,is_liked=False) for i in [8,7,9]],total=0 if q['q']==['kept'] else 3,offset=0)
     else:raise AssertionError(path)
     seen.append(dict(verb=verb,path=u.path,query=q,status='dropped' if drop else status,payload=json.loads(body) if verb=='POST' and u.path=='/api/v1/downloads' else None))
     if drop:continue
     data=json.dumps(result).encode();conn.sendall(b'HTTP/1.1 '+status.encode()+b'\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: '+str(len(data)).encode()+b'\r\n\r\n'+data)
  except Exception as e:errors.append(repr(e))
  finally:listener.close()
 endpoint='http://127.0.0.1:%d/api/v1'%listener.getsockname()[1];thread=threading.Thread(target=server);thread.start()
 try:ran=subprocess.run([str(out/'probe'),str(root/'native/macos/Sources/Resources'),endpoint,str(out)],capture_output=True,timeout=45) if built.returncode==0 else None
 finally:stop.set();thread.join(5)
 (out/'run.log').write_bytes(ran.stdout+ran.stderr if ran else b'NOT RUN');lines=ran.stdout.decode().splitlines() if ran else [];passes=[x[5:] for x in lines if x.startswith('PASS ')];fails=[x[5:] for x in lines if x.startswith('FAIL ')]
 expected=['held-duplicate-close-reentry-one-post','accepted-hidden-panel-retained','complete-hidden-panel-stores-before-ack','completion-drains-real-library-after-ack','completion-no-queue-or-session-mutation','repeat-complete-one-shot-library','explicit-open-all-empty-query-read','acknowledged-library-enables-ordinary-row','explicit-play-existing-select-only','deferred-intent-eventually-drained','account-replacement-retires-import','failed-read-retains-known-job','epoch-suppression-settles-uncertain-latch','current-read-recovers-suppressed-accepted-receipt','explicit-another-import-new-operation']
 expected.append('positive-existing-library-read-holds-import-intent')
 expected += ['recovered-A-before-new-submission','new-B-ACK-retires-A-projection','check-status-targets-new-B','B-completion-acknowledged-library-selection','B-completion-no-autoplay-queue-mutation','explicit-recovery-A-survives-unrelated-B-receipt']
 expected += ['active-'+tag+'-'+suffix for tag in ['accepted','uncertain'] for suffix in ['initial-receipt','ordinary-reopen-recovers']]
 expected += ['another-'+tag+'-'+suffix for tag in ['accepted','uncertain'] for suffix in ['check-keeps-editable-draft','core-retains-no-replay-receipt','retired-operation-replay-refused','recent-keeps-editable-draft','close-reopen-keeps-draft','one-explicit-next-post','exactly-two-user-posts','account-retirement-clears-state']]
 ownership_expected=list(expected)
 expected += ['feedback-'+tag+'-'+suffix for tag in ['validation','http400','http401','http503','dropped','malformed-ack'] for suffix in ['current-submission','matching-latch-and-ownership','failed-GET-not-old-submission']]
 expected += ['feedback-'+tag+'-'+suffix for tag in ['cancelled','malformed-native'] for suffix in ['real-core-accepted-before-delivery','uncertain-not-status-read','failed-read-cannot-adopt-old-accepted-receipt','explicit-read-recovers']]
 expected += ['feedback-failed-read-positive-known-job','feedback-failed-read-retains-accepted-identity','feedback-failed-read-retired-receipt-stays-draft','feedback-mismatched-receipt-cannot-diagnose-current-submit']
 from collections import Counter
 http_posts=[v['payload']['url'] for v in seen if v['verb']=='POST' and v['path']=='/api/v1/downloads']
 expected_posts={'https://youtu.be/dQw4w9WgXcQ':6,'https://youtu.be/BBBBBBBBBBB':3,'https://youtu.be/UUUUUUUUUUU':1}
 expected_posts.update({'https://youtu.be/'+s:n for s,n in [('44444444444',2),('11111111111',1),('55555555555',1),('DDDDDDDDDDD',1),('MMMMMMMMMMM',1),('CCCCCCCCCCC',3),('KKKKKKKKKKK',1)]})
 r=dict(passed=built.returncode==0 and ran is not None and ran.returncode==0 and Counter(passes)==Counter(expected) and Counter(http_posts)==Counter(expected_posts) and not errors and not thread.is_alive(),passes=passes,failures=fails,expected=expected,compile_exit=built.returncode,run_exit=ran.returncode if ran else None,errors=errors,skips=0,requests=seen,httpPosts=dict(Counter(http_posts)),expectedHttpPosts=expected_posts,threadDrained=not thread.is_alive(),argv=argv,TMPDIR=os.environ.get('TMPDIR'),core_sha256=hashlib.sha256(lib.read_bytes()).hexdigest(),probe_sha256=hashlib.sha256(p.read_bytes()).hexdigest(),test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),state_sha256=hashlib.sha256(state.encode()).hexdigest(),compiledMethodsSha256=hashlib.sha256(methods.encode()).hexdigest(),dependencies={str(d.relative_to(root)):hashlib.sha256(d.read_bytes()).hexdigest() for d in deps},productionBlocks={s:hashlib.sha256(swift_block(text,s).encode()).hexdigest() for s in IMPORT_METHODS})
 r['ownershipExpected']=ownership_expected;r['ownershipPassed']=[n for n in passes if n in ownership_expected]
 r['serverEndpoint']=endpoint;r['serverThreadIdent']=thread.ident;r['compilerPIDDrained']=built.returncode is not None;r['probePIDDrained']=ran is not None and ran.returncode is not None
 (out/'receipt.json').write_text(json.dumps(r,indent=2)+'\n');print((out/'compile.log').read_text());print((out/'run.log').read_text());return r['passed']
CASES=r'''
@main struct Tests {
 @MainActor static func main() async {
  var failed=0
  func check(_ n:String,_ v:Bool){print(v ? "PASS":"FAIL",n);if !v {failed+=1}}
  for kind in ["import_link","import_jobs","import_job"] {
   let a=App();var results=0,done=0
   _ = a.command(["command":kind],result:{_ in results+=1},completion:{done+=1})
   a.bridge.release(Data("malformed".utf8));while a.busy>0 {await Task.yield()}
   check(kind+"-malformed-terminal-once",results==1 && done==1)
   _ = a.command(["command":kind],result:{_ in results+=1},completion:{done+=1})
   a.epoch=2;a.bridge.release(Data("{}".utf8));while a.busy>0 {await Task.yield()}
   check(kind+"-epoch-terminal-once",results==2 && done==2)
  }
  exit(failed==0 ? 0:1)
 }
}
'''
def run(root,out):
 out.mkdir(parents=True,exist_ok=False)
 source=mac_terminal(root);source=source[:source.index('@main struct Tests')]+CASES
 p=out/'main.swift';p.write_text(source)
 argv=['swiftc','-parse-as-library','-swift-version','6','-num-threads','2',str(p),'-o',str(out/'probe')]
 built=subprocess.run(argv,capture_output=True,timeout=120);(out/'compile.log').write_bytes(built.stdout+built.stderr)
 ran=subprocess.run([str(out/'probe')],capture_output=True,timeout=30) if built.returncode==0 else None
 (out/'run.log').write_bytes(ran.stdout+ran.stderr if ran else b'NOT RUN')
 lines=ran.stdout.decode().splitlines() if ran else [];passes=[x[5:] for x in lines if x.startswith('PASS ')];fails=[x[5:] for x in lines if x.startswith('FAIL ')]
 expected=[k+'-'+suffix for k in ['import_link','import_jobs','import_job'] for suffix in ['malformed-terminal-once','epoch-terminal-once']]
 from collections import Counter
 receipt=dict(passed=built.returncode==0 and ran is not None and ran.returncode==0 and Counter(passes)==Counter(expected),passes=passes,failures=fails,expected=expected,compile_exit=built.returncode,run_exit=ran.returncode if ran else None,skips=0,argv=argv,TMPDIR=os.environ.get('TMPDIR'),probe_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
 (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print((out/'compile.log').read_text());print((out/'run.log').read_text());return receipt['passed']
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--source-root',type=Path,default=ROOT);p.add_argument('--output',type=Path,required=True);p.add_argument('--core-library',type=Path);a=p.parse_args();raise SystemExit(0 if (composition(a.source_root,a.output,a.core_library.resolve()) if a.core_library else run(a.source_root,a.output)) else 1)
