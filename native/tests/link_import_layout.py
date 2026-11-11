#!/usr/bin/env python3
"""Window-free mounted Add link and native sheet controls, no OS input."""
import argparse,hashlib,json,os,subprocess
from pathlib import Path
from library_dock_presentation import production_probe,FILES
ROOT=Path(__file__).resolve().parents[2]
CASES=r'''
var passes=[String](),failures=[String]()
@MainActor func check(_ n:String,_ v:Bool){print(v ? "PASS":"FAIL",n);if v {passes.append(n)} else {failures.append(n)}}
let assets=try NativeAssets.load(root:URL(fileURLWithPath:CommandLine.arguments[1]))
for scale:CGFloat in [1,2] {for width:CGFloat in [760,960,1200,1440] {
 let a=App(),host=NSView(frame:NSRect(x:0,y:0,width:width,height:760));a.mountLibraryDock(in:host,assets:assets)
 let shell=a.libraryDock!;shell.textScale=scale;shell.updateAuthentication(true);shell.layoutSubtreeIfNeeded()
 let buttons=shell.bodyDocument.subviews.compactMap {$0 as? NSButton},add=buttons.first {$0.title=="Add link"}
 let tag="\(Int(width))-\(Int(scale))"
 check("mounted-add-link-"+tag,add != nil && add!.target === a && add!.action != nil && !add!.isHidden)
 if let add {check("native-add-link-cell-"+tag,add.bounds.width>=add.cell!.cellSize.width && add.bounds.height>=add.cell!.cellSize.height && add.font!.pointSize==14*scale)} else {check("native-add-link-cell-"+tag,false)}
 shell.updateAuthentication(false);check("signed-out-add-link-hidden-"+tag,add?.isHidden==true)
}}
__SHEET_CASES__
__PAINT_CASES__
exit(failures.isEmpty ? 0:1)
'''
def run(root,out):
 out.mkdir(parents=True,exist_ok=False);probe,_=production_probe(root);header=probe[:probe.index('var failures=[String]')]
 from native_review_regressions import swift_block
 main=(root/'native/macos/Sources/main.swift').read_text()
 helper=(root/'native/macos/Sources/LinkImport.swift').read_text()
 if 'LinkImportView' in helper:
  methods='@objc func newLinkImport(){};@objc func submitLink(){};@objc func checkLinkImport(){};@objc func recentLinkImports(){};@objc func openImportLibrary(){};@objc func closeLinkImport(){};@objc func chooseLinkImport(_ sender:NSPopUpButton){};'
  header=header.replace('@objc func openLinkImport(){};',methods+'@objc func openLinkImport(){};')
  header+='\n'+helper.replace('import AppKit','')
 sheet=r'''
for scale:CGFloat in [1,2] {for stage in ["pending","uncertain","rejected","complete"] {
 let owner=App(),v=LinkImportView(target:owner,scale:scale);var state=LinkImportState();state.outcome=stage=="complete" ? "accepted":stage;state.pending=stage=="pending" ? 1:nil
 state.feedback=stage=="uncertain" ? "Submission is unconfirmed. Check recent jobs and choose an import; a matching link is not a confirmed match.":"Import complete. Open in Library to choose the track."
 v.update(state,canOpen:stage=="complete");v.layoutSubtreeIfNeeded();let tag="\(Int(scale))-\(stage)"
 check("sheet-native-key-loop-"+tag,v.url.nextKeyView === v.submit && v.close.nextKeyView === v.url && v.submit.keyEquivalent=="\r" && v.close.keyEquivalent=="\u{1b}")
 check("sheet-pending-admission-"+tag,v.submit.isEnabled == (stage=="rejected") && v.url.isEditable && v.url.isSelectable)
 let controls:[NSControl]=[v.url,v.submit,v.check,v.recent,v.open,v.another,v.close,v.jobs]
 check("sheet-controls-bounded-"+tag,controls.allSatisfy{v.bounds.contains($0.frame) && $0.bounds.height >= $0.cell!.cellSize.height})
 let natural=v.feedback.cell!.cellSize(forBounds:NSRect(x:0,y:0,width:v.feedback.bounds.width,height:10000))
 check("sheet-full-feedback-fits-"+tag,natural.height<=v.feedback.bounds.height && v.feedback.font!.pointSize==14*scale && v.bounds.contains(v.feedback.frame))
}}
'''
 paint=r'''
// Actual native cell/cache drawing, no window or input synthesis.
@MainActor func raster(_ view:NSView,_ name:String)->NSBitmapImageRep {
 let rep=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:rep)
 let path=URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent(name+".png")
 try! rep.representation(using:.png,properties:[:])!.write(to:path);return rep
}
@MainActor func focusedBoundaryRaster(_ view:NSTextField,_ name:String)->NSBitmapImageRep {
 // Window-free fields have no shared currentEditor: exercise actual focus
 // paint explicitly. This is not actual OS/shared-editor focus acceptance.
 let rep=raster(view,name)
 __FOCUS_PAINT__
 try! rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent(name+".png"));return rep
}
func near(_ a:NSColor,_ b:NSColor)->Bool {
 let a=a.usingColorSpace(.sRGB)!,b=b.usingColorSpace(.sRGB)!
 return abs(a.redComponent-b.redComponent)<0.035 && abs(a.greenComponent-b.greenComponent)<0.035 && abs(a.blueComponent-b.blueComponent)<0.035 && abs(a.alphaComponent-b.alphaComponent)<0.035
}
func pixel(_ rep:NSBitmapImageRep,_ x:CGFloat,_ y:CGFloat,_ bounds:NSRect)->NSColor {rep.colorAt(x:min(rep.pixelsWide-1,max(0,Int(x/bounds.width*CGFloat(rep.pixelsWide)))),y:min(rep.pixelsHigh-1,max(0,Int(y/bounds.height*CGFloat(rep.pixelsHigh)))))!}
@MainActor func squareBoundary(_ rep:NSBitmapImageRep,_ view:NSView,_ color:NSColor)->Bool {
 let w=view.bounds.width,h=view.bounds.height
 let points:[NSPoint]=[NSPoint(x:0.5,y:0.5),NSPoint(x:w-0.5,y:0.5),NSPoint(x:0.5,y:h-0.5),NSPoint(x:w-0.5,y:h-0.5),NSPoint(x:w/2,y:0.5),NSPoint(x:w/2,y:h-0.5),NSPoint(x:0.5,y:h/2),NSPoint(x:w-0.5,y:h/2)]
 return points.allSatisfy{near(pixel(rep,$0.x,$0.y,view.bounds),color)}
}
for scale:CGFloat in [1,2] {for dark in [false,true] {
 let owner=App(),v=LinkImportView(target:owner,scale:scale);v.appearance=NSAppearance(named:dark ? .darkAqua:.aqua)
 let t=SoundQTokens.resolve(v.effectiveAppearance),tag="\(Int(scale))-\(dark ? "dark":"light")"
 var state=LinkImportState();state.outcome="rejected";state.draft="https://soundcloud.com/artist/recognizable-track"
 v.update(state,canOpen:false);v.layoutSubtreeIfNeeded()
 let url=raster(v.url,"url-idle-"+tag)
 check("paint-url-square-idle-"+tag,squareBoundary(url,v.url,t.inputOutline))
 v.url.cell!.showsFirstResponder=true
 let focus=focusedBoundaryRaster(v.url,"url-focus-"+tag)
 check("paint-url-cyan-focus-boundary-"+tag,squareBoundary(focus,v.url,t.accent))
 v.url.cell!.showsFirstResponder=false;v.url.isEnabled=false
 let disabledURL=raster(v.url,"url-disabled-"+tag)
 check("paint-url-muted-disabled-"+tag,squareBoundary(disabledURL,v.url,t.surface.blended(withFraction:0.55,of:t.neutral)!))
 v.url.isEnabled=true
 let editor=NSTextView(frame:.zero);editor.isFieldEditor=true
 v.url.cell!.select(withFrame:v.url.bounds,in:v.url,editor:editor,delegate:v.url,start:8,length:12)
 check("paint-native-editor-selection-"+tag,editor.string==state.draft && editor.selectedRange()==NSRange(location:8,length:12) && editor.isFieldEditor && v.url.delegate === v && v.url.isEditable && v.url.isSelectable && v.url.font!.pointSize==14*scale)
 v.url.cell!.endEditing(editor)
 v.jobs.addItems(withTitles:["YouTube · https://youtu.be/AAAAAAAAAAA","SoundCloud · https://soundcloud.com/artist/track"]);v.jobs.isEnabled=true
 let chooser=raster(v.jobs,"chooser-idle-"+tag)
 check("paint-chooser-full-square-cell-"+tag,squareBoundary(chooser,v.jobs,t.accent) && v.jobs.bounds.height==SoundQTokens.grid(max(40,40*scale)))
 check("paint-chooser-full-flat-surface-"+tag,[CGFloat(3),v.jobs.bounds.height/2,v.jobs.bounds.height-3].allSatisfy{near(pixel(chooser,4,$0,v.jobs.bounds),t.surface)})
 v.jobs.cell!.isHighlighted=true
 let pressed=raster(v.jobs,"chooser-held-"+tag)
 check("paint-chooser-native-held-feedback-"+tag,squareBoundary(pressed,v.jobs,t.accent) && near(pixel(pressed,4,v.jobs.bounds.height/2,v.jobs.bounds),t.accent))
 v.jobs.cell!.isHighlighted=false
 v.jobs.isEnabled=false
 let disabledChooser=raster(v.jobs,"chooser-disabled-"+tag)
 check("paint-chooser-muted-disabled-"+tag,squareBoundary(disabledChooser,v.jobs,t.surface.blended(withFraction:0.55,of:t.neutral)!))
 check("paint-native-popup-semantics-"+tag,v.jobs.cell is NSPopUpButtonCell && v.jobs.target === owner && v.jobs.action==#selector(App.chooseLinkImport(_:)) && !v.jobs.pullsDown && v.jobs.nextKeyView === v.open)
}
}
for scale:CGFloat in [1,2] {
 let owner=App(),v=LinkImportView(target:owner,scale:scale);var state=LinkImportState();state.outcome="uncertain";state.feedback="Submission is unconfirmed. Check recent jobs and choose an import; a matching link is not a confirmed match."
 let fixtures:[(String,String,String,String)]=[("12345678-1234-4234-8234-123456789abc","youtube","https://youtu.be/AAAAAAAAAAA","2026-10-27T12:01:00Z"),("22345678-1234-4234-8234-123456789abc","soundcloud","https://soundcloud.com/actual-artist/different-track","2026-10-27T12:02:00Z")]
 state.jobs=fixtures.map{Reply.ImportJob(job_id:$0.0,status:"complete",progress:100,error:nil,url:$0.2,source_type:$0.1,track_id:7,created_at:$0.3)}
 v.update(state,canOpen:false);v.layoutSubtreeIfNeeded();let tag="\(Int(scale))"
 let label=v.subviews.compactMap{$0 as? NSTextField}.first{$0.stringValue=="Recent imports"}
 check("history-labeled-separate-current-feedback-"+tag,label != nil && v.feedback.frame.maxY+8<=label!.frame.minY && label!.frame.maxY<=v.jobs.frame.minY && v.feedback.stringValue==state.feedback)
 check("history-truthful-provider-url-time-"+tag,zip(v.jobs.itemArray,fixtures).allSatisfy{item,f in item.title.contains(f.1=="youtube" ? "YouTube":"SoundCloud") && item.title.contains(f.2) && item.title.contains(f.3) && item.title.range(of:f.2)!.lowerBound < (item.title.range(of:f.0)?.lowerBound ?? item.title.startIndex)})
 check("history-full-native-disclosure-"+tag,zip(v.jobs.itemArray,fixtures).allSatisfy{item,f in item.toolTip?.contains(f.0)==true && item.toolTip?.contains(f.2)==true && item.title.contains(f.0)} && v.jobs.accessibilityHelp()?.contains(fixtures[0].0)==true)
 state.jobID=fixtures[1].0;v.update(state,canOpen:false)
 check("history-exact-selection-without-outcome-binding-"+tag,v.jobs.indexOfSelectedItem==1 && state.outcome=="uncertain" && !v.submit.isEnabled && v.jobs.target === owner && v.jobs.action==#selector(App.chooseLinkImport(_:)) && v.jobs.accessibilityHelp()?.contains(fixtures[1].0)==true)
 _=raster(v,"history-layout-"+tag)
}
'''
 focus_paint='''NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
 (view as! LinkImportURLField).drawBoundary(focused:true);NSGraphicsContext.restoreGraphicsState()''' if 'func drawBoundary(focused' in helper else ''
 source=header+'\n'+CASES.replace('__SHEET_CASES__',sheet).replace('__PAINT_CASES__',paint.replace('__FOCUS_PAINT__',focus_paint))
 p=out/'main.swift';p.write_text(source)
 deps=[root/'native/macos/Sources'/n for n in FILES]+[root/'native/macos/Sources/LibraryMetadataDisclosure.swift']
 argv=['swiftc','-swift-version','6','-num-threads','2',str(p),*[str(d) for d in deps],'-o',str(out/'probe')]
 built=subprocess.run(argv,capture_output=True,timeout=120);(out/'compile.log').write_bytes(built.stdout+built.stderr)
 ran=subprocess.run([str(out/'probe'),str(root/'native/macos/Sources/Resources'),str(out)],capture_output=True,timeout=30) if built.returncode==0 else None
 (out/'run.log').write_bytes(ran.stdout+ran.stderr if ran else b'NOT RUN');lines=ran.stdout.decode().splitlines() if ran else []
 passes=[x[5:] for x in lines if x.startswith('PASS ')];expected=[prefix+f'{w}-{s}' for s in [1,2] for w in [760,960,1200,1440] for prefix in ['mounted-add-link-','native-add-link-cell-','signed-out-add-link-hidden-']]
 if sheet:expected += [prefix+f'{s}-{stage}' for s in [1,2] for stage in ['pending','uncertain','rejected','complete'] for prefix in ['sheet-native-key-loop-','sheet-pending-admission-','sheet-controls-bounded-','sheet-full-feedback-fits-']]
 expected += ['paint-'+name+f'-{s}-{appearance}' for s in [1,2] for appearance in ['light','dark'] for name in ['url-square-idle','url-cyan-focus-boundary','url-muted-disabled','native-editor-selection','chooser-full-square-cell','chooser-full-flat-surface','chooser-native-held-feedback','chooser-muted-disabled','native-popup-semantics']]
 expected += ['history-'+name+f'-{s}' for s in [1,2] for name in ['labeled-separate-current-feedback','truthful-provider-url-time','full-native-disclosure','exact-selection-without-outcome-binding']]
 from collections import Counter
 receipt=dict(passed=built.returncode==0 and ran is not None and ran.returncode==0 and Counter(passes)==Counter(expected),passes=passes,expected=expected,failures=[x[5:] for x in lines if x.startswith('FAIL ')],compile_exit=built.returncode,run_exit=ran.returncode if ran else None,skips=0,argv=argv,TMPDIR=os.environ.get('TMPDIR'),probe_sha256=hashlib.sha256(p.read_bytes()).hexdigest())
 receipt['test_sha256']=hashlib.sha256(Path(__file__).read_bytes()).hexdigest();receipt['helper_sha256']=hashlib.sha256(helper.encode()).hexdigest()
 (out/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print((out/'compile.log').read_text());print((out/'run.log').read_text());return receipt['passed']
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--source-root',type=Path,default=ROOT);p.add_argument('--output',type=Path,required=True);a=p.parse_args();raise SystemExit(0 if run(a.source_root,a.output) else 1)
