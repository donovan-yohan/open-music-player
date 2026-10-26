#!/usr/bin/env python3
"""Source-bound favorite menu controls, no app/window or real mutation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from native_review_regressions import swift_block

ROOT=Path(__file__).resolve().parents[2]
CASES=r'''
@MainActor func value(_ favorites:[Int64]=[],_ ids:[Int64]=[7,8])->Snapshot {
 var s=Snapshot(epoch:1,session:1,revision:1,authenticated:true,library:ids.map {Track(id:$0,title:"Track \($0)",artist:"Artist",duration_ms:30000)},library_unchanged:false,total:UInt64(ids.count),queue:[],queue_unchanged:false,selected_occurrence:nil,transport:"paused",position_ms:6000,duration_ms:30000,error:nil)
 s.favorite_track_ids=favorites;return s
}
var failures=[String](),passed=[String]()
@MainActor func check(_ name:String,_ ok:Bool){if ok {passed.append(name);print("PASS \(name)")} else {failures.append(name);print("FAIL \(name)")}}
@MainActor func ready()->(App,LibraryFavoriteMenu) {let a=App();a.snapshot=value();let menu=LibraryFavoriteMenu(owner:a);menu.menuNeedsUpdate(menu);return(a,menu)}
let (a,m)=ready();let first=m.items[0]
check("explicit-like-current-selected",first.title=="Like selected track" && m.validateMenuItem(first))
m.performFavorite(first)
check("actual-desired-like-wire",a.sent.count==1 && a.sent[0]["command"] as? String=="set_favorite" && (a.sent[0]["track_id"] as? Int64)==7 && a.sent[0]["liked"] as? Bool==true)
check("no-local-optimistic-like",a.snapshot?.favorite_track_ids==[])
m.performFavorite(first);check("consumed-action-no-repeat",a.sent.count==1)
a.snapshot=value([7]);m.menuNeedsUpdate(m);let unlike=m.items[0]
check("acknowledged-projection-explicit-unlike",unlike.title=="Unlike selected track" && m.validateMenuItem(unlike))
m.performFavorite(unlike);check("actual-desired-unlike-wire",a.sent.count==2 && a.sent[1]["liked"] as? Bool==false)
for kind in ["selection","account","epoch","session","removal","liked","busy","logout"] {
 let (owner,menu)=ready();let old=menu.items[0]
 if kind=="selection" {owner.table.selectedRow=1}
 if kind=="account" {owner.accountScope=2}
 if kind=="epoch" {owner.epoch=2}
 if kind=="session" {owner.snapshot=Snapshot(epoch:1,session:2,revision:1,authenticated:true,library:value().library,library_unchanged:false,favorite_track_ids:[],total:2,queue:[],queue_unchanged:false,selected_occurrence:nil,transport:"paused",position_ms:6000,duration_ms:30000,error:nil)}
 if kind=="removal" {owner.snapshot=value([],[8])}
 if kind=="liked" {owner.snapshot=value([7])}
 if kind=="busy" {owner.busy=1}
 if kind=="logout" {owner.snapshot=Snapshot(epoch:1,session:1,revision:1,authenticated:false,library:value().library,library_unchanged:false,favorite_track_ids:[],total:2,queue:[],queue_unchanged:false,selected_occurrence:nil,transport:"paused",position_ms:6000,duration_ms:30000,error:nil)}
 menu.performFavorite(old);check("stale-refused-"+kind,owner.sent.isEmpty && !menu.validateMenuItem(old))
}
let (replace,menu)=ready();let old=menu.items[0];menu.menuNeedsUpdate(menu);menu.performFavorite(old);check("replaced-item-refused",replace.sent.isEmpty && !menu.validateMenuItem(old))
let (empty,emptyMenu)=ready();empty.table.selectedRow = -1;emptyMenu.menuNeedsUpdate(emptyMenu);check("no-selection-disabled",!emptyMenu.items[0].isEnabled && !emptyMenu.validateMenuItem(emptyMenu.items[0]))
let (unknown,unknownMenu)=ready();unknown.snapshot?.favorite_track_ids=nil;unknownMenu.menuNeedsUpdate(unknownMenu);check("missing-projection-unavailable",!unknownMenu.items[0].isEnabled && !unknownMenu.validateMenuItem(unknownMenu.items[0]))
var scalarMissing=Snapshot(epoch:1,session:1,revision:2,authenticated:true,library:value().library,library_unchanged:true,favorite_track_ids:[],total:2,queue:[],queue_unchanged:true,selected_occurrence:nil,transport:"paused",position_ms:6000,duration_ms:30000,error:nil)
let scalarOwner=unknown
do {var value=scalarMissing;let snapshot=scalarOwner.snapshot;__MERGE__;scalarMissing=value}
unknown.snapshot=scalarMissing;unknownMenu.menuNeedsUpdate(unknownMenu)
check("actual-scalar-merge-preserves-unavailable-projection",scalarMissing.favorite_track_ids==nil && !unknownMenu.validateMenuItem(unknownMenu.items[0]))
let (scalar,scalarMenu)=ready();let stable=scalarMenu.items[0];var s=value();s.favorite_track_ids=[];scalar.snapshot=s;scalarMenu.performFavorite(stable);check("same-owner-scalar-remains-valid",scalar.sent.count==1)
print("LIBRARY_FAVORITES_PASS \(passed.count) failures=\(failures.count)");exit(failures.isEmpty ? 0 : 1)
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--source-root',type=Path,default=ROOT);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    args.output.mkdir(mode=0o700,parents=True,exist_ok=False)
    menu=args.source_root/'native/macos/Sources/LibraryFavoriteMenu.swift';source=(args.source_root/'native/macos/Sources/main.swift').read_text()
    if not menu.is_file() or 'LibraryFavoriteMenu(owner:self)' not in source:
        (args.output/'receipt.json').write_text(json.dumps(dict(passed=False,classification='missing-native-favorite-menu-contract'))+'\n');print('FAIL missing native favorite menu contract');return 1
    types='\n'.join(swift_block(source,s) for s in ['struct Track:','struct Occurrence:','struct Snapshot:'])
    facade=r'''
@MainActor class Table {var selectedRow=0}
@MainActor final class App:NSObject {
 var snapshot:Snapshot?;var epoch:UInt64=1;var accountScope:UInt64=1;var busy=0;var table=Table()
 var sent=[[String:Any]]()
 func command(_ value:[String:Any]) {sent.append(value)}
}
'''
    apply=swift_block(source,'func apply(_ incoming: Snapshot)')
    merge=next(line.strip() for line in apply.splitlines() if 'if value.library_unchanged {value.favorite_track_ids' in line)
    generated='import AppKit\n'+types+'\n'+facade+'\n'+menu.read_text().replace('import AppKit','')+'\n'+CASES.replace('__MERGE__',merge)
    p=args.output/'main.swift';p.write_text(generated)
    argv=['swiftc','-swift-version','6','-num-threads','2',str(p),'-o',str(args.output/'probe')]
    built=subprocess.run(argv,capture_output=True,timeout=100)
    ran=subprocess.run([str(args.output/'probe')],capture_output=True,timeout=20) if built.returncode==0 else None
    (args.output/'compile.log').write_bytes(built.stdout+built.stderr)
    (args.output/'run.log').write_bytes(ran.stdout+ran.stderr if ran else b'NOT RUN')
    lines=ran.stdout.decode().splitlines() if ran else []
    d=dict(passed=built.returncode==0 and ran is not None and ran.returncode==0,compile_exit=built.returncode,run_exit=ran.returncode if ran else None,production_menu_sha256=hashlib.sha256(menu.read_bytes()).hexdigest(),production_main_sha256=hashlib.sha256(source.encode()).hexdigest(),probe_sha256=hashlib.sha256(generated.encode()).hexdigest(),test_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),TMPDIR=os.environ.get('TMPDIR'),passes=[l[5:] for l in lines if l.startswith('PASS ')],failures=[l[5:] for l in lines if l.startswith('FAIL ')],scope='production native menu with observed App/selection dispatch boundaries, not app runtime or Go mutation')
    (args.output/'receipt.json').write_text(json.dumps(d,indent=2)+'\n');print((args.output/'compile.log').read_text());print((args.output/'run.log').read_text());return 0 if d['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
