#!/usr/bin/env python3
"""Actual production Library/dock in unattached AppKit; no app/window/audio launch.

Compiles the mounted production builder, apply and reusable rows with all four
production presentation files. Resources are verified/registered process-only.
This is geometry/publication proof, not screenshot, input, motion or design approval.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from native_review_regressions import swift_block

ROOT = Path(__file__).resolve().parents[2]
FILES = ['LibraryDockView.swift', 'SoundQControls.swift', 'SoundQTokens.swift', 'NativeAssets.swift', 'AuthForm.swift']
TYPES = ['struct Track:', 'struct Occurrence:', 'struct Snapshot:']
HARNESS = r'''
import AppKit
__TYPES__
final class CountingTable:NSTableView {var reloads=0;override func reloadData(){reloads+=1;super.reloadData()}}
@MainActor final class App:NSObject,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate {
 var table=CountingTable();var titleLabel=NSTextField(labelWithString:"Library");var status=NSTextField(labelWithString:"");var transportLabel=NSTextField(labelWithString:"No selection")
 var email=NSTextField();var password=NSSecureTextField();var endpoint=NSTextField();var search=SoundQSearchField();var slider=NSSlider(value:0,minValue:0,maxValue:1,target:nil,action:nil)
 var loginArea=NSStackView();var libraryArea=NSStackView();var play=SoundQButton(title:"Play",target:nil,action:nil);var logout=SoundQButton(title:"Sign out",target:nil,action:nil);var scroll=NSScrollView()
 var libraryDock:LibraryDockView?;var dockTrackID:Int64?;var snapshot:Snapshot?;var epoch:UInt64=1;var accountScope:UInt64=1
 var libraryLikedControl=SoundQButton(title:"Liked",target:nil,action:nil)
 var libraryDetailsMenuItem:NSMenuItem?
 var libraryDetails=SoundQButton(title:"Full details",target:nil,action:nil);var libraryDetailsAction:LibraryMetadataAction?;var libraryDetailsAlert:(alert:NSAlert,action:LibraryMetadataAction)?
 var commands=[[String:Any]]();func command(_ value:[String:Any]) {commands.append(value)}
 var window:NSWindow!;func closeQueueName(){}
 func reconcileQueueName(_ s:Snapshot){}
 @objc func signOut(){};@objc func signIn(){};@objc func refresh(){};@objc func loadMore(){};@objc func selectTrack(){};@objc func previousTrack(){};@objc func nextTrack(){};@objc func showQueue(){};@objc func toggle(){};@objc func seek(){}
 __METHODS__
}
var failures=[String]();var named=[String]()
@MainActor func check(_ name:String,_ value:Bool){if !value {failures.append(name);print("FAIL \(name)")} else {named.append(name);print("PASS \(name)")}}
let assets=try NativeAssets.load(root:URL(fileURLWithPath:CommandLine.arguments[1]))
let a=App();let host=NSView(frame:NSRect(x:0,y:0,width:1200,height:700));a.mountLibraryDock(in:host,assets:assets)
let shell=a.libraryDock!;shell.reduceMotion = true
if let item=a.makeLibraryMenu().items.first {
 check("native-library-menu-recognized-command-i",item.keyEquivalent=="i" && item.keyEquivalentModifierMask == [.command] && item.target === a && item.action == #selector(App.openLibraryDetailsFromMenu(_:)))
}
__METADATA_GEOMETRY__
@MainActor func sample(_ title:String="Title",_ artist:String="Artist",_ duration:UInt64=30000)->Snapshot {
 let t=Track(id:7,title:title,artist:artist,duration_ms:duration)
 return Snapshot(epoch:1,session:1,revision:1,authenticated:true,library:[t],library_unchanged:false,total:1,queue:[Occurrence(id:UInt64.max,track:t)],queue_unchanged:false,selected_occurrence:UInt64.max,transport:"paused",position_ms:0,duration_ms:duration,error:nil)
}
a.apply(sample());host.layoutSubtreeIfNeeded();shell.layoutSubtreeIfNeeded()

// Discover the mounted native control through existing AppKit types, rather
// than compiling against a proposed App method/property that does not exist.
// This is a mounted-control contract; callback/dispatch ownership needs the
// separate production-caller cases described in the preparation handoff.
let likedControls=shell.bodyDocument.subviews.compactMap {$0 as? SoundQButton}.filter {$0.title=="Liked"}
check("liked-filter-one-mounted-labeled-control",likedControls.count==1)
if let liked=likedControls.first {
 check("liked-filter-current-app-target-action",liked.target === a && liked.action != nil && a.responds(to:liked.action!))
 check("liked-filter-default-acknowledged-all",!liked.selected)
 for scale:CGFloat in [1,2] {for width:CGFloat in [760,960,1200,1440] {
  shell.textScale=scale;host.setFrameSize(NSSize(width:width,height:900));shell.frame=host.bounds;shell.needsLayout=true;shell.layoutSubtreeIfNeeded()
  let tag="\(Int(width))-\(Int(scale))",cell=liked.cell!,full=cell.cellSize
  for button in [shell.controls.refresh,shell.controls.more,shell.controls.select,shell.controls.details,shell.controls.retry,liked] {
   let native=button.cell!.cellSize,intrinsic=button.intrinsicContentSize
   let metric:[String:Any] = ["case":tag,"title":button.title,"frame":NSStringFromRect(button.frame),"nativeWidth":native.width,"nativeHeight":native.height,"intrinsicWidth":intrinsic.width,"intrinsicHeight":intrinsic.height,"font":button.font!.pointSize]
   print("SECONDARY_CELL",String(data:try! JSONSerialization.data(withJSONObject:metric,options:[.sortedKeys]),encoding:.utf8)!)
   check("secondary-full-native-label-cell-"+button.title+"-"+tag,button.frame.width>=native.width && button.frame.height>=native.height)
  }
  check("liked-filter-full-native-label-cell-"+tag,liked.frame.width>=full.width && liked.frame.height>=full.height && liked.frame.height>=40*scale)
  check("liked-filter-shares-secondary-height-"+tag,liked.frame.height==shell.controls.refresh.frame.height && liked.font?.pointSize==shell.controls.refresh.font?.pointSize)
  check("liked-filter-inside-document-grid-"+tag,liked.frame.minX>=0 && liked.frame.maxX<=shell.bodyDocument.bounds.width && liked.frame.minY>=0 && abs(liked.frame.minX/4-(liked.frame.minX/4).rounded())<0.01)
  check("liked-filter-no-toolbar-overlap-"+tag,![shell.controls.search,shell.controls.refresh,shell.controls.more,shell.controls.select,shell.controls.details,shell.controls.retry].contains {liked.frame.intersects($0.frame)})
 }}
}
shell.textScale=1;host.setFrameSize(NSSize(width:1200,height:700));shell.frame=host.bounds;shell.needsLayout=true;shell.layoutSubtreeIfNeeded()

// Round3 native paint/full-cell/reflow regressions. No window or input synthesis.
// Native glyph-body regression, not centered-line-rectangle inference.
@MainActor func searchRaster(_ field:NSSearchField,_ backing:Int)->NSBitmapImageRep {
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(field.bounds.width)*backing,pixelsHigh:Int(field.bounds.height)*backing,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();let base=NSGraphicsContext(bitmapImageRep:bitmap)!
 NSGraphicsContext.current=NSGraphicsContext(cgContext:base.cgContext,flipped:true)
 base.cgContext.scaleBy(x:CGFloat(backing),y:CGFloat(backing));base.cgContext.translateBy(x:0,y:field.bounds.height);base.cgContext.scaleBy(x:1,y:-1)
 field.cell!.draw(withFrame:field.bounds,in:field)
 base.cgContext.flush();NSGraphicsContext.restoreGraphicsState();return bitmap
}
@MainActor func ink(_ bitmap:NSBitmapImageRep,_ bounds:NSRect,_ backing:Int)->(count:Int,mid:CGFloat,height:CGFloat) {
 var count=0,first=bitmap.pixelsHigh,last = -1
 for y in 0..<bitmap.pixelsHigh {for x in max(0,Int(bounds.minX*CGFloat(backing)))..<min(bitmap.pixelsWide,Int(bounds.maxX*CGFloat(backing))) {
  if bitmap.colorAt(x:x,y:y)!.alphaComponent>0.1 {count+=1;first=min(first,y);last=max(last,y)}
 }}
 return (count,CGFloat(first+last)/CGFloat(2*backing),CGFloat(last-first+1)/CGFloat(backing))
}
for scale:CGFloat in [1,2] {
 shell.textScale=scale;host.setFrameSize(NSSize(width:960,height:900));shell.frame=host.bounds;shell.needsLayout=true;shell.layoutSubtreeIfNeeded()
 let cell=a.search.cell as! NSSearchFieldCell
 for value in ["","Native search Ω"] {for backing in [1,2] {
  a.search.stringValue=value;let single=cell.usesSingleLineMode
  let bitmap=searchRaster(a.search,backing),text=cell.searchTextRect(forBounds:a.search.bounds),glyph=cell.searchButtonRect(forBounds:a.search.bounds)
  let t=ink(bitmap,text,backing),g=ink(bitmap,glyph,backing),tag="\(Int(scale))-\(value.isEmpty ? "placeholder" : "typed")-\(backing)"
  print("SEARCH_INK",tag,"glyph",g,"text",t)
  // Preserve the exact measured native cell raster on hosted OS variants.
  // This is diagnostic output only: no redraw, metric or threshold change.
  if CommandLine.arguments.count>2 {
   let output=URL(fileURLWithPath:CommandLine.arguments[2]).appendingPathComponent("search-raster",isDirectory:true)
   try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
   let png=bitmap.representation(using:.png,properties:[:])!
   try png.write(to:output.appendingPathComponent(tag+".png"),options:.withoutOverwriting)
   func metric(_ value:(count:Int,mid:CGFloat,height:CGFloat))->[String:Any] {["count":value.count,"mid":value.mid,"height":value.height]}
   let record:[String:Any] = ["case":tag,"class":"native cell-only raster, not external screenshot","text":value,"scale":scale,"backing":backing,"pixels":[bitmap.pixelsWide,bitmap.pixelsHigh],"textInk":metric(t),"glyphInk":metric(g),"opticalThreshold":3,"bounds":NSStringFromRect(a.search.bounds),"textRect":NSStringFromRect(text),"glyphRect":NSStringFromRect(glyph),"fontName":a.search.font!.fontName,"fontPointSize":a.search.font!.pointSize,"fontMetrics":[a.search.font!.ascender,a.search.font!.descender,a.search.font!.leading],"appearance":a.search.effectiveAppearance.name.rawValue,"singleLine":cell.usesSingleLineMode,"windowAttached":a.search.window != nil]
   try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.prettyPrinted]).write(to:output.appendingPathComponent(tag+".json"),options:.withoutOverwriting)
  }
  check("optical-nonempty-native-glyph-text-"+tag,t.count>100 && g.count>20)
  check("optical-native-text-glyph-track-"+tag,t.count>0 && g.count>0 && abs(t.mid-g.mid)<=3)
  check("optical-retains-single-line-policy-"+tag,single && cell.usesSingleLineMode && !cell.wraps)
 }}
}

let editorDelegate=NSObject()
for scale:CGFloat in [1,2] {
 shell.textScale=scale;shell.layoutSubtreeIfNeeded()
 let cell=a.search.cell as! NSSearchFieldCell
 for value in ["Ω cafe e\u{301} 🚀","Long "+String(repeating:"native ",count:40)+"終点"] {
  a.search.stringValue=value
  let track=cell.searchTextRect(forBounds:a.search.bounds),tag="\(Int(scale))-\(value.utf8.count)"
  let editor=NSTextView(frame:.zero)
  cell.select(withFrame:a.search.bounds,in:a.search,editor:editor,delegate:editorDelegate,start:2,length:4)
  check("search-native-selection-delegate-utf8-"+tag,editor.string.utf8.elementsEqual(value.utf8) && editor.selectedRange()==NSRange(location:2,length:4) && editor.delegate === editorDelegate && editor.frame.origin==track.origin && editor.frame.height==track.height && editor.frame.width>=track.width && cell.usesSingleLineMode)
  editor.layoutManager!.ensureLayout(for:editor.textContainer!)
  print("EDITOR_LAYOUT",tag,"font",editor.font!.pointSize,"origin",editor.textContainerOrigin,"inset",editor.textContainerInset,"used",editor.layoutManager!.usedRect(for:editor.textContainer!),"track",track)
  check("search-native-editor-font-layout-"+tag,editor.font!.pointSize==14*scale && editor.textContainerOrigin == .zero && editor.textContainerInset == .zero && editor.layoutManager!.usedRect(for:editor.textContainer!).width>0)
  cell.endEditing(editor);check("search-native-selection-end-detaches-"+tag,editor.superview==nil)
  let edit=NSTextView(frame:.zero)
  cell.edit(withFrame:a.search.bounds,in:a.search,editor:edit,delegate:editorDelegate,event:nil)
  check("search-native-edit-delegate-utf8-"+tag,edit.string.utf8.elementsEqual(value.utf8) && edit.delegate === editorDelegate && edit.frame.origin==track.origin && edit.frame.height==track.height && edit.frame.width>=track.width && cell.usesSingleLineMode)
  cell.endEditing(edit);check("search-native-edit-end-detaches-"+tag,edit.superview==nil)
 }
}
a.search.stringValue=""

for (stage,scale):(Int,CGFloat) in [(0,1),(1,2),(2,1)] {for width:CGFloat in [400,600,879,1000] {for ms:UInt64 in [30000,3600000,360000000] {
 let row=LibraryTrackCell(frame:NSRect(x:0,y:0,width:width,height:56*scale));row.configure(track:Track(id:500,title:"Native Fixture 500",artist:"Synthetic Fixture",duration_ms:ms),current:false,scale:scale);row.layoutSubtreeIfNeeded()
 let field=row.duration,cell=field.cell!,full=cell.cellSize,bounded=cell.cellSize(forBounds:field.bounds),tag="\(stage)-\(Int(scale))-\(Int(width))-\(ms)"
 print("DURATION",tag,"allocated",field.frame,"native",full,"bounded",bounded)
 check("duration-native-full-cell-fits-"+tag,field.frame.width>=full.width && field.frame.height>=full.height)
 check("duration-native-bounded-cell-complete-"+tag,abs(bounded.width-full.width)<0.1 && abs(bounded.height-full.height)<0.1)
 check("duration-preserved-native-font-tracks-"+tag,field.font!.pointSize==11*scale && field.stringValue==LibraryDockView.timestamp(ms) && row.name.frame.maxX<field.frame.minX && field.frame.maxX<=width-8)
}}}

// The table facade models the documented available/in-flight native rows:
// visibility sampling deliberately excludes retained existing rows4/5. Native
// row/cell objects, production typography and later layout remain real AppKit.
final class ReflowTable:NSTableView {
 let retainedRows:[NSTableRowView]
 var requestedCreation=0
 var visibleCount=4
 override init(frame:NSRect) {
  retainedRows=(0..<6).map {i in let row=NSTableRowView(frame:NSRect(x:0,y:CGFloat(i)*56,width:879,height:56));let cell=LibraryTrackCell(frame:row.bounds);cell.configure(track:Track(id:Int64(500-i),title:"Track \(500-i)",artist:"Artist",duration_ms:30000),current:false,scale:1);row.addSubview(cell);return row}
  super.init(frame:frame);for row in retainedRows {addSubview(row)}
 }
 required init?(coder:NSCoder){fatalError()}
 override var numberOfRows:Int {500}
 override func rows(in rect:NSRect)->NSRange {NSRange(location:0,length:visibleCount)}
 override func view(atColumn column:Int,row:Int,makeIfNecessary:Bool)->NSView? {if makeIfNecessary {requestedCreation+=1};return row<visibleCount ? retainedRows[row].subviews.first : nil}
 override func enumerateAvailableRowViews(_ handler:(NSTableRowView,Int)->Void) {for (i,row) in retainedRows.enumerated(){handler(row,i)}}
}
let reflow=ReflowTable(frame:NSRect(x:0,y:0,width:879,height:588))
let reflowOwner=App();let reflowHost=NSView(frame:NSRect(x:0,y:0,width:960,height:900));reflowOwner.mountLibraryDock(in:reflowHost,assets:assets)
let c=reflowOwner.libraryDock!.controls
let borrowed=LibraryDockControls(table:reflow,scroll:c.scroll,search:c.search,slider:c.slider,play:c.play,title:c.title,identity:c.identity,status:c.status,login:c.login,library:c.library,logout:c.logout,refresh:c.refresh,more:c.more,select:c.select,details:c.details,retry:c.retry,previous:c.previous,next:c.next,queue:c.queue)
let reflowDock=LibraryDockView(controls:borrowed,assets:assets)
let cells=reflow.retainedRows.map {$0.subviews.first as! LibraryTrackCell}
let identities=cells.map {ObjectIdentifier($0)},configurations=cells.map {$0.configurations}
for (stage,scale):(Int,CGFloat) in [(0,1),(1,2),(2,1)] {
 reflow.visibleCount=stage==1 ? 6 : 4
 reflowDock.textScale=scale;reflowDock.applyTypography()
 for (i,row) in reflow.retainedRows.enumerated() {row.frame.size.height=56*scale;cells[i].frame=row.bounds;cells[i].needsLayout=true;cells[i].layoutSubtreeIfNeeded()}
 check("typography-every-instantiated-row-\(stage)",cells.allSatisfy {$0.scale==scale && $0.name.font!.pointSize==16*scale && $0.artist.font!.pointSize==12*scale && $0.duration.font!.pointSize==11*scale})
 check("typography-no-instantiation-reconfigure-\(stage)",reflow.requestedCreation==0 && cells.map {ObjectIdentifier($0)}==identities && cells.map {$0.configurations}==configurations)
}

let reentry=App(),reentryHost=NSView(frame:NSRect(x:0,y:0,width:960,height:900));reentry.mountLibraryDock(in:reentryHost,assets:assets);let reentryDock=reentry.libraryDock!
let reentryTracks=(0..<500).map {Track(id:Int64(500-$0),title:"Native Fixture \(500-$0)",artist:"Artist",duration_ms:30000)}
reentry.apply(Snapshot(epoch:1,session:1,revision:1,authenticated:true,library:reentryTracks,library_unchanged:false,total:500,queue:[],queue_unchanged:false,selected_occurrence:nil,transport:"idle",position_ms:0,duration_ms:0,error:nil))
for (stage,scale):(Int,CGFloat) in [(0,1),(1,2),(2,1)] {
 reentryDock.textScale=scale;reentryDock.needsLayout=true;reentryDock.layoutSubtreeIfNeeded();reentryHost.layoutSubtreeIfNeeded()
 for (move,offset):(Int,CGFloat) in [(0,0),(1,400),(2,0)] {
  reentry.scroll.contentView.scroll(to:NSPoint(x:0,y:offset));reentry.scroll.reflectScrolledClipView(reentry.scroll.contentView);reentry.table.layoutSubtreeIfNeeded()
  var available=[LibraryTrackCell]()
  reentry.table.enumerateAvailableRowViews {row,_ in available += row.subviews.compactMap {$0 as? LibraryTrackCell}}
  let tag="\(stage)-\(move)-\(Int(offset))"
  check("native-table-reentry-positive-bounded-"+tag,!available.isEmpty && available.count<50)
  check("native-table-reentry-current-fonts-"+tag,available.allSatisfy {$0.scale==scale && $0.duration.font!.pointSize==11*scale && $0.name.font!.pointSize==16*scale})
 }
}

// Native cache rasters, window-free. AppKit transforms the configured tint in
// legacy appearances; calibrate against an independent enabled stock control,
// never against the product's observed tint or its output bitmap.
@MainActor func sliderBitmap(_ slider:NSSlider,_ backing:Int)->NSBitmapImageRep {
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(slider.bounds.width)*backing,pixelsHigh:Int(slider.bounds.height)*backing,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 bitmap.size=slider.bounds.size
 slider.cacheDisplay(in:slider.bounds,to:bitmap)
 return bitmap
}
@MainActor func barPixel(_ slider:NSSlider,_ bitmap:NSBitmapImageRep,_ x:CGFloat,_ backing:Int)->NSColor {
 var bar=(slider.cell as! NSSliderCell).barRect(flipped:slider.isFlipped)
 if !slider.bounds.contains(bar) || bar.width<=slider.bounds.width/2 || bar.height<=0 {
  // Current-linked disabled cells report a sentinel, not paint coordinates.
  // The native enabled bar establishes only the track, never the value witness.
  let geometry=NSSlider(value:50,minValue:0,maxValue:100,target:nil,action:nil)
  geometry.frame=slider.frame;geometry.appearance=slider.effectiveAppearance;geometry.isEnabled=true;geometry.layoutSubtreeIfNeeded()
  bar=(geometry.cell as! NSSliderCell).barRect(flipped:geometry.isFlipped)
 }
 precondition(slider.bounds.contains(bar) && bar.width>slider.bounds.width/2 && bar.height>0)
 let y=slider.isFlipped ? bar.midY : slider.bounds.height-bar.midY
 return bitmap.colorAt(x:Int(x*CGFloat(backing)),y:Int(y*CGFloat(backing)))!.usingColorSpace(.deviceRGB)!
}
@MainActor func referenceTint(_ appearance:NSAppearance,_ color:NSColor,_ backing:Int)->NSColor {
 let stock=NSSlider(value:100,minValue:0,maxValue:100,target:nil,action:nil)
 stock.frame=NSRect(x:0,y:0,width:400,height:40);stock.appearance=appearance;stock.isEnabled=true;stock.trackFillColor=color;stock.layoutSubtreeIfNeeded()
 return barPixel(stock,sliderBitmap(stock,backing),100,backing)
}
// Disabled native treatments differ: legacy paints a neutral thumb, while
// current-linked cells expose sentinel geometry and a different alpha profile.
// Independently requested stock paint supplies the witness coordinates. Require
// positive native ink and every alpha distinction from BOTH endpoint rasters;
// neither the tested control's value/geometry nor its pixels choose the mask.
@MainActor func disabledValuePaint(_ actual:NSBitmapImageRep,_ appearance:NSAppearance,_ token:NSColor,_ value:Double,_ backing:Int)->(zero:Int,zeroMatched:Int,full:Int,fullMatched:Int) {
 func stock(_ requested:Double)->NSBitmapImageRep {
  let slider=NSSlider(value:requested,minValue:0,maxValue:100,target:nil,action:nil)
  slider.frame=NSRect(x:0,y:0,width:400,height:40);slider.appearance=appearance;slider.isEnabled=false;slider.trackFillColor=token;slider.layoutSubtreeIfNeeded()
  return sliderBitmap(slider,backing)
 }
 let requested=stock(value),zero=stock(0),full=stock(100)
 var zeroCount=0,zeroMatched=0,fullCount=0,fullMatched=0
 for y in 0..<requested.pixelsHigh {for x in 0..<requested.pixelsWide {
  let expected=requested.colorAt(x:x,y:y)!.alphaComponent,z=zero.colorAt(x:x,y:y)!.alphaComponent,f=full.colorAt(x:x,y:y)!.alphaComponent
  let observed=actual.colorAt(x:x,y:y)!.alphaComponent
  if max(expected,z)>0.1 && abs(expected-z)>0.01 {zeroCount+=1;if abs(observed-expected)<0.01 {zeroMatched+=1}}
  if max(expected,f)>0.1 && abs(expected-f)>0.01 {fullCount+=1;if abs(observed-expected)<0.01 {fullMatched+=1}}
 }}
 return (zeroCount,zeroMatched,fullCount,fullMatched)
}
@MainActor func matchingPixels(_ bitmap:NSBitmapImageRep,_ token:NSColor)->Int {
 var result=0
 for y in 0..<bitmap.pixelsHigh {for x in 0..<bitmap.pixelsWide {
  let c=bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
  if c.alphaComponent>0.1 && abs(c.redComponent-token.redComponent)<0.04 && abs(c.greenComponent-token.greenComponent)<0.04 && abs(c.blueComponent-token.blueComponent)<0.04 {result+=1}
 }}
 return result
}
for dark in [true,false] {for enabled in [true,false] {for value in [0.0,50.0,100.0] {for backing in [1,2] {
 let app=App();let host=NSView(frame:NSRect(x:0,y:0,width:960,height:900));app.mountLibraryDock(in:host,assets:assets);let dock=app.libraryDock!
 dock.appearance=NSAppearance(named:dark ? .darkAqua : .aqua);dock.applyColors()
 app.slider.frame=NSRect(x:0,y:0,width:400,height:40);app.slider.isEnabled=enabled;app.slider.minValue=0;app.slider.maxValue=100;app.slider.doubleValue=value;app.slider.layoutSubtreeIfNeeded()
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:400*backing,pixelsHigh:40*backing,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!;bitmap.size=NSSize(width:400,height:40)
 app.slider.cacheDisplay(in:app.slider.bounds,to:bitmap)
 let token=referenceTint(dock.effectiveAppearance,SoundQTokens(dark:dark).primary,backing)
 var primary=0,blue=0,coverage=0
 for y in 0..<40*backing {for x in 0..<400*backing {let c=bitmap.colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
  if c.alphaComponent>0.1 {coverage+=1;if abs(c.redComponent-token.redComponent)<0.04 && abs(c.greenComponent-token.greenComponent)<0.04 && abs(c.blueComponent-token.blueComponent)<0.04 {primary+=1};if c.blueComponent>0.6 && c.redComponent<0.5 {blue+=1}}
 }}
 let tag="\(dark)-\(enabled)-\(Int(value))-\(backing)"
 print("PROGRESS_INK",tag,"primary",primary,"blue",blue,"coverage",coverage)
 check("progress-positive-native-paint-"+tag,coverage>20)
 check("progress-semantic-native-paint-"+tag,enabled && value>0 ? primary>100 && blue==0 : primary==0 && blue==0)
 let cell=app.slider.cell as! NSSliderCell
 let stock=NSSlider(value:value,minValue:0,maxValue:100,target:nil,action:nil);stock.frame=app.slider.frame;stock.isEnabled=enabled;stock.appearance=dock.effectiveAppearance;stock.layoutSubtreeIfNeeded();let stockCell=stock.cell as! NSSliderCell
 check("progress-native-thumb-bar-geometry-"+tag,cell.knobRect(flipped:app.slider.isFlipped)==stockCell.knobRect(flipped:stock.isFlipped) && cell.barRect(flipped:app.slider.isFlipped)==stockCell.barRect(flipped:stock.isFlipped))
 let played=barPixel(app.slider,bitmap,100,backing),unplayed=barPixel(app.slider,bitmap,300,backing)
 var disabledMidpoint=false
 if !enabled && value==50 {
  let witness=disabledValuePaint(bitmap,dock.effectiveAppearance,SoundQTokens(dark:dark).primary,value,backing)
  print("PROGRESS_DISABLED_VALUE_WITNESS",tag,witness)
  disabledMidpoint=witness.zero>20 && witness.full>20 && witness.zeroMatched==witness.zero && witness.fullMatched==witness.full
 }
 print("PROGRESS_NATIVE_SAMPLE",tag,"bar",cell.barRect(flipped:app.slider.isFlipped),"expected",token,"played",played,"unplayed",unplayed)
 check("progress-value-driven-segment-"+tag,value==0 ? played.alphaComponent<0.2 && unplayed.alphaComponent<0.2 : value==50 ? (enabled ? played.alphaComponent>unplayed.alphaComponent : disabledMidpoint) : abs(played.alphaComponent-unplayed.alphaComponent)<0.01)
 if enabled && value==50 {
  for (name,color):(String,NSColor?) in [("uncolored",nil),("blue",.blue),("wrong-green",.green)] {
   let negative=NSSlider(value:value,minValue:0,maxValue:100,target:nil,action:nil)
   negative.frame=app.slider.frame;negative.appearance=dock.effectiveAppearance;negative.isEnabled=true;negative.trackFillColor=color;negative.layoutSubtreeIfNeeded()
   let rejected=sliderBitmap(negative,backing),negativePlayed=barPixel(negative,rejected,100,backing)
   check("progress-semantic-rejects-"+name+"-"+tag,matchingPixels(rejected,token)==0 && negativePlayed.alphaComponent>0.9)
  }
 }
 check("progress-native-input-contract-"+tag,type(of:app.slider)==NSSlider.self && type(of:cell)==NSSliderCell.self && app.slider.target === app && app.slider.action == #selector(App.seek) && !app.slider.isContinuous && app.slider.accessibilityLabel()=="Playback position" && app.slider.isEnabled==enabled && app.slider.doubleValue==value)
}}}}

// Device/window-free native field-editor recovery: actual cell select/edit,
// insertion/navigation, native layout and clip scrolling. Not OS-input pixels.
let recoverySample="BEGIN42 夜 Ω café e\u{301} 🚀 — "+(1...14).map {"移動\($0) ensemble"}.joined(separator:" / ")+" — END42"
let recoveryShort="BEGIN42 夜 Ω café e\u{301} 🚀 END42"
@MainActor func insertionX(_ editor:NSTextView)->CGFloat? {
 let manager=editor.layoutManager!,end=editor.string.utf16.count
 let count=manager.getLineFragmentInsertionPoints(forCharacterAt:max(0,end-1),alternatePositions:false,inDisplayOrder:false,positions:nil,characterIndexes:nil)
 var points=[CGFloat](repeating:0,count:count),indices=[Int](repeating:0,count:count)
 _=manager.getLineFragmentInsertionPoints(forCharacterAt:max(0,end-1),alternatePositions:false,inDisplayOrder:false,positions:&points,characterIndexes:&indices)
 return zip(points,indices).first {$0.1==end}?.0
}
@MainActor func recoveryRasterInk(_ editor:NSTextView,_ suffix:NSRect)->Int {
 let visible=editor.visibleRect,backing=2
 let width=Int(ceil(visible.width))*backing,height=Int(ceil(visible.height))*backing
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();let context=NSGraphicsContext(bitmapImageRep:bitmap)!
 NSGraphicsContext.current=NSGraphicsContext(cgContext:context.cgContext,flipped:true)
 context.cgContext.scaleBy(x:2,y:2);context.cgContext.translateBy(x:0,y:CGFloat(height)/2);context.cgContext.scaleBy(x:1,y:-1)
 context.cgContext.clip(to:NSRect(origin:.zero,size:visible.size))
 let suffixRange=editor.layoutManager!.glyphRange(forCharacterRange:NSRange(location:editor.string.utf16.count-5,length:5),actualCharacterRange:nil)
 editor.layoutManager!.drawGlyphs(forGlyphRange:suffixRange,at:NSPoint(x:-visible.minX,y:-visible.minY))
 context.cgContext.flush();NSGraphicsContext.restoreGraphicsState()
 let projected=suffix.offsetBy(dx:-visible.minX,dy:-visible.minY),lowX=max(0,Int(floor(projected.minX))*backing),highX=min(width,Int(ceil(projected.maxX))*backing)
 guard lowX<highX else{return 0}
 var count=0
 for y in 0..<height {for x in lowX..<highX {if bitmap.colorAt(x:x,y:y)!.alphaComponent>0.1 {count+=1}}}
 return count
}
for scale:CGFloat in [1,2] {for selectionEntry in [true,false] {for value in [recoveryShort,recoverySample] {
 let owner=NSView(frame:NSRect(x:0,y:0,width:960,height:900)),field=SoundQSearchField(frame:NSRect(x:105,y:700,width:831,height:40*scale))
 owner.addSubview(field);field.font=NativeAssets.font(14,scale:scale);field.isBezeled=false;field.drawsBackground=true
 let cell=field.cell as! NSSearchFieldCell,editor=NSTextView(frame:.zero),delegate=NSObject(),tag="\(Int(scale))-\(selectionEntry ? "select":"edit")-\(value.utf16.count)"
 editor.isFieldEditor=true
 if selectionEntry {cell.select(withFrame:field.bounds,in:field,editor:editor,delegate:delegate,start:0,length:0)} else {cell.edit(withFrame:field.bounds,in:field,editor:editor,delegate:delegate,event:nil)}
 for scalar in value.unicodeScalars {editor.insertText(String(scalar),replacementRange:editor.selectedRange())}
 editor.layoutManager!.ensureLayout(for:editor.textContainer!)
 editor.moveToBeginningOfDocument(nil);editor.scrollRangeToVisible(editor.selectedRange())
 let startVisible=editor.visibleRect
 editor.moveToEndOfDocument(nil);editor.scrollRangeToVisible(editor.selectedRange())
 let manager=editor.layoutManager!,container=editor.textContainer!;manager.ensureLayout(for:container)
 let lastRange=NSRange(location:value.utf16.count-5,length:5),glyphRange=manager.glyphRange(forCharacterRange:lastRange,actualCharacterRange:nil)
 let last=manager.boundingRect(forGlyphRange:glyphRange,in:container),endX=insertionX(editor),visible=editor.visibleRect
 var actual=NSRange();let caret=editor.firstRect(forCharacterRange:editor.selectedRange(),actualRange:&actual)
 print("RECOVERY",tag,"start",startVisible,"end",visible,"container",container.size,"frame",editor.frame,"resizable",editor.isHorizontallyResizable,"scrollable",cell.isScrollable,"suffix",last,"insertionX",endX as Any,"caret",caret)
 check("recovery-native-content-selection-"+tag,editor.string.utf8.elementsEqual(value.utf8) && editor.selectedRange()==NSRange(location:value.utf16.count,length:0))
 check("recovery-native-single-line-scroll-configuration-"+tag,cell.usesSingleLineMode && cell.isScrollable && !cell.wraps && editor.isHorizontallyResizable && !container.widthTracksTextView && container.size.width>field.bounds.width)
 check("recovery-native-ending-glyph-visible-"+tag,last.width>0 && last.height>0 && last.minX>=visible.minX && last.maxX<=visible.maxX && last.intersects(visible))
 check("recovery-native-end-caret-visible-"+tag,endX != nil && endX!>0 && endX!>=visible.minX && endX!<=visible.maxX && abs(endX!-last.maxX)<2 && caret.height>0)
 check("recovery-native-horizontal-navigation-"+tag,value==recoveryShort ? abs(visible.minX-startVisible.minX)<0.1 : visible.minX>startVisible.maxX)
 check("recovery-native-suffix-raster-positive-"+tag,recoveryRasterInk(editor,last)>100)
 editor.setSelectedRange(lastRange);editor.scrollRangeToVisible(lastRange)
 let selected=editor.firstRect(forCharacterRange:lastRange,actualRange:&actual)
 check("recovery-native-end-selection-geometry-"+tag,selected.width>0 && selected.height>0 && last.minX>=editor.visibleRect.minX && last.maxX<=editor.visibleRect.maxX && last.intersects(editor.visibleRect) && editor.selectedRange()==lastRange)
 let beforePaint=editor.visibleRect;_=searchRaster(field,2)
 check("recovery-native-paint-policy-stable-"+tag,cell.usesSingleLineMode && !cell.wraps && editor.visibleRect==beforePaint && editor.isFieldEditor && editor.delegate === delegate && editor.font!.pointSize==14*scale)
 editor.moveToBeginningOfDocument(nil);editor.scrollRangeToVisible(editor.selectedRange())
 check("recovery-native-return-to-prefix-"+tag,abs(editor.visibleRect.minX-startVisible.minX)<0.1 && editor.selectedRange()==NSRange(location:0,length:0))
 cell.endEditing(editor);check("recovery-native-end-editing-detaches-"+tag,editor.superview==nil)
}}}

a.search.stringValue="";shell.textScale=1;host.setFrameSize(NSSize(width:1200,height:700));shell.frame=host.bounds;shell.needsLayout=true;shell.layoutSubtreeIfNeeded()

// V1: production native cell drawing/editor allocation, not a replacement input.
for scale:CGFloat in [1,2] {
 shell.textScale=scale;host.setFrameSize(NSSize(width:1100,height:760));shell.frame=host.bounds;shell.needsLayout=true;shell.layoutSubtreeIfNeeded()
 for value in ["", "Native search Ω"] {
  a.search.stringValue=value
  let cell=a.search.cell as! NSSearchFieldCell, bounds=a.search.bounds
  let text=cell.searchTextRect(forBounds:bounds), glyph=cell.searchButtonRect(forBounds:bounds), cancel=cell.cancelButtonRect(forBounds:bounds)
  let tag="\(Int(scale))-\(value.isEmpty ? "placeholder" : "typed")"
  check("search-centered-text-"+tag,abs(text.midY-bounds.midY)<=1 && text.height<=ceil(a.search.font!.ascender-a.search.font!.descender+a.search.font!.leading)+2)
  check("search-centered-native-glyphs-"+tag,abs(glyph.midY-text.midY)<=1 && abs(cancel.midY-text.midY)<=1)
  check("search-separated-native-regions-"+tag,text.minX>=glyph.maxX-2 && text.maxX<=cancel.minX+2 && bounds.contains(text) && bounds.contains(glyph) && bounds.contains(cancel))
  check("search-drawing-uses-native-text-track-"+tag,cell.drawingRect(forBounds:bounds)==text && cell.titleRect(forBounds:bounds)==text)
  if !value.isEmpty {
   let editor=NSTextView(frame:.zero)
   cell.select(withFrame:bounds,in:a.search,editor:editor,delegate:nil,start:2,length:4)
   check("search-native-selection-editor-track-"+tag,editor.frame==text && editor.string==value && editor.selectedRange()==NSRange(location:2,length:4))
   cell.endEditing(editor)
   let edit=NSTextView(frame:.zero)
   cell.edit(withFrame:bounds,in:a.search,editor:edit,delegate:nil,event:nil)
   check("search-native-edit-editor-track-"+tag,edit.frame==text && edit.string==value)
   cell.endEditing(edit)
  }
 }
 check("search-no-exterior-platform-ring-\(Int(scale))",a.search.focusRingType == .none && a.search.cell!.focusRingType == .none)
 check("search-native-editing-ownership-\(Int(scale))",a.search.isEditable && a.search.isSelectable && a.search.delegate === a && (a.search.cell as! NSSearchFieldCell).searchButtonCell != nil && (a.search.cell as! NSSearchFieldCell).cancelButtonCell != nil)
}
a.search.stringValue="";shell.textScale=1;host.setFrameSize(NSSize(width:1200,height:700));shell.frame=host.bounds;shell.needsLayout=true;shell.layoutSubtreeIfNeeded()

let initial=a.table.reloads
a.apply(sample("Title","Updated artist"));check("artist-only-real-content-reload",a.table.reloads==initial+1)
let artist=a.table.reloads;a.apply(sample("Title","Updated artist",42000));check("duration-only-real-content-reload",a.table.reloads==artist+1)
let duration=a.table.reloads;a.apply(sample("Caf\u{e9}","Updated artist",42000));a.apply(sample("Cafe\u{301}","Updated artist",42000));check("normalization-only-title-reload",a.table.reloads==duration+2)
let before=a.table.reloads, chrome=shell.chromeEntries, identity=shell.identityAnimations, treatment=shell.rowTreatmentEntries, progress=shell.progressEntries
let configured=(a.table.view(atColumn:0,row:0,makeIfNecessary:true) as? LibraryTrackCell)?.configurations
check("scalar-probe-has-real-mounted-row",configured != nil && configured!>0)
for i in 1...120 {
 a.apply(Snapshot(epoch:1,session:1,revision:UInt64(i+1),authenticated:true,library:[],library_unchanged:true,total:1,queue:[],queue_unchanged:true,selected_occurrence:UInt64.max,transport:"paused",position_ms:UInt64(i),duration_ms:42000,error:nil))
}
check("120-scalar-publications-no-reload",a.table.reloads==before)
check("120-scalar-publications-no-chrome-entry",shell.chromeEntries==chrome)
check("120-scalar-publications-no-identity-animation-entry",shell.identityAnimations==identity)
check("120-scalar-publications-no-row-treatment-entry",shell.rowTreatmentEntries==treatment)
check("120-scalar-publications-no-row-configurations",(a.table.view(atColumn:0,row:0,makeIfNecessary:false) as? LibraryTrackCell)?.configurations==configured)
check("120-scalar-publications-progress-entry-counter",shell.progressEntries==progress+120)
check("scalar-hydration-and-full-width-occurrence",a.snapshot?.selected_occurrence==UInt64.max && a.snapshot?.library.count==1 && a.snapshot?.queue.count==1)
check("scalar-progress-real-slider",a.slider.doubleValue==120)
a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.apply(sample("New title"));check("browse-selection-preserved-by-id",a.table.selectedRow==0)
let pagingReloads=a.table.reloads,pagingChrome=shell.chromeEntries
func paging(_ total:UInt64,_ auth:Bool=true) -> Snapshot {Snapshot(epoch:1,session:1,revision:999,authenticated:auth,library:[],library_unchanged:true,total:total,queue:[],queue_unchanged:true,selected_occurrence:UInt64.max,transport:"paused",position_ms:0,duration_ms:30000,error:nil)}
a.apply(paging(2));check("total-only-increase-enables-more",shell.controls.more.isEnabled)
check("total-only-no-reload-no-chrome",a.table.reloads==pagingReloads && shell.chromeEntries==pagingChrome)
let pageTrack=a.snapshot!.library[0]
a.apply(Snapshot(epoch:1,session:1,revision:1000,authenticated:true,library:[pageTrack,Track(id:8,title:"Peer",artist:nil,duration_ms:nil)],library_unchanged:false,total:3,queue:[],queue_unchanged:true,selected_occurrence:UInt64.max,transport:"paused",position_ms:0,duration_ms:30000,error:nil))
check("total-decrease-enabled-precondition",shell.controls.more.isEnabled)
a.apply(paging(1));check("total-only-inverse-decrease-disables-more",!shell.controls.more.isEnabled)
a.apply(sample("New title"))
a.apply(paging(1));check("total-only-decrease-disables-more",!shell.controls.more.isEnabled)
a.apply(paging(2,false));check("auth-only-disables-library-actions",!shell.controls.more.isEnabled && !shell.controls.select.isEnabled)
a.apply(paging(2));check("auth-only-restores-library-actions",shell.controls.more.isEnabled && shell.controls.select.isEnabled)
check("paging-preserves-browse",a.table.selectedRow==0)
a.apply(Snapshot(epoch:1,session:1,revision:1001,authenticated:true,library:[],library_unchanged:false,total:2,queue:[],queue_unchanged:true,selected_occurrence:UInt64.max,transport:"paused",position_ms:0,duration_ms:30000,error:nil))
check("empty-with-total-can-page-no-selection",shell.controls.more.isEnabled && !shell.controls.select.isEnabled && !a.libraryDetails.isEnabled)
a.apply(sample("New title"));a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.tableViewSelectionDidChange(Notification(name:Notification.Name("selection")))
a.apply(paging(1));
let originalCell=a.tableView(a.table,viewFor:a.table.tableColumns[0],row:0) as! LibraryTrackCell
check("real-row-title-artist-duration",originalCell.name.stringValue=="New title" && originalCell.artist.stringValue=="Artist" && originalCell.duration.stringValue=="0:30")
check("real-row-current-identity",originalCell.current && originalCell.objectValue as? Int64 == 7)

for scale:CGFloat in [1,2] {for width:CGFloat in [400,600,1000] {for duration:UInt64 in [30000,3600000,360000000] {
 let cell=LibraryTrackCell(frame:NSRect(x:0,y:0,width:width,height:56*scale));cell.configure(track:Track(id:7,title:"Long title",artist:"Long artist",duration_ms:duration),current:false,scale:scale);cell.layoutSubtreeIfNeeded()
 let glyph=(cell.duration.stringValue as NSString).size(withAttributes:[.font:cell.duration.font!])
 check("duration-native-glyph-fits-\(Int(scale))-\(Int(width))-\(duration)",cell.duration.frame.width>=glyph.width && cell.duration.frame.height>=glyph.height && cell.duration.frame.maxX<=width-8 && cell.name.frame.maxX<cell.duration.frame.minX)
}}}

let b=[shell.controls.previous,shell.controls.play,shell.controls.next]
check("equal-painted-48-transport-cells",b.allSatisfy {$0.frame.size==NSSize(width:48,height:48)})
check("transport-physically-centered",abs(a.play.convert(a.play.bounds,to:host).midX-host.bounds.midX)<0.1)
check("reference-library-first-row-164",a.libraryArea.frame.minY==164)
check("reference-masthead-64",shell.navigation.frame.minY==64)
check("strict-identity-title-single-native-line",a.transportLabel.maximumNumberOfLines==1 && a.transportLabel.cell?.truncatesLastVisibleLine==true)
let long="SYNTHETIC QA — Long Night Transit / "+String(repeating:"Long recording disclosure segment / ",count:10)+"終点・終わり — Ω café e\u{301} 🚀"
let multiline="SYNTHETIC QA — Night Transit\n"+(1...12).map {"Movement \($0) / night passage\n"}.joined()+"終点・終わり — Ω café e\u{301} 🚀"
let short="Native Fixture500 · paused"
let labels=[("short",short),("long",long),("multiline-lf",multiline),("multiline-crlf",multiline.replacingOccurrences(of:"\n",with:"\r\n")),("multiline-cr",multiline.replacingOccurrences(of:"\n",with:"\r")),("unicode-separators","Ω café e\u{301} 🚀\u{2028}終点\u{2029}終わり"),("short-return",short)]
let buttons=[shell.controls.refresh,shell.controls.more,shell.controls.select,shell.controls.details,shell.controls.retry,shell.controls.previous,shell.controls.play,shell.controls.next,shell.controls.queue]
for scale:CGFloat in [1,2] {
 shell.textScale=scale
 for width:CGFloat in [760,900,960,1100,1200,1440,1920] {
  for height:CGFloat in [540,700] {
   host.setFrameSize(NSSize(width:width,height:height));shell.frame=host.bounds;shell.needsLayout=true;shell.layoutSubtreeIfNeeded()
   let base=[a.transportLabel.frame.height,shell.dockHeight,shell.fittingSize.height]
   for (stage,label) in labels {
    a.transportLabel.stringValue=label;shell.needsLayout=true;shell.layoutSubtreeIfNeeded()
    let tag="\(Int(width))x\(Int(height))-\(scale)-\(stage)"
    check("bounded-height-"+tag,zip(base,[a.transportLabel.frame.height,shell.dockHeight,shell.fittingSize.height]).allSatisfy {abs($0-$1)<0.1})
    check("exact-metadata-"+tag,Array(a.transportLabel.stringValue.utf8)==Array(label.utf8))
    check("title-mounted-positive-width-"+tag,a.transportLabel.superview===shell && a.transportLabel.frame.width>0 && !a.transportLabel.isHidden)
    check("parent-bounds-"+tag,shell.frame==host.bounds && shell.fittingSize.height==540)
   }
   let tag="\(Int(width))x\(Int(height))-\(scale)"

   check("shared-masthead-heading-rule-"+tag,shell.bodyDocument.rules.first==shell.railDocument.rules.first && shell.bodyDocument.rules.first==shell.navigation.frame.minY)
   check("queue-trailing-structural-track-"+tag,abs(shell.controls.queue.frame.maxX-width)<0.1 && abs(shell.controls.queue.frame.minY-(height-shell.dockHeight))<0.1)
   let visibleRow=a.table.rowView(atRow:0,makeIfNecessary:true)
   let visibleCell=a.table.view(atColumn:0,row:0,makeIfNecessary:true)
   check("list-full-width-row-track-"+tag,a.table.style == .plain && visibleRow != nil && visibleCell != nil && abs(visibleCell!.convert(visibleCell!.bounds,to:visibleRow!).minX)<0.1 && abs(visibleCell!.frame.width-visibleRow!.bounds.width)<0.1)
   // Draw production directly into an unattached bitmap. This is rule-pixel
   // proof, not a screenshot or native input/focus acceptance.
   for backing in [1,2] {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:Int(width)*backing,pixelsHigh:Int(height)*backing,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    let transform=NSAffineTransform();transform.scale(by:CGFloat(backing));transform.concat();shell.draw(shell.bounds);NSGraphicsContext.restoreGraphicsState()
    let outline=SoundQTokens.resolve(shell.effectiveAppearance).outline.usingColorSpace(.deviceRGB)!
    func rulePixel(_ x:CGFloat,_ y:CGFloat)->Bool {
     let c=bitmap.colorAt(x:Int(x*CGFloat(backing)),y:Int(height*CGFloat(backing)-1-y*CGFloat(backing)))!.usingColorSpace(.deviceRGB)!
     return abs(c.redComponent-outline.redComponent)<0.02 && abs(c.greenComponent-outline.greenComponent)<0.02 && abs(c.blueComponent-outline.blueComponent)<0.02 && c.alphaComponent>0.99
    }
    let commandBottom=a.play.frame.maxY,outer=(width-shell.centerWidth)/2
    check("center-bank-progress-rule-pixels-"+tag+"-\(backing)",[outer+2,a.play.frame.minX-8,a.play.frame.maxX+8,outer+shell.centerWidth-2].allSatisfy {rulePixel($0,commandBottom)})
   }

   check("physically-centered-"+tag,abs(a.play.frame.midX-width/2)<0.1)
   check("transport-equal-size-"+tag,b.allSatisfy {$0.frame.size==NSSize(width:48*scale,height:48*scale)})
   check("secondary-equal-painted-height-"+tag,[shell.controls.refresh,shell.controls.more,shell.controls.select,shell.controls.retry,shell.controls.queue].allSatisfy {$0.frame.height==40*scale})
   check("controls-inside-"+tag,buttons.allSatisfy {$0.frame.minX>=0 && $0.frame.maxX<=width+0.1 && $0.frame.minY>=0 && $0.frame.maxY<=height+0.1})
   check("actual-font-scale-"+tag,a.transportLabel.font!.pointSize==16*scale && a.search.font!.pointSize==14*scale && a.play.font!.pointSize==14*scale)
   check("rail-size-"+tag,width<1200 ? shell.railWidth==80 : shell.railWidth>=224)
   check("slider-inside-"+tag,a.slider.frame.maxY<=height+0.1 && a.slider.frame.width>0)
   check("library-viewport-before-dock-"+tag,shell.bodyScroll.frame.maxY<=height-shell.dockHeight+0.1 && shell.bodyScroll.frame.minX>=shell.railWidth && shell.bodyDocument.frame.height>=shell.bodyScroll.contentSize.height)
   check("library-viewport-positive-"+tag,a.libraryArea.frame.height>=56)
   check("library-content-not-behind-rail-"+tag,[shell.controls.refresh,shell.controls.more,shell.controls.select,shell.controls.retry].allSatisfy {$0.convert($0.bounds,to:shell).minX>=shell.railWidth})
   if scale==1 && width>=960 {check("reference-dock-100-"+tag,shell.dockHeight==100);check("reference-center-width-"+tag,shell.centerWidth==min(560,max(480,width*0.5)))}
  }
 }
}
check("original-enlarged-font-height-and-width-stress",{
 var ok=true
 for (buttonSize,labelSize):(CGFloat,CGFloat) in [(13,13),(20,20),(18,26)] {for width:CGFloat in [900,1100] {
  shell.textScale=1;host.setFrameSize(NSSize(width:width,height:700));shell.frame=host.bounds
  for button in buttons {button.font=NSFont.systemFont(ofSize:buttonSize)};a.transportLabel.font=NSFont.systemFont(ofSize:labelSize)
  var baseline=[CGFloat]()
  for (_,label) in labels {
   a.transportLabel.stringValue=label;shell.needsLayout=true;shell.layoutSubtreeIfNeeded()
   let heights=[a.transportLabel.frame.height,a.transportLabel.intrinsicContentSize.height,shell.dockHeight,shell.fittingSize.height]
   if baseline.isEmpty {baseline=heights};ok = ok && zip(heights,baseline).allSatisfy {abs($0-$1)<0.1}
   ok = ok && a.transportLabel.font?.pointSize==labelSize && buttons.allSatisfy {$0.font?.pointSize==buttonSize && $0.frame.width+0.1 >= $0.intrinsicContentSize.width}
   ok = ok && a.transportLabel.frame.width>0 && a.transportLabel.stringValue.utf8.elementsEqual(label.utf8)
  }
 }}
 return ok
}())
check("same-real-mounted-controls",a.search.superview===shell.bodyDocument && a.play.superview===shell && a.slider.superview===shell && a.scroll.documentView===a.table && a.scroll.superview===a.libraryArea)
check("native-cell-paint-path",a.play.cell is SoundQButtonCell)
for button in buttons {
 let frame=button.frame
 check("painted-hit-rect-"+button.title,button.bounds.size==frame.size && button.hitTest(NSPoint(x:frame.midX,y:frame.midY))===button && button.hitTest(NSPoint(x:frame.minX+1,y:frame.minY+1))===button)
}
let paintProbe=SoundQButton(title:"Probe",target:nil,action:nil);paintProbe.frame=NSRect(x:0,y:0,width:80,height:40);paintProbe.appearance=NSAppearance(named:.darkAqua)
@MainActor func raster(_ button:SoundQButton)->NSBitmapImageRep {
 let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:80,pixelsHigh:40,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap);button.drawSoundQ();NSGraphicsContext.restoreGraphicsState();return bitmap
}
let normalRaster=raster(paintProbe);paintProbe.isEnabled=false;let disabledRaster=raster(paintProbe)
check("painted-boundary-fills-full-cell",normalRaster.colorAt(x:4,y:4)!.alphaComponent>0.99 && normalRaster.colorAt(x:75,y:35)!.alphaComponent>0.99)
check("disabled-retains-painted-size",paintProbe.frame.size==NSSize(width:80,height:40) && disabledRaster.colorAt(x:4,y:4)!.alphaComponent>0.99)
check("native-target-action",buttons.allSatisfy {$0.action != nil && ($0 === a.libraryDetails ? $0.target === a.libraryDetailsAction : $0.target === a)})
check("availability-first-last",!shell.controls.previous.isEnabled && !shell.controls.next.isEnabled && a.play.isEnabled)

// V3: the real mounted control and real selector consume canonical failure,
// independently of browse selection or an unrelated error string.
func retryState(_ transport:String="idle",_ error:String?=nil,_ selected:UInt64?=nil,_ queued:Bool=false,_ auth:Bool=true,_ epoch:UInt64=1,_ scalar:Bool=false)->Snapshot {
 Snapshot(epoch:epoch,session:2,revision:1,authenticated:auth,library:scalar ? [] : [Track(id:7,title:"Browse only",artist:nil,duration_ms:30000)],library_unchanged:scalar,total:1,queue:scalar ? [] : (queued ? [Occurrence(id:99,track:Track(id:9,title:"Queued",artist:nil,duration_ms:30000))] : []),queue_unchanged:scalar,selected_occurrence:selected,transport:transport,position_ms:0,duration_ms:30000,error:error)
}
check("retry-clear-playback-label",shell.controls.retry.title=="Retry playback")
for (name,state) in [("empty",retryState()),("library-error",retryState("idle","network_unavailable")),("auth-error",retryState("idle","authentication_failed")),("save-error",retryState("paused","queue_storage_failed",99,true)),("paused",retryState("paused",nil,99,true)),("playing",retryState("playing",nil,99,true)),("preparing",retryState("preparing",nil,99,true)),("failed-no-selected-target",retryState("failed","native_playback_failed")),("logged-out",retryState("failed","native_playback_failed",99,true,false))] {
 a.apply(state);a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.tableViewSelectionDidChange(Notification(name:Notification.Name("selection")))
 let n=a.commands.count;a.retry()
 check("retry-disabled-no-command-"+name,!shell.controls.retry.isEnabled && a.commands.count==n)
}
a.apply(retryState());a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.tableViewSelectionDidChange(Notification(name:Notification.Name("selection")))
check("empty-playback-not-browse-selection",a.transportLabel.stringValue=="No queued track" && a.table.selectedRow==0)
a.apply(retryState("idle",nil,nil,true));check("queued-without-current-truthful",a.transportLabel.stringValue=="No current track")
a.apply(retryState("failed","native_playback_failed",99,true));let failedCount=a.commands.count;a.retry()
check("retry-failed-native-decoder-command",shell.controls.retry.isEnabled && a.commands.count==failedCount+1 && a.commands.last?["command"] as? String=="retry" && a.status.stringValue=="native playback failed")
let failedReloads=a.table.reloads,failedChrome=shell.chromeEntries
a.apply(retryState("failed","queue_storage_failed",99,true,true,1,true));check("retry-scalar-error-not-new-owner",shell.controls.retry.isEnabled && a.table.reloads==failedReloads && shell.chromeEntries==failedChrome && a.status.stringValue=="queue storage failed")
a.apply(retryState("preparing",nil,99,true,true,1,true));check("retry-success-clears-failure-affordance",!shell.controls.retry.isEnabled && a.status.stringValue=="1 of 1 tracks")
let successCount=a.commands.count;a.retry();check("retained-retry-selector-after-success-refused",a.commands.count==successCount)
a.apply(retryState("failed","cache_io",99,true));check("retry-prepare-failure-supported",shell.controls.retry.isEnabled)
a.epoch=2;let staleCount=a.commands.count;a.retry();check("stale-epoch-retry-no-command",a.commands.count==staleCount);a.epoch=1
a.apply(sample())

for face in NativeAssets.faces {check("required-face-"+face,NSFont(name:face,size:16)?.fontName==face)}
for script in ["日本語", "العربية", "e\u{301}", "🚀"] {let text=NSAttributedString(string:script,attributes:[.font:NativeAssets.font(16)]);check("script-layout-"+script,text.size().width>0)}
for dark in [true,false] {
 let t=SoundQTokens(dark:dark)
 for enabled in [true,false] {for primary in [true,false] {for selected in [true,false] {for hover in [true,false] {for focus in [true,false] {for pressed in [true,false] {
  let paint=t.paint(enabled:enabled,primary:primary,selected:selected,hover:hover,focus:focus,pressed:pressed)
  func luminance(_ c:NSColor)->Double {let c=c.usingColorSpace(.sRGB)!;func linear(_ v:CGFloat)->Double {let d=Double(v);return d<=0.04045 ? d/12.92 : pow((d+0.055)/1.055,2.4)};return 0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent)}
  if enabled {let f=luminance(paint.foreground),s=luminance(paint.surface);check("paint-contrast-\(dark)-\(primary)-\(selected)-\(hover)-\(focus)-\(pressed)",(max(f,s)+0.05)/(min(f,s)+0.05)>=4.5)}
 }}}}}}
}
print("LIBRARY_DOCK_PASS \(named.count) failures=\(failures.count)");exit(failures.isEmpty ? 0 : 1)
'''


def asset_contract(root):
    """Portable authority checks, independent of the runtime manifest reader."""
    resources = root / 'native/macos/Sources/Resources'
    manifest = json.loads((resources / 'asset-manifest.json').read_text())
    entries = manifest['files']
    assert len(entries) == len({e['path'] for e in entries}) == 11
    for entry in entries:
        data = (resources / entry['path']).read_bytes()
        assert len(data) == entry['bytes'] and hashlib.sha256(data).hexdigest() == entry['sha256'], entry['path']
    fonts = json.loads((resources / 'fonts/sources.json').read_text())
    for entry in fonts['files']:
        path = resources / entry['path'].removeprefix('assets/')
        assert hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256'], entry['path']
    assert hashlib.sha256((resources / 'brand/soundq-logo.png').read_bytes()).hexdigest() == '8b8ec5737c39efab15cc513772ee83360bda623c7aaf02aaa0cb4bc0c4e589f8'
    source = (root / 'native/macos/Sources/SoundQTokens.swift').read_text()
    # Frozen theme.dart181–211 exact order, not an arbitrary NSColor accent.
    expected = ['050505','0B0A08','14110D','211A13','F4EDDC','A89F90','32281F','6E6254','FF5A00','D84400','39C6B6','57D68D','FFC857','FF6B5F', 'FAFAF8','FFFFFF','FFFFFF','ECECEA','171411','5E554C','C8C2BC','76706A','C74400','9F3300','007F73','1B6E3C','8A5B00','B3261E']
    import re
    assert re.findall(r'0x([A-F0-9]{6})', source) == expected
    return {'assets':11,'fontFaces':6,'licenses':2,'semanticTokens':28,'manifestSha256':hashlib.sha256((resources/'asset-manifest.json').read_bytes()).hexdigest()}


def production_probe(root, apply_source_file=None):
    source = (root / 'native/macos/Sources/main.swift').read_text()
    signatures = ['func mountLibraryDock(', 'func apply(_ incoming: Snapshot)', 'func updateLibraryAvailability()', '@objc func retry()', 'func tableViewSelectionDidChange(', 'func numberOfRows(', 'func tableView(_ tableView: NSTableView,viewFor', 'func tableView(_ tableView: NSTableView,rowViewForRow']
    signatures += [s for s in ['@objc func toggleLibraryLiked()', 'func loadLibrary(', 'func makeLibraryMenu()', 'func libraryDetailsMenuAvailable(', '@objc func openLibraryDetailsFromMenu(', 'func updateLibraryDetailsAction()', 'func openLibraryDetails(', 'func closeLibraryDetails()', 'func retireLibraryDetails()', 'func reconcileLibraryDetails('] if s in source]
    signatures += [s for s in ['func readLibrary(', 'func finishLibraryRead(', 'func retireLibraryRead(', 'func updateLibraryReadPresentation()'] if s in source]
    types = TYPES + [s for s in ['struct Reply:', 'struct AudioEffect:', 'struct Credentials:', 'struct LibraryReadIdentity:', 'struct LibraryReadIntent:'] if s in source]
    blocks = {s: swift_block(source, s) for s in types+signatures}
    if apply_source_file:
        blocks['func apply(_ incoming: Snapshot)'] = swift_block(apply_source_file.read_text(), 'func apply(_ incoming: Snapshot)')
    probe = HARNESS.replace('__TYPES__', '\n'.join(blocks[s] for s in types)).replace('__METHODS__', '\n'.join(blocks[s] for s in signatures))
    if 'struct LibraryReadIntent:' in source:
        import re
        fields='\n'.join(line.strip() for line in source.splitlines() if re.match(r'    var (libraryLiked|libraryReadSerial|libraryReadRetired|pendingLibraryRead|acknowledgedLibraryRead|libraryReadFailure|libraryRevision|libraryReadInvalid)\b',line))
        probe=probe.replace(' var libraryDetailsMenuItem:NSMenuItem?', fields+'\n var busy=0\n var libraryDetailsMenuItem:NSMenuItem?')
        probe=probe.replace('func command(_ value:[String:Any]) {commands.append(value)}','@discardableResult func command(_ value:[String:Any],result:((Reply)->Void)? = nil,completion:(()->Void)? = nil)->Bool {commands.append(value);return false}')
    if 'func makeLibraryMenu()' not in source:
        start=probe.index('if let item=a.makeLibraryMenu()')
        end=probe.index('\n}',start)+2
        probe=probe[:start]+probe[end:]
    if 'func updateLibraryDetailsAction()' not in source:
        probe = probe.replace('var libraryDetailsAction:LibraryMetadataAction?;', '').replace('var libraryDetailsAlert:(alert:NSAlert,action:LibraryMetadataAction)?', '')
        probe = probe.replace('shell.controls.details,', '').replace('$0.action != nil && ($0 === a.libraryDetails ? $0.target === a.libraryDetailsAction : $0.target === a)', '$0.action != nil && $0.target === a')
    geometry = r'''
for scale:CGFloat in [1,2] {for width:CGFloat in [760,960,1200,1440] {
 let title=String(repeating:"Title long movement / ",count:100)+"TITLE SUFFIX Ω e\u{301} 🚀"
 let artist=String(repeating:"Artist long ensemble / ",count:100)+"ARTIST SUFFIX 終点"
 let area=LibraryMetadataDisclosure.area(track:Track(id:999,title:title,artist:artist,duration_ms:nil),available:NSSize(width:width,height:540),font:NativeAssets.font(14,scale:scale))
 let text=area.documentView as! NSTextView
 text.layoutManager!.ensureLayout(for:text.textContainer!)
 let used=text.layoutManager!.usedRect(for:text.textContainer!)
 check("metadata-native-exact-bytes-\(width)-\(scale)",text.string.utf8.elementsEqual(("Title\n"+title+"\n\nArtist\n"+artist).utf8))
 check("metadata-native-bounded-overflow-\(width)-\(scale)",area.frame.width<=560 && area.frame.height<=243 && used.height>area.contentSize.height && text.font!.pointSize==14*scale && text.isSelectable && !text.isEditable && !area.hasHorizontalScroller)
 let last=(text.string as NSString).length-1
 let glyph=text.layoutManager!.glyphRange(forCharacterRange:NSRange(location:last,length:1),actualCharacterRange:nil)
 let suffix=text.layoutManager!.boundingRect(forGlyphRange:glyph,in:text.textContainer!)
 check("metadata-native-final-suffix-laid-out-\(width)-\(scale)",suffix.width>0 && suffix.maxY<=used.maxY+1 && suffix.maxY>area.contentSize.height)
}}
'''
    if 'AuthFormView()' in source:
        probe=probe.replace('var loginArea=NSStackView();','var authForm=AuthFormState();var loginArea=AuthFormView();')
        probe=probe.replace('@objc func signOut(){};', '@objc func changeAuthMode(){};func authEdited(){};@objc func signOut(){};')
    probe = probe.replace('__METADATA_GEOMETRY__',geometry if 'func updateLibraryDetailsAction()' in source else '')
    if '@objc func openLinkImport()' in source:
        probe=probe.replace('@objc func signOut(){};', '@objc func openLinkImport(){};func retireLinkImport(){};func drainImportLibraryRefresh(){};@objc func signOut(){};')
    return probe, blocks



LF1_CASES = r'''
 // LF1: exact production read/command/apply with a held wire boundary and real,
 // window-free AppKit conversions. Native failure and previous projection are
 // established independently of the desired visible explanation.
 func lfWire(_ ids:[Int64],code:String="ok",unchanged:Bool=false,auth:Bool=true)->Data {
  var reply=try! JSONSerialization.jsonObject(with:wire(code=="ok",ids,unchanged:unchanged)) as! [String:Any]
  reply["ok"]=code=="ok";reply["code"]=code
  var state=reply["snapshot"] as! [String:Any]
  state["authenticated"]=auth;state["error"]=code=="ok" ? NSNull():code
  state["queue"]=[["id":99,"track":["id":9,"title":"Queued","artist":"Artist","duration_ms":30000]]]
  state["selected_occurrence"]=99;state["queue_unchanged"]=unchanged
  reply["snapshot"]=state
  return try! JSONSerialization.data(withJSONObject:reply)
 }
 for (width,scale):(CGFloat,CGFloat) in [(1440,2),(960,1)] {for retained in [false,true] {
  let owner=ready(),dock=owner.libraryDock!,tag="\(Int(width))-\(Int(scale))-\(retained ? "retained":"empty")"
  let host=NSView(frame:NSRect(x:0,y:0,width:width,height:760));host.addSubview(dock);dock.frame=host.bounds;dock.textScale=scale
  owner.apply(try! JSONDecoder().decode(Reply.self,from:lfWire([7])).snapshot!)
  tap(owner);owner.bridge.release(0,lfWire(retained ? [8]:[]));await settle(owner)
  if retained {owner.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)}
  let acknowledged=owner.acknowledgedLibraryRead,priorIDs=owner.snapshot!.library.map {$0.id},priorQueue=owner.snapshot!.queue.map {$0.id},selection=owner.table.selectedRow
  check("lf1-positive-prior-projection-"+tag,owner.libraryLiked && priorIDs==(retained ? [8]:[]) && priorQueue==[99] && owner.snapshot!.selected_occurrence==99 && owner.snapshot!.transport=="paused")
  owner.search.stringValue=String(repeating:"Native Fixture 500 ",count:32);owner.refresh()
  check("lf1-actual-over-limit-read-dispatched-"+tag,owner.search.stringValue.utf8.count>512 && owner.bridge.value(1)["query"] as? String==owner.search.stringValue && owner.bridge.value(1)["command"] as? String=="library_liked")
  check("lf1-loading-no-successful-empty-claim-"+tag,dock.empty.isHidden || !dock.empty.stringValue.contains("match this search"))
  owner.bridge.release(1,lfWire([],code:"invalid_query",unchanged:true));await settle(owner)
  host.layoutSubtreeIfNeeded();dock.needsLayout=true;dock.layoutSubtreeIfNeeded();dock.bodyScroll.layoutSubtreeIfNeeded()
  check("lf1-failure-owner-established-"+tag,owner.libraryReadFailure != nil && owner.pendingLibraryRead==nil && owner.search.isEnabled)
  check("lf1-refusal-retains-acknowledged-projection-"+tag,owner.libraryLiked && owner.acknowledgedLibraryRead==acknowledged && owner.snapshot!.library.map {$0.id}==priorIDs && owner.table.selectedRow==selection && owner.snapshot!.queue.map {$0.id}==priorQueue && owner.snapshot!.selected_occurrence==99 && owner.snapshot!.transport=="paused" && owner.bridge.revokes==0)
  check("lf1-refusal-explains-correction-"+tag,owner.status.stringValue=="Invalid query. Shorten your search and try again.")
  check("lf1-refusal-no-successful-empty-claim-"+tag,dock.empty.isHidden || !dock.empty.stringValue.contains("match this search"))
  let statusRect=owner.status.convert(owner.status.bounds,to:dock),viewport=dock.bodyScroll.contentView.convert(dock.bodyScroll.contentView.bounds,to:dock),searchRect=owner.search.convert(owner.search.bounds,to:dock)
  let natural=owner.status.cell!.cellSize(forBounds:NSRect(x:0,y:0,width:owner.status.bounds.width,height:10000))
  print("LF1_GEOMETRY",tag,"status",statusRect,"viewport",viewport,"search",searchRect,"nativeText",natural,"allocated",owner.status.bounds)
  check("lf1-native-coordinate-roundtrip-"+tag,dock.bodyDocument.convert(owner.status.convert(owner.status.bounds,to:dock.bodyDocument),to:dock)==statusRect && viewport.minY>=0 && viewport.maxY<=dock.bounds.height-dock.dockHeight+0.1)
  check("lf1-refusal-visible-first-viewport-"+tag,!owner.status.isHidden && statusRect.width>0 && viewport.contains(statusRect) && owner.status.visibleRect.contains(owner.status.bounds) && abs(dock.bodyScroll.contentView.bounds.minY)<0.1)
  check("lf1-full-feedback-native-cell-fits-"+tag,natural.width>0 && natural.height>0 && natural.width<=owner.status.bounds.width && natural.height<=owner.status.bounds.height && owner.status.font!.pointSize==12*scale)
  let reloads=owner.table.reloads,chrome=dock.chromeEntries,animation=dock.identityAnimations,treatment=dock.rowTreatmentEntries,progress=dock.progressEntries,statusFrame=owner.status.frame
  for _ in 0..<120 {owner.apply(try! JSONDecoder().decode(Reply.self,from:lfWire([],unchanged:true)).snapshot!)}
  check("lf1-scalars-preserve-refusal-no-content-chrome-work-"+tag,owner.status.stringValue=="Invalid query. Shorten your search and try again." && owner.table.reloads==reloads && dock.chromeEntries==chrome && dock.identityAnimations==animation && dock.rowTreatmentEntries==treatment && dock.progressEntries==progress+120 && owner.status.frame==statusFrame && !dock.needsLayout)
  owner.command(["command":"snapshot"]);owner.bridge.release(2,lfWire([],code:"queue_storage_failed",unchanged:true));await settle(owner)
  check("lf1-unrelated-command-keeps-own-error-"+tag,owner.status.stringValue=="queue storage failed" && owner.libraryReadFailure=="Invalid query. Shorten your search and try again.")
  owner.search.stringValue="valid missing";owner.refresh();owner.bridge.release(3,lfWire([]));await settle(owner)
  check("lf1-successful-empty-recovers-"+tag,owner.libraryReadFailure==nil && owner.libraryLiked && owner.snapshot!.library.isEmpty && !dock.empty.isHidden && dock.empty.stringValue=="No liked tracks match this search." && owner.status.stringValue=="0 of 100 tracks")
  owner.refresh();owner.bridge.release(4,lfWire([],code:"service_unavailable",unchanged:true));await settle(owner)
  check("lf1-other-read-error-not-empty-success-"+tag,owner.status.stringValue=="service unavailable" && (dock.empty.isHidden || !dock.empty.stringValue.contains("match this search")))
  owner.command(["command":"logout"]);owner.bridge.release(5,lfWire([],auth:false));await settle(owner)
  check("lf1-signout-clears-failure-mode-and-empty-"+tag,owner.libraryReadFailure==nil && !owner.libraryLiked && owner.acknowledgedLibraryRead==nil && dock.empty.isHidden && owner.libraryArea.isHidden)
 }}
'''


def callback_contract(root, output):
    """Execute exact App methods and decoded replies; only blocking ABI is held."""
    import re
    source=(root/'native/macos/Sources/main.swift').read_text()
    probe,blocks=production_probe(root)
    header=probe[:probe.index('var failures=[String]')]
    methods=['func command(', 'func loadLibrary(', '@objc func refresh()', '@objc func loadMore()', 'func controlTextDidEndEditing(', '@objc func selectTrack()', '@objc func toggle()', 'func queueCommand(', '@objc func nextTrack()', '@objc func previousTrack()']
    methods += [s for s in ['func command(_ value: [String:Any], completion:', 'func readLibrary(', '@objc func toggleLibraryLiked()', 'func finishLibraryRead(', 'func retireLibraryRead(', 'func updateLibraryReadPresentation()'] if s in source]
    if 'struct LibraryReadIntent:' not in source:
        methods=[s for s in methods if s != 'func command(_ value: [String:Any], completion:']
    for name in ['refresh','loadMore','selectTrack','toggle','nextTrack','previousTrack']:
        header=header.replace('@objc func '+name+'(){};','')
    for sig in methods:
        if sig in blocks: header=header.replace(blocks[sig], '')
    recorder='var commands=[[String:Any]]();'+('@discardableResult func command(_ value:[String:Any],result:((Reply)->Void)? = nil,completion:(()->Void)? = nil)->Bool {commands.append(value);return false}' if 'struct LibraryReadIntent:' in source else 'func command(_ value:[String:Any]) {commands.append(value)}')
    header=header.replace(recorder, '\n'.join(('@discardableResult\n' if s.startswith('func command(') and '-> Bool' in swift_block(source,s) else '')+swift_block(source,s) for s in methods))
    header=header.replace(' var busy=0\n', '')
    header=header.replace(' var window:NSWindow!;', '\n var bridge=Bridge();var busy=0;var storedCredentialVersion:UInt64=0;var wantsPlayback=false;var player:AVPlayer?;var observation:NSKeyValueObservation?;var reportPending=false\n func applyAudio(_ effect:AudioEffect){}\n var stored=[Credentials]();func storeCredentials(_ credentials:Credentials,epoch:UInt64){stored.append(credentials)}\n func deleteCredentials(){}\n var window:NSWindow!;')
    bridge=r"""
final class Bridge:@unchecked Sendable {
 struct Held {let value:Data;let epoch:UInt64;let completion:@Sendable(Data)->Void}
 var held=[Held]();var revokes=0;var released=0
 func send(_ data:Data,epoch:UInt64,completion:@escaping @Sendable(Data)->Void){held.append(Held(value:data,epoch:epoch,completion:completion))}
 func revoke()->UInt64 {revokes+=1;return UInt64(revokes+1)}
 func value(_ index:Int)->[String:Any] {try! JSONSerialization.jsonObject(with:held[index].value) as! [String:Any]}
 func release(_ index:Int,_ data:Data) {released+=1;held[index].completion(data)}
}
"""
    cases=r"""
@MainActor var failures=[String]();@MainActor var passes=[String]()
@MainActor func check(_ name:String,_ ok:Bool){if ok {passes.append(name);print("PASS",name)} else {failures.append(name);print("FAIL",name)}}
@MainActor func wire(_ ok:Bool=true,_ ids:[Int64]=[8],unchanged:Bool=false,epoch:UInt64=1,libraryRevision:UInt64=0)->Data {
 let tracks=ids.map {["id":$0,"title":"Track \($0)","artist":"Artist","duration_ms":30000] as [String:Any]}
 let s:[String:Any]=["epoch":epoch,"session":1,"revision":2,"authenticated":true,"library":tracks,"library_revision":libraryRevision,"library_unchanged":unchanged,"favorite_track_ids":ids,"total":100,"queue":[],"queue_unchanged":true,"selected_occurrence":NSNull(),"transport":"paused","position_ms":6000,"duration_ms":30000,"error":ok ? NSNull():"service_unavailable"]
 return try! JSONSerialization.data(withJSONObject:["ok":ok,"code":ok ? "ok":"service_unavailable","snapshot":s])
}
@MainActor func settle(_ a:App) async {
 let deadline=Date().addingTimeInterval(3)
 while a.busy != a.bridge.held.count-a.bridge.released && Date()<deadline {await Task.yield()}
 check("accepted-callback-barrier-\(a.bridge.released)",a.busy==a.bridge.held.count-a.bridge.released)
}
@main struct CallbackTests {
 @MainActor static func main() async throws {
 let assets=try NativeAssets.load(root:URL(fileURLWithPath:CommandLine.arguments[1]))
 func ready()->App {
  let a=App();a.mountLibraryDock(in:NSView(frame:NSRect(x:0,y:0,width:960,height:700)),assets:assets)
  let s=try! JSONDecoder().decode(Reply.self,from:wire(true,[7])).snapshot!;a.apply(s);a.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);a.updateLibraryAvailability();return a
 }
 func liked(_ a:App)->SoundQButton? {a.libraryDock!.bodyDocument.subviews.compactMap {$0 as? SoundQButton}.first {$0.title=="Liked"}}
 func tap(_ a:App) {if let b=liked(a),let action=b.action {_ = a.perform(action)}}
 // Existing caller, no new API: edited search must never append to old rows.
 let query=ready();query.search.stringValue="old";query.refresh();query.bridge.release(0,wire());await settle(query)
 query.search.stringValue="Ω & new";query.loadMore()
 check("edited-query-load-more-restarts-zero",query.bridge.value(1)["offset"] as? Int==0 && query.bridge.value(1)["query"] as? String=="Ω & new")
 query.bridge.release(1,wire());await settle(query)
 // Real held Refresh is independent of missing-control API discovery.
 let held=ready();let old=held.libraryDetailsAction;held.refresh()
 check("held-refresh-retires-row-disclosure",held.libraryDetailsAction==nil && old?.active==false && !held.libraryDetails.isEnabled)
 check("held-refresh-disables-conflicting-list-controls",!held.search.isEnabled && !held.libraryDock!.controls.refresh.isEnabled && !held.libraryDock!.controls.select.isEnabled)
 let count=held.bridge.held.count;held.selectTrack();held.queueCommand("queue_append",id:7)
 check("held-refresh-retained-row-handlers-refused",held.bridge.held.count==count && held.bridge.revokes==0)
 held.toggle();check("held-refresh-transport-still-dispatches",held.bridge.held.count==count+1 && held.bridge.value(count)["command"] as? String=="resume")
 held.bridge.release(0,wire(false,[7],unchanged:true));await settle(held)
 check("failed-refresh-keeps-rows-and-clears-list-pending",held.snapshot?.library.map {$0.id}==[7] && held.search.isEnabled && held.libraryDock!.controls.refresh.isEnabled)
 // Old trailing no-argument completion must still be ordinary completion.
 let legacy=ready();var completed=0;legacy.command(["command":"snapshot"]) {completed+=1};legacy.bridge.release(0,wire());await settle(legacy);check("legacy-trailing-noarg-completion",completed==1)
 let boundary=ready();boundary.busy=1;boundary.refresh();check("list-read-requires-idle-command-boundary",boundary.bridge.held.isEmpty && boundary.search.isEnabled);boundary.busy=0
 let a=ready();check("callback-mounted-liked-control",liked(a) != nil)
 if let button=liked(a) {
  tap(a);check("toggle-held-keeps-acknowledged-mode-rows",!button.selected && a.snapshot?.library.map {$0.id}==[7] && a.bridge.value(0)["command"] as? String=="library_liked" && a.bridge.revokes==0)
  a.bridge.release(0,wire());await settle(a)
  check("current-decoded-success-commits-mode-and-rows",button.selected && a.snapshot?.library.map {$0.id}==[8] && button.accessibilityValue() as? String=="Liked")
  a.search.stringValue="exact Ω & query";a.refresh();check("refresh-uses-acknowledged-liked",a.bridge.value(1)["command"] as? String=="library_liked" && a.bridge.value(1)["offset"] as? Int==0)
  a.bridge.release(1,wire());await settle(a);a.loadMore();check("more-uses-acknowledged-liked-identity",a.bridge.value(2)["command"] as? String=="library_liked" && a.bridge.value(2)["offset"] as? Int==1 && a.bridge.value(2)["query"] as? String=="exact Ω & query");a.bridge.release(2,wire());await settle(a)
  a.search.stringValue="search via delegate";a.controlTextDidEndEditing(Notification(name:NSControl.textDidEndEditingNotification,object:a.search));check("search-delegate-uses-liked-zero",a.bridge.value(3)["command"] as? String=="library_liked" && a.bridge.value(3)["offset"] as? Int==0);a.bridge.release(3,wire());await settle(a)
  tap(a);a.bridge.release(4,wire(false,[8],unchanged:true));await settle(a)
  check("decoded-failure-keeps-liked-mode-rows-feedback",button.selected && a.snapshot?.library.map {$0.id}==[8] && a.status.stringValue=="service unavailable" && a.search.isEnabled)
  let scalar=try! JSONDecoder().decode(Reply.self,from:wire(true,[],unchanged:true)).snapshot!;let reloads=a.table.reloads;a.apply(scalar)
  check("scalar-preserves-failure-and-no-row-reload",a.status.stringValue=="service unavailable" && a.table.reloads==reloads && a.snapshot?.library.map {$0.id}==[8])
  tap(a);a.bridge.release(5,Data("not json".utf8));await settle(a);check("malformed-clears-only-current-intent",button.selected && a.search.isEnabled && a.status.stringValue=="Invalid native response")
  a.busy=32;tap(a);check("immediate-busy-does-not-strand-intent",button.selected && a.search.isEnabled && a.bridge.held.count==6);a.busy=0
  tap(a);a.bridge.release(6,wire(true,[],unchanged:true));await settle(a);check("unchanged-success-does-not-acknowledge-toggle",button.selected && a.search.isEnabled && a.status.stringValue=="Invalid native response")
  tap(a);a.bridge.release(7,wire(true,[]));await settle(a);check("return-all-success-empty-presentation",!button.selected && a.libraryDock!.empty.stringValue=="Your library is empty. Refresh to check for tracks.")
  tap(a);a.bridge.release(8,wire(true,[]));await settle(a);check("liked-empty-selected-presentation",button.selected && a.libraryDock!.empty.stringValue=="No liked tracks match this search.")
  tap(a);a.bridge.release(9,Data(#"{"ok":true,"code":"ok"}"#.utf8));await settle(a)
  check("missing-snapshot-success-does-not-acknowledge-toggle",button.selected && a.search.isEnabled && a.status.stringValue=="Invalid native response")
  let before=a.bridge.held.count
  a.command(["command":"snapshot","invalid":Double.nan])
  check("serialization-refusal-does-not-dispatch-or-strand", a.bridge.held.count==before && a.search.isEnabled && a.status.stringValue=="Invalid native command")
 }
 for kind in ["account","epoch","supersession"] {
  let a=ready();if liked(a)==nil {continue};tap(a)
  // Retire through the real command owner (epoch revocation already happened
  // in the transport handler), then install a newer list intent.
  if kind=="account" {a.command(["command":"logout"])}
  else if kind=="epoch" {a.epoch=2;a.command(["command":"next"])}
  else {a.command(["command":"queue_restore"])}
  // The current sibling inherits the read already committed in core. It is
  // not an old-All transport fixture; real ABI composition is also exercised by
  // library_projection_regressions.py with both callback delivery orders.
  a.bridge.release(1,wire(true,kind=="account" ? [7]:[8],epoch:a.epoch,libraryRevision:1));await settle(a)
  check("inherited-"+kind+"-cannot-republish-retired-mode",kind=="account" || (a.snapshot?.library.map {$0.id}==[7] && a.libraryReadInvalid && !a.libraryDock!.controls.select.isEnabled))
  a.snapshot=try! JSONDecoder().decode(Reply.self,from:wire(true,[7],epoch:a.epoch)).snapshot!
  a.refresh();let newer=a.bridge.held.count-1
  var late=try! JSONSerialization.jsonObject(with:wire()) as! [String:Any]
  late["credentials"]=["access_token":"synthetic-access","refresh_token":"synthetic-refresh","account_id":"test-account","version":1]
  a.bridge.release(0,try! JSONSerialization.data(withJSONObject:late));await settle(a)
  check("stale-"+kind+"-credential-policy",a.stored.count==(kind=="supersession" ? 1:0))
  check("stale-"+kind+"-cannot-commit-or-clear-newer",liked(a)?.selected==false && !a.search.isEnabled && a.snapshot?.library.map {$0.id}==[7])
  a.bridge.release(newer,wire(true,[9],epoch:a.epoch));await settle(a);check("newer-"+kind+"-settles",a.search.isEnabled && a.snapshot?.library.map {$0.id}==[9])
 }
 print("LIBRARY_CALLBACK_PASS \(passes.count) failures=\(failures.count)");exit(failures.isEmpty ? 0:1)
 }
}
"""
    cases=cases.replace(' print("LIBRARY_CALLBACK_PASS',LF1_CASES+'\n print("LIBRARY_CALLBACK_PASS')
    generated='import AVFoundation\n'+bridge+'\n'+header+'\n'+cases
    path=output/'main.swift';path.write_text(generated)
    dependencies=[root/'native/macos/Sources'/f for f in FILES+['LibraryMetadataDisclosure.swift']]
    argv=['/usr/bin/swiftc','-swift-version','6','-parse-as-library','-j','2','-num-threads','2',*map(str,dependencies),str(path),'-o',str(output/'probe')]
    built=subprocess.run(argv,capture_output=True,timeout=180)
    ran=subprocess.run([str(output/'probe'),str(root/'native/macos/Sources/Resources')],capture_output=True,timeout=30) if built.returncode==0 else None
    (output/'compiler.log').write_bytes(built.stdout+built.stderr);(output/'runtime.log').write_bytes(ran.stdout+ran.stderr if ran else b'NOT RUN')
    lines=ran.stdout.decode().splitlines() if ran else []
    receipt=dict(compileExit=built.returncode,runExit=ran.returncode if ran else None,compileArgv=argv,passNames=[l[5:] for l in lines if l.startswith('PASS ')],failures=[l[5:] for l in lines if l.startswith('FAIL ')],testSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),productionSha256=hashlib.sha256(source.encode()).hexdigest(),probeSha256=hashlib.sha256(generated.encode()).hexdigest())
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt,indent=2));print((output/'compiler.log').read_text());print((output/'runtime.log').read_text());return built.returncode or (ran.returncode if ran else 1)


def runtime_asset_contract(root, output):
    """Execute the actual Swift reader on private resource trees, no NSApplication."""
    import copy
    import shutil
    output.mkdir(parents=True, exist_ok=False)
    source = output / 'main.swift'
    source.write_text('import AppKit\n do { _ = try NativeAssets.load(root:URL(fileURLWithPath:CommandLine.arguments[1])); print("READER_ACCEPT") } catch { print("READER_REFUSE \\(error)"); exit(1) }\n')
    native = root / 'native/macos/Sources/NativeAssets.swift'
    argv = ['/usr/bin/swiftc', '-swift-version', '6', '-j', '2', '-num-threads', '2', str(native), str(source), '-o', str(output/'reader')]
    built = subprocess.run(argv, capture_output=True, timeout=180)
    (output/'compiler.log').write_bytes(built.stdout+built.stderr)
    receipt: dict = dict(compileExit=built.returncode, compileArgv=argv, readerSourceSha256=hashlib.sha256(native.read_bytes()).hexdigest(), probeSha256=hashlib.sha256(source.read_bytes()).hexdigest(), testSha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), cases=[])
    if built.returncode == 0:
        resources = root/'native/macos/Sources/Resources'
        original = json.loads((resources/'asset-manifest.json').read_text())
        cases = [('valid',None,True),('reordered',None,True),('missing-schema',None,False),('unsupported-schema',None,False),('duplicate-missing-license',None,False),('missing-path',None,False),('unexpected','unexpected.txt',False),('dot-alias','./brand/soundq-logo.png',False),('slash-alias','brand//soundq-logo.png',False),('parent','../escape',False),('absolute','/escape',False),('corrupt-byte',None,False)]
        for name, alias, accepted in cases:
            private = output/name
            shutil.copytree(resources, private)
            manifest = copy.deepcopy(original)
            if name == 'reordered': manifest['files'].reverse()
            if name == 'missing-schema': manifest.pop('schema')
            if name == 'unsupported-schema': manifest['schema'] = 2
            if name == 'missing-path': manifest['files'].pop()
            if name == 'duplicate-missing-license':
                i = next(i for i,e in enumerate(manifest['files']) if e['path']=='fonts/spacegrotesk/OFL.txt')
                manifest['files'][i] = copy.deepcopy(manifest['files'][0])
                (private/'fonts/spacegrotesk/OFL.txt').unlink()
            if alias:
                if name == 'dot-alias': alias = './'+original['files'][0]['path']
                if name == 'slash-alias': alias = original['files'][0]['path'].replace('/', '//', 1)
                manifest['files'][0]['path'] = alias
                if name=='unexpected': (private/alias).write_bytes((resources/original['files'][0]['path']).read_bytes())
            if name=='corrupt-byte': (private/'fonts/spacegrotesk/OFL.txt').write_bytes(b'corrupt')
            (private/'asset-manifest.json').write_text(json.dumps(manifest))
            ran = subprocess.run([str(output/'reader'),str(private)],capture_output=True,timeout=30)
            (output/(name+'.log')).write_bytes(ran.stdout+ran.stderr)
            receipt['cases'].append(dict(name=name,exit=ran.returncode,expectedAccepted=accepted,passed=(ran.returncode==0)==accepted,manifestSha256=hashlib.sha256((private/'asset-manifest.json').read_bytes()).hexdigest(),logSha256=hashlib.sha256(ran.stdout+ran.stderr).hexdigest()))
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(json.dumps(receipt,indent=2))
    return built.returncode or int(not all(c['passed'] for c in receipt['cases']))


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source-root', type=Path, default=ROOT)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--regression', action='store_true', help='compatibility alias; all production tests run')
    p.add_argument('--callbacks-only', action='store_true', help='Held data-returning Bridge with actual App callers')
    p.add_argument('--apply-source-file', type=Path, help='Explicit predecessor apply replay; presentation builder remains current')
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    if args.callbacks_only:
        raise SystemExit(callback_contract(args.source_root,args.output))
    contract = asset_contract(args.source_root)
    (args.output / 'asset-contract.json').write_text(json.dumps(contract,indent=2)+'\n')
    probe, blocks = production_probe(args.source_root,args.apply_source_file)
    (args.output / 'main.swift').write_text(probe)
    dependencies = [args.source_root / 'native/macos/Sources' / f for f in FILES]
    metadata = args.source_root/'native/macos/Sources/LibraryMetadataDisclosure.swift'
    if metadata.exists(): dependencies.append(metadata)
    with tempfile.TemporaryDirectory(prefix='library-dock-', dir=os.environ.get('TMPDIR')) as tmp:
        argv = ['/usr/bin/swiftc', '-swift-version', '6', '-j', '2', '-num-threads', '2', '-module-cache-path', str(Path(tmp) / 'modules'), *map(str,dependencies), str(args.output / 'main.swift'), '-o', str(Path(tmp) / 'probe')]
        built = subprocess.run(argv, capture_output=True, timeout=180)
        if built.returncode == 0:
            annotations = subprocess.run(['/usr/bin/otool', '-l', str(Path(tmp) / 'probe')], capture_output=True, timeout=30)
            (args.output / 'probe-macho.log').write_bytes(annotations.stdout + annotations.stderr)
        ran = subprocess.run([str(Path(tmp) / 'probe'),str(args.source_root / 'native/macos/Sources/Resources'),str(args.output.resolve())], capture_output=True, timeout=60) if built.returncode == 0 else None
        for name, result in [('compiler.log', built), ('runtime.log', ran)]:
            (args.output / name).write_bytes(result.stdout + result.stderr if result else b'NOT RUN\n')
    lines = ran.stdout.decode().splitlines() if ran else []
    sha = lambda b: hashlib.sha256(b).hexdigest()
    receipt = dict(compileExit=built.returncode, runExit=ran.returncode if ran else None, compileArgv=argv, passNames=[l[5:] for l in lines if l.startswith('PASS ')], failures=[l[5:] for l in lines if l.startswith('FAIL ')], probeSha256=sha(probe.encode()), testSha256=sha(Path(__file__).read_bytes()), blocks={s:sha(b.encode()) for s,b in blocks.items()}, dependencies={p.name:sha(p.read_bytes()) for p in dependencies}, productionSha256=sha((args.source_root / 'native/macos/Sources/main.swift').read_bytes()), logs={n:sha((args.output/n).read_bytes()) for n in ['compiler.log','runtime.log']})
    (args.output / 'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(json.dumps({k:v for k,v in receipt.items() if k!='passNames'}, indent=2));print('passCount',sum(l.startswith('PASS ') for l in lines));print((args.output/'compiler.log').read_text());print('\n'.join(l for l in lines if not l.startswith('PASS ')))
    code = built.returncode or (ran.returncode if ran else 1)
    reader_code = runtime_asset_contract(args.source_root,args.output/'runtime-reader')
    callback_output=args.output/'callbacks';callback_output.mkdir()
    callback_code=callback_contract(args.source_root,callback_output)
    raise SystemExit(code or reader_code or callback_code)

# Explicit opt-in mounted search-only pilot. Unlike HARNESS, this creates one
# native window. Caller supplies real OS input; snapshots distinguish native
# cache rasters, current editor geometry, and target/action state. No app/core.
def focused_search_probe():
    return r'''
import AppKit
import CoreText
@MainActor final class Pilot:NSObject {
 let field=SoundQSearchField(frame:NSRect(x:100,y:160,width:271,height:40))
 let blur=NSTextField(frame:NSRect(x:100,y:70,width:300,height:32))
 let window=NSWindow(contentRect:NSRect(x:80,y:160,width:960,height:500),styleMask:[.titled,.closable],backing:.buffered,defer:false)
 var actions:[String]=[];var scale:CGFloat=1;var timer:Timer?;let root:URL
 init(root:URL) {self.root=root;super.init()
  window.title="SoundQ native search pilot";window.isReleasedWhenClosed=false
  let content=window.contentView!;content.wantsLayer=true;content.layer?.backgroundColor=NSColor(calibratedWhite:0.08,alpha:1).cgColor
  field.font=NativeAssets.font(14);field.isBordered=false;field.isBezeled=false;field.drawsBackground=false;field.textColor = .white;field.placeholderString="Search your library";field.sendsSearchStringImmediately=false;field.sendsWholeSearchString=true;field.target=self;field.action=#selector(search)
  field.setAccessibilityLabel("Pilot native search");content.addSubview(field)
  blur.stringValue="Native blur target";content.addSubview(blur)
  for (i,title) in ["Scale 1","Scale 2"].enumerated() {let b=NSButton(title:title,target:self,action:#selector(rescale(_:)));b.tag=i+1;b.frame=NSRect(x:100+i*140,y:280,width:120,height:40);content.addSubview(b)}
  let menu=NSMenu();let item=NSMenuItem();menu.addItem(item);let edit=NSMenu(title:"Edit");item.submenu=edit
  for (title,sel,key) in [("Cut",#selector(NSText.cut(_:)),"x"),("Copy",#selector(NSText.copy(_:)),"c"),("Paste",#selector(NSText.paste(_:)),"v"),("Select All",#selector(NSText.selectAll(_:)),"a")] {edit.addItem(withTitle:title,action:sel,keyEquivalent:key)}
  NSApp.mainMenu=menu
  timer=Timer.scheduledTimer(withTimeInterval:0.10,repeats:true){[weak self] _ in MainActor.assumeIsolated {self?.poll()}}
  window.makeKeyAndOrderFront(nil)
 }
 @objc func search() {actions.append(field.stringValue)}
 @objc func rescale(_ sender:NSButton) {scale=CGFloat(sender.tag);field.font=NativeAssets.font(14,scale:scale);field.frame.size=NSSize(width:scale==1 ? 271:831,height:40*scale);field.needsLayout=true;window.contentView?.layoutSubtreeIfNeeded()}
 func poll() {
  let request=root.appendingPathComponent("request.json");guard let data=try? Data(contentsOf:request),let obj=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let tag=obj["tag"] as? String,!tag.contains("/") else{return}
  try? FileManager.default.removeItem(at:request)
  if obj["stop"] as? Bool == true {NSApp.terminate(nil);return}
  if let e=field.currentEditor() as? NSTextView, obj["markedText"] as? Bool == true {e.setMarkedText("仮名",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))}
  if obj["raster"] as? Bool == true, let bitmap=field.bitmapImageRepForCachingDisplay(in:field.bounds) {
   field.cacheDisplay(in:field.bounds,to:bitmap)
   try? bitmap.representation(using:.png,properties:[:])?.write(to:root.appendingPathComponent("raster-\(tag).png"))
  }
  let cell=field.cell as! SoundQSearchFieldCell;let editor=field.currentEditor() as? NSTextView
  func rect(_ r:NSRect)->[Double] {[r.origin.x,r.origin.y,r.width,r.height]}
  func identity(_ o:AnyObject?)->String {o.map {String(describing:ObjectIdentifier($0))} ?? "nil"}
  var state:[String:Any] = ["tag":tag,"pid":ProcessInfo.processInfo.processIdentifier,"window":window.windowNumber,"content":rect(window.contentView!.bounds),"backing":window.backingScaleFactor,"scale":scale,"field":rect(field.frame),"fieldFont":field.font!.pointSize,"cell":identity(cell),"singleLine":cell.usesSingleLineMode,"scrollable":cell.isScrollable,"textRect":rect(cell.searchTextRect(forBounds:field.bounds)),"editor":identity(editor),"firstResponder":identity(window.firstResponder),"string":field.stringValue,"actions":actions]
  if let e=editor {
   // A font property/selected range does not prove entered glyph completeness.
   // Compare independent native CoreText outlines with the actual line baseline
   // and clip after ordinary input; this catches a fixed 16pt field-editor line.
   if let storage=e.textStorage,storage.length>0,let manager=e.layoutManager,let container=e.textContainer {
    manager.ensureLayout(for:container)
    let line=manager.lineFragmentRect(forGlyphAt:0,effectiveRange:nil)
    let baseline=manager.location(forGlyphAt:0).y
    let outline=CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(storage),.useGlyphPathBounds)
    let top=baseline-outline.maxY,bottom=baseline-outline.minY,visible=e.visibleRect
    var fontRuns:[[String:Any]]=[]
    storage.enumerateAttribute(.font,in:NSRange(location:0,length:storage.length)){value,range,_ in
     if let font=value as? NSFont {fontRuns.append(["range":[range.location,range.length],"name":font.fontName,"points":font.pointSize])}
    }
    state["fontRuns"]=fontRuns;state["typingFont"]=(e.typingAttributes[.font] as? NSFont)?.pointSize
    state["lineFragment"]=rect(line);state["glyphBaseline"]=baseline;state["unclippedOutline"]=rect(outline)
    state["typedGlyphsComplete"]=top>=line.minY && bottom<=line.maxY && top>=visible.minY && bottom<=visible.maxY
   }
   state["editorFrame"]=rect(e.frame);state["editorVisible"]=rect(e.visibleRect);state["editorFont"]=e.font?.pointSize;state["editorString"]=e.string;state["selection"]=[e.selectedRange().location,e.selectedRange().length];state["marked"]=[e.markedRange().location,e.markedRange().length];state["delegate"]=identity(e.delegate as AnyObject?);state["fieldEditor"]=e.isFieldEditor;state["clip"]=identity(e.superview);state["clipFrame"]=e.superview.map {rect($0.frame)};state["horizontalResize"]=e.isHorizontallyResizable;state["containerWidth"]=e.textContainer?.size.width
  }
  try? JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("state-\(tag).json"),options:.atomic)
 }
}
let app=NSApplication.shared;app.setActivationPolicy(.regular)
let assets=try NativeAssets.load(root:URL(fileURLWithPath:CommandLine.arguments[1]))
let pilot=Pilot(root:URL(fileURLWithPath:CommandLine.arguments[2]))
app.run()
'''


def qualify_focused_search_state(state):
    """Reject full-size font runs on a clipped native field-editor baseline."""
    if not state.get('editorString'):
        return {}
    return {
        'native-entered-glyphs-complete': state.get('typedGlyphsComplete') is True,
        'native-entered-font-size': bool(state.get('fontRuns')) and all(
            run['points'] == state['fieldFont'] for run in state['fontRuns']),
        'native-singleline-input': state['singleLine'] and state['scrollable'],
    }


if __name__ == '__main__':
    main()
