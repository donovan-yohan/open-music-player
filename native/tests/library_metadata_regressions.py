#!/usr/bin/env python3
"""Source-bound Library Full details contract and native wrapper regressions.

No NSApplication/window is created. A predecessor with no explicit Library route
fails the contract assertion, not compilation. Probes compile exact production
open/close/reconcile/action/command/apply methods against boundary facades, then
repeat browse-selection invariants using a real, window-free NSTableView hierarchy.
Only AppKit owns reload, selection and delegate notification behavior in that probe.
"""
import argparse
import hashlib
import json

import subprocess
from native_review_regressions import swift_block
import queue_current_marker_regressions as marker
from pathlib import Path

SWIFT_CASES = r'''
var failures=[String](),passes=[String]()
func check(_ name:String,_ value:Bool) {if value {passes.append(name);print("PASS \(name)")} else {failures.append(name);print("FAIL \(name)")}}
func state(_ title:String="Title",_ artist:String?="Artist",_ ids:[Int64]=[7],_ session:UInt64=1,_ auth:Bool=true,_ epoch:UInt64=1)->Snapshot {
 Snapshot(epoch:epoch,session:session,revision:1,authenticated:auth,library:ids.map {Track(id:$0,title:title,artist:artist,duration_ms:30000)},library_unchanged:false,total:UInt64(ids.count),queue:[],queue_unchanged:false,selected_occurrence:nil,transport:"paused",position_ms:0,duration_ms:30000,error:nil)
}
func ready()->App {let a=App();a.apply(state());a.table.selectedRow=0;a.updateLibraryDetailsAction();return a}
func open(_ a:App)->NSAlert {a.libraryDetailsAction!.open();return a.libraryDetailsAlert!.alert}

let menuOwner=ready(),menu=menuOwner.makeLibraryMenu(),item=menu.items[0]
check("library-menu-native-key-equivalent",menu.title=="Library" && menu.autoenablesItems && menu.items.count==1 && item.title=="Full details" && item.keyEquivalent=="i" && item.keyEquivalentModifierMask == [.command] && item.target === menuOwner && item.action == #selector(App.openLibraryDetailsFromMenu(_:)))
menu.update();check("library-menu-automatic-selected-validation",item.isEnabled)
menuOwner.openLibraryDetailsFromMenu(item)
check("library-menu-dispatches-existing-read-capability",menuOwner.libraryDetailsAlert != nil && menuOwner.bridge.sent.isEmpty && menuOwner.bridge.revocations==0)
let oldMenuAction=menuOwner.libraryDetailsAlert!.action
menuOwner.closeLibraryDetails();oldMenuAction.open();check("library-menu-consumed-capability-no-reopen",menuOwner.libraryDetailsAlert==nil)
for (name,incoming) in [("empty",state("Title","Artist",[])),("auth",state("Title","Artist",[7],1,false)),("epoch",state("Title","Artist",[7],1,true,2)),("session",state("Title","Artist",[7],2)),("title",state("Changed")),("artist",state("Title","Changed"))] {
 let f=ready(),m=f.makeLibraryMenu(),i=m.items[0],action=f.libraryDetailsAction!
 f.apply(incoming);m.update();action.open()
 check("library-menu-old-capability-refused-"+name,f.libraryDetailsAlert==nil && f.bridge.sent.isEmpty && !action.active)
 let currentAvailable=["session","title","artist"].contains(name)
 check("library-menu-current-availability-"+name,i.isEnabled==currentAvailable)
 f.openLibraryDetailsFromMenu(i)
 check("library-menu-dispatch-current-only-"+name,(f.libraryDetailsAlert != nil)==currentAvailable && f.bridge.sent.isEmpty)
}
let account=ready(),am=account.makeLibraryMenu(),ai=am.items[0],aa=account.libraryDetailsAction!;account.accountScope+=1;am.update();account.openLibraryDetailsFromMenu(ai);aa.open()
check("library-menu-account-retired-disabled-and-raw-refusal",!ai.isEnabled && account.libraryDetailsAlert==nil)

let missing=ready(),missingMenu=missing.makeLibraryMenu(),missingItem=missingMenu.items[0];missing.snapshot=nil;missingMenu.update();missing.openLibraryDetailsFromMenu(missingItem)
check("library-menu-missing-snapshot-unavailable",!missingItem.isEnabled && missing.libraryDetailsAlert==nil)
let retired=ready(),retiredMenu=retired.makeLibraryMenu(),retiredItem=retiredMenu.items[0],retiredAction=retired.libraryDetailsAction!;retired.retireLibraryDetails();retiredMenu.update();retired.openLibraryDetailsFromMenu(retiredItem);retiredAction.open()
check("library-menu-explicit-retirement-unavailable",!retiredItem.isEnabled && retired.libraryDetailsAlert==nil && retired.bridge.sent.isEmpty)

let malformed=ready(),mm=malformed.makeLibraryMenu(),forged=NSMenuItem(title:"Full details",action:#selector(App.openLibraryDetailsFromMenu(_:)),keyEquivalent:"i");forged.target=malformed;mm.addItem(forged);mm.update();malformed.openLibraryDetailsFromMenu(forged)
check("library-menu-malformed-sender-refused",!forged.isEnabled && malformed.libraryDetailsAlert==nil)
let superseded=ready(),sm=superseded.makeLibraryMenu(),si=sm.items[0];_ = superseded.makeLibraryMenu();sm.update();superseded.openLibraryDetailsFromMenu(si)
check("library-menu-replaced-item-refused",!si.isEnabled && superseded.libraryDetailsAlert==nil)
let restored=ready(),rm=restored.makeLibraryMenu(),ri=rm.items[0],ra=restored.libraryDetailsAction!;restored.apply(state("Title","Artist",[]));restored.apply(state());restored.table.selectedRow=0;restored.updateLibraryDetailsAction();rm.update();ra.open()
check("library-menu-no-old-action-revival",restored.libraryDetailsAlert==nil && ri.isEnabled && restored.libraryDetailsAction !== ra);restored.openLibraryDetailsFromMenu(ri)
check("library-menu-current-capability-reenabled",restored.libraryDetailsAlert != nil)
let a=ready()
check("unqueued-positive-issued-native-target",a.snapshot!.queue.isEmpty && a.libraryDetails.target === a.libraryDetailsAction && a.libraryDetails.isEnabled && a.libraryDetails.action == #selector(LibraryMetadataAction.open))
let issued=a.libraryDetailsAction!,detail=open(a),text=detail.accessoryView!.documentView as! NSTextView
check("real-open-original-title-and-artist",text.string=="Title\nTitle\n\nArtist\nArtist" && !text.isEditable && text.isSelectable && !text.isRichText)
check("real-open-bounded-native-scroll",detail.accessoryView!.hasVerticalScroller && !detail.accessoryView!.hasHorizontalScroller && detail.accessoryView!.frame.width<=560 && detail.accessoryView!.frame.height<=320 && text.textContainer!.widthTracksTextView && text.textContainer!.lineBreakMode == .byCharWrapping)
check("cancel-not-return-default",detail.buttons.first!.keyEquivalent=="\u{1b}" && detail.window.defaultButtonCell==nil && detail.window.initialFirstResponder === text)
check("read-only-no-wire-or-decoder",a.bridge.sent.isEmpty && a.bridge.revocations==0 && a.player==nil)
let latest=a.libraryDetailsAction!
for _ in 0..<120 {a.apply(Snapshot(epoch:1,session:1,revision:2,authenticated:true,library:[],library_unchanged:true,total:1,queue:[],queue_unchanged:true,selected_occurrence:nil,transport:"paused",position_ms:10,duration_ms:30000,error:nil))}
check("120-scalars-preserve-open-and-issued-action",a.libraryDetailsAlert!.alert === detail && a.libraryDetailsAction === latest && issued.active)
issued.open();check("consumed-old-opening-cannot-replace-current",a.libraryDetailsAlert!.alert === detail)
a.closeLibraryDetails();let newer=open(a);detail.drainCompletion()
check("delayed-old-completion-cannot-clear-new",a.libraryDetailsAlert!.alert === newer)
issued.open();check("old-action-cannot-clear-new-disclosure",a.libraryDetailsAlert!.alert === newer)
newer.finish(a.window);newer.drainCompletion();check("done-completion-retires-own-authority",a.libraryDetailsAlert==nil && !a.libraryDetailsAction!.consumed)
for (name,incoming) in [("removal",state("Title","Artist",[])),("title",state("Changed")),("artist",state("Title","Changed")),("nil-vs-empty",state("Title",nil)),("session",state("Title","Artist",[7],2)),("auth",state("Title","Artist",[7],1,false)),("epoch",state("Title","Artist",[7],1,true,2))] {
 let f=ready(),old=f.libraryDetailsAction!,sheet=open(f)
 f.apply(incoming);check("synchronous-retirement-"+name,f.libraryDetailsAlert==nil && !old.active && f.window.attachedSheet==nil)
 f.apply(state());f.table.selectedRow=0;f.updateLibraryDetailsAction();let fresh=open(f);old.open();sheet.drainCompletion()
 check("no-revival-and-old-cleanup-"+name,f.libraryDetailsAlert!.alert === fresh && f.libraryDetailsAction !== old)
}
let reorder=ready(),rowAction=reorder.libraryDetailsAction!;reorder.apply(state("Title","Artist",[8,7]));check("reorder-preserves-semantic-disclosure-capability",rowAction.active && reorder.snapshot!.library[reorder.table.selectedRow].id==7)
rowAction.open();check("reordered-current-action-opens-by-id",reorder.libraryDetailsAlert?.action.track.id==7)
let selection=ready(),selectedAction=selection.libraryDetailsAction!;selection.apply(state("Title","Artist",[7,8]));selection.table.selectedRow=1;selection.tableViewSelectionDidChange(Notification(name:Notification.Name("selection")));selectedAction.open();check("old-browse-selection-action-refused",selection.libraryDetailsAlert==nil && !selectedAction.active)
for kind in ["login","register","restore","logout","select","queue_play","next","previous","queue_clear","queue_restore"] {
 let f=ready(),old=f.libraryDetailsAction!;_ = open(f);f.busy=32
 f.command(["command":kind]);old.open()
 check("actual-command-account-retires-before-busy-"+kind,f.libraryDetailsAlert==nil && !old.active && f.bridge.sent.isEmpty)
}
for kind in ["signIn","signOut","select","queue","terminate","window-close"] {
 let f=ready(),old=f.libraryDetailsAction!;_ = open(f);let p=Player();f.player=p
 var saw=false;let boundary={if !saw {check("retired-before-first-effect-"+kind,f.libraryDetailsAlert==nil && !old.active && f.libraryDetailsAction==nil)};saw=true}
 p.onEffect=boundary;f.bridge.onRevoke=boundary;f.bridge.onSend=boundary
 if kind=="signIn" {f.signIn()} else if kind=="signOut" {f.signOut()} else if kind=="select" {f.selectTrack()} else if kind=="queue" {f.queueCommand("queue_clear")} else if kind=="window-close" {f.windowWillClose(Notification(name:Notification.Name("close")))} else {f.applicationWillTerminate(Notification(name:Notification.Name("quit")))}
 old.open();check("actual-wrapper-retirement-"+kind,(saw || kind=="window-close") && f.libraryDetailsAlert==nil && !old.active)
}
let normalized=ready();normalized.apply(state("Caf\u{e9}"));normalized.updateLibraryDetailsAction();let n=normalized.libraryDetailsAction!;_ = open(normalized);normalized.apply(state("Cafe\u{301}"));check("normalization-only-exact-byte-retirement",!n.active && normalized.libraryDetailsAlert==nil)
let duration=ready(),d=duration.libraryDetailsAction!;_ = open(duration);var changed=state();changed.library=[Track(id:7,title:"Title",artist:"Artist",duration_ms:40000)];duration.apply(changed);check("duration-metadata-retirement",!d.active && duration.libraryDetailsAlert==nil)
let empty=ready();empty.apply(state("Title","Artist",[]));empty.table.selectedRow = -1;empty.updateLibraryDetailsAction();check("empty-no-action",empty.libraryDetailsAction==nil && !empty.libraryDetails.isEnabled)
let nilArtist=ready();nilArtist.apply(state("Title",nil));nilArtist.table.selectedRow=0;nilArtist.updateLibraryDetailsAction();let na=nilArtist.libraryDetailsAction!;_ = open(nilArtist);nilArtist.apply(state("Title",""));check("nil-empty-artist-exact-retirement",!na.active && nilArtist.libraryDetailsAlert==nil)
let unrelated=ready(),u=unrelated.libraryDetailsAction!;let us=open(unrelated);unrelated.command(["command":"queue_move","occurrence_id":77,"to_index":0]);check("unrelated-command-preserves-read-capability",u.active && unrelated.libraryDetailsAlert!.alert === us && unrelated.bridge.sent.count==1)
print("LIBRARY_METADATA_PASS \(passes.count) failures=\(failures.count)");exit(failures.isEmpty ? 0 : 1)
'''


NATIVE_SELECTION_CASES = r'''
var failures=[String](),passes=[String]()
func check(_ name:String,_ value:Bool) {if value {passes.append(name);print("PASS \(name)")} else {failures.append(name);print("FAIL \(name)")}}
func state(_ ids:[Int64],session:UInt64=1,auth:Bool=true,epoch:UInt64=1,scalar:Bool=false)->Snapshot {
 Snapshot(epoch:epoch,session:session,revision:1,authenticated:auth,library:ids.map {Track(id:$0,title:"Track \($0)",artist:"Artist",duration_ms:30000)},library_unchanged:scalar,total:UInt64(ids.count),queue:[],queue_unchanged:scalar,selected_occurrence:nil,transport:"paused",position_ms:10,duration_ms:30000,error:nil)
}
func ready(_ ids:[Int64]=[7,8],row:Int=0)->App {
 let a=App();a.apply(state(ids));if row>=0 {a.table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)};return a
}
func noChoice(_ a:App,_ name:String) {
 let menu=a.makeLibraryMenu();let item=menu.items[0];menu.update()
 check(name+"-no-selection-or-capability",a.table.selectedRow == -1 && a.libraryDetailsAction == nil && !a.libraryDetails.isEnabled && !item.isEnabled && a.libraryDock!.selected == false)
 let p=Player();a.player=p
 a.openLibraryDetailsFromMenu(item)
 let detailsOpened=a.libraryDetailsAlert != nil
 a.selectTrack()
 print("OBSERVE \(name) row=\(a.table.selectedRow) detailsOpened=\(detailsOpened) requests=\(a.bridge.requests) revocations=\(a.bridge.revocations)")
 check(name+"-raw-play-and-details-refused",a.bridge.sent.isEmpty && a.bridge.revocations==0 && p.events.isEmpty && !detailsOpened && a.libraryDetailsAlert==nil)
}
// A native hierarchy only: no NSApplication, NSWindow, input or capture.
let witness=ready(),before=witness.table.selectedRow
witness.snapshot=state([8,9]);witness.table.reloadData()
check("native-reload-positively-retains-numeric-row",before==0 && witness.table.selectedRow==0 && witness.snapshot!.library[witness.table.selectedRow].id==8 && witness.table.window==nil && witness.table.superview != nil)
for (name,ids) in [("removed-same-count",[Int64(8),9]),("filtered-still-valid-index",[Int64(8)])] {
 let a=ready(),old=a.libraryDetailsAction!
 check(name+"-selected-owner-established",old.track.id==7 && a.libraryDetails.isEnabled && a.libraryDock!.selected==true)
 a.apply(state(ids));old.open();noChoice(a,name)
 check(name+"-old-capability-retired",!old.active && a.libraryDetailsAlert==nil)
 let reappeared=ready();reappeared.apply(state(ids));reappeared.apply(state([7,8]));noChoice(reappeared,name+"-reappeared")
 let explicit=ready();explicit.apply(state(ids));explicit.apply(state([7,8]))
 explicit.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
 check(name+"-explicit-reselection-restores-current",explicit.libraryDetailsAction?.track.id==7 && explicit.libraryDetails.isEnabled && explicit.libraryDock!.selected==true)
}
let reordered=ready(),kept=reordered.libraryDetailsAction!
reordered.apply(state([8,7,9]))
check("native-reorder-preserves-id-and-capability",reordered.table.selectedRow==1 && reordered.libraryDetailsAction === kept && kept.active && reordered.libraryDock!.selected==true)
kept.open()
check("native-reordered-current-details-open",reordered.libraryDetailsAlert?.action.track.id==7 && reordered.bridge.sent.isEmpty)
reordered.selectTrack()
check("native-reordered-current-play-exact-wire",reordered.bridge.requests.count==1 && reordered.bridge.requests[0]["command"] as? String == "select" && (reordered.bridge.requests[0]["track_id"] as? NSNumber)?.int64Value==7 && reordered.bridge.revocations==1 && reordered.libraryDetailsAlert==nil)
let none=ready(row:-1);none.apply(state([8,9]));noChoice(none,"no-prior-selection")
let empty=ready();empty.apply(state([]));noChoice(empty,"empty-results")
let trailing=ready([7,8,9],row:2);trailing.apply(state([8]));noChoice(trailing,"old-index-out-of-range")
let malformed=ready();malformed.snapshot=state([]);malformed.apply(state([8,9]));noChoice(malformed,"prior-row-outside-model")
let scalar=ready(),action=scalar.libraryDetailsAction!,loads=scalar.table.reloads
for _ in 0..<120 {scalar.apply(state([],scalar:true))}
check("native-120-scalars-no-reload-or-choice-change",scalar.table.reloads==loads && scalar.table.selectedRow==0 && scalar.libraryDetailsAction === action && action.active)
for (name,incoming) in [("session",state([8,7],session:2)),("auth",state([8,7],auth:false)),("epoch",state([8,7],epoch:2))] {
 let a=ready(),old=a.libraryDetailsAction!;a.apply(incoming);old.open()
 check("native-ownership-old-details-retired-"+name,!old.active && a.libraryDetailsAlert==nil && a.table.selectedRow==1)
 check("native-ownership-current-details-"+name,(a.libraryDetailsAction != nil)==(name=="session"))
}
let account=ready(),old=account.libraryDetailsAction!;account.accountScope+=1
let m=account.makeLibraryMenu();m.update();old.open()
check("native-account-retained-details-refused",!m.items[0].isEnabled && account.libraryDetailsAlert==nil)
let changed=ready(),previous=changed.libraryDetailsAction!
changed.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false);previous.open()
check("native-delegate-selection-retires-previous",!previous.active && changed.libraryDetailsAction?.track.id==8 && changed.libraryDetailsAlert==nil)
print("LIBRARY_NATIVE_SELECTION_PASS \(passes.count) failures=\(failures.count)");exit(failures.isEmpty ? 0 : 1)
'''


def facade_probe(root, output, native_selection=False):
    source=(root/'native/macos/Sources/main.swift').read_text()
    metadata=(root/'native/macos/Sources/LibraryMetadataDisclosure.swift').read_text()
    base=marker.SWIFT_FACADES.split('__TYPES__')[0]
    base=base.replace('@objc protocol NSMenuItemValidation', '@MainActor @objc protocol NSMenuItemValidation')
    base=base.replace('class NSFont {', 'class NSFont {static func systemFont(ofSize:CGFloat)->NSFont {NSFont(ofSize)};')
    base=base.replace('let title:String;let nativeCell:NSButtonCell;', 'var target:AnyObject?;var action:Selector?;var isEnabled=false;var font:NSFont?;let title:String;let nativeCell:NSButtonCell;')

    # Swift 6 isolation mirrors AppKit UI ownership, not a synchronous completion.
    import re
    base=re.sub(r'(?m)^(class |final class )(?!Bridge)',r'@MainActor \1',base)
    base=base.replace(' func revoke()->UInt64', ' @MainActor func revoke()->UInt64').replace(' func send(_ data:', ' @MainActor func send(_ data:')
    types=['struct Track:', 'struct Occurrence:', 'struct Snapshot:', 'struct AudioEffect:', 'struct Credentials:', 'struct Reply:']
    methods=['func makeLibraryMenu()', 'func libraryDetailsMenuAvailable(', '@objc func openLibraryDetailsFromMenu(', 'func validateMenuItem(', 'func updateLibraryDetailsAction()', 'func openLibraryDetails(', 'func closeLibraryDetails()', 'func retireLibraryDetails()', 'func reconcileLibraryDetails(', 'func command(', 'func apply(_ incoming: Snapshot)', '@objc func signIn()', '@objc func signOut()', '@objc func selectTrack()', 'func queueCommand(', 'func applicationWillTerminate(', 'func windowWillClose(', 'func tableViewSelectionDidChange(', 'func updateLibraryAvailability()']
    if native_selection:
        methods.append('func numberOfRows(in tableView: NSTableView)')
    blocks={s:swift_block(source,s) for s in types+methods}
    projection=swift_block((root/'native/macos/Sources/LibraryDockView.swift').read_text(),'struct DockChrome {')
    app=r'''
@MainActor class Timer {func invalidate(){}}
@MainActor class App:NSObject,NSMenuItemValidation {
 var window=Window();var snapshot:Snapshot?;var epoch:UInt64=1;var bridge=Bridge()
 var busy=0;var accountScope:UInt64=1;var storedCredentialVersion:UInt64=0;var wantsPlayback=false;var reportPending=false;var player:Player?;var observation:Any?;var timer:Timer?
 var email=Label();var password=Label();var loginArea=Label();var libraryArea=Label();var logout=Label();var table=Table();var titleLabel=Label();var transportLabel=Label();var play=Label();var slider=Slider();var status=Label()
 var libraryDock:LibraryDockView?;var dockTrackID:Int64?
 var libraryDetailsMenuItem:NSMenuItem?
 @objc func clearQueue(){};@objc func playOccurrence(_ item:NSMenuItem){};@objc func removeOccurrence(_ item:NSMenuItem){};@objc func moveOccurrenceUp(_ item:NSMenuItem){};@objc func moveOccurrenceDown(_ item:NSMenuItem){};@objc func showOccurrenceName(_ item:NSMenuItem){};func queueNameOccurrence(_ item:NSMenuItem)->Occurrence? {nil}
 var libraryDetails=NSButton("Full details","");var libraryDetailsAction:LibraryMetadataAction?;var libraryDetailsAlert:(alert:NSAlert,action:LibraryMetadataAction)?
 func closeQueueName(){};func reconcileQueueName(_ s:Snapshot){};func deleteCredentials(){};func storeCredentials(_ c:Credentials,epoch:UInt64){};func applyAudio(_ effect:AudioEffect){};func loadLibrary(){}
 __METHODS__
}
'''.replace('__METHODS__','\n'.join(blocks[s] for s in methods))
    base=base.replace('func updateProgress(position:UInt64,duration:UInt64){}','func updateProgress(position:UInt64,duration:UInt64){};var selected=false;func setLibraryAvailability(selected:Bool,canLoadMore:Bool){self.selected=selected}')
    # A real NSTableView owns reload/selection/delegate semantics. Only sheet,
    # transport and chrome boundaries stay facades; no production policy is copied.
    if native_selection:
        base=base.replace('import CoreGraphics', 'import CoreGraphics\nimport AppKit')
        base=re.sub(r'@MainActor class Table \{[^\n]+', '''@MainActor class Table: NSTableView {
 var reloads=0
 override func reloadData() {reloads+=1;super.reloadData()}
}''',base)
        app=app.replace('class App:NSObject,NSMenuItemValidation', 'class App:NSObject,NSMenuItemValidation,NSTableViewDataSource,NSTableViewDelegate')
        app=app.replace('var window=Window();', '''let root=NSView(frame:NSRect(x:0,y:0,width:600,height:400))
 let scroll=AppKit.NSScrollView(frame:NSRect(x:0,y:0,width:600,height:400))
 override init() {
  super.init();table.addTableColumn(NSTableColumn(identifier:NSUserInterfaceItemIdentifier("track")))
  table.headerView=nil;table.dataSource=self;table.delegate=self
  scroll.documentView=table;root.addSubview(scroll);libraryDock=LibraryDockView()
 }
 var window=Window();''')
    cases = re.sub(r'(?m)^func ', '@MainActor func ', NATIVE_SELECTION_CASES if native_selection else SWIFT_CASES)
    generated=base+'\n'+'\n'.join(blocks[s] for s in types)+'\n'+projection+'\n'+metadata.replace('import AppKit','')+'\n'+app+'\n'+cases
    path=output/'main.swift';path.write_text(generated)
    argv=['/usr/bin/swiftc','-swift-version','6','-j','2','-num-threads','2',str(path),'-o',str(output/'probe')]
    built=subprocess.run(argv,capture_output=True,timeout=180)
    ran=subprocess.run([str(output/'probe')],capture_output=True,timeout=30) if built.returncode==0 else None
    for name,r in [('compiler.log',built),('runtime.log',ran)]: (output/name).write_bytes(r.stdout+r.stderr if r else b'NOT RUN\n')
    lines=ran.stdout.decode().splitlines() if ran else []
    sha=lambda b:hashlib.sha256(b).hexdigest()
    result=dict(scope='native window-free NSTableView with sheet/transport/chrome facades' if native_selection else 'sheet/transport/AppKit boundary facades',productionSha256=sha(source.encode()),projectionSha256=sha(projection.encode()),compileExit=built.returncode,runExit=ran.returncode if ran else None,compileArgv=argv,blocks={s:sha(b.encode()) for s,b in blocks.items()},metadataSha256=sha(metadata.encode()),probeSha256=sha(generated.encode()),testSha256=sha(Path(__file__).read_bytes()),facadeDependencySha256=sha(Path(marker.__file__).read_bytes()),passNames=[l[5:] for l in lines if l.startswith('PASS ')],failures=[l[5:] for l in lines if l.startswith('FAIL ')],logs={s:sha((output/s).read_bytes()) for s in ['compiler.log','runtime.log']})
    (output/'facade-receipt.json').write_text(json.dumps(result,indent=2)+'\n')
    print((output/'compiler.log').read_text());print((output/'runtime.log').read_text())
    return built.returncode or (ran.returncode if ran else 1)

ROOT = Path(__file__).resolve().parents[2]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-root', type=Path, default=ROOT)
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    a.output.mkdir(parents=True, exist_ok=False)
    source = (a.source_root/'native/macos/Sources/main.swift').read_text()
    menu_route = 'func makeLibraryMenu()' in source and 'makeLibraryMenu()' in swift_block(source, 'func buildWindow()')
    if not menu_route:
        result = dict(productionSha256=hashlib.sha256(source.encode()).hexdigest(),testSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),contract='explicit native Library menu keyboard route in production window composition',passed=False,compileExit=None,classification='missing-explicit-keyboard-route-contract')
        (a.output/'receipt.json').write_text(json.dumps(result,indent=2)+'\n')
        print('FAIL missing explicit native Library menu keyboard route in production window composition')
        return 1
    # Explicit supported route, separate from queued occurrence Full name and a
    # title-only hover/AX label. This is an admission contract, not runtime input.
    exists = 'Full details' in source and 'libraryDetails' in source
    result = dict(productionSha256=hashlib.sha256(source.encode()).hexdigest(),
                  testSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  contract='unqueued selected Library row exposes a native Full details action',
                  passed=exists, compileExit=None,
                  classification='explicit-route-contract' if not exists else 'route-present')
    (a.output/'receipt.json').write_text(json.dumps(result, indent=2)+'\n')
    print(('PASS ' if exists else 'FAIL ')+'unqueued selected Library row exposes a native Full details action')
    if not exists:
        return 1
    facade_output=a.output/'facade';facade_output.mkdir()
    native_output=a.output/'native-selection';native_output.mkdir()
    facade_exit=facade_probe(a.source_root,facade_output)
    native_exit=facade_probe(a.source_root,native_output,native_selection=True)
    return facade_exit or native_exit


if __name__ == '__main__':
    raise SystemExit(main())
