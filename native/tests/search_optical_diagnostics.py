#!/usr/bin/env python3
"""Collect window-free native search controls; never approve product alignment.

The current production controls execute the unchanged native optical predicates.
The falsified image-metadata experiment is retired. Controls are copied below the
fresh output directory without adding or replacing production methods.
A collected optical failure is diagnostic data, not a successful product gate.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
from typing import TypedDict

ROOT = Path(__file__).resolve().parents[2]
DEPENDENCIES = ['LibraryDockView.swift', 'SoundQControls.swift', 'SoundQTokens.swift', 'NativeAssets.swift']

PROBE = r'''
import AppKit
import CoreText
struct Track: Decodable {
    let id: Int64
    let title: String
    let artist: String?
    let duration_ms: UInt64?
}
struct Occurrence: Decodable { let id: UInt64; let track: Track }
struct Snapshot: Decodable {
    let epoch: UInt64
    let session: UInt64
    let revision: UInt64
    let authenticated: Bool
    var library: [Track]
    let library_unchanged: Bool
    let total: UInt64
    var queue: [Occurrence]
    let queue_unchanged: Bool
    let selected_occurrence: UInt64?
    let transport: String
    let position_ms: UInt64
    let duration_ms: UInt64
    let error: String?
    // Core load_occurrence sets selected_occurrence before preparing and marks
    // transport failed on preparation refusal; AudioReport.failed does likewise.
    // Ordinary Library/auth/save errors alone are not playback failures.
    var canRetryPlayback: Bool {authenticated && transport == "failed" && selected_occurrence != nil}
}
let assets=try NativeAssets.load(root:URL(fileURLWithPath:CommandLine.arguments[1]))
@MainActor func raster(_ field:NSSearchField,_ backing:Int,_ mode:String)->NSBitmapImageRep {
 let b=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(field.bounds.width)*backing,pixelsHigh:Int(field.bounds.height)*backing,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!

 if mode=="cache" {field.cacheDisplay(in:field.bounds,to:b);return b}
 NSGraphicsContext.saveGraphicsState();let c=NSGraphicsContext(bitmapImageRep:b)!
 NSGraphicsContext.current=NSGraphicsContext(cgContext:c.cgContext,flipped:true)
 c.cgContext.scaleBy(x:CGFloat(backing),y:CGFloat(backing));c.cgContext.translateBy(x:0,y:field.bounds.height);c.cgContext.scaleBy(x:1,y:-1)
 if mode=="appearanceCell" {field.effectiveAppearance.performAsCurrentDrawingAppearance {field.cell!.draw(withFrame:field.bounds,in:field)}} else {field.cell!.draw(withFrame:field.bounds,in:field)}
 c.cgContext.flush();NSGraphicsContext.restoreGraphicsState();return b
}
@MainActor func stats(_ b:NSBitmapImageRep,_ rect:NSRect,_ backing:Int)->[String:Any] {
 var count=0,first=b.pixelsHigh,last = -1,sum:CGFloat=0,weight:CGFloat=0,rows=[[String:Any]]()
 for y in 0..<b.pixelsHigh {
  var n=0,w:CGFloat=0
  for x in max(0,Int(rect.minX*CGFloat(backing)))..<min(b.pixelsWide,Int(rect.maxX*CGFloat(backing))) {
   let a=b.colorAt(x:x,y:y)!.alphaComponent
   if a>0.1 {count+=1;n+=1;first=min(first,y);last=max(last,y);sum+=CGFloat(y)*a;weight+=a;w+=a}
  }
  if n>0 {rows.append(["y":y,"count":n,"alpha":w])}
 }
 return ["count":count,"first":first,"last":last,"mid":CGFloat(first+last)/CGFloat(2*backing),"height":CGFloat(last-first+1)/CGFloat(backing),"alphaCentroid":weight>0 ? sum/weight/CGFloat(backing):0,"rows":rows]
}

var failures=[String](),passed=[String]()
@MainActor func check(_ name:String,_ value:Bool) {if value {passed.append(name);print("PASS",name)} else {failures.append(name);print("FAIL",name)}}
for scale:CGFloat in [1,2] {for backing in [1,2] {
 for content in ["Search your library","Native search Ω","Hg"] {for placeholder in [true,false] {
 let root=NSView(frame:NSRect(x:0,y:0,width:960,height:900));root.appearance=NSAppearance(named:.aqua)
 let field=SoundQSearchField(frame:NSRect(x:0,y:0,width:831,height:40*scale));root.addSubview(field)
 field.font=NativeAssets.font(14,scale:scale);field.placeholderString=content;field.stringValue=placeholder ? "" : content;field.isBezeled=false;field.drawsBackground=false
 let cell=field.cell as! NSSearchFieldCell
 let text=cell.searchTextRect(forBounds:field.bounds),glyph=cell.searchButtonRect(forBounds:field.bounds),cancel=cell.cancelButtonRect(forBounds:field.bounds),button=cell.searchButtonCell!,image=button.image!
 let b=raster(field,backing,"cell"),t=stats(b,text,backing),g=stats(b,glyph,backing)
 let line=CTLineCreateWithAttributedString(NSAttributedString(string:content,attributes:[.font:field.font!]))
 let path=CTLineGetBoundsWithOptions(line,[.useGlyphPathBounds])
 let record:[String:Any]=["scale":scale,"backing":backing,"content":content,"placeholder":placeholder,"text":t,"glyph":g,"textRect":NSStringFromRect(text),"glyphRect":NSStringFromRect(glyph),"cancelRect":NSStringFromRect(cancel),"font":field.font!.description,"glyphPath":NSStringFromRect(path),"fontCapHeight":field.font!.capHeight,"fontXHeight":field.font!.xHeight,"imageSize":NSStringFromSize(image.size),"imageAlignmentRect":NSStringFromRect(image.alignmentRect),"nativeImageRect":NSStringFromRect(button.imageRect(forBounds:glyph)),"window":field.window != nil,"singleLine":cell.usesSingleLineMode]
 print("CONTROL",String(data:try! JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),encoding:.utf8)!)
 let tag="\(Int(scale))-\(backing)-\(content)-\(placeholder)"
 check("optical-"+tag,(t["count"] as! Int)>(content=="Hg" ? 0 : 100) && (g["count"] as! Int)>20 && abs((t["mid"] as! CGFloat)-(g["mid"] as! CGFloat))<=3)
 check("geometry-policy-"+tag,text.height==ceil(field.font!.ascender-field.font!.descender+field.font!.leading) && text.midY==field.bounds.midY && cell.usesSingleLineMode && cell.isScrollable && !cell.wraps)
 let url=URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent("control-\(Int(scale))-\(backing)-\(content)-\(placeholder).png")
 try! b.representation(using:.png,properties:[:])!.write(to:url,options:.withoutOverwriting)
 }
 }
}}
print("MINIMAL_PASS \(passed.count) failures=\(failures.count)");if !failures.isEmpty {exit(1)}
'''


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class CommandResult(TypedDict):
    argv: list[str]
    exit: int
    stdout: str
    stderr: str


def command(argv, cwd, timeout) -> CommandResult:
    result = subprocess.run(list(map(str, argv)), cwd=cwd, capture_output=True, text=True, timeout=timeout)
    return CommandResult(argv=list(map(str, argv)), exit=result.returncode, stdout=result.stdout, stderr=result.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-root', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root, output = args.source_root.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    sources = root / 'native/macos/Sources'
    production = (sources / 'SoundQControls.swift').read_text()
    inputs = {name: digest(sources / name) for name in DEPENDENCIES}
    resources = {str(p.relative_to(sources / 'Resources')): digest(p)
                 for p in (sources / 'Resources').rglob('*') if p.is_file()}
    if not resources:
        raise RuntimeError('Native resource inventory is empty')
    context = dict(classification='Native cell-only window-free rasters, not screenshots or focused/full-app proof',
                   productionUnchanged=True, diagnosticOnly=True, inputs=inputs, resources=resources,
                   compiler=command(['/usr/bin/swiftc', '--version'], root, 20),
                   host=command(['/usr/bin/sw_vers'], root, 20))
    (output / 'context.json').write_text(json.dumps(context, indent=2) + '\n')
    results = []
    for label, controls in [('production', production)]:
        stage = output / label
        stage.mkdir()
        control = stage / 'SoundQControls.swift'
        control.write_text(controls)
        probe = stage / 'main.swift'
        probe.write_text(PROBE)
        dependencies = [control if name == 'SoundQControls.swift' else sources / name for name in DEPENDENCIES]
        argv = ['/usr/bin/swiftc', '-swift-version', '6', '-j', '2', '-num-threads', '2',
                '-module-cache-path', output / 'modules', '-target', 'arm64-apple-macosx14.0',
                *dependencies, probe, '-o', stage / 'probe']
        compiled = command(argv, root, 240)
        (stage / 'compile.log').write_text(compiled['stdout'] + compiled['stderr'])
        receipt: dict[str, object] = dict(controlsSHA=digest(control), probeSHA=digest(probe), inputs=inputs, compile=compiled)
        if compiled['exit'] != 0:
            (stage / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
            raise RuntimeError('Native diagnostic compilation failed: ' + label)
        receipt['binarySHA'] = digest(stage / 'probe')
        macho = command(['/usr/bin/otool', '-l', stage / 'probe'], root, 30)
        receipt['macho'] = macho
        if macho['exit'] != 0:
            raise RuntimeError('Native binary annotations unavailable')
        (stage / 'macho.log').write_text(macho['stdout'])
        ran = command([stage / 'probe', sources / 'Resources', stage], root, 100)
        (stage / 'runtime.log').write_text(ran['stdout'] + ran['stderr'])
        passes = [line[5:] for line in ran['stdout'].splitlines() if line.startswith('PASS ')]
        failures = [line[5:] for line in ran['stdout'].splitlines() if line.startswith('FAIL ')]
        terminal = 'MINIMAL_PASS ' + str(len(passes)) + ' failures=' + str(len(failures))
        images = list(stage.glob('control-*.png'))
        # Expected production optical failure is retained as data. Missing
        # cases, crash, compile failure or an incomplete artifact is a collector failure.
        if len(passes) + len(failures) != 48 or terminal not in ran['stdout'].splitlines() or len(images) != 24 or ran['exit'] != int(bool(failures)):
            receipt['run'] = ran
            (stage / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
            raise RuntimeError('Incomplete native diagnostic: ' + label)
        receipt.update(run=ran, passes=passes, failures=failures, images={p.name:digest(p) for p in images})
        (stage / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        results.append(dict(label=label, nativeExit=ran['exit'], passes=len(passes), failures=failures, receiptSHA=digest(stage / 'receipt.json')))
    if any(digest(sources / name) != value for name, value in inputs.items()):
        raise RuntimeError('Production source changed during diagnostic')
    summary = dict(collectionComplete=True, diagnosticOnly=True, productGatePassed=False,
                   productionControls=results, productionInputsUnchanged=True)
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
