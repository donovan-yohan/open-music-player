#!/usr/bin/env python3
"""Device-free queue wording checks through both production disclosure renderers.

Android compiles retained production disclosure with a shell boundary facade,
reusing every queue-dialog control. The SDK build compiles the whole Activity.
Swift compiles the exact extracted showQueue, dynamic native validation,
occurrence action/detail/publication, queueCommand and command methods, plus
selection/account revocation entries with native/bridge facades and production
Decodable types. Automatic validation and raw retained dispatch are separate
checks. Neither facade proves native paint, accessibility, keyboard or devices.
Requires installed kotlinc/JDK and macOS swiftc; no dependency downloads/builds.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

import queue_dialog_regressions as dialog
from native_review_regressions import swift_block
from test_toolchain import java_home, kotlin_compiler

ROOT = Path(__file__).resolve().parents[2]
SWIFT = 'native/macos/Sources/main.swift'

ANDROID_CASES = r'''
 for(transport in listOf("preparing","paused","playing","ended")) {
  for(owner in listOf<Long?>(11L,12L,13L,99L,null)) test("ownership-$transport-${owner ?: "none"}") {
   val f=Fixture(11,12,13)
   f.service.snapshot.put("transport",transport).put("selected_occurrence",owner)
   f.service.listener!!.invoke(f.service.snapshot,null)
   val q=f.queueDialog()
   val labels=q.listView.children.map {(it as TextView).text.toString()}
   val expected=listOf(11L,12L,13L).map {if(it==owner) "Current · Same recording" else "Same recording"}
   requireThat(labels==expected,"$transport owner=$owner expected=$expected actual=$labels")
   requireThat(q.heading=="Listening queue · 3","queue heading changed")
   requireThat(f.service.snapshot.optString("transport")==transport,"disclosure changed canonical transport")
   // Browse an occurrence of the same recording which does not own playback.
   val browse=if(owner==12L) 2 else 1
   q.choose(browse)
   val actions=AlertDialog.shown.last()
   requireThat(actions.heading=="Same recording","browsed noncurrent occurrence acquired current marker")
   actions.choose(0);f.sent("queue_play",listOf(11L,12L,13L)[browse])
   requireThat(f.service.snapshot.optLong("selected_occurrence")== (owner ?: 0L),"browsing changed canonical occurrence")
   f.activity.onDestroy()
  }
 }
 test("ownership-empty-queue") {
  val f=Fixture();val q=f.queueDialog()
  requireThat(q.listView.children.isEmpty(),"empty queue acquired a current row")
  q.clear();f.sent("queue_clear");f.activity.onDestroy()
 }
'''

SWIFT_FACADES = r'''import Foundation
import CoreFoundation
import CoreGraphics
enum NSLineBreakMode {case byWordWrapping,byCharWrapping}
enum NSEvent {struct ModifierFlags:OptionSet {let rawValue:Int;static let command=Self(rawValue:1)}}
@objc protocol NSMenuItemValidation {
 func validateMenuItem(_ menuItem:NSMenuItem)->Bool
}
class NSMenuItem: NSObject {
 let title:String; let action:Selector?; var target:AnyObject?
 var representedObject:Any?; var submenu:NSMenu?; var isEnabled=true; weak var menu:NSMenu?
 var keyEquivalent:String;var keyEquivalentModifierMask:NSEvent.ModifierFlags = [.command]
 init(title:String,action:Selector?,keyEquivalent:String) {self.title=title;self.action=action;self.keyEquivalent=keyEquivalent}
 static func separator()->NSMenuItem {NSMenuItem(title:"separator",action:nil,keyEquivalent:"")}
}
class NSMenu {
 static var shown:NSMenu?;let title:String;var items=[NSMenuItem]();var autoenablesItems=true;var font:NSFont?
 init(title:String="") {self.title=title}
 func addItem(_ item:NSMenuItem) {item.menu=self;items.append(item)}
 // Model only AppKit's documented automatic target validation, not queue policy.
 func update() {
  guard autoenablesItems else {return}
  for item in items {
   let target=item.target as? NSObject
   item.isEnabled=item.action.map {target?.responds(to:$0)==true} ?? false
   if item.isEnabled,let validator=target as? NSMenuItemValidation {
    item.isEnabled=validator.validateMenuItem(item)
   }
  }
 }
 func popUp(positioning:NSMenuItem?,at:NSPoint,in:Any?) {update();Self.shown=self}
}
// Native API configuration/ownership only: no layout engine, pixel or focus claims.
class NSFont {let pointSize:CGFloat;init(_ size:CGFloat) {pointSize=size};static func menuFont(ofSize:CGFloat)->NSFont {NSFont(ofSize)}}
// Installed AppKit contract: one shared button/cell equivalent. Assigning a
// window default cell overwrites Escape with Return; assigning Escape afterwards
// clears that default association. This records configuration, not key dispatch.
class NSButtonCell {
 weak var window:Window?
 var keyEquivalent:String {
  didSet {if keyEquivalent != "\r",window?.defaultButtonCell === self {window?.defaultButtonCell=nil}}
 }
 init(_ key:String) {keyEquivalent=key}
}
class NSButton {
 let title:String;let nativeCell:NSButtonCell;var cell:Any? {nativeCell}
 var keyEquivalent:String {get {nativeCell.keyEquivalent} set {nativeCell.keyEquivalent=newValue}}
 init(_ title:String,_ key:String) {self.title=title;nativeCell=NSButtonCell(key)}
}
class NSTextContainer {var size=NSSize.zero;var widthTracksTextView=false;var lineBreakMode=NSLineBreakMode.byWordWrapping}
class NSTextView:NSObject {
 var string="";var isEditable=true;var isSelectable=false;var isRichText=true;var font:NSFont?
 var isHorizontallyResizable=true;var isVerticallyResizable=false
 struct AutoresizingMask:OptionSet {let rawValue:Int;static let width=Self(rawValue:1)}
 var autoresizingMask=AutoresizingMask();var minSize=NSSize.zero;var maxSize=NSSize.zero
 var textContainer:NSTextContainer?=NSTextContainer()
 static func scrollableTextView()->NSScrollView {let scroll=NSScrollView();scroll.documentView=NSTextView();return scroll}
 func setAccessibilityLabel(_ value:String) {}
}
class NSScrollView:NSObject {
 var frame=NSRect.zero;var hasVerticalScroller=false;var hasHorizontalScroller=true;var autohidesScrollers=false
 var documentView:AnyObject?;var contentSize:NSSize {frame.size}
 func setAccessibilityLabel(_ value:String) {}
}
class Screen {var visibleFrame=NSRect(x:0,y:0,width:1440,height:900)}
class Window:NSObject {
 var contentView:Any?;var contentLayoutRect=NSRect(x:0,y:0,width:900,height:700)
 var frame=NSRect(x:0,y:0,width:900,height:728);var screen:Screen?=Screen()
 var initialFirstResponder:AnyObject?;var attachedSheet:Window?
 var defaultButtonCell:NSButtonCell? {
  didSet {
   if oldValue !== defaultButtonCell {oldValue?.window=nil}
   defaultButtonCell?.window=self;defaultButtonCell?.keyEquivalent="\r"
  }
 }
 func endSheet(_ sheet:Window) {if attachedSheet === sheet {attachedSheet=nil};sheet.alert?.pendingCompletion=true}
 weak var alert:NSAlert?
}
class NSAlert:NSObject {
 static var shown=[NSAlert]();var messageText="";var informativeText="";var accessoryView:NSScrollView?
 let window=Window();var buttons=[NSButton]();var completion:((Int)->Void)?;var pendingCompletion=false
 override init() {super.init();window.alert=self}
 @discardableResult func addButton(withTitle title:String)->NSButton {
  let b=NSButton(title,title=="Cancel" ? "\u{1b}" : buttons.isEmpty ? "\r" : "")
  b.nativeCell.window=window;buttons.append(b);return b
 }
 func beginSheetModal(for parent:Window,completionHandler:((Int)->Void)?) {parent.attachedSheet=window;completion=completionHandler;Self.shown.append(self)}
 func finish(_ parent:Window) {parent.endSheet(window)}
 func drainCompletion() {if pendingCompletion {pendingCompletion=false;completion?(1000)}}
}
class Label {var stringValue="";var isHidden=false;var isEnabled=true;var title="";func setAccessibilityLabel(_ value:String){}}
class Table {var selectedRow=0;func reloadData() {};func selectRowIndexes(_ indexes:IndexSet,byExtendingSelection:Bool){selectedRow=indexes.first ?? -1}}
// Rendering is tested by the real unattached AppKit gate. These optional nil
// presentation references let the unchanged command/disclosure facades compose
// the complete production apply, including the real DockChrome projection.
class LibraryDockView {func updateAuthentication(_ authenticated:Bool){};func updateContent(empty:Bool){};func updateChrome(_ value:DockChrome){};func updateCurrent(old:Int64?,new:Int64?){};func updateProgress(position:UInt64,duration:UInt64){};func setPlaybackRetryAvailable(_ available:Bool){}}
class Slider {var maxValue=0.0;var doubleValue=0.0;var isEnabled=true}
// Record only native/core boundary effects. Production owns all admission,
// selection, account, epoch and disclosure predicates; replies stay held.
class Player {
 var events=[String]();var onEffect:(()->Void)?
 func pause() {onEffect?();events.append("pause")}
 func replaceCurrentItem(with item:Any?) {onEffect?();events.append("replace")}
}
final class Bridge:@unchecked Sendable {
 var sent=[(String,UInt64?,Int?)]();var requests=[[String:Any]]();var epochs=[UInt64]()
 var completions=[@Sendable (Data)->Void]();var generation:UInt64=1;var revocations=0
 var onRevoke:(()->Void)?;var onSend:(()->Void)?
 func revoke()->UInt64 {onRevoke?();revocations+=1;generation+=1;return generation}
 func send(_ data:Data,epoch:UInt64,completion:@escaping @Sendable (Data)->Void) {
  onSend?()
  let value=try! JSONSerialization.jsonObject(with:data) as! [String:Any]
  sent.append((value["command"] as! String,(value["occurrence_id"] as? NSNumber)?.uint64Value,
               (value["to_index"] as? NSNumber)?.intValue))
  requests.append(value);epochs.append(epoch);completions.append(completion)
 }
}
__TYPES__
class App:NSObject__VALIDATION__ {
 var window=Window();var snapshot:Snapshot?;var epoch:UInt64=1;var bridge=Bridge()
 var sent:[(String,UInt64?,Int?)] {get {bridge.sent} set {bridge.sent=newValue}}
 var busy=0;var accountScope:UInt64=1;var storedCredentialVersion:UInt64=0
 var wantsPlayback=false;var reportPending=false;var player:Player?;var observation:Any?
 var email=Label();var password=Label();var credentialDeletes=0;var libraryLoads=0
 var loginArea=Label();var libraryArea=Label();var logout=Label();var table=Table()
 var titleLabel=Label();var transportLabel=Label();var play=Label();var slider=Slider();var status=Label()
 var libraryDock:LibraryDockView?;var dockTrackID:Int64?
 func updateLibraryAvailability(){};func retireLibraryDetails(){};func libraryDetailsMenuAvailable(_ item:NSMenuItem)->Bool {false};@objc func openLibraryDetailsFromMenu(_ item:NSMenuItem){};func closeLibraryDetails(){};func reconcileLibraryDetails(_ s:Snapshot){}
__DETAIL_FIELDS__
 func retireLinkImport(){};func drainImportLibraryRefresh(){}
 func deleteCredentials() {credentialDeletes+=1}
 func storeCredentials(_ credentials:Credentials,epoch:UInt64) {}
 func applyAudio(_ effect:AudioEffect) {}
 func loadLibrary() {libraryLoads+=1}
__METHODS__
}
var failures=0
func test(_ name:String,_ body:() throws ->Void) {
 do {try body();print("PASS \(name)")} catch {failures+=1;print("FAIL \(name): \(error)")}
}
struct Mismatch:Error,CustomStringConvertible {let description:String}
func requireThat(_ value:Bool,_ message:String) throws {if !value {throw Mismatch(description:message)}}
func snapshot(_ transport:String,_ owner:UInt64?,empty:Bool=false) throws ->Snapshot {
 let track:[String:Any] = ["id":7,"title":"Same recording"]
 let queue:[[String:Any]] = empty ? [] : [11,12,13].map {["id":$0,"track":track]}
 let value:[String:Any] = ["epoch":1,"session":1,"revision":1,"authenticated":true,
  "library":[track],"library_unchanged":false,"total":1,"queue":queue,"queue_unchanged":false,
  "selected_occurrence":owner.map {NSNumber(value:$0) as Any} ?? NSNull(),
  "transport":transport,"position_ms":0,"duration_ms":30000]
 return try JSONDecoder().decode(Snapshot.self,from:JSONSerialization.data(withJSONObject:value))
}
for transport in ["preparing","paused","playing","ended"] {
 for owner:UInt64? in [11,12,13,99,nil] {
  test("ownership-\(transport)-\(owner.map {String($0)} ?? "none")") {
   let f=App();f.snapshot=try snapshot(transport,owner);f.showQueue()
   let menu=NSMenu.shown!;let rows=Array(menu.items.prefix(3))
   let expected:[String] = [UInt64(11),12,13].map {$0==owner ? "Current · Same recording" : "Same recording"}
   try requireThat(rows.map {$0.title}==expected,"\(transport) owner=\(String(describing:owner)) expected=\(expected) actual=\(rows.map {$0.title})")
   try requireThat(menu.title=="Listening queue" && menu.items.count==5 && menu.items.last!.title=="Clear queue","queue structure changed")
   try requireThat(f.snapshot!.transport==transport && f.snapshot!.selected_occurrence==owner,"disclosure mutated canonical snapshot")
   for (index,row) in rows.enumerated() {
    let id=UInt64(index+11)
    try requireThat((row.representedObject as? NSNumber)?.uint64Value==id && row.target === f,"row lost occurrence identity")
    let actions=row.submenu!.items
    try requireThat(Array(actions.prefix(4)).map {$0.title}==["Play","Move up","Move down","Remove"],"action labels changed")
    try requireThat(actions.allSatisfy {($0.representedObject as? NSNumber)?.uint64Value==id && $0.target === f},"submenu lost occurrence identity")
   }
   let browse=owner==12 ? 2 : 1
   try requireThat(rows[browse].title=="Same recording","browsed noncurrent occurrence acquired marker")
   f.playOccurrence(rows[browse].submenu!.items[0])
   try requireThat(f.sent.count==1 && f.sent[0].0=="queue_play" && f.sent[0].1==UInt64(browse+11),"browsed duplicate recording dispatched wrong occurrence")
  }
 }
}
test("ownership-empty-queue") {
 let f=App();f.snapshot=try snapshot("paused",nil,empty:true);f.showQueue()
 try requireThat(NSMenu.shown!.items.map {$0.title}==["separator","Clear queue"],"empty queue acquired marker")
}
func orderedSnapshot(_ ids:[UInt64],owner:UInt64?=12) throws ->Snapshot {
 var s=try snapshot("paused",owner)
 let track=s.queue[0].track
 s.queue=ids.map {Occurrence(id:$0,track:track)}
 return s
}
func open(_ ids:[UInt64]) throws ->(App,NSMenu) {
 let f=App();f.snapshot=try orderedSnapshot(ids);f.showQueue();return (f,NSMenu.shown!)
}
func raw(_ f:App,_ item:NSMenuItem) {
 // Deliberately bypass disabled-item suppression and dispatch the retained selector.
 _=f.perform(item.action!,with:item)
}
func expectSent(_ f:App,_ kind:String,_ id:UInt64?,_ index:Int?=nil) throws {
 try requireThat(f.sent.count==1 && f.sent[0].0==kind && f.sent[0].1==id && f.sent[0].2==index,
                 "wrong dispatch: \(f.sent)")
 f.sent.removeAll()
}
for (name,ids,expected) in [
 ("first-interior-last",[UInt64(11),12,13],[[true,false,true,true],[true,true,true,true],[true,true,false,true]]),
 ("single",[UInt64(11)],[[true,false,false,true]]),
 ("empty",[UInt64](),[[Bool]]())] {
 test("native-validation-\(name)") {
  let (f,menu)=try open(ids)
  for (index,row) in menu.items.prefix(ids.count).enumerated() {
   let actions=row.submenu!;actions.update()
   try requireThat(actions.autoenablesItems,"native automatic validation was disabled")
   try requireThat(Array(actions.items.prefix(4)).map {$0.isEnabled}==expected[index],
                   "\(name) row=\(index) expected=\(expected[index]) actual=\(actions.items.map {$0.isEnabled})")
  }
  menu.update()
  try requireThat(menu.items.last!.isEnabled == !ids.isEmpty,"Clear availability disagrees with live queue")
  try requireThat(f.sent.isEmpty,"validation dispatched a command")
 }
}
for (name,ids,row,action,kind,index) in [
 ("first-play",[UInt64(11),12,13],0,0,"queue_play",Int?.none),
 ("last-remove",[UInt64(11),12,13],2,3,"queue_remove",Int?.none),
 ("interior-up",[UInt64(11),12,13],1,1,"queue_move",Int?(0)),
 ("interior-down",[UInt64(11),12,13],1,2,"queue_move",Int?(2)),
 ("single-play",[UInt64(11)],0,0,"queue_play",Int?.none),
 ("single-remove",[UInt64(11)],0,3,"queue_remove",Int?.none)] {
 test("native-positive-\(name)") {
  let (f,menu)=try open(ids);let item=menu.items[row].submenu!.items[action]
  menu.items[row].submenu!.update();try requireThat(item.isEnabled,"valid action disabled")
  raw(f,item);try expectSent(f,kind,ids[row],index)
 }
}
test("native-retained-reorder-live-boundary-and-index") {
 let (f,menu)=try open([11,12,13]);let retained=menu.items[1];let actions=retained.submenu!
 actions.update();try requireThat(actions.items.allSatisfy {$0.isEnabled},"interior controls missing")
 f.snapshot=try orderedSnapshot([12,13,11]);actions.update()
 try requireThat(Array(actions.items.prefix(4)).map {$0.isEnabled}==[true,false,true,true],"retained first boundary stale")
 raw(f,actions.items[1]);try requireThat(f.sent.isEmpty,"raw first-up dispatched")
 raw(f,actions.items[2]);try expectSent(f,"queue_move",12,1)
 f.snapshot=try orderedSnapshot([11,13,12]);actions.update()
 try requireThat(Array(actions.items.prefix(4)).map {$0.isEnabled}==[true,true,false,true],"retained last boundary stale")
 raw(f,actions.items[2]);try requireThat(f.sent.isEmpty,"raw last-down dispatched")
 raw(f,actions.items[1]);try expectSent(f,"queue_move",12,1)
 raw(f,actions.items[0]);try expectSent(f,"queue_play",12)
 raw(f,actions.items[3]);try expectSent(f,"queue_remove",12)
 try requireThat((retained.representedObject as? NSNumber)?.uint64Value==12 && retained.target === f,
                 "reorder transferred occurrence/action ownership")
 try requireThat(f.snapshot!.selected_occurrence==12 && f.snapshot!.transport=="paused","menu changed playback truth")
}
for (name,ids) in [("removed-with-same-recording",[UInt64(11),13]),("empty",[UInt64]())] {
 test("native-retained-\(name)") {
  let (f,menu)=try open([11,12,13]);let row=menu.items[1];let actions=row.submenu!
  f.snapshot=try orderedSnapshot(ids);actions.update();menu.update()
  try requireThat(actions.items.allSatisfy {!$0.isEnabled},"removed occurrence retained enabled operation")
  for item in actions.items {raw(f,item)}
  raw(f,row)
  try requireThat(f.sent.isEmpty,"removed occurrence raw callback dispatched against a duplicate recording")
 }
}
for (name,ids) in [("removed-with-same-recording",[UInt64(11),13]),("empty",[UInt64]())] {
 test("native-raw-retained-\(name)-without-validation") {
  let (f,menu)=try open([11,12,13]);let row=menu.items[1]
  f.snapshot=try orderedSnapshot(ids)
  // No update/disabled-state assertion may mask the raw consumer guard.
  for item in row.submenu!.items {raw(f,item)}
  raw(f,row)
  try requireThat(f.sent.isEmpty,"removed occurrence raw callback reached queueCommand: \(f.sent)")
 }
}
test("native-raw-clear-empty-without-validation") {
 let (f,menu)=try open([11]);f.snapshot=try orderedSnapshot([])
 raw(f,menu.items.last!)
 try requireThat(f.sent.isEmpty,"raw empty Clear reached queueCommand")
}
test("native-raw-boundaries-and-single") {
 let (f,menu)=try open([11,12,13])
 raw(f,menu.items[0].submenu!.items[1]);raw(f,menu.items[2].submenu!.items[2])
 try requireThat(f.sent.isEmpty,"raw unavailable edge move dispatched")
 f.snapshot=try orderedSnapshot([12]);let retained=menu.items[1].submenu!;retained.update()
 try requireThat(Array(retained.items.prefix(4)).map {$0.isEnabled}==[true,false,false,true],"live single boundary stale")
 raw(f,retained.items[1]);raw(f,retained.items[2]);try requireThat(f.sent.isEmpty,"raw single move dispatched")
}
test("native-live-missing-snapshot-and-malformed-identity") {
 let (f,menu)=try open([11,12,13]);let actions=menu.items[1].submenu!
 for item in actions.items {item.representedObject=nil}
 actions.update();try requireThat(actions.items.allSatisfy {!$0.isEnabled},"missing identity enabled")
 for item in actions.items {raw(f,item)}
 f.snapshot=nil;actions.update();menu.update();raw(f,menu.items.last!)
 try requireThat(!menu.items.last!.isEnabled && f.sent.isEmpty,"missing snapshot permitted clear or occurrence callback")
}
test("native-clear-live-empty-and-positive") {
 let (f,menu)=try open([11,12,13]);let clear=menu.items.last!
 menu.update();try requireThat(clear.isEnabled,"valid Clear disabled");raw(f,clear);try expectSent(f,"queue_clear",nil)
 f.snapshot=try orderedSnapshot([]);menu.update();try requireThat(!clear.isEnabled,"empty Clear enabled")
 raw(f,clear);try requireThat(f.sent.isEmpty,"retained empty Clear dispatched")
 f.snapshot=try orderedSnapshot([13]);menu.update();try requireThat(clear.isEnabled,"Clear did not re-enable")
 raw(f,clear);try expectSent(f,"queue_clear",nil)
}
test("full-name-explicit-native-route") {
 let (f,menu)=try open([11,12,13])
 let route=menu.items[1].submenu!.items.filter {$0.title=="Full name"}
 try requireThat(route.count==1 && route[0].action != nil,"queue occurrence has no explicit Full name route")
 try requireThat(f.sent.isEmpty,"reading menu sent a command")
}
__DETAIL_CASES__
exit(failures==0 ? 0 : 1)
'''


SWIFT_DETAIL_CASES = r'''
test("facade-default-cell-setter-overwrites-shared-Escape") {
 let alert=NSAlert();let done=alert.addButton(withTitle:"Done");let cell=done.cell as! NSButtonCell
 try requireThat(done.keyEquivalent=="\r" && cell.keyEquivalent=="\r","first native alert button must begin with Return")
 done.keyEquivalent="\u{1b}";let window=alert.window
 try requireThat(cell === done.cell as? NSButtonCell && cell.keyEquivalent=="\u{1b}" && window.defaultButtonCell==nil,"window getter changed Escape or fabricated default association")
 window.defaultButtonCell=cell
 try requireThat(done.keyEquivalent=="\r" && cell.keyEquivalent=="\r" && window.defaultButtonCell === cell,"explicit default setter did not overwrite the same button/cell")
}
test("facade-Escape-after-default-clears-association-without-extra-cancel") {
 let alert=NSAlert();let done=alert.addButton(withTitle:"Done");let cell=done.cell as! NSButtonCell
 alert.window.defaultButtonCell=cell;done.keyEquivalent="\u{1b}"
 try requireThat(alert.buttons.count==1 && done.keyEquivalent=="\u{1b}" && cell.keyEquivalent=="\u{1b}" && alert.window.defaultButtonCell==nil,"Escape must clear default, not promise one-button dual equivalents")
}
test("full-name-cancel-completion-retires-only-disclosure-owner") {
 let (f,menu)=try open([11,12,13]);let before=try JSONEncoder().encode(f.snapshot!.queue.map{String($0.id)})
 raw(f,try nameItem(menu));let alert=f.queueNameAlert!.alert
 let epoch=f.epoch;let account=f.accountScope;let busy=f.busy;let player=Player();f.player=player
 // Simulate only the existing NSAlert completion boundary, not native key input.
 alert.finish(f.window)
 try requireThat(alert.pendingCompletion && f.window.attachedSheet==nil && f.queueNameAlert?.alert === alert,"facade must hold posted completion separately from detachment")
 alert.drainCompletion()
 try requireThat(f.queueNameAlert==nil && f.sent.isEmpty && f.bridge.revocations==0 && f.epoch==epoch && f.accountScope==account && f.busy==busy && player.events.isEmpty && f.player === player,"cancel completion changed command/account/decoder ownership")
 try requireThat(try JSONEncoder().encode(f.snapshot!.queue.map{String($0.id)})==before,"cancel completion changed queue order")
 try requireThat(f.snapshot!.selected_occurrence==12 && f.snapshot!.transport=="paused","cancel completion changed playback truth")
}
for busy in [0,32] {
 test("full-name-selected-remove-retires-before-revoke-busy-\(busy)") {
  let (f,menu)=try open([11,12,13]);let row=menu.items[1];let item=try nameItem(menu)
  raw(f,item);let old=f.queueNameAlert!.alert;f.busy=busy
  let player=Player();f.player=player;f.observation=NSObject()
  var effectsRetired=[Bool]();var revokeRetired=[Bool]();var sendRetired=[Bool]()
  player.onEffect={effectsRetired.append(f.queueNameAlert==nil)}
  f.bridge.onRevoke={revokeRetired.append(f.queueNameAlert==nil && old.pendingCompletion)}
  f.bridge.onSend={sendRetired.append(f.queueNameAlert==nil && old.pendingCompletion)}
  // Retain Remove from the real menu and bypass native disabled dispatch.
  raw(f,row.submenu!.items[3])
  try requireThat(revokeRetired==[true] && effectsRetired==[true,true],"selected Remove exposed old owner at decoder/revoke boundary")
  try requireThat(f.queueNameAlert==nil && old.pendingCompletion && f.epoch==2 && f.bridge.revocations==1 && f.player==nil && f.observation==nil,"selected Remove did not retire disclosure and decoder synchronously")
  if busy==32 {
   try requireThat(f.sent.isEmpty && f.bridge.completions.isEmpty && f.busy==32 && f.status.stringValue=="Playback is busy. Try again.","busy Remove was admitted or lost refusal")
  } else {
   try requireThat(sendRetired==[true] && f.bridge.completions.count==1 && f.busy==1 && f.bridge.epochs==[2],"ordinary Remove did not retire before held bridge admission")
   try requireThat((f.bridge.requests[0]["account_scope_v1"] as? NSNumber)?.uint64Value==1,"production command lost account scope")
   try expectSent(f,"queue_remove",12)
  }
  raw(f,item);old.drainCompletion()
  try requireThat(f.queueNameAlert==nil,"retained name route revived revoked owner")
 }
}
for kind in ["queue_play","next","previous","queue_clear","sign-in","sign-out","select"] {
 test("full-name-owner-boundary-before-revoke-\(kind)") {
  let (f,menu)=try open([11,12,13]);raw(f,try nameItem(menu));let old=f.queueNameAlert!.alert
  f.busy=32;let player=Player();f.player=player
  var revokeRetired=[Bool]();var effectsRetired=[Bool]()
  player.onEffect={effectsRetired.append(f.queueNameAlert==nil)}
  f.bridge.onRevoke={revokeRetired.append(f.queueNameAlert==nil && old.pendingCompletion)}
  switch kind {
  case "sign-in":f.email.stringValue="synthetic@example.test";f.password.stringValue="synthetic-password";f.busy=0;f.signIn()
  case "sign-out":f.signOut()
  case "select":f.selectTrack()
  default:f.queueCommand(kind,id:11)
  }
  let dispatchOK = kind == "sign-in" ? f.bridge.requests.count==1 && f.bridge.requests[0]["command"] as? String=="login" : f.sent.isEmpty
  try requireThat(revokeRetired==[true] && effectsRetired.allSatisfy {$0} && !effectsRetired.isEmpty && f.queueNameAlert==nil && dispatchOK,"owner boundary reached decoder/revoke before retiring detail")
 }
}
for kind in ["login","register","restore","logout","select","queue_play","next","previous","queue_clear","queue_restore"] {
 test("full-name-direct-command-retirement-before-busy-\(kind)") {
  let (f,menu)=try open([11,12,13]);raw(f,try nameItem(menu));let old=f.queueNameAlert!.alert
  f.busy=32;f.command(["command":kind])
  try requireThat(f.queueNameAlert==nil && old.pendingCompletion && f.sent.isEmpty && f.bridge.revocations==0,"direct owner command lost pre-admission retirement")
 }
}
for kind in ["queue_remove","queue_move"] {
 test("full-name-noncurrent-\(kind)-preserves-until-publication") {
  let (f,menu)=try open([11,12,13]);let row=menu.items[0];let item=try nameItem(menu,0)
  raw(f,item);let old=f.queueNameAlert!.alert;let player=Player();f.player=player
  raw(f,row.submenu!.items[kind=="queue_remove" ? 3 : 2])
  try requireThat(f.queueNameAlert?.alert === old && !old.pendingCompletion && f.epoch==1 && f.bridge.revocations==0 && player.events.isEmpty && f.bridge.completions.count==1,"noncurrent mutation retired valid detail before publication")
  try expectSent(f,kind,11,kind=="queue_move" ? 1 : nil)
  f.apply(try orderedSnapshot([13,12,11]))
  try requireThat(f.queueNameAlert?.alert === old,"unrelated reorder retired exact detail")
  if kind=="queue_remove" {f.apply(try orderedSnapshot([13,12]))}
  else {f.apply(renamed(f.snapshot!,11,"published rename"))}
  try requireThat(f.queueNameAlert==nil && old.pendingCompletion,"genuine removal/rename publication retained old detail")
  raw(f,item);old.drainCompletion()
  if kind=="queue_remove" {try requireThat(f.queueNameAlert==nil,"removed occurrence reopened")}
  else {try requireThat(f.queueNameAlert?.alert !== old && (try nameText(f.queueNameAlert!.alert)).string=="published rename","reopen revived old metadata")}
 }
}
for (kind,owner) in [("previous",UInt64(11)),("next",UInt64(13))] {
 test("full-name-unavailable-\(kind)-preserves-owner") {
  let (f,menu)=try open([11,12,13]);f.snapshot=try orderedSnapshot([11,12,13],owner:owner)
  raw(f,try nameItem(menu));let old=f.queueNameAlert!.alert;let player=Player();f.player=player
  f.queueCommand(kind)
  try requireThat(f.queueNameAlert?.alert === old && !old.pendingCompletion && f.sent.isEmpty && f.bridge.revocations==0 && player.events.isEmpty,"unavailable transport no-op retired valid detail")
 }
}
func nameItem(_ menu:NSMenu,_ row:Int=1) throws ->NSMenuItem {
 guard let item=menu.items[row].submenu?.items.first(where:{$0.title=="Full name"}) else {throw Mismatch(description:"missing name route")}
 return item
}
func nameText(_ alert:NSAlert) throws ->NSTextView {
 guard let text=alert.accessoryView?.documentView as? NSTextView else {throw Mismatch(description:"no native text view")}
 return text
}
func renamed(_ s:Snapshot,_ id:UInt64,_ title:String) ->Snapshot {
 var s=s;s.queue=s.queue.map {$0.id==id ? Occurrence(id:id,track:Track(id:$0.track.id,title:title,artist:nil,duration_ms:nil)) : $0};return s
}
func changed(_ s:Snapshot,_ key:String,_ value:Any) throws ->Snapshot {
 var object:[String:Any] = ["epoch":s.epoch,"session":s.session,"revision":s.revision,"authenticated":s.authenticated,
  "library":[],"library_unchanged":true,"total":s.total,"queue":s.queue.map {["id":$0.id,"track":["id":$0.track.id,"title":$0.track.title]]},
  "queue_unchanged":false,"selected_occurrence":s.selected_occurrence.map {NSNumber(value:$0) as Any} ?? NSNull(),
  "transport":s.transport,"position_ms":s.position_ms,"duration_ms":s.duration_ms]
 object[key]=value
 return try JSONDecoder().decode(Snapshot.self,from:JSONSerialization.data(withJSONObject:object))
}
for (label,title) in [("short","短 🎵"),("unicode-very-long",String(repeating:"e\u{301}👩🏽‍🚀音楽\n",count:4096)+"FINAL 名称")] {
 for owner:UInt64? in [11,12,nil] {
  test("full-name-exact-\(label)-owner-\(owner.map {String($0)} ?? "none")") {
   let (f,menu)=try open([11,12,13]);f.snapshot=renamed(try orderedSnapshot([13,12,11],owner:owner),12,title)
   let item=try nameItem(menu);item.menu?.font=NSFont(26)
   item.menu?.update();try requireThat(item.isEnabled,"live route unavailable")
   let before=f.snapshot!;raw(f,item)
   guard let detail=f.queueNameAlert else {throw Mismatch(description:"name route did not show")}
   let text=try nameText(detail.alert)
   try requireThat(Array(text.string.utf8)==Array(title.utf8) && detail.id==12,"wrong occurrence title/prefix/Unicode bytes")
   try requireThat(!text.isEditable && text.isSelectable && !text.isRichText,"name is not read-only selectable plain text")
   try requireThat(text.font?.pointSize==26,"native menu font not inherited")
   try requireThat(f.sent.isEmpty && f.snapshot!.selected_occurrence==before.selected_occurrence && f.snapshot!.transport==before.transport,"name changed playback truth")
   f.closeQueueName();try requireThat(f.queueNameAlert==nil && f.sent.isEmpty,"close sent a command or retained detail")
  }
 }
}
test("full-name-native-scroll-and-close-configuration") {
 let (f,menu)=try open([11]);raw(f,try nameItem(menu,0));let detail=f.queueNameAlert!.alert
 let text=try nameText(detail);let area=detail.accessoryView!
 try requireThat(area.hasVerticalScroller && !area.hasHorizontalScroller && text.isVerticallyResizable && !text.isHorizontallyResizable,"native wrapping/vertical scroll configuration missing")
 try requireThat(text.textContainer!.widthTracksTextView && text.textContainer!.lineBreakMode == .byCharWrapping,"long unbroken Unicode cannot wrap")
 // The former Escape + nonnil-default assertion passed only because the facade
 // did not model AppKit's setter. A single native equivalent cannot hold both.
 try requireThat(detail.buttons.map {$0.title}==["Done"] && detail.buttons[0].keyEquivalent=="\u{1b}","native Done Escape was overwritten")
 try requireThat((detail.buttons[0].cell as? NSButtonCell)?.keyEquivalent=="\u{1b}" && detail.window.defaultButtonCell==nil,"Escape requires the same cell and no Return-default association")
 try requireThat(detail.window.initialFirstResponder === text,"native initial text focus not configured")
 detail.finish(f.window);detail.drainCompletion()
 try requireThat(f.queueNameAlert==nil && f.sent.isEmpty,"native close completion mutated queue or retained owner")
}
for (name,value) in [("missing",nil),("string","12" as Any?),("boolean",NSNumber(value:true) as Any?),
                     ("negative",NSNumber(value:-1) as Any?),("fraction",NSNumber(value:12.5) as Any?),
                     ("zero",NSNumber(value:0) as Any?),("nonfinite",NSNumber(value:Double.nan) as Any?)] {
 test("full-name-reject-identity-\(name)") {
  let (f,menu)=try open([1,12,13]);let item=try nameItem(menu);item.representedObject=value
  item.menu?.update();try requireThat(!item.isEnabled,"malformed ID enabled")
  raw(f,item);try requireThat(f.queueNameAlert==nil && f.sent.isEmpty,"malformed ID opened or dispatched")
 }
}
for reason in ["removed","missing-snapshot","revoked-epoch","signed-out"] {
 test("full-name-live-refusal-\(reason)") {
  let (f,menu)=try open([11,12,13]);let item=try nameItem(menu)
  if reason=="removed" {f.snapshot=try orderedSnapshot([11,13])}
  if reason=="missing-snapshot" {f.snapshot=nil}
  if reason=="revoked-epoch" {f.epoch=2}
  if reason=="signed-out" {f.snapshot=try changed(f.snapshot!,"authenticated",false)}
  item.menu?.update();try requireThat(!item.isEnabled,"retired identity enabled")
  raw(f,item);try requireThat(f.queueNameAlert==nil && f.sent.isEmpty,"retired identity showed name or dispatched")
 }
}
test("full-name-supersession-old-completion-cannot-close-newer-detail") {
 let (f,menu)=try open([11,12,13]);raw(f,try nameItem(menu));let old=f.queueNameAlert!.alert
 raw(f,try nameItem(menu,2));let newer=f.queueNameAlert!.alert
 try requireThat(old !== newer && old.pendingCompletion,"older detail not retired before replacement")
 old.drainCompletion();try requireThat(f.queueNameAlert?.alert === newer && f.window.attachedSheet === newer.window,"older completion retired newer detail")
 f.showQueue();try requireThat(f.queueNameAlert==nil && f.sent.isEmpty,"queue supersession retained detail or dispatched")
}
for reason in ["removed","renamed","selection","session","epoch","signed-out"] {
 test("full-name-publication-cleanup-\(reason)") {
  let (f,menu)=try open([11,12,13]);raw(f,try nameItem(menu));let old=f.queueNameAlert!.alert
  var incoming=f.snapshot!
  switch reason {
  case "removed":incoming=try orderedSnapshot([11,13])
  case "renamed":incoming=renamed(incoming,12,"new title")
  case "selection":incoming=try changed(incoming,"selected_occurrence",11)
  case "session":incoming=try changed(incoming,"session",2)
  case "epoch":incoming=try changed(incoming,"epoch",2)
  default:incoming=try changed(incoming,"authenticated",false)
  }
  f.apply(incoming);try requireThat(f.queueNameAlert==nil && old.pendingCompletion && f.sent.isEmpty,"publication failed to close read-only detail")
 }
}
for (label,opening,incomingTitle) in [("decomposed","Caf\u{e9}","Cafe\u{301}"),("precomposed","Cafe\u{301}","Caf\u{e9}")] {
 test("full-name-normalization-only-rename-\(label)") {
  try requireThat(opening==incomingTitle && Array(opening.utf8) != Array(incomingTitle.utf8),"fixture must have Swift canonical equality but different exact UTF8")
  let (f,menu)=try open([11,12,13]);let item=try nameItem(menu)
  f.snapshot=renamed(f.snapshot!,12,opening);raw(f,item);let old=f.queueNameAlert!.alert
  try requireThat(Array(try nameText(old).string.utf8)==Array(opening.utf8),"opening lost exact source bytes")
  f.apply(renamed(f.snapshot!,12,incomingTitle))
  try requireThat(f.queueNameAlert==nil && old.pendingCompletion && f.sent.isEmpty,"normalization-only rename retained stale selectable metadata")
  try requireThat(Array(f.snapshot!.queue[1].track.title.utf8)==Array(incomingTitle.utf8),"apply lost incoming exact bytes")
  raw(f,item);let fresh=f.queueNameAlert!.alert;old.drainCompletion()
  try requireThat(fresh !== old && f.queueNameAlert?.alert === fresh && Array(try nameText(fresh).string.utf8)==Array(incomingTitle.utf8) && f.sent.isEmpty,"reopen returned predecessor bytes or old completion retired fresh owner")
 }
}
test("full-name-reorder-and-unrelated-publication-keeps-browse-owner") {
 let (f,menu)=try open([11,12,13]);raw(f,try nameItem(menu,0));let detail=f.queueNameAlert!.alert
 f.apply(try orderedSnapshot([13,12,11]));try requireThat(f.queueNameAlert?.alert === detail && f.queueNameAlert?.id==11 && f.snapshot?.selected_occurrence==12 && f.sent.isEmpty,"publication transferred browse/current ownership")
 f.closeQueueName()
}
test("full-name-live-reenable-and-unsigned-identity") {
 let id=UInt64.max;let (f,menu)=try open([11,id,13]);let item=try nameItem(menu)
 f.snapshot=try orderedSnapshot([11,13]);item.menu?.update();try requireThat(!item.isEnabled,"removed name action enabled")
 f.snapshot=try orderedSnapshot([13,11,id]);item.menu?.update();try requireThat(item.isEnabled,"restored unsigned identity did not reenable")
 raw(f,item);try requireThat(f.queueNameAlert?.id==id && f.sent.isEmpty,"unsigned occurrence identity changed or dispatched")
 f.closeQueueName()
}
test("full-name-queue-unchanged-publication-keeps-detail") {
 let (f,menu)=try open([11,12,13]);raw(f,try nameItem(menu));let alert=f.queueNameAlert!.alert
 var incoming=try changed(f.snapshot!,"queue_unchanged",true);incoming.queue=[]
 f.apply(incoming);try requireThat(f.queueNameAlert?.alert === alert && f.snapshot?.queue.count==3 && f.sent.isEmpty,"unchanged publication closed detail or lost queue")
 f.closeQueueName()
}
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def run_platform(platform, root, output):
    output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    with tempfile.TemporaryDirectory(prefix='queue-current-', dir=os.environ.get('TMPDIR')) as tmp:
        work = Path(tmp)
        if platform == 'android':
            production = (root / dialog.ACTIVITY).read_bytes()
            probe = dialog.PROBE.replace(' check(failures==0)', ANDROID_CASES + '\n check(failures==0)')
            assert probe != dialog.PROBE
            sources = []
            from android_library_regressions import prepare_queue_harness
            sources_text = prepare_queue_harness(root)
            sources_text['Probe.kt'] = probe
            for name, text in sources_text.items():
                path = work / name
                path.write_text(text)
                sources.append(str(path))
            java = java_home()
            env.update(JAVA_HOME=str(java), JAVA_TOOL_OPTIONS='-XX:ActiveProcessorCount=2')
            compile_argv = [kotlin_compiler(), *sources, '-nowarn', '-include-runtime', '-d', str(work / 'probe.jar')]
            run_argv = [str(java / 'bin/java'), '-jar', str(work / 'probe.jar')]
            extraction = {'wholeActivity': False, 'evidenceClass': 'production-queue-disclosure-with-shell-boundary-facade',
                          'sourceHashes': {name:sha(text.encode()) for name,text in sources_text.items()},
                          'dialogTestSha256': sha(Path(dialog.__file__).read_bytes())}
        else:
            production = (root / SWIFT).read_bytes()
            source = production.decode()
            type_signatures = ['struct Track:', 'struct Occurrence:', 'struct Snapshot:',
                               'struct AudioEffect:', 'struct Credentials:', 'struct Reply:']
            signatures = ['@objc func showQueue()', '@objc func playOccurrence(', '@objc func removeOccurrence(',
                          '@objc func moveOccurrenceUp(', '@objc func moveOccurrenceDown(',
                          'func moveOccurrence(', '@objc func clearQueue()', 'func queueCommand(', 'func command(',
                          '@objc func signIn()', '@objc func signOut()', '@objc func selectTrack()']
            if 'struct LibraryReadIntent:' in source:
                signatures[signatures.index('func command(')] = 'func command(_ value: [String:Any], result:'
                signatures += ['func command(_ value: [String:Any], completion:', 'func finishLibraryRead(', 'func retireLibraryRead(']
                type_signatures += ['struct LibraryReadIdentity:', 'struct LibraryReadIntent:']
            assert all(source.count(s) == 1 for s in type_signatures + signatures), 'production extraction must be unambiguous'
            types = '\n'.join(swift_block(source, s) for s in type_signatures)
            projection = (root / 'native/macos/Sources/LibraryDockView.swift').read_text()
            types += '\n' + swift_block(projection, 'struct DockChrome {')
            methods = '\n'.join(('@discardableResult\n' if s.startswith('func command(') and '-> Bool' in swift_block(source,s) else '')+swift_block(source, s) for s in signatures)
            assert source.count('func validateMenuItem(') <= 1
            validation = swift_block(source, 'func validateMenuItem(') if 'func validateMenuItem(' in source else ''
            methods += '\n' + validation
            details = ['func queueNameOccurrence(', '@objc func showOccurrenceName(', 'func closeQueueName()', 'func reconcileQueueName(', 'func apply(_ incoming: Snapshot)']
            assert all(source.count(s) <= 1 for s in details), 'detail extraction must be unambiguous'
            methods += '\n' + '\n'.join(swift_block(source, s) for s in details if s in source)
            detail_fields = '\n'.join(line for line in source.splitlines() if line.strip().startswith('var queueNameAlert:'))
            if 'struct LibraryReadIntent:' in source:
                import re
                detail_fields += '\n'+'\n'.join(line.strip() for line in source.splitlines() if re.match(r'    var (libraryLiked|libraryReadSerial|libraryReadRetired|pendingLibraryRead|acknowledgedLibraryRead|libraryReadFailure|libraryRevision|libraryReadInvalid)\b',line))
                detail_fields += '\n func updateLibraryReadPresentation(){}'
            declaration_start = source.index('final class App:')
            declaration = source[declaration_start:source.index('{', declaration_start)]
            conformance = ',NSMenuItemValidation' if 'NSMenuItemValidation' in declaration else ''
            probe = SWIFT_FACADES.replace('__TYPES__', types).replace('__METHODS__', methods).replace('__VALIDATION__', conformance)
            probe = probe.replace('__DETAIL_FIELDS__', detail_fields).replace('__DETAIL_CASES__', SWIFT_DETAIL_CASES if detail_fields else '')
            if 'AuthFormView()' in source:
                probe=probe.replace('class App:NSObject',swift_block((root/'native/macos/Sources/AuthForm.swift').read_text(),'struct AuthFormState')+'\nclass Form:Label {var username=Label();var confirmation=Label();func clearSecrets(){};func update(_ state:AuthFormState){}}\nclass App:NSObject',1)
                probe=probe.replace('var loginArea=Label();','var authForm=AuthFormState();var loginArea=Form();')
            assert '__' not in probe
            path = work / 'main.swift'
            path.write_text(probe)
            compile_argv = ['/usr/bin/swiftc', '-j', '2', '-num-threads', '2', '-module-cache-path', str(work / 'module-cache'), str(path), '-o', str(work / 'probe')]
            run_argv = [str(work / 'probe')]
            extraction = {'showQueueSha256': sha(swift_block(source, '@objc func showQueue()').encode()),
                          'commandMethodSha256': {s: sha(swift_block(source, s).encode()) for s in signatures},
                          'detailMethodSha256': {s: sha(swift_block(source, s).encode()) for s in details if s in source},
                          'detailFieldsSha256': sha(detail_fields.encode()),
                          'methodsSha256': sha(methods.encode()), 'typesSha256': sha(types.encode())}
        (output / ('Probe.kt' if platform == 'android' else 'main.swift')).write_text(probe)
        compiled = subprocess.run(compile_argv, cwd=root, env=env, capture_output=True, timeout=120)
        ran = subprocess.run(run_argv, cwd=root, env=env, capture_output=True, timeout=30) if compiled.returncode == 0 else None
        for label, result in [('compiler', compiled), ('runtime', ran)]:
            (output / (label + '.log')).write_bytes(result.stdout + result.stderr if result else b'NOT RUN\n')
        lines = ran.stdout.decode().splitlines() if ran else []
        receipt = dict(platform=platform, productionSha256=sha(production), testSha256=sha(Path(__file__).read_bytes()),
                       extraction=extraction, compileArgv=compile_argv, compileExit=compiled.returncode,
                       runArgv=run_argv, runExit=ran.returncode if ran else None,
                       passNames=[s[5:] for s in lines if s.startswith('PASS ')],
                       failures=[s[5:] for s in lines if s.startswith('FAIL ')],
                       logSha256={s: sha((output / s).read_bytes()) for s in ['compiler.log', 'runtime.log']})
        (output / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(platform, json.dumps(receipt))
        print((output / 'compiler.log').read_text(), end='')
        print((output / 'runtime.log').read_text(), end='')
        return compiled.returncode or (ran.returncode if ran else 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    results = [run_platform(p, args.source_root.resolve(), args.output.resolve() / p) for p in ['android', 'macos']]
    raise SystemExit(1 if any(results) else 0)


if __name__ == '__main__':
    main()
