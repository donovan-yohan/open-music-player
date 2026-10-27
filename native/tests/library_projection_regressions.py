#!/usr/bin/env python3
"""Real ABI1 Library publication -> held native callback authority regression.

Synthetic loopback HTTP only. No app/window, decoder, keychain or Go fixture.
The Bridge executes the installed cdylib before holding delivery, reproducing
producer commit versus main-actor delivery rather than inventing snapshots.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import threading
import urllib.parse
from library_dock_presentation import production_probe, FILES
from native_review_regressions import swift_block

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = r'''
final class Bridge:@unchecked Sendable {
 struct Held {let value:Data;let epoch:UInt64;let response:Data;let completion:@Sendable(Data)->Void}
 let handle:UInt64
 var held=[Held]();var released=0;var revokes=0;var delivered=Set<Int>()
 var root:String
 init() {
  precondition(sq_core_abi_version()==1)
  let path=CommandLine.arguments[3]+"/case-"+UUID().uuidString
  root=path
  let endpoint=CommandLine.arguments[2]
  handle=endpoint.withCString {e in path.withCString {sq_core_open(e,$0)}}
  precondition(handle != 0)
 }
 deinit {sq_core_close(handle)}
 func execute(_ value:[String:Any],epoch:UInt64=1)->Data {
  var v=value;v["account_scope_v1"]=1
  return executeData(try! JSONSerialization.data(withJSONObject:v),epoch:epoch)
 }
 func executeData(_ data:Data,epoch:UInt64)->Data {
  let text=String(data:data,encoding:.utf8)!
  let p=text.withCString {sq_core_execute(handle,epoch,$0)}!
  let result=Data(bytes:p,count:strlen(p));sq_core_string_free(p);return result
 }
 func send(_ data:Data,epoch:UInt64,completion:@escaping @Sendable(Data)->Void) {
  let response=executeData(data,epoch:epoch),index=held.count
  try! data.write(to:URL(fileURLWithPath:root).appendingPathComponent("native-\(index)-request.json"))
  try! response.write(to:URL(fileURLWithPath:root).appendingPathComponent("native-\(index)-response.json"))
  held.append(Held(value:data,epoch:epoch,response:response,completion:completion))
 }
 func revoke()->UInt64 {revokes+=1;return sq_core_revoke(handle)}
 func value(_ i:Int)->[String:Any] {try! JSONSerialization.jsonObject(with:held[i].value) as! [String:Any]}
 func response(_ i:Int)->Reply {try! JSONDecoder().decode(Reply.self,from:held[i].response)}
 func release(_ i:Int) {if delivered.insert(i).inserted {released+=1;held[i].completion(held[i].response)}}
 // Compatibility delivery changes only the optional snapshot marker; retain
 // both exact envelopes so the runner verifies the sole semantic difference.
 func withoutRevision(_ data:Data,_ name:String)->Data {
  var envelope=try! JSONSerialization.jsonObject(with:data) as! [String:Any]
  var snapshot=envelope["snapshot"] as! [String:Any]
  precondition(snapshot.removeValue(forKey:"library_revision") != nil)
  envelope["snapshot"]=snapshot
  let legacy=try! JSONSerialization.data(withJSONObject:envelope,options:[.sortedKeys])
  let dir=URL(fileURLWithPath:root)
  try! data.write(to:dir.appendingPathComponent(name+"-original.json"))
  try! legacy.write(to:dir.appendingPathComponent(name+"-legacy.json"))
  return legacy
 }
 func releaseWithoutRevision(_ i:Int) {
  if delivered.insert(i).inserted {released+=1;held[i].completion(withoutRevision(held[i].response,"compat-\(i)"))}
 }
 func seedCache(_ ids:[Int]) {
  let endpoint=CommandLine.arguments[2]
  let scope=SHA256.hash(data:Data((endpoint+"\0projection-synthetic-account").utf8)).map{String(format:"%02x",$0)}.joined()
  let dir=URL(fileURLWithPath:root).appendingPathComponent(scope)
  try! FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
  for id in ids {
   let data=Data("synthetic-cache-never-decoded".utf8),name="\(id)-projection.wav"
   try! data.write(to:dir.appendingPathComponent(name))
   let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
   try! JSONSerialization.data(withJSONObject:["name":name,"sha256":digest]).write(to:dir.appendingPathComponent("\(id).json"))
  }
 }
 func removeCache(_ id:Int) {
  let paths=FileManager.default.enumerator(at:URL(fileURLWithPath:root),includingPropertiesForKeys:nil)!
  for case let p as URL in paths where p.lastPathComponent=="\(id).json" {try! FileManager.default.removeItem(at:p)}
 }
}
let kSecValueData="value",kSecAttrAccessible="accessible",kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly="device-only"
let errSecSuccess:Int32=0,errSecDuplicateItem:Int32 = -25299
@MainActor var durable=[Data]()
@MainActor func SecItemAdd(_ q:CFDictionary,_ out:UnsafeMutablePointer<CFTypeRef?>?)->Int32 {durable.append((q as NSDictionary)["value"] as! Data);return errSecSuccess}
@MainActor func SecItemUpdate(_ q:CFDictionary,_ v:CFDictionary)->Int32 {fatalError("unexpected duplicate storage")}
'''
CASES = r'''
@MainActor var passes=[String](),failures=[String](),barriers=[String]()
@MainActor func check(_ n:String,_ v:Bool){if v {passes.append(n);print("PASS",n)} else {failures.append(n);print("FAIL",n)};fflush(nil)}
@MainActor func settle(_ a:App) async {
 let limit=Date().addingTimeInterval(3)
 while a.busy != a.bridge.held.count-a.bridge.released && Date()<limit {await Task.yield()}
 let name="delivery-\(barriers.count)";barriers.append(name)
 if a.busy != a.bridge.held.count-a.bridge.released {failures.append(name);print("FAIL",name)}
}
@main struct ProjectionTests {
 @MainActor static func main() async throws {
  let assets=try NativeAssets.load(root:URL(fileURLWithPath:CommandLine.arguments[1]))
  func decoded(_ data:Data)->Reply {try! JSONDecoder().decode(Reply.self,from:data)}
  func rows(_ a:App)->[Int64] {a.snapshot!.library.map{$0.id}}
  func coreRows(_ a:App)->[Int64] {decoded(a.bridge.execute(["command":"snapshot"],epoch:a.epoch)).snapshot!.library.map{$0.id}}
  func available(_ a:App)->Bool {a.libraryDock!.controls.select.isEnabled}
  func ready(_ legacy:Bool=false)->App {
   let a=App();a.mountLibraryDock(in:NSView(frame:NSRect(x:0,y:0,width:960,height:700)),assets:assets)
   let auth=decoded(a.bridge.execute(["command":"restore","access_token":"projection-synthetic-old","refresh_token":"projection-synthetic-old-refresh","account_id":"projection-synthetic-account"]))
   precondition(auth.ok);_ = a.bridge.execute(["command":"acknowledge_credentials","version":auth.credentials!.version!])
   _ = a.bridge.execute(["command":"library","offset":0,"query":"","sort":"added_at","order":"desc"])
   a.bridge.seedCache([7,8,9]);let selected=decoded(a.bridge.execute(["command":"select","track_id":7]))
   _ = a.bridge.execute(["command":"audio_report","epoch":1,"session":selected.snapshot!.session,"state":"playing","position_ms":4321,"duration_ms":30000])
   let initial=a.bridge.execute(["command":"snapshot"])
   a.apply(decoded(legacy ? a.bridge.withoutRevision(initial,"compat-initial"):initial).snapshot!)
   return a
  }
  func releaseLast(_ a:App) async {a.bridge.release(a.bridge.held.count-1);await settle(a)}
  func establish(_ a:App,_ liked:Bool=false) async {
   a.refresh();await releaseLast(a)
   if liked {a.toggleLibraryLiked();await releaseLast(a)}
   a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.updateLibraryAvailability()
  }
  if !CommandLine.arguments.contains("compatibility") {
  // Joined production menu -> ABI/HTTP unlike -> native Load more recovery.
  for query in ["", "Ω & valid", String(repeating:"Ω",count:256)] {
   let a=ready();a.search.stringValue=query;await establish(a,true)
   let tag="favorite-pagination-\(query.utf8.count)",before=a.snapshot!,count=a.bridge.held.count
   func files()->[String:Data] {
    let root=URL(fileURLWithPath:a.bridge.root),paths=FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil)!
    var result=[String:Data]()
    for case let p as URL in paths where !p.lastPathComponent.hasPrefix("native-") && !p.hasDirectoryPath {result[p.path]=try! Data(contentsOf:p)}
    return result
   }
   let saved=files(),menu=LibraryFavoriteMenu(owner:a);menu.menuNeedsUpdate(menu)
   check(tag+"-positive-partial-liked-menu",a.libraryLiked && rows(a)==[8] && a.snapshot!.total>1 && menu.items[0].title=="Unlike selected track" && menu.validateMenuItem(menu.items[0]))
   menu.performFavorite(menu.items[0]);await releaseLast(a)
   check(tag+"-acknowledged-unlike-no-auto-read",a.bridge.held.count==count+1 && a.bridge.response(count).ok && a.bridge.value(count)["liked"] as? Bool==false && rows(a)==[8] && a.snapshot!.favorite_track_ids==[] && a.snapshot!.position_ms==before.position_ms && a.snapshot!.queue.map{$0.id}==before.queue.map{$0.id} && files()==saved)
   a.loadMore();let append=a.bridge.held.count-1
   check(tag+"-actual-stale-append-refused",a.bridge.value(append)["offset"] as? Int==1 && a.bridge.response(append).code=="invalid_query")
   await releaseLast(a)
   check(tag+"-truthful-refresh-guidance",a.status.stringValue=="Library changed. Refresh before loading more." && !a.status.stringValue.contains("Shorten") && rows(a)==[8] && a.pendingLibraryRead==nil && a.bridge.held.count==count+2 && files()==saved)
   a.refresh();check(tag+"-explicit-offset-zero",a.bridge.value(a.bridge.held.count-1)["offset"] as? Int==0);await releaseLast(a)
   a.loadMore();await releaseLast(a)
   check(tag+"-explicit-recovery-no-skipped-row",rows(a)==[9,10] && a.libraryLiked && a.libraryReadFailure==nil && a.snapshot!.position_ms==before.position_ms && a.snapshot!.queue.map{$0.id}==before.queue.map{$0.id} && files()==saved && a.bridge.held.count==count+4)
  }
  let oversized=ready();await establish(oversized,true);let beforeOversize=oversized.bridge.held.count
  oversized.search.stringValue=String(repeating:"Ω",count:257);oversized.refresh();await releaseLast(oversized)
  check("favorite-pagination-514-byte-query-still-shorten",oversized.bridge.response(beforeOversize).code=="invalid_query" && oversized.status.stringValue=="Invalid query. Shorten your search and try again." && oversized.bridge.held.count==beforeOversize+1)
  for reverse in [false,true] {for nextFirst in [false,true] {
   let a=ready();await establish(a,reverse)
   let olderReply=a.bridge.execute(["command":"snapshot"],epoch:a.epoch)
   let expected:[Int64]=reverse ? [8]:[7,8],tag="\(reverse ? "liked-all":"all-liked")-\(nextFirst ? "next-first":"read-first")"
   check(tag+"-positive-playing-baseline",rows(a)==expected && a.libraryLiked==reverse && available(a) && a.snapshot!.queue.map{$0.track.id}==[7,8] && a.snapshot!.transport=="playing" && a.snapshot!.position_ms==4321)
   a.toggleLibraryLiked();let old=a.bridge.held.count-1
   check(tag+"-producer-committed-before-delivery",a.bridge.response(old).ok && coreRows(a)==(reverse ? [7,8]:[8]) && rows(a)==expected && a.pendingLibraryRead != nil && a.bridge.revokes==0)
   a.nextTrack();let next=a.bridge.held.count-1
   check(tag+"-actual-next-retired-read",a.bridge.value(next)["command"] as? String=="next" && a.bridge.revokes==1 && a.epoch==2 && a.pendingLibraryRead==nil)
   if nextFirst {a.bridge.release(next);await settle(a);a.bridge.release(old);await settle(a)}
   else {a.bridge.release(old);await settle(a);a.bridge.release(next);await settle(a)}
   check(tag+"-mode-membership-not-republished",rows(a)==expected && a.libraryLiked==reverse && a.libraryLikedControl.selected==reverse)
   check(tag+"-canonical-next-effect-preserved",a.snapshot!.queue.map{$0.track.id}==[7,8] && a.snapshot!.selected_occurrence==a.snapshot!.queue[1].id && a.effects.last?.action=="load" && a.effects.last?.epoch==2 && a.busy==0)
   a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.updateLibraryAvailability()
   check(tag+"-unacknowledged-core-membership-unavailable",!available(a) && !a.libraryDetails.isEnabled && a.snapshot?.favorite_track_ids==nil)
   let count=a.bridge.held.count
   let refused=a.command(["command":"select","track_id":expected[0]])
   let appendRefused=a.command(["command":"queue_append","track_id":expected[0]])
   let favorite=a.command(["command":"set_favorite","track_id":expected[0],"liked":true])
   a.selectTrack();a.queueCommand("queue_append",id:UInt64(expected[0]))
   check(tag+"-direct-and-handler-row-authority-refused",!refused && !appendRefused && !favorite && a.bridge.held.count==count && a.bridge.revokes==1)
   // Older ABI1 snapshots decode, but cannot prove retired row authority.
   var legacy=try! JSONSerialization.jsonObject(with:a.bridge.execute(["command":"snapshot"],epoch:a.epoch)) as! [String:Any]
   var legacySnapshot=legacy["snapshot"] as! [String:Any];legacySnapshot.removeValue(forKey:"library_revision");legacy["snapshot"]=legacySnapshot
   a.apply(decoded(try! JSONSerialization.data(withJSONObject:legacy)).snapshot!)
   check(tag+"-missing-marker-cannot-clear-uncertainty",rows(a)==expected && !available(a) && a.libraryLiked==reverse)
   // Every scalar and full sibling must preserve unavailability and membership.
   for kind in ["snapshot","pause","previous","queue_move","set_favorite"] {
    if kind=="set_favorite" {continue} // refused above: no mutation without row authority
    let reloads=a.table.reloads
    if kind=="previous" {a.previousTrack()}
    else if kind=="queue_move" {a.queueCommand(kind,id:a.snapshot!.queue[0].id,index:0)}
    else {a.command(["command":kind])}
    await releaseLast(a)
    check(tag+"-sibling-"+kind,rows(a)==expected && !available(a) && a.libraryLiked==reverse && (kind != "pause" || a.table.reloads==reloads))
   }
   // An explicit failed recovery must not silently re-enable stale rows.
   a.search.stringValue="fail";a.refresh();await releaseLast(a)
   check(tag+"-failed-recovery-still-unavailable",!available(a) && rows(a)==expected && a.pendingLibraryRead==nil && a.libraryLiked==reverse)
   a.search.stringValue="";a.loadMore()
   check(tag+"-invalid-more-restarts-zero",a.bridge.value(a.bridge.held.count-1)["offset"] as? Int==0)
   await releaseLast(a);a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.updateLibraryAvailability()
   check(tag+"-explicit-recovery-restores-authority",available(a) && rows(a)==expected && coreRows(a)==expected && a.libraryLiked==reverse)
   let freshReloads=a.table.reloads
   // Preserve current transport fields while replaying a genuinely older core
   // Library topic to isolate delayed topic delivery, not stale audio ownership.
   var older=try! JSONSerialization.jsonObject(with:olderReply) as! [String:Any]
   var oldTopic=older["snapshot"] as! [String:Any]
   let current=try! JSONSerialization.jsonObject(with:a.bridge.execute(["command":"snapshot"],epoch:a.epoch)) as! [String:Any]
   let currentSnapshot=current["snapshot"] as! [String:Any]
   for key in ["epoch","session","queue","selected_occurrence","transport","position_ms","duration_ms"] {oldTopic[key]=currentSnapshot[key]}
   older["snapshot"]=oldTopic;a.apply(decoded(try! JSONSerialization.data(withJSONObject:older)).snapshot!)
   check(tag+"-older-topic-cannot-invalidate-newer-read",available(a) && rows(a)==expected && a.table.reloads==freshReloads)
   a.loadMore();check(tag+"-acknowledged-page-offset",a.bridge.value(a.bridge.held.count-1)["offset"] as? Int==expected.count);await releaseLast(a)
   let afterPage=rows(a);a.queueCommand("queue_append",id:8);let append=a.bridge.response(a.bridge.held.count-1);await releaseLast(a)
   check(tag+"-actual-append-authority",append.ok && coreRows(a)==afterPage && a.snapshot!.queue.last!.track.id==8)
   a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.updateLibraryAvailability();a.selectTrack();let select=a.bridge.response(a.bridge.held.count-1);await releaseLast(a)
   check(tag+"-actual-select-builds-authoritative-loaded-membership",select.ok && a.snapshot!.queue.map{$0.track.id}==afterPage && coreRows(a)==afterPage && rows(a)==afterPage && a.libraryLiked==reverse)
  }}
  // Same-mode query change is also a distinct producer publication.
  let q=ready();await establish(q);q.search.stringValue="narrow";q.refresh();let qi=q.bridge.held.count-1;q.nextTrack();await releaseLast(q);q.bridge.release(qi);await settle(q)
  q.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);q.updateLibraryAvailability()
  check("query-change-retired-membership-unavailable",rows(q)==[7,8] && coreRows(q)==[8] && !available(q) && !q.libraryLiked)
  q.refresh();await releaseLast(q);q.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);q.updateLibraryAvailability()
  check("query-recovery-authoritative",rows(q)==[8] && available(q) && q.acknowledgedLibraryRead?.queryUTF8==Array("narrow".utf8))
  // Failed precommit read retains the producer's acknowledged revision.
  let f=ready();await establish(f);f.search.stringValue="fail";f.toggleLibraryLiked();let fi=f.bridge.held.count-1;check("precommit-read-actually-failed",!f.bridge.response(fi).ok && coreRows(f)==[7,8]);f.nextTrack();await releaseLast(f);f.bridge.release(fi);await settle(f)
  f.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);f.updateLibraryAvailability();check("precommit-failure-current-transport-proves-old-authority",rows(f)==[7,8] && available(f) && !f.libraryLiked)
  // Current transport failure still publishes its queue/feedback, never Library.
  let t=ready();await establish(t);t.toggleLibraryLiked();let ti=t.bridge.held.count-1;t.bridge.removeCache(8);t.nextTrack();let tn=t.bridge.held.count-1
  check("transport-failure-actually-after-read-commit",!t.bridge.response(tn).ok && coreRows(t)==[8]);t.bridge.release(tn);await settle(t);t.bridge.release(ti);await settle(t)
  check("transport-failure-no-library-leak",rows(t)==[7,8] && !t.libraryLiked && !available(t) && t.snapshot!.queue.map{$0.track.id}==[7,8])
  // Same-epoch retirement: real rotation storage/ACK, newer read cleanup.
  let c=ready();await establish(c);c.search.stringValue="rotate";c.toggleLibraryLiked();let ci=c.bridge.held.count-1
  check("rotation-committed-on-old-read",c.bridge.response(ci).credentials != nil)
  c.command(["command":"queue_restore"]);await releaseLast(c)
  // Durable rotation on this current sibling dispatches an ACK; settle it before
  // admitting another read, preserving production's ordinary busy admission.
  if c.bridge.value(c.bridge.held.count-1)["command"] as? String=="acknowledge_credentials" {await releaseLast(c)}
  c.search.stringValue="";c.refresh();let newer=c.pendingLibraryRead!,ni=c.bridge.held.count-1
  let beforeDurable=durable.count;c.bridge.release(ci);await settle(c)
  check("retired-read-keeps-newer-owner",c.pendingLibraryRead==newer && !c.search.isEnabled)
  // queue_restore may have delivered the pending pair first. Either way exact
  // real storeCredentials must have durably stored then dispatched an ACK.
  check("current-rotation-durable-owner-and-real-ack",!durable.isEmpty && c.storedCredentialVersion>0 && c.bridge.held.contains{(try! JSONSerialization.jsonObject(with:$0.value) as! [String:Any])["command"] as? String=="acknowledge_credentials"} && durable.count>=beforeDurable)
  // Drain ACKs without clearing the newer pending read.
  for i in 0..<c.bridge.held.count where c.bridge.value(i)["command"] as? String=="acknowledge_credentials" {c.bridge.release(i);await settle(c)}
  check("credential-ack-cannot-clear-newer-read",c.pendingLibraryRead==newer && !c.search.isEnabled)
  c.bridge.release(ni);await settle(c);check("newer-read-safe-admission",c.pendingLibraryRead==nil && rows(c)==[7,8] && coreRows(c)==[7,8] && c.busy==0)
  let a=ready();await establish(a);a.toggleLibraryLiked();let ai=a.bridge.held.count-1;a.epoch=a.bridge.revoke();a.command(["command":"logout"]);await releaseLast(a);a.bridge.release(ai);await settle(a)
  check("account-retirement-no-old-projection",a.snapshot?.authenticated==false && rows(a).isEmpty && !a.libraryLiked && a.pendingLibraryRead==nil && a.busy==0)
  }
  if CommandLine.arguments.contains("compatibility") || CommandLine.arguments.contains("combined") {
   // Exact review witness first: All[7,8], committed Liked[8], real Next,
   // then a real successful Refresh with only its optional revision removed.
   for kind in ["review","liked-all","query","page","known-clean","unknown-retired"] {
    let a=ready(kind=="unknown-retired")
    if kind != "unknown-retired" {await establish(a,kind=="liked-all")}
    else {a.refresh();a.bridge.releaseWithoutRevision(a.bridge.held.count-1);await settle(a)}
    let expected=rows(a),mode=a.libraryLiked,revision=a.libraryRevision,identity=a.acknowledgedLibraryRead,total=a.snapshot!.total
    let tag="compat-"+kind
    check(tag+"-positive-acknowledged-baseline",!a.libraryReadInvalid && rows(a)==(mode ? [8]:[7,8]) && (kind=="unknown-retired" ? revision==nil:revision != nil))
    if kind != "known-clean" {
     if kind=="query" {a.search.stringValue="narrow";a.refresh()}
     else if kind=="page" {a.loadMore()}
     else {a.toggleLibraryLiked()}
     let retired=a.bridge.held.count-1
     let committed:[Int64]=kind=="page" ? [7,8,9]:(mode ? [7,8]:[8])
     check(tag+"-positive-real-core-commit",a.bridge.response(retired).ok && coreRows(a)==committed && rows(a)==expected && a.pendingLibraryRead != nil)
     a.nextTrack();await releaseLast(a);a.bridge.release(retired);await settle(a)
     check(tag+"-positive-retirement",a.libraryReadInvalid && !available(a) && rows(a)==expected && coreRows(a)==committed && a.libraryRevision==revision)
    }
    // The review path Refreshes All; the reverse path explicitly requests All
    // so refusal must retain its acknowledged Liked mode as well as rows.
    if kind=="liked-all" || kind=="known-clean" {a.toggleLibraryLiked()} else {a.refresh()}
    let missing=a.bridge.held.count-1
    check(tag+"-positive-real-successful-read",a.bridge.response(missing).ok && a.bridge.response(missing).snapshot!.library_revision != nil && a.pendingLibraryRead != nil)
    a.bridge.releaseWithoutRevision(missing);await settle(a)
    a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.updateLibraryAvailability()
    check(kind=="review" ? "independent-missing-read-marker-cannot-clear-known-uncertainty":tag+"-missing-marker-refused",a.libraryReadInvalid && !available(a))
    check(tag+"-acknowledged-display-and-identity-preserved",rows(a)==expected && a.snapshot!.total==total && a.libraryLiked==mode && a.libraryLikedControl.selected==mode && a.libraryRevision==revision && a.acknowledgedLibraryRead==identity && a.pendingLibraryRead==nil && a.search.isEnabled && !a.libraryDetails.isEnabled && !a.libraryDock!.controls.more.isEnabled && a.snapshot!.favorite_track_ids==nil)
    let count=a.bridge.held.count,revokes=a.bridge.revokes
    a.selectTrack();a.queueCommand("queue_append",id:UInt64(expected[0]))
    check(kind=="review" ? "independent-missing-read-marker-cannot-authorize-row-actions":tag+"-actual-row-handlers-refused",a.bridge.held.count==count && a.bridge.revokes==revokes)
    print("MISSING_MARKER_OBSERVATION \(kind) invalid=\(a.libraryReadInvalid) acknowledgedRevision=\(String(describing:a.libraryRevision)) newlyDispatched=\((count..<a.bridge.held.count).map{a.bridge.value($0)["command"] as? String ?? ""})")
    for i in count..<a.bridge.held.count {a.bridge.release(i);await settle(a)}
    a.search.stringValue="fail";a.refresh();await releaseLast(a)
    check(tag+"-failed-recovery-preserves-refusal",a.libraryReadInvalid && !available(a) && a.pendingLibraryRead==nil && rows(a)==expected && a.libraryLiked==mode && a.libraryRevision==revision)
    a.search.stringValue="";a.loadMore();let recovery=a.bridge.held.count-1
    check(tag+"-invalid-more-restarts-zero",a.bridge.value(recovery)["offset"] as? Int==0)
    a.bridge.release(recovery);await settle(a)
    a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.updateLibraryAvailability()
    check(tag+"-marker-bearing-recovery",!a.libraryReadInvalid && available(a) && rows(a)==coreRows(a) && a.libraryLiked==mode && a.libraryRevision != nil && a.pendingLibraryRead==nil && a.busy==0)
    a.queueCommand("queue_append",id:UInt64(rows(a)[0]));let appended=a.bridge.held.count-1;await releaseLast(a)
    check(tag+"-recovered-real-append",a.bridge.value(appended)["command"] as? String=="queue_append" && a.bridge.response(appended).ok)
    a.selectTrack();let selected=a.bridge.held.count-1;await releaseLast(a)
    check(tag+"-recovered-real-select",a.bridge.value(selected)["command"] as? String=="select" && a.bridge.response(selected).ok && a.snapshot!.queue.map{$0.track.id}==rows(a))
   }
   // Fresh legacy compatibility is separate: no known marker or uncertainty.
   let legacy=ready(true)
   check("fresh-legacy-no-known-marker",legacy.libraryRevision==nil && !legacy.libraryReadInvalid)
   for kind in ["all","liked","page","all-again","query"] {
    if kind=="liked" || kind=="all-again" {legacy.toggleLibraryLiked()}
    else if kind=="page" {legacy.loadMore()}
    else {legacy.search.stringValue=kind=="query" ? "narrow":"";legacy.refresh()}
    let i=legacy.bridge.held.count-1,liked=kind=="liked" || kind=="page"
    check("fresh-legacy-"+kind+"-real-success",legacy.bridge.response(i).ok && (kind != "page" || legacy.bridge.value(i)["offset"] as? Int==1))
    legacy.bridge.releaseWithoutRevision(i);await settle(legacy)
    legacy.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);legacy.updateLibraryAvailability()
    check("fresh-legacy-"+kind+"-compatible",legacy.libraryRevision==nil && !legacy.libraryReadInvalid && available(legacy) && legacy.libraryLiked==liked && rows(legacy)==coreRows(legacy) && legacy.pendingLibraryRead==nil)
   }
   let oldRows=rows(legacy),oldIdentity=legacy.acknowledgedLibraryRead
   legacy.search.stringValue="fail";legacy.toggleLibraryLiked();legacy.bridge.releaseWithoutRevision(legacy.bridge.held.count-1);await settle(legacy)
   legacy.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);legacy.updateLibraryAvailability()
   // Failure replies also carry a new-core marker, so strip it to model legacy.
   // This failed read itself must not acknowledge the requested mode/identity.
   check("fresh-legacy-failure-preserves-acknowledgement",rows(legacy)==oldRows && !legacy.libraryLiked && legacy.acknowledgedLibraryRead==oldIdentity && legacy.pendingLibraryRead==nil && legacy.libraryRevision==nil && !legacy.libraryReadInvalid && available(legacy))
  }
  print("PROJECTION_RESULT assertions=\(passes.count+failures.count) passes=\(passes.count) failures=\(failures.count) barriers=\(barriers.count)")
  exit(failures.isEmpty ? 0:1)
 }
}
'''


def header(root):
    source = (root/'native/macos/Sources/main.swift').read_text()
    probe, blocks = production_probe(root)
    result = probe[:probe.index('var failures=[String]')]
    methods = ['func command(', 'func command(_ value: [String:Any], completion:',
               'func loadLibrary(', '@objc func refresh()', '@objc func loadMore()',
               'func controlTextDidEndEditing(', '@objc func selectTrack()', '@objc func toggle()',
               'func queueCommand(', '@objc func nextTrack()', '@objc func previousTrack()',
               'func readLibrary(', '@objc func toggleLibraryLiked()', 'func finishLibraryRead(',
               'func retireLibraryRead(', 'func updateLibraryReadPresentation()']
    for name in ['refresh', 'loadMore', 'selectTrack', 'toggle', 'nextTrack', 'previousTrack']:
        result = result.replace('@objc func '+name+'(){};', '')
    for sig in methods:
        if sig in blocks:
            result = result.replace(blocks[sig], '')
    recorder = 'var commands=[[String:Any]]();@discardableResult func command(_ value:[String:Any],result:((Reply)->Void)? = nil,completion:(()->Void)? = nil)->Bool {commands.append(value);return false}'
    assert recorder in result
    actual = '\n'.join(('@discardableResult\n' if s.startswith('func command(') else '') + swift_block(source, s) for s in methods)
    result = result.replace(recorder, actual).replace(' var busy=0\n', '')
    result = result.replace(' var window:NSWindow!;', '\n var bridge=Bridge();var busy=0;var storedCredentialVersion:UInt64=0;var wantsPlayback=false;var player:AVPlayer?;var observation:NSKeyValueObservation?;var reportPending=false\n var effects=[AudioEffect]();func applyAudio(_ effect:AudioEffect){effects.append(effect)}\n'+swift_block(source, 'func storeCredentials(')+'\n func keychainQuery()->[String:Any]{[:]}\n func deleteCredentials(){}\n var window:NSWindow!;')
    blocks.update({s: swift_block(source,s) for s in methods+["func storeCredentials("]})
    return result, blocks


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-root', type=Path, default=ROOT)
    p.add_argument('--core-library', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--suite', choices=['canonical', 'compatibility', 'combined'], default='combined')
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    root = args.source_root
    extracted, blocks = header(root)
    generated = 'import AVFoundation\nimport CryptoKit\nimport SoundQCore\n'+BRIDGE+'\n'+extracted+'\n'+CASES
    src = args.output/'main.swift'
    src.write_text(generated)
    dependencies = [root/'native/macos/Sources'/f for f in FILES+['LibraryMetadataDisclosure.swift', 'LibraryFavoriteMenu.swift']]
    lib = args.core_library.resolve()
    argv = ['/usr/bin/swiftc', '-swift-version', '6', '-parse-as-library', '-j', '2', '-num-threads', '2', '-I', str(root/'native/core/include'), *map(str, dependencies), str(src), str(lib), '-Xlinker', '-rpath', '-Xlinker', str(lib.parent), '-o', str(args.output/'probe')]
    built = subprocess.run(argv, capture_output=True, timeout=180)
    (args.output/'compiler.log').write_bytes(built.stdout+built.stderr)
    seen, errors = [], []
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0))
    listener.listen()
    listener.settimeout(0.2)
    stop = threading.Event()
    rotated = set()

    def server():
        unlike_committed = False
        try:
            while not stop.is_set():
                try:
                    conn, _ = listener.accept()
                except socket.timeout:
                    continue
                with conn:
                    conn.settimeout(3)
                    raw = b''
                    while b'\r\n\r\n' not in raw:
                        part = conn.recv(8192)
                        assert part
                        raw += part
                    verb, path, _ = raw.split(b'\r\n', 1)[0].decode().split(' ')
                    u = urllib.parse.urlparse(path)
                    q = urllib.parse.parse_qs(u.query, keep_blank_values=True)
                    status = '200 OK'
                    if u.path == '/api/v1/auth/refresh':
                        # Synthetic test credential placeholder, never a live secret.
                        body = dict(accessToken='projection-synthetic-access', refreshToken='projection-synthetic-refresh', user=dict(id='projection-synthetic-account'))  # placeholder
                        unlike_committed = False
                    elif u.path == '/api/v1/auth/logout':
                        body = {}
                    elif u.path.startswith('/api/v1/library/tracks/') and u.path.endswith('/like'):
                        status = '201 Created' if verb == 'POST' else '204 No Content'
                        body = dict(track_id=int(u.path.split('/')[-2]), liked=True) if verb == 'POST' else None
                        if verb == 'DELETE':
                            assert u.path == '/api/v1/library/tracks/8/like'
                            unlike_committed = True
                    elif u.path == '/api/v1/library':
                        assert verb == 'GET' and q['limit'] == ['50'] and q['sort'] == ['added_at'] and q['order'] == ['desc']
                        query, offset = q['q'][0], int(q['offset'][0])
                        if query == 'fail':
                            status, body = '503 Service Unavailable', {}
                        elif query == 'rotate' and query not in rotated:
                            rotated.add(query)
                            status, body = '401 Unauthorized', {}
                        else:
                            ids = [8] if q.get('liked') == ['true'] or query in ['narrow', 'rotate'] else [7, 8]
                            # A second page is genuine append, not an old first-page fixture.
                            if unlike_committed:
                                liked = q.get('liked') == ['true']
                                page = ([9] if offset == 0 else [10]) if liked else ([7, 8] if offset == 0 else [9, 10])
                                total = 2 if liked else 4
                            else:
                                page, total = (ids if offset == 0 else [9]), len(ids)+1
                            body = dict(tracks=[dict(id=i, title=f'Track {i}', duration_ms=30000, is_liked=i in ([9, 10] if unlike_committed else [8, 9, 10])) for i in page], total=total, offset=offset)
                    else:
                        assert u.path == '/api/v1/playback/urls', u.path
                        status, body = '503 Service Unavailable', {}
                    seen.append(dict(verb=verb, path=u.path, query=q, status=status))
                    data = b'' if body is None else json.dumps(body).encode()
                    conn.sendall(b'HTTP/1.1 '+status.encode()+b'\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: '+str(len(data)).encode()+b'\r\n\r\n'+data)
        except Exception as exc:
            errors.append(type(exc).__name__+': '+str(exc))
        finally:
            listener.close()

    endpoint = 'http://127.0.0.1:%d/api/v1' % listener.getsockname()[1]
    thread = threading.Thread(target=server)
    thread.start()
    try:
        ran = subprocess.run([str(args.output/'probe'), str(root/'native/macos/Sources/Resources'), endpoint, str(args.output), args.suite], capture_output=True, timeout=60) if built.returncode == 0 else None
    finally:
        stop.set()
        thread.join(timeout=5)
    (args.output/'runtime.log').write_bytes(ran.stdout+ran.stderr if ran else b'NOT RUN')
    lines = ran.stdout.decode().splitlines() if ran else []
    # Join command counts with actual exchanges: three ordinary unlike cases
    # have no HTTP for refused append, replay or credential refresh.
    favorite_exchanges = []
    if args.suite != 'compatibility' and ran is not None and built.returncode == 0:
        starts = [i for i, r in enumerate(seen) if r['path'] == '/api/v1/auth/refresh']
        for case, query in enumerate(['', 'Ω & valid', 'Ω' * 256]):
            group = seen[starts[case]:starts[case+1]] if len(starts) > case+1 else []
            expected = [('POST', '/api/v1/auth/refresh', None, None),
                        ('GET', '/api/v1/library', '0', False), ('GET', '/api/v1/library', '0', False),
                        ('GET', '/api/v1/library', '0', True), ('DELETE', '/api/v1/library/tracks/8/like', None, None),
                        ('GET', '/api/v1/library', '0', True), ('GET', '/api/v1/library', '1', True)]
            # Require true only for intended Liked reads, including establishment
            # and both recovery pages; ordinary All may omit liked or send false.
            actual = [(r['verb'], r['path'], r['query'].get('offset', [None])[0],
                       True if r['query'].get('liked') == ['true'] else
                       False if r['query'].get('liked') in (None, ['false']) else 'invalid')
                      if r['verb'] == 'GET' else (r['verb'], r['path'], r['query'].get('offset', [None])[0], None) for r in group]
            valid = actual == expected and all(r['query']['q'] == [query] for r in group[2:] if r['verb'] == 'GET')
            favorite_exchanges.append(dict(queryUTF8Bytes=len(query.encode()), exactExchanges=valid, requests=group))
    favorite_exchanges_ok = all(c['exactExchanges'] for c in favorite_exchanges)
    compatibility = []
    for original in sorted(args.output.glob('case-*/compat-*-original.json')):
        delivered = original.with_name(original.name.replace('-original.json', '-legacy.json'))
        expected = json.loads(original.read_bytes())
        revision = expected['snapshot'].pop('library_revision')
        compatibility.append(dict(original=str(original.relative_to(args.output)), delivered=str(delivered.relative_to(args.output)), originalSha256=hashlib.sha256(original.read_bytes()).hexdigest(), deliveredSha256=hashlib.sha256(delivered.read_bytes()).hexdigest(), removedRevision=revision, onlySemanticDifference=json.loads(delivered.read_bytes()) == expected, byteTransformation='JSONSerialization sortedKeys reencoding; remove only snapshot.library_revision'))
    compatibility_ok = all(c['onlySemanticDifference'] for c in compatibility)
    receipt = dict(suite=args.suite, favoriteExchanges=favorite_exchanges, favoriteExchangesVerified=favorite_exchanges_ok, compatibility=compatibility, compatibilityVerified=compatibility_ok, compileExit=built.returncode, runExit=ran.returncode if ran else None, compileArgv=argv, testSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), probeSha256=hashlib.sha256(generated.encode()).hexdigest(), coreSha256=hashlib.sha256(lib.read_bytes()).hexdigest(), TMPDIR=os.environ.get('TMPDIR'), productionBlocks={k: hashlib.sha256(v.encode()).hexdigest() for k, v in blocks.items()}, compilerInputs={str(v): hashlib.sha256(v.read_bytes()).hexdigest() for v in dependencies+[src]}, passes=[l[5:] for l in lines if l.startswith('PASS ')], failures=[l[5:] for l in lines if l.startswith('FAIL ')], terminal=[l for l in lines if l.startswith('PROJECTION_RESULT')], abiInputs={str(p.relative_to(args.output)): hashlib.sha256(p.read_bytes()).hexdigest() for p in args.output.glob("case-*/native-*.json")}, requests=seen, serverErrors=errors, threadDrained=not thread.is_alive(), scope='real ABI1 producer + exact native methods; held worker delivery; no decoder/OS storage/GUI')
    (args.output/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print((args.output/'compiler.log').read_text())
    print((args.output/'runtime.log').read_text())
    return built.returncode or (ran.returncode if ran else 1) or int(bool(errors) or thread.is_alive() or not compatibility_ok or not favorite_exchanges_ok)


if __name__ == '__main__':
    raise SystemExit(main())
